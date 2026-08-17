// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
//  Directed ISA suite for rtl/cpu/upd96050/upd96050.sv.
//
//  Every expected value below is DERIVED BY HAND from MAME's
//  src/devices/cpu/upd7725/upd7725.cpp, with the arithmetic shown in the
//  comment so a reviewer can re-check it without running anything. Where the
//  derivation is interesting (sticky OV1, the DP 0xf0 mask, signed multiply
//  rounding) the intermediate values are written out.
//
//  REFUTATION CONDITIONS -- what a wrong core would do:
//   * ALU/flags: the ADD-overflow and SUB-borrow cases (T8/T9) both depend on
//     OV1 being sticky and on S1 being frozen while OV1 is set. A core that
//     recomputes S1 unconditionally reports flaga=0x3A instead of 0x1A in T9.
//   * Multiply: T4d and T5 use negative operands. A core using an unsigned
//     multiply reports m=0x8000/n=0 for T4b instead of 0xFFFF/0xFFFC.
//   * DP modify: T17a fails on any core that preserves DP bits 15:8 through
//     DPINC (it would report 0x0120 rather than 0x0020).
//   * dst-4 / dst-5 suppression: T17f and T18b fail if the guards are absent.
//   * jps bit 13: T16k fails if the branch target does not inherit bit 13
//     from the *incremented* PC (it would jump to 0x0010 and hang on zeros).
//   * Interrupt: T19 fails if PC is advanced across the two synthesised
//     opcodes (the return address would be 3, not 1).
//============================================================================

`timescale 1ns/1ps

module tb_upd96050_isa;

//--------------------------------------------------------------------------
reg clk = 0;
always #10 clk = ~clk;
reg rst = 1;
reg ce  = 0;

//--------------------------------------------------------------------------
// Program memory model: 16384 x 24, holding {b0,b1,b2} of each 32-bit
// big-endian region word, i.e. MAME's read_dword(pc) >> 8.
//
// +PRGLAT=<n> adds n extra stall clks before prg_valid, so the same 116
// checks also cover the SDRAM-backed case where the fetch port stalls. The
// default of 0 gives the one-clk latency an on-chip ROM would have.
//--------------------------------------------------------------------------
reg [23:0] prom [0:16383];
wire [13:0] prg_addr;
wire        prg_req;
reg  [23:0] prg_data;
reg         prg_valid;
integer     prg_lat;
integer     lat_cnt = 0;
initial if (!$value$plusargs("PRGLAT=%d", prg_lat)) prg_lat = 0;
always @(posedge clk) begin
    prg_data <= prom[prg_addr];
    if (!prg_req) begin
        lat_cnt   <= 0;
        prg_valid <= 1'b0;
    end
    else if (lat_cnt < prg_lat) begin
        lat_cnt   <= lat_cnt + 1;
        prg_valid <= 1'b0;
    end
    else prg_valid <= 1'b1;
end

//--------------------------------------------------------------------------
// Data ROM model: ssv.cpp:346 populates words 0x000-0x7ff of a 12-bit space.
//--------------------------------------------------------------------------
reg [15:0] drom [0:2047];
wire [11:0] drom_addr;
reg  [15:0] drom_data;
always @(posedge clk)
    drom_data <= drom_addr[11] ? 16'h0000 : drom[drom_addr[10:0]];

//--------------------------------------------------------------------------
reg  [10:0] host_ram_addr = 0;
reg         host_ram_high = 0;
reg         host_ram_wr   = 0;
reg   [7:0] host_ram_din  = 0;
wire  [7:0] host_ram_dout;
reg         host_dp_rd = 0, host_dp_wr = 0;
reg   [7:0] host_dp_din = 0;
wire  [7:0] host_dp_dout, host_sr;
reg         int_req = 0;

wire        dbg_retire;
wire [13:0] dbg_pc;
wire [15:0] dbg_a, dbg_b, dbg_k, dbg_l, dbg_m, dbg_n;
wire [15:0] dbg_dp, dbg_rp, dbg_tr, dbg_trb, dbg_dr, dbg_sr, dbg_so, dbg_idb;
wire  [5:0] dbg_flaga, dbg_flagb;
wire  [3:0] dbg_sp;
wire        p0, p1;

upd96050 dut (
    .clk(clk), .ce(ce), .rst(rst), .soft_rst(1'b0),
    .prg_addr(prg_addr), .prg_req(prg_req),
    .prg_data(prg_data), .prg_valid(prg_valid),
    .drom_addr(drom_addr), .drom_data(drom_data),
    .host_dp_rd(host_dp_rd), .host_dp_wr(host_dp_wr),
    .host_dp_din(host_dp_din), .host_dp_dout(host_dp_dout), .host_sr(host_sr),
    .host_ram_addr(host_ram_addr), .host_ram_high(host_ram_high),
    .host_ram_wr(host_ram_wr), .host_ram_din(host_ram_din),
    .host_ram_dout(host_ram_dout),
    .int_req(int_req), .p0(p0), .p1(p1),
    .dbg_retire(dbg_retire), .dbg_pc(dbg_pc),
    .dbg_a(dbg_a), .dbg_b(dbg_b), .dbg_flaga(dbg_flaga), .dbg_flagb(dbg_flagb),
    .dbg_k(dbg_k), .dbg_l(dbg_l), .dbg_m(dbg_m), .dbg_n(dbg_n),
    .dbg_dp(dbg_dp), .dbg_rp(dbg_rp), .dbg_tr(dbg_tr), .dbg_trb(dbg_trb),
    .dbg_dr(dbg_dr), .dbg_sr(dbg_sr), .dbg_so(dbg_so), .dbg_idb(dbg_idb),
    .dbg_sp(dbg_sp)
);

`include "upd96050_asm.svh"

//==========================================================================
integer pass = 0, fail = 0;
task chk(input [15:0] got, input [15:0] exp, input string nm);
begin
    if (got === exp) begin
        pass = pass + 1;
    end
    else begin
        fail = fail + 1;
        $display("  FAIL %-28s got %04x expected %04x", nm, got, exp);
    end
end
endtask
task chkf(input [5:0] got, input [5:0] exp, input string nm);
begin
    if (got === exp) pass = pass + 1;
    else begin
        fail = fail + 1;
        $display("  FAIL %-28s flags got %02x{s1%0d s0%0d c%0d z%0d ov1%0d ov0%0d} expected %02x",
                 nm, got, got[5], got[4], got[3], got[2], got[1], got[0], exp);
    end
end
endtask

integer ii, jj;
reg [8:0] brch_t;
reg       take_t;
string    nm_t;
task clr;
begin
    for (jj = 0; jj < 16384; jj = jj + 1) prom[jj] = 24'h000000;
    for (jj = 0; jj < 2048;  jj = jj + 1) drom[jj] = 16'h0000;
end
endtask

task reset_dsp;
begin
    ce = 0; rst = 1;
    // Cold reset walks all 2048 inferred data-RAM words to MAME's clean
    // device-start value before the first instruction issue.
    repeat (2060) @(posedge clk);
    @(negedge clk); rst = 0;
    @(negedge clk);
end
endtask

// Execute exactly one instruction, returning with every register committed.
task step;
begin
    @(negedge clk); ce = 1'b1;
    @(negedge clk); ce = 1'b0;
    while (dbg_retire !== 1'b1) @(negedge clk);
end
endtask

integer rr;
task run(input integer n);
begin
    for (rr = 0; rr < n; rr = rr + 1) step;
end
endtask

// Write one data-RAM word through the host port, as two byte-enabled halves.
task ram_poke(input [10:0] w, input [15:0] v);
begin
    @(negedge clk);
    host_ram_addr = w; host_ram_high = 1'b0; host_ram_din = v[7:0];
    host_ram_wr = 1'b1;
    @(negedge clk);
    host_ram_high = 1'b1; host_ram_din = v[15:8];
    @(negedge clk);
    host_ram_wr = 1'b0; host_ram_high = 1'b0;
    @(negedge clk);
end
endtask

//==========================================================================
initial begin
    clr;
    reset_dsp;

    //======================================================================
    // T1 -- LD immediate to A, B, TR, TRB, DP, RP  (upd7725.cpp:551-567)
    //======================================================================
    clr;
    prom[0] = LDW(16'h1234, 4'd1);
    prom[1] = LDW(16'h5678, 4'd2);
    prom[2] = LDW(16'habcd, 4'd3);
    prom[3] = LDW(16'hdead, 4'd14);
    prom[4] = LDW(16'h00f0, 4'd4);
    prom[5] = LDW(16'h0007, 4'd5);
    reset_dsp; run(6);
    chk(dbg_a,   16'h1234, "T1 LD A");
    chk(dbg_b,   16'h5678, "T1 LD B");
    chk(dbg_tr,  16'habcd, "T1 LD TR");
    chk(dbg_trb, 16'hdead, "T1 LD TRB");
    chk(dbg_dp,  16'h00f0, "T1 LD DP");
    chk(dbg_rp,  16'h0007, "T1 LD RP");
    chk(dbg_idb, 16'h0007, "T1 IDB tracks id");
    chk({12'h000, dbg_pc}, 16'h0006, "T1 PC");

    //======================================================================
    // T2 -- LD DR sets RQM; LD SR honours the 0x907c preserve mask.
    // dst 6:  regs.dr = id; regs.sr.rqm = 1                (:556)
    // dst 7:  regs.sr = (regs.sr & 0x907c) | (id & ~0x907c) (:557)
    //         => RQM(15) and DRS(12) keep their old value, bits 6:2 have no
    //            storage at all in MAME's Status struct.
    // 0x0483 = DRC(10) | EI(7) | P1(1) | P0(0); RQM stays 1 -> 0x8483.
    // 0x807c then clears every writable bit; bit15 and bits 6:2 are ignored
    // -> 0x8000.
    //======================================================================
    clr;
    prom[0] = LDW(16'h9999, 4'd6);
    prom[1] = LDW(16'h0483, 4'd7);
    prom[2] = LDW(16'h807c, 4'd7);
    reset_dsp; run(1);
    chk(dbg_dr, 16'h9999, "T2 LD DR");
    chk(dbg_sr, 16'h8000, "T2 DR sets RQM");
    run(1);
    chk(dbg_sr, 16'h8483, "T2 LD SR");
    chk({15'd0, p0}, 16'h0001, "T2 P0 out");
    chk({15'd0, p1}, 16'h0001, "T2 P1 out");
    chk({8'h00, host_sr}, 16'h0084, "T2 status_r = SR[15:8]");
    run(1);
    chk(dbg_sr, 16'h8000, "T2 SR mask 0x907c");

    //======================================================================
    // T3 -- SO: dst 9 is MSB-first, dst 8 reverses (:561-562).
    // bitswap<16>(0x1234, 0..15) = 0x2c48.
    //======================================================================
    clr;
    prom[0] = LDW(16'h1234, 4'd9);
    prom[1] = LDW(16'h1234, 4'd8);
    reset_dsp; run(1);
    chk(dbg_so, 16'h1234, "T3 LD SO plain");
    run(1);
    chk(dbg_so, 16'h2c48, "T3 LD SO reversed");

    //======================================================================
    // T4 -- multiplier (:341-343):
    //   result = (int32)K * L ; M = result >> 15 ; N = result << 1
    //======================================================================
    // (a) 0x4000 * 2 = 0x00008000 -> M = 1, N = 0
    clr;
    prom[0] = LDW(16'h4000, 4'd10);
    prom[1] = LDW(16'h0002, 4'd13);
    reset_dsp; run(2);
    chk(dbg_m, 16'h0001, "T4a M");
    chk(dbg_n, 16'h0000, "T4a N");
    // (b) -1 * 2 = 0xfffffffe -> M = -1 = 0xffff, N = (0x7ffe << 1) = 0xfffc
    clr;
    prom[0] = LDW(16'hffff, 4'd10);
    prom[1] = LDW(16'h0002, 4'd13);
    reset_dsp; run(2);
    chk(dbg_m, 16'hffff, "T4b M signed");
    chk(dbg_n, 16'hfffc, "T4b N signed");
    // (c) 0x7fff * 0x7fff = 0x3fff0001 -> M = 0x7ffe, N = 0x0002
    clr;
    prom[0] = LDW(16'h7fff, 4'd10);
    prom[1] = LDW(16'h7fff, 4'd13);
    reset_dsp; run(2);
    chk(dbg_m, 16'h7ffe, "T4c M");
    chk(dbg_n, 16'h0002, "T4c N");
    // (d) -32768 * -32768 = 0x40000000 -> M = 0x8000, N = 0
    clr;
    prom[0] = LDW(16'h8000, 4'd10);
    prom[1] = LDW(16'h8000, 4'd13);
    reset_dsp; run(2);
    chk(dbg_m, 16'h8000, "T4d M");
    chk(dbg_n, 16'h0000, "T4d N");

    //======================================================================
    // T5 -- data ROM: src 6 (:367) and dst 11 (:564), both at the
    // pre-decrement RP.  drom[3] = 0xcafe.
    // Multiply check: K=0x0055(85), L=0xcafe(-13570) -> -1153450 = 0xffee6656
    //   M = -1153450 >> 15 = -36    = 0xffdc
    //   N = (0x6656 << 1)           = 0xccac
    //======================================================================
    clr;
    drom[3] = 16'hcafe;
    prom[0] = LDW(16'h0003, 4'd5);
    prom[1] = MOV(4'd6, 4'd1);
    prom[2] = LDW(16'h0055, 4'd11);
    reset_dsp; run(2);
    chk(dbg_a, 16'hcafe, "T5 src6 dataROM");
    run(1);
    chk(dbg_k, 16'h0055, "T5 dst11 K");
    chk(dbg_l, 16'hcafe, "T5 dst11 L from ROM");
    chk(dbg_m, 16'hffdc, "T5 M");
    chk(dbg_n, 16'hccac, "T5 N");

    //======================================================================
    // T6 -- data RAM: dst 15 writes RAM[DP] (:568), src 15 reads it (:376).
    //======================================================================
    clr;
    prom[0] = LDW(16'h0000, 4'd4);
    prom[1] = LDW(16'h1357, 4'd15);
    prom[2] = MOV(4'd15, 4'd1);
    reset_dsp; run(3);
    chk(dbg_a, 16'h1357, "T6 RAM write/read");

    //======================================================================
    // T7 -- dst 12: regs.l = id; regs.k = dataRAM[(dp & 0x7ff) | 0x40] (:565)
    // K = RAM[0x40] = 0x2468, L = 9 -> 9320*9 = 83880 = 0x000147a8
    //   M = 83880 >> 15 = 2, N = (0x47a8 << 1) = 0x8f50
    //======================================================================
    clr;
    prom[0] = LDW(16'h0040, 4'd4);
    prom[1] = LDW(16'h2468, 4'd15);
    prom[2] = LDW(16'h0000, 4'd4);
    prom[3] = LDW(16'h0009, 4'd12);
    reset_dsp; run(4);
    chk(dbg_l, 16'h0009, "T7 dst12 L");
    chk(dbg_k, 16'h2468, "T7 dst12 K from RAM|0x40");
    chk(dbg_m, 16'h0002, "T7 M");
    chk(dbg_n, 16'h8f50, "T7 N");

    //======================================================================
    // T8 -- ADD with signed overflow and carry.
    // A = 0x8000, P = IDB = TR = 0x8000, ALU 5.
    //   R  = 0x0000
    //   S0 = 0, Z = 1, old OV1 = 0 so S1 = S0 = 0
    //   OV0 = (Q^R) & ~(Q^P) & 0x8000 = 0x8000 & 0xffff & 0x8000 -> 1
    //   C   = (R < Q) = (0x0000 < 0x8000) -> 1
    //   OV1 = (OV0 & oldOV1)=0 -> OV0 | oldOV1 = 1
    //   flaga = {s1 0, s0 0, c 1, z 1, ov1 1, ov0 1} = 6'b001111 = 0x0f
    //======================================================================
    clr;
    prom[0] = LDW(16'h8000, 4'd1);
    prom[1] = LDW(16'h8000, 4'd3);
    prom[2] = ALUI(4'h5, 1'b0, 4'd3);
    // T9 -- SUB, borrow, and the sticky-OV1 / frozen-S1 rules, continuing
    // from T8's flaga (OV1 already 1).
    //   Q = 1, P = 2, R = 0xffff
    //   S0 = 1, Z = 0, oldOV1 = 1 so S1 keeps its old value 0
    //   OV0 = (Q^R)&(Q^P)&0x8000 = 0x8000 & 0x0003 & 0x8000 -> 0
    //   C   = (R > Q) -> 1
    //   OV1 = (0 & 1)=0 -> 0 | 1 = 1
    //   flaga = {0,1,1,0,1,0} = 6'b011010 = 0x1a
    prom[3] = LDW(16'h0001, 4'd1);
    prom[4] = LDW(16'h0002, 4'd3);
    prom[5] = ALUI(4'h4, 1'b0, 4'd3);
    // T10 -- OR clears C/OV0/OV1 but S1 is still frozen by the OLD OV1.
    //   Q = 0x0f0f, P = 0xf0f0, R = 0xffff, S0 = 1, oldOV1 = 1 -> S1 = 0
    //   flaga = {0,1,0,0,0,0} = 0x10
    prom[6] = LDW(16'h0f0f, 4'd1);
    prom[7] = LDW(16'hf0f0, 4'd3);
    prom[8] = ALUI(4'h1, 1'b0, 4'd3);
    // AND, now with OV1 clear so S1 follows S0.
    //   Q = 0xffff, P = 0xf0f0, R = 0xf0f0, S0 = 1 -> S1 = 1
    //   flaga = {1,1,0,0,0,0} = 0x30
    prom[9]  = ALUI(4'h2, 1'b0, 4'd3);
    // XOR to zero.  R = 0, S0 = 0, Z = 1, S1 = 0 -> flaga = {0,0,0,1,0,0} = 0x04
    prom[10] = ALUI(4'h3, 1'b0, 4'd3);
    reset_dsp; run(3);
    chk (dbg_a,     16'h0000, "T8 ADD result");
    chkf(dbg_flaga, 6'h0f,    "T8 ADD flags");
    run(3);
    chk (dbg_a,     16'hffff, "T9 SUB result");
    chkf(dbg_flaga, 6'h1a,    "T9 SUB flags sticky OV1");
    run(3);
    chk (dbg_a,     16'hffff, "T10 OR result");
    chkf(dbg_flaga, 6'h10,    "T10 OR flags");
    run(1);
    chk (dbg_a,     16'hf0f0, "T10 AND result");
    chkf(dbg_flaga, 6'h30,    "T10 AND flags");
    run(1);
    chk (dbg_a,     16'h0000, "T10 XOR result");
    chkf(dbg_flaga, 6'h04,    "T10 XOR flags");

    //======================================================================
    // T11 -- shifts and CMP (:411-416).
    //  SHR1: R = (Q>>1)|(Q&0x8000); C = Q&1
    //  SHL1: R = (Q<<1)|otherC;     C = Q>>15
    //  SHL2: R = (Q<<2)|3           SHL4: R = (Q<<4)|15
    //  XCHG: byte swap              CMP : ~Q
    //======================================================================
    clr;
    prom[0] = LDW(16'h8001, 4'd1);
    prom[1] = ALUI(4'hb, 1'b0, 4'd0);   // SHR1: 0x8001 -> 0xc000, C = 1
    prom[2] = ALUI(4'hc, 1'b0, 4'd0);   // SHL1: 0xc000 -> 0x8000 (otherC = 0), C = 1
    prom[3] = LDW(16'h1234, 4'd1);
    prom[4] = ALUI(4'hd, 1'b0, 4'd0);   // SHL2: 0x48d3
    prom[5] = LDW(16'h1234, 4'd1);
    prom[6] = ALUI(4'he, 1'b0, 4'd0);   // SHL4: 0x234f
    prom[7] = LDW(16'h1234, 4'd1);
    prom[8] = ALUI(4'hf, 1'b0, 4'd0);   // XCHG: 0x3412
    prom[9] = LDW(16'h1234, 4'd1);
    prom[10]= ALUI(4'ha, 1'b0, 4'd0);   // CMP : 0xedcb
    reset_dsp; run(2);
    chk (dbg_a,     16'hc000, "T11 SHR1");
    chkf(dbg_flaga, 6'h38,    "T11 SHR1 flags");   // s1 1 s0 1 c 1 z 0
    run(1);
    chk (dbg_a,     16'h8000, "T11 SHL1");
    chkf(dbg_flaga, 6'h38,    "T11 SHL1 flags");
    run(2);
    chk (dbg_a,     16'h48d3, "T11 SHL2");
    chkf(dbg_flaga, 6'h00,    "T11 SHL2 flags");
    run(2);
    chk (dbg_a,     16'h234f, "T11 SHL4");
    run(2);
    chk (dbg_a,     16'h3412, "T11 XCHG");
    run(2);
    chk (dbg_a,     16'hedcb, "T11 CMP");
    chkf(dbg_flaga, 6'h30,    "T11 CMP flags");

    //======================================================================
    // T12 -- DEC and INC, where MAME forces P = 1 for the overflow formula.
    //  DEC: Q = 0, R = 0xffff, OV0 = (Q^R)&(Q^1)&0x8000 = 0x8000&0x0001&.. = 0
    //       C = (R > Q) = 1 -> flaga = {1,1,1,0,0,0} = 0x38
    //  INC: Q = 0x7fff, R = 0x8000, OV0 = (0xffff) & ~(0x7ffe) & 0x8000 -> 1
    //       C = (R < Q) = 0, OV1 = 1 -> flaga = {1,1,0,0,1,1} = 0x33
    //======================================================================
    clr;
    prom[0] = LDW(16'h0000, 4'd1);
    prom[1] = ALUI(4'h8, 1'b0, 4'd0);
    reset_dsp; run(2);
    chk (dbg_a,     16'hffff, "T12 DEC");
    chkf(dbg_flaga, 6'h38,    "T12 DEC flags");
    clr;
    prom[0] = LDW(16'h7fff, 4'd1);
    prom[1] = ALUI(4'h9, 1'b0, 4'd0);
    reset_dsp; run(2);
    chk (dbg_a,     16'h8000, "T12 INC");
    chkf(dbg_flaga, 6'h33,    "T12 INC flags");

    //======================================================================
    // T13 -- ADC and SBB take the carry of the OTHER accumulator (:397-398).
    //  Step 1-3 leave flagb.c = 1 (0xffff + 1 wraps).
    //  ADC on A: 0x0010 + 0x0020 + 1 = 0x0031
    //  SBB on A: 0x0010 - 0x0020 - 1 = 0xffef, C = 1
    //======================================================================
    clr;
    prom[0] = LDW(16'hffff, 4'd2);
    prom[1] = LDW(16'h0001, 4'd3);
    prom[2] = ALUI(4'h5, 1'b1, 4'd3);   // ADD on B -> flagb.c = 1
    prom[3] = LDW(16'h0010, 4'd1);
    prom[4] = LDW(16'h0020, 4'd3);
    prom[5] = ALUI(4'h7, 1'b0, 4'd3);   // ADC on A
    prom[6] = LDW(16'h0010, 4'd1);
    prom[7] = ALUI(4'h6, 1'b0, 4'd3);   // SBB on A
    reset_dsp; run(3);
    chk (dbg_b,     16'h0000, "T13 ADD on B");
    chkf(dbg_flagb, 6'h0c,    "T13 flagb c|z");
    run(3);
    chk (dbg_a,     16'h0031, "T13 ADC");
    chkf(dbg_flaga, 6'h00,    "T13 ADC flags");
    run(2);
    chk (dbg_a,     16'hffef, "T13 SBB");
    chkf(dbg_flaga, 6'h38,    "T13 SBB flags");

    //======================================================================
    // T14 -- P select 0/1/2/3 = RAM[DP] / IDB / M / N  (:389-394)
    //======================================================================
    clr;
    prom[0] = LDW(16'h0000, 4'd4);
    prom[1] = LDW(16'h0100, 4'd1);
    prom[2] = OPW(2'd0, 4'h5, 1'b0, 2'd0, 4'd0, 1'b0, 4'd0, 4'd0);  // A += RAM[0]
    prom[3] = LDW(16'h4000, 4'd10);
    prom[4] = LDW(16'h0002, 4'd13);                                  // M = 1, N = 0
    prom[5] = OPW(2'd2, 4'h5, 1'b0, 2'd0, 4'd0, 1'b0, 4'd0, 4'd0);  // A += M
    prom[6] = OPW(2'd3, 4'h5, 1'b0, 2'd0, 4'd0, 1'b0, 4'd0, 4'd0);  // A += N
    prom[7] = LDW(16'h0007, 4'd3);
    prom[8] = ALUI(4'h5, 1'b0, 4'd3);                                // A += IDB(TR)
    reset_dsp;
    ram_poke(11'h000, 16'h0011);
    run(3);
    chk(dbg_a, 16'h0111, "T14 P = RAM[DP]");
    run(3);
    chk(dbg_a, 16'h0112, "T14 P = M");
    run(1);
    chk(dbg_a, 16'h0112, "T14 P = N");
    run(2);
    chk(dbg_a, 16'h0119, "T14 P = IDB");

    //======================================================================
    // T15 -- source select 0..5, 7, 10, 13, 14 and the SGN form (:360-377)
    //======================================================================
    clr;
    prom[0]  = LDW(16'haaaa, 4'd14);  prom[1]  = MOV(4'd0,  4'd1);  // TRB -> A
    prom[2]  = LDW(16'h1111, 4'd1);   prom[3]  = MOV(4'd1,  4'd2);  // A   -> B
    prom[4]  = MOV(4'd2,  4'd3);                                    // B   -> TR
    prom[5]  = MOV(4'd3,  4'd14);                                   // TR  -> TRB
    prom[6]  = LDW(16'h0055, 4'd4);   prom[7]  = MOV(4'd4,  4'd1);  // DP  -> A
    prom[8]  = LDW(16'h0066, 4'd5);   prom[9]  = MOV(4'd5,  4'd2);  // RP  -> B
    prom[10] = MOV(4'd7,  4'd1);                                    // SGN -> A
    prom[11] = MOV(4'd10, 4'd2);                                    // SR  -> B
    prom[12] = LDW(16'h0012, 4'd10);  prom[13] = MOV(4'd13, 4'd1);  // K   -> A
    prom[14] = LDW(16'h0034, 4'd13);  prom[15] = MOV(4'd14, 4'd2);  // L   -> B
    reset_dsp; run(2);
    chk(dbg_a,   16'haaaa, "T15 src0 TRB");
    run(2);
    chk(dbg_b,   16'h1111, "T15 src1 A");
    run(1);
    chk(dbg_tr,  16'h1111, "T15 src2 B");
    run(1);
    chk(dbg_trb, 16'h1111, "T15 src3 TR");
    run(2);
    chk(dbg_a,   16'h0055, "T15 src4 DP");
    run(2);
    chk(dbg_b,   16'h0066, "T15 src5 RP");
    run(1);
    chk(dbg_a,   16'h8000, "T15 src7 SGN (S1=0)");
    run(1);
    chk(dbg_b,   16'h0000, "T15 src10 SR");
    run(2);
    chk(dbg_a,   16'h0012, "T15 src13 K");
    run(2);
    chk(dbg_b,   16'h0034, "T15 src14 L");

    // src 8 sets RQM, src 9 does not (:369-370). Differential from reset.
    clr; prom[0] = MOV(4'd8, 4'd1);
    reset_dsp; run(1);
    chk(dbg_sr, 16'h8000, "T15 src8 sets RQM");
    clr; prom[0] = MOV(4'd9, 4'd1);
    reset_dsp; run(1);
    chk(dbg_sr, 16'h0000, "T15 src9 leaves RQM");

    // SGN with S1 = 1: the INC of T12 leaves flaga.s1 set.
    clr;
    prom[0] = LDW(16'h7fff, 4'd1);
    prom[1] = ALUI(4'h9, 1'b0, 4'd0);   // S1 = 1
    prom[2] = MOV(4'd7, 4'd2);
    reset_dsp; run(3);
    chk(dbg_b, 16'h7fff, "T15 src7 SGN (S1=1)");

    //======================================================================
    // T16 -- JP (:481-541)
    //======================================================================
    // (a) LJMP
    clr;
    prom[0]     = JPW(9'h100, 11'h123, 2'b00);
    prom[16'h123] = LDW(16'h00aa, 4'd1);
    reset_dsp; run(2);
    chk(dbg_a, 16'h00aa, "T16a LJMP");
    chk({12'h0, dbg_pc}, 16'h0124, "T16a LJMP PC");
    // (b) HJMP -> 0x2000 | na
    clr;
    prom[0]      = JPW(9'h101, 11'h005, 2'b00);
    prom[16'h2005] = LDW(16'h00bb, 4'd1);
    reset_dsp; run(2);
    chk(dbg_a, 16'h00bb, "T16b HJMP");
    // (c) bank field occupies PC[12:11]
    clr;
    prom[0]      = JPW(9'h100, 11'h001, 2'b11);
    prom[16'h1801] = LDW(16'h00cc, 4'd1);
    reset_dsp; run(2);
    chk(dbg_a, 16'h00cc, "T16c LJMP bank");
    // (d) LCALL then RT: the pushed return address is the INCREMENTED PC.
    clr;
    prom[0]      = JPW(9'h140, 11'h100, 2'b00);
    prom[16'h100] = LDW(16'h00cc, 4'd1);
    prom[16'h101] = RTW(2'd0, 4'd0, 1'b0, 2'd0, 4'd0, 1'b0, 4'd0, 4'd0);
    prom[1]      = LDW(16'h00dd, 4'd2);
    reset_dsp; run(1);
    chk({12'h0, dbg_pc}, 16'h0100, "T16d LCALL PC");
    chk({12'h0, dbg_sp}, 16'h0001, "T16d LCALL SP");
    run(3);
    chk(dbg_a, 16'h00cc, "T16d call body");
    chk(dbg_b, 16'h00dd, "T16d after RT");
    chk({12'h0, dbg_sp}, 16'h0000, "T16d RT SP");
    // (e) RT also performs its OP move (exec_rt calls exec_op first, :475-479)
    clr;
    prom[0]      = LDW(16'h6789, 4'd3);              // TR
    prom[1]      = JPW(9'h140, 11'h200, 2'b00);
    prom[16'h200] = RTW(2'd0, 4'd0, 1'b0, 2'd0, 4'd0, 1'b0, 4'd3, 4'd1);
    prom[2]      = LDW(16'h0001, 4'd2);
    reset_dsp; run(3);
    chk(dbg_a, 16'h6789, "T16e RT move body");
    chk({12'h0, dbg_pc}, 16'h0002, "T16e RT return");
    // (f) JZA taken / JNZA not taken
    clr;
    prom[0]     = LDW(16'h0000, 4'd1);
    prom[1]     = ALUI(4'h2, 1'b0, 4'd0);            // AND 0 -> Z = 1
    prom[2]     = JPW(9'h08a, 11'h010, 2'b00);       // JZA
    prom[16'h10] = JPW(9'h088, 11'h020, 2'b00);      // JNZA, must NOT branch
    prom[16'h11] = LDW(16'h00ee, 4'd1);
    prom[16'h20] = LDW(16'hbad0, 4'd1);
    reset_dsp; run(5);
    chk(dbg_a, 16'h00ee, "T16f JZA/JNZA");
    // (g) JMPSO
    clr;
    prom[0]     = LDW(16'h0020, 4'd9);
    prom[1]     = JPW(9'h000, 11'h000, 2'b00);
    prom[16'h20] = LDW(16'h0077, 4'd1);
    reset_dsp; run(3);
    chk(dbg_a, 16'h0077, "T16g JMPSO");
    // (h) JRQM
    clr;
    prom[0]     = LDW(16'h0001, 4'd6);               // LD DR -> RQM = 1
    prom[1]     = JPW(9'h0be, 11'h030, 2'b00);       // JRQM
    prom[16'h30] = LDW(16'h0088, 4'd1);
    reset_dsp; run(3);
    chk(dbg_a, 16'h0088, "T16h JRQM");
    // (i) JDPLN0 on DPL != 0
    clr;
    prom[0]     = LDW(16'h0005, 4'd4);
    prom[1]     = JPW(9'h0b1, 11'h040, 2'b00);
    prom[16'h40] = LDW(16'h0099, 4'd1);
    reset_dsp; run(3);
    chk(dbg_a, 16'h0099, "T16i JDPLN0");
    // (j) JDPLF on DPL == 0xf
    clr;
    prom[0]     = LDW(16'h003f, 4'd4);
    prom[1]     = JPW(9'h0b2, 11'h050, 2'b00);
    prom[16'h50] = LDW(16'h009a, 4'd1);
    reset_dsp; run(3);
    chk(dbg_a, 16'h009a, "T16j JDPLF");
    // (k) jps inherits bit 13 from the INCREMENTED PC, so a conditional branch
    //     taken from 0x2000 lands in the high half.
    clr;
    prom[0]        = JPW(9'h101, 11'h000, 2'b00);    // HJMP 0x2000
    prom[16'h2000] = JPW(9'h0b0, 11'h010, 2'b00);    // JDPL0, DP = 0 -> taken
    prom[16'h2010] = LDW(16'h00a5, 4'd1);
    prom[16'h0010] = LDW(16'hbad1, 4'd1);            // wrong target
    reset_dsp; run(3);
    chk(dbg_a, 16'h00a5, "T16k jps keeps PC[13]");
    // (l) an unrecognised branch code falls through
    clr;
    prom[0] = JPW(9'h1ff, 11'h010, 2'b00);
    prom[1] = LDW(16'h0011, 4'd1);
    reset_dsp; run(2);
    chk(dbg_a, 16'h0011, "T16l unknown brch falls through");

    //======================================================================
    // T17 -- DP modify (:462-470).  MAME masks with 0xf0, so DP bits 15:8 are
    // DESTROYED by DPINC/DPDEC/DPCLR.  Reproduced deliberately; see the note
    // in upd96050.sv.
    //   (a) DP 0x012f, DPINC: (0x012f & 0xf0)=0x20, (0x0130 & 0x0f)=0 -> 0x0020
    //   (b) DP 0x0030, DPDEC: 0x30 + ((0x2f)&0x0f = 0xf)             -> 0x003f
    //   (c) DP 0x0037, DPCLR: 0x30                                    -> 0x0030
    //   (d) DP 0x0105, dphm=3, dpl=0: high bits survive a bare XOR    -> 0x0135
    //   (e) DP 0x0105, dphm=3, dpl=1: 0x00 + 0x6 = 0x0006, ^0x30      -> 0x0036
    //   (f) dst == 4 suppresses BOTH the DPL op and the XOR entirely
    //======================================================================
    clr;
    prom[0] = LDW(16'h012f, 4'd4);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd1, 4'd0, 1'b0, 4'd0, 4'd0);
    reset_dsp; run(2);
    chk(dbg_dp, 16'h0020, "T17a DPINC (MAME 0xf0 mask)");
    clr;
    prom[0] = LDW(16'h0030, 4'd4);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd2, 4'd0, 1'b0, 4'd0, 4'd0);
    reset_dsp; run(2);
    chk(dbg_dp, 16'h003f, "T17b DPDEC");
    clr;
    prom[0] = LDW(16'h0037, 4'd4);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd3, 4'd0, 1'b0, 4'd0, 4'd0);
    reset_dsp; run(2);
    chk(dbg_dp, 16'h0030, "T17c DPCLR");
    clr;
    prom[0] = LDW(16'h0105, 4'd4);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd0, 4'd3, 1'b0, 4'd0, 4'd0);
    reset_dsp; run(2);
    chk(dbg_dp, 16'h0135, "T17d DPHM xor only");
    clr;
    prom[0] = LDW(16'h0105, 4'd4);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd1, 4'd3, 1'b0, 4'd0, 4'd0);
    reset_dsp; run(2);
    chk(dbg_dp, 16'h0036, "T17e DPINC then DPHM");
    clr;
    prom[0] = LDW(16'h00ab, 4'd3);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd1, 4'hf, 1'b0, 4'd3, 4'd4);
    reset_dsp; run(2);
    chk(dbg_dp, 16'h00ab, "T17f dst4 suppresses modify");

    //======================================================================
    // T18 -- RP decrement, and dst == 5 suppressing it (:472)
    //======================================================================
    clr;
    prom[0] = LDW(16'h0010, 4'd5);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd0, 4'd0, 1'b1, 4'd0, 4'd0);
    reset_dsp; run(2);
    chk(dbg_rp, 16'h000f, "T18a RPDCR");
    clr;
    prom[0] = LDW(16'h0033, 4'd3);
    prom[1] = OPW(2'd0, 4'd0, 1'b0, 2'd0, 4'd0, 1'b1, 4'd3, 4'd5);
    reset_dsp; run(2);
    chk(dbg_rp, 16'h0033, "T18b dst5 suppresses RPDCR");

    //======================================================================
    // T19 -- interrupt entry (:275-289, :318-331).  A rising INT with EI set
    // injects a NOP then LCALL 0x100 without advancing PC, so the pushed
    // return address is the address of the instruction that was displaced.
    //======================================================================
    clr;
    prom[0]      = LDW(16'h0080, 4'd7);              // EI = 1
    prom[1]      = LDW(16'h0001, 4'd1);              // displaced by the IRQ
    prom[16'h100] = LDW(16'h0033, 4'd2);
    prom[16'h101] = RTW(2'd0, 4'd0, 1'b0, 2'd0, 4'd0, 1'b0, 4'd0, 4'd0);
    reset_dsp; run(1);
    chk(dbg_sr, 16'h0080, "T19 EI set");
    @(negedge clk); int_req = 1'b1;
    @(negedge clk); int_req = 1'b0;
    chk(dbg_sr, 16'h0000, "T19 INT clears EI");
    run(1);                                          // synthesised NOP
    chk({12'h0, dbg_pc}, 16'h0001, "T19 NOP does not advance PC");
    run(1);                                          // synthesised LCALL 0x100
    chk({12'h0, dbg_pc}, 16'h0100, "T19 vector 0x100");
    chk({12'h0, dbg_sp}, 16'h0001, "T19 SP after call");
    run(1);
    chk(dbg_b, 16'h0033, "T19 handler ran");
    run(1);                                          // RT
    chk({12'h0, dbg_pc}, 16'h0001, "T19 return address");
    run(1);
    chk(dbg_a, 16'h0001, "T19 displaced insn runs on return");

    //======================================================================
    // T20 -- every flag-conditional branch code, both polarities and both
    // accumulators, against one fixed flag state (:492-533).
    //
    // Setup leaves:
    //   flagb = 0x0c : ADD 0xffff + 1 on B  -> s1 0, s0 0, c 1, z 1, ov1 0, ov0 0
    //   flaga = 0x33 : INC 0x7fff on A      -> s1 1, s0 1, c 0, z 0, ov1 1, ov0 1
    // SIACK and SOACK are hardwired 0, as in MAME.
    // TRB is used for the markers so the flag-bearing registers stay put.
    //======================================================================
    for (ii = 0; ii < 28; ii = ii + 1) begin
        case (ii)
            0:  begin brch_t = 9'h080; take_t = 1'b1; nm_t = "JNCA   (flaga.c=0)"; end
            1:  begin brch_t = 9'h082; take_t = 1'b0; nm_t = "JCA    (flaga.c=0)"; end
            2:  begin brch_t = 9'h084; take_t = 1'b0; nm_t = "JNCB   (flagb.c=1)"; end
            3:  begin brch_t = 9'h086; take_t = 1'b1; nm_t = "JCB    (flagb.c=1)"; end
            4:  begin brch_t = 9'h088; take_t = 1'b1; nm_t = "JNZA   (flaga.z=0)"; end
            5:  begin brch_t = 9'h08a; take_t = 1'b0; nm_t = "JZA    (flaga.z=0)"; end
            6:  begin brch_t = 9'h08c; take_t = 1'b0; nm_t = "JNZB   (flagb.z=1)"; end
            7:  begin brch_t = 9'h08e; take_t = 1'b1; nm_t = "JZB    (flagb.z=1)"; end
            8:  begin brch_t = 9'h090; take_t = 1'b0; nm_t = "JNOVA0 (flaga.ov0=1)"; end
            9:  begin brch_t = 9'h092; take_t = 1'b1; nm_t = "JOVA0  (flaga.ov0=1)"; end
            10: begin brch_t = 9'h094; take_t = 1'b1; nm_t = "JNOVB0 (flagb.ov0=0)"; end
            11: begin brch_t = 9'h096; take_t = 1'b0; nm_t = "JOVB0  (flagb.ov0=0)"; end
            12: begin brch_t = 9'h098; take_t = 1'b0; nm_t = "JNOVA1 (flaga.ov1=1)"; end
            13: begin brch_t = 9'h09a; take_t = 1'b1; nm_t = "JOVA1  (flaga.ov1=1)"; end
            14: begin brch_t = 9'h09c; take_t = 1'b1; nm_t = "JNOVB1 (flagb.ov1=0)"; end
            15: begin brch_t = 9'h09e; take_t = 1'b0; nm_t = "JOVB1  (flagb.ov1=0)"; end
            16: begin brch_t = 9'h0a0; take_t = 1'b0; nm_t = "JNSA0  (flaga.s0=1)"; end
            17: begin brch_t = 9'h0a2; take_t = 1'b1; nm_t = "JSA0   (flaga.s0=1)"; end
            18: begin brch_t = 9'h0a4; take_t = 1'b1; nm_t = "JNSB0  (flagb.s0=0)"; end
            19: begin brch_t = 9'h0a6; take_t = 1'b0; nm_t = "JSB0   (flagb.s0=0)"; end
            20: begin brch_t = 9'h0a8; take_t = 1'b0; nm_t = "JNSA1  (flaga.s1=1)"; end
            21: begin brch_t = 9'h0aa; take_t = 1'b1; nm_t = "JSA1   (flaga.s1=1)"; end
            22: begin brch_t = 9'h0ac; take_t = 1'b1; nm_t = "JNSB1  (flagb.s1=0)"; end
            23: begin brch_t = 9'h0ae; take_t = 1'b0; nm_t = "JSB1   (flagb.s1=0)"; end
            24: begin brch_t = 9'h0b4; take_t = 1'b1; nm_t = "JNSIAK (siack=0)"; end
            25: begin brch_t = 9'h0b6; take_t = 1'b0; nm_t = "JSIAK  (siack=0)"; end
            26: begin brch_t = 9'h0b8; take_t = 1'b1; nm_t = "JNSOAK (soack=0)"; end
            27: begin brch_t = 9'h0ba; take_t = 1'b0; nm_t = "JSOAK  (soack=0)"; end
        endcase
        clr;
        prom[0] = LDW(16'hffff, 4'd2);
        prom[1] = LDW(16'h0001, 4'd3);
        prom[2] = ALUI(4'h5, 1'b1, 4'd3);        // flagb = 0x0c
        prom[3] = LDW(16'h7fff, 4'd1);
        prom[4] = ALUI(4'h9, 1'b0, 4'd0);        // flaga = 0x33
        prom[5] = JPW(brch_t, 11'h100, 2'b00);
        prom[6] = LDW(16'h00f1, 4'd14);          // fall-through marker
        prom[16'h100] = LDW(16'h00f2, 4'd14);    // taken marker
        reset_dsp;
        run(5);
        chkf(dbg_flaga, 6'h33, "T20 setup flaga");
        chkf(dbg_flagb, 6'h0c, "T20 setup flagb");
        run(2);
        chk(dbg_trb, take_t ? 16'h00f2 : 16'h00f1, nm_t);
    end

    //======================================================================
    $display("------------------------------------------------------------");
    if (prg_lat != 0) $display("(program fetch stalled by %0d extra clks)", prg_lat);
    $display("UPD96050 ISA: %0d passed, %0d failed", pass, fail);
    if (fail == 0) $display("UPD96050 ISA PASS");
    else           $display("UPD96050 ISA FAIL");
    $finish;
end

initial begin
    #20000000;
    $display("UPD96050 ISA FAIL (timeout)");
    $finish;
end

endmodule
