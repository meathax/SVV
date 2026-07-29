// SPDX-License-Identifier: GPL-3.0-or-later
// Vblank-cached scanline renderer for interleaved SSV sprites and tilemaps.
`timescale 1ns/1ps

module ssv_cached_sprite_renderer #(
    // Attract soak used ~1277, but a 1500-frame gameplay soak peaked at 1519 of
    // 1536 -- seventeen entries of margin. On hardware the sticky overrun
    // indicator lights with no per-line deadline marks, which points at this
    // overflowing rather than the renderer running late; an overflow silently
    // drops descriptors, so sprites and tilemap slices simply go missing.
    //
    // 2048 costs roughly eight more M10K. That is affordable now only because
    // narrowing the palette's odd bank freed 31 blocks (530 -> 499 of 553).
    parameter integer CACHE_ENTRIES = 2048
) (
    input  logic         clk,
    input  logic         rst,
    input  ssv_pkg::ssv_cfg_t cfg,
    input  logic         cache_start,
    // Asserted once the raster reaches the lines where the first display rows
    // must be prepared. The vblank descriptor build must give up by then --
    // see the BUILD_ADVANCE abort for why overrunning is unrecoverable.
    input  logic         cache_deadline,
    input  logic         start,
    input  logic   [8:0] target_y,

    input  logic  [15:0] local_control,
    input  logic  [15:0] flip_control,
    input  logic  [15:0] coordinate_control,
    input  logic  [15:0] global_y_base,
    input  logic  [15:0] global_y_adjust,
    input  logic [255:0] sprite_offsets,
    input  logic [511:0] tilemap_scrolls,
    input  logic         shadow_4bit,

    output logic  [16:0] spr_addr,
    input  logic  [15:0] spr_data,
    // The sprite-RAM word at `spr_addr | 1`, available in the same cycle as
    // `spr_data` because sprite RAM is banked by word parity. Valid only when
    // `spr_addr` is even, which every consumer of it below guarantees -- see
    // tile_address(), whose result is always even.
    input  logic  [15:0] spr_data_next,

    output logic         rom_req,
    output logic  [ssv_pkg::SDR_AW:4] rom_addr,
    input  logic [127:0] rom_data,
    input  logic         rom_ack,

    output logic   [3:0] plot_we,
    output logic  [35:0] plot_x,
    output logic  [59:0] plot_color,
    output logic         plot_shadow,
    output logic  [31:0] plot_pen,
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
// Dense Dyna Gear story/gameplay scanlines exceed 64 real sprite descriptors.
// Keep headroom so valid sprites are not silently dropped.
// Index as y*LINE_SLOTS+slot (not a shifted concat) so non-power-of-two depths
// do not overrun the packed table.
localparam integer LINE_SLOTS = 96;
localparam integer LINE_SLOT_WIDTH = $clog2(LINE_SLOTS);
localparam integer LINE_COUNT_WIDTH = $clog2(LINE_SLOTS + 1);
localparam integer LINE_TABLE_WORDS = 240 * LINE_SLOTS;
localparam integer LINE_ADDR_WIDTH = $clog2(LINE_TABLE_WORDS);
localparam logic [LINE_COUNT_WIDTH-1:0] LINE_SLOTS_VALUE = LINE_SLOTS;
// Cache descriptors are appended in monotonically increasing address order.
// Keep only seven low bits in the large per-line table and record the first
// slot belonging to each 128-entry cache page.  Eleven 7-bit boundaries cover
// pages 1..11; page 0 is implicit.  This preserves all 96 entries while
// avoiding the third M10K depth slice on four descriptor-address bits.
localparam integer LINE_ENTRY_LOW_WIDTH = 7;
localparam integer LINE_ENTRY_PAGE_SIZE = 1 << LINE_ENTRY_LOW_WIDTH;
localparam integer LINE_PAGE_WIDTH = CACHE_ADDR_WIDTH - LINE_ENTRY_LOW_WIDTH;
localparam integer LINE_PAGE_BOUNDARIES =
    (CACHE_ENTRIES + LINE_ENTRY_PAGE_SIZE - 1) / LINE_ENTRY_PAGE_SIZE - 1;
localparam integer LINE_PAGE_META_WIDTH =
    LINE_PAGE_BOUNDARIES * LINE_COUNT_WIDTH;

typedef enum logic [5:0] {
    IDLE,
    BUILD_CLEAR_LINES,
    BUILD_GLOBAL_WAIT, BUILD_GLOBAL_0, BUILD_GLOBAL_1,
    BUILD_GLOBAL_2, BUILD_GLOBAL_3,
    BUILD_LOCAL_WAIT, BUILD_LOCAL_0, BUILD_LOCAL_1,
    BUILD_LOCAL_2, BUILD_LOCAL_3, BUILD_EVALUATE,
    BUILD_STORE,
    BUILD_BUCKET_READ, BUILD_BUCKET_WRITE, BUILD_ADVANCE,
    RENDER_COUNT_READ, RENDER_COUNT_WAIT,
    RENDER_LINE_READ, RENDER_READ, RENDER_DECODE, RENDER_PREP,
    RENDER_EVAL,
    RENDER_SPRITE_PREP, RENDER_ADVANCE,
    TILE_ROW_ADDR, TILE_ROW_WAIT,
    // One address, both words. The tile code and its attribute are an adjacent
    // even/odd pair, and sprite RAM is banked by parity, so the separate
    // TILE_ATTR_ADDR/TILE_ATTR_WAIT pair that used to follow is gone.
    TILE_CODE_ADDR, TILE_CODE_WAIT,
    TILE_PREP,
    FETCH_START, FETCH_WAIT, PLOT
} state_t;
state_t state;

logic [11:0] global_base;
logic [16:0] local_base;
logic  [4:0] local_index;
logic [15:0] global_w0, global_w1, global_w2, global_w3;
logic [15:0] local_w0, local_w1, local_w2, local_w3;
logic [15:0] tilemaps_offsy;

logic [CACHE_ADDR_WIDTH:0] cache_write_count;
logic [CACHE_ADDR_WIDTH:0] cache_count;
logic [CACHE_ADDR_WIDTH-1:0] cache_read_index;
logic [CACHE_ADDR_WIDTH:0] cache_render_index;
logic [127:0] cache_q;
logic [127:0] cache_decode_q;
logic cache_pending;
// After storing the last cache slot, finish its line buckets then stop.
logic cache_stop_after_bucket;
// One array, not two. The 128-bit form was measured at 22 M10K; splitting it
// into 53/75-bit halves to steer packing was predicted to give 18 but the
// Fitter RAM Summary reports 16 + 14 = 30 -- eight blocks WORSE than the
// single array it replaced. Block RAM is the binding resource on this part
// (530 of 553), so the measurement wins over the prediction. Do not re-split
// without a fit report showing a real reduction.
(* ramstyle = "M10K, no_rw_check" *)
logic [127:0] descriptor_cache [0:CACHE_ENTRIES-1];

(* ramstyle = "MLAB, no_rw_check" *)
logic [LINE_COUNT_WIDTH-1:0] line_counts [0:239];
logic [7:0] line_count_addr;
logic [LINE_COUNT_WIDTH-1:0] line_count_q;
(* ramstyle = "M10K, no_rw_check" *)
logic [LINE_ENTRY_LOW_WIDTH-1:0] line_entries [0:LINE_TABLE_WORDS-1];
// M10K, reversing the earlier MLAB choice, because the resource balance this
// array was tuned against has inverted.
//
// The original note said MLAB cost "about 32 MLAB cells" against two M10K
// blocks, and chose MLAB because M10K was the scarce resource at 532/553 with
// ALM at 82%. The first half of that was an underestimate. The fitter charges
// this array 751.3 ALM -- 480 in LUTRAM cells, 236.8 for mux_rib:rd_mux and 5
// for the write decoder -- because 240 deep by 77 wide needs eight MLABs of
// depth by four of width, and a 240-entry read mux on top.
//
// Meanwhile the design has moved the other way: the last fit came back at 92%
// ALM, and quartus_sta then ran out of memory before it could produce a timing
// report at all. Dropping the stock video chain freed block RAM but little
// logic, so ALM is now the binding resource and M10K is not. Two blocks for
// 751 ALM is the right way round at this operating point.
//
// The access shape and the no_rw_check argument are unchanged from the note on
// line_counts above; only the storage choice moves. line_counts itself stays
// MLAB: the fitter charges it 103 ALM, so trading it for a whole M10K would be
// close to break-even rather than a win.
(* ramstyle = "M10K, no_rw_check" *)
logic [LINE_PAGE_META_WIDTH-1:0] line_page_starts [0:239];
logic [LINE_PAGE_META_WIDTH-1:0] line_page_q;
logic [7:0] clear_y;
logic [7:0] bucket_y, bucket_last_y;
logic [CACHE_ADDR_WIDTH-1:0] bucket_descriptor;
logic [LINE_ADDR_WIDTH-1:0] line_entry_addr;
logic [LINE_ENTRY_LOW_WIDTH-1:0] line_entry_q;
logic [LINE_PAGE_WIDTH-1:0] line_entry_page_q;
logic [LINE_COUNT_WIDTH-1:0] render_line_count;
logic [LINE_COUNT_WIDTH-1:0] render_line_slot;
logic [LINE_PAGE_META_WIDTH-1:0] render_line_pages;
logic [7:0] build_first_y, build_last_y;
logic build_screen_visible_q;
logic [7:0] build_first_y_q, build_last_y_q;
logic [127:0] cache_write_data_q;



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
logic        render_tilemap;
logic [15:0] tile_mode;
logic [15:0] tile_unknown;
logic [15:0] tile_code_low;
logic [15:0] tile_attr;
logic [16:0] tile_word_addr;
logic [16:0] tile_map_x;
// Map origin for the current scanline; fixes which page (i.e. which tilemap)
// the whole line reads from. See tile_address().
logic [16:0] tile_map_x0;
logic [16:0] tile_map_y;
logic [16:0] tile_scroll_x;
logic signed [10:0] tile_screen_x;
logic        last_was_tilemap;
logic  [2:0] last_tilemap_group;

// --- Tilemap code/attribute prefetch ---------------------------------------
// FETCH_WAIT is ~10 cycles in which the renderer does nothing at all but wait
// for the 128-bit graphics row to come back from SDRAM. Sprite RAM is a
// different memory, and its video port is idle for that entire window, so the
// *next* tilemap tile's code/attribute pair is read there and reduced to fetch
// operands ahead of time. When PLOT (or a transparent row) finishes, the
// TILE_CODE_ADDR / TILE_CODE_WAIT / TILE_PREP trio is skipped outright.
//
// This touches sprite RAM only. The graphics row itself is still fetched
// strictly one at a time, and nothing here issues a second p2 transaction --
// the p2 mux is deliberately left alone.
//
// Stages, all of which occur inside FETCH_WAIT/PLOT:
//   1 = drive spr_addr with tile_next_word_addr
//   2 = one-cycle sprite-RAM latency has elapsed; latch the pair
//   3 = do TILE_PREP's arithmetic into the shadow registers, set valid
//   0 = idle: either finished, or never armed (sprite, or last tile of line)
// If the row fetch somehow completed before stage 3, tile_pf_valid stays low
// and the original TILE_CODE_ADDR path runs unchanged.
logic  [1:0] tile_pf_stage;
logic        tile_pf_valid;
logic [15:0] tile_pf_code_low;
logic [15:0] tile_pf_attr;
logic        tile_pf_flip_x;
logic        tile_pf_flip_y;
logic  [8:0] tile_pf_color;
logic  [2:0] tile_pf_row;
logic [19:0] tile_pf_fetch_code;

logic        fetch_start;
logic        fetch_done;
logic [19:0] fetch_code;
logic  [2:0] fetch_row;
logic [31:0] plane01, plane23, plane45, plane67;
logic [127:0] pens;

wire [15:0] cached_tilemaps_offsy = cache_decode_q[127:112];
wire [15:0] cached_g0 = cache_decode_q[111:96];
wire [15:0] cached_g2 = cache_decode_q[95:80];
wire [15:0] cached_g3 = cache_decode_q[79:64];
wire [15:0] cached_l0 = cache_decode_q[63:48];
wire [15:0] cached_l1 = cache_decode_q[47:32];
wire [15:0] cached_l2 = cache_decode_q[31:16];
wire [15:0] cached_l3 = cache_decode_q[15:0];

logic  [1:0] calc_xbits, calc_ybits;
logic  [3:0] calc_xnum, calc_ynum;
logic  [3:0] calc_depth;
logic [19:0] calc_code;
logic        calc_flip_x, calc_flip_y;
logic  [6:0] calc_height;
logic        calc_tilemap;
logic        calc_tilemap_active;
logic signed [16:0] calc_tilemap_sy;
logic signed [17:0] calc_tilemap_sy_work;
logic signed [17:0] calc_tile_scroll_x_work;
logic [16:0] calc_tile_map_y;
logic signed [17:0] calc_tilemap_bottom;

// Registered descriptor-decode results.  Coordinate calculation contains
// several dependent add/subtract stages; separating it from the render-state
// updates keeps that arithmetic out of the 48 MHz state/register paths.
logic        prep_tilemap;
logic        prep_tilemap_active;
logic signed [16:0] prep_tilemap_sy;
logic signed [17:0] prep_tilemap_bottom;
logic [15:0] prep_tile_mode;
logic [15:0] prep_tile_unknown;
logic  [2:0] prep_tile_group;
logic [16:0] prep_tile_map_y;
logic signed [17:0] prep_tile_scroll_x_work;
logic  [6:0] prep_height;
logic [19:0] prep_code;
logic  [3:0] prep_xnum, prep_ynum;
logic  [3:0] prep_depth;
logic        prep_flip_x, prep_flip_y;
logic  [8:0] prep_color;
logic signed [16:0] prep_sx_work, prep_sy_work;
logic signed [16:0] prep_sprites_offsx, prep_sprites_offsy;
logic [15:0] prep_coordinate_control, prep_flip_control;

logic signed [16:0] eval_sx, eval_sy;
logic signed [17:0] eval_line_rel;

// Finish coordinate transforms from the registered first-level sums.  This
// is the second half of the decode pipeline; the sprite-offset mux and the
// three-input local/global/offset sums are no longer in this path.
always_comb begin
    logic signed [16:0] sx_work;
    logic signed [16:0] sy_work;

    sx_work = prep_sx_work;
    sy_work = prep_sy_work;

    if (prep_flip_control[14]) begin
        sy_work = -sy_work;
        if (!prep_flip_control[15])
            sy_work = sy_work - 17'sd16;
    end
    if (prep_flip_control[12])
        sx_work = -sx_work + 17'sd256;

    if (prep_coordinate_control == 16'h7140) begin
        eval_sx = prep_sprites_offsx + sx_work;
        eval_sy = prep_sprites_offsy - sy_work;
    end
    else if (prep_coordinate_control[11]) begin
        eval_sx = prep_sprites_offsx + sx_work -
                  $signed({9'd0, prep_xnum, 3'd0});
        eval_sy = prep_sprites_offsy - sy_work -
                  $signed({10'd0, prep_ynum, 2'd0});
    end
    else begin
        eval_sx = prep_sprites_offsx + sx_work;
        eval_sy = prep_sprites_offsy - sy_work -
                  $signed({9'd0, prep_ynum, 3'd0});
    end

    eval_line_rel = $signed({1'b0, target_y_latched}) - eval_sy;
end

function automatic logic signed [10:0] signed10(input logic [15:0] value);
    signed10 = $signed({value[9], value[9:0]});
endfunction

function automatic logic signed [8:0] signed8(input logic [15:0] value);
    signed8 = $signed({value[7], value[7:0]});
endfunction

// MAME's init_ssv builds m_tile_code[i] = bitswap<4>(i,0,1,2,3) << 16, which
// is attr[13:10] REVERSED. cairblad uses init_ssv_tilescram, whose table is the
// identity (m_tile_code[i] = i << 16), so the high nibble passes through in
// natural order. One config bit selects between them.
function automatic logic [19:0] expand_code(
    input ssv_pkg::ssv_cfg_t cfg,
    input logic [15:0] low,
    input logic [15:0] attr
);
    expand_code = cfg.tile_code_identity
                ? {attr[13:10], low}
                : {{attr[10], attr[11], attr[12], attr[13]}, low};
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

function automatic logic [15:0] tilemap_scroll_word(
    input logic [511:0] values,
    input logic   [4:0] index
);
    tilemap_scroll_word = values[index * 16 +: 16];
endfunction

// `x_base` is the map origin for this scanline; `x` is the running position
// along it.
//
// tile_address() carries no per-group base, so a tilemap group is identified
// purely by which page its scroll value lands in -- Dyna Gear puts group 1 in
// page 3, group 3 in page 5 and group 4 in page 6. `page` therefore selects
// *which map to read*, and must be fixed for the whole line by the origin.
// Deriving it from the running `x` instead meant a group whose span crossed a
// page boundary walked into the neighbouring group's map partway across the
// screen: the background went blank and picked up font tiles from whatever
// lived there. `column` already wraps inside the page via size_mask, which is
// the correct behaviour for the scroll itself.
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
        // See the matching note in ssv_bg_renderer.sv: computed at 4 bits this
        // wraps for size_shift 14/15 and shifts by 0/1 instead of 16/17.
        base = page << ({1'b0, size_shift} + 5'd2);
        column = (x & (size_mask & 17'h1fff0)) << 2;
        row = (y & 17'h001f0) >> 3;
        tile_address = base + column + row;
    end
endfunction

wire signed [10:0] global_y_base_s = signed10(global_y_base);

wire [3:0] cached_offset_index = {cached_g0[7:5], 1'b0};
wire [15:0] selected_offset_x =
    offset_word(sprite_offsets, cached_offset_index);
wire [15:0] selected_offset_y =
    offset_word(sprite_offsets, cached_offset_index + 1'd1);
wire [4:0] cached_tilemap_base = {cached_l0[2:0], 2'b00};
wire [15:0] cached_tile_scroll_x =
    tilemap_scroll_word(tilemap_scrolls, cached_tilemap_base);
wire [15:0] cached_tile_scroll_y =
    tilemap_scroll_word(tilemap_scrolls, cached_tilemap_base + 1'd1);
wire [15:0] cached_tile_unknown =
    tilemap_scroll_word(tilemap_scrolls, cached_tilemap_base + 2'd2);
wire [15:0] cached_tile_mode =
    tilemap_scroll_word(tilemap_scrolls, cached_tilemap_base + 2'd3);


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
logic build_tilemap_active;
logic signed [17:0] build_tilemap_sy_work;
logic signed [16:0] build_tilemap_sy;
logic signed [17:0] build_tilemap_bottom;

always_comb begin
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
    calc_tilemap_active = calc_tilemap && (cached_g0[4:0] != 0) &&
                          (cached_l0 != 0);
    calc_tilemap_sy_work = signed10(cached_l3);
    if (local_control[12])
        calc_tilemap_sy_work = calc_tilemap_sy_work - 18'sd32;
    else if (coordinate_control[11]) begin
        if (coordinate_control[12])
            calc_tilemap_sy_work = calc_tilemap_sy_work -
                                   signed10(cached_tilemaps_offsy);
        else
            calc_tilemap_sy_work = calc_tilemap_sy_work +
                                   signed10(cached_tilemaps_offsy);
    end
    calc_tilemap_sy = signed10(calc_tilemap_sy_work[15:0]);
    calc_tilemap_bottom = calc_tilemap_sy + 18'sd65;
    calc_tile_scroll_x_work = $signed({2'b00, cached_tile_scroll_x});
    if ((cached_tile_unknown & 16'h05ff) == 16'h0440)
        calc_tile_scroll_x_work = calc_tile_scroll_x_work - 18'sd16;
    else if ((cached_tile_unknown & 16'h05ff) == 16'h0401)
        calc_tile_scroll_x_work = calc_tile_scroll_x_work - 18'sd32;

    calc_tile_map_y = {8'd0, target_y_latched} +
                      {1'b0, cached_tile_scroll_y} +
                      {{6{global_y_base_s[10]}}, global_y_base_s} +
                      {1'b0, global_y_adjust} + 17'd2;

    calc_code = expand_code(cfg, cached_l0, cached_l1);
    if ((calc_xnum == 4'd2) && (calc_ynum == 4'd4))
        calc_code = calc_code & 20'hffff8;

    calc_flip_x = cached_l1[15] ^
                  (flip_control[12] && !flip_control[13]);
    calc_flip_y = cached_l1[14] ^
                  (flip_control[14] && !flip_control[13]);

    calc_height = {calc_ynum, 3'd0};
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
    build_tilemap_active = build_tilemap && (global_w0[4:0] != 0) &&
                           (local_w0 != 0);
    build_tilemap_sy_work = signed10(local_w3);
    if (local_control[12])
        build_tilemap_sy_work = build_tilemap_sy_work - 18'sd32;
    else if (coordinate_control[11]) begin
        if (coordinate_control[12])
            build_tilemap_sy_work = build_tilemap_sy_work -
                                    signed10(tilemaps_offsy);
        else
            build_tilemap_sy_work = build_tilemap_sy_work +
                                    signed10(tilemaps_offsy);
    end
    build_tilemap_sy = signed10(build_tilemap_sy_work[15:0]);
    build_tilemap_bottom = build_tilemap_sy + 18'sd65;

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
    if (build_tilemap) begin
        if (build_tilemap_sy < 0)
            build_first_y = 8'd0;
        else
            build_first_y = build_tilemap_sy[7:0];
        build_last_y = (build_tilemap_bottom > 18'sd240) ? 8'd239 :
                       build_tilemap_bottom[7:0] - 1'd1;
        build_screen_visible = build_tilemap_active &&
                               (build_tilemap_sy < 17'sd240) &&
                               (build_tilemap_bottom > 18'sd0);
    end
    else begin
        if (build_sy < 0)
            build_first_y = 8'd0;
        else
            build_first_y = build_sy[7:0];
        build_last_y = (build_bottom > 18'sd240) ? 8'd239 :
                       build_bottom[7:0] - 1'd1;
        build_screen_visible = (build_sx < 17'sd336) &&
                               (build_right > 18'sd0) &&
                               (build_sy < 17'sd240) &&
                               (build_bottom > 18'sd0);
    end
end

wire cache_we = (state == BUILD_STORE) &&
                build_screen_visible_q &&
                (cache_write_count < CACHE_COUNT_VALUE);
wire [127:0] cache_write_data = {
    tilemaps_offsy, global_w0, global_w2, global_w3,
    local_w0, local_w1, local_w2, local_w3
};

function automatic logic [LINE_PAGE_WIDTH-1:0] line_page_for_slot(
    input logic [LINE_PAGE_META_WIDTH-1:0] starts,
    input logic [LINE_COUNT_WIDTH-1:0] slot
);
    integer page_i;
    begin
        line_page_for_slot = '0;
        for (page_i = 1; page_i <= LINE_PAGE_BOUNDARIES; page_i = page_i + 1) begin
            if (starts[(page_i - 1) * LINE_COUNT_WIDTH +:
                       LINE_COUNT_WIDTH] <= slot)
                line_page_for_slot = LINE_PAGE_WIDTH'(page_i);
        end
    end
endfunction

logic [LINE_PAGE_META_WIDTH-1:0] line_page_write_data;
logic line_page_write;
integer line_page_write_index;
always_comb begin
    line_page_write_data = line_page_q;
    line_page_write = 1'b0;
    line_page_write_index = 0;
    if (bucket_descriptor[CACHE_ADDR_WIDTH-1:LINE_ENTRY_LOW_WIDTH] != 0) begin
        line_page_write_index =
            bucket_descriptor[CACHE_ADDR_WIDTH-1:LINE_ENTRY_LOW_WIDTH] - 1'b1;
        if (line_page_q[line_page_write_index * LINE_COUNT_WIDTH +:
                        LINE_COUNT_WIDTH] == LINE_SLOTS_VALUE) begin
            line_page_write_data[line_page_write_index * LINE_COUNT_WIDTH +:
                                 LINE_COUNT_WIDTH] = line_count_q;
            line_page_write = 1'b1;
        end
    end
end

wire [LINE_COUNT_WIDTH-1:0] line_entry_read_slot =
    (state == RENDER_PREP) ? render_line_slot + 2'd2 :
    (state == RENDER_DECODE) ? render_line_slot + 1'd1 :
    render_line_slot;
wire [LINE_PAGE_WIDTH-1:0] line_entry_read_page =
    line_page_for_slot(render_line_pages, line_entry_read_slot);
wire [CACHE_ADDR_WIDTH-1:0] line_entry_descriptor = {
    line_entry_page_q, line_entry_q
};

// NOTE on `no_rw_check` for these tables: the unconditional reads below use
// the same address as the BUILD_CLEAR_LINES / BUILD_BUCKET_WRITE writes, so a
// same-address read-during-write happens on every one of those cycles. That is
// exactly the case `no_rw_check` promises cannot occur, and on hardware the
// read data is undefined where simulation returns the pre-write value.
//
// It is safe only because the colliding read is never consumed. During
// BUILD_BUCKET_WRITE the value landing in line_count_q is replaced by the next
// BUILD_BUCKET_READ (which uses the incremented address) before any state
// reads it, and during BUILD_CLEAR_LINES nothing reads line_count_q at all.
// If a future change ever samples line_count_q one cycle earlier, this
// attribute becomes a live sim-versus-silicon divergence.
always_ff @(posedge clk) begin
    line_count_q <= line_counts[line_count_addr];
    line_page_q <= line_page_starts[line_count_addr];
    if (state == BUILD_CLEAR_LINES) begin
        line_counts[line_count_addr] <= '0;
        line_page_starts[line_count_addr] <=
            {LINE_PAGE_BOUNDARIES{LINE_SLOTS_VALUE}};
    end
    else if ((state == BUILD_BUCKET_WRITE) &&
             (line_count_q < LINE_SLOTS_VALUE)) begin
        line_counts[line_count_addr] <= line_count_q + 1'd1;
        if (line_page_write)
            line_page_starts[line_count_addr] <= line_page_write_data;
    end

    // Fetch the first entry explicitly.  During PREP, use the registered next
    // line entry to prefetch the following descriptor and simultaneously read
    // the entry after it.  ADVANCE can then transfer cache_q directly into the
    // decode register without an otherwise-idle decode state.
    if ((state == RENDER_LINE_READ) ||
        (state == RENDER_DECODE) ||
        ((state == RENDER_PREP) &&
         (render_line_slot + 2'd2 < render_line_count))) begin
        line_entry_q <= line_entries[line_entry_addr];
        line_entry_page_q <= line_entry_read_page;
    end
    if ((state == RENDER_READ) ||
        ((state == RENDER_PREP) &&
         (render_line_slot + 1'd1 < render_line_count)))
        cache_q <= descriptor_cache[line_entry_descriptor];
    if (cache_we)
        descriptor_cache[cache_write_count[CACHE_ADDR_WIDTH-1:0]]
            <= cache_write_data_q;
end

ssv_gfx_row_fetch fetch (
    .clk(clk), .rst(rst), .cfg(cfg), .start(fetch_start),
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

logic [7:0] batch_pen [0:3];
logic signed [17:0] batch_x [0:3];
integer plot_lane;
wire tile_flip_x = tile_attr[15] ^
                   (flip_control[12] && !flip_control[13]);
wire tile_flip_y = tile_attr[14] ^
                   (flip_control[14] && !flip_control[13]);

// Sprite-RAM address of the next tilemap tile along this scanline. tile_map_x,
// tile_map_x0, tile_map_y and tile_mode are all fixed for the whole of the
// current tile, so this is stable from the moment that tile starts fetching --
// which is exactly what lets the prefetch run inside FETCH_WAIT. The two
// advance points (FETCH_WAIT's transparent exit and PLOT's) each used to
// instantiate this same tile_address() call; they now share this one.
wire [16:0] tile_next_word_addr =
    tile_address(tile_map_x + 17'd16, tile_map_x0, tile_map_y, tile_mode);
// True when a further tile still fits on the line. This is the same test the
// advance points make, just evaluated one tile earlier, so an armed prefetch
// can never read past the end of the line.
wire tile_next_in_range =
    !((tile_screen_x + 11'sd16) > $signed({2'd0, LAST_PIXEL}));
// tile_flip_x/y above, but for the prefetched attribute.
wire tile_pf_flip_x_next = tile_pf_attr[15] ^
                           (flip_control[12] && !flip_control[13]);
wire tile_pf_flip_y_next = tile_pf_attr[14] ^
                           (flip_control[14] && !flip_control[13]);

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
        TILE_ROW_ADDR, TILE_ROW_WAIT:
            spr_addr = ({9'd0, tile_mode[7:0]} << 9) + tile_map_y[8:0];
        TILE_CODE_ADDR, TILE_CODE_WAIT: spr_addr = tile_word_addr;
        default: ;
    endcase

    // The prefetch borrows the idle sprite-RAM video port. It is gated on the
    // two states that own the port but do not use it, so it can never fight the
    // descriptor-cache build walk, the row-scroll table lookup, or the ordinary
    // TILE_CODE_ADDR read above -- none of which can be the current state here.
    if ((tile_pf_stage == 2'd1) &&
        ((state == FETCH_WAIT) || (state == PLOT)))
        spr_addr = tile_next_word_addr;

    fetch_start = (state == FETCH_START);
    plot_we = 4'd0;
    plot_x = 36'd0;
    plot_pen = 32'd0;
    plot_color = 60'd0;
    for (plot_lane = 0; plot_lane < 4; plot_lane = plot_lane + 1) begin
        batch_pen[plot_lane] =
            pens[(plot_i + plot_lane) * 8 +: 8];
        batch_x[plot_lane] = render_tilemap
            ? tile_screen_x + $signed({13'd0, plot_i}) + plot_lane
            : sprite_sx + $signed({13'd0, plot_i}) + plot_lane;
        plot_we[plot_lane] = (state == PLOT) &&
            (batch_x[plot_lane] >= 0) &&
            (batch_x[plot_lane] <= $signed({9'd0, LAST_PIXEL})) &&
            (batch_pen[plot_lane] != 0);
        plot_x[plot_lane * 9 +: 9] = batch_x[plot_lane][8:0];
        plot_pen[plot_lane * 8 +: 8] = batch_pen[plot_lane];
        plot_color[plot_lane * 15 +: 15] =
            ({color, 6'd0} + batch_pen[plot_lane]) & 15'h7fff;
    end
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
        tilemaps_offsy <= 16'd0;
        cache_write_count <= '0;
        cache_count <= '0;
        cache_read_index <= '0;
        cache_render_index <= '0;
        cache_decode_q <= '0;
        cache_busy <= 1'b0;
        cache_ready <= 1'b0;
        cache_overflow <= 1'b0;
        cache_pending <= 1'b0;
        cache_stop_after_bucket <= 1'b0;
        build_screen_visible_q <= 1'b0;
        build_first_y_q <= 8'd0;
        build_last_y_q <= 8'd0;
        cache_write_data_q <= 128'd0;
        clear_y <= 8'd0;
        line_count_addr <= 8'd0;
        bucket_y <= 8'd0;
        bucket_last_y <= 8'd0;
        bucket_descriptor <= '0;
        line_entry_addr <= '0;
        render_line_count <= '0;
        render_line_slot <= '0;
        render_line_pages <= {LINE_PAGE_BOUNDARIES{LINE_SLOTS_VALUE}};
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
        render_tilemap <= 1'b0;
        tile_mode <= 16'd0;
        tile_unknown <= 16'd0;
        tile_code_low <= 16'd0;
        tile_attr <= 16'd0;
        tile_word_addr <= 17'd0;
        tile_map_x <= 17'd0;
        tile_map_x0 <= 17'd0;
        tile_map_y <= 17'd0;
        tile_scroll_x <= 17'd0;
        tile_screen_x <= 11'sd0;
        last_was_tilemap <= 1'b0;
        last_tilemap_group <= 3'd0;
        fetch_code <= 20'd0;
        fetch_row <= 3'd0;
        tile_pf_stage <= 2'd0;
        tile_pf_valid <= 1'b0;
        tile_pf_code_low <= 16'd0;
        tile_pf_attr <= 16'd0;
        tile_pf_flip_x <= 1'b0;
        tile_pf_flip_y <= 1'b0;
        tile_pf_color <= 9'd0;
        tile_pf_row <= 3'd0;
        tile_pf_fetch_code <= 20'd0;
        busy <= 1'b0;
        done <= 1'b0;
    end
    else begin
        done <= 1'b0;
        if (cache_start)
            cache_pending <= 1'b1;

        // Prefetch sequencer. Runs beside the main state machine, and only in
        // the two states where the sprite-RAM video port is idle. FETCH_WAIT is
        // reachable only from FETCH_START, which always re-arms tile_pf_stage,
        // so a stage left over from an early-terminating fetch can never be
        // mistaken for a live one.
        if ((state == FETCH_WAIT) || (state == PLOT)) begin
            case (tile_pf_stage)
                2'd1: tile_pf_stage <= 2'd2;
                2'd2: begin
                    tile_pf_code_low <= spr_data;
                    tile_pf_attr     <= spr_data_next;
                    tile_pf_stage    <= 2'd3;
                end
                2'd3: begin
                    // TILE_PREP's arithmetic, verbatim, run early. tile_mode
                    // and tile_map_y are fixed for the whole tilemap run, so
                    // only the attribute-derived terms need shadowing.
                    tile_pf_flip_x <= tile_pf_flip_x_next;
                    tile_pf_flip_y <= tile_pf_flip_y_next;
                    tile_pf_color  <= tile_pf_attr[8:0];
                    tile_pf_row    <= tile_pf_flip_y_next ? ~tile_map_y[2:0]
                                                          :  tile_map_y[2:0];
                    if (tile_pf_flip_y_next ? !tile_map_y[3] : tile_map_y[3])
                        tile_pf_fetch_code <=
                            expand_code(cfg, tile_pf_code_low, tile_pf_attr) + 1'd1;
                    else
                        tile_pf_fetch_code <=
                            expand_code(cfg, tile_pf_code_low, tile_pf_attr);
                    tile_pf_valid <= 1'b1;
                    tile_pf_stage <= 2'd0;
                end
                default: ;
            endcase
        end

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
                    cache_stop_after_bucket <= 1'b0;
                    cache_busy <= 1'b1;
                    cache_pending <= 1'b0;
                    state <= BUILD_CLEAR_LINES;
                end
                else if (start) begin
                    if (cache_ready) begin
                        target_y_latched <= target_y;
                        last_was_tilemap <= 1'b0;
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
                    // Enter the local loop unconditionally, even when the
                    // global's count field is zero. Combined with the
                    // `local_index < global_w0[4:0]` test in BUILD_ADVANCE
                    // this yields count+1 iterations, which is what MAME's
                    // `for (; num >= 0; num--)` does. Do NOT "optimise" a
                    // zero-count global into a skip: it would drop a
                    // descriptor MAME draws and break frame-CRC parity.
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
                if (local_index == 0)
                    tilemaps_offsy <= spr_data;
                state <= BUILD_EVALUATE;
            end

            BUILD_EVALUATE: begin
                build_screen_visible_q <= build_screen_visible;
                build_first_y_q <= build_first_y;
                build_last_y_q <= build_last_y;
                cache_write_data_q <= cache_write_data;
                state <= BUILD_STORE;
            end

            BUILD_STORE: begin
                if (build_screen_visible_q &&
                    (cache_write_count < CACHE_COUNT_VALUE)) begin
                    // Write+bucket every accepted slot, including the last;
                    // stop after that entry's buckets so it is not orphaned.
                    // Because the stop fires exactly as the count reaches
                    // CACHE_COUNT_VALUE, the "already full" arm below is
                    // unreachable in practice and is kept only as a guard.
                    cache_write_count <= cache_write_count + 1'd1;
                    bucket_descriptor <=
                        cache_write_count[CACHE_ADDR_WIDTH-1:0];
                    bucket_y <= build_first_y_q;
                    bucket_last_y <= build_last_y_q;
                    line_count_addr <= build_first_y_q;
                    cache_stop_after_bucket <=
                        (cache_write_count == CACHE_LAST_VALUE);
                    state <= BUILD_BUCKET_READ;
                end
                else if (build_screen_visible_q) begin
                    cache_count <= cache_write_count;
                    cache_ready <= 1'b1;
                    cache_overflow <= 1'b1;
                    cache_busy <= 1'b0;
                    state <= IDLE;
                end
                else begin
                    state <= BUILD_ADVANCE;
                end
            end

            BUILD_BUCKET_READ: state <= BUILD_BUCKET_WRITE;

            BUILD_BUCKET_WRITE: begin
                if (line_count_q < LINE_SLOTS_VALUE) begin
                    line_entries[
                        (bucket_y * LINE_SLOTS) +
                        line_count_q[LINE_SLOT_WIDTH-1:0]
                    ] <= bucket_descriptor[LINE_ENTRY_LOW_WIDTH-1:0];
                end
                else begin
                    cache_overflow <= 1'b1;
                end
                if (bucket_y == bucket_last_y) begin
                    if (cache_stop_after_bucket) begin
                        // Every descriptor up to here was stored, but the
                        // scan is being abandoned at the ceiling, so anything
                        // still left in the sprite list is dropped. Report it:
                        // cache_overflow means "list truncated", not "write
                        // failed". Same flag is raised above when one scanline
                        // needs more than LINE_SLOTS descriptors.
                        cache_count <= CACHE_COUNT_VALUE;
                        cache_ready <= 1'b1;
                        cache_overflow <= 1'b1;
                        cache_busy <= 1'b0;
                        cache_stop_after_bucket <= 1'b0;
                        state <= IDLE;
                    end
                    else begin
                        state <= BUILD_ADVANCE;
                    end
                end
                else begin
                    bucket_y <= bucket_y + 1'd1;
                    line_count_addr <= line_count_addr + 1'd1;
                    state <= BUILD_BUCKET_READ;
                end
            end


            BUILD_ADVANCE: begin
                // Hard vblank deadline. The sprite list is only bounded by
                // 1024 globals x 32 locals x up to 240 bucket lines, which is
                // orders of magnitude longer than a frame. If the build ever
                // runs past the start of display, ssv_core's line_buffer_start
                // -- which gates on !cache_busy -- stops firing, so no line
                // ever swaps and the picture freezes. Worse, it cannot
                // recover: the next vblank re-arms the build, so it stays busy
                // forever. Publishing a partial cache degrades one frame's
                // sprites and raises cache_overflow (wired to the overrun LED)
                // instead of latching the whole core into a dead display.
                if (cache_deadline) begin
                    cache_count <= cache_write_count;
                    cache_ready <= 1'b1;
                    cache_overflow <= 1'b1;
                    cache_busy <= 1'b0;
                    state <= IDLE;
                end
                else if ((local_index < global_w0[4:0]) &&
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
                    render_line_pages <= line_page_q;
                    line_entry_addr <= LINE_ADDR_WIDTH'(
                        target_y_latched[7:0] * LINE_SLOTS
                    );
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
                cache_read_index <= line_entry_descriptor;
                cache_render_index <= line_entry_descriptor;
                if (render_line_slot + 1'd1 < render_line_count)
                    line_entry_addr <= line_entry_addr + 1'd1;
                state <= RENDER_DECODE;
            end
            // Keep the M10K output separate from coordinate/decode arithmetic.
            // This extra register removes the cache-to-position critical path.
            RENDER_DECODE: begin
                cache_decode_q <= cache_q;
                if (render_line_slot + 2'd2 < render_line_count)
                    line_entry_addr <= line_entry_addr + 1'd1;
                state <= RENDER_PREP;
            end
            RENDER_PREP: begin
                if (render_line_slot + 2'd3 < render_line_count)
                    line_entry_addr <= line_entry_addr + 1'd1;
                prep_tilemap <= calc_tilemap;
                prep_tilemap_active <= calc_tilemap_active;
                prep_tilemap_sy <= calc_tilemap_sy;
                prep_tilemap_bottom <= calc_tilemap_bottom;
                prep_tile_mode <= cached_tile_mode;
                prep_tile_unknown <= cached_tile_unknown;
                prep_tile_group <= cached_l0[2:0];
                prep_tile_map_y <= calc_tile_map_y;
                prep_tile_scroll_x_work <= calc_tile_scroll_x_work;
                prep_height <= calc_height;
                prep_code <= calc_code;
                prep_xnum <= calc_xnum;
                prep_ynum <= calc_ynum;
                prep_depth <= calc_depth;
                prep_flip_x <= calc_flip_x;
                prep_flip_y <= calc_flip_y;
                prep_color <= cached_l1[8:0];
                prep_sx_work <= signed10(
                    cached_l2 + cached_g2 + selected_offset_x
                );
                prep_sy_work <= signed10(
                    cached_l3 + cached_g3 + selected_offset_y
                );
                prep_sprites_offsx <= signed8(flip_control);
                prep_sprites_offsy <= -(
                    signed10(global_y_base) +
                    $signed({1'b0, global_y_adjust}) + 17'sd1
                );
                prep_coordinate_control <= coordinate_control;
                prep_flip_control <= flip_control;
                state <= RENDER_EVAL;
            end
            RENDER_EVAL: begin
                if (prep_tilemap) begin
                    if (prep_tilemap_active &&
                        ($signed({1'b0, target_y_latched}) >=
                         prep_tilemap_sy) &&
                        ($signed({1'b0, target_y_latched}) <
                         prep_tilemap_bottom) &&
                        ((prep_tile_mode & 16'he000) != 0)) begin
                        // Adjacent 64-pixel tilemap slices overlap by one
                        // inclusive line in MAME. If the same scroll group
                        // is repeated with no intervening draw, its second
                        // rendering is pixel-for-pixel identical.
                        if (last_was_tilemap &&
                            (last_tilemap_group == prep_tile_group)) begin
                            state <= RENDER_ADVANCE;
                        end
                        else begin
                            last_was_tilemap <= 1'b1;
                            last_tilemap_group <= prep_tile_group;
                            render_tilemap <= 1'b1;
                            tile_mode <= prep_tile_mode;
                            tile_unknown <= prep_tile_unknown;
                            tile_map_y <= prep_tile_map_y;
                            tile_scroll_x <= prep_tile_scroll_x_work[16:0];
                            if (prep_tile_mode[12]) begin
                                state <= TILE_ROW_ADDR;
                            end
                            else begin
                                tile_map_x <= prep_tile_scroll_x_work[16:0];
                                tile_map_x0 <= prep_tile_scroll_x_work[16:0];
                                tile_screen_x <=
                                    -$signed({7'd0,
                                              prep_tile_scroll_x_work[3:0]});
                                tile_word_addr <= tile_address(
                                    prep_tile_scroll_x_work[16:0],
                                    prep_tile_scroll_x_work[16:0],
                                    prep_tile_map_y, prep_tile_mode
                                );
                                state <= TILE_CODE_ADDR;
                            end
                        end
                    end
                    else begin
                        state <= RENDER_ADVANCE;
                    end
                end
                else if ((eval_line_rel >= 0) &&
                         (eval_line_rel <
                          $signed({1'b0, prep_height}))) begin
                    render_tilemap <= 1'b0;
                    last_was_tilemap <= 1'b0;
                    sprite_code <= prep_code;
                    sprite_xnum <= prep_xnum;
                    sprite_ynum <= prep_ynum;
                    sprite_tile_x <= 4'd0;
                    sprite_tile_y <= eval_line_rel[6:3];
                    sprite_sx <= eval_sx;
                    sprite_row <= prep_flip_y ? ~eval_line_rel[2:0]
                                              : eval_line_rel[2:0];
                    gfx_mode <= prep_depth[2:0];
                    flip_x <= prep_flip_x;
                    flip_y <= prep_flip_y;
                    shadow <= prep_depth[3];
                    color <= prep_color;
                    state <= RENDER_SPRITE_PREP;
                end
                else begin
                    state <= RENDER_ADVANCE;
                end
            end
            // Isolate descriptor decode from the row-fetch address. The
            // cached values above are registered, breaking the M10K-to-code
            // arithmetic path while adding only one system-clock cycle.
            RENDER_SPRITE_PREP: begin
                fetch_code <= code_for_tile(
                    sprite_code, 4'd0, sprite_tile_y,
                    sprite_xnum, sprite_ynum,
                    flip_x, flip_y
                );
                fetch_row <= sprite_row;
                state <= FETCH_START;
            end

            RENDER_ADVANCE: begin
                if (render_line_slot + 1'd1 < render_line_count) begin
                    render_line_slot <= render_line_slot + 1'd1;
                    cache_decode_q <= cache_q;
                    state <= RENDER_PREP;
                end
                else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
            end

            TILE_ROW_ADDR: state <= TILE_ROW_WAIT;
            TILE_ROW_WAIT: begin
                // The row-scroll offset moves the running position only. MAME
                // fixes `page` from the raw scroll register before adding it
                // (ssv_v.cpp:684 vs :702), so the origin passed here must stay
                // `tile_scroll_x`. Adding the offset first lets a row-scroll
                // word of 0xffff -- a one-pixel step back -- carry a whole
                // scanline onto the neighbouring tilemap.
                tile_map_x <= tile_scroll_x + {1'b0, spr_data};
                tile_map_x0 <= tile_scroll_x;
                tile_screen_x <=
                    -$signed({7'd0,
                              tile_scroll_x[3:0] + spr_data[3:0]});
                tile_word_addr <= tile_address(
                    tile_scroll_x + {1'b0, spr_data},
                    tile_scroll_x,
                    tile_map_y, tile_mode
                );
                state <= TILE_CODE_ADDR;
            end

            TILE_CODE_ADDR: state <= TILE_CODE_WAIT;
            // tile_word_addr is even for every tile (see tile_address), so the
            // attribute is the odd word at the same bank index and arrives on
            // spr_data_next in this very cycle. The old
            // TILE_ATTR_ADDR/TILE_ATTR_WAIT pair -- and the +1 address bump
            // that fed them -- are gone; the address is recomputed from
            // scratch by tile_address() for the next tile either way.
            TILE_CODE_WAIT: begin
                tile_code_low <= spr_data;
                tile_attr <= spr_data_next;
                state <= TILE_PREP;
            end

            TILE_PREP: begin
                gfx_mode <= tile_mode[10:8];
                flip_x <= tile_flip_x;
                flip_y <= tile_flip_y;
                shadow <= tile_mode[11];
                color <= tile_attr[8:0];
                fetch_row <= tile_flip_y ? ~tile_map_y[2:0] :
                                           tile_map_y[2:0];
                if (tile_flip_y ? !tile_map_y[3] : tile_map_y[3])
                    fetch_code <= expand_code(cfg, tile_code_low, tile_attr) +
                                  1'd1;
                else
                    fetch_code <= expand_code(cfg, tile_code_low, tile_attr);
                state <= FETCH_START;
            end

            FETCH_START: begin
                // Arm the prefetch for the tile *after* the one now being
                // fetched. tile_map_x / tile_screen_x were already advanced to
                // the current tile, so tile_next_word_addr and
                // tile_next_in_range both refer to the correct successor.
                // Normal sprites index by code and never walk a map, so they
                // leave the sequencer idle.
                tile_pf_valid <= 1'b0;
                tile_pf_stage <= (render_tilemap && tile_next_in_range)
                                 ? 2'd1 : 2'd0;
                state <= FETCH_WAIT;
            end
            FETCH_WAIT: begin
                if (fetch_done) begin
                    if (pens == 128'd0) begin
                        // A fully transparent decoded row cannot affect the
                        // line buffer.  Skip its four four-pixel plot batches.
                        if (render_tilemap) begin
                            if (tile_screen_x + 11'sd16 >
                                $signed({2'd0, LAST_PIXEL})) begin
                                state <= RENDER_ADVANCE;
                            end
                            else begin
                                tile_screen_x <= tile_screen_x + 11'sd16;
                                tile_map_x <= tile_map_x + 17'd16;
                                tile_word_addr <= tile_next_word_addr;
                                if (tile_pf_valid) begin
                                    // Code and attribute were read out of the
                                    // idle sprite-RAM port during FETCH_WAIT
                                    // and already reduced to fetch operands, so
                                    // TILE_CODE_ADDR/TILE_CODE_WAIT/TILE_PREP
                                    // have nothing left to do.
                                    gfx_mode <= tile_mode[10:8];
                                    shadow <= tile_mode[11];
                                    flip_x <= tile_pf_flip_x;
                                    flip_y <= tile_pf_flip_y;
                                    color <= tile_pf_color;
                                    fetch_row <= tile_pf_row;
                                    fetch_code <= tile_pf_fetch_code;
                                    tile_code_low <= tile_pf_code_low;
                                    tile_attr <= tile_pf_attr;
                                    state <= FETCH_START;
                                end
                                else begin
                                    state <= TILE_CODE_ADDR;
                                end
                            end
                        end
                        else if (sprite_tile_x + 1'd1 < sprite_xnum) begin
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
                        else begin
                            state <= RENDER_ADVANCE;
                        end
                    end
                    else begin
                        plot_i <= 5'd0;
                        state <= PLOT;
                    end
                end
            end

            PLOT: begin
                if (plot_i == 5'd12) begin
                    if (render_tilemap) begin
                        if (tile_screen_x + 11'sd16 >
                            $signed({2'd0, LAST_PIXEL})) begin
                            state <= RENDER_ADVANCE;
                        end
                        else begin
                            tile_screen_x <= tile_screen_x + 11'sd16;
                            tile_map_x <= tile_map_x + 17'd16;
                            tile_word_addr <= tile_next_word_addr;
                            if (tile_pf_valid) begin
                                // See the matching note in FETCH_WAIT above.
                                gfx_mode <= tile_mode[10:8];
                                shadow <= tile_mode[11];
                                flip_x <= tile_pf_flip_x;
                                flip_y <= tile_pf_flip_y;
                                color <= tile_pf_color;
                                fetch_row <= tile_pf_row;
                                fetch_code <= tile_pf_fetch_code;
                                tile_code_low <= tile_pf_code_low;
                                tile_attr <= tile_pf_attr;
                                state <= FETCH_START;
                            end
                            else begin
                                state <= TILE_CODE_ADDR;
                            end
                        end
                    end
                    else if (sprite_tile_x + 1'd1 < sprite_xnum) begin
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
                    else begin
                        state <= RENDER_ADVANCE;
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
