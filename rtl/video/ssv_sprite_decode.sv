// SPDX-License-Identifier: GPL-3.0-or-later
// SSV global/local sprite descriptor decode, following MAME's ssv_v.cpp.
`timescale 1ns/1ps

// Attribute bit 9 and local-Y bits 15:12 are documented but not decoded.
/* verilator lint_off UNUSEDSIGNAL */
module ssv_sprite_decode (
    input  logic [15:0] global_mode,
    input  logic [15:0] local_code,
    input  logic [15:0] local_attr,
    input  logic [15:0] local_x,
    input  logic [15:0] local_y,
    input  logic        use_local_size,

    output logic  [5:0] local_count,
    output logic  [3:0] scroll_word,
    output logic        is_tilemap,
    output logic  [2:0] tilemap_scroll,
    output logic [19:0] tile_code,
    output logic  [8:0] color,
    output logic        flip_x,
    output logic        flip_y,
    output logic  [2:0] gfx_mode,
    output logic        shadow,
    output logic  [3:0] x_tiles,
    output logic  [3:0] y_tiles,
    output logic signed [10:0] x_pos,
    output logic signed [10:0] y_pos
);

logic [1:0] x_size_code;
logic [1:0] y_size_code;
logic [3:0] depth;
logic [3:0] high_code_scrambled;

always_comb begin
    local_count = {1'b0, global_mode[4:0]} + 6'd1;
    scroll_word = {global_mode[7:5], 1'b0};

    x_size_code = use_local_size ? local_x[11:10] : global_mode[11:10];
    y_size_code = use_local_size ? local_y[11:10] : global_mode[9:8];
    depth       = use_local_size ? local_x[15:12] : global_mode[15:12];

    x_tiles = 4'd1 << x_size_code;
    y_tiles = 4'd1 << y_size_code;

    is_tilemap     = (local_code <= 16'd7) && (local_attr == 16'd0) &&
                     (x_size_code == 2'd0) && (y_size_code == 2'd3);
    tilemap_scroll = local_code[2:0];

    // init_ssv uses bitswap<4>(index, 0,1,2,3) for the ROM address nibble.
    high_code_scrambled = {
        local_attr[10], local_attr[11], local_attr[12], local_attr[13]
    };
    tile_code = {high_code_scrambled, local_code};

    color    = local_attr[8:0];
    flip_x   = local_attr[15];
    flip_y   = local_attr[14];
    gfx_mode = depth[2:0];
    shadow   = depth[3];

    x_pos = $signed({local_x[9], local_x[9:0]});
    y_pos = $signed({local_y[9], local_y[9:0]});
end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
