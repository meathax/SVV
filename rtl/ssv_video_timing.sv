// SPDX-License-Identifier: GPL-3.0-or-later
// Raw SSV CRT timing: 42.954545 MHz / 6, 454 x 262, descriptor active area.
`timescale 1ns/1ps

module ssv_video_timing #(
    // clk_sys cycles per native pixel. clk_sys is generated at exactly this
    // multiple of the board pixel clock -- see SSV_PIXEL_DIV in ssv_pkg.sv.
    parameter int PIXEL_DIV = ssv_pkg::SSV_PIXEL_DIV
) (
    input              clk,
    input              rst,
    input logic [8:0]  active_width,
    input logic [8:0]  active_height,
    output logic       ce_pixel,
    // Exactly twice ce_pixel and phase-locked to it, for the line doubler.
    // With PIXEL_DIV = 8 the two halves of every pixel are 4 clk each, so the
    // line doubler's raster has a constant whole-number pitch too -- required
    // by Direct Video's DV1 pixrep (see SSV_PIXEL_DIV in ssv_pkg.sv).
    output logic       ce_pix_x2,
    output logic [8:0] hcnt,
    output logic [8:0] vcnt,
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       vblank_pulse,
    output logic       irq3_pulse
);

import ssv_pkg::*;

// PIXEL CLOCK.
//
// clk_sys is exactly PIXEL_DIV times the board's 42.954545 MHz / 6 pixel
// clock, so the pixel enable is a plain divide-by-PIXEL_DIV. Every pixel is
// PIXEL_DIV clk wide, every line is SSV_HTOTAL * PIXEL_DIV = 3632 clk and the
// frame runs at the board's own 60.1867 Hz.
//
// This replaces a 16-bit fractional accumulator against a 48.317 MHz clk_sys
// (6.749 clk per pixel). That produced 7,7,7,6 pixel widths, and because
// Direct Video and the analog DAC emit one sample per CLK_VIDEO cycle, the
// 6-clk columns were visible as seams on a line-locked scaler. The per-line
// accumulator preload and the output retime FIFO that followed were both
// workarounds for the non-integer ratio; neither is needed any more.
//
// ce_pix_x2 marks phase 0 (with ce_pixel) and phase PIXEL_DIV/2 of every
// pixel, from the same counter, so it is exactly 2x ce_pixel and in phase by
// construction -- the line doubler's invariant (see ssv_scandoubler.sv).
localparam int PHW = $clog2(PIXEL_DIV);
localparam logic [PHW-1:0] PHASE_LAST = PHW'(PIXEL_DIV - 1);
localparam logic [PHW-1:0] PHASE_HALF = PHW'(PIXEL_DIV / 2 - 1);

// Even, so the doubler's half-pixel enable has a whole-number pitch too.
initial if (PIXEL_DIV < 4 || PIXEL_DIV % 2 != 0)
    $fatal(1, "ssv_video_timing: PIXEL_DIV must be even and at least 4");

logic [PHW-1:0] pix_phase;
logic        native_tick;
logic        half_tick;
logic [8:0]  hcnt_next;
logic [8:0]  vcnt_next;
logic        vblank_pulse_next;
logic        irq3_pulse_next;

// Keep the sync outputs registered with the raster state.  The old version
// decoded hcnt/vcnt in an always_comb block; that is functionally equivalent
// at a simulator sample point, but it leaves the sync pins exposed to a
// counter-decode transition while the registered counter bits settle.  The
// ST-0006/X1-007 evidence is consistent with a registered sync boundary, and
// this implementation preserves the existing phase: sync is decoded from the
// very same next counter value that is committed on the native pixel tick.
always_comb begin
    native_tick       = (pix_phase == PHASE_LAST);
    half_tick         = (pix_phase == PHASE_HALF);
    hcnt_next         = hcnt;
    vcnt_next         = vcnt;
    vblank_pulse_next = 1'b0;
    irq3_pulse_next   = 1'b0;

    if (native_tick) begin
        if (hcnt == SSV_HTOTAL - 1) begin
            hcnt_next = 9'd0;
            if (vcnt == SSV_VTOTAL - 1)
                vcnt_next = 9'd0;
            else begin
                vcnt_next = vcnt + 1'd1;
                if (vcnt == active_height - 1'd1)
                    vblank_pulse_next = 1'b1;
                // The board IRQ3 source is fixed at physical scanline 240.
                // Drift Out crops the visible area (and therefore its live
                // VBLANK status) at line 238, but MAME's SSV scan timer and
                // raw 262-line raster retain the line-240 interrupt.
                if (vcnt == SSV_VBSTART - 1'd1)
                    irq3_pulse_next = 1'b1;
            end
        end
        else
            hcnt_next = hcnt + 1'd1;
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        pix_phase    <= '0;
        ce_pixel     <= 1'b0;
        ce_pix_x2    <= 1'b0;
        hcnt         <= 9'd0;
        vcnt         <= 9'd0;
        vblank_pulse <= 1'b0;
        irq3_pulse   <= 1'b0;
        hsync        <= 1'b1;
        vsync        <= 1'b1;
    end
    else begin
        pix_phase <= native_tick ? '0 : pix_phase + 1'd1;
        ce_pix_x2 <= native_tick | half_tick;
        ce_pixel  <= native_tick;
        hcnt         <= hcnt_next;
        vcnt         <= vcnt_next;
        vblank_pulse <= vblank_pulse_next;
        irq3_pulse   <= irq3_pulse_next;

        if (native_tick) begin
            hsync <= ~((hcnt_next >= 9'd368) && (hcnt_next < 9'd400));
            vsync <= ~((vcnt_next >= 9'd244) && (vcnt_next < 9'd247));
        end
    end
end

always_comb begin
    hblank = (hcnt >= active_width);
    vblank = (vcnt >= active_height);
end

// The exact board sync widths are not documented by MAME's set_raw call.
// These pulses lie wholly in blanking and are suitable for MiSTer output;
// active dimensions and interrupt position remain exact.  Keep this note
// beside the registered decode so a future timing change does not mistake the
// pulse locations for measured ST-0006 hardware values.
//
// Best available evidence (MAME 0.289 ssv_v.cpp CRTC table + per-game
// set_visarea): the games program the ST-0006 with display START positions
// that differ per game -- x start 68 dots (cairblad) .. 88 dots (dynagear,
// survarts, twineag2, ultrax); y start line 14 (vasara, stmblade, mslider,
// cairblad) .. 19 (drifto94). If the CRTC counters' zero is the start of
// sync (the usual CRTC arrangement, NOT verified), real hsync begins 454 - 2*x
// start dots before the first active pixel (366 for dynagear vs 368 here,
// 382 for vasara) and vsync begins (262 - y start) lines into the frame
// (244 for dynagear -- exactly the value used here -- 248 for vasara). So the
// picture sits up to ~20 dots / ~5 lines differently on a real board, per
// game. $1c0060 (0x21 or 0x2b) and $1c0068 (1) are plausibly the hsync and
// vsync END values, but MAME labels both "?". Only a scope on a real
// STA-0001B can settle the positions and widths; a DV1-aware sink is
// unaffected either way (Main reports the DE offset), a CRT just centres
// differently.

`ifdef SIMULATION
// Simulation-only boundary guard.  It has no release hardware cost and makes
// a future edit that accidentally reintroduces a mid-cycle sync transition
// fail at the source rather than only showing up as an HDMI monitor symptom.
always @(hsync or vsync or hblank or vblank) begin
    if (!rst && !ce_pixel)
        $fatal(1, "SSV video boundary changed without native pixel enable");
end
`endif

endmodule
