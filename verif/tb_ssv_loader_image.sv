// SPDX-License-Identifier: GPL-3.0-or-later
//
// Load the REAL Dyna Gear program stream through ssv_rom_loader, into the REAL
// sdram controller, into the part model -- then read it back through p0 and
// compare against the ROM file.
//
// WHY THIS EXISTS. Nothing covered this path end to end:
//
//   * tb_ssv_rom_loader checks the loader's OUTPUT addresses/data against an
//     idealised handshake that acks instantly. It never reaches memory.
//   * tb_ssv_frame_crc +REAL_SDRAM PRELOADS chip.mem[] directly
//     (verif/tb_ssv_frame_crc.sv "REAL_SDRAM preloading chip image"), so the
//     write path is bypassed entirely.
//   * tb_ssv_loader_core_boot proves only max_addr=3, i.e. a four-byte load.
//
// So the loader-to-controller WRITE handshake and the resulting memory image
// have never been simulated, while hardware reports exactly the symptom that
// gap would produce: the on-board probe reads 0x007A at byte 0 where the ROM
// holds 0x207A, and it returns byte-identical wrong data whether the read
// capture tap is cl_pipe[2] or cl_pipe[3] -- which means the READ timing is not
// the variable and the bytes are most likely wrong before they are ever read.
//
// The controller's request contract is the specific thing under test
// (rtl/mem/sdram.sv header): "one transaction per req RISING EDGE; the address
// (and write data/be) is sampled on that edge. A request held high is serviced
// exactly ONCE." The loader is a clk_sys requester driving a clk_ram
// controller, which is where a contract like that goes wrong.

`timescale 1ns/1ps

module tb_ssv_loader_image;

import ssv_pkg::*;

localparam int AW = 26;

logic clk_ram = 1'b0;
always #2.5 clk_ram = ~clk_ram;          // 200 MHz-ish sim clock, ratio is what matters

// clk_sys is exactly clk_ram/2 and synchronous, as on hardware.
logic clk_sys = 1'b0;
always @(posedge clk_ram) clk_sys <= ~clk_sys;

logic rst = 1'b1;
logic sdram_ready;

// ---------------------------------------------------------------------------
// ROM image
// ---------------------------------------------------------------------------
localparam int PROG_BYTES = 1048576;
logic [7:0] prog [0:PROG_BYTES-1];
integer fd, n;

// ---------------------------------------------------------------------------
// ioctl stream into the loader
// ---------------------------------------------------------------------------
logic        ioctl_download = 1'b0;
logic  [7:0] ioctl_index    = 8'd0;
logic        ioctl_wr       = 1'b0;
logic [26:0] ioctl_addr     = 27'd0;
logic  [7:0] ioctl_dout     = 8'd0;
wire         ioctl_wait;

wire             ld_wr_req;
wire [SDR_AW:1]  ld_wr_addr;
wire [15:0]      ld_wr_din;
wire  [1:0]      ld_wr_be;
wire             ld_wr_ack;
ssv_cfg_t        cfg;
wire             cfg_valid;
wire             rom_loaded;
wire [26:0]      download_max_addr;

ssv_rom_loader loader (
    .clk(clk_sys), .rst(rst), .mem_ready(sdram_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ld_wr_req), .sdr_wr_addr(ld_wr_addr), .sdr_wr_din(ld_wr_din),
    .sdr_wr_be(ld_wr_be), .sdr_wr_ack(ld_wr_ack),
    .cfg(cfg), .cfg_valid(cfg_valid),
    .st010_drom_we(), .st010_drom_wa(), .st010_drom_wd(),
    .rom_loaded(rom_loaded), .download_max_addr(download_max_addr)
);

// Read port, driven by this bench after the load.
logic            p0_req = 1'b0;
logic [SDR_AW:1] p0_addr = '0;
wire  [15:0]     p0_dout;
wire             p0_ack;

ssv_sdram_harness #(
    .BANK_BITS(2), .ROW_BITS(13), .COL_BITS(11), .TRFC_CYC(11)
) u_sdram (
    .clk_ram(clk_ram), .init(rst), .ready(sdram_ready),
    .wr_req(ld_wr_req), .wr_addr(ld_wr_addr), .wr_din(ld_wr_din),
    .wr_be(ld_wr_be), .wr_ack(ld_wr_ack),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p2_req(1'b0), .p2_addr('0), .p2_dout(), .p2_ack(),
    .p4_req(1'b0), .p4_addr('0), .p4_dout(), .p4_ack(),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

// ---------------------------------------------------------------------------
// Stream helpers. ioctl_wait is BACKPRESSURE and must be honoured -- ignoring
// it is itself a way to lose bytes, so the bench models the HPS faithfully.
// ---------------------------------------------------------------------------
task automatic sys_tick;
    @(posedge clk_sys);
    #1;
endtask

task automatic send_byte(input [26:0] a, input [7:0] d);
    begin
        while (ioctl_wait) sys_tick();
        ioctl_addr = a;
        ioctl_dout = d;
        ioctl_wr   = 1'b1;
        sys_tick();
        ioctl_wr   = 1'b0;
        sys_tick();
    end
endtask

// 16-byte config block, Dyna Gear, version 1 (see tools/ssv_cfg_block.py).
task automatic send_cfg;
    logic [7:0] b [0:15];
    integer i, sum;
    begin
        b[0]=8'h53; b[1]=8'd1; b[2]=8'd1;  b[3]=8'd16; b[4]=8'd17; b[5]=8'd0;
        b[6]=8'd3;  b[7]=8'd0; b[8]=8'd4;  b[9]=8'd4;  b[10]=8'd1; b[11]=8'd0;
        b[12]=8'd0; b[13]=8'd0; b[14]=8'd0;
        sum = 0;
        for (i = 0; i < 15; i = i + 1) sum = sum + b[i];
        b[15] = (-sum) & 8'hFF;
        ioctl_index = 8'd1;
        for (i = 0; i < 16; i = i + 1) send_byte(i[26:0], b[i]);
        ioctl_index = 8'd0;
    end
endtask

task automatic read_word(input [SDR_AW:1] a, output [15:0] q);
    begin
        @(posedge clk_ram); #1;
        p0_addr = a;
        p0_req  = 1'b1;
        @(posedge clk_ram); #1;
        p0_req  = 1'b0;
        while (!p0_ack) @(posedge clk_ram);
        q = p0_dout;
        @(posedge clk_ram); #1;
    end
endtask

integer i;
integer errors = 0;
integer checked = 0;
logic [15:0] got, exp;
integer bytes_to_send;

initial begin
    fd = $fopen("sim_output/rom/maincpu.bin", "rb");
    if (fd == 0) $fatal(1, "cannot open sim_output/rom/maincpu.bin");
    n = $fread(prog, fd);
    $fclose(fd);
    if (n != PROG_BYTES) $fatal(1, "short program ROM read %0d", n);
    $display("program ROM loaded, %0d bytes", n);

    repeat (20) @(posedge clk_ram);
    rst = 0;
    while (!sdram_ready) @(posedge clk_ram);
    $display("sdram ready");

    ioctl_download = 1'b1;
    send_cfg();
    if (!cfg_valid) $fatal(1, "config block rejected");
    $display("cfg accepted: prog_mb=%0d gfx_mb=%0d quarters=%0d",
             cfg.prog_mb, cfg.gfx_mb, cfg.gfx_quarters);

    // Send enough of the program to cover BOTH probe addresses. The whole 1 MB
    // is unnecessary and slow; 0x20000 bytes covers 0x00000 and 0x1F3D0.
    bytes_to_send = 32'h20000;
    for (i = 0; i < bytes_to_send; i = i + 1)
        send_byte(i[26:0], prog[i]);

    ioctl_download = 1'b0;
    // rom_loaded needs the final write to drain.
    repeat (200) sys_tick();
    if (!rom_loaded) $fatal(1, "rom_loaded never asserted");
    $display("rom_loaded, download_max_addr=%h", download_max_addr);

    // The two words the hardware probe reads.
    read_word((27'h00000) >> 1, got);
    exp = {prog[1], prog[0]};
    checked++;
    if (got !== exp) begin
        errors++;
        $display("MISMATCH @0x00000 expected %04h got %04h", exp, got);
    end else $display("OK @0x00000 = %04h", got);

    read_word((27'h1F3D0) >> 1, got);
    exp = {prog[27'h1F3D1], prog[27'h1F3D0]};
    checked++;
    if (got !== exp) begin
        errors++;
        $display("MISMATCH @0x1F3D0 expected %04h got %04h", exp, got);
    end else $display("OK @0x1F3D0 = %04h", got);

    // Sweep a spread of words so a systematic fault shows its shape rather
    // than being inferred from two samples.
    for (i = 0; i < 4096; i = i + 1) begin
        automatic integer byte_off = i * 8;
        if (byte_off + 1 < bytes_to_send) begin
            read_word(byte_off[SDR_AW:1] >> 0, got);
            exp = {prog[byte_off+1], prog[byte_off]};
            checked++;
            if (got !== exp) begin
                errors++;
                if (errors <= 12)
                    $display("MISMATCH @%06h expected %04h got %04h",
                             byte_off, exp, got);
            end
        end
    end

    $display("checked=%0d errors=%0d", checked, errors);
    if (errors) $display("FAIL tb_ssv_loader_image");
    else        $display("PASS tb_ssv_loader_image");
    $finish;
end

initial begin
    #200_000_000;
    $display("FAIL tb_ssv_loader_image timeout");
    $finish;
end

endmodule
