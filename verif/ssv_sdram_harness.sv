// SPDX-License-Identifier: GPL-3.0-or-later
// Real SDRAM controller + chip model, wrapped to look like the behavioural
// port model the full-core testbenches already drive.
//
// WHY THIS EXISTS
//
// Every full-core bench in this repo answers the core's SDRAM ports from plain
// arrays with a fixed two-cycle sticky ack. That model cannot miss a deadline,
// so `overruns bg=0 obj=0` has always been a statement about the model rather
// than about the memory system. On hardware the same RTL shows drifting
// horizontal corruption bands and starved audio, because the real controller
// serialises every access as ACT -> tRCD -> READ xN -> drain with
// auto-precharge, round-robins six ports, and stops for refresh.
//
// Dropping this module in front of the core makes that cost real in
// simulation, so the bandwidth problem can be reproduced, measured and
// regressed instead of only observed on the bench.
//
// CLOCKING
//
// The core runs at clk_sys (48.3 MHz on hardware) and the controller at
// clk_ram (96.6 MHz) -- exactly 2x. The caller must supply that ratio, because
// getting it wrong silently changes the bandwidth answer, which is the one
// number this harness exists to produce.
`timescale 1ns/1ps

module ssv_sdram_harness (
    input  logic        clk_ram,
    input  logic        init,
    output logic        ready,

    // ROM download / CPU writes
    input  logic        wr_req,
    input  logic [24:1] wr_addr,
    input  logic [15:0] wr_din,
    input  logic  [1:0] wr_be,
    output logic        wr_ack,

    // p0: V60 fetch/data
    input  logic        p0_req,
    input  logic [24:1] p0_addr,
    output logic [15:0] p0_dout,
    output logic        p0_ack,

    // p2: graphics row fetch (128-bit, 8-word burst, 16-byte aligned).
    // The core moved off p1 when the loader began packing a whole 16-pixel
    // tile row into one aligned 16-byte record -- see
    // docs/SDRAM_GFX_REPACK_DESIGN.md.
    input  logic         p2_req,
    input  logic  [24:4] p2_addr,
    output logic [127:0] p2_dout,
    output logic         p2_ack,

    // p4: ES5506 sample fetch (16-bit)
    input  logic        p4_req,
    input  logic [24:1] p4_addr,
    output logic [15:0] p4_dout,
    output logic        p4_ack
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH;
wire        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

sdram controller (
    .clk(clk_ram),
    .init(init),
    .ready(ready),

    .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_A(SDRAM_A),
    .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE),

    .wr_req(wr_req), .wr_addr(wr_addr), .wr_din(wr_din),
    .wr_be(wr_be), .wr_ack(wr_ack),

    .p0_req(p0_req), .p0_addr(p0_addr),
    .p0_dout(p0_dout), .p0_ack(p0_ack),

    .p2_req(p2_req), .p2_addr(p2_addr),
    .p2_dout(p2_dout), .p2_ack(p2_ack),

    // Unused ports on this board. Tied off so the arbiter never grants them.
    .p1_req(1'b0), .p1_addr('0), .p1_dout(), .p1_ack(),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(), .p3_ack(),

    .p4_req(p4_req), .p4_addr(p4_addr),
    .p4_dout(p4_dout), .p4_ack(p4_ack),

    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

ssv_sdram_chip chip (
    .clk(clk_ram),
    .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_A(SDRAM_A),
    .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS),
    .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_CKE(SDRAM_CKE)
);

endmodule
