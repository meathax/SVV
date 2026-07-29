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

module tb_ssv_sdram_loopback;

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
logic [24:1] wr_addr = '0;
logic [15:0] wr_din  = '0;
logic  [1:0] wr_be   = 2'b11;
wire         wr_ack;

logic        p0_req  = 1'b0;
logic [24:1] p0_addr = '0;
wire  [15:0] p0_dout;
wire         p0_ack;

logic        p1_req  = 1'b0;
logic [24:3] p1_addr = '0;
wire  [63:0] p1_dout;
wire         p1_ack;

logic         p2_req  = 1'b0;
logic  [24:4] p2_addr = '0;
wire  [127:0] p2_dout;
wire          p2_ack;

logic        p3_req  = 1'b0;
logic [24:1] p3_addr = '0;
wire  [15:0] p3_dout;
wire         p3_ack;

logic        p4_req  = 1'b0;
logic [24:1] p4_addr = '0;
wire  [15:0] p4_dout;
wire         p4_ack;

logic        p5_req  = 1'b0;
logic [24:3] p5_addr = '0;
wire  [63:0] p5_dout;
wire         p5_ack;

// ---------------------------------------------------------------------------
sdram u_ctl (
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

function automatic [15:0] pat(input [23:0] a);
    // address-derived and distinct for every word, including neighbours
    pat = {a[7:0] ^ a[23:16], a[15:8] ^ 8'h5a} ^ 16'h1234;
endfunction

localparam int NG = 9;
bit [23:0] grp [0:NG-1];

function automatic string where(input [23:0] a);
    where = $sformatf("bank %0d row %0d col %0d", a[23:22], a[21:9], a[8:0]);
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

task automatic do_wr(input [23:0] a, input [15:0] d, input [1:0] be);
    @(negedge clk);
    wr_addr = a; wr_din = d; wr_be = be; wr_req = 1'b1;
    @(negedge clk);                 // the posedge in between latches the request
    wr_req = 1'b0;
    while (!wr_ack) @(negedge clk);
    while ( wr_ack) @(negedge clk); // let the 2-cycle ack stretch retire
    bus_idle();
endtask

task automatic do_p0(input [23:0] a, output [15:0] d, output int cost);
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

task automatic do_p4(input [23:0] a, output [15:0] d, output int cost);
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
task automatic do_p1(input [23:0] a, output [63:0] d, output int cost);
    @(negedge clk);
    p1_addr = a[23:2]; p1_req = 1'b1;
    @(negedge clk);
    p1_req = 1'b0;
    cost = 0;
    while (!p1_ack) begin @(negedge clk); cost++; end
    d = p1_dout;
    while (p1_ack) @(negedge clk);
    bus_idle();
endtask

// ---------------------------------------------------------------------------
task automatic chk16(input string tag, input [23:0] a,
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
logic [15:0] rd16;
logic [63:0] rd64;
logic [63:0] exp64;

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
