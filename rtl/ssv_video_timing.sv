// SPDX-License-Identifier: GPL-3.0-or-later
// Raw SSV CRT timing: 42.954545 MHz / 6, 454 x 262, active 336 x 240.
`timescale 1ns/1ps

module ssv_video_timing #(
    parameter logic [15:0] PIXEL_INC = 16'd9710
) (
    input              clk,
    input              rst,
    output logic       ce_pixel,
    output logic [8:0] hcnt,
    output logic [8:0] vcnt,
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       vblank_pulse
);

import ssv_pkg::*;

logic [15:0] pixel_acc;

always_ff @(posedge clk) begin
    logic [16:0] sum;
    if (rst) begin
        pixel_acc    <= 16'd0;
        ce_pixel     <= 1'b0;
        hcnt         <= 9'd0;
        vcnt         <= 9'd0;
        vblank_pulse <= 1'b0;
    end
    else begin
        sum       = {1'b0, pixel_acc} + {1'b0, PIXEL_INC};
        pixel_acc <= sum[15:0];
        ce_pixel  <= sum[16];
        vblank_pulse <= 1'b0;

        if (sum[16]) begin
            if (hcnt == SSV_HTOTAL - 1) begin
                hcnt <= 9'd0;
                if (vcnt == SSV_VTOTAL - 1)
                    vcnt <= 9'd0;
                else begin
                    vcnt <= vcnt + 1'd1;
                    if (vcnt == SSV_VBSTART - 1)
                        vblank_pulse <= 1'b1;
                end
            end
            else
                hcnt <= hcnt + 1'd1;
        end
    end
end

always_comb begin
    hblank = (hcnt >= SSV_HBSTART);
    vblank = (vcnt >= SSV_VBSTART);

    // The exact board sync widths are not documented by MAME's set_raw call.
    // These pulses lie wholly in blanking and are suitable for MiSTer output;
    // active dimensions and interrupt position remain exact.
    hsync = ~((hcnt >= 9'd368) && (hcnt < 9'd400));
    vsync = ~((vcnt >= 9'd244) && (vcnt < 9'd247));
end

endmodule
