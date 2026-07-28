// SPDX-License-Identifier: GPL-3.0-or-later
// Scanline renderer for SSV's automatic scroll-zero background tilemap.
`timescale 1ns/1ps

module ssv_bg_renderer (
    input  logic        clk,
    input  logic        rst,
    input  logic        line_start,
    input  logic  [8:0] target_y,
    input  logic        clear_done,

    input  logic [15:0] scroll_x,
    input  logic [15:0] scroll_y,
    input  logic [15:0] scroll_mode,
    input  logic [15:0] global_y_base,
    input  logic [15:0] global_y_adjust,
    input  logic [15:0] flip_control,
    input  logic        shadow_4bit,

    output logic [16:0] spr_addr,
    input  logic [15:0] spr_data,

    output logic        rom_req,
    output logic [24:3] rom_addr,
    input  logic [63:0] rom_data,
    input  logic        rom_ack,

    output logic  [3:0] plot_we,
    output logic [35:0] plot_x,
    output logic [59:0] plot_color,
    output logic        plot_shadow,
    output logic [31:0] plot_pen,
    output logic        plot_shadow_4bit,

    output logic        busy,
    output logic        done
);

localparam logic [8:0] LAST_PIXEL = 9'd335;

typedef enum logic [4:0] {
    IDLE, WAIT_CLEAR, ROW_DECIDE,
    ROW_ADDR, ROW_WAIT,
    TILE_CODE_ADDR, TILE_CODE_WAIT,
    TILE_ATTR_ADDR, TILE_ATTR_WAIT,
    TILE_PREP, FETCH_START, FETCH_WAIT, PLOT
} state_t;
state_t state;

logic [8:0] target_y_latched;
logic [16:0] tile_word_addr;
logic [15:0] tile_code_low;
logic [15:0] tile_attr;
logic [19:0] fetch_code;
logic [2:0] fetch_row;
logic [2:0] gfx_mode;
logic flip_x;
logic shadow;
logic [8:0] color;
logic signed [10:0] screen_x;
logic [16:0] map_x;
// Map origin for the current scanline; fixes which page the line reads from.
logic [16:0] map_x0;
logic [16:0] map_y;
logic [4:0] plot_i;

logic fetch_start;
logic fetch_done;
logic [31:0] plane01, plane23, plane45, plane67;
logic [127:0] pens;
logic signed [10:0] global_y_base_s;

function automatic logic [19:0] expand_code(
    input logic [15:0] low,
    input logic [15:0] attr
);
    expand_code = {{attr[10], attr[11], attr[12], attr[13]}, low};
endfunction

function automatic logic signed [10:0] signed10(input logic [15:0] value);
    signed10 = $signed({value[9], value[9:0]});
endfunction

assign global_y_base_s = signed10(global_y_base);

// `x_base` is this scanline's map origin and selects which page (i.e. which
// tilemap) the line reads; `x` is the running position within it. See the
// longer note on the matching function in ssv_cached_sprite_renderer.sv.
function automatic logic [16:0] tile_address(
    input logic [16:0] x,
    input logic [16:0] x_base,
    input logic [16:0] y,
    input logic [15:0] mode
);
    logic [3:0] size_shift;
    logic [16:0] size_mask;
    logic [16:0] page;
    logic [16:0] base;
    logic [16:0] column;
    logic [16:0] row;
    begin
        size_shift = 4'd8 + {1'b0, mode[15:13]};
        size_mask = (17'd1 << size_shift) - 17'd1;
        page = (x_base & 17'h07fff) >> size_shift;
        base = page << (size_shift + 2'd2);
        column = (x & (size_mask & 17'h1fff0)) << 2;
        row = (y & 17'h001f0) >> 3;
        tile_address = base + column + row;
    end
endfunction

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

logic [7:0] batch_pen;
logic signed [11:0] batch_x;
integer plot_lane;
wire tile_flip_x = tile_attr[15] ^
                   (flip_control[12] && !flip_control[13]);
wire tile_flip_y = tile_attr[14] ^
                   (flip_control[14] && !flip_control[13]);

always_comb begin
    spr_addr = tile_word_addr;
    if (state == ROW_ADDR || state == ROW_WAIT)
        spr_addr = ({9'd0, scroll_mode[7:0]} << 9) + map_y[8:0];

    fetch_start = (state == FETCH_START);

    plot_we = 4'd0;
    plot_x = 36'd0;
    plot_pen = 32'd0;
    plot_color = 60'd0;
    for (plot_lane = 0; plot_lane < 4; plot_lane = plot_lane + 1) begin
        batch_pen = pens[(plot_i + plot_lane) * 8 +: 8];
        batch_x = screen_x + $signed(plot_i + plot_lane);
        plot_we[plot_lane] = (state == PLOT) && (batch_x >= 0) &&
                             (batch_x <= LAST_PIXEL) && (batch_pen != 0);
        plot_x[plot_lane * 9 +: 9] = batch_x[8:0];
        plot_pen[plot_lane * 8 +: 8] = batch_pen;
        plot_color[plot_lane * 15 +: 15] =
            ({color, 6'd0} + batch_pen) & 15'h7fff;
    end
    plot_shadow = shadow;
    plot_shadow_4bit = shadow_4bit;
end

always_ff @(posedge clk) begin
    if (rst) begin
        state            <= IDLE;
        target_y_latched <= 9'd0;
        tile_word_addr   <= 17'd0;
        tile_code_low    <= 16'd0;
        tile_attr        <= 16'd0;
        fetch_code       <= 20'd0;
        fetch_row        <= 3'd0;
        gfx_mode         <= 3'd0;
        flip_x           <= 1'b0;
        shadow           <= 1'b0;
        color            <= 9'd0;
        screen_x         <= 11'sd0;
        map_x            <= 17'd0;
        map_x0           <= 17'd0;
        map_y            <= 17'd0;
        plot_i           <= 5'd0;
        busy             <= 1'b0;
        done             <= 1'b0;
    end
    else begin
        done <= 1'b0;
        unique case (state)
            IDLE: begin
                busy <= 1'b0;
                if (line_start) begin
                    target_y_latched <= target_y;
                    busy <= 1'b1;
                    state <= WAIT_CLEAR;
                end
            end

            WAIT_CLEAR: begin
                if (clear_done) begin
                    map_y <= {8'd0, target_y_latched} +
                             {1'b0, scroll_y} +
                             {{6{global_y_base_s[10]}},
                              global_y_base_s} +
                             {1'b0, global_y_adjust} + 17'd2;
                    screen_x <= -$signed({7'd0, scroll_x[3:0]});
                    state <= ROW_DECIDE;
                end
            end

            ROW_DECIDE: begin
                if ((scroll_mode & 16'he000) == 16'd0) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
                else if (scroll_mode[12]) begin
                    state <= ROW_ADDR;
                end
                else begin
                    map_x <= {1'b0, scroll_x};
                    map_x0 <= {1'b0, scroll_x};
                    tile_word_addr <= tile_address(
                        {1'b0, scroll_x}, {1'b0, scroll_x},
                        map_y, scroll_mode
                    );
                    state <= TILE_CODE_ADDR;
                end
            end

            ROW_ADDR: state <= ROW_WAIT;
            ROW_WAIT: begin
                map_x <= {1'b0, scroll_x} + {1'b0, spr_data};
                map_x0 <= {1'b0, scroll_x} + {1'b0, spr_data};
                tile_word_addr <= tile_address(
                    {1'b0, scroll_x} + {1'b0, spr_data},
                    {1'b0, scroll_x} + {1'b0, spr_data},
                    map_y, scroll_mode
                );
                state <= TILE_CODE_ADDR;
            end

            TILE_CODE_ADDR: state <= TILE_CODE_WAIT;
            TILE_CODE_WAIT: begin
                tile_code_low <= spr_data;
                tile_word_addr <= tile_word_addr + 1'd1;
                state <= TILE_ATTR_ADDR;
            end

            TILE_ATTR_ADDR: state <= TILE_ATTR_WAIT;
            TILE_ATTR_WAIT: begin
                tile_attr <= spr_data;
                state <= TILE_PREP;
            end

            TILE_PREP: begin
                flip_x <= tile_flip_x;
                gfx_mode <= scroll_mode[10:8];
                shadow <= scroll_mode[11];
                color <= tile_attr[8:0];
                fetch_row <= tile_flip_y ? ~map_y[2:0] : map_y[2:0];

                if (tile_flip_y ? !map_y[3] : map_y[3])
                    fetch_code <= expand_code(tile_code_low, tile_attr) + 1'd1;
                else
                    fetch_code <= expand_code(tile_code_low, tile_attr);
                state <= FETCH_START;
            end

            FETCH_START: state <= FETCH_WAIT;
            FETCH_WAIT: begin
                if (fetch_done) begin
                    plot_i <= 5'd0;
                    state <= PLOT;
                end
            end

            PLOT: begin
                if (plot_i == 5'd12) begin
                    if (screen_x + 11'sd16 > $signed({2'd0, LAST_PIXEL})) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                    else begin
                        screen_x <= screen_x + 11'sd16;
                        map_x <= map_x + 17'd16;
                        tile_word_addr <= tile_address(
                            map_x + 17'd16, map_x0, map_y, scroll_mode
                        );
                        state <= TILE_CODE_ADDR;
                    end
                end
                else begin
                    plot_i <= plot_i + 3'd4;
                end
            end
        endcase
    end
end

endmodule
