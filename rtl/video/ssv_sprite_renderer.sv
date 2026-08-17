// SPDX-License-Identifier: GPL-3.0-or-later
// Scanline renderer for SSV normal sprites (global list + local descriptors).
`timescale 1ns/1ps

module ssv_sprite_renderer (
    input  logic         clk,
    input  logic         rst,
    input  logic         start,
    input  logic   [8:0] target_y,

    input  logic  [15:0] local_control,
    input  logic  [15:0] flip_control,
    input  logic  [15:0] coordinate_control,
    input  logic  [15:0] global_y_base,
    input  logic  [15:0] global_y_adjust,
    input  logic [255:0] sprite_offsets,
    input  logic         shadow_4bit,

    output logic  [16:0] spr_addr,
    input  logic  [15:0] spr_data,

    output logic         rom_req,
    output logic  [24:4] rom_addr,
    input  logic [127:0] rom_data,
    input  logic         rom_ack,

    output logic         plot_we,
    output logic   [8:0] plot_x,
    output logic  [14:0] plot_color,
    output logic         plot_shadow,
    output logic   [7:0] plot_pen,
    output logic         plot_shadow_4bit,

    output logic         busy,
    output logic         done
);

localparam logic [11:0] LAST_GLOBAL = 12'hffc;
localparam logic [16:0] LAST_LOCAL  = 17'h1fffc;
localparam logic  [8:0] LAST_PIXEL  = 9'd335;

typedef enum logic [4:0] {
    IDLE,
    GLOBAL_WAIT, GLOBAL_0, GLOBAL_1, GLOBAL_2, GLOBAL_3,
    LOCAL_WAIT, LOCAL_0, LOCAL_1, LOCAL_2, LOCAL_3,
    PREP,
    FETCH_START, FETCH_WAIT, PLOT
} state_t;
state_t state;

logic  [8:0] target_y_latched;
logic [11:0] global_base;
logic [16:0] local_base;
logic  [4:0] local_index;
logic [15:0] global_w0, global_w1, global_w2, global_w3;
logic [15:0] local_w0, local_w1, local_w2, local_w3;
logic        local_cache_valid;
logic [16:0] local_cache_base;
logic [15:0] local_cache_w0;
logic [15:0] local_cache_w1;
logic [15:0] local_cache_w2;
logic [15:0] local_cache_w3;

logic [19:0] sprite_code;
logic  [3:0] sprite_xnum;
logic  [3:0] sprite_ynum;
logic  [3:0] sprite_tile_x;
logic  [3:0] sprite_tile_y;
logic signed [16:0] sprite_sx;
logic  [2:0] sprite_row;
logic  [2:0] gfx_mode;
logic        flip_x;
logic        shadow;
logic  [8:0] color;
logic  [4:0] plot_i;

logic        fetch_start;
logic        fetch_done;
logic [19:0] fetch_code;
logic  [2:0] fetch_row;
logic [31:0] plane01, plane23, plane45, plane67;
logic [127:0] pens;

logic  [1:0] calc_xbits, calc_ybits;
logic  [3:0] calc_xnum, calc_ynum;
logic  [3:0] calc_depth;
logic [19:0] calc_code;
logic        calc_flip_x, calc_flip_y;
logic signed [16:0] calc_sx, calc_sy;
logic signed [17:0] calc_line_rel;
logic  [6:0] calc_height;
logic        calc_tilemap;
logic  [3:0] calc_tile_y;
logic  [2:0] calc_row;

function automatic logic signed [10:0] signed10(input logic [15:0] value);
    signed10 = $signed({value[9], value[9:0]});
endfunction

function automatic logic signed [8:0] signed8(input logic [15:0] value);
    signed8 = $signed({value[7], value[7:0]});
endfunction

function automatic logic [19:0] expand_code(
    input logic [15:0] low,
    input logic [15:0] attr
);
    expand_code = {{attr[10], attr[11], attr[12], attr[13]}, low};
endfunction

function automatic logic [15:0] offset_word(
    input logic [255:0] values,
    input logic   [3:0] index
);
    begin
        case (index)
            4'h0: offset_word = values[15:0];
            4'h1: offset_word = values[31:16];
            4'h2: offset_word = values[47:32];
            4'h3: offset_word = values[63:48];
            4'h4: offset_word = values[79:64];
            4'h5: offset_word = values[95:80];
            4'h6: offset_word = values[111:96];
            4'h7: offset_word = values[127:112];
            4'h8: offset_word = values[143:128];
            4'h9: offset_word = values[159:144];
            4'ha: offset_word = values[175:160];
            4'hb: offset_word = values[191:176];
            4'hc: offset_word = values[207:192];
            4'hd: offset_word = values[223:208];
            4'he: offset_word = values[239:224];
            default: offset_word = values[255:240];
        endcase
    end
endfunction

function automatic logic [19:0] code_for_tile(
    input logic [19:0] base,
    input logic  [3:0] tile_x,
    input logic  [3:0] tile_y,
    input logic  [3:0] xnum,
    input logic  [3:0] ynum,
    input logic        fx,
    input logic        fy
);
    logic [3:0] order_x;
    logic [3:0] order_y;
    logic [7:0] offset;
    begin
        order_x = fx ? (xnum - 1'd1 - tile_x) : tile_x;
        order_y = fy ? (ynum - 1'd1 - tile_y) : tile_y;
        offset = order_x * ynum + order_y;
        code_for_tile = base + offset;
    end
endfunction

wire [3:0] global_offset_index = {global_w0[7:5], 1'b0};
wire [15:0] selected_offset_x =
    offset_word(sprite_offsets, global_offset_index);
wire [15:0] selected_offset_y =
    offset_word(sprite_offsets, global_offset_index + 1'd1);

always_comb begin
    logic signed [16:0] sx_work;
    logic signed [16:0] sy_work;
    logic signed [16:0] sprites_offsx;
    logic signed [16:0] sprites_offsy;

    calc_xbits = local_control[14] ? local_w2[11:10]
                                   : global_w0[11:10];
    calc_ybits = local_control[14] ? local_w3[11:10]
                                   : global_w0[9:8];
    calc_depth = local_control[14] ? local_w2[15:12]
                                   : global_w0[15:12];
    calc_xnum = 4'd1 << calc_xbits;
    calc_ynum = 4'd1 << calc_ybits;
    calc_tilemap = (local_w0 <= 16'd7) && (local_w1 == 16'd0) &&
                   (calc_xbits == 2'd0) && (calc_ybits == 2'd3);

    calc_code = expand_code(local_w0, local_w1);
    if ((calc_xnum == 4'd2) && (calc_ynum == 4'd4))
        calc_code = calc_code & 20'hffff8;

    calc_flip_x = local_w1[15] ^
                  (flip_control[12] && !flip_control[13]);
    calc_flip_y = local_w1[14] ^
                  (flip_control[14] && !flip_control[13]);

    sx_work = signed10(local_w2 + global_w2 + selected_offset_x);
    sy_work = signed10(local_w3 + global_w3 + selected_offset_y);
    sprites_offsx = signed8(flip_control);
    sprites_offsy = -(signed10(global_y_base) +
                      $signed({1'b0, global_y_adjust}) + 17'sd1);

    if (flip_control[14]) begin
        sy_work = -sy_work;
        if (!flip_control[15])
            sy_work = sy_work - 17'sd16;
    end
    if (flip_control[12])
        sx_work = -sx_work + 17'sd256;

    if (coordinate_control == 16'h7140) begin
        calc_sx = sprites_offsx + sx_work;
        calc_sy = sprites_offsy - sy_work;
    end
    else if (coordinate_control[11]) begin
        calc_sx = sprites_offsx + sx_work -
                  $signed({9'd0, calc_xnum, 3'd0});
        calc_sy = sprites_offsy - sy_work -
                  $signed({10'd0, calc_ynum, 2'd0});
    end
    else begin
        calc_sx = sprites_offsx + sx_work;
        calc_sy = sprites_offsy - sy_work -
                  $signed({9'd0, calc_ynum, 3'd0});
    end

    calc_line_rel = $signed({1'b0, target_y_latched}) - calc_sy;
    calc_height = {calc_ynum, 3'd0};
    calc_tile_y = calc_line_rel[6:3];
    calc_row = calc_flip_y ? ~calc_line_rel[2:0]
                           : calc_line_rel[2:0];
end

ssv_gfx_row_fetch fetch (
    .clk(clk), .rst(rst), .start(fetch_start),
    .tile_code(fetch_code), .tile_row(fetch_row),
    .rom_req(rom_req), .rom_addr(rom_addr),
    .rom_data(rom_data), .rom_ack(rom_ack),
    .busy(), .done(fetch_done),
    .plane01(plane01), .plane23(plane23),
    .plane45(plane45), .plane67(plane67)
);

ssv_gfx_row_decode decode (
    .plane01(plane01), .plane23(plane23),
    .plane45(plane45), .plane67(plane67),
    .gfx_mode(gfx_mode), .flip_x(flip_x), .pens(pens)
);

wire [7:0] current_pen = pens[plot_i * 8 +: 8];
wire signed [17:0] current_x =
    sprite_sx + $signed({13'd0, plot_i});
wire current_x_visible =
    (current_x >= 0) && (current_x <= $signed({9'd0, LAST_PIXEL}));

always_comb begin
    spr_addr = {5'd0, global_base};
    unique case (state)
        GLOBAL_0: spr_addr = {5'd0, global_base} + 1'd1;
        GLOBAL_1: spr_addr = {5'd0, global_base} + 2'd2;
        GLOBAL_2: spr_addr = {5'd0, global_base} + 2'd3;
        LOCAL_WAIT: spr_addr = local_base;
        LOCAL_0: spr_addr = local_base + 1'd1;
        LOCAL_1: spr_addr = local_base + 2'd2;
        LOCAL_2: spr_addr = local_base + 2'd3;
        default: ;
    endcase

    fetch_start = (state == FETCH_START);
    plot_we = (state == PLOT) && current_x_visible &&
              (current_pen != 8'd0);
    plot_x = current_x[8:0];
    plot_pen = current_pen;
    plot_color = ({color, 6'd0} + current_pen) & 15'h7fff;
    plot_shadow = shadow;
    plot_shadow_4bit = shadow_4bit;
end

always_ff @(posedge clk) begin
    if (rst) begin
        state <= IDLE;
        target_y_latched <= 9'd0;
        global_base <= 12'd0;
        local_base <= 17'd0;
        local_index <= 5'd0;
        global_w0 <= 16'd0;
        global_w1 <= 16'd0;
        global_w2 <= 16'd0;
        global_w3 <= 16'd0;
        local_w0 <= 16'd0;
        local_w1 <= 16'd0;
        local_w2 <= 16'd0;
        local_w3 <= 16'd0;
        local_cache_valid <= 1'b0;
        local_cache_base <= 17'd0;
        local_cache_w0 <= 16'd0;
        local_cache_w1 <= 16'd0;
        local_cache_w2 <= 16'd0;
        local_cache_w3 <= 16'd0;
        sprite_code <= 20'd0;
        sprite_xnum <= 4'd0;
        sprite_ynum <= 4'd0;
        sprite_tile_x <= 4'd0;
        sprite_tile_y <= 4'd0;
        sprite_sx <= 17'sd0;
        sprite_row <= 3'd0;
        gfx_mode <= 3'd0;
        flip_x <= 1'b0;
        shadow <= 1'b0;
        color <= 9'd0;
        plot_i <= 5'd0;
        fetch_code <= 20'd0;
        fetch_row <= 3'd0;
        busy <= 1'b0;
        done <= 1'b0;
    end
    else begin
        done <= 1'b0;
        unique case (state)
            IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    target_y_latched <= target_y;
                    global_base <= 12'd0;
                    local_cache_valid <= 1'b0;
                    busy <= 1'b1;
                    state <= GLOBAL_WAIT;
                end
            end

            GLOBAL_WAIT: state <= GLOBAL_0;
            GLOBAL_0: begin
                global_w0 <= spr_data;
                state <= GLOBAL_1;
            end
            GLOBAL_1: begin
                global_w1 <= spr_data;
                state <= GLOBAL_2;
            end
            GLOBAL_2: begin
                global_w2 <= spr_data;
                state <= GLOBAL_3;
            end
            GLOBAL_3: begin
                global_w3 <= spr_data;
                if (global_w1[15]) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
                else begin
                    local_base <= {global_w1[14:0], 2'b00};
                    local_index <= 5'd0;
                    if (local_cache_valid &&
                        (local_cache_base == {global_w1[14:0], 2'b00})) begin
                        local_w0 <= local_cache_w0;
                        local_w1 <= local_cache_w1;
                        local_w2 <= local_cache_w2;
                        local_w3 <= local_cache_w3;
                        state <= PREP;
                    end
                    else
                        state <= LOCAL_WAIT;
                end
            end

            LOCAL_WAIT: state <= LOCAL_0;
            LOCAL_0: begin
                local_w0 <= spr_data;
                state <= LOCAL_1;
            end
            LOCAL_1: begin
                local_w1 <= spr_data;
                state <= LOCAL_2;
            end
            LOCAL_2: begin
                local_w2 <= spr_data;
                state <= LOCAL_3;
            end
            LOCAL_3: begin
                local_w3 <= spr_data;
                local_cache_valid <= 1'b1;
                local_cache_base <= local_base;
                local_cache_w0 <= local_w0;
                local_cache_w1 <= local_w1;
                local_cache_w2 <= local_w2;
                local_cache_w3 <= spr_data;
                state <= PREP;
            end

            PREP: begin
                if (!calc_tilemap && (calc_line_rel >= 0) &&
                    (calc_line_rel < $signed({1'b0, calc_height}))) begin
                    sprite_code <= calc_code;
                    sprite_xnum <= calc_xnum;
                    sprite_ynum <= calc_ynum;
                    sprite_tile_x <= 4'd0;
                    sprite_tile_y <= calc_tile_y;
                    sprite_sx <= calc_sx;
                    sprite_row <= calc_row;
                    gfx_mode <= calc_depth[2:0];
                    flip_x <= calc_flip_x;
                    shadow <= calc_depth[3];
                    color <= local_w1[8:0];
                    fetch_code <= code_for_tile(
                        calc_code, 4'd0, calc_tile_y,
                        calc_xnum, calc_ynum,
                        calc_flip_x, calc_flip_y
                    );
                    fetch_row <= calc_row;
                    state <= FETCH_START;
                end
                else if ((local_index < global_w0[4:0]) &&
                         ((local_base + 17'd4) <= LAST_LOCAL)) begin
                    local_index <= local_index + 1'd1;
                    local_base <= local_base + 3'd4;
                    state <= LOCAL_WAIT;
                end
                else if (global_base < LAST_GLOBAL) begin
                    global_base <= global_base + 3'd4;
                    state <= GLOBAL_WAIT;
                end
                else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
            end

            FETCH_START: state <= FETCH_WAIT;
            FETCH_WAIT: begin
                if (fetch_done) begin
                    plot_i <= 5'd0;
                    state <= PLOT;
                end
            end

            PLOT: begin
                if (plot_i == 5'd15) begin
                    if (sprite_tile_x + 1'd1 < sprite_xnum) begin
                        sprite_tile_x <= sprite_tile_x + 1'd1;
                        sprite_sx <= sprite_sx + 17'sd16;
                        fetch_code <= code_for_tile(
                            sprite_code, sprite_tile_x + 1'd1,
                            sprite_tile_y, sprite_xnum, sprite_ynum,
                            flip_x, calc_flip_y
                        );
                        fetch_row <= sprite_row;
                        state <= FETCH_START;
                    end
                    else if ((local_index < global_w0[4:0]) &&
                             ((local_base + 17'd4) <= LAST_LOCAL)) begin
                        local_index <= local_index + 1'd1;
                        local_base <= local_base + 3'd4;
                        state <= LOCAL_WAIT;
                    end
                    else if (global_base < LAST_GLOBAL) begin
                        global_base <= global_base + 3'd4;
                        state <= GLOBAL_WAIT;
                    end
                    else begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
                else begin
                    plot_i <= plot_i + 1'd1;
                end
            end
        endcase
    end
end

endmodule
