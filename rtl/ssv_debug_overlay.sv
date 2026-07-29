// SPDX-License-Identifier: GPL-3.0-or-later
//
// On-screen renderer diagnostics for HARDWARE bring-up.
//
// The scanline renderer can miss a line deadline (still busy when the line
// buffer is told to swap). In simulation that is measurable -- tb_ssv_frame_crc
// counts bg_overruns/obj_overruns directly -- but on a real MiSTer there is no
// counter to read, only the picture. This module draws the counters onto the
// picture itself so a still screenshot answers the question.
//
// WHAT IT MEASURES, per scanline, while that line is being rendered:
//   overran      renderer still busy at the swap point (= the TB's
//                `line_buffer_start && (bg_busy|obj_busy)` condition)
//   busy_cycles  clk_sys cycles the renderer was busy on that line
//   wait_cycles  clk_sys cycles the graphics fetch held p2 req without ack
//
// WHY THE SAME FRAME IS SAFE. The renderer runs two lines ahead of the raster
// (renderer_target_y = vcnt + 2) into the back half of a double line buffer, so
// the stats for display line L are complete at the swap at the end of line L-1
// -- one horizontal blank before line L is scanned out. Nothing is deferred to
// the next frame.
//
// STORAGE COST: 256 x 17 bits = 4352 bits = ONE M10K. The last recorded fit
// (output_files/Arcade-SSV.fit.rpt) used 530 of 553 M10K, so this takes the
// core to 531/553 and leaves 22 spare. Deliberately not MLAB: 256 deep x 17
// wide is 8 MLABs plus output muxing, ~100 ALMs, which is the worse trade
// while any M10K remains -- swap the ramstyle attribute below if that changes.
// The whole module can be removed from a release build by tying mode to 0 --
// with a constant 0 the array, both counters and the compare logic are dead
// and Quartus strips them.
//
// NOT IN THE RENDERER'S PATH: every capture input is read-only. Nothing here
// gates, delays or feeds back into the renderers or their SDRAM requests. The
// only signal that leaves this module and touches the render path at all is
// hide_obj/hide_bg, and that masks the LINE BUFFER's write enables downstream
// of the renderer -- the state machines and p2 traffic are untouched, which is
// the point of modes 4 and 5 (change what is drawn, not how long it takes).
`timescale 1ns/1ps

module ssv_debug_overlay #(
    // Must match ssv_video_timing's PIXEL_INC; only used to derive the
    // per-line clk_sys budget below.
    parameter logic [15:0] PIXEL_INC = 16'd9710
) (
    input  logic        clk,
    input  logic        rst,

    // 0 off (bit-exact no-op), 1 overrun marks, 2 load bars,
    // 3 fetch-wait bars, 4 hide objects, 5 hide background.
    input  logic  [2:0] mode,

    // Raster position and the core's own active-pixel condition.
    input  logic  [8:0] hcnt,
    input  logic  [8:0] vcnt,
    input  logic        active,

    // Capture inputs (all read-only observers).
    input  logic  [8:0] renderer_target_y, // line the renderer is working on
    input  logic        line_commit,       // line_buffer_start: window boundary
    input  logic        renderer_busy,     // bg_busy | obj_busy
    input  logic        gfx_wait,          // p2 req asserted, ack not yet back
    input  logic        overrun_sticky,    // core's sticky renderer_overrun
    // Split by cause so one glance says which fired. A missed line deadline
    // and a full descriptor cache both set renderer_overrun but need
    // completely different fixes.
    input  logic        overrun_deadline,
    input  logic        overrun_cachefull,

    // Pixel path.
    input  logic [23:0] rgb_in,
    output logic [23:0] rgb_out,

    // Pixel-write suppression for modes 4/5 (applied in ssv_core).
    output logic        hide_obj,
    output logic        hide_bg
);

import ssv_pkg::*;

// ---------------------------------------------------------------------------
// Scale.
//
// clk_sys cycles per scanline = SSV_HTOTAL * 65536 / PIXEL_INC
//                             = 454 * 65536 / 9710 = 3064.
//
// Counters are kept at 12 bits (saturating) and stored as bits [11:4], so one
// stored unit = 16 clk_sys cycles and one bar pixel = 16 cycles. A full line
// budget is 3064/16 = 191 pixels and saturation is 255 pixels (4080 cycles),
// both inside the 336-pixel active area, so the bar length in pixels IS the
// scaled counter with no further scaling at draw time.
// ---------------------------------------------------------------------------
localparam int CLKS_PER_LINE = (int'(SSV_HTOTAL) * 65536) / int'(PIXEL_INC);
localparam int CNT_SHIFT     = 4;
localparam logic [7:0] BUDGET8 = 8'(CLKS_PER_LINE >> CNT_SHIFT); // 191

localparam logic [23:0] C_RED   = 24'hff0000; // over budget / overran / sticky
localparam logic [23:0] C_GREEN = 24'h00c000; // busy, within budget
localparam logic [23:0] C_BLUE  = 24'h0060ff; // fetch wait, within budget
localparam logic [23:0] C_TICK  = 24'h909090; // budget ruler
localparam logic [23:0] C_OK    = 24'h004000; // sticky: no overrun yet

assign hide_obj = (mode == 3'd4);
assign hide_bg  = (mode == 3'd5);

// ---------------------------------------------------------------------------
// Per-line capture.
//
// One window runs from one line_commit to the next; that is exactly the period
// the renderer owns for renderer_target_y, latched at the opening edge into
// cur_y. At the closing edge the window's totals are written to slot cur_y and
// the counters restart for the new target in the same cycle.
// ---------------------------------------------------------------------------
logic [11:0] busy_cnt, wait_cnt;
logic  [7:0] cur_y;

always_ff @(posedge clk) begin
    if (rst) begin
        busy_cnt <= 12'd0;
        wait_cnt <= 12'd0;
        cur_y    <= 8'd0;
    end
    else if (line_commit) begin
        busy_cnt <= {11'd0, renderer_busy};
        wait_cnt <= {11'd0, gfx_wait};
        cur_y    <= renderer_target_y[7:0];
    end
    else begin
        if (renderer_busy && !(&busy_cnt)) busy_cnt <= busy_cnt + 12'd1;
        if (gfx_wait     && !(&wait_cnt)) wait_cnt <= wait_cnt + 12'd1;
    end
end

// {overran, busy[7:0], wait[7:0]}. 240 lines used; 256 deep so the address is
// a plain 8-bit slice and the vblank-tail commit for target 240 lands in a
// slot that is never displayed instead of aliasing onto line 0.
(* ramstyle = "M10K, no_rw_check" *) logic [16:0] line_stats [0:255];
logic [16:0] disp_stat;

// Write address (cur_y, 0..240) and read address (vcnt, 0..239 while active)
// can never be equal in the same cycle. The commit at the end of line V-1
// writes slot V -- the line about to be scanned -- and immediately latches
// cur_y = V+1, so throughout line V the only pending write is to V+1 while the
// read address sits on V. Hence no_rw_check.
always_ff @(posedge clk) begin
    if (line_commit)
        line_stats[cur_y] <= {renderer_busy, busy_cnt[11:CNT_SHIFT],
                                             wait_cnt[11:CNT_SHIFT]};
    disp_stat <= line_stats[vcnt[7:0]];
end

`ifdef SIMULATION
// Hardware M10K contents power up to zero; match that so a testbench does not
// see X-driven bars on the first frame after reset.
integer dbg_init_i;
initial begin
    for (dbg_init_i = 0; dbg_init_i < 256; dbg_init_i = dbg_init_i + 1)
        line_stats[dbg_init_i] = 17'd0;
    disp_stat = 17'd0;
end
`endif

wire       d_ovr  = disp_stat[16];
wire [7:0] d_busy = disp_stat[15:8];
wire [7:0] d_wait = disp_stat[7:0];

// ---------------------------------------------------------------------------
// Draw. Pure combinational on rgb_in: no added pixel-pipeline delay, and with
// mode == 0 rgb_out is rgb_in bit for bit.
// ---------------------------------------------------------------------------
wire draw_en = active && (mode != 3'd0) && (mode <= 3'd5);

// Sticky "has ever missed a deadline" block, top-right 8x8 of the active area.
wire in_sticky = (vcnt < 9'd8) &&
                 (hcnt >= SSV_HBSTART - 9'd8) && (hcnt < SSV_HBSTART);

wire in_mark  = (hcnt < 9'd8);
wire bar_busy = (hcnt < {1'b0, d_busy});
wire bar_wait = (hcnt < {1'b0, d_wait});
wire on_tick  = (hcnt == {1'b0, BUDGET8});

always_comb begin
    rgb_out = rgb_in;
    if (draw_en) begin
        if (in_sticky)
            // green  = clean
            // red    = missed a line deadline (renderer too slow)
            // yellow = descriptor cache overflowed (dropped sprites)
            // white  = both
            rgb_out = (overrun_deadline && overrun_cachefull) ? 24'hffffff :
                       overrun_deadline                       ? C_RED       :
                       overrun_cachefull                      ? 24'hffff00  :
                       overrun_sticky                         ? C_RED       : C_OK;
        else begin
            case (mode)
                3'd1: if (d_ovr && in_mark)     rgb_out = C_RED;
                3'd2: if (bar_busy)             rgb_out = (d_busy > BUDGET8)
                                                          ? C_RED : C_GREEN;
                      else if (on_tick)         rgb_out = C_TICK;
                3'd3: if (bar_wait)             rgb_out = (d_wait > BUDGET8)
                                                          ? C_RED : C_BLUE;
                      else if (on_tick)         rgb_out = C_TICK;
                default: ; // 4/5 change plot_we only; 6/7 unused
            endcase
        end
    end
end

endmodule
