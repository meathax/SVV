// SPDX-License-Identifier: GPL-3.0-or-later
// Simulation-only checker for tilemap page selection.
//
// MAME's ssv_v.cpp draw_row_64pixhigh() computes the page from the *raw*
// scroll register, before either the eaglshot kludge or the per-line row-scroll
// offset is folded in:
//
//     int tilemap_scrollx = m_scroll[scrollreg * 4 + 0];
//     const int size = 1 << (8 + ((mode & 0xe000) >> 13));
//     const int page = (tilemap_scrollx & 0x7fff) / size;      // <-- here
//     ...
//     if (BIT(mode, 12))                                       // row-scroll
//         tilemap_scrollx += m_spriteram[...];                 // <-- after
//
// `page` selects which tilemap the whole scanline reads. Deriving it from the
// row-scrolled position instead lets a per-line offset of a few pixels flip the
// entire line onto a neighbouring map, which draws as blank or as whatever else
// lives there. This checker flags every scanline where the two disagree.
//
// Bound into ssv_core, so nothing in rtl/ or in the shared testbench has to
// change to carry it.
`timescale 1ns/1ps

module ssv_tilemap_page_check (
    input logic clk,
    input logic rst,
    input logic frame_tick,

    // Every tilemap tile the object renderer draws, row-scrolled or not.
    // Only here to prove the row-scroll counters below are plumbed to a live
    // state encoding rather than silently reading a state that never occurs.
    input logic        obj_tile,

    // Object renderer, row-scroll path (TILE_ROW_WAIT).
    input logic        obj_active,
    input logic [15:0] obj_raw_scroll_x,
    input logic [16:0] obj_used_x_base,
    input logic [15:0] obj_mode,
    input logic  [2:0] obj_group,
    input logic  [8:0] obj_y,

    // Background renderer, row-scroll path (ROW_WAIT).
    input logic        bg_active,
    input logic [15:0] bg_raw_scroll_x,
    input logic [16:0] bg_used_x_base,
    input logic [15:0] bg_mode,
    input logic  [8:0] bg_y,

    // SDRAM demand. The hardware symptom is drifting horizontal bands plus
    // pitch-dropped audio, which is what starving the graphics row fetch (p1)
    // against the ES5506 sample fetch (p4) would look like. Neither is
    // frame-synchronous, so measure the request rate rather than infer it.
    input logic        p1_req,
    input logic        p1_ack,
    input logic        p4_req,
    input logic        p4_ack,

    // Object-renderer state occupancy. The renderer is compute-bound (69% of a
    // missed scanline is plotting, 5% is waiting for SDRAM), so the only way to
    // pick an optimisation honestly is to know which states actually burn the
    // cycles rather than inferring it from two aggregate counters.
    input logic        obj_busy,
    input logic  [5:0] obj_state,
    input logic        obj_fetch_start,

    // RAM-sizing evidence. The palette's odd bank stores 16 bits per entry but
    // video uses only the low 8 (red); the upper byte is SSV's unused field.
    // Narrowing it would halve that bank (64 -> 32 M10K) but changes what the
    // CPU reads back -- so count whether the CPU ever reads the palette at all.
    // Likewise track how much of the 256 KB sprite RAM the game actually walks.
    input logic        pal_sel,
    input logic        cpu_we,
    input logic        cpu_ack,
    input logic [16:0] spr_cpu_addr,
    input logic        spr_cpu_we
);

function automatic logic [16:0] page_of(
    input logic [16:0] x,
    input logic [15:0] mode
);
    logic [3:0] size_shift;
    begin
        size_shift = 4'd8 + {1'b0, mode[15:13]};
        page_of = (x & 17'h07fff) >> size_shift;
    end
endfunction

int frame_idx;
int obj_tiles;                      // tilemap tiles drawn (liveness control)
int obj_rows, bg_rows;              // row-scrolled scanlines seen
int obj_bad, bg_bad;                // ... of which pick the wrong page
int obj_bad_frame, bg_bad_frame;    // this frame only
int bg_neg_frame;                   // negative row-scroll offsets this frame
// Cycles the object renderer spends in each state while busy, and how many
// graphics fetches it starts. Totals over the run; the ratio is what matters.
int obj_state_cycles [0:47];
int obj_busy_cycles, obj_fetches;
// p4 (ES5506 sample) service latency: request rising edge to ack.
int p4_lat_worst, p4_lat_total, p4_lat_count, p4_lat_timer;
logic p4_inflight;

int  pal_reads, pal_writes;
logic cpu_ack_d;
logic [16:0] spr_addr_hi;           // highest sprite-RAM word the CPU touched
int  spr_writes;

int p1_frame, p4_frame;             // SDRAM read requests raised this frame
int p1_total, p4_total;
int p4_peak, p4_peak_frame;
logic p1_req_d, p4_req_d;
int worst_frame, worst_bad;
int detail_budget;
// Counting by default so a baseline run can characterise the defect; +TMPAGE_FATAL
// makes it a gate that stops on the first wrong page.
logic fatal_mode;

logic [16:0] page_ref, page_used;

initial begin
    fatal_mode = $test$plusargs("TMPAGE_FATAL");
    frame_idx = 0;
    obj_tiles = 0;
    obj_rows = 0; bg_rows = 0;
    obj_bad = 0; bg_bad = 0;
    obj_bad_frame = 0; bg_bad_frame = 0;
    bg_neg_frame = 0;
    p1_frame = 0; p4_frame = 0;
    p1_total = 0; p4_total = 0;
    p4_peak = 0; p4_peak_frame = -1;
    p1_req_d = 1'b0; p4_req_d = 1'b0;
    for (int s = 0; s < 48; s++) obj_state_cycles[s] = 0;
    obj_busy_cycles = 0; obj_fetches = 0;
    p4_lat_worst = 0; p4_lat_total = 0; p4_lat_count = 0;
    p4_lat_timer = 0; p4_inflight = 1'b0;
    pal_reads = 0; pal_writes = 0; cpu_ack_d = 1'b0;
    spr_addr_hi = 17'd0; spr_writes = 0;
    worst_frame = -1; worst_bad = 0;
    // Enough to characterise the pattern without drowning the log.
    detail_budget = 24;
end

always_ff @(posedge clk) begin
    if (!rst) begin
        // Count request rising edges: the SDRAM contract is one transaction
        // per rising edge of req, so this is the true demand on each port.
        p1_req_d <= p1_req;
        p4_req_d <= p4_req;
        if (p1_req && !p1_req_d) begin
            p1_frame <= p1_frame + 1;
            p1_total <= p1_total + 1;
        end
        if (p4_req && !p4_req_d) begin
            p4_frame <= p4_frame + 1;
            p4_total <= p4_total + 1;
        end
        // One count per completed CPU access, not per cycle of a stretched ack.
        cpu_ack_d <= cpu_ack;
        if (pal_sel && cpu_ack && !cpu_ack_d) begin
            if (cpu_we) pal_writes <= pal_writes + 1;
            else        pal_reads  <= pal_reads  + 1;
        end
        if (spr_cpu_we) begin
            spr_writes <= spr_writes + 1;
            if (spr_cpu_addr > spr_addr_hi) spr_addr_hi <= spr_cpu_addr;
        end

        if (obj_busy) begin
            obj_busy_cycles <= obj_busy_cycles + 1;
            obj_state_cycles[obj_state] <= obj_state_cycles[obj_state] + 1;
        end
        if (obj_fetch_start)
            obj_fetches <= obj_fetches + 1;

        // p4 round trip. The sample engine has never been exercised with real
        // data in a full-core run, so this is the first measurement of what
        // latency it actually sees.
        if (p4_req && !p4_req_d) begin
            p4_inflight <= 1'b1;
            p4_lat_timer <= 0;
        end
        else if (p4_inflight) begin
            p4_lat_timer <= p4_lat_timer + 1;
            if (p4_ack) begin
                p4_inflight <= 1'b0;
                p4_lat_total <= p4_lat_total + p4_lat_timer;
                p4_lat_count <= p4_lat_count + 1;
                if (p4_lat_timer > p4_lat_worst)
                    p4_lat_worst <= p4_lat_timer;
            end
        end

        if (obj_tile)
            obj_tiles <= obj_tiles + 1;
        if (obj_active) begin
            obj_rows <= obj_rows + 1;
            page_ref  = page_of({1'b0, obj_raw_scroll_x}, obj_mode);
            page_used = page_of(obj_used_x_base, obj_mode);
            if (page_ref != page_used) begin
                obj_bad <= obj_bad + 1;
                obj_bad_frame <= obj_bad_frame + 1;
                if (detail_budget > 0) begin
                    detail_budget <= detail_budget - 1;
                    $display("TMPAGE_BAD f=%0d src=OBJ y=%0d grp=%0d mode=%04x size=%0d raw=%0d used=%0d page_ref=%0d page_used=%0d",
                             frame_idx, obj_y, obj_group, obj_mode,
                             1 << (8 + obj_mode[15:13]),
                             obj_raw_scroll_x, obj_used_x_base,
                             page_ref, page_used);
                end
                if (fatal_mode)
                    $fatal(1, "tilemap page from row-scrolled origin: OBJ y=%0d grp=%0d page_ref=%0d page_used=%0d",
                           obj_y, obj_group, page_ref, page_used);
            end
        end
        if (bg_active) begin
            bg_rows <= bg_rows + 1;
            // A row-scroll word with bit 15 set reads as a small negative
            // offset. Those are the ones that pull a line back across a page
            // boundary; count them so a clean frame can be told apart from a
            // frame that simply never used one.
            if ((bg_used_x_base - {1'b0, bg_raw_scroll_x}) & 17'h08000)
                bg_neg_frame <= bg_neg_frame + 1;
            page_ref  = page_of({1'b0, bg_raw_scroll_x}, bg_mode);
            page_used = page_of(bg_used_x_base, bg_mode);
            if (page_ref != page_used) begin
                bg_bad <= bg_bad + 1;
                bg_bad_frame <= bg_bad_frame + 1;
                if (detail_budget > 0) begin
                    detail_budget <= detail_budget - 1;
                    $display("TMPAGE_BAD f=%0d src=BG y=%0d mode=%04x size=%0d raw=%0d used=%0d page_ref=%0d page_used=%0d",
                             frame_idx, bg_y, bg_mode,
                             1 << (8 + bg_mode[15:13]),
                             bg_raw_scroll_x, bg_used_x_base,
                             page_ref, page_used);
                end
                if (fatal_mode)
                    $fatal(1, "tilemap page from row-scrolled origin: BG y=%0d page_ref=%0d page_used=%0d",
                           bg_y, page_ref, page_used);
            end
        end
        if (frame_tick) begin
            // How far has the stage actually travelled, and is the layer using
            // the offsets that can trip the page? Printed sparsely so it costs
            // nothing to leave on.
            if ((frame_idx % 50) == 0)
                $display("TMPAGE_SCROLL f=%0d bg_scroll=%0d bg_neg_rows=%0d gfx_reads=%0d smp_reads=%0d",
                         frame_idx, bg_raw_scroll_x, bg_neg_frame,
                         p1_frame, p4_frame);
            if (p4_frame > p4_peak) begin
                p4_peak <= p4_frame;
                p4_peak_frame <= frame_idx;
            end
            bg_neg_frame <= 0;
            p1_frame <= 0;
            p4_frame <= 0;
            if (obj_bad_frame + bg_bad_frame > 0) begin
                $display("TMPAGE_FRAME f=%0d obj_bad=%0d bg_bad=%0d",
                         frame_idx, obj_bad_frame, bg_bad_frame);
                if (obj_bad_frame + bg_bad_frame > worst_bad) begin
                    worst_bad <= obj_bad_frame + bg_bad_frame;
                    worst_frame <= frame_idx;
                end
            end
            frame_idx <= frame_idx + 1;
            obj_bad_frame <= 0;
            bg_bad_frame <= 0;
        end
    end
end

final begin
    $display("TMPAGE_TOTAL obj_tiles=%0d obj_rows=%0d obj_bad=%0d bg_rows=%0d bg_bad=%0d worst_frame=%0d worst_bad=%0d",
             obj_tiles, obj_rows, obj_bad, bg_rows, bg_bad,
             worst_frame, worst_bad);
    $display("SDRAM_DEMAND gfx_reads=%0d smp_reads=%0d smp_peak_per_frame=%0d (frame %0d)",
             p1_total, p4_total, p4_peak, p4_peak_frame);
    $display("P4_LATENCY worst=%0d avg=%0d over %0d transactions",
             p4_lat_worst,
             (p4_lat_count != 0) ? (p4_lat_total / p4_lat_count) : 0,
             p4_lat_count);
    $display("PALETTE_ACCESS cpu_reads=%0d cpu_writes=%0d", pal_reads, pal_writes);
    $display("SPRITERAM_USE cpu_writes=%0d highest_word=0x%05x of 0x1ffff",
             spr_writes, spr_addr_hi);
    $display("OBJ_BUDGET busy_cycles=%0d fetches=%0d cycles_per_fetch=%0d",
             obj_busy_cycles, obj_fetches,
             (obj_fetches != 0) ? (obj_busy_cycles / obj_fetches) : 0);
    // State names follow the enum in ssv_cached_sprite_renderer.sv.
    for (int s = 0; s < 48; s++)
        if (obj_state_cycles[s] != 0)
            $display("OBJ_STATE %0d cycles=%0d pct=%0d",
                     s, obj_state_cycles[s],
                     (obj_busy_cycles != 0)
                         ? ((obj_state_cycles[s] * 100) / obj_busy_cycles) : 0);
end

endmodule

// TILE_ROW_WAIT is state 27 and ROW_WAIT is state 4; both are the cycle in
// which the renderer latches the row-scrolled origin for the scanline.
// TILE_PREP is 32, the same encoding the frame-CRC testbench already traces.
bind ssv_core ssv_tilemap_page_check u_tilemap_page_check (
    .clk(clk_sys),
    .rst(rst),
    .frame_tick(video_enable && vblank_pulse),

    .obj_tile(sprite_renderer.state == 6'd32),
    .obj_active(sprite_renderer.state == 6'd27),
    .obj_raw_scroll_x(tilemap_scrolls[{sprite_renderer.prep_tile_group,
                                       6'd0} +: 16]),
    .obj_used_x_base(sprite_renderer.tile_scroll_x +
                     {1'b0, sprite_renderer.spr_data}),
    .obj_mode(sprite_renderer.tile_mode),
    .obj_group(sprite_renderer.prep_tile_group),
    .obj_y(sprite_renderer.target_y_latched),

    .bg_active(background_renderer.state == 5'd4),
    .bg_raw_scroll_x(scroll[0]),
    .bg_used_x_base({1'b0, background_renderer.scroll_x} +
                    {1'b0, background_renderer.spr_data}),
    .bg_mode(scroll[3]),
    .bg_y(background_renderer.target_y_latched),

    // The graphics fetch moved from p1 to p2 (128-bit) with the repack.
    .p1_req(sdr_p2_req),
    .p1_ack(sdr_p2_ack),
    .p4_req(sdr_p4_req),
    .p4_ack(sdr_p4_ack),

    .obj_busy(obj_busy),
    .obj_state(sprite_renderer.state),
    .obj_fetch_start(sprite_renderer.fetch_start),

    .pal_sel(sel_palette),
    .cpu_we(m_we),
    .cpu_ack(ack_r),
    .spr_cpu_addr(spr_addr),
    .spr_cpu_we(m_req && m_we && sel_sprram)
);
