// SPDX-License-Identifier: GPL-3.0-or-later
// Independent diagnostic raster for MiSTer bring-up.
// Timing stays alive whenever the PLL is locked so status colors remain visible
// while ssv_core is held in reset (loader / SDRAM / ROM handshake failures).
`timescale 1ns/1ps

module ssv_diag_video (
    input              clk,
    input              rst,          // typically ~pll_locked only
    input              show_core,    // 1 = forward core pixels in active area
    input       [23:0] core_rgb,
    input              pll_locked,
    input              ioctl_download,
    input              rom_loaded,
    input              sdram_ready,
    input              video_reset,
    input              core_reset,
    input              video_enable,
    input              cpu_halted,
    input              cpu_pause,    // OSD Pause freezes ce_cpu
    input              service_mode, // OSD Service Mode / Test
    input              irq_n,
    input        [7:0] irq_enabled,
    input              ext_busy,
    input              rom_sig_ok,
    input              probe_done,
    input       [15:0] probe_sig0,
    input       [15:0] probe_sig1,
    input       [31:0] debug_pc,
    input       [26:0] ioctl_addr,
    input       [26:0] download_max_addr,
    input       [15:0] frame_count,

    output logic [23:0] rgb,
    output logic       ce_pixel,
    output logic       hs,
    output logic       vs,
    output logic       hb,
    output logic       vb,
    // 1 when the wrapper must drive HDMI from ssv_core timing/pixels
    // (state 8). Diag and core each have an independent raster; mixing
    // core RGB onto the diag CE/HS/VS phase tears or blanks the picture.
    output logic       use_core_video
);

import ssv_pkg::*;

logic [8:0] hcnt, vcnt;

ssv_video_timing timing (
    .clk(clk), .rst(rst),
    .ce_pixel(ce_pixel), .hcnt(hcnt), .vcnt(vcnt),
    .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
    .vblank_pulse()
);

// Primary bring-up state, ranked so the first failing boundary wins.
// Note: state 1 (download) is deep blue; state 7 (CPU up, video off) is teal.
wire [3:0] state_code =
    !pll_locked     ? 4'h0 :
    ioctl_download  ? 4'h1 :
    !rom_loaded     ? 4'h2 :
    !sdram_ready    ? 4'h3 :
    !probe_done     ? 4'ha :
    (probe_done && !rom_sig_ok) ? 4'hb :
    video_reset     ? 4'h4 :
    core_reset      ? 4'h5 :
    cpu_pause       ? 4'h9 :
    cpu_halted      ? 4'h6 :
    !video_enable   ? 4'h7 :
                      4'h8;

assign use_core_video = show_core && (state_code == 4'h8);

function automatic [23:0] state_color(input [3:0] code);
    case (code)
        4'h0: state_color = 24'h101010; // PLL unlocked
        4'h1: state_color = 24'h000080; // downloading (deep blue)
        4'h2: state_color = 24'hc00000; // ROM not loaded
        4'h3: state_color = 24'hc000c0; // SDRAM not ready
        4'h4: state_color = 24'hc0c000; // video/user reset
        4'h5: state_color = 24'hc06000; // core still reset
        4'h6: state_color = 24'h808080; // CPU halted
        4'h7: state_color = 24'h008080; // running, video disabled (teal)
        4'h9: state_color = 24'hc08000; // OSD Pause freezing ce_cpu
        4'ha: state_color = 24'h4040c0; // ROM signature probe in progress
        4'hb: state_color = 24'hff00ff; // ROM signature MISMATCH (download corrupt)
        default: state_color = 24'h004000; // running + video enable
    endcase
endfunction

wire [23:0] base_rgb = state_color(state_code);

// Progress bar only while the HPS download is active.
wire [26:0] progress_addr = (ioctl_addr > download_max_addr) ? ioctl_addr : download_max_addr;
wire [8:0] progress_x = progress_addr[26:18];
wire       in_progress = ioctl_download && (vcnt < 9'd12) &&
                         (hcnt < SSV_HBSTART) && (hcnt < progress_x);

// PC activity: toggles when the sampled PC changes between frames.
logic [31:0] pc_sample;
logic        pc_changed;
always_ff @(posedge clk) begin
    if (rst) begin
        pc_sample  <= 32'd0;
        pc_changed <= 1'b0;
    end
    else if (ce_pixel && (vcnt == 9'd0) && (hcnt == 9'd0)) begin
        pc_changed <= (debug_pc != pc_sample);
        pc_sample  <= debug_pc;
    end
end

// Status bit strip: 16 cells along scanline 16..31.
wire [3:0] bit_index = hcnt[7:4]; // 16-pixel cells
wire       in_bits = (vcnt >= 9'd16) && (vcnt < 9'd32) && (hcnt < 9'd256);
wire [15:0] status_bits = {
    pll_locked,          // 15
    ioctl_download,      // 14
    rom_loaded,          // 13
    sdram_ready,         // 12
    video_reset,         // 11
    core_reset,          // 10
    video_enable,        //  9
    cpu_halted,          //  8
    cpu_pause,           //  7
    service_mode,        //  6
    ~irq_n,              //  5 IRQ asserted
    |irq_enabled,        //  4 any IRQ enabled
    ext_busy,            //  3
    pc_changed,          //  2 PC moved since last frame
    frame_count[0],      //  1
    frame_count[5]       //  0 heart-ish
};
wire bit_on = status_bits[4'(15 - bit_index)];

// PC nybble strip on scanlines 40..55.
// On signature mismatch, show {probe_sig0, probe_sig1} instead of PC.
wire [31:0] strip_word = (probe_done && !rom_sig_ok) ?
    {probe_sig0, probe_sig1} : debug_pc;
wire [2:0] pc_nyb = hcnt[7:5];
wire       in_pc = (vcnt >= 9'd40) && (vcnt < 9'd56) && (hcnt < 9'd256);
wire [3:0] pc_val = 4'(strip_word >> (28 - {1'b0, pc_nyb, 2'b00}));
wire [23:0] pc_rgb = {pc_val, 4'h0, pc_val, 4'h0, ~pc_val, 4'h0};

// Big state-code nibble on the right so download-blue vs video-off-teal
// cannot be confused from a screenshot description alone.
wire       in_state = (vcnt >= 9'd16) && (vcnt < 9'd48) &&
                      (hcnt >= 9'd280) && (hcnt < 9'd312);
wire [23:0] state_digit_rgb = {state_code, 4'h0, state_code, 4'h0, ~state_code, 4'h0};

// Heartbeat / frame flash in the corner so a stuck raster is obvious.
wire in_heart = (vcnt < 9'd8) && (hcnt >= 9'd320) && (hcnt < SSV_HBSTART);
wire heart_on = frame_count[5];

always_comb begin
    if (hb || vb)
        rgb = 24'h000000;
    else if (show_core && (state_code == 4'h8))
        rgb = core_rgb;
    else if (in_heart)
        rgb = heart_on ? 24'hffffff : 24'h000000;
    else if (in_progress)
        rgb = 24'hffffff;
    else if (in_state)
        rgb = state_digit_rgb;
    else if (in_bits)
        rgb = bit_on ? 24'h00ff00 : 24'h202020;
    else if (in_pc)
        rgb = pc_rgb;
    else
        rgb = base_rgb;
end

endmodule
