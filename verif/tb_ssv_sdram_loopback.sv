//============================================================================
//  tb_ssv_sdram_loopback.sv
//
//  Self-checking loopback for rtl/mem/sdram.sv against verif/ssv_sdram_chip.sv.
//
//  What it proves:
//    * the controller's ACT / READ / WRITE address decomposition round-trips
//      through a device that decodes { ba, row, col } the way real hardware
//      does (bank bits 24:23, row 22:10, column 9:1, A[9] a don't-care);
//    * the CL2 capture alignment picks up the RIGHT word — every word carries
//      an address-derived, per-word-distinct pattern, so an off-by-one in the
//      capture pipeline mismatches instead of silently passing;
//    * p1's 64-bit assembly puts the words in the order the controller's
//      deliver() actually builds:
//          p1_dout = { word3, word2, word1, word0 }      (word0 = lowest addr)
//      taken from sdram.sv:279
//          p1_dout <= {final_word, cap_buf[2], cap_buf[1], cap_buf[0]};
//      where final_word is the LAST word captured, i.e. base+3.
//    * DQML/DQMH byte masking on the write port.
//
//  Request contract (sdram.sv:14-20): one transaction per RISING EDGE of req.
//  Every task here pulses req for exactly one clock and waits for ack, then
//  waits for ack to fall before the next transaction.
//
//  Cost measurement: `cost` counts clk RISING EDGES from the edge on which the
//  controller's rising-edge detector latches the request to the edge on which
//  that port's ack asserts.  Reported as  SDRAM_COST p1=<n> p0=<n> p4=<n>
//  Add 1 if you want the figure a requester actually sees, since it cannot
//  observe ack until the following edge.
//============================================================================

`timescale 1ns/1ps

module tb_ssv_sdram_loopback #(
    // Geometry sweep. CTL_* configures the controller, CHIP_* the part.
    // Setting them DIFFERENTLY is the aliasing negative test: a controller
    // driving 11 column bits into a 9-column part puts real address bits on
    // pins the part ignores, so distinct addresses collide. That test must
    // FAIL; a self-test that cannot fail proves nothing.
    parameter int CTL_COL_BITS  = 9,
    parameter int CHIP_COL_BITS = CTL_COL_BITS,
    parameter int AW            = 2 + 13 + CTL_COL_BITS
) ;

// 96.6 MHz clk_ram -> 10.352 ns period
localparam real HALF_PERIOD = 5.176;

logic clk = 1'b0;
always #(HALF_PERIOD) clk = ~clk;

logic init = 1'b1;
wire  ready;

// ---- SDRAM pins -----------------------------------------------------------
wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH;
wire        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE;
wire        SDRAM_CKE;

// ---- port wiring ----------------------------------------------------------
logic        wr_req  = 1'b0;
logic [AW:1] wr_addr = '0;
logic [15:0] wr_din  = '0;
logic  [1:0] wr_be   = 2'b11;
wire         wr_ack;

logic        p0_req  = 1'b0;
logic [AW:1] p0_addr = '0;
wire  [15:0] p0_dout;
wire         p0_ack;

logic        p1_req  = 1'b0;
// [AW:3], not a hardcoded [24:3].  At CTL_COL_BITS=11 the controller port is
// [26:3], so a 22-bit driver left the two BANK bits permanently zero and every
// p1/p5 burst in this bench could only ever address bank 0 -- a coverage hole
// that hid the burst ports' bank decode entirely.
logic [AW:3] p1_addr = '0;
wire  [63:0] p1_dout;
wire         p1_ack;

logic         p2_req  = 1'b0;
logic  [AW:4] p2_addr = '0;
wire  [127:0] p2_dout;
wire          p2_ack;

logic        p3_req  = 1'b0;
logic [AW:1] p3_addr = '0;
wire  [15:0] p3_dout;
wire         p3_ack;

logic        p4_req  = 1'b0;
logic [AW:1] p4_addr = '0;
wire  [15:0] p4_dout;
wire         p4_ack;

logic        p5_req  = 1'b0;
logic [AW:3] p5_addr = '0;      // [AW:3] for the same reason as p1_addr above
wire  [63:0] p5_dout;
wire         p5_ack;

// ---------------------------------------------------------------------------
sdram #(
    .BANK_BITS(2), .ROW_BITS(13), .COL_BITS(CTL_COL_BITS)
) u_ctl (
    .clk        (clk),
    .init       (init),
    .ready      (ready),

    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_A    (SDRAM_A),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_DQML (SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_CKE  (SDRAM_CKE),

    .wr_req (wr_req), .wr_addr(wr_addr), .wr_din(wr_din), .wr_be(wr_be), .wr_ack(wr_ack),
    .p0_req (p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req (p1_req), .p1_addr(p1_addr), .p1_dout(p1_dout), .p1_ack(p1_ack),
    .p2_req (p2_req), .p2_addr(p2_addr), .p2_dout(p2_dout), .p2_ack(p2_ack),
    .p3_req (p3_req), .p3_addr(p3_addr), .p3_dout(p3_dout), .p3_ack(p3_ack),
    .p4_req (p4_req), .p4_addr(p4_addr), .p4_dout(p4_dout), .p4_ack(p4_ack),
    .p5_req (p5_req), .p5_addr(p5_addr), .p5_dout(p5_dout), .p5_ack(p5_ack)
);

ssv_sdram_chip #(
    .BANK_BITS(2), .ROW_BITS(13), .COL_BITS(CHIP_COL_BITS),
    .CHECK_OPEN_ROW (1'b1),     // on here: the controller must never RD/WR a
    .TRCD_CYCLES    (3),        // closed bank, and must honour tRCD
    .VERBOSE        (1'b0)
) u_chip (
    .clk        (clk),
    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_A    (SDRAM_A),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_DQML (SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_CKE  (SDRAM_CKE)
);

// ---------------------------------------------------------------------------
// test data
// ---------------------------------------------------------------------------
int errors = 0;

// Word address, [AW-1:0].  Bit 0 of these values lands on the controller's
// a[1], so they are WORD addresses: col = a[CTL_COL_BITS-1:0],
// row = a[CTL_COL_BITS+12:CTL_COL_BITS], bank = a[AW-1:AW-2].
function automatic [15:0] pat(input [AW-1:0] a);
    // address-derived and distinct for every word, including neighbours
    pat = {a[7:0] ^ a[23:16], a[15:8] ^ 8'h5a} ^ 16'h1234;
endfunction

// Distinct over EVERY address bit, including the bank field, which pat() above
// ignores: at CTL_COL_BITS=11 the bank is a[25:24] and pat() only reaches
// a[23:0], so two addresses differing only in bank share a pattern and a bank
// decode fault would cancel.  Used by the geometry sweep in section 8, whose
// addresses differ in exactly that field.  Pairwise distinctness is asserted at
// runtime rather than argued for.
function automatic [15:0] patw(input [AW-1:0] a);
    logic [31:0] h;
    h    = ({{(32-AW){1'b0}}, a} + 32'h9e3779b9) * 32'h85ebca6b;
    patw = h[31:16] ^ h[15:0];
endfunction

localparam int NG = 9;
bit [AW-1:0] grp [0:NG-1];

// Build a word address from bank/row/column for the CONFIGURED geometry, so the
// same test covers the same structural corners at COL_BITS 9, 10 and 11.
function automatic [AW-1:0] mk(input int bank, input int row, input int col);
    mk = (AW'(bank) << (CTL_COL_BITS + 13))
       | (AW'(row)  <<  CTL_COL_BITS)
       |  AW'(col);
endfunction

function automatic string where(input [AW-1:0] a);
    where = $sformatf("bank %0d row %0d col %0d",
                      a[AW-1:AW-2], a[CTL_COL_BITS+12:CTL_COL_BITS],
                      a[CTL_COL_BITS-1:0]);
endfunction

// ---------------------------------------------------------------------------
// bus tasks — one transaction per RISING EDGE of req (sdram.sv:14-20)
// ---------------------------------------------------------------------------
// All stimulus is driven, and all responses sampled, on the NEGEDGE.  That
// removes every same-edge race with the DUT's own posedge logic, and makes the
// cost number mean exactly one thing:
//
//   req is raised at negedge Nk, so the very next rising edge P(k+1) is the
//   one on which the controller's rising-edge detector latches the request.
//   Call that edge t = 0.  req is dropped at N(k+1), so P(k+2) sees req low
//   and the transaction is latched exactly ONCE, per the sdram.sv contract.
//   The loop then samples ack once per negedge; seeing ack high at negedge
//   N(k+1+n) means ack was asserted by the posedge at t = n.
//
//   cost == clk rising edges from the edge that latches req
//                            to the edge that asserts ack.
task automatic bus_idle();
    @(negedge clk);
    @(negedge clk);
endtask

task automatic do_wr(input [AW-1:0] a, input [15:0] d, input [1:0] be);
    @(negedge clk);
    wr_addr = a; wr_din = d; wr_be = be; wr_req = 1'b1;
    @(negedge clk);                 // the posedge in between latches the request
    wr_req = 1'b0;
    while (!wr_ack) @(negedge clk);
    while ( wr_ack) @(negedge clk); // let the 2-cycle ack stretch retire
    bus_idle();
endtask

task automatic do_p0(input [AW-1:0] a, output [15:0] d, output int cost);
    @(negedge clk);
    p0_addr = a; p0_req = 1'b1;
    @(negedge clk);                 // posedge in between = t0 (request latched)
    p0_req = 1'b0;
    cost = 0;
    while (!p0_ack) begin @(negedge clk); cost++; end
    d = p0_dout;
    while (p0_ack) @(negedge clk);
    bus_idle();
endtask

task automatic do_p4(input [AW-1:0] a, output [15:0] d, output int cost);
    @(negedge clk);
    p4_addr = a; p4_req = 1'b1;
    @(negedge clk);
    p4_req = 1'b0;
    cost = 0;
    while (!p4_ack) begin @(negedge clk); cost++; end
    d = p4_dout;
    while (p4_ack) @(negedge clk);
    bus_idle();
endtask

// a is the WORD address of the first of four words (must be 4-word aligned)
task automatic do_p1(input [AW-1:0] a, output [63:0] d, output int cost);
    @(negedge clk);
    p1_addr = a[AW-1:2]; p1_req = 1'b1;
    @(negedge clk);
    p1_req = 1'b0;
    cost = 0;
    while (!p1_ack) begin @(negedge clk); cost++; end
    d = p1_dout;
    while (p1_ack) @(negedge clk);
    bus_idle();
endtask

// p5: 4-word burst, same shape as p1 but the LAST port in the round-robin.
task automatic do_p5(input [AW-1:0] a, output [63:0] d, output int cost);
    @(negedge clk);
    p5_addr = a[AW-1:2]; p5_req = 1'b1;
    @(negedge clk);
    p5_req = 1'b0;
    cost = 0;
    while (!p5_ack) begin @(negedge clk); cost++; end
    d = p5_dout;
    while (p5_ack) @(negedge clk);
    bus_idle();
endtask

// p2: 8-word burst, 16-byte aligned.  Never exercised by this bench before, so
// the 8-lane assembly in deliver() (sdram.sv:629) had no coverage at all.
task automatic do_p2(input [AW-1:0] a, output [127:0] d, output int cost);
    @(negedge clk);
    p2_addr = a[AW-1:3]; p2_req = 1'b1;
    @(negedge clk);
    p2_req = 1'b0;
    cost = 0;
    while (!p2_ack) begin @(negedge clk); cost++; end
    d = p2_dout;
    while (p2_ack) @(negedge clk);
    bus_idle();
endtask

// ---------------------------------------------------------------------------
task automatic chk16(input string tag, input [AW-1:0] a,
                     input [15:0] got, input [15:0] exp);
    if (got !== exp) begin
        errors++;
        $fatal(1, "MISMATCH %s addr %06x (%s): got %04x expected %04x",
               tag, a, where(a), got, exp);
    end
endtask

// ---------------------------------------------------------------------------
int  c, cost_p0, cost_p1, cost_p4;
int  cmax_p0, cmax_p1, cmax_p4;
logic  [15:0] rd16;
logic  [63:0] rd64;
logic [127:0] rd128;
logic  [63:0] exp64;

// ---------------------------------------------------------------------------
// section 8 state (see the block comment at its call site)
// ---------------------------------------------------------------------------
// The top column bit for the configured geometry: bit 10 of an 11-bit column,
// which the controller has to route to A[11] because A[10] is auto-precharge.
localparam [11:0] TOPCOL = 12'(1 << (CTL_COL_BITS - 1));

bit [AW-1:0] gs [0:3], gb4 [0:3], gb8 [0:3];
bit [AW-1:0] alist [0:127];
int ng2;
int seen_hit_s, seen_act_s, seen_pre_s;
int seen_hit_b, seen_act_b, seen_pre_b;
int snap_hit, snap_miss, snap_conf, snap_ref;

// Snapshot the controller's own transaction classifier for one port.  The three
// exits from ST_IDLE are exhaustive and mutually exclusive (sdram.sv:391-397),
// so hit/miss/conflict tell us which path a transaction actually took instead of
// re-deriving it here -- a re-derivation can disagree with the machine it is
// supposed to be measuring.
task automatic cls_snap(input int port);
    snap_hit  = u_ctl.sdr_row_hit[port];
    snap_miss = u_ctl.sdr_row_miss[port];
    snap_conf = u_ctl.sdr_conflict_total;
    snap_ref  = u_ctl.sdr_refresh_count;
endtask

// Classify the transaction that just completed and tally it.  Exactly one of
// hit/miss must have advanced, always -- that part is asserted unconditionally.
// WHICH one is only asserted-about when no refresh intervened: a refresh
// PRE-alls every bank (sdram.sv:698-702), so it can legitimately turn an
// expected open-row hit into a miss, and asserting through that would make the
// bench flaky rather than strict.
task automatic cls_take(input int port, input bit is_burst);
    int dh, dm, dc;
    begin
        dh = u_ctl.sdr_row_hit[port]      - snap_hit;
        dm = u_ctl.sdr_row_miss[port]     - snap_miss;
        dc = u_ctl.sdr_conflict_total     - snap_conf;
        if (dh + dm != 1) begin
            errors++;
            $fatal(1, "port %0d: %0d transactions classified for one request (hit+%0d miss+%0d)",
                   port, dh + dm, dh, dm);
        end
        if (u_ctl.sdr_refresh_count != snap_ref) return;   // refresh intervened
        if (is_burst) begin
            if (dh)      seen_hit_b++;
            else if (dc) seen_pre_b++;
            else         seen_act_b++;
        end
        else begin
            if (dh)      seen_hit_s++;
            else if (dc) seen_pre_s++;
            else         seen_act_s++;
        end
    end
endtask

initial begin
    grp[0] = 24'h000000;   // bank0 row0    col0     — bottom of memory
    grp[1] = 24'h0003fc;   // bank0 row1    col508   — top of row 1
    grp[2] = 24'h000400;   // bank0 row2    col0     — just over a row edge
    grp[3] = 24'h3ffffc;   // bank0 row8191 col508   — top of bank 0
    grp[4] = 24'h400000;   // bank1 row0    col0     — just over a bank edge
    grp[5] = 24'h7ffffc;   // bank1 row8191 col508   — top of bank 1
    grp[6] = 24'h800004;   // bank2 row0    col4
    grp[7] = 24'hc00000;   // bank3 row0    col0
    grp[8] = 24'hfffffc;   // bank3 row8191 col508   — top of memory

    cost_p0 = 1000; cost_p1 = 1000; cost_p4 = 1000;
    cmax_p0 = 0;    cmax_p1 = 0;    cmax_p4 = 0;

    // ---- reset / init ----------------------------------------------------
    init = 1'b1;
    repeat (16) @(negedge clk);
    init = 1'b0;
    $display("tb_ssv_sdram_loopback: waiting for controller init...");
    wait (ready === 1'b1);
    @(negedge clk);
    $display("[%0t] controller ready", $time);

    // =====================================================================
    // 1. write the pattern through the wr port
    // =====================================================================
    for (int g = 0; g < NG; g++)
        for (int w = 0; w < 4; w++)
            do_wr(grp[g] + w[23:0], pat(grp[g] + w[23:0]), 2'b11);

    // =====================================================================
    // 2. read every word back on p0 (16-bit single)
    // =====================================================================
    for (int g = 0; g < NG; g++)
        for (int w = 0; w < 4; w++) begin
            do_p0(grp[g] + w[23:0], rd16, c);
            chk16("p0", grp[g] + w[23:0], rd16, pat(grp[g] + w[23:0]));
            if (c < cost_p0) cost_p0 = c;
            if (c > cmax_p0) cmax_p0 = c;
        end
    $display("p0 loopback OK (%0d words)", NG*4);

    // =====================================================================
    // 3. read every word back on p4 (16-bit single)
    // =====================================================================
    for (int g = 0; g < NG; g++)
        for (int w = 0; w < 4; w++) begin
            do_p4(grp[g] + w[23:0], rd16, c);
            chk16("p4", grp[g] + w[23:0], rd16, pat(grp[g] + w[23:0]));
            if (c < cost_p4) cost_p4 = c;
            if (c > cmax_p4) cmax_p4 = c;
        end
    $display("p4 loopback OK (%0d words)", NG*4);

    // =====================================================================
    // 4. read each 4-word group back on p1 (64-bit)
    //    ordering per sdram.sv:279 -> { w3, w2, w1, w0 }, w0 = lowest addr
    // =====================================================================
    for (int g = 0; g < NG; g++) begin
        do_p1(grp[g], rd64, c);
        exp64 = { pat(grp[g] + 24'd3), pat(grp[g] + 24'd2),
                  pat(grp[g] + 24'd1), pat(grp[g] + 24'd0) };
        if (rd64 !== exp64) begin
            errors++;
            $fatal(1, "MISMATCH p1 base %06x (%s): got %016x expected %016x",
                   grp[g], where(grp[g]), rd64, exp64);
        end
        // per-lane check so a word-order fault names the offending lane
        for (int w = 0; w < 4; w++)
            chk16($sformatf("p1.lane%0d", w), grp[g] + w[23:0],
                  rd64[w*16 +: 16], pat(grp[g] + w[23:0]));
        if (c < cost_p1) cost_p1 = c;
        if (c > cmax_p1) cmax_p1 = c;
    end
    $display("p1 loopback OK (%0d bursts, word order {w3,w2,w1,w0})", NG);

    // =====================================================================
    // 5. DQML/DQMH byte masking on the write port
    // =====================================================================
    do_wr(24'h000010, 16'hffff, 2'b11);
    do_p0(24'h000010, rd16, c);
    chk16("mask.pre", 24'h000010, rd16, 16'hffff);

    do_wr(24'h000010, 16'h1234, 2'b01);      // low byte only  (DQML=0,DQMH=1)
    do_p0(24'h000010, rd16, c);
    chk16("mask.lo", 24'h000010, rd16, 16'hff34);

    do_wr(24'h000010, 16'habcd, 2'b10);      // high byte only (DQML=1,DQMH=0)
    do_p0(24'h000010, rd16, c);
    chk16("mask.hi", 24'h000010, rd16, 16'hab34);

    do_wr(24'h000010, 16'h55aa, 2'b00);      // both masked -> no change
    do_p0(24'h000010, rd16, c);
    chk16("mask.none", 24'h000010, rd16, 16'hab34);
    $display("byte-mask (DQML/DQMH) OK");

    // =====================================================================
    // 6. independent address-mapping proof: poke the array directly by
    //    hierarchical reference and read it out through the controller.
    //    (A write path and a read path that share the SAME wrong mapping
    //     would cancel out in steps 2-4; this cannot.)
    // =====================================================================
    u_chip.mem[24'h123456] = 16'hbeef;    // bank0 row 2330 col 342
    u_chip.mem[24'hf01235] = 16'hcafe;    // bank3 row 3081 col 53
    do_p0(24'h123456, rd16, c);
    chk16("xmr", 24'h123456, rd16, 16'hbeef);
    do_p4(24'hf01235, rd16, c);
    chk16("xmr", 24'hf01235, rd16, 16'hcafe);
    $display("direct-array address mapping OK");

    // =====================================================================
    // 7. repeat measurements on a quiet bus for the cost figures
    // =====================================================================
    for (int r = 0; r < 12; r++) begin
        do_p0(24'h001000 + r[23:0], rd16, c); if (c < cost_p0) cost_p0 = c;
        do_p4(24'h001000 + r[23:0], rd16, c); if (c < cost_p4) cost_p4 = c;
        do_p1(24'h001000 + (r[23:0] << 2), rd64, c); if (c < cost_p1) cost_p1 = c;
    end

    // =====================================================================
    // 8. Geometry sweep: all four banks, the TOP column bit, and each of the
    //    three ways a transaction can leave ST_IDLE.
    //
    //    WHY THIS EXISTS.  Sections 1-7 use 24-bit literal word addresses.  At
    //    CTL_COL_BITS=11 the bank field is a[25:24], so every one of those
    //    addresses lies in BANK 0 and the bank decode is never really tested;
    //    p2 (8-word burst) was never driven at all, so the 8-lane assembly in
    //    deliver() (sdram.sv:629-630) had no coverage; and p1/p5 could not
    //    leave bank 0 because their bench drivers were 22 bits wide.
    //
    //    What this asserts:
    //      * all four banks, on single-word (p0/p4) and burst (p1/p2/p5) ports;
    //      * the TOP column bit set on every address -- A[11] on a 2048-column
    //        part.  A[10] is auto-precharge, so column bit 10 has to ride on
    //        A[11] (sdram.sv:613-615 cas_addr).  That splice is the only new
    //        address arithmetic the 128 MB retarget introduced;
    //      * a read whose row is ALREADY OPEN (ST_IDLE -> ST_RD), one that
    //        needs ACT (-> ST_ACT), and one that must precharge a wrong row
    //        first (-> ST_PRE_BANK), each classified by the controller's OWN
    //        transaction counters rather than assumed from the address.
    //
    //    Every cell is preloaded by hierarchical reference, so the controller's
    //    write path is not involved and a read-side mapping error cannot be
    //    cancelled by a matching write-side one.
    // =====================================================================
    $display("--- section 8: %0d banks x {open-row, ACT, PRE} x {single, burst}",
             1 << 2);
    ng2 = 0;
    for (int b = 0; b < 4; b++) begin
        gs[b]  = mk(b, 3, TOPCOL | 12'h005);   // single words, row 3
        gb4[b] = mk(b, 3, TOPCOL | 12'h008);   // 4-word burst, row 3
        gb8[b] = mk(b, 9, TOPCOL | 12'h010);   // 8-word burst, row 9
        for (int k = 0; k < 8; k++) begin
            alist[ng2] = gs[b]  + AW'(k); ng2++;
            alist[ng2] = gb4[b] + AW'(k); ng2++;
            alist[ng2] = gb8[b] + AW'(k); ng2++;
        end
    end
    // The pattern must be distinct over the whole set, or a bank/column decode
    // fault could return another cell and still compare equal.  Proved, not
    // asserted in a comment.
    for (int i = 0; i < ng2; i++)
        for (int j = i + 1; j < ng2; j++)
            if (alist[i] != alist[j] && patw(alist[i]) == patw(alist[j]))
                $fatal(1, "bench defect: patw collision %06x / %06x",
                       alist[i], alist[j]);
    for (int i = 0; i < ng2; i++) u_chip.mem[alist[i]] = patw(alist[i]);

    seen_hit_s = 0; seen_act_s = 0; seen_pre_s = 0;
    seen_hit_b = 0; seen_act_b = 0; seen_pre_b = 0;

    for (int b = 0; b < 4; b++) begin
        // Close this bank deterministically: a write auto-precharges
        // (sdram.sv:784-787), so the next read into it must ACT.
        do_wr(gs[b] + AW'(60), 16'h0000, 2'b11);

        cls_snap(0);  do_p0(gs[b],           rd16, c);  cls_take(0, 0);
        chk16("g8.p0.act",  gs[b],           rd16, patw(gs[b]));
        cls_snap(0);  do_p0(gs[b] + AW'(1),  rd16, c);  cls_take(0, 0);
        chk16("g8.p0.hit",  gs[b] + AW'(1),  rd16, patw(gs[b] + AW'(1)));

        cls_snap(1);  do_p1(gb4[b],          rd64, c);  cls_take(1, 1);
        for (int w = 0; w < 4; w++)
            chk16($sformatf("g8.p1.lane%0d", w), gb4[b] + AW'(w),
                  rd64[w*16 +: 16], patw(gb4[b] + AW'(w)));

        // row 9 while row 3 is open: the wrong-row path, on a burst port
        cls_snap(2);  do_p2(gb8[b],          rd128, c); cls_take(2, 1);
        for (int w = 0; w < 8; w++)
            chk16($sformatf("g8.p2.lane%0d", w), gb8[b] + AW'(w),
                  rd128[w*16 +: 16], patw(gb8[b] + AW'(w)));

        // and back to row 3: the wrong-row path on a single-word port
        cls_snap(0);  do_p0(gs[b] + AW'(2),  rd16, c);  cls_take(0, 0);
        chk16("g8.p0.pre",  gs[b] + AW'(2),  rd16, patw(gs[b] + AW'(2)));

        cls_snap(4);  do_p4(gb4[b] + AW'(2), rd16, c);  cls_take(4, 0);
        chk16("g8.p4.hit",  gb4[b] + AW'(2), rd16, patw(gb4[b] + AW'(2)));

        // Close the bank again so a BURST also gets to take the ACT path; the
        // sequence above always leaves some row open, so without this the
        // burst-with-closed-bank case never occurs.
        do_wr(gs[b] + AW'(61), 16'h0000, 2'b11);

        cls_snap(5);  do_p5(gb4[b],          rd64, c);  cls_take(5, 1);
        for (int w = 0; w < 4; w++)
            chk16($sformatf("g8.p5.lane%0d", w), gb4[b] + AW'(w),
                  rd64[w*16 +: 16], patw(gb4[b] + AW'(w)));
    end

    // Coverage gate.  A pass that never took the ACT-skip path, or never took
    // the wrong-row path, would not be evidence about either.
    if (seen_hit_s == 0 || seen_act_s == 0 || seen_pre_s == 0)
        $fatal(1, "section 8 did not cover single-word open-row (%0d), ACT (%0d), wrong-row (%0d)",
               seen_hit_s, seen_act_s, seen_pre_s);
    if (seen_hit_b == 0 || seen_act_b == 0 || seen_pre_b == 0)
        $fatal(1, "section 8 did not cover burst open-row (%0d), ACT (%0d), wrong-row (%0d)",
               seen_hit_b, seen_act_b, seen_pre_b);
    $display("section 8 OK: banks 0-3, top column bit, p0/p1/p2/p4/p5");
    $display("  single-word: open-row %0d  ACT %0d  wrong-row %0d",
             seen_hit_s, seen_act_s, seen_pre_s);
    $display("  burst      : open-row %0d  ACT %0d  wrong-row %0d",
             seen_hit_b, seen_act_b, seen_pre_b);

    if (errors != 0) $fatal(1, "FAIL tb_ssv_sdram_loopback: %0d errors", errors);

    $display("SDRAM_COST p1=%0d p0=%0d p4=%0d", cost_p1, cost_p0, cost_p4);
    $display("  (clk rising edges from the edge that latches req to the edge");
    $display("   that asserts ack, best case on an idle bus; worst observed");
    $display("   including refresh stalls: p1=%0d p0=%0d p4=%0d)",
             cmax_p1, cmax_p0, cmax_p4);
    $display("PASS tb_ssv_sdram_loopback");
    $finish;
end

// watchdog
initial begin
    #4000000;   // 4 ms; init alone is 65536 clk = 678 us
    $fatal(1, "TIMEOUT tb_ssv_sdram_loopback (ready=%b)", ready);
end

endmodule
