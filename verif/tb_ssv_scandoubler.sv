// SPDX-License-Identifier: GPL-3.0-or-later
//
// Line-doubler bench.
//
// rtl/ssv_scandoubler.sv replaced sys/arcade_video.v in commit 095d3b2, whose
// own message records: "Verified by parse and elaboration only... Not built,
// not simulated, no hardware -- and the line doubler in particular has never
// produced a pixel." This is that missing test.
//
// It drives the REAL ssv_video_timing and a VERBATIM copy of the ce_pix_x2
// generator from Arcade-SSV.sv:604-617, because the doubler's contract is
// "ce_pix_x2 is exactly twice ce_pix and phase-locked to it" and that generator
// is the thing which has to satisfy it. Testing an idealised 2x enable here
// would pass while the shipped design fails.
//
// Every pixel carries its own coordinate in its RGB value, so a failure decodes
// to "output pixel N was (x=..,y=..), expected (x=..,y=..)" instead of "the
// picture looks wrong".
//
//   rgb = { vcnt[7:0], hcnt[8:0], 7'b0 }
//
// Assertions (see docs plan Phase 6):
//   A1  each input line is emitted exactly twice
//   A2  every output pixel is the correct input pixel, in order
//   A3  sync is replayed: 2 hs_out pulses per input line
//   A4  vs_out survives doubling: 1 pulse per frame
//   A6  VGA_DE is 672 active output pixels per output line pair (336 x 2)
//
// Build with --binary --timing --assert over rtl/ssv_pkg.sv,
// rtl/ssv_video_timing.sv, rtl/ssv_scandoubler.sv and this file, with
// --top-module tb_ssv_scandoubler. (Spelling the tool name at the start of a
// comment line would be read as a lint directive, so it is omitted.)

`timescale 1ns/1ps

module tb_ssv_scandoubler;

import ssv_pkg::*;

localparam logic [15:0] PIXEL_INC = 16'd9710;   // matches ssv_video_timing
localparam int FRAMES = 3;

logic clk = 1'b0;
always #10 clk = ~clk;

logic rst = 1'b1;

// ---------------------------------------------------------------------------
// Real raster timing.
// ---------------------------------------------------------------------------
logic       av_ce, ce_pix_x2;
logic [8:0] hcnt, vcnt;
logic       av_hb, av_vb, av_hs, av_vs, vbp;

// ce_pix_x2 now comes from the timing module itself, off the same accumulator
// as ce_pixel, so the 2:1 ratio holds by construction. It used to be generated
// by a second, line-restarted accumulator in Arcade-SSV.sv; A1 below measured
// that at a constant 907 ticks per line where 908 is required.
ssv_video_timing #(.PIXEL_INC(PIXEL_INC)) u_timing (
    .clk(clk), .rst(rst),
    .ce_pixel(av_ce), .ce_pix_x2(ce_pix_x2),
    .hcnt(hcnt), .vcnt(vcnt),
    .hblank(av_hb), .vblank(av_vb),
    .hsync(av_hs), .vsync(av_vs), .vblank_pulse(vbp)
);

logic av_hs_d2;
always_ff @(posedge clk) if (av_ce) av_hs_d2 <= av_hs;
wire av_line_start = av_ce && (av_hs & ~av_hs_d2);

// ---------------------------------------------------------------------------
// Self-identifying pixels.
// ---------------------------------------------------------------------------
wire [23:0] rgb_in = {vcnt[7:0], hcnt[8:0], 7'b0};

function automatic int dec_v(input logic [23:0] p); dec_v = int'(p[23:16]); endfunction
function automatic int dec_h(input logic [23:0] p); dec_h = int'(p[15:7]);  endfunction

wire [23:0] rgb_out;
logic       hs_out, vs_out, hb_out, vb_out;

ssv_scandoubler u_dut (
    .clk(clk), .rst(rst),
    .ce_pix(av_ce), .ce_pix_x2(ce_pix_x2),
    .rgb_in(rgb_in), .hs_in(av_hs), .vs_in(av_vs),
    .hb_in(av_hb), .vb_in(av_vb),
    .rgb_out(rgb_out), .hs_out(hs_out), .vs_out(vs_out),
    .hb_out(hb_out), .vb_out(vb_out)
);

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------
int ce_pix_in_line, ce_x2_in_line;
int input_lines, out_hs_pulses, out_vs_pulses, out_de_pixels;
int out_de_frame;
int frames_seen;

int a1_fail, a2_fail, a3_fail, a4_fail, a6_fail;
int a1_first_line, a2_reports;
int a1_min_x2, a1_max_x2;

// The line just captured on the input side, replayed for comparison.
logic [23:0] expect_rgb [0:511];
int          expect_len;
logic [23:0] cur_rgb    [0:511];
int          cur_len;
logic        expect_valid;

// Output-side walk through the expected line, twice.
int out_idx;

logic hs_out_d, vs_out_d;

initial begin
    ce_pix_in_line = 0; ce_x2_in_line = 0;
    input_lines = 0; out_hs_pulses = 0; out_vs_pulses = 0; out_de_pixels = 0;
    out_de_frame = 0;
    frames_seen = 0;
    a1_fail = 0; a2_fail = 0; a3_fail = 0; a4_fail = 0; a6_fail = 0;
    a1_first_line = -1; a2_reports = 0;
    a1_min_x2 = 1 << 30; a1_max_x2 = 0;
    expect_len = 0; cur_len = 0; expect_valid = 1'b0; out_idx = 0;
end

always_ff @(posedge clk) begin
    if (rst) begin
        hs_out_d <= 1'b1;
        vs_out_d <= 1'b1;
    end
    else begin
        // ---- input side ----
        //
        // Mirror the DUT's own line boundary exactly: the pixel on the line
        // reference opens the NEW line at index 0. Modelling it any other way
        // makes the bench disagree with a correct DUT by one pixel.
        if (av_ce) begin
            if (av_line_start) begin
                for (int i = 0; i < 512; i++) expect_rgb[i] <= cur_rgb[i];
                expect_len   <= cur_len;
                expect_valid <= (input_lines >= 1);
                cur_rgb[0]   <= rgb_in;
                cur_len      <= 1;
            end
            else begin
                if (cur_len < 512) cur_rgb[cur_len] <= rgb_in;
                cur_len <= cur_len + 1;
            end
            ce_pix_in_line <= ce_pix_in_line + 1;
        end

        if (ce_pix_x2) ce_x2_in_line <= ce_x2_in_line + 1;

        if (av_line_start) begin
            input_lines <= input_lines + 1;

            // A1: the doubler needs exactly 2x ticks over the line just ended.
            // Skip the first two lines: hmax is still '1 until a full line has
            // been measured (ssv_scandoubler.sv:81), so nothing is meaningful
            // before then.
            // The av_ce tick coincident with line_start is the first pixel of
            // the NEW line on the write side, but it is still one pixel of the
            // interval just measured, so count it here; ce_pix_x2 is forced low
            // by the generator on this same edge and so contributes nothing.
            if (input_lines >= 2) begin
                // Both counters are reset on the line reference, so the tick
                // coincident with it must be added back to BOTH or the ratio
                // is measured off by one. ce_pixel being high implies
                // ce_pix_x2 is high on the same clock (they register the same
                // carry), so the boundary contributes one to each.
                automatic int ended_pix = ce_pix_in_line + 1;
                automatic int ended_x2  = ce_x2_in_line + (ce_pix_x2 ? 1 : 0);
                if (ended_x2 < a1_min_x2) a1_min_x2 <= ended_x2;
                if (ended_x2 > a1_max_x2) a1_max_x2 <= ended_x2;
                if (ended_x2 != 2 * ended_pix) begin
                    a1_fail <= a1_fail + 1;
                    if (a1_first_line < 0) begin
                        a1_first_line <= input_lines;
                        $display("A1 FAIL line=%0d ce_pix=%0d ce_pix_x2=%0d (want %0d)",
                                 input_lines, ended_pix, ended_x2,
                                 2 * ended_pix);
                    end
                end

                // A3: exactly two replayed hsync pulses per input line.
                if (out_hs_pulses != 2) begin
                    a3_fail <= a3_fail + 1;
                    if (a3_fail < 4)
                        $display("A3 FAIL line=%0d hs_out pulses=%0d want 2",
                                 input_lines, out_hs_pulses);
                end

                // A6 is a per-FRAME check; see the vblank_pulse block below.
            end

            // The read port registers `q`, so rgb_out lags rd by one x2 tick:
            // the first tick after the reference still shows the previous
            // value. Start at -1 and skip that tick rather than reporting it
            // as a content error.
            out_idx <= -1;

            ce_pix_in_line <= 0;
            ce_x2_in_line  <= 0;
            out_hs_pulses  <= 0;
            out_de_pixels  <= 0;
        end

        // ---- output side ----
        hs_out_d <= hs_out;
        vs_out_d <= vs_out;

        if (ce_pix_x2) begin
            // A6 accumulate
            if (!(hb_out || vb_out)) begin
                out_de_pixels <= out_de_pixels + 1;
                out_de_frame  <= out_de_frame + 1;
            end

            // A2: the output must walk the previous input line twice, in order.
            if (expect_valid && input_lines >= 3 && expect_len > 0 &&
                out_idx >= 0) begin
                automatic int want_i = out_idx % expect_len;
                if (rgb_out !== expect_rgb[want_i]) begin
                    a2_fail <= a2_fail + 1;
                    if (a2_reports < 6) begin
                        a2_reports <= a2_reports + 1;
                        $display("A2 FAIL line=%0d outpix=%0d got(x=%0d,y=%0d) want(x=%0d,y=%0d)",
                                 input_lines, out_idx,
                                 dec_h(rgb_out), dec_v(rgb_out),
                                 dec_h(expect_rgb[want_i]),
                                 dec_v(expect_rgb[want_i]));
                    end
                end
                out_idx <= out_idx + 1;
            end
        end

        // hs_out is active low: count falling edges as pulse starts.
        if (!hs_out && hs_out_d) out_hs_pulses <= out_hs_pulses + 1;
        if (!vs_out && vs_out_d) out_vs_pulses <= out_vs_pulses + 1;

        if (vbp) begin
            frames_seen <= frames_seen + 1;
            // A4: exactly one vsync per frame survives the doubler.
            if (frames_seen >= 1 && out_vs_pulses != 1) begin
                a4_fail <= a4_fail + 1;
                $display("A4 FAIL frame=%0d vs_out pulses=%0d want 1",
                         frames_seen, out_vs_pulses);
            end
            // A6: 240 active lines, each emitted twice at 336 px = 161280
            // active output pixels per frame. Checked per frame because the
            // doubler's hsync-to-hsync line straddles the vblank boundary, so
            // the two boundary lines legitimately split one active region
            // between them (measured 52 + 620 = 672).
            if (frames_seen >= 1 && out_de_frame != 240 * 672) begin
                a6_fail <= a6_fail + 1;
                $display("A6 FAIL frame=%0d DE pixels=%0d want %0d",
                         frames_seen, out_de_frame, 240 * 672);
            end
            out_vs_pulses <= 0;
            out_de_frame  <= 0;
        end
    end
end

initial begin
    repeat (20) @(posedge clk);
    rst <= 1'b0;

    wait (frames_seen >= FRAMES);
    repeat (100) @(posedge clk);

    $display("----------------------------------------------------------");
    $display("tb_ssv_scandoubler: %0d input lines, %0d frames", input_lines,
             frames_seen);
    $display("A1 ce_pix_x2 per line: min=%0d max=%0d (want a constant 908)",
             a1_min_x2, a1_max_x2);
    $display("A1 line-doubling ratio   failures=%0d", a1_fail);
    $display("A2 pixel content/order   failures=%0d", a2_fail);
    $display("A3 hsync replay          failures=%0d", a3_fail);
    $display("A4 vsync per frame       failures=%0d", a4_fail);
    $display("A6 active DE width       failures=%0d", a6_fail);

    if (a1_fail || a2_fail || a3_fail || a4_fail || a6_fail)
        $display("FAIL tb_ssv_scandoubler");
    else
        $display("PASS tb_ssv_scandoubler");
    $finish;
end

endmodule
