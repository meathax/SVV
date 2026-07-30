`timescale 1ns/1ps
// Integration boot path: ioctl stream -> ssv_rom_loader -> behavioral memory
// -> ssv_core reset release. Exercises the loader/core handshake without the
// MiSTer emu wrapper or physical SDRAM PHY.

module tb_ssv_loader_core_boot;
import ssv_pkg::*;

logic clk = 0;
always #5 clk = ~clk;

logic rst_loader;
logic mem_ready;
logic ioctl_download, ioctl_wr;
logic [7:0] ioctl_index, ioctl_dout;
logic [26:0] ioctl_addr;
logic ioctl_wait;
logic sdr_wr_req, sdr_wr_ack;
logic sdr_p4_req, sdr_p4_ack;
logic [SDR_AW:1] sdr_p4_addr;
logic [15:0] sdr_p4_dout;

logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic rom_loaded;
logic [26:0] download_max_addr;

logic core_rst, ce_cpu;
logic [1:0] ce_div;
logic sdr_p0_req, sdr_p0_ack;
logic [SDR_AW:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p2_req, sdr_p2_ack;
logic [SDR_AW:4] sdr_p2_addr;
logic [127:0] sdr_p2_dout;
logic core_wr_req, core_wr_ack;
logic [SDR_AW:1] core_wr_addr;
logic [15:0] core_wr_din;
logic [1:0] core_wr_be;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;

// Sparse store; unread locations read as 0xFFFF.
logic [15:0] store [bit [24:1]];

function automatic [15:0] mem_rd(input [24:1] addr);
    if (store.exists(addr))
        mem_rd = store[addr];
    else
        mem_rd = 16'hffff;
endfunction

ssv_rom_loader loader (
    .clk(clk), .rst(rst_loader), .mem_ready(mem_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .rom_loaded(rom_loaded),
    .download_max_addr(download_max_addr)
);

ssv_core core (
    .cfg(ssv_pkg::cfg_dynagear()),
    .clk_sys(clk), .rst(core_rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(core_wr_req), .sdr_wr_addr(core_wr_addr),
    .sdr_wr_din(core_wr_din), .sdr_wr_be(core_wr_be),
    .sdr_wr_ack(core_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hfffd),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

always_ff @(posedge clk) begin
    if (core_rst) begin
        ce_div <= 0;
        ce_cpu <= 0;
    end else begin
        ce_cpu <= (ce_div == 2);
        ce_div <= (ce_div == 2) ? 0 : ce_div + 1'd1;
    end
end

logic [15:0] wr_cur;

always_ff @(posedge clk) begin
    sdr_wr_ack <= 1'b0;
    sdr_p4_ack <= 1'b0;
    sdr_p4_dout <= 16'd0;
    if (sdr_wr_req && !sdr_wr_ack) begin
        wr_cur = mem_rd(sdr_wr_addr);
        if (sdr_wr_be[0]) wr_cur[7:0] = sdr_wr_din[7:0];
        if (sdr_wr_be[1]) wr_cur[15:8] = sdr_wr_din[15:8];
        store[sdr_wr_addr] = wr_cur;
        sdr_wr_ack <= 1'b1;
    end
    if (sdr_p4_req)
        sdr_p4_ack <= 1'b1;
end

logic p0_pending;
logic [SDR_AW:1] p0_latched;
always_ff @(posedge clk) begin
    sdr_p0_ack <= 1'b0;
    if (core_rst) begin
        p0_pending <= 1'b0;
        sdr_p0_dout <= 16'h0;
    end
    else if (sdr_p0_req && !p0_pending) begin
        p0_pending <= 1'b1;
        p0_latched <= sdr_p0_addr;
    end
    else if (p0_pending) begin
        sdr_p0_dout <= mem_rd(p0_latched);
        sdr_p0_ack <= 1'b1;
        p0_pending <= 1'b0;
    end
end

always_ff @(posedge clk) begin
    sdr_p2_ack <= 1'b0;
    sdr_p2_dout <= 128'd0;
    if (sdr_p2_req) begin
        // p2 is a 16-byte burst: eight 16-bit words, lowest address in the
        // low bits (sdram.sv assembles p2_dout little-endian).
        sdr_p2_dout <= {
            mem_rd({sdr_p2_addr, 3'd7}),
            mem_rd({sdr_p2_addr, 3'd6}),
            mem_rd({sdr_p2_addr, 3'd5}),
            mem_rd({sdr_p2_addr, 3'd4}),
            mem_rd({sdr_p2_addr, 3'd3}),
            mem_rd({sdr_p2_addr, 3'd2}),
            mem_rd({sdr_p2_addr, 3'd1}),
            mem_rd({sdr_p2_addr, 3'd0})
        };
        sdr_p2_ack <= 1'b1;
    end
end

always_ff @(posedge clk) begin
    core_wr_ack <= 1'b0;
    if (core_wr_req && !core_wr_ack) begin
        wr_cur = mem_rd(core_wr_addr);
        if (core_wr_be[0]) wr_cur[7:0] = core_wr_din[7:0];
        if (core_wr_be[1]) wr_cur[15:8] = core_wr_din[15:8];
        store[core_wr_addr] = wr_cur;
        core_wr_ack <= 1'b1;
    end
end

task automatic tick;
    @(posedge clk); #1;
endtask

task automatic send_byte(input [26:0] addr, input [7:0] data);
    while (ioctl_wait) tick();
    ioctl_addr = addr;
    ioctl_dout = data;
    ioctl_wr = 1;
    tick();
    ioctl_wr = 0;
    tick();
endtask

// The loader requires an MRA <rom index="1"> configuration block before it
// will accept index-0 bytes -- without it cfg_valid stays low, index 0 is
// discarded and rom_loaded never asserts (which is exactly how this bench
// caught the new requirement). Send the Dyna Gear record first.
// The bytes mra/Dyna Gear.mra ships, verbatim, rather than hand-built values.
// This task previously restated them and carried the stale v1 form (bank_map
// 0xE4, flags0 0x00, no samples_mb), which the loader now rejects outright --
// version 2 is required because a v1 block has no sample size and would put the
// st010 block on top of the samples.
localparam logic [127:0] CFG_DYNAGEAR = 128'h53020110110003000404010004000079;

task automatic send_cfg;
    logic [7:0] b [0:15];
    logic [7:0] sum;
    int i;
    begin
        for (i = 0; i < 16; i = i + 1)
            b[i] = CFG_DYNAGEAR[(15 - i) * 8 +: 8];
        sum = 8'd0;
        for (i = 0; i < 15; i = i + 1) sum = sum + b[i];
        if (b[15] !== ((-sum) & 8'hFF))
            $fatal(1, "cfg literal checksum %h, computed %h",
                   b[15], (-sum) & 8'hFF);
        ioctl_index = 8'd1;
        for (i = 0; i < 16; i = i + 1) send_byte(27'(i), b[i]);
        ioctl_index = 8'd0;
        tick();
    end
endtask

logic saw_fetch;
logic [31:0] first_pc;
integer cycles;

initial begin
    rst_loader = 1;
    mem_ready = 0;
    ioctl_download = 0;
    ioctl_index = 0;
    ioctl_wr = 0;
    ioctl_addr = 0;
    ioctl_dout = 0;
    core_rst = 1;
    saw_fetch = 0;
    first_pc = 0;

    repeat (4) tick();
    rst_loader = 0;
    mem_ready = 1;
    ioctl_download = 1;
    send_cfg();

    // Packed program image at stream base (loader writes SDR words).
    send_byte(27'h000000, 8'hcd); // NOP
    send_byte(27'h000001, 8'hcd); // NOP
    send_byte(27'h000002, 8'h00); // HALT
    send_byte(27'h000003, 8'h00);

    while (ioctl_wait) tick();
    ioctl_download = 0;
    repeat (8) tick();

    if (!rom_loaded)
        $fatal(1, "rom_loaded did not assert after ioctl drain");
    if (download_max_addr < 27'h3)
        $fatal(1, "download_max_addr too small: %0h", download_max_addr);

    // Ensure reset-vector alias (CPU PC 0xFFFFFFF0 -> offset 0xFFFF0) has NOPs.
    // The download already wrote SDR words 0/1; also plant the high alias.
    store[(24'h0ffff0) >> 1] = 16'hcdcd;
    store[(24'h0ffff2) >> 1] = 16'h0000;

    core_rst = 0;
    cycles = 0;
    while (cycles < 20000) begin
        tick();
        cycles = cycles + 1;
        if (!saw_fetch && sdr_p0_req) begin
            saw_fetch = 1;
            first_pc = debug_pc;
        end
        if (saw_fetch && (cycles > 100))
            break;
    end

    if (!saw_fetch)
        $fatal(1, "core never issued a program fetch after reset release");
    if (!rom_loaded)
        $fatal(1, "rom_loaded cleared unexpectedly");

    $display("PASS tb_ssv_loader_core_boot rom_loaded=1 max_addr=%0h first_pc=%08x cycles=%0d",
             download_max_addr, first_pc, cycles);
    $finish;
end

endmodule
