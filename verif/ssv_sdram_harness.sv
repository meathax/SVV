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

module ssv_sdram_harness #(
    // Geometry is NO LONGER a parameter. The board carries the MiSTer 128 MB
    // module -- two 32Mx16 devices selected by nCS, with DQML/DQMH shorted to
    // A11/A12 -- and both the controller and verif/ssv_sdram_module.sv encode
    // that contract directly. Parameterising it is how a controller for a part
    // this board does not have got configured and shipped: it byte-masked its
    // own writes through the A11 short and never sent MRS to device 1.
    //
    // The old BANK_BITS/ROW_BITS/COL_BITS/CHIP_COL_BITS/CHIP_CLK_180 knobs are
    // accepted and IGNORED so existing benches still elaborate; they no longer
    // select anything.
    parameter int BANK_BITS      = 2,
    parameter int ROW_BITS       = 13,
    parameter int COL_BITS       = 10,
    parameter int CHIP_COL_BITS  = COL_BITS,
    // Clock the part on clk_ram, EDGE-ALIGNED with the controller. This is the
    // convention every MiSTer core's simulation uses, including the Sega
    // System 32 core this controller comes from and which runs on this board.
    //
    // Inverting it to "model the board's 180-degree SDRAM_CLK" is wrong and was
    // tried: in a zero-delay RTL simulation the half-cycle offset is not
    // representable as an inverted clock, it merely shifts which cycle the part
    // samples, and it made the proven controller fail. The real relationship is
    // a setup/hold property of the physical interface, which belongs to STA and
    // the SDC, not to a behavioural part model.
    parameter bit CHIP_CLK_180   = 1'b0,
    parameter int TRFC_CYC       = 6,
    // 26-bit word address = 128 MB across the two devices, matching
    // ssv_pkg::SDR_AW.
    parameter int AW             = 26
) (
    input  logic        clk_ram,
    input  logic        init,
    output logic        ready,

    // ROM download / CPU writes
    input  logic        wr_req,
    input  logic [AW:1] wr_addr,
    input  logic [15:0] wr_din,
    input  logic  [1:0] wr_be,
    output logic        wr_ack,

    // p0: V60 fetch/data
    input  logic        p0_req,
    input  logic [AW:1] p0_addr,
    output logic [15:0] p0_dout,
    output logic        p0_ack,

    // p2: graphics row fetch (128-bit, 8-word burst, 16-byte aligned).
    // The core moved off p1 when the loader began packing a whole 16-pixel
    // tile row into one aligned 16-byte record -- see
    // docs/SDRAM_GFX_REPACK_DESIGN.md.
    input  logic         p2_req,
    input  logic  [AW:4] p2_addr,
    output logic [127:0] p2_dout,
    output logic         p2_ack,

    // p4: ES5506 sample fetch (16-bit)
    input  logic        p4_req,
    input  logic [AW:1] p4_addr,
    output logic [15:0] p4_dout,
    output logic        p4_ack,

    // p5: ST010 (uPD96050) program fetch (64-bit, 4-word burst, 8-byte
    // aligned). Idle for every title without the daughterboard, so a bench that
    // leaves it unconnected keeps its previous behaviour exactly.
    input  logic        p5_req,
    input  logic [AW:3] p5_addr,
    output logic [63:0] p5_dout,
    output logic        p5_ack
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH;
wire        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

// No geometry parameters: the controller now encodes the MiSTer 128 MB module
// contract (two devices via nCS, DQM shorted to A11/A12) and the geometry is
// fixed by the hardware.
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

    .p5_req(p5_req), .p5_addr(p5_addr),
    .p5_dout(p5_dout), .p5_ack(p5_ack)
);

// The part is verif/ssv_sdram_module.sv -- the MiSTer 128 MB MODULE (two
// devices, nCS as device select, DQM shorted to A11/A12) -- and NOT
// verif/ssv_sdram_chip.sv, which models a single monolithic 64Mx16 part this
// board does not carry. Grading against that fiction is why every bench in this
// repository passed while hardware showed a black screen and no sound.
//
// STRICT is on: a controller that fights the A11/A12 short, or touches a device
// that never received MRS, stops the run at the first offence instead of
// returning quietly wrong data for someone to chase through the video chain.
ssv_sdram_module #(.STRICT(1'b1)) chip (
    .clk(CHIP_CLK_180 ? ~clk_ram : clk_ram),
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
