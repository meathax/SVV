// SPDX-License-Identifier: GPL-3.0-or-later
// Vblank-cached scanline renderer for SSV normal sprites.
`timescale 1ns/1ps

module ssv_cached_sprite_renderer #(
    parameter integer CACHE_ENTRIES = 2048
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         cache_start,
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
    output logic  [24:3] rom_addr,
    input  logic  [63:0] rom_data,
    input  logic         rom_ack,

    output logic         plot_we,
    output logic   [8:0] plot_x,
    output logic  [14:0] plot_color,
    output logic         plot_shadow,
    output logic   [7:0] plot_pen,
    output logic         plot_shadow_4bit,

    output logic         cache_busy,
    output logic         cache_ready,
    output logic         cache_overflow,
    output logic         busy,
    output logic         done
);

localparam logic [11:0] LAST_GLOBAL = 12'hffc;
localparam logic [16:0] LAST_LOCAL  = 17'h1fffc;
localparam logic  [8:0] LAST_PIXEL  = 9'd335;
localparam integer CACHE_ADDR_WIDTH = $clog2(CACHE_ENTRIES);
localparam logic [CACHE_ADDR_WIDTH:0] CACHE_COUNT_VALUE = CACHE_ENTRIES;
localparam logic [CACHE_ADDR_WIDTH:0] CACHE_LAST_VALUE =
    CACHE_ENTRIES - 1;
localparam integer LINE_SLOTS = 64;
localparam integer LINE_SLOT_WIDTH = $clog2(LINE_SLOTS);
localparam integer LINE_COUNT_WIDTH = LINE_SLOT_WIDTH + 1;
localparam integer LINE_ADDR_WIDTH = 8 + LINE_SLOT_WIDTH;
localparam logic [LINE_COUNT_WIDTH-1:0] LINE_SLOTS_VALUE = LINE_SLOTS;

typedef enum logic [4:0] {
    IDLE,
    BUILD_CLEAR_LINES,
    BUILD_GLOBAL_WAIT, BUILD_GLOBAL_0, BUILD_GLOBAL_1,
    BUILD_GLOBAL_2, BUILD_GLOBAL_3,
    BUILD_LOCAL_WAIT, BUILD_LOCAL_0, BUILD_LOCAL_1,
    BUILD_LOCAL_2, BUILD_LOCAL_3, BUILD_STORE,
    BUILD_BUCKET_READ, BUILD_BUCKET_WRITE, BUILD_ADVANCE,
    RENDER_COUNT_READ, RENDER_COUNT_WAIT,
    RENDER_LINE_READ, RENDER_READ, RENDER_PREP,
    FETCH_START, FETCH_WAIT, PLOT
} state_t;
state_t state;

logic [11:0] global_base;
logic [16:0] local_base;
logic  [4:0] local_index;
logic [15:0] global_w0, global_w1, global_w2, global_w3;
logic [15:0] local_w0, local_w1, local_w2, local_w3;

logic [CACHE_ADDR_WIDTH:0] cache_write_count;
logic [CACHE_ADDR_WIDTH:0] cache_count;
logic [CACHE_ADDR_WIDTH-1:0] cache_read_index;
logic [CACHE_ADDR_WIDTH:0] cache_render_index;
logic [111:0] cache_q;
logic cache_pending;
(* ramstyle = "M10K, no_rw_check" *)
logic [111:0] descriptor_cache [0:CACHE_ENTRIES-1];

(* ramstyle = "M10K, no_rw_check" *)
logic [LINE_COUNT_WIDTH-1:0] line_counts [0:239];
logic [7:0] line_count_addr;
logic [LINE_COUNT_WIDTH-1:0] line_count_q;
(* ramstyle = "M10K, no_rw_check" *)
logic [CACHE_ADDR_WIDTH-1:0] line_entries [0:240*LINE_SLOTS-1];
logic [7:0] clear_y;
logic [7:0] bucket_y, bucket_last_y;
logic [CACHE_ADDR_WIDTH-1:0] bucket_descriptor;
logic [LINE_ADDR_WIDTH-1:0] line_entry_addr;
logic [CACHE_ADDR_WIDTH-1:0] line_entry_q;
logic [LINE_COUNT_WIDTH-1:0] render_line_count;
logic [LINE_COUNT_WIDTH-1:0] render_line_slot;
logic [7:0] build_first_y, build_last_y;


logic  [8:0] target_y_latched;
logic [19:0] sprite_code;
logic  [3:0] sprite_xnum;
logic  [3:0] sprite_ynum;
logic  [3:0] sprite_tile_x;
logic  [3:0] sprite_tile_y;
logic signed [16:0] sprite_sx;
logic  [2:0] sprite_row;
logic  [2:0] gfx_mode;
logic        flip_x;
logic        flip_y;
logic        shadow;
logic  [8:0] color;
logic  [4:0] plot_i;

logic        fetch_start;
logic        fetch_done;
logic [19:0] fetch_code;
logic  [2:0] fetch_row;
logic [31:0] plane01, plane23, plane45, plane67;
logic [127:0] pens;

wire [15:0] cached_g0 = cache_q[111:96];
wire [15:0] cached_g2 = cache_q[95:80];
wire [15:0] cached_g3 = cache_q[79:64];
wire [15:0] cached_l0 = cache_q[63:48];
wire [15:0] cached_l1 = cache_q[47:32];
wire [15:0] cached_l2 = cache_q[31:16];
wire [15:0] cached_l3 = cache_q[15:0];

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

wire [3:0] cached_offset_index = {cached_g0[7:5], 1'b0};
wire [15:0] selected_offset_x =
    offset_word(sprite_offsets, cached_offset_index);
wire [15:0] selected_offset_y =
    offset_word(sprite_offsets, cached_offset_index + 1'd1);

wire [3:0] build_offset_index = {global_w0[7:5], 1'b0};
wire [15:0] build_offset_x =
    offset_word(sprite_offsets, build_offset_index);
wire [15:0] build_offset_y =
    offset_word(sprite_offsets, build_offset_index + 1'd1);
logic [1:0] build_xbits, build_ybits;
logic [3:0] build_xnum, build_ynum;
logic [6:0] build_height;
logic build_tilemap;
logic build_screen_visible;
logic signed [16:0] build_sx;
logic signed [16:0] build_sy;
logic signed [16:0] build_sx_work;
logic signed [16:0] build_sy_work;
logic signed [16:0] build_offsx;
logic signed [16:0] build_offsy;
logic signed [17:0] build_right;
logic signed [17:0] build_bottom;

always_comb begin
    logic signed [16:0] sx_work;
    logic signed [16:0] sy_work;
    logic signed [16:0] sprites_offsx;
    logic signed [16:0] sprites_offsy;

    calc_xbits = local_control[14] ? cached_l2[11:10]
                                   : cached_g0[11:10];
    calc_ybits = local_control[14] ? cached_l3[11:10]
                                   : cached_g0[9:8];
    calc_depth = local_control[14] ? cached_l2[15:12]
                                   : cached_g0[15:12];
    calc_xnum = 4'd1 << calc_xbits;
    calc_ynum = 4'd1 << calc_ybits;
    calc_tilemap = (cached_l0 <= 16'd7) && (cached_l1 == 16'd0) &&
                   (calc_xbits == 2'd0) && (calc_ybits == 2'd3);

    calc_code = expand_code(cached_l0, cached_l1);
    if ((calc_xnum == 4'd2) && (calc_ynum == 4'd4))
        calc_code = calc_code & 20'hffff8;

    calc_flip_x = cached_l1[15] ^
                  (flip_control[12] && !flip_control[13]);
    calc_flip_y = cached_l1[14] ^
                  (flip_control[14] && !flip_control[13]);

    sx_work = signed10(cached_l2 + cached_g2 + selected_offset_x);
    sy_work = signed10(cached_l3 + cached_g3 + selected_offset_y);
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

always_comb begin
    build_xbits = local_control[14] ? local_w2[11:10]
                                    : global_w0[11:10];
    build_ybits = local_control[14] ? local_w3[11:10]
                                    : global_w0[9:8];
    build_xnum = 4'd1 << build_xbits;
    build_ynum = 4'd1 << build_ybits;
    build_height = {build_ynum, 3'd0};
    build_tilemap = (local_w0 <= 16'd7) && (local_w1 == 16'd0) &&
                    (build_xbits == 2'd0) && (build_ybits == 2'd3);

    build_sx_work = signed10(local_w2 + global_w2 + build_offset_x);
    build_sy_work = signed10(local_w3 + global_w3 + build_offset_y);
    build_offsx = signed8(flip_control);
    build_offsy = -(signed10(global_y_base) +
                    $signed({1'b0, global_y_adjust}) + 17'sd1);

    if (flip_control[14]) begin
        build_sy_work = -build_sy_work;
        if (!flip_control[15])
            build_sy_work = build_sy_work - 17'sd16;
    end
    if (flip_control[12])
        build_sx_work = -build_sx_work + 17'sd256;

    if (coordinate_control == 16'h7140) begin
        build_sx = build_offsx + build_sx_work;
        build_sy = build_offsy - build_sy_work;
    end
    else if (coordinate_control[11]) begin
        build_sx = build_offsx + build_sx_work -
                   $signed({9'd0, build_xnum, 3'd0});
        build_sy = build_offsy - build_sy_work -
                   $signed({10'd0, build_ynum, 2'd0});
    end
    else begin
        build_sx = build_offsx + build_sx_work;
        build_sy = build_offsy - build_sy_work -
                   $signed({9'd0, build_ynum, 3'd0});
    end

    build_right = build_sx + $signed({1'b0, build_xnum, 4'd0});
    build_bottom = build_sy + $signed({1'b0, build_height});
    if (build_sy < 0)
        build_first_y = 8'd0;
    else
        build_first_y = build_sy[7:0];
    build_last_y = (build_bottom > 18'sd240) ? 8'd239 :
                   build_bottom[7:0] - 1'd1;
    build_screen_visible = !build_tilemap &&
                           (build_sx < 17'sd336) &&
                           (build_right > 18'sd0) &&
                           (build_sy < 17'sd240) &&
                           (build_bottom > 18'sd0);
end

wire cache_we = (state == BUILD_STORE) &&
                build_screen_visible &&
                (cache_write_count < CACHE_COUNT_VALUE);
wire [111:0] cache_write_data = {
    global_w0, global_w2, global_w3,
    local_w0, local_w1, local_w2, local_w3
};

always_ff @(posedge clk) begin
    line_count_q <= line_counts[line_count_addr];
    if (state == BUILD_CLEAR_LINES)
        line_counts[line_count_addr] <= '0;
    else if ((state == BUILD_BUCKET_WRITE) &&
             (line_count_q < LINE_SLOTS_VALUE))
        line_counts[line_count_addr] <= line_count_q + 1'd1;

    if (state == RENDER_LINE_READ)
        line_entry_q <= line_entries[line_entry_addr];
    if (state == RENDER_READ)
        cache_q <= descriptor_cache[line_entry_q];
    if (cache_we)
        descriptor_cache[cache_write_count[CACHE_ADDR_WIDTH-1:0]]
            <= cache_write_data;
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
        BUILD_GLOBAL_0: spr_addr = {5'd0, global_base} + 1'd1;
        BUILD_GLOBAL_1: spr_addr = {5'd0, global_base} + 2'd2;
        BUILD_GLOBAL_2: spr_addr = {5'd0, global_base} + 2'd3;
        BUILD_LOCAL_WAIT: spr_addr = local_base;
        BUILD_LOCAL_0: spr_addr = local_base + 1'd1;
        BUILD_LOCAL_1: spr_addr = local_base + 2'd2;
        BUILD_LOCAL_2: spr_addr = local_base + 2'd3;
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
        cache_write_count <= '0;
        cache_count <= '0;
        cache_read_index <= '0;
        cache_render_index <= '0;
        cache_busy <= 1'b0;
        cache_ready <= 1'b0;
        cache_overflow <= 1'b0;
        cache_pending <= 1'b0;
        clear_y <= 8'd0;
        line_count_addr <= 8'd0;
        bucket_y <= 8'd0;
        bucket_last_y <= 8'd0;
        bucket_descriptor <= '0;
        line_entry_addr <= '0;
        render_line_count <= '0;
        render_line_slot <= '0;
        target_y_latched <= 9'd0;
        sprite_code <= 20'd0;
        sprite_xnum <= 4'd0;
        sprite_ynum <= 4'd0;
        sprite_tile_x <= 4'd0;
        sprite_tile_y <= 4'd0;
        sprite_sx <= 17'sd0;
        sprite_row <= 3'd0;
        gfx_mode <= 3'd0;
        flip_x <= 1'b0;
        flip_y <= 1'b0;
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
        if (cache_start)
            cache_pending <= 1'b1;
        unique case (state)
            IDLE: begin
                busy <= 1'b0;
                cache_busy <= 1'b0;
                if (cache_start || cache_pending) begin
                    clear_y <= 8'd0;
                    line_count_addr <= 8'd0;
                    cache_write_count <= '0;
                    cache_ready <= 1'b0;
                    cache_overflow <= 1'b0;
                    cache_busy <= 1'b1;
                    cache_pending <= 1'b0;
                    state <= BUILD_CLEAR_LINES;
                end
                else if (start) begin
                    if (cache_ready) begin
                        target_y_latched <= target_y;
                        cache_render_index <= '0;
                        line_count_addr <= target_y[7:0];
                        busy <= 1'b1;
                        state <= RENDER_COUNT_READ;
                    end
                    else begin
                        done <= 1'b1;
                    end
                end
            end


            BUILD_CLEAR_LINES: begin
                if (clear_y == 8'd239) begin
                    global_base <= 12'd0;
                    state <= BUILD_GLOBAL_WAIT;
                end
                else begin
                    clear_y <= clear_y + 1'd1;
                    line_count_addr <= line_count_addr + 1'd1;
                end
            end

            BUILD_GLOBAL_WAIT: state <= BUILD_GLOBAL_0;
            BUILD_GLOBAL_0: begin
                global_w0 <= spr_data;
                state <= BUILD_GLOBAL_1;
            end
            BUILD_GLOBAL_1: begin
                global_w1 <= spr_data;
                state <= BUILD_GLOBAL_2;
            end
            BUILD_GLOBAL_2: begin
                global_w2 <= spr_data;
                state <= BUILD_GLOBAL_3;
            end
            BUILD_GLOBAL_3: begin
                global_w3 <= spr_data;
                if (global_w1[15]) begin
                    cache_count <= cache_write_count;
                    cache_ready <= 1'b1;
                    cache_busy <= 1'b0;
                    state <= IDLE;
                end
                else begin
                    local_base <= {global_w1[14:0], 2'b00};
                    local_index <= 5'd0;
                    state <= BUILD_LOCAL_WAIT;
                end
            end

            BUILD_LOCAL_WAIT: state <= BUILD_LOCAL_0;
            BUILD_LOCAL_0: begin
                local_w0 <= spr_data;
                state <= BUILD_LOCAL_1;
            end
            BUILD_LOCAL_1: begin
                local_w1 <= spr_data;
                state <= BUILD_LOCAL_2;
            end
            BUILD_LOCAL_2: begin
                local_w2 <= spr_data;
                state <= BUILD_LOCAL_3;
            end
            BUILD_LOCAL_3: begin
                local_w3 <= spr_data;
                state <= BUILD_STORE;
            end

            BUILD_STORE: begin
                if (build_screen_visible) begin
                    if (cache_write_count == CACHE_LAST_VALUE) begin
                        cache_write_count <= cache_write_count + 1'd1;
                        cache_count <= CACHE_COUNT_VALUE;
                        cache_ready <= 1'b1;
                        cache_overflow <= 1'b1;
                        cache_busy <= 1'b0;
                        state <= IDLE;
                    end
                    else begin
                        cache_write_count <= cache_write_count + 1'd1;
                        bucket_descriptor <=
                            cache_write_count[CACHE_ADDR_WIDTH-1:0];
                        bucket_y <= build_first_y;
                        bucket_last_y <= build_last_y;
                        line_count_addr <= build_first_y;
                        state <= BUILD_BUCKET_READ;
                    end
                end
                else begin
                    state <= BUILD_ADVANCE;
                end
            end

            BUILD_BUCKET_READ: state <= BUILD_BUCKET_WRITE;

            BUILD_BUCKET_WRITE: begin
                if (line_count_q < LINE_SLOTS_VALUE) begin
                    line_entries[
                        {bucket_y, {LINE_SLOT_WIDTH{1'b0}}} +
                        line_count_q[LINE_SLOT_WIDTH-1:0]
                    ] <= bucket_descriptor;
                end
                else begin
                    cache_overflow <= 1'b1;
                end
                if (bucket_y == bucket_last_y)
                    state <= BUILD_ADVANCE;
                else begin
                    bucket_y <= bucket_y + 1'd1;
                    line_count_addr <= line_count_addr + 1'd1;
                    state <= BUILD_BUCKET_READ;
                end
            end


            BUILD_ADVANCE: begin
                if ((local_index < global_w0[4:0]) &&
                    ((local_base + 17'd4) <= LAST_LOCAL)) begin
                    local_index <= local_index + 1'd1;
                    local_base <= local_base + 3'd4;
                    state <= BUILD_LOCAL_WAIT;
                end
                else if (global_base < LAST_GLOBAL) begin
                    global_base <= global_base + 3'd4;
                    state <= BUILD_GLOBAL_WAIT;
                end
                else begin
                    cache_count <= cache_write_count;
                    cache_ready <= 1'b1;
                    cache_busy <= 1'b0;
                    state <= IDLE;
                end
            end

            RENDER_COUNT_READ: state <= RENDER_COUNT_WAIT;

            RENDER_COUNT_WAIT: begin
                if (line_count_q != 0) begin
                    render_line_count <= line_count_q;
                    render_line_slot <= '0;
                    line_entry_addr <= {
                        target_y_latched[7:0],
                        {LINE_SLOT_WIDTH{1'b0}}
                    };
                    state <= RENDER_LINE_READ;
                end
                else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
            end

            RENDER_LINE_READ: state <= RENDER_READ;

            RENDER_READ: begin
                cache_read_index <= line_entry_q;
                cache_render_index <= line_entry_q;
                state <= RENDER_PREP;
            end
            RENDER_PREP: begin
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
                    flip_y <= calc_flip_y;
                    shadow <= calc_depth[3];
                    color <= cached_l1[8:0];
                    fetch_code <= code_for_tile(
                        calc_code, 4'd0, calc_tile_y,
                        calc_xnum, calc_ynum,
                        calc_flip_x, calc_flip_y
                    );
                    fetch_row <= calc_row;
                    state <= FETCH_START;
                end
                else if (render_line_slot + 1'd1 < render_line_count) begin
                    render_line_slot <= render_line_slot + 1'd1;
                    line_entry_addr <= line_entry_addr + 1'd1;
                    state <= RENDER_LINE_READ;
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
                            flip_x, flip_y
                        );
                        fetch_row <= sprite_row;
                        state <= FETCH_START;
                    end
                    else if (render_line_slot + 1'd1 < render_line_count) begin
                        render_line_slot <= render_line_slot + 1'd1;
                        line_entry_addr <= line_entry_addr + 1'd1;
                        state <= RENDER_LINE_READ;
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
