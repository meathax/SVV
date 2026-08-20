// ssv_ddr_rom_loader.sv
//
// DDR3 fast-load adaptor for the index-0 ROM stream.
//
// Background: an MRA <rom index="0" address="0x...."> element tells MiSTer
// Main to memcpy the assembled ROM blob straight into DDR3 at that address
// instead of streaming it over the ioctl link byte-by-byte. Main still runs
// the ordinary ioctl_download handshake around the transfer (so ioctl_addr
// ends up holding the final byte count), but emits zero ioctl_wr strobes.
// This is the same convention MiSTer-devel/Arcade-IGSPGM_MiSTer's
// ddr_rom_loader_adaptor uses (rtl/rom_loader.sv, module
// ddr_rom_loader_adaptor) -- ported here rather than copied verbatim because
// this core's ssv_rom_loader keys off ioctl_addr directly for byte-pair
// parity and mapping-table comparisons.
//
// This module sits alongside ssv_rom_loader, not inside it: it watches the
// real HPS ioctl bus for index-0 traffic and classifies which of the two
// download shapes actually happened once ioctl_download for that index
// falls:
//   - at least one ioctl_wr was observed  -> legacy MRA (no address=), the
//     bytes already reached ssv_rom_loader over the real bus. This module
//     stays idle for that entire session; behaviour is byte-for-byte
//     identical to before this module existed.
//   - no ioctl_wr was observed and ioctl_addr != 0 -> address-mode MRA. The
//     blob is sitting in DDR3; ioctl_addr is the byte count. This module
//     reads it back over the DDRAM_* port and replays it as a synthetic
//     ioctl byte stream (replay_wr/replay_addr/replay_dout) with the same
//     one-strobe-per-byte, wait-gated shape hps_io itself uses, so the
//     caller can mux it straight into ssv_rom_loader's ioctl_wr/ioctl_addr/
//     ioctl_dout inputs with no changes to ssv_rom_loader itself.
//
// DDR3 port ownership: ddr_acquire is only ever asserted while the caller's
// video_reset is also asserted (AND'd in here, not left to the caller to
// remember). screen_rotate is the only other DDRAM_* consumer in this core
// and is not producing meaningful framebuffer traffic while video is held
// in reset, so acquiring the port during that window cannot contend with a
// live rotate transaction. If video_reset is not asserted when a
// address-mode index-0 download completes (should not happen -- ROM load
// only ever happens while the core is held in reset -- but this is a
// hardware-visible DDR3 port-sharing change and is called out explicitly
// per the project's hardware-hazard rules), this module simply never
// acquires the port and the load stalls (rom_loaded never asserts, LED_USER
// stays lit) rather than silently corrupting screen_rotate's traffic.
module ssv_ddr_rom_loader #(
    parameter [31:0] DDR_BASE_BYTES = 32'h3000_0000  // must match the MRA's address=
)(
    input                clk,
    input                reset,
    input                video_reset,   // DDR3 port may only be acquired while this is high

    // Real HPS ioctl bus (only the index-0 window is acted on).
    input                ioctl_download,
    input          [7:0] ioctl_index,
    input                ioctl_wr,
    input         [26:0] ioctl_addr,

    // ssv_rom_loader's own ioctl_wait output (the value it would drive back
    // to hps_io on the real bus). This is fed back in so the replay stream
    // honours the exact same back-pressure contract hps_io does -- without
    // it, replay could push a byte into the loader mid-SDRAM-write.
    input                loader_wait,

    // Synthetic ioctl view for ssv_rom_loader's index-0 path. When
    // replay_active is low every one of these is inert; the caller ORs/
    // muxes them with the real bus and gets the real bus back unchanged.
    output logic         replay_active,
    output logic         replay_wr,
    output logic  [26:0] replay_addr,
    output logic   [7:0] replay_dout,

    // DDRAM_* port (arbitrated by the caller against screen_rotate using
    // ddr_acquire as the select).
    output logic         ddr_acquire,
    output logic   [7:0] ddr_burstcnt,
    output logic  [28:0] ddr_addr,
    output logic         ddr_rd,
    input                ddr_busy,
    input         [63:0] ddr_dout,
    input                ddr_dout_ready
);

localparam [7:0] ROM_INDEX = 8'd0;

typedef enum logic [1:0] {
    S_IDLE,
    S_ISSUE,
    S_WAIT,
    S_DRAIN
} state_t;

state_t      state;
logic        prev_download;
logic        wr_seen;
logic [26:0] length;
logic [26:0] offset;
logic [63:0] buffer;

wire sel = (ioctl_index == ROM_INDEX);

assign ddr_burstcnt  = 8'd1;
assign replay_active = (state != S_IDLE);
// AND with video_reset every cycle, not just at the moment of acquisition:
// if video_reset were ever to drop mid-load this releases the port
// immediately rather than trusting a stale decision from load-start.
assign ddr_acquire   = (state != S_IDLE) && video_reset;

always_ff @(posedge clk) begin
    if (reset) begin
        state          <= S_IDLE;
        prev_download  <= 1'b0;
        wr_seen        <= 1'b0;
        ddr_rd         <= 1'b0;
        replay_wr      <= 1'b0;
    end else begin
        prev_download <= ioctl_download;
        replay_wr     <= 1'b0;

        if (sel && ioctl_download && ioctl_wr)
            wr_seen <= 1'b1;

        case (state)
            S_IDLE: begin
                if (sel && prev_download && !ioctl_download) begin
                    if (wr_seen) begin
                        // Legacy MRA: bytes already streamed over the real
                        // ioctl bus. Nothing to replay.
                        wr_seen <= 1'b0;
                    end
                    else if (ioctl_addr != 27'd0) begin
                        // Address-mode MRA: ioctl_addr is the final byte
                        // count Main left behind; the blob itself is in
                        // DDR3 at DDR_BASE_BYTES.
                        length <= ioctl_addr;
                        offset <= 27'd0;
                        state  <= S_ISSUE;
                    end
                    // ioctl_addr == 0 && !wr_seen: an empty index-0
                    // download. Nothing to load either way.
                end
            end

            S_ISSUE: begin
                // Only issue once the port is actually granted (video_reset
                // asserted) and the previous transaction has drained.
                if (video_reset && !ddr_busy) begin
                    // 8-byte-aligned word address for the current byte
                    // offset, expressed the same way the top-level's other
                    // DDRAM_ADDR producer (screen_rotate) does: a byte
                    // address shifted right by 3.
                    ddr_addr <= DDR_BASE_BYTES[31:3] + {5'b00000, offset[26:3]};
                    ddr_rd   <= 1'b1;
                    state    <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (!ddr_busy)
                    ddr_rd <= 1'b0;
                if (ddr_dout_ready) begin
                    buffer <= ddr_dout;
                    state  <= S_DRAIN;
                end
            end

            S_DRAIN: begin
                // One byte per cycle, MSB-first out of the 64-bit word --
                // this must match the byte order Main used when it wrote
                // the blob into DDR3 (sequential stream byte 0 is the top
                // byte of the first 64-bit word), same convention
                // MiSTer-devel/Arcade-IGSPGM_MiSTer's adaptor uses.
                // Gated on loader_wait exactly like hps_io gates ioctl_wr
                // on ioctl_wait for the real bus, so this never outruns
                // ssv_rom_loader's SDRAM-write pipeline.
                if (!loader_wait) begin
                    replay_wr   <= 1'b1;
                    replay_addr <= offset;
                    replay_dout <= buffer[63:56];
                    buffer      <= {buffer[55:0], 8'h00};
                    offset      <= offset + 27'd1;
                    if (offset + 27'd1 == length)
                        state <= S_IDLE;
                    else if (offset[2:0] == 3'd7)
                        state <= S_ISSUE;
                    // else: stay in S_DRAIN, next byte comes from the
                    // buffer already latched -- no new DDR read needed.
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
