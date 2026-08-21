// SPDX-License-Identifier: GPL-3.0-or-later
//
// DDR3 fast ROM-load adaptor (rtl/mem/ssv_ddr_rom_loader.sv).
//
// The adaptor had no functional coverage: verif/ carried no model of the
// DDRAM_* read handshake, so nothing had ever checked that the bytes it
// replays into ssv_rom_loader are the bytes MiSTer Main left in DDR3. This
// bench supplies that model and checks the replayed stream byte for byte.
//
// The DDR3 model here is little-endian, matching the only other DDRAM_*
// client in this core: sys/arcade_video.v's screen_rotate drives
//   assign DDRAM_BE = ram_addr[2] ? 8'hF0 : 8'h0F;
// so the low half of an 8-byte word (byte offsets 0-3) is DIN/DOUT[31:0] --
// the lowest byte address sits in the lowest bits. Byte N of a linear blob is
// therefore DDRAM_DOUT[8*(N%8) +: 8].
`timescale 1ns/1ps

module tb_ssv_ddr_rom_loader;

localparam [31:0] DDR_BASE_BYTES = 32'h3000_0000;
localparam int    BLOB_LEN       = 1035;   // deliberately not a multiple of 8

logic clk = 0;
always #10 clk = ~clk;

logic reset       = 1'b1;
logic core_cold_reset = 1'b1;

logic        ioctl_download = 1'b0;
logic  [7:0] ioctl_index    = 8'd0;
logic        ioctl_wr       = 1'b0;
logic [26:0] ioctl_addr     = 27'd0;
logic        loader_wait    = 1'b0;

wire         replay_active;
wire   [7:0] replay_index;
wire         replay_hold;
wire         replay_wr;
wire  [26:0] replay_addr;
wire   [7:0] replay_dout;

wire         ddr_acquire;
wire   [7:0] ddr_burstcnt;
wire  [28:0] ddr_addr;
wire         ddr_rd;
logic        ddr_busy       = 1'b0;
logic [63:0] ddr_dout       = 64'd0;
logic        ddr_dout_ready = 1'b0;

int errors = 0;

ssv_ddr_rom_loader #(.DDR_BASE_BYTES(DDR_BASE_BYTES)) dut (
    .clk(clk), .reset(reset), .core_cold_reset(core_cold_reset),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .loader_wait(loader_wait),
    .replay_active(replay_active), .replay_wr(replay_wr),
    .replay_addr(replay_addr), .replay_dout(replay_dout),
    .replay_index(replay_index), .replay_hold(replay_hold),
    .ddr_acquire(ddr_acquire), .ddr_burstcnt(ddr_burstcnt),
    .ddr_addr(ddr_addr), .ddr_rd(ddr_rd), .ddr_busy(ddr_busy),
    .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
);

// ---------------------------------------------------------------------------
// DDR3 model
// ---------------------------------------------------------------------------
// The blob Main is pretending to have placed at DDR_BASE_BYTES. Every byte is
// distinct within each 8-byte group so a byte-order error cannot cancel out.
byte unsigned blob [BLOB_LEN];

// Word address the adaptor may read, relative to the base.
localparam [28:0] DDR_BASE_WORD = DDR_BASE_BYTES[31:3];

int reads_issued = 0;
int bad_addr     = 0;

// Avalon-MM style read: a request is accepted on an edge where ddr_rd is high
// and ddr_busy is low, after which the data comes back some cycles later on
// ddr_dout_ready. Latency is varied so the adaptor cannot depend on a fixed
// one, and ddr_busy is raised for a while after each accept the way a real
// controller does.
int unsigned lat_seed = 32'h1234_5678;

task automatic serve_reads;
    int unsigned lat;
    logic [28:0] a;
    int          base;
    forever begin
        @(posedge clk);
        if (ddr_rd && !ddr_busy) begin
            a = ddr_addr;
            reads_issued++;
            if (a < DDR_BASE_WORD || ((a - DDR_BASE_WORD) * 8) >= BLOB_LEN + 8) begin
                $display("FAIL: read outside the blob, word addr %h", a);
                bad_addr++;
                errors++;
            end
            ddr_busy <= 1'b1;
            lat_seed = lat_seed * 32'd1103515245 + 32'd12345;
            lat      = 2 + (lat_seed >> 28);     // 2..17 cycles
            repeat (lat) @(posedge clk);
            ddr_busy <= 1'b0;
            base = (a - DDR_BASE_WORD) * 8;
            for (int k = 0; k < 8; k++)
                ddr_dout[8*k +: 8] <= (base + k) < BLOB_LEN ? blob[base + k] : 8'hxx;
            ddr_dout_ready <= 1'b1;
            @(posedge clk);
            ddr_dout_ready <= 1'b0;
        end
    end
endtask

// ---------------------------------------------------------------------------
// Replay collector
// ---------------------------------------------------------------------------
byte unsigned got [BLOB_LEN];
int  got_n = 0;
int  addr_errs = 0;

// What the top level actually hands ssv_rom_loader as its index. The loader
// only accepts a byte when this is 0 (ssv_rom_loader.sv: ioctl_index == 8'd0),
// so a replay that outlives Main's index-0 download is silently dropped unless
// the index is held for the replay's duration.
wire [7:0] loader_index = replay_index;

// ssv_rom_loader accepts a byte on (ioctl_wr && !busy && index==0) and drives
// ioctl_wait from busy, with no input buffer -- so a byte counts as delivered
// exactly on the cycles where the strobe is up, wait is down, and the index it
// sees is still 0. Sampling every cycle the strobe is high instead would count
// a held byte many times over.
always @(posedge clk) begin
    if (replay_wr && !loader_wait && loader_index == 8'd0) begin
        if (got_n < BLOB_LEN) begin
            got[got_n] = replay_dout;
            if (replay_addr != got_n) begin
                if (addr_errs < 5)
                    $display("FAIL: byte %0d replayed with addr %0d", got_n, replay_addr);
                addr_errs++;
            end
        end
        got_n++;
    end
end

// Back-pressure. Free-running rather than derived from a loader model, so the
// wait can rise at any point in the adaptor's cycle -- including the cycle
// after it decided to strobe, which is the case that used to lose a byte.
initial begin
    forever begin
        repeat (23) @(posedge clk);
        loader_wait <= 1'b1;
        repeat (7)  @(posedge clk);
        loader_wait <= 1'b0;
    end
end

// While a byte is offered but not yet taken, it must not change: the loader
// samples whatever is on the bus in the cycle it stops waiting.
logic [26:0] held_addr;
logic  [7:0] held_dout;
logic        holding = 1'b0;
always @(posedge clk) begin
    if (replay_wr && loader_wait) begin
        if (holding && (replay_addr !== held_addr || replay_dout !== held_dout)) begin
            $display("FAIL: offered byte changed while waiting (addr %0d -> %0d)",
                     held_addr, replay_addr);
            errors++;
        end
        held_addr <= replay_addr;
        held_dout <= replay_dout;
        holding   <= 1'b1;
    end
    else holding <= 1'b0;
end

// The adaptor must never hold the DDR3 port while the core (and with it
// screen_rotate's write stream) is running: that would let it contend with
// framebuffer traffic.
always @(posedge clk)
    if (ddr_acquire && !core_cold_reset) begin
        $display("FAIL: ddr_acquire asserted while core_cold_reset low");
        errors++;
    end

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
task automatic run_download(input bit address_mode, input int len);
    ioctl_index    <= 8'd0;
    ioctl_download <= 1'b1;
    ioctl_addr     <= 27'd0;
    @(posedge clk);
    if (address_mode) begin
        // Main copies the blob straight into DDR3 and emits no ioctl_wr at
        // all; ioctl_addr is left holding the byte count.
        repeat (20) @(posedge clk);
        // user_io_set_download(1, len) in address mode: hps_io latches the
        // byte count into ioctl_addr up front, and no FIO_FILE_TX_DAT ever
        // fires, so it is never incremented during the transfer...
        ioctl_addr <= len[26:0];
        repeat (4)  @(posedge clk);
        // ...but hps_io's end-of-download branch adds one unconditionally.
        ioctl_addr <= len[26:0] + 27'd1;
    end
    else begin
        // Legacy MRA: real byte traffic over the ioctl bus.
        for (int i = 0; i < len; i++) begin
            ioctl_addr <= i[26:0];
            ioctl_wr   <= 1'b1;
            @(posedge clk);
            ioctl_wr   <= 1'b0;
            @(posedge clk);
        end
    end
    ioctl_download <= 1'b0;
    @(posedge clk);
    // No-gap contract: for an address-mode load, replay_active must already
    // be high on the very cycle the real download is seen low, or
    // ssv_host_guard's core_cold_reset hold would open for one cycle on a
    // game switch and the port gate would deadlock (see the adaptor's
    // replay_active comment).
    if (address_mode && !replay_active) begin
        $display("FAIL: replay_active gap after ioctl_download fell");
        errors++;
    end
    if (!address_mode && replay_active) begin
        $display("FAIL: replay_active rose for a legacy download");
        errors++;
    end
endtask

int timeout;

initial begin
    for (int i = 0; i < BLOB_LEN; i++)
        blob[i] = 8'((i * 7) ^ (i >> 3) ^ 8'hA5);

    fork
        serve_reads();
    join_none

    repeat (4) @(posedge clk);
    reset <= 1'b0;
    repeat (4) @(posedge clk);

    // -------------------------------------------------------------------
    // 1. Legacy download: the adaptor must stay completely out of the way.
    // -------------------------------------------------------------------
    run_download(.address_mode(0), .len(32));
    repeat (200) @(posedge clk);
    if (got_n != 0) begin
        $display("FAIL: legacy download produced %0d replayed bytes", got_n);
        errors++;
    end
    if (reads_issued != 0) begin
        $display("FAIL: legacy download issued %0d DDR reads", reads_issued);
        errors++;
    end

    // -------------------------------------------------------------------
    // 2. Address-mode download: the blob must come back byte for byte.
    // -------------------------------------------------------------------
    run_download(.address_mode(1), .len(BLOB_LEN));

    timeout = 0;
    while (got_n < BLOB_LEN && timeout < 400000) begin
        @(posedge clk);
        timeout++;
    end
    if (got_n < BLOB_LEN) begin
        $display("FAIL: only %0d of %0d bytes replayed before timeout", got_n, BLOB_LEN);
        errors++;
    end

    repeat (500) @(posedge clk);

    if (got_n != BLOB_LEN) begin
        $display("FAIL: replayed %0d bytes, expected %0d", got_n, BLOB_LEN);
        errors++;
    end
    if (addr_errs != 0) begin
        $display("FAIL: %0d bytes replayed with the wrong ioctl_addr", addr_errs);
        errors++;
    end

    for (int i = 0; i < BLOB_LEN; i++) begin
        if (got[i] !== blob[i]) begin
            if (errors < 12)
                $display("FAIL: byte %0d is %02h, expected %02h", i, got[i], blob[i]);
            errors++;
        end
    end

    if (replay_active) begin
        $display("FAIL: replay_active still high after the load finished");
        errors++;
    end

    // -------------------------------------------------------------------
    // 3. Gate honoured: with core_cold_reset low the adaptor must not touch
    // the DDR3 port at all, and must resume cleanly once the gate rises.
    // (ssv_host_guard holds core_cold_reset high for the entire replay in
    // real operation, because it folds ~rom_loaded in; this checks the
    // fail-safe path.)
    // -------------------------------------------------------------------
    got_n           = 0;
    reads_issued    = 0;
    core_cold_reset <= 1'b0;
    repeat (20) @(posedge clk);
    run_download(.address_mode(1), .len(64));
    repeat (2000) @(posedge clk);
    if (reads_issued != 0 || got_n != 0) begin
        $display("FAIL: gate low but adaptor issued %0d reads / replayed %0d bytes",
                 reads_issued, got_n);
        errors++;
    end
    if (!replay_active) begin
        $display("FAIL: pending load lost while gate low");
        errors++;
    end
    core_cold_reset <= 1'b1;
    timeout = 0;
    while (got_n < 64 && timeout < 100000) begin
        @(posedge clk);
        timeout++;
    end
    if (got_n != 64) begin
        $display("FAIL: load did not resume after gate rose (%0d of 64 bytes)", got_n);
        errors++;
    end
    for (int i = 0; i < 64; i++) begin
        if (got[i] !== blob[i]) begin
            if (errors < 12)
                $display("FAIL: resumed byte %0d is %02h, expected %02h", i, got[i], blob[i]);
            errors++;
        end
    end
    repeat (50) @(posedge clk);

    // -------------------------------------------------------------------
    // 4. Main moves on while the replay is still in flight.
    //
    // This is what address mode actually looks like on hardware and it is the
    // case the original code got wrong. Main's rom_finish() does a shmem_put
    // and drops ioctl_download in milliseconds -- it never waits for the core
    // to consume anything -- then proceeds to the next MRA element. Every
    // shipped SSV MRA has a trailing <nvram index="4">, so Main sets
    // ioctl_index to 4 and starts that transfer while the core is still
    // replaying megabytes out of DDR3. ssv_rom_loader only accepts bytes while
    // the index it sees is 0, so unless the index is held for the replay the
    // rest of the ROM is dropped on the floor, rom_loaded never asserts, and
    // the core never leaves reset -- a black screen on every game.
    // -------------------------------------------------------------------
    got_n        = 0;
    reads_issued = 0;
    core_cold_reset <= 1'b1;
    repeat (20) @(posedge clk);
    run_download(.address_mode(1), .len(BLOB_LEN));

    // Main is done with index 0 and immediately starts the next element.
    repeat (40) @(posedge clk);
    if (!replay_hold) begin
        $display("FAIL: replay_hold low while a replay is in flight -- Main is not stalled");
        errors++;
    end
    ioctl_index    <= 8'd4;
    ioctl_download <= 1'b1;

    timeout = 0;
    while (got_n < BLOB_LEN && timeout < 400000) begin
        @(posedge clk);
        timeout++;
    end
    ioctl_download <= 1'b0;
    ioctl_index    <= 8'd0;

    if (got_n != BLOB_LEN) begin
        $display("FAIL: Main switched index mid-replay: only %0d of %0d bytes reached the loader",
                 got_n, BLOB_LEN);
        errors++;
    end
    for (int i = 0; i < BLOB_LEN; i++) begin
        if (got[i] !== blob[i]) begin
            if (errors < 12)
                $display("FAIL: index-switch byte %0d is %02h, expected %02h", i, got[i], blob[i]);
            errors++;
        end
    end
    repeat (50) @(posedge clk);

    if (errors == 0) $display("PASS tb_ssv_ddr_rom_loader (%0d bytes, %0d DDR reads)",
                              BLOB_LEN, reads_issued);
    else             $display("FAIL tb_ssv_ddr_rom_loader (%0d errors)", errors);
    $finish;
end

endmodule
