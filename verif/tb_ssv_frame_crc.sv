`timescale 1ns/1ps
// Real-ROM frame CRC dump + attract/coin soak for Dyna Gear G1/G2/G3.
// Plusargs:
//   +MAINROM= +SPRROM= +FRAME_CRC=path +STATE_CRC=path
//   +FRAMES=N +SOAK_FRAMES=N
//   +SCENARIO=attract_idle|coin_start_p1|coin_start_p1_gameplay
//   +DUMP_FRAME_DIAG (IRQ/list/scroll/pal snapshots at vb-edge)
//   +REQUIRE_GAMEPLAY (require a jungle-stage visual at frame 850)
//   +DUMP_PPM=path +DUMP_PPM_FRAME=N  (write one 336x240 raw PPM after VE)
//   +USE_FRAC_CE (default on) uses ssv_tb_ce_cpu

module tb_ssv_frame_crc;
`include "ssv_tb_crc32.svh"

// The behavioural SDRAM model below decodes the same regions the RTL does.
// Import the layout instead of restating it: five benches used to carry their
// own copies of 0x0100000/0x1100000/0x1160000, and a divergence between them
// and ssv_pkg is exactly the "wrong ROM load offset" fake bug CLAUDE.md warns
// about.
import ssv_pkg::*;

logic clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;

logic rst, ce_cpu;
logic sdr_p0_req, sdr_p0_ack;
logic [SDR_AW:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p2_req, sdr_p2_ack;
logic [SDR_AW:4] sdr_p2_addr;
logic [127:0] sdr_p2_dout;
logic sdr_wr_req, sdr_wr_ack;
logic sdr_p4_req, sdr_p4_ack;
logic [SDR_AW:1] sdr_p4_addr;
logic [15:0] sdr_p4_dout;
logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;

// ---------------------------------------------------------------------------
// Two SDRAM models, selected at run time by +REAL_SDRAM.
//
// beh_*  the original one-cycle-per-port behavioural model. Every existing gate
//        and the golden frame CRC were produced against it, so it stays the
//        default and its behaviour is untouched.
// real_* rtl/mem/sdram.sv driving a chip model, at the true clk_ram = 2 x
//        clk_sys ratio. This is the only configuration in which a scanline can
//        actually miss its deadline, which is the precondition for the
//        hardware-only corruption this core shows on real silicon.
//
// Both models see every request; only the responses are muxed.
// ---------------------------------------------------------------------------
// Defaults to the behavioural model from time zero: the muxes and core_rst
// read this before the plusargs are parsed.
logic        use_real_sdram = 1'b0;
logic        beh_p0_ack, beh_p2_ack, beh_wr_ack, beh_p4_ack;
logic [15:0] beh_p0_dout, beh_p4_dout;
logic [127:0] beh_p2_dout;
logic        real_p0_ack, real_p2_ack, real_wr_ack, real_p4_ack;
logic [15:0] real_p0_dout, real_p4_dout;
logic [127:0] real_p2_dout;
logic        sdram_ready;

// clk_ram is exactly twice clk_sys on hardware (96.6 / 48.3 MHz). Getting this
// ratio wrong would silently change every bandwidth number this harness exists
// to produce.
logic clk_ram = 1'b0;
always #2.5 clk_ram = ~clk_ram;

// Must match Arcade-SSV.sv's controller geometry, or +REAL_SDRAM measures a
// part the board does not have. AW then derives to 26 = ssv_pkg::SDR_AW, so
// the port widths line up with the core's without truncation -- and this build
// suppresses WIDTH warnings, so a mismatch here would be silent.
ssv_sdram_harness #(
    .BANK_BITS(2), .ROW_BITS(13), .COL_BITS(11), .TRFC_CYC(11)
) u_sdram (
    .clk_ram(clk_ram), .init(rst), .ready(sdram_ready),
    .wr_req(sdr_wr_req), .wr_addr(sdr_wr_addr), .wr_din(sdr_wr_din),
    .wr_be(sdr_wr_be), .wr_ack(real_wr_ack),
    .p0_req(sdr_p0_req), .p0_addr(sdr_p0_addr),
    .p0_dout(real_p0_dout), .p0_ack(real_p0_ack),
    .p2_req(sdr_p2_req), .p2_addr(sdr_p2_addr),
    .p2_dout(real_p2_dout), .p2_ack(real_p2_ack),
    .p4_req(sdr_p4_req), .p4_addr(sdr_p4_addr),
    .p4_dout(real_p4_dout), .p4_ack(real_p4_ack)
);

assign sdr_p0_ack  = use_real_sdram ? real_p0_ack  : beh_p0_ack;
assign sdr_p2_ack  = use_real_sdram ? real_p2_ack  : beh_p2_ack;
assign sdr_wr_ack  = use_real_sdram ? real_wr_ack  : beh_wr_ack;
assign sdr_p4_ack  = use_real_sdram ? real_p4_ack  : beh_p4_ack;
assign sdr_p0_dout = use_real_sdram ? real_p0_dout : beh_p0_dout;
assign sdr_p2_dout = use_real_sdram ? real_p2_dout : beh_p2_dout;
assign sdr_p4_dout = use_real_sdram ? real_p4_dout : beh_p4_dout;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;

logic [15:0] in_p1, in_p2, in_system, in_extra, in_dsw1, in_dsw2;

byte main_rom [0:1048575];
byte sprite_rom [0:12582911];
byte sample_rom [0:4194303];
integer sample_fd, sample_count;
string sample_path;
logic [15:0] external_ram [0:196607];

string main_path, sprite_path, crc_path, state_path, scenario;
integer main_fd, sprite_fd, crc_fd, state_fd;
integer main_count, sprite_count, i;
// 32-bit `integer` caps +CYCLES at 2^31-1, which is only ~2640 post-VE frames
// (~805k clk_sys per 60 Hz frame plus ~26M of boot).  The long gameplay
// scenario needs more than that, so the cycle budget is 64-bit.
longint cycle_count, max_cycles;
integer p1_transactions;
integer frame_idx, post_ve_frames, max_frames, soak_frames;
integer active_pixels, nonblack_pixels, post_ve_nonblack;
integer select_header_pixels, frame_nonblack;
integer gameplay_green_pixels;
logic require_play, play_reached, require_gameplay, gameplay_reached;
logic ve_seen, vb_d, frame_active;
logic [31:0] idx_crc, rgb_crc;
logic [14:0] idx15;
integer px_count;
logic p0_seen, p1_seen, wr_seen, p4_seen;
logic [3:0] p0_hold, p1_hold, wr_hold, p4_hold;
logic [SDR_AW:0] p0_byte_addr, p1_byte_addr;
integer ext_index, sprite_index, packed_code, packed_row;
integer raw_q0_index, raw_q1_index, raw_q2_index;
integer stuck, last_pc_i;
logic [31:0] last_pc;
integer bg_overruns, obj_overruns;
integer obj_line_cycles, obj_rom_wait_cycles, obj_max_line_cycles;
integer obj_line_descriptors, obj_line_fetches, obj_line_tilemap_fetches;
integer obj_line_plot_cycles;
integer obj_max_line_entries;
integer cache_build_cycles, cache_build_max, cache_build_max_frame;
integer cache_build_start_v, cache_deadline_hits;
logic   cache_busy_d;
logic obj_busy_d, dump_renderer_budget, stop_on_renderer_overrun;
logic obj_cache_overflow_d;
integer dump_x, dump_y, dump_count;
integer overflow_i, overflow_entry, overflow_tile_desc, overflow_sprite_desc;
integer overflow_tile_groups [0:7];
logic [127:0] overflow_desc;
logic dump_pixels, dump_frame_diag, dump_ppm_en, dump_ppm_open;
logic ppm_open_event;
logic ignore_overrun;
string irq_schedule_path, ppm_path, ppm_prefix;
integer ppm_fd, ppm_frame, ppm_pixels;
integer ppm_start, ppm_count, ppm_step, ppm_shots_done;
integer irq_schedule_fd, irq_scan_result;
logic diff_irq_enabled, diff_vblank_pulse, diff_count_started;
longint unsigned retire_count, next_irq_retire;
longint unsigned last_vb_retire, last_irq_entry_retire;
integer irq_entries_post_ve, vb_pulses_post_ve;
integer diag_i;
logic [31:0] list_crc, scroll_crc, spr8k_crc, pal_crc;

// Sprite RAM is two parity banks in ssv_core (even words / odd words at the
// same bank index), so recombine them here. The diagnostic CRCs below then see
// exactly the flat 131072-word array they saw when it was a single dpram.
function automatic logic [15:0] spr_peek(input logic [16:0] word_addr);
    spr_peek = word_addr[0]
        ? dut.sprite_ram_odd.sim_peek(word_addr[16:1])
        : dut.sprite_ram_even.sim_peek(word_addr[16:1]);
endfunction

ssv_tb_ce_cpu u_ce (.clk(clk_sys), .rst(rst), .ce_cpu(ce_cpu));

// With the real controller the core must stay in reset until the chip has
// finished its init sequence, exactly as Arcade-SSV.sv does on hardware.
// Identical to `rst` when the behavioural model is selected.
wire core_rst = rst | (use_real_sdram & ~sdram_ready);

ssv_core dut (
    .cfg(ssv_pkg::cfg_dynagear()),
    .clk_sys(clk_sys), .rst(core_rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .in_dsw1(in_dsw1), .in_dsw2(in_dsw2),
    .in_p1(in_p1), .in_p2(in_p2),
    .in_system(in_system), .in_extra(in_extra),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

// ---------------------------------------------------------------------------
// Phase 0 instrumentation (C3 line occupancy, C4 dropped start, C5 bg-vs-obj
// overlap, C6 no_rw_check proofs, C7 ES5506 bank/compression use).
//
// All of it is observation only; nothing here drives the DUT, so every existing
// gate and the golden frame CRC are untouched.
// ---------------------------------------------------------------------------

// --- C3: full per-scanline descriptor occupancy distribution ---------------
//
// obj_max_line_entries already records the peak, but a single peak cannot say
// whether 96 slots are comfortable or one busy scene away from dropping
// sprites. LINE_SLOTS is 96 and a line that reaches it has ALREADY silently
// dropped its 97th descriptor, so `occ_at_cap` is the number that decides
// whether raising it to 128 is warranted. Sampled when the vblank build
// finishes, which is the only point the table is complete and stable.
localparam int OCC_BINS = 256;
integer occ_hist [0:OCC_BINS-1];
integer occ_max, occ_max_frame, occ_at_cap, occ_lines_sampled;
integer occ_i, occ_v;
logic   obj_cache_busy_d;

// occ_hist above reads line_counts, which SATURATES at LINE_SLOTS, so it can
// only report "this line hit the cap" and never how far past it the scene
// went. That is enough to justify raising LINE_SLOTS but not to choose a new
// value. dut.sprite_renderer.sim_line_demand is the uncapped shadow count of
// every bucket write attempt (sim-only, `ifdef SIMULATION`), so `dem_max` is
// the depth the scene actually asked for.
integer dem_hist [0:OCC_BINS-1];
integer dem_max, dem_max_frame, dem_over_cap, dem_v;

// --- C4: `start` pulses arriving while the renderer is not in IDLE --------
//
// `start` is a one-cycle pulse sampled only in IDLE, so one missed pulse costs
// the NEXT scanline all of its objects. Counting it settles whether the
// latch is a real fix or dead code for this title.
integer start_dropped, start_total;

// --- C5: background renderer started while the object renderer is busy ----
//
// Distinct from bg_ack_while_obj_owns above: that catches a completed
// transaction, this catches the START, which is the condition that lets the bg
// renderer latch the object renderer's tile code (ssv_core.sv:352-358).
integer bg_start_while_obj_busy;

// --- C7: ES5506 voices outside the implemented subset ---------------------
integer es_nonbank2_slots, es_compressed_slots;
logic [4:0] es_voice_d;

initial begin
    for (occ_i = 0; occ_i < OCC_BINS; occ_i = occ_i + 1) occ_hist[occ_i] = 0;
    for (occ_i = 0; occ_i < OCC_BINS; occ_i = occ_i + 1) dem_hist[occ_i] = 0;
    occ_max = 0; occ_max_frame = 0; occ_at_cap = 0; occ_lines_sampled = 0;
    dem_max = 0; dem_max_frame = 0; dem_over_cap = 0;
    start_dropped = 0; start_total = 0;
    bg_start_while_obj_busy = 0;
    es_nonbank2_slots = 0; es_compressed_slots = 0;
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        obj_cache_busy_d <= 1'b0;
        es_voice_d       <= 5'd0;
    end else begin
        obj_cache_busy_d <= dut.obj_cache_busy;
        es_voice_d       <= dut.sound_voices.eng_voice;

        // C3 -- the build has just completed; the bucket table is final.
        if (obj_cache_busy_d && !dut.obj_cache_busy) begin
            for (occ_i = 0; occ_i < 240; occ_i = occ_i + 1) begin
                occ_v = int'(dut.sprite_renderer.line_counts[occ_i]);
                if (occ_v >= 0 && occ_v < OCC_BINS)
                    occ_hist[occ_v] = occ_hist[occ_v] + 1;
                occ_lines_sampled = occ_lines_sampled + 1;
                if (occ_v >= int'(dut.sprite_renderer.LINE_SLOTS))
                    occ_at_cap = occ_at_cap + 1;
                if (occ_v > occ_max) begin
                    occ_max = occ_v;
                    occ_max_frame = post_ve_frames;
                end

                // Uncapped demand for the same scanline.
                dem_v = dut.sprite_renderer.sim_line_demand[occ_i];
                if (dem_v >= 0 && dem_v < OCC_BINS)
                    dem_hist[dem_v] = dem_hist[dem_v] + 1;
                else if (dem_v >= OCC_BINS)
                    dem_hist[OCC_BINS-1] = dem_hist[OCC_BINS-1] + 1;
                if (dem_v > int'(dut.sprite_renderer.LINE_SLOTS))
                    dem_over_cap = dem_over_cap + 1;
                if (dem_v > dem_max) begin
                    dem_max = dem_v;
                    dem_max_frame = post_ve_frames;
                end
            end
        end

        // C4 -- count every start pulse and the ones that cannot be taken.
        if (dut.renderer_line_start) begin
            start_total <= start_total + 1;
            if (dut.sprite_renderer.state != 6'd0)   // not IDLE
                start_dropped <= start_dropped + 1;
        end

        // C5
        if (dut.renderer_line_start && dut.obj_busy)
            bg_start_while_obj_busy <= bg_start_while_obj_busy + 1;

        // C7 -- sample each voice once, as the engine advances to it.
        //
        // Only RUNNING voices count. A halted voice has CR_STOP (16'h0003) set
        // and would be silent on real hardware too, so counting those would
        // report a five-figure "bug" that is really just idle voices -- the
        // question is whether a voice that should be HEARD is being muted by
        // the bank-2-only and uncompressed-only restrictions.
        if (dut.sound_voices.eng_voice != es_voice_d &&
            dut.sound_voices.eng_cr_valid &&
            !(|(dut.sound_voices.eng_cr & 16'h0003))) begin      // CR_STOP
            if (|(dut.sound_voices.eng_cr & 16'h2000))           // CR_CMPD
                es_compressed_slots <= es_compressed_slots + 1;
            else if (dut.sound_voices.eng_cr[15:14] != 2'b10)
                es_nonbank2_slots <= es_nonbank2_slots + 1;
        end
    end
end

// --- C6: the three `no_rw_check` arrays --------------------------------------
//
// These should be silent BY CONSTRUCTION, and saying why is the point.
// `state` is a single register, writes to descriptor_cache happen only in
// BUILD_STORE and to line_entries only in BUILD_BUCKET_WRITE, while the reads
// happen only in RENDER_* states -- so build and render can never collide.
// line_page_starts is different: its read at ssv_cached_sprite_renderer.sv:680
// is unconditional and DOES collide on every build cycle, by design; it is safe
// only because its single consumer (RENDER_COUNT_WAIT) is reachable only from
// RENDER_COUNT_READ, which never writes.
//
// docs/DYNAGEAR_HW_RENDER_FIX_PLAN.md:72-80 flags all three as unproven. These
// assertions convert that argument into a measurement. If any fires, the
// structural reasoning above is wrong and the attribute must come off.
integer c6_desc_hits, c6_entry_hits, c6_page_consume_hits;
initial begin
    c6_desc_hits = 0; c6_entry_hits = 0; c6_page_consume_hits = 0;
end

// State encodings taken from the state_t enum in
// rtl/video/ssv_cached_sprite_renderer.sv:92-112 (IDLE is 0), matching the
// existing `6'd30 // TILE_PREP` idiom already used in this file.
localparam logic [5:0] ST_BUILD_STORE        = 6'd13;
localparam logic [5:0] ST_BUILD_BUCKET_WRITE = 6'd15;
localparam logic [5:0] ST_RENDER_COUNT_READ  = 6'd17;
localparam logic [5:0] ST_RENDER_COUNT_WAIT  = 6'd18;
localparam logic [5:0] ST_RENDER_LINE_READ   = 6'd19;
localparam logic [5:0] ST_RENDER_READ        = 6'd20;
localparam logic [5:0] ST_RENDER_DECODE      = 6'd21;
localparam logic [5:0] ST_RENDER_PREP        = 6'd22;

// Reconstruct the exact enable conditions from the RAM process at
// ssv_cached_sprite_renderer.sv:697-710, so these track the design rather than
// a paraphrase of it.
wire c6_entry_rd = (dut.sprite_renderer.state == ST_RENDER_LINE_READ) ||
                   (dut.sprite_renderer.state == ST_RENDER_DECODE)    ||
                   (dut.sprite_renderer.state == ST_RENDER_PREP);
wire c6_entry_wr = (dut.sprite_renderer.state == ST_BUILD_BUCKET_WRITE);
wire c6_desc_rd  = (dut.sprite_renderer.state == ST_RENDER_READ) ||
                   (dut.sprite_renderer.state == ST_RENDER_PREP);
wire c6_desc_wr  = dut.sprite_renderer.cache_we;   // implies BUILD_STORE

always_ff @(posedge clk_sys) if (!rst) begin
    // C6a / C6b: a read and a write of the same array in the same cycle. Both
    // must be impossible because `state` is one register and the writes live in
    // BUILD_* while the reads live in RENDER_*.
    if (c6_desc_wr && c6_desc_rd) begin
        c6_desc_hits <= c6_desc_hits + 1;
        $display("C6a descriptor_cache read-during-write state=%0d cyc=%0d",
                 dut.sprite_renderer.state, cycle_count);
    end
    if (c6_entry_wr && c6_entry_rd) begin
        c6_entry_hits <= c6_entry_hits + 1;
        $display("C6b line_entries read-during-write state=%0d cyc=%0d",
                 dut.sprite_renderer.state, cycle_count);
    end

    // C6c: line_page_q / line_count_q are read unconditionally and DO collide
    // with the build writes by design. They are safe only because their single
    // consumer, RENDER_COUNT_WAIT, is reachable only from RENDER_COUNT_READ --
    // which never writes. Assert exactly that.
    if (dut.sprite_renderer.state == ST_RENDER_COUNT_WAIT &&
        tm_state_d != ST_RENDER_COUNT_READ &&
        tm_state_d != ST_RENDER_COUNT_WAIT) begin
        c6_page_consume_hits <= c6_page_consume_hits + 1;
        $display("C6c RENDER_COUNT_WAIT entered from state %0d cyc=%0d",
                 tm_state_d, cycle_count);
    end
end

// ---------------------------------------------------------------------------
// SDRAM port model.
//
// Default: every port is served independently after one cycle. That is what
// all existing gates and the golden frame CRC were produced against, so it is
// preserved bit-for-bit.
//
// +P1_LATENCY=N inserts N extra cycles before each GFX-fetch ack. The real
// rtl/mem/sdram.sv serialises all six ports through one chip with ~11 clk_ram
// per 4-word burst plus arbitration and refresh stalls, so the renderer's real
// service time is several times this model's. Starving p1 is what makes a
// scanline miss its deadline, which is the precondition for the whole class of
// hardware-only rendering faults -- with the default model, `overruns bg=0
// obj=0` across 950 frames and none of them are reachable.
// ---------------------------------------------------------------------------
int p1_latency;
int p1_delay;
// A renderer must never complete a transaction it does not own.
int bg_ack_while_obj_owns;
logic [1:0] bg_fetch_state_d;
logic obj_owned_d;

// +DUMP_TILEMAP=<frame> traces every tilemap tile fetch on that post-VE frame.
// The scroll-triggered background corruption shows font glyphs where scenery
// belongs, which means a wrong tile *index* -- i.e. tile_word_addr is landing
// in the wrong tilemap. Dumping the address inputs alongside the result
// localises that to either the address maths or the scroll/mode registers
// feeding it.
int dump_tilemap_frame;
logic [5:0] tm_state_d;

// Does Dyna Gear ever read the $500008 "extra inputs" window? The SAM-5127
// cartridge has filtered 3P/4P connectors and this is the only decoded input
// window we cannot account for, so it is the candidate for where those players
// read back. Counting the accesses settles whether the port is dead for this
// title (expected) or live (which would be a surprise worth chasing).
int extra_reads;
logic extra_ack_d;

// Peak descriptor-cache occupancy. CACHE_ENTRIES is 1536 and costs 22 M10K of
// a 553-block device; 1024 entries would cost 11. Whether that reduction is
// even arguable depends on how close real gameplay gets to the ceiling, so
// measure it rather than guess.
int cache_peak, cache_peak_frame;

// Sticky multi-cycle ack (covers CE gaps from fractional enable).
always_ff @(posedge clk_sys) begin
    beh_p0_ack <= 1'b0;
    beh_p2_ack <= 1'b0;
    beh_wr_ack <= 1'b0;
    beh_p4_ack <= 1'b0;
    if (rst) begin
        p0_seen <= 1'b0; p1_seen <= 1'b0;
        wr_seen <= 1'b0; p4_seen <= 1'b0;
        p0_hold <= 4'd0; p1_hold <= 4'd0;
        wr_hold <= 4'd0; p4_hold <= 4'd0;
        p1_transactions <= 0;
        p1_delay <= 0;
        bg_ack_while_obj_owns <= 0;
        bg_fetch_state_d <= 2'd0;
        obj_owned_d <= 1'b0;
        tm_state_d <= 6'd0;
        extra_reads <= 0;
        extra_ack_d <= 1'b0;
        cache_peak <= 0;
        cache_peak_frame <= 0;
    end else begin
        // Ownership check, written against observable behaviour rather than
        // against the fix, so it is valid with or without it: the background
        // fetcher must never complete a transaction (leave WAIT_ACK=1) while
        // the object renderer owns p1. If it does, it has just latched the
        // object renderer's tile data as its own background tile.
        bg_fetch_state_d <= dut.background_renderer.fetch.state;
        obj_owned_d      <= dut.obj_busy;

        // Count completed CPU reads of the $500008 extra-input window.
        extra_ack_d <= dut.ack_r;
        if (dut.sel_extra && !dut.m_we && dut.ack_r && !extra_ack_d)
            extra_reads <= extra_reads + 1;

        if (dut.sprite_renderer.cache_count > cache_peak) begin
            cache_peak <= dut.sprite_renderer.cache_count;
            cache_peak_frame <= post_ve_frames;
        end

        // Trace tilemap tile fetches on the requested frame. TILE_PREP is
        // where code+attr have both landed, so every field below is settled.
        tm_state_d <= dut.sprite_renderer.state;
        if (dump_tilemap_frame >= 0 && post_ve_frames == dump_tilemap_frame &&
            tm_state_d != dut.sprite_renderer.state &&
            dut.sprite_renderer.state == 6'd30) begin   // TILE_PREP
            $display("TM f=%0d y=%0d grp=%0d mode=%04x sz=%0d sx=%05x mapx=%05x mapy=%05x addr=%05x code=%04x attr=%04x scrx=%0d",
                     post_ve_frames, dut.sprite_renderer.target_y_latched,
                     dut.sprite_renderer.prep_tile_group,
                     dut.sprite_renderer.tile_mode,
                     dut.sprite_renderer.tile_mode[15:13],
                     dut.sprite_renderer.tile_scroll_x,
                     dut.sprite_renderer.tile_map_x,
                     dut.sprite_renderer.tile_map_y,
                     dut.sprite_renderer.tile_word_addr,
                     dut.sprite_renderer.tile_code_low,
                     dut.sprite_renderer.tile_attr,
                     dut.sprite_renderer.tile_screen_x);
        end
        if (bg_fetch_state_d == 2'd1 &&
            dut.background_renderer.fetch.state != 2'd1 &&
            obj_owned_d)
            bg_ack_while_obj_owns <= bg_ack_while_obj_owns + 1;
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1'b1;
            p0_byte_addr = {sdr_p0_addr, 1'b0};
            if (p0_byte_addr < SDR_GFX_BASE)
                beh_p0_dout <= {main_rom[p0_byte_addr+1], main_rom[p0_byte_addr]};
            else if (p0_byte_addr >= SDR_XRAM_BASE && p0_byte_addr < SDR_SAMPLES_BASE) begin
                ext_index = (p0_byte_addr - SDR_XRAM_BASE) >> 1;
                beh_p0_dout <= external_ram[ext_index];
            end else
                beh_p0_dout <= 16'hffff;
            p0_hold <= 4'd2;
        end
        if (p0_hold != 0) begin
            beh_p0_ack <= 1'b1;
            p0_hold <= p0_hold - 1'd1;
        end else if (!sdr_p0_req)
            p0_seen <= 1'b0;

        if (sdr_p2_req && !p1_seen) begin
            p1_seen <= 1'b1;
            // One aligned 16-byte record per 16-pixel tile row:
            //   [31:0]=Q0  [63:32]=Q1  [95:64]=Q2  [127:96]=Q3 (never loaded).
            // This must agree byte for byte with ssv_pkg::gfx_plane_addr, with
            // ssv_rom_loader, and with the +REAL_SDRAM chip preload below.
            p1_byte_addr = {sdr_p2_addr, 4'b0000};
            sprite_index = p1_byte_addr - SDR_GFX_BASE;
            if (sprite_index >= 0 && sprite_index < 16777216) begin
                packed_code = sprite_index >> 7;         // 0..0x1ffff
                packed_row = (sprite_index >> 4) & 7;
                raw_q0_index = packed_code * 32 + packed_row * 4;
                raw_q1_index = 4194304 + raw_q0_index;
                raw_q2_index = 8388608 + raw_q0_index;
                beh_p2_dout <= {
                    32'h0,                               // Q3 slot: never loaded
                    sprite_rom[raw_q2_index+3], sprite_rom[raw_q2_index+2],
                    sprite_rom[raw_q2_index+1], sprite_rom[raw_q2_index],
                    sprite_rom[raw_q1_index+3], sprite_rom[raw_q1_index+2],
                    sprite_rom[raw_q1_index+1], sprite_rom[raw_q1_index],
                    sprite_rom[raw_q0_index+3], sprite_rom[raw_q0_index+2],
                    sprite_rom[raw_q0_index+1], sprite_rom[raw_q0_index]
                };
            end else
                beh_p2_dout <= 128'd0;
            // Hold the ack off for the configured extra latency first.
            p1_delay <= p1_latency;
            if (p1_latency == 0) p1_hold <= 4'd2;
            p1_transactions <= p1_transactions + 1;
        end
        if (p1_delay != 0) begin
            p1_delay <= p1_delay - 1;
            if (p1_delay == 1) p1_hold <= 4'd2;
        end
        if (p1_hold != 0) begin
            beh_p2_ack <= 1'b1;
            p1_hold <= p1_hold - 1'd1;
        end else if (!sdr_p2_req && p1_delay == 0)
            p1_seen <= 1'b0;

        if (sdr_wr_req && !wr_seen) begin
            wr_seen <= 1'b1;
            if ({sdr_wr_addr, 1'b0} >= SDR_XRAM_BASE &&
                {sdr_wr_addr, 1'b0} < SDR_SAMPLES_BASE) begin
                ext_index = ({sdr_wr_addr, 1'b0} - SDR_XRAM_BASE) >> 1;
                if (sdr_wr_be[0])
                    external_ram[ext_index][7:0] <= sdr_wr_din[7:0];
                if (sdr_wr_be[1])
                    external_ram[ext_index][15:8] <= sdr_wr_din[15:8];
            end
            wr_hold <= 4'd2;
        end
        if (wr_hold != 0) begin
            beh_wr_ack <= 1'b1;
            wr_hold <= wr_hold - 1'd1;
        end else if (!sdr_wr_req)
            wr_seen <= 1'b0;

        if (sdr_p4_req && !p4_seen) begin
            p4_seen <= 1'b1;
            beh_p4_dout <= 16'd0;
            p4_hold <= 4'd2;
        end
        if (p4_hold != 0) begin
            beh_p4_ack <= 1'b1;
            p4_hold <= p4_hold - 1'd1;
        end else if (!sdr_p4_req)
            p4_seen <= 1'b0;
    end
end

always_comb begin
    diff_vblank_pulse =
        diff_irq_enabled && diff_count_started && ce_cpu &&
        dut.cpu.st == 7'd3 &&
        retire_count + 1 == next_irq_retire;
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        retire_count <= 0;
        diff_count_started <= 1'b0;
    end else if (ce_cpu && dut.cpu.st == 7'd3 &&
                 !(!dut.irq_n && dut.cpu.psw_ie)) begin
        if (!diff_count_started) begin
            if (dut.cpu.pc == 32'h00f1_0120) begin
                diff_count_started <= 1'b1;
                retire_count <= 1;
            end
        end else begin
            if (diff_irq_enabled &&
                retire_count + 1 == next_irq_retire) begin
                irq_scan_result = $fscanf(
                    irq_schedule_fd, "%d\n", next_irq_retire);
                if (irq_scan_result != 1)
                    next_irq_retire <= {64{1'b1}};
            end
            retire_count <= retire_count + 1;
        end
    end
end

task automatic apply_inputs(input integer f);
    in_dsw1 = 16'hffff;
    in_dsw2 = 16'hfffd;
    in_p2 = 16'hffff;
    in_extra = 16'hffff;
    in_p1 = 16'hffff;
    in_system = 16'hffff;
    if (scenario == "coin_start_p1" ||
        scenario == "coin_start_p1_gameplay" ||
        scenario == "coin_start_p1_long" ||
        scenario == "coin_start_p1_runright") begin
        if (f >= 30 && f < 34) in_system = 16'hfffe; // COIN1
        // Wait for "PUSH START" after coin, then enter select.
        if (f >= 165 && f < 170) in_p1[0] = 1'b0;   // START
        // Confirm Roger on SELECT PLAYER.
        if (f >= 250 && f < 255) in_p1[0] = 1'b0;   // START confirm
        if (f >= 255 && f < 262) in_p1[3] = 1'b0;   // B1 confirm
        // Stage movement / attack after gameplay begins.
        if (f >= 300 && f < 330) in_p1[4] = 1'b0;   // RIGHT
        if (f >= 330 && f < 360) in_p1[3] = 1'b0;   // B1
        if (f >= 360 && f < 390) in_p1[7] = 1'b0;   // UP
        if (scenario == "coin_start_p1_gameplay" ||
            scenario == "coin_start_p1_long" ||
            scenario == "coin_start_p1_runright") begin
            // Skip the two long story beats, then dismiss the map transition.
            if (f >= 420 && f < 425) in_p1[3] = 1'b0; // B1
            if (f >= 480 && f < 485) in_p1[0] = 1'b0; // START
            if (f >= 540 && f < 545) in_p1[3] = 1'b0; // B1
            // Exercise controllable play after the stage-intro GO prompt.
            if (f >= 820 && f < 870) in_p1[4] = 1'b0; // RIGHT
            if ((f >= 840 && f < 848) ||
                (f >= 875 && f < 883)) in_p1[3] = 1'b0; // B1
            if (f >= 890 && f < 920) in_p1[7] = 1'b0; // UP
        end
        // -------------------------------------------------------------
        // coin_start_p1_long: identical to coin_start_p1_gameplay up to
        // post-VE frame 950 (so the existing 950-frame gate is unchanged),
        // then a repeating 240-frame gameplay cycle that keeps the player
        // moving, attacking and jumping indefinitely.  The pattern is a
        // pure function of `f`, so the scenario stays deterministic and
        // needs no external input file.
        //
        // P1 bit map (active low, per verif/tb_ssv_input_matrix.sv):
        //   7 UP  6 DOWN  5 LEFT  4 RIGHT  3 B1  2 B2  1 B3  0 START
        // -------------------------------------------------------------
        if (scenario == "coin_start_p1_long" && f >= 950) begin : long_play
            automatic integer c;
            c = (f - 950) % 240;
            if (c < 140)                in_p1[4] = 1'b0;  // RIGHT (advance)
            if (c >= 200 && c < 220)    in_p1[5] = 1'b0;  // LEFT  (back up)
            if (c >= 150 && c < 170)    in_p1[7] = 1'b0;  // UP    (climb/aim)
            if (c >= 176 && c < 190)    in_p1[6] = 1'b0;  // DOWN  (duck)
            if ((c % 12) < 6)           in_p1[3] = 1'b0;  // B1    (attack)
            if ((c >= 60 && c < 66) ||
                (c >= 170 && c < 176)) in_p1[2] = 1'b0;   // B2    (jump)
            if (c >= 232 && c < 236)    in_p1[1] = 1'b0;  // B3
            // START every 30 s: answers a respawn / continue prompt without
            // hammering it during normal play.
            if (((f - 950) % 1800) < 5) in_p1[0] = 1'b0;  // START
            // Re-coin every 60 s so a continue is always affordable.
            if (((f - 950) % 3600) < 4) in_system[0] = 1'b0; // COIN1
        end
        // -------------------------------------------------------------
        // coin_start_p1_runright: identical to coin_start_p1_gameplay up to
        // post-VE frame 950, then holds RIGHT continuously instead of the
        // 240-frame mixed cycle.  coin_start_p1_long only presses RIGHT for
        // 140 of every 240 frames and spends 20 of the rest walking back
        // LEFT, so the stage advances slowly; the reported symptom needs the
        // camera to travel several screens.  Attack and jump are still
        // exercised, because the camera does not advance past enemies and
        // obstacles on their own.
        // -------------------------------------------------------------
        if (scenario == "coin_start_p1_runright" && f >= 950) begin : run_right
            automatic integer c;
            c = (f - 950) % 240;
            in_p1[4] = 1'b0;                                  // RIGHT, always
            if ((c % 12) < 6)           in_p1[3] = 1'b0;      // B1 attack
            if ((c % 60) < 6)           in_p1[2] = 1'b0;      // B2 jump
            if (((f - 950) % 1800) < 5) in_p1[0] = 1'b0;      // START
            if (((f - 950) % 3600) < 4) in_system[0] = 1'b0;  // COIN1
        end
    end
    // -------------------------------------------------------------------
    // coin_start_2p_dense -- the two-player scenario PHASE0_MEASUREMENT
    // recorded as missing.
    //
    // C3's refutation condition was "peak occupancy <= 96 in 1P AND 2P".
    // Only 1P had ever been run, so the LINE_SLOTS question stayed open, and
    // commit d2237df's note that "two players will exceed it" was never
    // tested either way. This is that test.
    //
    // Two coins (COIN1 then COIN2), both players start, P2 picks a different
    // character, then both are driven with 120-frame out-of-phase patterns:
    // in phase they overlap and share scanlines, out of phase they aggro
    // enemies at two separate points of the stage, which is the case that
    // actually stacks descriptors on one line.
    //
    // P1/P2 bit map (active low, per verif/tb_ssv_input_matrix.sv):
    //   7 UP  6 DOWN  5 LEFT  4 RIGHT  3 B1  2 B2  1 B3  0 START
    // SYSTEM: 0 COIN1  1 COIN2
    // -------------------------------------------------------------------
    if (scenario == "coin_start_2p_dense") begin : two_player
        automatic integer c1, c2;
        if (f >= 30  && f < 34)  in_system[0] = 1'b0;  // COIN1 -> P1 credit
        if (f >= 40  && f < 44)  in_system[1] = 1'b0;  // COIN2 -> P2 credit
        if (f >= 50  && f < 54)  in_system[0] = 1'b0;  // spare credit
        if (f >= 165 && f < 170) in_p1[0] = 1'b0;      // P1 START
        if (f >= 180 && f < 185) in_p2[0] = 1'b0;      // P2 START (join)
        // Character select. P1 keeps the default (Roger, matching the 1P
        // scenarios so the two runs stay comparable); P2 moves one right so
        // the two players are different characters with different sprite
        // sets, which is the denser case.
        if (f >= 210 && f < 215) in_p2[4] = 1'b0;      // P2 RIGHT
        if (f >= 250 && f < 255) begin                 // both confirm
            in_p1[0] = 1'b0; in_p2[0] = 1'b0;
        end
        if (f >= 255 && f < 262) begin
            in_p1[3] = 1'b0; in_p2[3] = 1'b0;
        end
        // Story beats and the map transition, same beats as the 1P gameplay
        // scenario so the run reaches controllable play at the same frame.
        if (f >= 300 && f < 330) in_p1[4] = 1'b0;
        if (f >= 330 && f < 360) begin
            in_p1[3] = 1'b0; in_p2[3] = 1'b0;
        end
        if (f >= 360 && f < 390) in_p1[7] = 1'b0;
        if (f >= 420 && f < 425) begin
            in_p1[3] = 1'b0; in_p2[3] = 1'b0;
        end
        if (f >= 480 && f < 485) in_p1[0] = 1'b0;
        if (f >= 540 && f < 545) begin
            in_p1[3] = 1'b0; in_p2[3] = 1'b0;
        end
        // Controllable play from the stage-intro GO prompt onwards. Pure
        // function of f, so the scenario stays deterministic.
        if (f >= 820) begin
            c1 = (f - 820) % 240;
            c2 = (f - 820 + 120) % 240;
            if (c1 < 150)              in_p1[4] = 1'b0;  // P1 RIGHT
            if (c1 >= 170 && c1 < 190) in_p1[7] = 1'b0;  // P1 UP
            if ((c1 % 12) < 6)         in_p1[3] = 1'b0;  // P1 B1 attack
            if ((c1 % 60) < 6)         in_p1[2] = 1'b0;  // P1 B2 jump
            if (c2 < 150)              in_p2[4] = 1'b0;  // P2 RIGHT
            if (c2 >= 170 && c2 < 190) in_p2[7] = 1'b0;  // P2 UP
            if ((c2 % 12) < 6)         in_p2[3] = 1'b0;  // P2 B1 attack
            if ((c2 % 60) < 6)         in_p2[2] = 1'b0;  // P2 B2 jump
            // Answer respawn / continue prompts for either player, and keep
            // credits topped up so neither drops out of the game.
            if (((f - 820) % 1800) < 5) begin
                in_p1[0] = 1'b0; in_p2[0] = 1'b0;
            end
            if (((f - 820) % 3600) < 4)          in_system[0] = 1'b0;
            if (((f - 820 + 1800) % 3600) < 4)   in_system[1] = 1'b0;
        end
    end
endtask

always_comb begin
    ppm_open_event = dump_ppm_en && !dump_ppm_open && ve_seen &&
                     vb_d && !vb &&
                     (post_ve_frames >= ppm_start) &&
                     (ppm_shots_done < ppm_count) &&
                     (((post_ve_frames - ppm_start) % ppm_step) == 0);
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ve_seen <= 1'b0;
        vb_d <= 1'b1;
        frame_active <= 1'b0;
        frame_idx <= 0;
        post_ve_frames <= 0;
        idx_crc <= 32'hffffffff;
        rgb_crc <= 32'hffffffff;
        px_count <= 0;
        active_pixels <= 0;
        nonblack_pixels <= 0;
        post_ve_nonblack <= 0;
        select_header_pixels <= 0;
        frame_nonblack <= 0;
        gameplay_green_pixels <= 0;
        play_reached <= 1'b0;
        gameplay_reached <= 1'b0;
        bg_overruns <= 0;
        obj_overruns <= 0;
        obj_line_cycles <= 0;
        obj_rom_wait_cycles <= 0;
        obj_max_line_cycles <= 0;
        obj_line_descriptors <= 0;
        obj_line_fetches <= 0;
        obj_line_tilemap_fetches <= 0;
        obj_line_plot_cycles <= 0;
        obj_max_line_entries <= 0;
        cache_build_cycles = 0;
        cache_build_max = 0;
        cache_build_max_frame = 0;
        cache_build_start_v = 0;
        cache_deadline_hits = 0;
        cache_busy_d <= 1'b0;
        obj_busy_d <= 1'b0;
        obj_cache_overflow_d <= 1'b0;
        stuck <= 0;
        last_pc <= 32'hffffffff;
        irq_entries_post_ve <= 0;
        vb_pulses_post_ve <= 0;
        dump_ppm_open <= 1'b0;
        ppm_pixels <= 0;
        ppm_shots_done <= 0;
    end else begin
        if (debug_status[22])
            ve_seen <= 1'b1;

        // Multi-shot PPM: frames ppm_start + k*ppm_step for k in [0, ppm_count).
        // Single-shot: ppm_count==1 and ppm_path already set via +DUMP_PPM=.
        if (ppm_open_event) begin
            if (ppm_prefix.len() != 0)
                $sformat(ppm_path, "%s_f%0d.ppm", ppm_prefix, post_ve_frames);
            ppm_fd = $fopen(ppm_path, "wb");
            if (ppm_fd == 0)
                $fatal(1, "cannot open DUMP_PPM path %s", ppm_path);
            $fwrite(ppm_fd, "P6\n336 240\n255\n");
            dump_ppm_open <= 1'b1;
            ppm_pixels <= 0;
            $display("DUMP_PPM capturing frame %0d -> %s",
                     post_ve_frames, ppm_path);
        end

        if (ce_pixel && !hb && !vb && debug_status[22]) begin
            active_pixels <= active_pixels + 1;
            if (rgb != 24'd0) begin
                nonblack_pixels <= nonblack_pixels + 1;
                frame_nonblack <= frame_nonblack + 1;
                if (ve_seen)
                    post_ve_nonblack <= post_ve_nonblack + 1;
            end
            // The color-cycling "SELECT PLAYER" header has a stable 836-pixel
            // silhouette in this box. Gameplay frames measure well below 700.
            if (px_count >= (5 * 336) && px_count < (55 * 336) &&
                (px_count % 336) >= 40 && (px_count % 336) < 310 &&
                rgb != 24'd0)
                select_header_pixels <= select_header_pixels + 1;
            // Jungle gameplay is dominated by bright green foliage. Count a
            // conservative green-dominant population over the full frame.
            if (rgb[15:8] > rgb[23:16] && rgb[15:8] > rgb[7:0] &&
                rgb[15:8] >= 8'h40)
                gameplay_green_pixels <= gameplay_green_pixels + 1;
            // Accumulate every active pixel after VE (no delayed frame_active).
            if (ve_seen) begin
                idx15 = {rgb[23:19], rgb[15:11], rgb[7:3]};
                idx_crc <= ssv_crc32_byte(
                    ssv_crc32_byte(idx_crc, idx15[7:0]),
                    {1'b0, idx15[14:8]});
                rgb_crc <= ssv_crc32_byte(
                    ssv_crc32_byte(
                        ssv_crc32_byte(rgb_crc, rgb[23:16]),
                        rgb[15:8]),
                    rgb[7:0]);
                px_count <= px_count + 1;
                if (dump_pixels && post_ve_frames == 30 &&
                    rgb != 24'd0 && dump_count < 32) begin
                    $display("RTLPIX %0d %0d %06x", dut.hcnt, dut.vcnt, rgb);
                    dump_count <= dump_count + 1;
                end
                // The file opens on the first active-pixel edge.  Include that
                // edge explicitly because dump_ppm_open updates after this
                // procedural block; otherwise every PPM is one pixel short.
                if (dump_ppm_open || ppm_open_event) begin
                    $fwrite(ppm_fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
                    ppm_pixels <= ppm_open_event ? 1 : ppm_pixels + 1;
                end
            end
        end

        // Emit + reset on entering vblank so the first active pixel is included.
        if (ve_seen && !vb_d && vb) begin
            if (post_ve_frames == 440) begin
                if (require_play)
                    $display("PLAY_FRAME f=%0d header=%0d nonblack=%0d",
                             post_ve_frames, select_header_pixels,
                             frame_nonblack);
                if (select_header_pixels < 700 && frame_nonblack > 1000)
                    play_reached <= 1'b1;
            end
            if (post_ve_frames == 850) begin
                if (require_gameplay)
                    $display("GAMEPLAY_FRAME f=%0d green=%0d nonblack=%0d",
                             post_ve_frames, gameplay_green_pixels,
                             frame_nonblack);
                if (gameplay_green_pixels > 5000 && frame_nonblack > 20000)
                    gameplay_reached <= 1'b1;
            end
            if (dump_ppm_open) begin
                $fclose(ppm_fd);
                dump_ppm_open <= 1'b0;
                ppm_shots_done <= ppm_shots_done + 1;
                $display("DUMP_PPM wrote %s frame=%0d pixels=%0d shot=%0d/%0d",
                         ppm_path, post_ve_frames, ppm_pixels,
                         ppm_shots_done + 1, ppm_count);
            end
            if (crc_fd != 0 && post_ve_frames < max_frames && px_count != 0) begin
                $fdisplay(crc_fd, "FRAME %0d %08x %08x",
                          post_ve_frames,
                          ~idx_crc,
                          ~rgb_crc);
                $fflush(crc_fd);
                if (post_ve_frames == 0)
                    $display("FRAME0 px=%0d idx=%08x rgb=%08x",
                             px_count, ~idx_crc, ~rgb_crc);
                if ((dump_frame_diag && post_ve_frames < 4) ||
                    state_fd != 0) begin
                    list_crc = 32'hffffffff;
                    spr8k_crc = 32'hffffffff;
                    for (diag_i = 0; diag_i < 8192; diag_i = diag_i + 1) begin
                        spr8k_crc = ssv_crc32_byte(
                            ssv_crc32_byte(spr8k_crc,
                                spr_peek(diag_i[16:0])[7:0]),
                            spr_peek(diag_i[16:0])[15:8]);
                        if (diag_i < 512)
                            list_crc = ssv_crc32_byte(
                                ssv_crc32_byte(list_crc,
                                    spr_peek(diag_i[16:0])[7:0]),
                                spr_peek(diag_i[16:0])[15:8]);
                    end
                    scroll_crc = 32'hffffffff;
                    for (diag_i = 0; diag_i < 64; diag_i = diag_i + 1) begin
                        scroll_crc = ssv_crc32_byte(
                            ssv_crc32_byte(scroll_crc,
                                dut.scroll[diag_i][7:0]),
                            dut.scroll[diag_i][15:8]);
                    end
                    pal_crc = 32'hffffffff;
                    for (diag_i = 0; diag_i < 512; diag_i = diag_i + 1) begin
                        pal_crc = ssv_crc32_byte(
                            ssv_crc32_byte(pal_crc,
                                dut.palette_ram.even_words.sim_peek(
                                    diag_i[14:0])[7:0]),
                            dut.palette_ram.even_words.sim_peek(
                                diag_i[14:0])[15:8]);
                        pal_crc = ssv_crc32_byte(
                            ssv_crc32_byte(pal_crc,
                                dut.palette_ram.odd_words.sim_peek(
                                    diag_i[14:0])[7:0]),
                            dut.palette_ram.odd_words.sim_peek(
                                diag_i[14:0])[15:8]);
                    end
                    $display("FRAMEDIAG f=%0d retire=%0d dretire=%0d irq_entries=%0d vb_pulses=%0d list512=%08x spr8k=%08x scroll64=%08x pal512=%08x scr0=%04x scr1=%04x scr3=%04x scr53=%04x scr56=%04x scr58=%04x scr59=%04x scr61=%04x cache_cnt=%0d pc=%08x",
                             post_ve_frames, retire_count,
                             (last_vb_retire == 0) ? 0 :
                                (retire_count - last_vb_retire),
                             irq_entries_post_ve, vb_pulses_post_ve,
                             ~list_crc, ~spr8k_crc, ~scroll_crc, ~pal_crc,
                             dut.scroll[0], dut.scroll[1], dut.scroll[3],
                             dut.scroll[53], dut.scroll[56], dut.scroll[58],
                             dut.scroll[59], dut.scroll[61],
                             dut.sprite_renderer.cache_count, debug_pc);
                    if (state_fd != 0) begin
                        $fdisplay(state_fd,
                            "STATE %0d list512=%08x spr8k=%08x scroll64=%08x pal512=%08x",
                            post_ve_frames, ~list_crc, ~spr8k_crc,
                            ~scroll_crc, ~pal_crc);
                        $fflush(state_fd);
                    end
                    last_vb_retire = retire_count;
                end
                apply_inputs(post_ve_frames);
                post_ve_frames <= post_ve_frames + 1;
                frame_idx <= frame_idx + 1;
            end
            idx_crc <= 32'hffffffff;
            rgb_crc <= 32'hffffffff;
            px_count <= 0;
            select_header_pixels <= 0;
            frame_nonblack <= 0;
            gameplay_green_pixels <= 0;
        end
        vb_d <= vb;

        if (ve_seen && dut.vblank_pulse) begin
            vb_pulses_post_ve <= vb_pulses_post_ve + 1;
            // Snapshot descriptors at cache_start for the upcoming frame.
            if (dump_frame_diag && post_ve_frames < 3) begin
                list_crc = 32'hffffffff;
                spr8k_crc = 32'hffffffff;
                for (diag_i = 0; diag_i < 8192; diag_i = diag_i + 1) begin
                    spr8k_crc = ssv_crc32_byte(
                        ssv_crc32_byte(spr8k_crc,
                            spr_peek(diag_i[16:0])[7:0]),
                        spr_peek(diag_i[16:0])[15:8]);
                    if (diag_i < 512)
                        list_crc = ssv_crc32_byte(
                            ssv_crc32_byte(list_crc,
                                spr_peek(diag_i[16:0])[7:0]),
                            spr_peek(diag_i[16:0])[15:8]);
                end
                scroll_crc = 32'hffffffff;
                for (diag_i = 0; diag_i < 64; diag_i = diag_i + 1) begin
                    scroll_crc = ssv_crc32_byte(
                        ssv_crc32_byte(scroll_crc,
                            dut.scroll[diag_i][7:0]),
                        dut.scroll[diag_i][15:8]);
                end
                $display("CACHESNAP retire=%0d next_f=%0d list512=%08x spr8k=%08x scroll64=%08x scr0=%04x scr1=%04x scr3=%04x",
                         retire_count, post_ve_frames,
                         ~list_crc, ~spr8k_crc, ~scroll_crc,
                         dut.scroll[0], dut.scroll[1], dut.scroll[3]);
            end
        end

        if (ce_cpu && dut.cpu.st == 7'd3 && debug_pc == 32'h00f1_1124) begin
            if (ve_seen)
                irq_entries_post_ve <= irq_entries_post_ve + 1;
            if (dump_frame_diag &&
                (last_irq_entry_retire == 0 ||
                 retire_count != last_irq_entry_retire)) begin
                $display("IRQENTRY retire=%0d dretire=%0d ve=%0d f=%0d",
                         retire_count,
                         (last_irq_entry_retire == 0) ? 0 :
                            (retire_count - last_irq_entry_retire),
                         ve_seen, post_ve_frames);
                last_irq_entry_retire = retire_count;
            end
        end

        if (dut.line_buffer_start && dut.bg_busy)
            bg_overruns <= bg_overruns + 1;
        if (dut.line_buffer_start && dut.obj_busy) begin
            obj_overruns <= obj_overruns + 1;
            if (dump_renderer_budget && obj_overruns < 16)
                $display("OBJ_LATE f=%0d y=%0d state=%0d slots=%0d/%0d entry=%0d tilemap=%0b tile=%0d/%0d plot=%0d line_cycles=%0d desc=%0d fetch=%0d tilefetch=%0d plotcycles=%0d rom_wait=%0d req=%0b ack=%0b",
                         post_ve_frames, dut.renderer_target_y,
                         dut.sprite_renderer.state,
                         dut.sprite_renderer.render_line_slot,
                         dut.sprite_renderer.render_line_count,
                         dut.sprite_renderer.cache_render_index,
                         dut.sprite_renderer.render_tilemap,
                         dut.sprite_renderer.sprite_tile_x,
                         dut.sprite_renderer.sprite_xnum,
                         dut.sprite_renderer.plot_i,
                         obj_line_cycles, obj_line_descriptors,
                         obj_line_fetches, obj_line_tilemap_fetches,
                         obj_line_plot_cycles, obj_rom_wait_cycles,
                         dut.obj_rom_req, sdr_p2_ack);
            if (stop_on_renderer_overrun) begin
                $display("FIRST_OBJ_LATE f=%0d y=%0d cycles=%0d desc=%0d fetch=%0d tilefetch=%0d",
                         post_ve_frames, dut.renderer_target_y,
                         obj_line_cycles, obj_line_descriptors,
                         obj_line_fetches, obj_line_tilemap_fetches);
                $fatal(1, "renderer overrun");
            end
        end

        // Vblank budget for the descriptor build. The build owns vblank; if it
        // ever runs past the lines that prepare display rows 0/1 the core now
        // aborts it (cache_deadline) rather than freezing the display, but the
        // margin is what says whether hardware could realistically get there.
        cache_busy_d <= dut.obj_cache_busy;
        if (dut.obj_cache_busy && !cache_busy_d) begin
            cache_build_cycles = 0;
            cache_build_start_v = dut.timing.vcnt;
        end
        else if (dut.obj_cache_busy) begin
            cache_build_cycles = cache_build_cycles + 1;
        end
        else if (!dut.obj_cache_busy && cache_busy_d) begin
            if (cache_build_cycles > cache_build_max) begin
                cache_build_max = cache_build_cycles;
                cache_build_max_frame = post_ve_frames;
            end
            if (dut.cache_deadline) cache_deadline_hits = cache_deadline_hits + 1;
        end

        obj_cache_overflow_d <= dut.obj_cache_overflow;
        if (dut.obj_cache_overflow && !obj_cache_overflow_d) begin
            $display("FIRST_CACHE_OVERFLOW f=%0d state=%0d cache=%0d writes=%0d bucket_y=%0d line_count=%0d",
                     post_ve_frames, dut.sprite_renderer.state,
                     dut.sprite_renderer.cache_count,
                     dut.sprite_renderer.cache_write_count,
                     dut.sprite_renderer.bucket_y,
                     dut.sprite_renderer.line_count_q);
            overflow_tile_desc = 0;
            overflow_sprite_desc = 0;
            for (overflow_i = 0; overflow_i < 8; overflow_i = overflow_i + 1)
                overflow_tile_groups[overflow_i] = 0;
            for (overflow_i = 0;
                 overflow_i < dut.sprite_renderer.LINE_SLOTS;
                 overflow_i = overflow_i + 1) begin
                overflow_entry = {
                    dut.sprite_renderer.line_page_for_slot(
                        dut.sprite_renderer.line_page_starts[
                            dut.sprite_renderer.bucket_y],
                        overflow_i),
                    dut.sprite_renderer.line_entries[
                        dut.sprite_renderer.bucket_y *
                        dut.sprite_renderer.LINE_SLOTS + overflow_i]
                };
                overflow_desc =
                    dut.sprite_renderer.descriptor_cache[overflow_entry];
                if ((overflow_desc[63:48] <= 16'd7) &&
                    (overflow_desc[47:32] == 16'd0) &&
                    ((dut.scroll[59][14] ? overflow_desc[27:26] :
                                           overflow_desc[107:106]) == 2'd0) &&
                    ((dut.scroll[59][14] ? overflow_desc[11:10] :
                                           overflow_desc[109:108]) == 2'd3)) begin
                    overflow_tile_desc = overflow_tile_desc + 1;
                    overflow_tile_groups[overflow_desc[50:48]] =
                        overflow_tile_groups[overflow_desc[50:48]] + 1;
                end
                else begin
                    overflow_sprite_desc = overflow_sprite_desc + 1;
                end
            end
            $display("OVERFLOW_LINE_CONTENT tilemaps=%0d sprites=%0d groups=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                     overflow_tile_desc, overflow_sprite_desc,
                     overflow_tile_groups[0], overflow_tile_groups[1],
                     overflow_tile_groups[2], overflow_tile_groups[3],
                     overflow_tile_groups[4], overflow_tile_groups[5],
                     overflow_tile_groups[6], overflow_tile_groups[7]);
            if (stop_on_renderer_overrun)
                $fatal(1, "sprite descriptor/line cache overflow");
        end

        obj_busy_d <= dut.obj_busy;
        if (dut.sprite_renderer.render_line_count > obj_max_line_entries)
            obj_max_line_entries <= dut.sprite_renderer.render_line_count;
        if (dut.obj_busy && !obj_busy_d) begin
            obj_line_cycles <= 1;
            obj_rom_wait_cycles <= 0;
            obj_line_descriptors <= 0;
            obj_line_fetches <= 0;
            obj_line_tilemap_fetches <= 0;
            obj_line_plot_cycles <= 0;
        end
        else if (dut.obj_busy) begin
            obj_line_cycles <= obj_line_cycles + 1;
            // Encoding shifted down by two when TILE_ATTR_ADDR/TILE_ATTR_WAIT
            // were removed: FETCH_START 33->31, TILE_PREP 32->30,
            // FETCH_WAIT 34->32. RENDER_PREP is still 22. The states observed
            // are unchanged, only their numbers.
            if (dut.sprite_renderer.state == 6'd31)
                obj_rom_wait_cycles <= obj_rom_wait_cycles + 1;
            if (dut.sprite_renderer.state == 6'd22)
                obj_line_descriptors <= obj_line_descriptors + 1;
            if (dut.sprite_renderer.state == 6'd30) begin
                obj_line_fetches <= obj_line_fetches + 1;
                if (dut.sprite_renderer.render_tilemap)
                    obj_line_tilemap_fetches <= obj_line_tilemap_fetches + 1;
            end
            if (dut.sprite_renderer.state == 6'd32)
                obj_line_plot_cycles <= obj_line_plot_cycles + 1;
        end
        else if (obj_busy_d && obj_line_cycles > obj_max_line_cycles) begin
            obj_max_line_cycles <= obj_line_cycles;
            if (dump_renderer_budget)
                $display("OBJ_MAX f=%0d y=%0d cycles=%0d desc=%0d fetch=%0d tilefetch=%0d plotcycles=%0d rom_wait=%0d",
                         post_ve_frames, dut.renderer_target_y,
                         obj_line_cycles, obj_line_descriptors,
                         obj_line_fetches, obj_line_tilemap_fetches,
                         obj_line_plot_cycles, obj_rom_wait_cycles);
        end

        if (ce_cpu && debug_pc == last_pc)
            stuck <= stuck + 1;
        else
            stuck <= 0;
        if (ce_cpu)
            last_pc <= debug_pc;
    end
end

initial begin
    if (!$value$plusargs("MAINROM=%s", main_path))
        main_path = "sim_output/rom/maincpu.bin";
    if (!$value$plusargs("SPRROM=%s", sprite_path))
        sprite_path = "sim_output/rom/sprites.bin";
    if (!$value$plusargs("FRAME_CRC=%s", crc_path))
        crc_path = "sim_output/diff/rtl_attract_idle_frames.crc";
    state_fd = 0;
    if ($value$plusargs("STATE_CRC=%s", state_path)) begin
        state_fd = $fopen(state_path, "w");
        if (state_fd == 0)
            $fatal(1, "cannot open STATE_CRC path %s", state_path);
    end
    if (!$value$plusargs("SCENARIO=%s", scenario))
        scenario = "attract_idle";
    if (!$value$plusargs("P1_LATENCY=%d", p1_latency))
        p1_latency = 0;
    if (!$value$plusargs("DUMP_TILEMAP=%d", dump_tilemap_frame))
        dump_tilemap_frame = -1;
    if (!$value$plusargs("FRAMES=%d", max_frames))
        max_frames = 120;
    if (!$value$plusargs("SOAK_FRAMES=%d", soak_frames))
        soak_frames = 30;
    if (!$value$plusargs("CYCLES=%d", max_cycles))
        max_cycles = 200000000;
    dump_pixels = $test$plusargs("DUMP_PIXELS");
    dump_frame_diag = $test$plusargs("DUMP_FRAME_DIAG");
    dump_renderer_budget = $test$plusargs("DUMP_RENDERER_BUDGET");
    stop_on_renderer_overrun =
        $test$plusargs("STOP_ON_RENDERER_OVERRUN");
    ignore_overrun = $test$plusargs("IGNORE_OVERRUN");
    use_real_sdram = $test$plusargs("REAL_SDRAM");
    if (!$value$plusargs("SMPROM=%s", sample_path))
        sample_path = "sim_output/rom/samples.bin";
    sample_fd = $fopen(sample_path, "rb");
    require_play = $test$plusargs("REQUIRE_PLAY");
    require_gameplay = $test$plusargs("REQUIRE_GAMEPLAY");
    // Single-shot legacy: +DUMP_PPM=path +DUMP_PPM_FRAME=N
    // Multi-shot: +DUMP_PPM_PREFIX=path/stem +DUMP_PPM_START=N +DUMP_PPM_COUNT=5
    //              +DUMP_PPM_STEP=20
    dump_ppm_en = 1'b0;
    ppm_count = 1;
    ppm_step = 1;
    ppm_shots_done = 0;
    if ($value$plusargs("DUMP_PPM_PREFIX=%s", ppm_prefix)) begin
        dump_ppm_en = 1'b1;
        if (!$value$plusargs("DUMP_PPM_START=%d", ppm_start))
            ppm_start = 160;
        if (!$value$plusargs("DUMP_PPM_COUNT=%d", ppm_count))
            ppm_count = 5;
        if (!$value$plusargs("DUMP_PPM_STEP=%d", ppm_step))
            ppm_step = 20;
        if (ppm_step < 1) ppm_step = 1;
    end else if ($value$plusargs("DUMP_PPM=%s", ppm_path)) begin
        dump_ppm_en = 1'b1;
        ppm_prefix = "";
        if (!$value$plusargs("DUMP_PPM_FRAME=%d", ppm_frame))
            ppm_frame = 2;
        ppm_start = ppm_frame;
        ppm_count = 1;
        ppm_step = 1;
    end
    dump_ppm_open = 1'b0;
    ppm_pixels = 0;
    ppm_fd = 0;
    dump_count = 0;
    last_vb_retire = 0;
    last_irq_entry_retire = 0;
    irq_entries_post_ve = 0;
    vb_pulses_post_ve = 0;
    diff_irq_enabled = 1'b0;
    irq_schedule_fd = 0;
    if ($value$plusargs("DIFF_IRQ_SCHEDULE=%s", irq_schedule_path)) begin
        irq_schedule_fd = $fopen(irq_schedule_path, "r");
        if (irq_schedule_fd == 0)
            $fatal(1, "cannot open IRQ schedule: %s", irq_schedule_path);
        irq_scan_result = $fscanf(
            irq_schedule_fd, "%d\n", next_irq_retire);
        if (irq_scan_result != 1)
            $fatal(1, "empty IRQ schedule: %s", irq_schedule_path);
        diff_irq_enabled = 1'b1;
        force dut.vblank_pulse = diff_vblank_pulse;
    end

    main_fd = $fopen(main_path, "rb");
    sprite_fd = $fopen(sprite_path, "rb");
    if (main_fd == 0 || sprite_fd == 0)
        $fatal(1, "cannot open ROM images");
    main_count = $fread(main_rom, main_fd);
    sprite_count = $fread(sprite_rom, sprite_fd);
    $fclose(main_fd);
    $fclose(sprite_fd);
    if (main_count != 1048576 || sprite_count != 12582912)
        $fatal(1, "short ROM read main=%0d sprite=%0d", main_count, sprite_count);

    // With the real controller the ROM loader is bypassed exactly as it is for
    // the behavioural model, so the chip has to be preloaded with the same
    // image the behavioural model synthesises on the fly. The layouts must
    // agree bit for bit, otherwise the two runs would differ for reasons that
    // have nothing to do with memory timing -- and the whole point of this
    // harness is that frame CRCs stay identical while only timing changes.
    if (use_real_sdram) begin
        $display("REAL_SDRAM preloading chip image");
        // V60 program, 1 MB at SDR_MAINCPU_BASE = 0.
        for (i = 0; i < 524288; i = i + 1)
            u_sdram.chip.mem[i] =
                {main_rom[i*2+1], main_rom[i*2]};
        // Graphics, 16 MB at SDR_GFX_BASE = 0x0100000. One aligned 16-byte
        // record per 16-pixel tile row: Q0 | Q1 | Q2 | pad. This mirrors the
        // behavioural p2 model above and ssv_pkg::gfx_plane_addr; a divergence
        // between the three is exactly the fake-bug generator the design doc
        // warns about, so the arithmetic below is deliberately the same shape.
        //
        // The quarter-3 slot is written as zero rather than left X. The loader
        // never writes it on hardware and ssv_gfx_row_fetch forces plane67 to
        // zero, so its value is unobservable -- zeroing it just keeps X out of
        // the waveform.
        for (i = 0; i < 8388608; i = i + 1) begin : preload_packed
            automatic integer byte_off  = i * 2;
            automatic integer pk_code   = byte_off >> 7;
            automatic integer pk_row    = (byte_off >> 4) & 7;
            automatic integer q0        = pk_code * 32 + pk_row * 4;
            automatic integer in_rec    = byte_off & 15;
            automatic integer quarter   = in_rec >> 2;
            // Quarter 3 has no source bytes at all, so the index must not be
            // formed: sprite_rom only holds three quarters.
            automatic integer src       = (quarter == 3)
                                            ? 0
                                            : quarter * 4194304 + q0 + (in_rec & 3);
            u_sdram.chip.mem[(SDR_GFX_BASE >> 1) + i] =
                (quarter == 3) ? 16'h0000
                               : {sprite_rom[src+1], sprite_rom[src]};
        end
        // ES5506 samples. Without these the sample engine fetches zeroes, which
        // is what every full-core run in this project has done so far -- so the
        // audio path has never actually been exercised in simulation.
        if (sample_fd != 0) begin
            sample_count = $fread(sample_rom, sample_fd);
            $fclose(sample_fd);
            if (sample_count != 4194304)
                $fatal(1, "short sample ROM read %0d", sample_count);
            // SDR_SAMPLES_BASE moved to 0x1160000 (above XRAM and CPU RAM)
            // when the graphics region grew to 16 MB.
            for (i = 0; i < 2097152; i = i + 1)
                u_sdram.chip.mem[(SDR_SAMPLES_BASE >> 1) + i] =
                    {sample_rom[i*2+1], sample_rom[i*2]};
            $display("REAL_SDRAM samples preloaded");
        end
        else
            $display("REAL_SDRAM no sample image (+SMPROM=) - audio path unexercised");
        $display("REAL_SDRAM preload done");
    end

    crc_fd = $fopen(crc_path, "w");
    if (crc_fd == 0)
        $fatal(1, "cannot open FRAME_CRC path %s", crc_path);

    for (i = 0; i < 196608; i = i + 1)
        external_ram[i] = 16'd0;

    apply_inputs(0);
    rst = 1'b1;
    repeat (8) @(posedge clk_sys);
    rst = 1'b0;

    for (cycle_count = 0; cycle_count < max_cycles; cycle_count = cycle_count + 1) begin
        @(posedge clk_sys);
        if (stuck > 500000)
            $fatal(1, "STUCK pc=%08x cyc=%0d", debug_pc, cycle_count);
        if (ve_seen && post_ve_frames >= max_frames &&
            post_ve_frames >= soak_frames)
            break;
    end

    if (crc_fd != 0)
        $fclose(crc_fd);
    if (state_fd != 0)
        $fclose(state_fd);

    if (!ve_seen)
        $fatal(1, "video_enable never rose pc=%08x", debug_pc);
    // The loop above also exits when the cycle budget runs out, and it used to
    // do so silently: +FRAMES=250 with the default +CYCLES=200000000 stops at
    // post-VE frame 215, because a frame is 262 x 3064.2 = ~803k clk_sys and
    // ~35 frames go by before video_enable. Every measurement in
    // docs/PHASE0_MEASUREMENT.md was taken from such a run and therefore never
    // reached this scenario's controllable gameplay, which begins at post-VE
    // frame 820. Say so loudly rather than reporting a short run as a full one.
    if (post_ve_frames < max_frames)
        $display("WARNING CYCLE_BUDGET_TRUNCATED frames=%0d requested=%0d cycles=%0d -- raise +CYCLES to reach the requested frame",
                 post_ve_frames, max_frames, max_cycles);
    if (post_ve_frames < soak_frames)
        $fatal(1, "soak frames=%0d need=%0d", post_ve_frames, soak_frames);
    if (!ignore_overrun && (bg_overruns != 0 || obj_overruns != 0))
        $fatal(1, "renderer overrun bg=%0d obj=%0d", bg_overruns, obj_overruns);
    if (post_ve_nonblack < 1000)
        $fatal(1, "post-VE nonblack too low: %0d", post_ve_nonblack);
    if (!ignore_overrun && debug_status[16])
        $fatal(1, "renderer_overrun sticky set");
    if (require_play && !play_reached)
        $fatal(1, "character select did not reach game intro by frame %0d",
               post_ve_frames);
    if (require_gameplay && !gameplay_reached)
        $fatal(1, "controllable jungle gameplay not reached by frame %0d",
               post_ve_frames);

    $display("CACHE_BUILD max=%0d cycles (frame %0d) deadline_aborts=%0d",
             cache_build_max, cache_build_max_frame, cache_deadline_hits);
    $display("P1_LATENCY=%0d bg_ack_while_obj_owns=%0d",
             p1_latency, bg_ack_while_obj_owns);
    // Direct measurement of the repack's claim: one 128-bit transaction per
    // 16-pixel tile row instead of two 64-bit ones.
    $display("GFX_TRANSACTIONS=%0d", p1_transactions);
    $display("EXTRA_PORT $500008 reads=%0d", extra_reads);
    $display("CACHE_PEAK=%0d of %0d entries (frame %0d)",
             cache_peak, dut.sprite_renderer.CACHE_ENTRIES, cache_peak_frame);
    if (bg_ack_while_obj_owns != 0)
        $fatal(1, "background renderer latched %0d acks it did not own",
               bg_ack_while_obj_owns);
    // Phase 0 report. Gated on the existing +DUMP_RENDERER_BUDGET so every
    // current gate keeps byte-identical output when it is not requested.
    if (dump_renderer_budget) begin
        $display("=== PHASE0 C3 line occupancy (LINE_SLOTS=%0d) ===",
                 dut.sprite_renderer.LINE_SLOTS);
        $display("C3_OCC max=%0d frame=%0d at_cap=%0d lines=%0d",
                 occ_max, occ_max_frame, occ_at_cap, occ_lines_sampled);
        for (diag_i = 0; diag_i < OCC_BINS; diag_i = diag_i + 1)
            if (occ_hist[diag_i] != 0)
                $display("C3_HIST %0d %0d", diag_i, occ_hist[diag_i]);
        // Uncapped demand. C3_DEM max is the LINE_SLOTS the scene asked for;
        // C3_OCC max can never exceed LINE_SLOTS because line_counts
        // saturates. over_cap counts the (line, frame) pairs that dropped at
        // least one descriptor.
        $display("C3_DEM max=%0d frame=%0d over_cap=%0d",
                 dem_max, dem_max_frame, dem_over_cap);
        for (diag_i = 0; diag_i < OCC_BINS; diag_i = diag_i + 1)
            if (dem_hist[diag_i] != 0)
                $display("C3_DEMHIST %0d %0d", diag_i, dem_hist[diag_i]);
        $display("C4_START total=%0d dropped=%0d", start_total, start_dropped);
        $display("C5_BGSTART bg_start_while_obj_busy=%0d bg_ack_while_obj_owns=%0d",
                 bg_start_while_obj_busy, bg_ack_while_obj_owns);
        $display("C6_NORWCHECK desc=%0d entries=%0d page_consume=%0d",
                 c6_desc_hits, c6_entry_hits, c6_page_consume_hits);
        $display("C7_ES5506 nonbank2_slots=%0d compressed_slots=%0d",
                 es_nonbank2_slots, es_compressed_slots);
        if (use_real_sdram)
            u_sdram.controller.sdram_dump_stats("frame_crc");
    end

    $display("PASS tb_ssv_frame_crc scenario=%s frames=%0d nonblack=%0d pc=%08x crc=%s overruns bg=%0d obj=%0d max_line_entries=%0d",
             scenario, post_ve_frames, post_ve_nonblack, debug_pc, crc_path,
             bg_overruns, obj_overruns, obj_max_line_entries);
    $finish;
end
endmodule
