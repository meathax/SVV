// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  $482000-$482fff data-RAM window translation, against
//  rtl/cpu/upd96050/upd96050_st010.sv.
//
//  WHAT IS BEING PINNED DOWN
//  -------------------------
//  ssv.cpp:350-362 works in MAME *handler offsets*, and for an 8-bit handler
//  installed with umask16 on a 16-bit space that offset advances once per bus
//  WORD (src/emu/emumem_mud.cpp: shift = Width - access_width -
//  active_count_log + access_width + AddrShift = 1). So with A the V60 byte
//  address:
//
//      offset       = (A - 0x482000) >> 1   = A[11:1]
//      DSP word     = offset >> 1           = A[11:2]
//      high byte    = offset[0]             = A[1]
//      mapped lane  = D[7:0] = the EVEN byte (V60 is little-endian)
//
//  REFUTATION CONDITIONS -- each of these makes a specific test fail:
//   R1  If the word index were A[11:1] ("byte offset / 2" read naively off the
//       CPU address), then writing 0xaa at $482000 and 0xbb at $482002 would
//       land in words 0 and 1. The DSP read of word 0 in W3 would be 0x00aa.
//   R2  If the high/low select were A[0] instead of A[1], both of those writes
//       would hit word 0's low byte and W3 would read 0x00bb.
//   R3  If the byte-lane check were missing or used D[15:8], the odd-address
//       write in W5 would corrupt word 0 and W6 would fail.
//   R4  If the window were assumed to reach 2048 DSP words, W7's top-of-range
//       write would target word 0x7ff instead of 0x3ff and W8 would find
//       word 0x3ff unchanged.
//   R5  If dataram_w ignored the byte mask and stored the duplicated byte
//       (0xdddd rather than one half), W3 and W4 would both read 0xaaaa/0xbbbb
//       style doubled values.
//============================================================================

`timescale 1ns/1ps

module tb_upd96050_window;

`include "upd96050_asm.svh"

reg clk = 0;
always #10 clk = ~clk;
reg rst = 1;
reg soft_rst = 0;
reg ce  = 0;

//--------------------------------------------------------------------------
reg [23:0] prom [0:16383];
wire [13:0] prg_addr;
wire        prg_req;
reg  [23:0] prg_data;
reg         prg_valid;
always @(posedge clk) begin
    prg_valid <= prg_req;
    prg_data  <= prom[prg_addr];
end

reg  [23:1] cpu_addr = 23'h000000;
reg   [1:0] cpu_be   = 2'b00;
reg         cpu_we   = 0;
reg         cpu_re   = 0;
reg  [15:0] cpu_wdata = 0;
wire [15:0] cpu_rdata;
wire        cpu_sel;

wire        dbg_retire;
wire [13:0] dbg_pc;
wire [15:0] dbg_a, dbg_b, dbg_dp, dbg_dr, dbg_sr, dbg_k, dbg_l, dbg_m, dbg_n;

upd96050_st010 dut (
    .clk(clk), .rst(rst), .soft_rst(soft_rst), .ce_dsp(ce),
    .cpu_addr(cpu_addr), .cpu_be(cpu_be), .cpu_we(cpu_we), .cpu_re(cpu_re),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_sel(cpu_sel),
    .prg_addr(prg_addr), .prg_req(prg_req),
    .prg_data(prg_data), .prg_valid(prg_valid),
    .drom_we(1'b0), .drom_wa(11'd0), .drom_wd(16'd0),
    .int_req(1'b0), .p0(), .p1(),
    .dbg_retire(dbg_retire), .dbg_pc(dbg_pc),
    .dbg_a(dbg_a), .dbg_b(dbg_b), .dbg_dp(dbg_dp), .dbg_dr(dbg_dr),
    .dbg_sr(dbg_sr), .dbg_k(dbg_k), .dbg_l(dbg_l), .dbg_m(dbg_m), .dbg_n(dbg_n)
);

//--------------------------------------------------------------------------
integer pass = 0, fail = 0;
task chk(input [15:0] got, input [15:0] exp, input string nm);
begin
    if (got === exp) pass = pass + 1;
    else begin
        fail = fail + 1;
        $display("  FAIL %-40s got %04x expected %04x", nm, got, exp);
    end
end
endtask

task reset_dsp_soft;
begin
    ce = 0; soft_rst = 1;
    repeat (2) @(posedge clk);
    @(negedge clk); soft_rst = 0;
    @(negedge clk);
end
endtask

integer ii;
task clr;
begin
    for (ii = 0; ii < 16384; ii = ii + 1) prom[ii] = 24'h000000;
end
endtask

task reset_dsp;
begin
    ce = 0; rst = 1;
    // Complete the cold-reset 2048-word data-RAM clear before host traffic.
    repeat (2060) @(posedge clk);
    @(negedge clk); rst = 0;
    @(negedge clk);
end
endtask

task step;
begin
    @(negedge clk); ce = 1'b1;
    @(negedge clk); ce = 1'b0;
    while (dbg_retire !== 1'b1) @(negedge clk);
end
endtask

// One V60 byte write, exactly as the bus presents it: address on [23:1], the
// byte in its own lane, and the matching byte enable.
task cpu_wr(input [23:0] ba, input [7:0] d);
begin
    @(negedge clk);
    cpu_addr  = ba[23:1];
    cpu_be    = ba[0] ? 2'b10 : 2'b01;
    cpu_wdata = ba[0] ? {d, 8'h00} : {8'h00, d};
    cpu_we    = 1'b1;
    @(negedge clk);
    cpu_we    = 1'b0;
end
endtask

// One V60 byte read on the mapped (even) lane. The window costs one wait
// state, so the address is held for a second bus clk before latching.
task cpu_rd(input [23:0] ba, output [7:0] d);
begin
    @(negedge clk);
    cpu_addr = ba[23:1];
    cpu_be   = 2'b01;
    @(negedge clk);
    d = cpu_rdata[7:0];
end
endtask

// Read a DSP data-RAM word from the DSP's own side, which is the only way to
// prove the word index the CPU write actually landed on.
task dsp_word(input [10:0] w, output [15:0] v);
begin
    clr;
    prom[0] = LDW({5'd0, w}, 4'd4);     // LD DP, w
    prom[1] = MOV(4'd15, 4'd1);         // A = dataRAM[DP]
    // Rewind DSP execution without erasing the RAM image being inspected.
    // This is MAME's device_reset retention contract, not device_start.
    reset_dsp_soft;
    step; step;
    v = dbg_a;
end
endtask

reg [15:0] w0, w1, wt, wtop, wover;
reg  [7:0] rb;
integer    k;

//==========================================================================
initial begin
    clr;
    reset_dsp;

    //----------------------------------------------------------------------
    // W1/W2 -- two consecutive CPU bytes must be the two halves of ONE word.
    //   $482000 -> offset 0 -> word 0, low  byte
    //   $482002 -> offset 1 -> word 0, high byte
    //----------------------------------------------------------------------
    cpu_wr(24'h482000, 8'haa);
    cpu_wr(24'h482002, 8'hbb);
    //   $482004 -> offset 2 -> word 1, low
    //   $482006 -> offset 3 -> word 1, high
    cpu_wr(24'h482004, 8'hcc);
    cpu_wr(24'h482006, 8'hdd);

    //----------------------------------------------------------------------
    // W3/W4 -- read them back from the DSP side.
    //----------------------------------------------------------------------
    dsp_word(11'h000, w0);
    chk(w0, 16'hbbaa, "W3 word 0 = {A[1]=1 byte, A[1]=0 byte}");
    dsp_word(11'h001, w1);
    chk(w1, 16'hddcc, "W4 word 1");

    //----------------------------------------------------------------------
    // W5/W6 -- an access on the unmapped odd lane must do nothing.
    //----------------------------------------------------------------------
    cpu_wr(24'h482001, 8'h5a);
    cpu_wr(24'h482003, 8'h5a);
    dsp_word(11'h000, w0);
    chk(w0, 16'hbbaa, "W6 odd lane write is not mapped");

    //----------------------------------------------------------------------
    // W7/W8 -- top of the reachable range. $482ffc/$482ffe are offsets
    // 0x7fe/0x7ff, i.e. the two halves of word 0x3ff -- the LAST DSP word the
    // CPU can touch through this window.
    //----------------------------------------------------------------------
    cpu_wr(24'h482ffc, 8'h12);
    cpu_wr(24'h482ffe, 8'h34);
    dsp_word(11'h3ff, wtop);
    chk(wtop, 16'h3412, "W8 top of window is word 0x3ff");

    //----------------------------------------------------------------------
    // W9 -- the upper half of the 2048-word data RAM is DSP-private: no CPU
    // address in the window reaches it. Fill the entire window with a pattern
    // and confirm words 0x400 and 0x7ff are still untouched.
    //----------------------------------------------------------------------
    for (k = 0; k < 4096; k = k + 2)             // every mapped (even) byte
        cpu_wr(24'h482000 + k, 8'he0 | ((k >> 1) & 8'h0f));
    dsp_word(11'h400, wover);
    chk(wover, 16'h0000, "W9 word 0x400 unreachable from CPU");
    dsp_word(11'h7ff, wover);
    chk(wover, 16'h0000, "W9 word 0x7ff unreachable from CPU");

    //----------------------------------------------------------------------
    // W10 -- the pattern just written is self-consistent on the DSP side.
    // Byte written at $482000 + 2*offset is 0xe0 | (offset & 0xf), so DSP word
    // n holds { 0xe0|((2n+1)&0xf), 0xe0|((2n)&0xf) }.
    //----------------------------------------------------------------------
    dsp_word(11'h000, wt);
    chk(wt, 16'he1e0, "W10 word 0x000 pattern");
    dsp_word(11'h001, wt);
    chk(wt, 16'he3e2, "W10 word 0x001 pattern");
    dsp_word(11'h1ff, wt);
    chk(wt, 16'hefee, "W10 word 0x1ff pattern");   // 2n=0x3fe -> 0xe, 0x3ff -> 0xf
    dsp_word(11'h3ff, wt);
    chk(wt, 16'hefee, "W10 word 0x3ff pattern");   // 2n=0x7fe -> 0xe, 0x7ff -> 0xf

    //----------------------------------------------------------------------
    // W11 -- CPU read-back path: same translation in the read direction.
    //----------------------------------------------------------------------
    cpu_wr(24'h482040, 8'h71);      // offset 0x20 -> word 0x10 low
    cpu_wr(24'h482042, 8'h72);      // offset 0x21 -> word 0x10 high
    dsp_word(11'h010, wt);
    chk(wt, 16'h7271, "W11 word 0x010 via $482040/$482042");
    cpu_rd(24'h482040, rb);
    chk({8'h00, rb}, 16'h0071, "W11 read $482040 = low byte");
    cpu_rd(24'h482042, rb);
    chk({8'h00, rb}, 16'h0072, "W11 read $482042 = high byte");

    //----------------------------------------------------------------------
    // W12 -- the DSP writes, the CPU reads. Confirms the same mapping is used
    // in both directions and that the DSP reaches beyond word 0x3ff.
    //----------------------------------------------------------------------
    clr;
    prom[0] = LDW(16'h0100, 4'd4);      // DP = 0x100
    prom[1] = LDW(16'h9c3d, 4'd15);     // dataRAM[0x100] = 0x9c3d
    prom[2] = LDW(16'h0500, 4'd4);      // DP = 0x500  (above the window)
    prom[3] = LDW(16'h1e2f, 4'd15);
    reset_dsp;
    step; step; step; step;
    // word 0x100 -> offsets 0x200/0x201 -> byte addresses $482400/$482402
    cpu_rd(24'h482400, rb);
    chk({8'h00, rb}, 16'h003d, "W12 CPU sees DSP write, low byte");
    cpu_rd(24'h482402, rb);
    chk({8'h00, rb}, 16'h009c, "W12 CPU sees DSP write, high byte");
    dsp_word(11'h500, wt);
    chk(wt, 16'h1e2f, "W12 DSP reaches word 0x500");

    //----------------------------------------------------------------------
    // W13 -- $480000 must NOT alias into the window, and cpu_sel must only
    // claim the two decoded regions.
    //----------------------------------------------------------------------
    @(negedge clk); cpu_addr = 23'h240000; cpu_be = 2'b01;
    @(negedge clk);
    chk({15'd0, cpu_sel}, 16'h0001, "W13 sel at $480000");
    @(negedge clk); cpu_addr = 23'h241000;
    @(negedge clk);
    chk({15'd0, cpu_sel}, 16'h0001, "W13 sel at $482000");
    @(negedge clk); cpu_addr = 23'h2417ff;
    @(negedge clk);
    chk({15'd0, cpu_sel}, 16'h0001, "W13 sel at $482ffe");
    @(negedge clk); cpu_addr = 23'h241800;   // $483000
    @(negedge clk);
    chk({15'd0, cpu_sel}, 16'h0000, "W13 no sel at $483000");
    @(negedge clk); cpu_addr = 23'h240800;   // $481000
    @(negedge clk);
    chk({15'd0, cpu_sel}, 16'h0000, "W13 no sel at $481000");

    $display("------------------------------------------------------------");
    $display("UPD96050 WINDOW: %0d passed, %0d failed", pass, fail);
    if (fail == 0) $display("UPD96050 WINDOW PASS");
    else           $display("UPD96050 WINDOW FAIL");
    $finish;
end

initial begin
    #50000000;
    $display("UPD96050 WINDOW FAIL (timeout)");
    $finish;
end

endmodule
