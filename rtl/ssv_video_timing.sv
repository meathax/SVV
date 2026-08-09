// SPDX-License-Identifier: GPL-3.0-or-later
// Raw SSV CRT timing: 42.954545 MHz / 6, 454 x 262, descriptor active area.
`timescale 1ns/1ps

module ssv_video_timing #(
    parameter logic [15:0] PIXEL_INC = ssv_pkg::SSV_PIXEL_INC
) (
    input              clk,
    input              rst,
    input logic [8:0]  active_width,
    input logic [8:0]  active_height,
    output logic       ce_pixel,
    // Exactly twice ce_pixel and phase-locked to it, for the line doubler.
    //
    // It MUST come from here rather than from a second accumulator in the
    // wrapper. Arcade-SSV.sv used to run its own, restarted on the line
    // reference while this one free-runs, and verif/tb_ssv_scandoubler.sv
    // measured the result at a constant 907 ticks per line where exact
    // doubling of a 454-pixel line needs 908 -- so the second copy of every
    // line was one pixel short.
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

// The accumulator runs at DOUBLE the pixel increment and the native pixel
// enable is every second carry. That makes ce_pix_x2 exactly 2x ce_pixel by
// construction, with no second accumulator to drift against.
//
// It is also bit-identical to the previous single-rate version, which is why
// it does not move a single frame CRC: the k-th native tick used to be the
// smallest N with floor(N*INC/65536) == k, and the 2k-th double-rate carry is
// the smallest N with floor(N*2*INC/65536) == 2k -- the same condition, so
// both land on exactly the same clock cycles.
localparam logic [15:0] PIXEL_INC_X2 = PIXEL_INC << 1;

logic [15:0] pixel_acc;
logic        pix_phase;      // 0 -> next carry is the half tick, 1 -> native

logic [16:0] pixel_sum;
logic        native_tick;
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
    pixel_sum         = {1'b0, pixel_acc} + {1'b0, PIXEL_INC_X2};
    native_tick       = pixel_sum[16] & pix_phase;
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
        pixel_acc    <= 16'd0;
        pix_phase    <= 1'b0;
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
        pixel_acc <= pixel_sum[15:0];
        ce_pix_x2 <= pixel_sum[16];
        if (pixel_sum[16]) pix_phase <= ~pix_phase;
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
