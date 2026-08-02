// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  $480000 data-port SR/DR handshake, against
//  rtl/cpu/upd96050/upd96050_st010.sv.
//
//  Reference: MAME necdsp_device::status_r / data_r / data_w,
//  src/devices/cpu/upd7725/upd7725.cpp:572-631, plus the SR bit layout at
//  upd7725.h:90-108 (RQM 15, USF1 14, USF0 13, DRS 12, DMA 11, DRC 10,
//  SOC 9, SIC 8, EI 7, P1 1, P0 0; bits 6:2 have no storage).
//
//  16-bit mode (DRC = 0):
//      read  : DRS 0 -> return DR[7:0]  and set DRS
//              DRS 1 -> return DR[15:8] and clear RQM and DRS
//      write : DRS 0 -> DR[7:0]  = data, set DRS
//              DRS 1 -> DR[15:8] = data, clear RQM and DRS
//  8-bit mode (DRC = 1):
//      read  : return DR[7:0], clear RQM      write : DR[7:0] = data, clear RQM
//
//  REFUTATION CONDITIONS:
//   R1  If the low/high byte order were swapped, D2 reports DR = 0x3412.
//   R2  If DRS did not toggle, D3's second read returns 0x65 again instead of
//       0x87 and RQM is never cleared, so D6's spin loop never exits.
//   R3  If DRC were ignored, D4's repeated read would alternate bytes instead
//       of returning 0x65 twice.
//   R4  If RQM were writable from the program (it is inside MAME's 0x907c
//       preserve mask), D5's LD SR would clear it and the branch flips.
//   R5  If $480000 were decoded on the wrong lane or aliased, D7 corrupts DR.
//============================================================================

`timescale 1ns/1ps

module tb_upd96050_dataport;

`include "upd96050_asm.svh"

reg clk = 0;
always #10 clk = ~clk;
reg rst = 1;
reg ce  = 0;

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
reg   [1:0] cpu_be   = 2'b01;
reg         cpu_we   = 0;
reg         cpu_re   = 0;
reg  [15:0] cpu_wdata = 0;
wire [15:0] cpu_rdata;
wire        cpu_sel;

wire        dbg_retire;
wire [13:0] dbg_pc;
wire [15:0] dbg_a, dbg_b, dbg_dp, dbg_dr, dbg_sr, dbg_k, dbg_l, dbg_m, dbg_n;

upd96050_st010 dut (
    .clk(clk), .rst(rst), .soft_rst(1'b0), .ce_dsp(ce),
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

// One V60 byte write to $480000 (even lane, D7:0).
task dp_wr(input [7:0] d);
begin
    @(negedge clk);
    cpu_addr  = 23'h240000;
    cpu_be    = 2'b01;
    cpu_wdata = {8'h00, d};
    cpu_we    = 1'b1;
    @(negedge clk);
    cpu_we    = 1'b0;
end
endtask

// One V60 byte read of $480000: sample the combinational data, then let the
// single-clk strobe apply data_r's SR side effects.
task dp_rd(output [7:0] d);
begin
    @(negedge clk);
    cpu_addr = 23'h240000;
    cpu_be   = 2'b01;
    #1;
    d = cpu_rdata[7:0];
    cpu_re = 1'b1;
    @(negedge clk);
    cpu_re = 1'b0;
end
endtask

reg [7:0] rb;

//==========================================================================
initial begin
    clr;
    reset_dsp;

    //----------------------------------------------------------------------
    // D1 -- after /RESET, SR is zero: 16-bit mode, DRS clear, RQM clear.
    //----------------------------------------------------------------------
    chk(dbg_sr, 16'h0000, "D1 SR clear after reset");

    //----------------------------------------------------------------------
    // D2 -- host write pair in 16-bit mode: first byte is the LOW half.
    //----------------------------------------------------------------------
    dp_wr(8'h34);
    chk(dbg_sr, 16'h1000, "D2 first write sets DRS");
    chk(dbg_dr & 16'h00ff, 16'h0034, "D2 first write is low byte");
    dp_wr(8'h12);
    chk(dbg_dr, 16'h1234, "D2 DR after write pair");
    chk(dbg_sr, 16'h0000, "D2 DRS cleared after pair");

    //----------------------------------------------------------------------
    // D3 -- DSP loads DR (which sets RQM), host reads the pair back.
    //----------------------------------------------------------------------
    clr;
    prom[0] = LDW(16'h8765, 4'd6);
    reset_dsp;
    step;
    chk(dbg_dr, 16'h8765, "D3 LD DR");
    chk(dbg_sr, 16'h8000, "D3 LD DR sets RQM");
    dp_rd(rb);
    chk({8'h00, rb}, 16'h0065, "D3 read 1 = DR low");
    chk(dbg_sr, 16'h9000, "D3 read 1 sets DRS, RQM still set");
    dp_rd(rb);
    chk({8'h00, rb}, 16'h0087, "D3 read 2 = DR high");
    chk(dbg_sr, 16'h0000, "D3 read 2 clears RQM and DRS");

    //----------------------------------------------------------------------
    // D4 -- 8-bit mode (DRC = 1) is byte-at-a-time and ignores DRS.
    //----------------------------------------------------------------------
    clr;
    prom[0] = LDW(16'h0400, 4'd7);      // SR: DRC = 1
    prom[1] = LDW(16'h8765, 4'd6);      // DR, sets RQM
    reset_dsp;
    step;
    chk(dbg_sr, 16'h0400, "D4 DRC set");
    step;
    chk(dbg_sr, 16'h8400, "D4 LD DR sets RQM in 8-bit mode");
    dp_rd(rb);
    chk({8'h00, rb}, 16'h0065, "D4 8-bit read");
    chk(dbg_sr, 16'h0400, "D4 8-bit read clears RQM only");
    dp_rd(rb);
    chk({8'h00, rb}, 16'h0065, "D4 8-bit read repeats low byte");
    chk(dbg_sr, 16'h0400, "D4 DRS untouched in 8-bit mode");
    dp_wr(8'h99);
    chk(dbg_dr, 16'h8799, "D4 8-bit write hits low byte only");

    //----------------------------------------------------------------------
    // D5 -- RQM is not writable by the program: MAME's LD SR preserves it
    // through the 0x907c mask, so an LD SR of 0 leaves RQM set.
    //----------------------------------------------------------------------
    clr;
    prom[0] = LDW(16'h1111, 4'd6);      // sets RQM
    prom[1] = LDW(16'h0000, 4'd7);      // LD SR 0 -- must NOT clear RQM
    reset_dsp;
    step;
    chk(dbg_sr, 16'h8000, "D5 RQM set");
    step;
    chk(dbg_sr, 16'h8000, "D5 LD SR 0 preserves RQM");

    //----------------------------------------------------------------------
    // D6 -- full handshake: the DSP raises RQM with src 8, spins on JRQM, and
    // only escapes once the host has written BOTH bytes. This is the property
    // the real ST010 protocol depends on.
    //----------------------------------------------------------------------
    clr;
    prom[0]     = MOV(4'd8, 4'd0);              // src 8: IDB = DR, RQM = 1
    prom[1]     = JPW(9'h0be, 11'h001, 2'b00);  // JRQM -> 1  (spin)
    prom[2]     = MOV(4'd9, 4'd1);              // A = DR
    reset_dsp;
    step;
    chk(dbg_sr, 16'h8000, "D6 src8 raises RQM");
    step;
    chk({12'h0, dbg_pc}, 16'h0001, "D6 spin iteration 1");
    step;
    chk({12'h0, dbg_pc}, 16'h0001, "D6 spin iteration 2");
    step;
    chk({12'h0, dbg_pc}, 16'h0001, "D6 spin iteration 3");
    dp_wr(8'hcd);
    chk(dbg_sr, 16'h9000, "D6 half-written: RQM still set");
    step;
    chk({12'h0, dbg_pc}, 16'h0001, "D6 still spinning on half a word");
    dp_wr(8'hab);
    chk(dbg_sr, 16'h0000, "D6 pair complete clears RQM");
    step;
    chk({12'h0, dbg_pc}, 16'h0002, "D6 spin exits");
    step;
    chk(dbg_a, 16'habcd, "D6 DSP reads the host word");

    //----------------------------------------------------------------------
    // D7 -- decode isolation. Neither a neighbouring address nor the unmapped
    // odd lane may touch DR.
    //----------------------------------------------------------------------
    @(negedge clk);
    cpu_addr = 23'h240001; cpu_be = 2'b01; cpu_wdata = 16'h0055; cpu_we = 1'b1;
    @(negedge clk); cpu_we = 1'b0;
    chk(dbg_dr, 16'habcd, "D7 $480002 does not reach DR");
    @(negedge clk);
    cpu_addr = 23'h240000; cpu_be = 2'b10; cpu_wdata = 16'h6600; cpu_we = 1'b1;
    @(negedge clk); cpu_we = 1'b0;
    chk(dbg_dr, 16'habcd, "D7 odd lane does not reach DR");
    @(negedge clk);
    cpu_addr = 23'h240000; cpu_be = 2'b01;
    @(negedge clk);
    chk({15'd0, cpu_sel}, 16'h0001, "D7 sel asserted at $480000");

    //----------------------------------------------------------------------
    // D8 -- data_r/data_w are not idempotent, so a strobe held for a whole
    // multi-clk bus cycle must still count as ONE access. DR starts at
    // 0xabcd with DRS clear.
    //----------------------------------------------------------------------
    chk(dbg_dr, 16'habcd, "D8 start state");
    chk(dbg_sr, 16'h0000, "D8 DRS clear to start");
    @(negedge clk);
    cpu_addr = 23'h240000; cpu_be = 2'b01; cpu_wdata = 16'h0077; cpu_we = 1'b1;
    repeat (5) @(negedge clk);
    cpu_we = 1'b0;
    @(negedge clk);
    chk(dbg_dr, 16'hab77, "D8 held write lands once, low byte only");
    chk(dbg_sr, 16'h1000, "D8 held write toggles DRS once");
    @(negedge clk);
    cpu_re = 1'b1;
    repeat (5) @(negedge clk);
    cpu_re = 1'b0;
    @(negedge clk);
    chk(dbg_sr, 16'h0000, "D8 held read consumes one byte only");

    $display("------------------------------------------------------------");
    $display("UPD96050 DATAPORT: %0d passed, %0d failed", pass, fail);
    if (fail == 0) $display("UPD96050 DATAPORT PASS");
    else           $display("UPD96050 DATAPORT FAIL");
    $finish;
end

initial begin
    #20000000;
    $display("UPD96050 DATAPORT FAIL (timeout)");
    $finish;
end

endmodule
