// SPDX-License-Identifier: GPL-3.0-or-later
//============================================================================
// ssv_debug_hud: optional on-screen hex readout of a few live counters, for
// diagnosing issues on real MiSTer hardware where no MAME/Verilator
// reference is available. Off by default (enable=0): overlay_active is then
// always 0 and the caller's normal video path is completely unaffected.
//
// Draws up to 5 rows of 4 hex digits each in the top-left corner of the
// active picture, using a small built-in 3x5 pixel font scaled 2x. Row
// contents are supplied by the caller as plain 16-bit words; this module
// has no knowledge of what they mean (see ssv_core.sv's instantiation for
// the current row assignment).
//============================================================================
`timescale 1ns/1ps

module ssv_debug_hud (
    input        [8:0] hcnt,
    input        [8:0] vcnt,
    input               enable,
    input        [15:0] row0,
    input        [15:0] row1,
    input        [15:0] row2,
    input        [15:0] row3,
    input        [15:0] row4,
    output logic        overlay_active,
    output logic [23:0] overlay_rgb
);

localparam int ORIGIN_X = 4;
localparam int ORIGIN_Y = 4;
localparam int GLYPH_W  = 3;
localparam int GLYPH_H  = 5;
localparam int SCALE    = 2;
localparam int CELL_W   = GLYPH_W * SCALE + 2;   // 8 px: glyph + 1px gap either side
localparam int CELL_H   = GLYPH_H * SCALE + 2;   // 12 px: glyph + 1px gap top/bottom
localparam int HUD_W    = CELL_W * 4;            // 4 hex digits/row
localparam int HUD_H    = CELL_H * 5;            // 5 rows

// 3-bit-wide row pattern per hex digit (MSB = leftmost column). Standard
// tiny numeric font; visually verified against the intended glyph shapes.
function automatic [2:0] hex_glyph_row(input [3:0] d, input [2:0] r);
    case (d)
        4'h0: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b101; 3:hex_glyph_row=3'b101; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h1: case (r) 0:hex_glyph_row=3'b010; 1:hex_glyph_row=3'b110; 2:hex_glyph_row=3'b010; 3:hex_glyph_row=3'b010; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h2: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b001; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b100; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h3: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b001; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b001; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h4: case (r) 0:hex_glyph_row=3'b101; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b001; 4:hex_glyph_row=3'b001; default:hex_glyph_row=3'b000; endcase
        4'h5: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b100; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b001; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h6: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b100; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b101; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h7: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b001; 2:hex_glyph_row=3'b001; 3:hex_glyph_row=3'b001; 4:hex_glyph_row=3'b001; default:hex_glyph_row=3'b000; endcase
        4'h8: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b101; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'h9: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b001; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'ha: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b101; 4:hex_glyph_row=3'b101; default:hex_glyph_row=3'b000; endcase
        4'hb: case (r) 0:hex_glyph_row=3'b110; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b110; 3:hex_glyph_row=3'b101; 4:hex_glyph_row=3'b110; default:hex_glyph_row=3'b000; endcase
        4'hc: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b100; 2:hex_glyph_row=3'b100; 3:hex_glyph_row=3'b100; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'hd: case (r) 0:hex_glyph_row=3'b110; 1:hex_glyph_row=3'b101; 2:hex_glyph_row=3'b101; 3:hex_glyph_row=3'b101; 4:hex_glyph_row=3'b110; default:hex_glyph_row=3'b000; endcase
        4'he: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b100; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b100; 4:hex_glyph_row=3'b111; default:hex_glyph_row=3'b000; endcase
        4'hf: case (r) 0:hex_glyph_row=3'b111; 1:hex_glyph_row=3'b100; 2:hex_glyph_row=3'b111; 3:hex_glyph_row=3'b100; 4:hex_glyph_row=3'b100; default:hex_glyph_row=3'b000; endcase
    endcase
endfunction

wire signed [10:0] rel_x = $signed({1'b0, hcnt}) - ORIGIN_X;
wire signed [10:0] rel_y = $signed({1'b0, vcnt}) - ORIGIN_Y;
wire in_box = enable &&
    (rel_x >= 0) && (rel_x < HUD_W) && (rel_y >= 0) && (rel_y < HUD_H);

// Which of the 5 rows / 4 digit cells this pixel falls in, and the pixel's
// position within that cell (small enumerable ranges -- plain compares,
// no divide, to keep this cheap and unambiguous to review).
logic [2:0] row_ix;
logic [1:0] col_ix;
logic [10:0] y_in_row, x_in_cell;
always_comb begin
    row_ix = 3'd0; y_in_row = rel_y[10:0];
    if (rel_y >= CELL_H*4)      begin row_ix = 3'd4; y_in_row = rel_y - CELL_H*4; end
    else if (rel_y >= CELL_H*3) begin row_ix = 3'd3; y_in_row = rel_y - CELL_H*3; end
    else if (rel_y >= CELL_H*2) begin row_ix = 3'd2; y_in_row = rel_y - CELL_H*2; end
    else if (rel_y >= CELL_H*1) begin row_ix = 3'd1; y_in_row = rel_y - CELL_H*1; end

    col_ix = 2'd0; x_in_cell = rel_x[10:0];
    if (rel_x >= CELL_W*3)      begin col_ix = 2'd3; x_in_cell = rel_x - CELL_W*3; end
    else if (rel_x >= CELL_W*2) begin col_ix = 2'd2; x_in_cell = rel_x - CELL_W*2; end
    else if (rel_x >= CELL_W*1) begin col_ix = 2'd1; x_in_cell = rel_x - CELL_W*1; end
end

// 1px border gap on each side of the scaled glyph within its cell.
wire glyph_x_in_range = (x_in_cell >= 1) && (x_in_cell < 1 + GLYPH_W*SCALE);
wire glyph_y_in_range = (y_in_row  >= 1) && (y_in_row  < 1 + GLYPH_H*SCALE);
wire [10:0] glyph_x = (x_in_cell - 1) / SCALE;   // 0..2
wire [10:0] glyph_y = (y_in_row  - 1) / SCALE;   // 0..4

logic [15:0] row_word;
always_comb begin
    case (row_ix)
        3'd0: row_word = row0;
        3'd1: row_word = row1;
        3'd2: row_word = row2;
        3'd3: row_word = row3;
        default: row_word = row4;
    endcase
end

// Most-significant nibble first (col 0), matching normal hex reading order.
logic [3:0] digit;
always_comb begin
    case (col_ix)
        2'd0: digit = row_word[15:12];
        2'd1: digit = row_word[11:8];
        2'd2: digit = row_word[7:4];
        default: digit = row_word[3:0];
    endcase
end

wire [2:0] glyph_row_bits = hex_glyph_row(digit, glyph_y[2:0]);
wire pixel_lit = glyph_x_in_range && glyph_y_in_range &&
    glyph_row_bits[2 - glyph_x[1:0]];

always_comb begin
    overlay_active = in_box;
    // Bright green text on a solid black backing box, for visibility over
    // any game content. The backing box is the full in_box region; the
    // glyph itself is drawn in green, everything else in the box is black.
    overlay_rgb = pixel_lit ? 24'h20FF40 : 24'h000000;
end

endmodule
