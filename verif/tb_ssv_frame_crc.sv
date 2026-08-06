`timescale 1ns/1ps
// Real-ROM frame CRC dump + attract/coin soak for every universal SSV set.
// Plusargs:
//   +MAINROM= +SPRROM= +FRAME_CRC=path +STATE_CRC=path
//   +FRAMES=N +SOAK_FRAMES=N
//   +GAME_ID=0..9 +DSW1= +DSW2= +SCENARIO=attract_idle|coin_start_p1...
//   +DUMP_FRAME_DIAG (IRQ/list/scroll/pal snapshots at vb-edge)
//   +DUMP_LATE_LINE (classify the first object-renderer late line)
//   +REQUIRE_GAMEPLAY (require a jungle-stage visual at frame 850)
//   +DUMP_PPM=path +DUMP_PPM_FRAME=N  (write one 336x240 raw PPM after VE)
//   +REQUIRE_VERILATOR_SCREENSHOT    (require at least one PPM shot)
//   +USE_FRAC_CE (default on) uses ssv_tb_ce_cpu

`ifdef SSV_VISUAL_EXTERNAL_CLOCK
module tb_ssv_frame_crc(
    input  logic clk_sys,
    input  logic checkpoint_prepare,
    input  logic checkpoint_restore,
    output logic run_done,
    output logic [63:0] checkpoint_cycle_count,
    output logic [63:0] checkpoint_native_frame,
    output logic        checkpoint_ve_seen,
    output logic [31:0] checkpoint_post_ve_frame
);
`else
module tb_ssv_frame_crc;
logic run_done;
`endif
`include "ssv_tb_crc32.svh"

`ifdef SSV_VISUAL
import "DPI-C" function int ssv_visual_present(
    input bit [31:0] pixels [0:84479],
    input int unsigned width,
    input int unsigned height,
    input int unsigned raster_frame
);
import "DPI-C" function int ssv_visual_init();
import "DPI-C" function void ssv_visual_set_geometry(
    input int unsigned width,
    input int unsigned height
);
import "DPI-C" function int ssv_visual_poll();
import "DPI-C" function int ssv_visual_p1();
import "DPI-C" function int ssv_visual_system();
import "DPI-C" function void ssv_visual_trace_bus(
    input longint unsigned frame,
    input longint unsigned cycle,
    input int unsigned pc,
    input int unsigned write,
    input int unsigned address,
    input int unsigned data,
    input int unsigned lanes,
    input int unsigned device
);
import "DPI-C" function int ssv_visual_frame_commit(
    input int unsigned frame,
    input int unsigned p1_pressed,
    input int unsigned p2_pressed,
    input int unsigned system_pressed,
    input int unsigned pc,
    input int unsigned list512_crc,
    input int unsigned spr8k_crc,
    input int unsigned scroll63_crc,
    input int unsigned pal512_crc,
    input int unsigned st010_present,
    input int unsigned st010_pc,
    input int unsigned st010_a,
    input int unsigned st010_b,
    input int unsigned st010_dp,
    input int unsigned st010_dr,
    input int unsigned st010_k,
    input int unsigned st010_l,
    input int unsigned st010_m,
    input int unsigned st010_n
);
import "DPI-C" function void ssv_visual_audio_sample(
    input int signed sample_l,
    input int signed sample_r,
    input int unsigned source_rate
);
`endif

// The behavioural SDRAM model below decodes the same regions the RTL does.
// Import the layout instead of restating it: five benches used to carry their
// own copies of 0x0100000/0x1100000/0x1160000, and a divergence between them
// and ssv_pkg is exactly the "wrong ROM load offset" fake bug CLAUDE.md warns
// about.
import ssv_pkg::*;

`ifndef SSV_VISUAL_EXTERNAL_CLOCK
logic clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;
`endif

logic rst, ce_cpu;
logic st010_load_active;
integer st010_load_index;
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
// p5: ST010 program fetch. The physical profile serves this from SDRAM bank
// 3; the release behavioural model must provide the same burst rather than
// silently tying the port off, otherwise every ST010 game stalls as soon as
// the DSP leaves reset.
logic sdr_p5_req, sdr_p5_ack;
logic [SDR_AW:3] sdr_p5_addr;
logic [63:0] sdr_p5_dout;
logic st010_drom_we;
logic [10:0] st010_drom_wa;
logic [15:0] st010_drom_wd;

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
logic        beh_p5_ack;
logic [63:0] beh_p5_dout;
logic        real_p0_ack, real_p2_ack, real_wr_ack, real_p4_ack;
logic [15:0] real_p0_dout, real_p4_dout;
logic [127:0] real_p2_dout;
logic        sdram_ready;

// clk_ram is exactly twice clk_sys on hardware (96.6 / 48.3 MHz). Getting this
// ratio wrong would silently change every bandwidth number this harness exists
// to produce.
logic clk_ram = 1'b0;
`ifndef SSV_VISUAL_BEHAVIORAL_ONLY
always #2.5 clk_ram = ~clk_ram;
`endif

// Must match Arcade-SSV.sv's controller geometry, or +REAL_SDRAM measures a
// part the board does not have. AW then derives to 26 = ssv_pkg::SDR_AW, so
// the port widths line up with the core's without truncation -- and this build
// suppresses WIDTH warnings, so a mismatch here would be silent.
// SSV_CHIP_COL_BITS exists to run the harness's documented mismatch/aliasing
// negative test: the CONTROLLER keeps the geometry Arcade-SSV.sv instantiates
// (COL_BITS 11 = 128 MB), while the PART is built smaller. That is the only way
// to reproduce, in simulation, a board fitted with a module the controller was
// not built for -- every ordinary run leaves it at 11 and is unaffected.
`ifndef SSV_CHIP_COL_BITS
`define SSV_CHIP_COL_BITS 11
`endif
// SSV_CHIP_CLK_180 must stay 0: clocking the part model on the inverted clock
// does NOT model the board's 180-degree forwarded SDRAM_CLK -- in a zero-delay
// simulation it merely shifts which edge the part samples, and it breaks the
// PROVEN controller (reads return idle-bus zeros; the V60 dies at its reset
// vector). The 1 default briefly used here did exactly that while the contract
// and loader benches, which take the harness default of 0, kept passing -- a
// disagreement that cost a debugging round. The real phase relationship is
// STA/SDC territory. See ssv_sdram_harness.sv.
`ifndef SSV_CHIP_CLK_180
`define SSV_CHIP_CLK_180 0
`endif
`ifndef SSV_VISUAL_BEHAVIORAL_ONLY
ssv_sdram_harness #(
    .BANK_BITS(2), .ROW_BITS(13), .COL_BITS(11),
    .CHIP_COL_BITS(`SSV_CHIP_COL_BITS),
    .CHIP_CLK_180(`SSV_CHIP_CLK_180), .TRFC_CYC(11)
) u_sdram (
    .clk_ram(clk_ram), .init(rst), .ready(sdram_ready),
    .wr_req(sdr_wr_req), .wr_addr(sdr_wr_addr), .wr_din(sdr_wr_din),
    .wr_be(sdr_wr_be), .wr_ack(real_wr_ack),
    .p0_req(sdr_p0_req), .p0_addr(sdr_p0_addr),
    .p0_dout(real_p0_dout), .p0_ack(real_p0_ack),
    .p2_req(sdr_p2_req), .p2_addr(sdr_p2_addr),
    .p2_dout(real_p2_dout), .p2_ack(real_p2_ack),
    .p4_req(sdr_p4_req), .p4_addr(sdr_p4_addr),
    .p4_dout(real_p4_dout), .p4_ack(real_p4_ack),
    .p5_req(sdr_p5_req), .p5_addr(sdr_p5_addr),
    .p5_dout(sdr_p5_dout), .p5_ack(sdr_p5_ack)
);
`else
// Live lockstep uses the deterministic one-cycle behavioural ports below.
// Compiling the unused physical SDRAM model out avoids evaluating a second,
// twice-frequency clock domain on every frame. Real-SDRAM diagnostics retain
// the original instance by building without SSV_VISUAL_BEHAVIORAL_ONLY.
assign sdram_ready  = 1'b1;
assign real_p0_ack  = 1'b0;
assign real_p2_ack  = 1'b0;
assign real_wr_ack  = 1'b0;
assign real_p4_ack  = 1'b0;
assign real_p0_dout = 16'h0000;
assign real_p2_dout = 128'h0;
assign real_p4_dout = 16'h0000;
`endif

// Refutation condition for the "Dyna Gear is untouched" claim: if the ST010
// integration ever leaks a fetch on a title without the daughterboard, this
// fires instead of silently perturbing SDRAM arbitration.
always @(posedge clk_sys)
    if (!rst && sdr_p5_req && !sim_cfg.has_st010)
        $fatal(1, "ST010 program fetch requested with cfg.has_st010 = 0");

// Handshake census, counted on the RISING EDGE of each strobe so a level held
// across many cycles counts once -- the controller services one transaction per
// rising edge, so edges are the meaningful unit.
integer dbg_p0_req_cnt = 0, dbg_p0_ack_cnt = 0;
integer dbg_p2_req_cnt = 0, dbg_p2_ack_cnt = 0;
integer dbg_wr_req_cnt = 0, dbg_wr_ack_cnt = 0;
logic dbg_p0_rq, dbg_p0_ak, dbg_p2_rq, dbg_p2_ak, dbg_wr_rq, dbg_wr_ak;
always @(posedge clk_sys) begin
    dbg_p0_rq <= sdr_p0_req; dbg_p0_ak <= sdr_p0_ack;
    dbg_p2_rq <= sdr_p2_req; dbg_p2_ak <= sdr_p2_ack;
    dbg_wr_rq <= sdr_wr_req; dbg_wr_ak <= sdr_wr_ack;
    if (sdr_p0_req & ~dbg_p0_rq) dbg_p0_req_cnt <= dbg_p0_req_cnt + 1;
    if (sdr_p0_ack & ~dbg_p0_ak) dbg_p0_ack_cnt <= dbg_p0_ack_cnt + 1;
    // First transactions in full: the census said 12 reqs all acked and then
    // silence, which cannot distinguish wrong-data from a wedged consumer.
    // Addresses and returned words can -- they are checkable against
    // sim_output/rom/maincpu.bin offline.
    if (sdr_p0_req & ~dbg_p0_rq && dbg_p0_req_cnt < 20)
        $display("P0LOG req %0d byteaddr=%07h", dbg_p0_req_cnt, {sdr_p0_addr, 1'b0});
    if (sdr_p0_ack & ~dbg_p0_ak && dbg_p0_ack_cnt < 20)
        $display("P0LOG ack %0d dout=%04h", dbg_p0_ack_cnt, sdr_p0_dout);
    if (sdr_p2_req & ~dbg_p2_rq) dbg_p2_req_cnt <= dbg_p2_req_cnt + 1;
    if (sdr_p2_ack & ~dbg_p2_ak) dbg_p2_ack_cnt <= dbg_p2_ack_cnt + 1;
    if (sdr_wr_req & ~dbg_wr_rq) dbg_wr_req_cnt <= dbg_wr_req_cnt + 1;
    if (sdr_wr_ack & ~dbg_wr_ak) dbg_wr_ack_cnt <= dbg_wr_ack_cnt + 1;
end

`ifdef SSV_VISUAL_BEHAVIORAL_ONLY
// The release visual profile compiles the physical SDRAM model out. Make its
// selected response path constant as well, so Verilator does not retain seven
// dead runtime muxes in the hot model evaluation path.
assign sdr_p0_ack  = beh_p0_ack;
assign sdr_p2_ack  = beh_p2_ack;
assign sdr_wr_ack  = beh_wr_ack;
assign sdr_p4_ack  = beh_p4_ack;
assign sdr_p5_ack  = beh_p5_ack;
assign sdr_p0_dout = beh_p0_dout;
assign sdr_p2_dout = beh_p2_dout;
assign sdr_p4_dout = beh_p4_dout;
assign sdr_p5_dout = beh_p5_dout;
`else
assign sdr_p0_ack  = use_real_sdram ? real_p0_ack  : beh_p0_ack;
assign sdr_p2_ack  = use_real_sdram ? real_p2_ack  : beh_p2_ack;
assign sdr_wr_ack  = use_real_sdram ? real_wr_ack  : beh_wr_ack;
assign sdr_p4_ack  = use_real_sdram ? real_p4_ack  : beh_p4_ack;
assign sdr_p0_dout = use_real_sdram ? real_p0_dout : beh_p0_dout;
assign sdr_p2_dout = use_real_sdram ? real_p2_dout : beh_p2_dout;
assign sdr_p4_dout = use_real_sdram ? real_p4_dout : beh_p4_dout;
`endif
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;
integer visual_width, visual_height, visual_expected_pixels;

`ifdef SSV_VISUAL
bit [31:0] visual_pixels [0:84479];
integer visual_status;
integer visual_trace_device;
integer visual_p1_mask, visual_system_mask;
integer visual_index_nonzero, visual_palette_nonblack, visual_active_pixels;
integer visual_line_starts, visual_renderer_starts;
integer visual_bg_done, visual_obj_done;
integer visual_cache_busy_cycles, visual_cache_ready_cycles;
integer visual_cache_overflows;
integer visual_cache_blocked_swaps;
integer visual_irq_req_cycles, visual_irq_active_cycles;
integer visual_irq_acks, visual_ram0_writes, visual_irq_reg_writes;
integer visual_bg_plot_pixels, visual_obj_plot_pixels;
integer visual_gfx_acks, visual_gfx_nonzero_acks;
integer visual_bg_fetch_done, visual_obj_fetch_done;
integer visual_bg_nonzero_rows, visual_obj_nonzero_rows;
integer visual_bg_nonzero_pens, visual_obj_nonzero_pens;
integer visual_nonzero_spr_writes, visual_spr_write_logs;
integer visual_cache_store_logs;
integer visual_boot_trace_count;
logic [31:0] visual_boot_trace_pc;
integer visual_loop_trace_count;
longint unsigned visual_loop_trace_start;
longint unsigned visual_sample_fetches, visual_nonzero_sample_fetches;
integer visual_sample_fetch_logs;
logic [15:0] visual_sample_word;
logic visual_cache_slot_valid;
logic [11:0] visual_cache_last_slot;
longint visual_total_spr_writes, visual_total_pal_writes, visual_total_scroll_writes;
logic visual_spr_write_d;
logic [23:0] visual_spr_write_addr_d;
logic [15:0] visual_spr_write_data_d;
logic [1:0] visual_spr_write_be_d;
logic visual_user_quit;
logic visual_diag;
`endif

logic [15:0] in_p1, in_p2, in_system, in_extra, in_dsw1, in_dsw2;

byte main_rom [0:4194303];
byte sprite_rom [0:33554431];
byte sample_rom [0:8388607];
byte st010_rom [0:69631];
integer sample_fd, sample_count;
integer st010_fd, st010_count;
string sample_path;
string st010_path;
// XRAM (128 KiB), CPU RAM (256 KiB), and Cairblad NVRAM (64 KiB) share the
// external SDRAM behavioural window. The NVRAM is descriptor-selected and
// uses the otherwise unused tail immediately above SDR_CPU_RAM_BASE.
logic [15:0] external_ram [0:229375];

string main_path, sprite_path, crc_path, state_path, scenario;
string game_name;
ssv_cfg_t sim_cfg;
integer selected_game_id;
integer prog_bytes, gfx_stream_bytes, gfx_quarter_bytes, sample_bytes;
logic [15:0] dsw1_value, dsw2_value;
logic [127:0] gfx_word_tmp;
integer gfx_q, gfx_src;
logic packed_gfx;
integer main_fd, sprite_fd, crc_fd, state_fd;
integer main_count, sprite_count, i;
// 32-bit `integer` caps +CYCLES at 2^31-1, which is only ~2640 post-VE frames
// (~805k clk_sys per 60 Hz frame plus ~26M of boot).  The long gameplay
// scenario needs more than that, so the cycle budget is 64-bit.
longint cycle_count, max_cycles;

// ---------------------------------------------------------------------
// V60 per-instruction cycle-cost profiler (simulation-only, additive).
// Taps the CPU's existing dbg_retire/dbg_pc/cur_op debug hooks
// (rtl/cpu/v60/s32_v60.sv) hierarchically via `dut.cpu.*` -- exactly like
// the pre-existing BOOT_TRACE/CPU_LOOP_TRACE probes below already do for
// dut.cpu.st/dut.cpu.r[]. Zero RTL changes; reads only. See
// docs/hardware/V60_CYCLE_TIMING_REFERENCE.md for the hardware targets
// this is meant to be compared against (via tools/analyze_v60_cycle_profile.py).
// Enabled with +V60_CYCLE_PROFILE; window and output path are configurable.
// ---------------------------------------------------------------------
bit                    v60_prof_enable;
bit                    v60_prof_started;
integer                v60_prof_lo_frame, v60_prof_hi_frame;
string                 v60_prof_path;
integer                v60_prof_fd;
longint unsigned       v60_prof_last_tick;
longint unsigned       v60_prof_delta;
logic [7:0]            v60_prof_op_tmp;
longint unsigned       v60_prof_op_count [0:255];
longint unsigned       v60_prof_op_cycles[0:255];
longint unsigned       v60_prof_op_min   [0:255];
longint unsigned       v60_prof_op_max   [0:255];
longint unsigned       v60_prof_total_instrs;

// ---------------------------------------------------------------------
// V60 per-FSM-state cycle profiler, gated to ONE target opcode byte per run
// (+V60_STATE_PROFILE_OP=<hex>). Same dbg-hook tap as the opcode profiler
// above; additionally reads dut.cpu.st (already used elsewhere in this file,
// e.g. BOOT_TRACE/CPU_LOOP_TRACE). Localizes WHERE inside a specific
// instruction's execution its cycles go (S_EA_MODE, S_WB_MEM, etc.) --
// the natural next step after the opcode-level ranking in
// docs/hardware/V60_CYCLE_PROFILE_FINDINGS.md. Caveat: cur_op still holds
// the OUTGOING instruction's opcode during the retiring S_DECODE cycle
// itself (see that same finding doc / the opcode profiler's comment below),
// so each instruction's own S_DECODE cycle is undercounted by exactly one
// tick, attributed instead to whatever instruction preceded it. Negligible
// against the hundreds of cycles a single instruction spans, but real --
// documented rather than engineered around, to keep this instrumentation
// simple and reuse the already-validated read timing.
// ---------------------------------------------------------------------
bit                    v60_stateprof_enable;
logic [7:0]            v60_stateprof_target_op;
longint unsigned       v60_stateprof_cycles [0:127];
longint unsigned       v60_stateprof_entries[0:127];
logic [6:0]            v60_stateprof_prev_st;
bit                    v60_stateprof_prev_valid;
string                 v60_stateprof_path;
integer                v60_stateprof_fd;

// ---------------------------------------------------------------------
// V60 memory-access-site trace: which memory region (sel_wram/sel_sprram/
// sel_rom/etc, from ssv_core.sv's own address decode) and how many clk_sys
// ticks a specific opcode's S_WB_MEM/S_OP2_LD wait actually resolves against.
// Answers whether the dominant cost found in
// docs/hardware/V60_CYCLE_PROFILE_FINDINGS.md is SDRAM-arbitration-bound
// (sel_rom) or local-BRAM-bound (sel_wram/sel_sprram/etc, no SDRAM
// controller or arbiter involved at all). Bounded print count; simulation
// only, no RTL signal written.
// ---------------------------------------------------------------------
bit                    v60_memtrace_enable;
logic [7:0]            v60_memtrace_target_op;
integer                v60_memtrace_printed;
integer                v60_memtrace_max;
logic [6:0]            v60_memtrace_prev_st;
bit                    v60_memtrace_prev_valid;
longint unsigned       v60_memtrace_entry_tick;

`ifdef SSV_VISUAL_EXTERNAL_CLOCK
logic external_setup_complete;
integer external_reset_edges;
longint unsigned native_frame_boundaries;

// These observability-only ports let the no-timing host stop on a real raster
// boundary before a game performs its software video-enable write.  Long ROM
// self-tests can therefore be accumulated in bounded full-state chunks without
// inventing a game-specific fast boot or saving at an arbitrary CPU cycle.
assign checkpoint_cycle_count = cycle_count;
assign checkpoint_native_frame = native_frame_boundaries;
assign checkpoint_ve_seen = ve_seen;
assign checkpoint_post_ve_frame = post_ve_frames;
`endif
integer p1_transactions;
// coin_start_p1-family override, mirroring tools/mame-capture-ssv-frames.lua's
// SSV_COIN_FRAME_LO/HI env vars -- see apply_inputs() for why.
integer coin_frame_lo, coin_frame_hi, start_frame_lo, start_frame_hi;
integer visual_p2_nonzero_code_logs;
integer visual_p2_max_code;
logic visual_p2_code_valid;
logic [19:0] visual_p2_last_code;
integer frame_idx, post_ve_frames, max_frames, soak_frames;
integer state_start_frame;
integer active_pixels, nonblack_pixels, post_ve_nonblack;
integer select_header_pixels, frame_nonblack;
integer gameplay_green_pixels;
logic require_play, play_reached, require_gameplay, gameplay_reached;
logic require_attract, attract_reached;
logic require_verilator_screenshot;
integer attract_visible_frames, attract_active_frames;
longint unsigned attract_last_retire;
longint unsigned attract_last_activity;
// Sticky evidence/scenario epoch: accepted software video-enable write, not
// the hardware latch's power-on level (which is already enabled per MAME).
logic ve_seen, vb_d, frame_active;
logic [31:0] idx_crc, rgb_crc;
logic [14:0] idx15;
integer px_count;
logic p0_seen, p1_seen, wr_seen, p4_seen, p5_seen;
logic [3:0] p0_hold, p1_hold, wr_hold, p4_hold, p5_hold;
logic [SDR_AW:0] p0_byte_addr, p1_byte_addr, p4_byte_addr, p5_byte_addr;
integer st010_byte_offset;
integer ext_index, sprite_index, packed_code, packed_row, sample_offset;
integer raw_q0_index, raw_q1_index, raw_q2_index;
integer stuck, last_pc_i;
logic [31:0] last_pc;
integer bg_overruns, obj_overruns;
integer watchdog_soft_resets;
logic wdog_rst_d;
integer obj_line_cycles, obj_rom_wait_cycles, obj_max_line_cycles;
integer obj_line_descriptors, obj_line_fetches, obj_line_tilemap_fetches;
integer obj_line_plot_cycles;
integer obj_max_line_entries;
integer cache_build_cycles, cache_build_max, cache_build_max_frame;
integer cache_build_start_v, cache_deadline_hits;
logic   cache_busy_d;
logic obj_busy_d, dump_renderer_budget, stop_on_renderer_overrun;
logic obj_cache_overflow_d;
logic dump_late_line, late_line_dumped;
integer dump_x, dump_y, dump_count;
integer overflow_i, overflow_entry, overflow_tile_desc, overflow_sprite_desc;
integer overflow_tile_groups [0:7];
logic [127:0] overflow_desc;
integer late_i, late_entry, late_base, late_count, late_page;
integer late_nonzero_local, late_tile_candidates;
integer late_g0 [0:15];
logic [127:0] late_desc;
logic dump_pixels, dump_frame_diag, dump_ppm_en, dump_ppm_open;
logic ppm_open_event;
logic ignore_overrun;
// Diagnostic runs that intentionally stop on a renderer overflow can leave
// the frame black; allow their allocator census to print without weakening
// the normal strict attract gate.
logic ignore_nonblack;
string irq_schedule_path, ppm_path, ppm_prefix;
integer ppm_fd, ppm_frame, ppm_pixels;
integer ppm_start, ppm_count, ppm_step, ppm_shots_done;
integer irq_schedule_fd, irq_scan_result;
logic diff_irq_enabled, diff_vblank_pulse, diff_count_started;
longint unsigned retire_count, next_irq_retire;
longint unsigned cpu_activity_count;
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

// samples.bin is the generator's canonical MAME ROM_REGION16_BE byte image.
// The even byte is therefore the high half of the ES5506 word, exactly as in
// ssv_rom_loader; do not reuse the V60 little-endian pairing here.
function automatic logic [15:0] sample_word_be(
    input byte first_byte, input byte second_byte
);
    sample_word_be = {first_byte, second_byte};
endfunction

// The loader stores non-sample streams as little-endian SDRAM words.  The
// physical p5 burst returns four such words in descending vector order; this
// helper keeps the behavioural path byte-identical to rtl/mem/sdram.sv.
function automatic logic [15:0] st010_word(input integer byte_offset);
    if (byte_offset >= 0 && byte_offset + 1 < st010_count)
        st010_word = {st010_rom[byte_offset + 1], st010_rom[byte_offset]};
    else
        st010_word = 16'h0000;
endfunction

ssv_tb_ce_cpu u_ce (.clk(clk_sys), .rst(rst), .ce_cpu(ce_cpu));

// With the real controller the core must stay in cold reset until the chip has
// finished its init sequence, exactly as Arcade-SSV.sv does on hardware.  The
// watchdog is a separate soft reset: feeding it back here is required for a
// real-game run to exercise the same Dyna/Vasara reset path as the MiSTer top.
// core_cold_rst is identical to `rst` with the behavioural SDRAM model.
`ifdef SSV_VISUAL_BEHAVIORAL_ONLY
wire core_cold_rst = rst | st010_load_active;
`else
wire core_cold_rst = rst | st010_load_active |
                     (use_real_sdram & ~sdram_ready);
`endif
wire wdog_rst;
wire core_rst = core_cold_rst | wdog_rst;

ssv_core dut (
    .cfg(sim_cfg),
    .clk_sys(clk_sys), .rst(core_rst), .cold_rst(core_cold_rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .sdr_p5_req(sdr_p5_req), .sdr_p5_addr(sdr_p5_addr),
    .sdr_p5_dout(sdr_p5_dout), .sdr_p5_ack(sdr_p5_ack),
    .st010_drom_we(st010_drom_we), .st010_drom_wa(st010_drom_wa),
    .st010_drom_wd(st010_drom_wd),
    .in_dsw1(in_dsw1), .in_dsw2(in_dsw2),
    .in_p1(in_p1), .in_p2(in_p2),
    .in_system(in_system), .in_extra(in_extra),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .wdog_rst(wdog_rst),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

// A qualified game must service its descriptor-selected watchdog. Count the
// actual feedback pulse independently of core_rst so a soft reset cannot erase
// its own evidence from the testbench.
always_ff @(posedge clk_sys) begin
    if (rst) begin
        wdog_rst_d <= 1'b0;
        watchdog_soft_resets <= 0;
    end
    else begin
        wdog_rst_d <= wdog_rst;
        if (wdog_rst && !wdog_rst_d) begin
            watchdog_soft_resets <= watchdog_soft_resets + 1;
            $display("SSV_WATCHDOG_SOFT_RESET count=%0d frame=%0d pc=%08x",
                     watchdog_soft_resets + 1, post_ve_frames, debug_pc);
        end
    end
end

`ifdef SSV_VISUAL
// sound_sample_tick and audio_l/audio_r are registered together in the voice
// engine. Observing the prior-cycle tick here therefore presents the matching
// completed stereo sample to the host, not the next mix accumulator value.
always_ff @(posedge clk_sys) begin
    if (!core_rst && dut.sound_sample_tick &&
        (!ve_seen || post_ve_frames >= state_start_frame)) begin
        ssv_visual_audio_sample(
            int'($signed(audio_l)), int'($signed(audio_r)),
            16_000_000 / (16 * (int'(dut.sound_active_voices) + 1)));
    end
end
`endif

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
// whether the per-line guard is comfortable or one busy scene away from
// dropping sprites. A line that reaches LINE_SLOTS has already saturated its
// bucket, so `occ_at_cap` is the number that would justify raising the guard.
// Sampled when the vblank build finishes, which is the only point the table is
// complete and stable.
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
// BUILD_STORE and to line_entries only in BUILD_REINDEX_BUCKET_WRITE, while
// the reads happen only in RENDER_* states -- so build and render can never
// collide. line_page_starts is different: its read at
// ssv_cached_sprite_renderer.sv:702
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
// rtl/video/ssv_cached_sprite_renderer.sv (IDLE is 0). Keep these explicit
// because this is sim-only instrumentation and is not part of the DUT.
localparam logic [5:0] ST_BUILD_STORE        = 6'd13;
localparam logic [5:0] ST_BUILD_BUCKET_WRITE = 6'd15;
localparam logic [5:0] ST_REINDEX_BUCKET_WRITE = 6'd24;
localparam logic [5:0] ST_RENDER_COUNT_READ  = 6'd25;
localparam logic [5:0] ST_RENDER_COUNT_WAIT  = 6'd26;
localparam logic [5:0] ST_RENDER_LINE_READ   = 6'd27;
localparam logic [5:0] ST_RENDER_READ        = 6'd28;
localparam logic [5:0] ST_RENDER_DECODE      = 6'd29;
localparam logic [5:0] ST_RENDER_PREP        = 6'd30;
localparam logic [5:0] ST_RENDER_EVAL        = 6'd31;
localparam logic [5:0] ST_RENDER_SPRITE_PREP = 6'd32;
localparam logic [5:0] ST_TILE_PREP          = 6'd38;
localparam logic [5:0] ST_FETCH_START        = 6'd39;
localparam logic [5:0] ST_FETCH_WAIT         = 6'd40;
localparam logic [5:0] ST_PLOT               = 6'd41;

// Reconstruct the exact enable conditions from the RAM process at
// ssv_cached_sprite_renderer.sv:697-710, so these track the design rather than
// a paraphrase of it.
wire c6_entry_rd = (dut.sprite_renderer.state == ST_RENDER_LINE_READ) ||
                   (dut.sprite_renderer.state == ST_RENDER_DECODE)    ||
                   (dut.sprite_renderer.state == ST_RENDER_PREP);
wire c6_entry_wr =
    (dut.sprite_renderer.state == ST_REINDEX_BUCKET_WRITE);
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

// The ROM loader normally writes the ST010 data half while the MiSTer
// download is in progress. Real-ROM visual runs bypass that download, so
// reproduce the same one-time 2K-word load here and hold the shared core in
// cold reset until the DSP data ROM is complete.
always_ff @(posedge clk_sys) begin
    if (rst) begin
        st010_drom_we     <= 1'b0;
        st010_drom_wa     <= 11'd0;
        st010_drom_wd     <= 16'd0;
        st010_load_index  <= 0;
        st010_load_active <= sim_cfg.has_st010;
    end
    else if (st010_load_active && st010_load_index < 2048) begin
        st010_drom_we <= 1'b1;
        st010_drom_wa <= st010_load_index[10:0];
        st010_drom_wd <= {st010_rom[17'h10000 + st010_load_index * 2],
                          st010_rom[17'h10001 + st010_load_index * 2]};
        st010_load_index <= st010_load_index + 1;
    end
    else if (st010_load_active) begin
        // The final write is observed by the dual-port RAM one clock after
        // index 2047 is presented.
        st010_load_active <= 1'b0;
        st010_drom_we <= 1'b0;
    end
    else
        st010_drom_we <= 1'b0;
end

// Sticky multi-cycle ack (covers CE gaps from fractional enable).
always_ff @(posedge clk_sys) begin
    beh_p0_ack <= 1'b0;
    beh_p2_ack <= 1'b0;
    beh_wr_ack <= 1'b0;
    beh_p4_ack <= 1'b0;
    beh_p5_ack <= 1'b0;
    if (rst) begin
        p0_seen <= 1'b0; p1_seen <= 1'b0;
        wr_seen <= 1'b0; p4_seen <= 1'b0; p5_seen <= 1'b0;
        p0_hold <= 4'd0; p1_hold <= 4'd0;
        wr_hold <= 4'd0; p4_hold <= 4'd0; p5_hold <= 4'd0;
        p1_transactions <= 0;
        visual_p2_nonzero_code_logs <= 0;
        visual_p2_max_code <= 0;
        visual_p2_code_valid <= 1'b0;
        visual_p2_last_code <= 20'd0;
        p1_delay <= 0;
        bg_ack_while_obj_owns <= 0;
        bg_fetch_state_d <= 2'd0;
        obj_owned_d <= 1'b0;
        tm_state_d <= 6'd0;
        extra_reads <= 0;
        extra_ack_d <= 1'b0;
        cache_peak <= 0;
        cache_peak_frame <= 0;
`ifdef SSV_VISUAL
        visual_sample_fetches <= 0;
        visual_nonzero_sample_fetches <= 0;
        visual_sample_fetch_logs <= 0;
`endif
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
            dut.sprite_renderer.state == 6'd38) begin   // TILE_PREP
            $display("TM f=%0d y=%0d grp=%0d mode=%04x sz=%0d sx=%05x mapx=%05x mapy=%05x addr=%05x peek=%04x/%04x code=%04x attr=%04x scrx=%0d",
                     post_ve_frames, dut.sprite_renderer.target_y_latched,
                     dut.sprite_renderer.prep_tile_group,
                     dut.sprite_renderer.tile_mode,
                     dut.sprite_renderer.tile_mode[15:13],
                     dut.sprite_renderer.tile_scroll_x,
                     dut.sprite_renderer.tile_map_x,
                     dut.sprite_renderer.tile_map_y,
                     dut.sprite_renderer.tile_word_addr,
                     spr_peek(dut.sprite_renderer.tile_word_addr),
                     spr_peek(dut.sprite_renderer.tile_word_addr + 1'd1),
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
            // External RAM physically occupies the gap between the program
            // and graphics slots. Test it first: `< SDR_GFX_BASE` aliases
            // XRAM/CPU-RAM reads onto main_rom[] (Twin Eagle II stack pops).
            if (p0_byte_addr >= SDR_XRAM_BASE && p0_byte_addr < SDR_SAMPLES_BASE) begin
                ext_index = (p0_byte_addr - SDR_XRAM_BASE) >> 1;
                beh_p0_dout <= external_ram[ext_index];
            end else if (p0_byte_addr < SDR_XRAM_BASE)
                beh_p0_dout <= {main_rom[p0_byte_addr+1], main_rom[p0_byte_addr]};
            else
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
            if (sprite_index >= 0 &&
                sprite_index < (int'(sim_cfg.gfx_mb) * 1048576)) begin
                packed_code = sprite_index >> 7;
                packed_row = (sprite_index >> 4) & 7;
                raw_q0_index = packed_code * 32 + packed_row * 4;
                gfx_word_tmp = 128'd0;
                // The input image is the MRA graphics stream: each logical
                // quarter is gfx_region/4 bytes, including erased holes. The
                // physical SDRAM record always has four lanes; Q3 is zero for
                // the three-quarter boards and populated for Vasara.
                for (gfx_q = 0; gfx_q < 4; gfx_q = gfx_q + 1) begin
                    if (gfx_q < sim_cfg.gfx_quarters) begin
                        gfx_src = gfx_q * gfx_quarter_bytes + raw_q0_index;
                        gfx_word_tmp[gfx_q*32 +: 32] = {
                            sprite_rom[gfx_src+3], sprite_rom[gfx_src+2],
                            sprite_rom[gfx_src+1], sprite_rom[gfx_src]
                        };
                    end
                end
`ifdef SSV_VISUAL
                if (packed_code > visual_p2_max_code)
                    visual_p2_max_code <= packed_code;
                if (visual_diag &&
                    (p1_transactions < 16 ||
                     ((!visual_p2_code_valid ||
                       packed_code != visual_p2_last_code) &&
                      visual_p2_nonzero_code_logs < 128))) begin
                    $display("P2LOG tx=%0d addr=%07x sprite_index=%08x code=%05x row=%0d raw=%08x src_last=%08x data=%032x",
                             p1_transactions, p1_byte_addr, sprite_index,
                             packed_code, packed_row, raw_q0_index, gfx_src,
                             gfx_word_tmp);
                    if (!visual_p2_code_valid ||
                        packed_code != visual_p2_last_code) begin
                        visual_p2_nonzero_code_logs <=
                            visual_p2_nonzero_code_logs + 1;
                        visual_p2_code_valid <= 1'b1;
                        visual_p2_last_code <= packed_code;
                    end
                end
`endif
                beh_p2_dout <= gfx_word_tmp;
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
`ifdef SSV_VISUAL
            p4_byte_addr = {sdr_p4_addr, 1'b0};
            sample_offset = int'(p4_byte_addr - SDR_SAMPLES_BASE);
            if (p4_byte_addr >= SDR_SAMPLES_BASE && sample_offset >= 0 &&
                sample_offset + 1 < sample_count) begin
                visual_sample_word = sample_word_be(
                    sample_rom[sample_offset], sample_rom[sample_offset+1]);
                beh_p4_dout <= visual_sample_word;
                visual_sample_fetches <= visual_sample_fetches + 1;
                if (visual_sample_word != 16'd0)
                    visual_nonzero_sample_fetches <=
                        visual_nonzero_sample_fetches + 1;
                if (visual_sample_fetch_logs < 8) begin
                    $display("SSV_VISUAL_SAMPLE_FETCH seq=%0d addr=%07x offset=%07x data=%04x",
                             visual_sample_fetches, p4_byte_addr,
                             sample_offset, visual_sample_word);
                    visual_sample_fetch_logs <= visual_sample_fetch_logs + 1;
                end
            end else begin
                beh_p4_dout <= 16'd0;
                if (visual_sample_fetch_logs < 8) begin
                    $display("SSV_VISUAL_SAMPLE_FETCH_OOB seq=%0d addr=%07x offset=%0d bytes=%0d",
                             visual_sample_fetches, p4_byte_addr,
                             sample_offset, sample_count);
                    visual_sample_fetch_logs <= visual_sample_fetch_logs + 1;
                end
            end
`else
            beh_p4_dout <= 16'd0;
`endif
            p4_hold <= 4'd2;
        end
        if (p4_hold != 0) begin
            beh_p4_ack <= 1'b1;
            p4_hold <= p4_hold - 1'd1;
        end else if (!sdr_p4_req)
            p4_seen <= 1'b0;

        // ST010 program fetches are 8-byte p5 bursts.  The physical SDRAM
        // controller returns word@+6 in [63:48] down to word@+0 in [15:0],
        // while each non-sample loader word is {stream[odd],stream[even]}.
        if (sdr_p5_req && !p5_seen) begin
            p5_seen <= 1'b1;
            p5_byte_addr = {sdr_p5_addr, 3'b000};
            st010_byte_offset = integer'(p5_byte_addr - SDR_ST010_BASE);
            beh_p5_dout <= {
                st010_word(st010_byte_offset + 6),
                st010_word(st010_byte_offset + 4),
                st010_word(st010_byte_offset + 2),
                st010_word(st010_byte_offset + 0)
            };
            p5_hold <= 4'd2;
        end
        if (p5_hold != 0) begin
            beh_p5_ack <= 1'b1;
            p5_hold <= p5_hold - 1'd1;
        end else if (!sdr_p5_req)
            p5_seen <= 1'b0;
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
        cpu_activity_count <= 0;
        diff_count_started <= 1'b0;
    end else begin
        if (ce_cpu && dut.cpu.st == 7'd3 &&
            !(!dut.irq_n && dut.cpu.psw_ie)) begin
            cpu_activity_count <= cpu_activity_count + 1;
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
end

task automatic apply_inputs(input integer f);
    in_dsw1 = dsw1_value;
    in_dsw2 = dsw2_value;
    in_p2 = 16'hffff;
    in_extra = 16'hffff;
    in_p1 = 16'hffff;
    in_system = 16'hffff;
    // Diagnostic-only probe: a much longer, more forgiving coin+start hold
    // than coin_start_p1's 4-frame pulses, used to check whether a title's
    // coin-accept window is simply longer than that script assumes. Not
    // tuned for any specific game's actual gameplay beyond coin+start.
    if (scenario == "coin_start_probe") begin
        if (f >= 20 && f < 60)   in_system[0] = 1'b0;  // COIN1, held 40 frames
        if (f >= 80 && f < 140)  in_p1[0] = 1'b0;       // START, held 60 frames
    end
    if (scenario == "coin_start_p1" ||
        scenario == "coin_start_p1_gameplay" ||
        scenario == "coin_start_p1_long" ||
        scenario == "coin_start_p1_runright") begin
        // coin_frame_lo/hi and start_frame_lo/hi default to the original
        // Dyna Gear-tuned 30-34/165-170 (see +COIN_FRAME_LO=/etc. parsing
        // below) -- overridable per set without changing any existing
        // scenario's behavior. Mirrors the same fix applied to
        // tools/mame-capture-ssv-frames.lua's SSV_COIN_FRAME_LO/HI for the
        // identical reason: vasara1's own coin-poll loop does not start
        // until post-VE frame ~73 (docs/debug/vasara/GAMEPLAY_AND_SOUND.md),
        // so the 30-34 default is structurally invisible to that title.
        if (f >= coin_frame_lo && f < coin_frame_hi) in_system = 16'hfffe; // COIN1
        // Wait for "PUSH START" after coin, then enter select.
        if (f >= start_frame_lo && f < start_frame_hi) in_p1[0] = 1'b0;   // START
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
`ifdef SSV_VISUAL
    // SDL reports active-high pressed controls; the SSV ports are active low.
    // Overlay live controls after any deterministic scenario inputs so the
    // same universal testbench remains usable both interactively and in gates.
    visual_p1_mask = ssv_visual_p1();
    visual_system_mask = ssv_visual_system();
    in_p1 = in_p1 & ~visual_p1_mask[15:0];
    in_system = in_system & ~visual_system_mask[15:0];
`endif
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
`ifdef SSV_VISUAL_EXTERNAL_CLOCK
        native_frame_boundaries <= 0;
`endif
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
        attract_reached <= 1'b0;
        attract_visible_frames <= 0;
        attract_active_frames <= 0;
        attract_last_retire <= 0;
        attract_last_activity <= 0;
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
        late_line_dumped <= 1'b0;
        stuck <= 0;
        last_pc <= 32'hffffffff;
        irq_entries_post_ve <= 0;
        vb_pulses_post_ve <= 0;
        dump_ppm_open <= 1'b0;
        ppm_pixels <= 0;
        ppm_shots_done <= 0;
`ifdef SSV_VISUAL
        visual_index_nonzero <= 0;
        visual_palette_nonblack <= 0;
        visual_active_pixels <= 0;
        visual_line_starts <= 0;
        visual_renderer_starts <= 0;
        visual_bg_done <= 0;
        visual_obj_done <= 0;
        visual_cache_busy_cycles <= 0;
        visual_cache_ready_cycles <= 0;
        visual_cache_overflows <= 0;
        visual_cache_blocked_swaps <= 0;
        visual_irq_req_cycles <= 0;
        visual_irq_active_cycles <= 0;
        visual_irq_acks <= 0;
        visual_ram0_writes <= 0;
        visual_irq_reg_writes <= 0;
        visual_bg_plot_pixels <= 0;
        visual_obj_plot_pixels <= 0;
        visual_gfx_acks <= 0;
        visual_gfx_nonzero_acks <= 0;
        visual_bg_fetch_done <= 0;
        visual_obj_fetch_done <= 0;
        visual_bg_nonzero_rows <= 0;
        visual_obj_nonzero_rows <= 0;
        visual_bg_nonzero_pens <= 0;
        visual_obj_nonzero_pens <= 0;
        visual_nonzero_spr_writes <= 0;
        visual_spr_write_logs <= 0;
        visual_cache_store_logs <= 0;
        visual_boot_trace_count <= 0;
        visual_boot_trace_pc <= 32'hffff_ffff;
        visual_loop_trace_count <= 0;
        visual_cache_slot_valid <= 1'b0;
        visual_cache_last_slot <= 12'd0;
        visual_spr_write_d <= 1'b0;
        visual_spr_write_addr_d <= 24'd0;
        visual_spr_write_data_d <= 16'd0;
        visual_spr_write_be_d <= 2'd0;
        visual_total_spr_writes <= 0;
        visual_total_pal_writes <= 0;
        visual_total_scroll_writes <= 0;
`endif
    end else begin
`ifdef SSV_VISUAL
        // Keep accepted-event append and the later blocking frame commit in
        // this one procedural block. Separate always_ff blocks have no active-
        // region order, which could otherwise publish a token before its last
        // bus event. Program ROM and private work RAM remain intentionally out.
        if (post_ve_frames >= state_start_frame &&
            dut.m_req && dut.m_ack && !dut.ack_r_d && !dut.sel_rom) begin
            visual_trace_device = 0;
            if (dut.sel_sprram)                       visual_trace_device = 2;
            else if (dut.sel_palette)                 visual_trace_device = 3;
            else if (dut.sel_nvram)                   visual_trace_device = 4;
            else if (dut.sel_scroll)                  visual_trace_device = 5;
            else if (dut.sel_io || dut.sel_extra)     visual_trace_device = 6;
            else if (dut.sel_irqvec || dut.sel_irqack || dut.sel_irqen)
                                                        visual_trace_device = 7;
            else if (dut.sel_sound)                   visual_trace_device = 8;
            else if (dut.sel_st010)                   visual_trace_device = 9;
            else if (dut.sel_drifto_unknown)          visual_trace_device = 10;
            if (visual_trace_device != 0)
                ssv_visual_trace_bus(
                    post_ve_frames, cycle_count, debug_pc, dut.m_we, dut.a,
                    dut.m_we ? dut.m_wdata : dut.m_rdata, dut.m_be,
                    visual_trace_device);
        end
        if (visual_diag) begin
        if (dut.line_buffer_start) visual_line_starts <= visual_line_starts + 1;
        if (dut.renderer_line_start) visual_renderer_starts <= visual_renderer_starts + 1;
        if (dut.bg_done) visual_bg_done <= visual_bg_done + 1;
        if (dut.obj_done) visual_obj_done <= visual_obj_done + 1;
        if (dut.obj_cache_busy) visual_cache_busy_cycles <= visual_cache_busy_cycles + 1;
        if (dut.sprite_renderer.cache_ready) visual_cache_ready_cycles <= visual_cache_ready_cycles + 1;
        if (dut.obj_cache_overflow) visual_cache_overflows <= visual_cache_overflows + 1;
        if (dut.video_enable && dut.ce_pixel &&
            (dut.hcnt == dut.active_width - 1'd1) &&
            (dut.renderer_target_y <= dut.active_height) &&
            dut.obj_cache_busy)
            visual_cache_blocked_swaps <= visual_cache_blocked_swaps + 1;
        visual_bg_plot_pixels <= visual_bg_plot_pixels +
            int'(dut.bg_plot_we[0]) + int'(dut.bg_plot_we[1]) +
            int'(dut.bg_plot_we[2]) + int'(dut.bg_plot_we[3]);
        visual_obj_plot_pixels <= visual_obj_plot_pixels +
            int'(dut.obj_plot_we[0]) + int'(dut.obj_plot_we[1]) +
            int'(dut.obj_plot_we[2]) + int'(dut.obj_plot_we[3]);
        if (dut.sdr_p2_ack) begin
            visual_gfx_acks <= visual_gfx_acks + 1;
            if (dut.sdr_p2_dout != 128'd0)
                visual_gfx_nonzero_acks <= visual_gfx_nonzero_acks + 1;
        end
        if (dut.background_renderer.fetch.done) begin
            visual_bg_fetch_done <= visual_bg_fetch_done + 1;
            if (dut.background_renderer.fetch.plane01 != 32'd0 ||
                dut.background_renderer.fetch.plane23 != 32'd0 ||
                dut.background_renderer.fetch.plane45 != 32'd0 ||
                dut.background_renderer.fetch.plane67 != 32'd0)
                visual_bg_nonzero_rows <= visual_bg_nonzero_rows + 1;
        end
        if (dut.sprite_renderer.fetch.done) begin
            visual_obj_fetch_done <= visual_obj_fetch_done + 1;
            if (dut.sprite_renderer.fetch.plane01 != 32'd0 ||
                dut.sprite_renderer.fetch.plane23 != 32'd0 ||
                dut.sprite_renderer.fetch.plane45 != 32'd0 ||
                dut.sprite_renderer.fetch.plane67 != 32'd0)
                visual_obj_nonzero_rows <= visual_obj_nonzero_rows + 1;
        end
        if (dut.background_renderer.pens != 128'd0)
            visual_bg_nonzero_pens <= visual_bg_nonzero_pens + 1;
        if (dut.sprite_renderer.pens != 128'd0)
            visual_obj_nonzero_pens <= visual_obj_nonzero_pens + 1;
        if (dut.m_req && dut.m_we && dut.m_ack && dut.sel_sprram) begin
            visual_total_spr_writes <= visual_total_spr_writes + 1;
            if (!visual_spr_write_d ||
                dut.a != visual_spr_write_addr_d ||
                dut.m_wdata != visual_spr_write_data_d ||
                dut.m_be != visual_spr_write_be_d) begin
                if ((dut.m_be[0] && dut.m_wdata[7:0] != 8'd0) ||
                    (dut.m_be[1] && dut.m_wdata[15:8] != 8'd0)) begin
                    visual_nonzero_spr_writes <= visual_nonzero_spr_writes + 1;
                    if (visual_spr_write_logs < 32) begin
                        $display("SPRWRITE frame=%0d pc=%08x addr=%06x data=%04x be=%02b",
                                 post_ve_frames, debug_pc, dut.a,
                                 dut.m_wdata, dut.m_be);
                        visual_spr_write_logs <= visual_spr_write_logs + 1;
                    end
                end
            end
            visual_spr_write_d <= 1'b1;
            visual_spr_write_addr_d <= dut.a;
            visual_spr_write_data_d <= dut.m_wdata;
            visual_spr_write_be_d <= dut.m_be;
        end else begin
            visual_spr_write_d <= 1'b0;
        end
        if (dut.sprite_renderer.cache_we &&
            (!visual_cache_slot_valid ||
             dut.sprite_renderer.cache_write_count != visual_cache_last_slot) &&
            visual_cache_store_logs < 64) begin
            $display("CACHELOG frame=%0d slot=%0d y=%0d..%0d tilemap=%0b desc=%032x g0=%04x g2=%04x g3=%04x l0=%04x l1=%04x l2=%04x l3=%04x",
                     post_ve_frames,
                     dut.sprite_renderer.cache_write_count,
                     dut.sprite_renderer.build_first_y,
                     dut.sprite_renderer.build_last_y,
                     dut.sprite_renderer.build_tilemap,
                     dut.sprite_renderer.cache_write_data,
                     dut.sprite_renderer.cache_write_data[111:96],
                     dut.sprite_renderer.cache_write_data[95:80],
                     dut.sprite_renderer.cache_write_data[79:64],
                     dut.sprite_renderer.cache_write_data[63:48],
                     dut.sprite_renderer.cache_write_data[47:32],
                     dut.sprite_renderer.cache_write_data[31:16],
                     dut.sprite_renderer.cache_write_data[15:0]);
            visual_cache_store_logs <= visual_cache_store_logs + 1;
            visual_cache_slot_valid <= 1'b1;
            visual_cache_last_slot <= dut.sprite_renderer.cache_write_count;
        end
        if (dut.m_req && dut.m_we && dut.m_ack && dut.sel_palette)
            visual_total_pal_writes <= visual_total_pal_writes + 1;
        if (dut.m_req && dut.m_we && dut.m_ack && dut.sel_scroll)
            visual_total_scroll_writes <= visual_total_scroll_writes + 1;
        if (dut.irq_requested != 8'd0) visual_irq_req_cycles <= visual_irq_req_cycles + 1;
        if (!dut.irq_n) visual_irq_active_cycles <= visual_irq_active_cycles + 1;
        if (dut.cpu_irq_ack) begin
            visual_irq_acks <= visual_irq_acks + 1;
            $display("SSV_VISUAL_IRQ_ACK frame=%0d pc=%08x vector=%02x requested=%02x enabled=%02x",
                     post_ve_frames, debug_pc, dut.irq_vector,
                     dut.irq_requested, dut.irq_enabled);
        end
        if (dut.m_req && dut.m_we && dut.m_ack && dut.sel_wram &&
            dut.a <= 24'h000001) begin
            visual_ram0_writes <= visual_ram0_writes + 1;
            $display("SSV_VISUAL_RAM0_WRITE frame=%0d pc=%08x data=%04x be=%02b requested=%02x enabled=%02x irq_n=%0b",
                     post_ve_frames, debug_pc, dut.m_wdata, dut.m_be,
                     dut.irq_requested, dut.irq_enabled, dut.irq_n);
        end
        if (dut.m_req && dut.m_we && dut.m_ack &&
            (dut.sel_irqvec || dut.sel_irqack || dut.sel_irqen)) begin
            visual_irq_reg_writes <= visual_irq_reg_writes + 1;
            $display("SSV_VISUAL_IRQ_REG_WRITE frame=%0d pc=%08x addr=%06x data=%04x be=%02b requested=%02x enabled=%02x irq_n=%0b",
                     post_ve_frames, debug_pc, dut.a, dut.m_wdata,
                     dut.m_be, dut.irq_requested, dut.irq_enabled,
                     dut.irq_n);
        end
        if ($test$plusargs("BOOT_TRACE") && ce_cpu && dut.cpu.st == 7'd3 &&
            visual_boot_trace_count < 2000 &&
            (((debug_pc >= 32'h00e02b00) && (debug_pc < 32'h00e02f80)) ||
             ((debug_pc >= 32'h00e03a00) && (debug_pc < 32'h00e04200)) ||
             ((debug_pc >= 32'h00e04800) && (debug_pc < 32'h00e04920)) ||
             ((debug_pc >= 32'h00fc0300) && (debug_pc < 32'h00fc0500)) ||
             ((debug_pc >= 32'h00fc1c00) && (debug_pc < 32'h00fc1d20))) &&
            debug_pc != visual_boot_trace_pc) begin
            $display("BOOT_TRACE cycle=%0d frame=%0d pc=%08x r0=%08x r1=%08x r2=%08x psw=%08x bus=%0b/%0b/%06x ack=%0b",
                     cycle_count, post_ve_frames, debug_pc,
                     dut.cpu.r[0], dut.cpu.r[1], dut.cpu.r[2], dut.cpu.psw,
                     dut.m_req, dut.m_we, dut.a, dut.m_ack);
            visual_boot_trace_count <= visual_boot_trace_count + 1;
            visual_boot_trace_pc <= debug_pc;
        end
        // Temporary per-cycle FSM probe (not PC-range-gated): every clk_sys
        // cycle once armed, so the full S_FILL/S_DECODE/... sequence between
        // two retirements is visible, not just the retirement cadence.
        // Used to locate the vasara2 attract idle-loop bottleneck. Remove
        // after use.
        if ($test$plusargs("CPU_LOOP_TRACE") &&
            cycle_count >= visual_loop_trace_start &&
            visual_loop_trace_count < 6000) begin
            $display("CPU_LOOP_TRACE cycle=%0d frame=%0d ce=%0b st=%0d pc=%08x fb_base=%08x fb_valid=%0d fb_wr=%0d pf_suppress=%0b pf_busy=%0b r0=%08x",
                     cycle_count, post_ve_frames, ce_cpu, dut.cpu.st, debug_pc,
                     dut.cpu.fb_base, dut.cpu.fb_valid, dut.cpu.fb_wr,
                     dut.cpu.pf_suppress, dut.cpu.pf_busy, dut.cpu.r[0]);
            visual_loop_trace_count <= visual_loop_trace_count + 1;
        end
        end
`endif
        // MAME init_ssv() and the shared RTL both power on with video enabled,
        // but deterministic scenarios and the protocol-v2 reference adapter
        // use the game's accepted $21000e bit-7 write as their common epoch.
        // Do not use the power-on latch level here or token zero would name
        // different software frames on the two sides.
        if (dut.lockout_write && dut.m_wdata[7])
            ve_seen <= 1'b1;
`ifdef SSV_VISUAL
        if (dut.lockout_write && visual_diag)
            $display("SSV_VISUAL_LOCKOUT_WRITE cycle=%0d pc=%08x data=%04x video_enable=%0b",
                     cycle_count, debug_pc, dut.m_wdata, dut.video_enable);
`endif

        // Multi-shot PPM: frames ppm_start + k*ppm_step for k in [0, ppm_count).
        // Single-shot: ppm_count==1 and ppm_path already set via +DUMP_PPM=.
        if (ppm_open_event) begin
            if (ppm_prefix.len() != 0)
                $sformat(ppm_path, "%s_f%0d.ppm", ppm_prefix, post_ve_frames);
            ppm_fd = $fopen(ppm_path, "wb");
            if (ppm_fd == 0)
                $fatal(1, "cannot open DUMP_PPM path %s", ppm_path);
            $fwrite(ppm_fd, "P6\n%0d %0d\n255\n", visual_width, visual_height);
            dump_ppm_open <= 1'b1;
            ppm_pixels <= 0;
            $display("DUMP_PPM capturing frame %0d -> %s",
                     post_ve_frames, ppm_path);
        end

        // MAME's raw screen frame advances through software-blanked frames as
        // well as visible frames.  Count the native active raster regardless
        // of video_enable; core_pixel is already black while the latch is
        // clear.  Gating this on debug_status[22] used to drop blank boot
        // frames and shift the lockstep token stream relative to MAME.
        if (ce_pixel && !hb && !vb) begin
`ifdef SSV_VISUAL
            if (visual_diag) begin
                if (dut.line_color != 15'd0)
                    visual_index_nonzero <= visual_index_nonzero + 1;
                if (dut.palette_video_rgb != 24'd0)
                    visual_palette_nonblack <= visual_palette_nonblack + 1;
                if (dut.video_active)
                    visual_active_pixels <= visual_active_pixels + 1;
            end
`endif
            active_pixels <= active_pixels + 1;
            if (rgb != 24'd0) begin
                nonblack_pixels <= nonblack_pixels + 1;
                frame_nonblack <= frame_nonblack + 1;
                if (ve_seen)
                    post_ve_nonblack <= post_ve_nonblack + 1;
            end
            // The color-cycling "SELECT PLAYER" header has a stable 836-pixel
            // silhouette in this box. Gameplay frames measure well below 700.
            if (require_play && post_ve_frames == 440 &&
                px_count >= (5 * 336) && px_count < (55 * 336) &&
                (px_count % 336) >= 40 && (px_count % 336) < 310 &&
                rgb != 24'd0)
                select_header_pixels <= select_header_pixels + 1;
            // Jungle gameplay is dominated by bright green foliage. Count a
            // conservative green-dominant population over the full frame.
            if (require_gameplay && post_ve_frames == 850 &&
                rgb[15:8] > rgb[23:16] && rgb[15:8] > rgb[7:0] &&
                rgb[15:8] >= 8'h40)
                gameplay_green_pixels <= gameplay_green_pixels + 1;
            // Accumulate every active pixel after VE (no delayed frame_active).
            if (ve_seen) begin
`ifdef SSV_VISUAL
                if (px_count < visual_expected_pixels) begin
                    visual_pixels[px_count] <= {8'hff, rgb};
                end
`endif
                if (post_ve_frames >= state_start_frame) begin
                    idx15 = {rgb[23:19], rgb[15:11], rgb[7:3]};
                    idx_crc <= ssv_crc32_byte(
                        ssv_crc32_byte(idx_crc, idx15[7:0]),
                        {1'b0, idx15[14:8]});
                    rgb_crc <= ssv_crc32_byte(
                        ssv_crc32_byte(
                            ssv_crc32_byte(rgb_crc, rgb[23:16]),
                            rgb[15:8]),
                        rgb[7:0]);
                end
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

        // Count every native raster boundary, including the pre-video software
        // boot epoch.  The external-clock host observes this only after the
        // completed posedge and saves with clk_sys low.
`ifdef SSV_VISUAL_EXTERNAL_CLOCK
        if (!vb_d && vb)
            native_frame_boundaries <= native_frame_boundaries + 1;
`endif

        // Emit + reset on entering vblank so the first active pixel is included.
        if (ve_seen && !vb_d && vb) begin
`ifdef SSV_VISUAL
            if (px_count == visual_expected_pixels) begin
                if (visual_diag)
                    $display("SSV_VISUAL_CORE frame=%0d pc=%08x ve=%0b active=%0dx%0d crtc_x=%04x/%04x min=%0d crtc_y=%04x/%04x min=%0d scr=%04x/%04x/%04x/%04x/%04x/%04x/%04x cache_count=%0d pool=%0d gfx_tx=%0d gfx_ack=%0d/%0d fetch_bg=%0d/%0d obj=%0d/%0d pens_bg=%0d obj=%0d line_nonzero=%0d palette_nonblack=%0d video_active=%0d line_start=%0d render_start=%0d bg_done=%0d obj_done=%0d bg_plot=%0d obj_plot=%0d cache_busy=%0d cache_ready=%0d cache_overflow=%0d cache_blocked=%0d writes_spr=%0d pal=%0d scroll=%0d irq_req=%02x irq_en=%02x irq_n=%0b vector=%02x req_cycles=%0d active_cycles=%0d acks=%0d ram0_writes=%0d irq_reg_writes=%0d",
                         post_ve_frames, debug_pc, dut.video_enable,
                         dut.active_width, dut.active_height,
                         dut.scroll[49], dut.scroll[50], dut.crtc_min_x,
                         dut.scroll[53], dut.scroll[54], dut.crtc_min_y,
                         dut.scroll[0], dut.scroll[1], dut.scroll[3],
                         dut.scroll[56], dut.scroll[58], dut.scroll[59],
                         dut.scroll[61], dut.sprite_renderer.cache_count,
                         dut.sprite_renderer.line_pool_alloc, p1_transactions,
                         visual_gfx_acks, visual_gfx_nonzero_acks,
                         visual_bg_fetch_done, visual_bg_nonzero_rows,
                         visual_obj_fetch_done, visual_obj_nonzero_rows,
                         visual_bg_nonzero_pens, visual_obj_nonzero_pens,
                         visual_index_nonzero, visual_palette_nonblack,
                         visual_active_pixels, visual_line_starts,
                         visual_renderer_starts, visual_bg_done, visual_obj_done,
                         visual_bg_plot_pixels, visual_obj_plot_pixels,
                         visual_cache_busy_cycles, visual_cache_ready_cycles,
                         visual_cache_overflows, visual_cache_blocked_swaps,
                         visual_total_spr_writes,
                         visual_total_pal_writes, visual_total_scroll_writes,
                         dut.irq_requested,
                         dut.irq_enabled, dut.irq_n, dut.irq_vector,
                         visual_irq_req_cycles, visual_irq_active_cycles,
                         visual_irq_acks, visual_ram0_writes,
                         visual_irq_reg_writes);
                if (visual_diag &&
                    (post_ve_frames == 22 || post_ve_frames == 28 ||
                     post_ve_frames == 30 || post_ve_frames == 33 ||
                     post_ve_frames == 40)) begin
                    $display("SSV_VISUAL_RAMSNAP frame=%0d p2_max_code=%05x unique_nonzero_spr_writes=%0d global=%04x/%04x/%04x/%04x/%04x/%04x/%04x/%04x local10000=%04x/%04x/%04x/%04x/%04x/%04x/%04x/%04x renderer_global=%04x/%04x/%04x/%04x renderer_local=%04x/%04x/%04x/%04x",
                             post_ve_frames, visual_p2_max_code,
                             visual_nonzero_spr_writes,
                             spr_peek(17'h00000), spr_peek(17'h00001),
                             spr_peek(17'h00002), spr_peek(17'h00003),
                             spr_peek(17'h00004), spr_peek(17'h00005),
                             spr_peek(17'h00006), spr_peek(17'h00007),
                             spr_peek(17'h10000), spr_peek(17'h10001),
                             spr_peek(17'h10002), spr_peek(17'h10003),
                             spr_peek(17'h10004), spr_peek(17'h10005),
                             spr_peek(17'h10006), spr_peek(17'h10007),
                             dut.sprite_renderer.global_w0,
                             dut.sprite_renderer.global_w1,
                             dut.sprite_renderer.global_w2,
                             dut.sprite_renderer.global_w3,
                             dut.sprite_renderer.local_w0,
                             dut.sprite_renderer.local_w1,
                             dut.sprite_renderer.local_w2,
                             dut.sprite_renderer.local_w3);
                end
                visual_status = ssv_visual_present(
                    visual_pixels, visual_width, visual_height,
                    post_ve_frames);
                if (visual_status != 0) begin
                    $display("SSV_VISUAL_EXIT frame=%0d", post_ve_frames);
                    visual_user_quit = 1'b1;
                end
            end else begin
                $display("SSV_VISUAL_INCOMPLETE_FRAME frame=%0d pixels=%0d",
                         post_ve_frames, px_count);
            end
`endif
            // Cheap per-frame state trace for real-ROM bring-up. The existing
            // DUMP_FRAME_DIAG path intentionally hashes thousands of RAM words
            // and is too expensive to use while a set is being triaged.
            if ($test$plusargs("LIGHT_DIAG") &&
                (post_ve_frames < 16 || (post_ve_frames % 30) == 0))
                $display("FRAME_STATS f=%0d pc=%08x r0=%08x psw=%08x ve=%0b nonblack=%0d scroll=%04x/%04x/%04x/%04x/%04x/%04x spr=%04x/%04x/%04x/%04x local=%04x/%04x/%04x/%04x/%04x/%04x/%04x/%04x ptrlocal=%04x/%04x/%04x/%04x/%04x/%04x/%04x/%04x pal=%04x/%04x/%04x/%04x cache=%0d state=%0d retire=%0d active=%0d irq=%0d cpu_st=%0d bus=%0b/%0b/%08x/%0b pf=%0b/%0b/%08x if=%0b/%0b fb=%08x/%0d/%0d video=%0b raster=%0d/%0d bg=%0d/%0b/%0b obj=%0d/%0b/%0b sprc=%0b/%0b",
                         post_ve_frames, debug_pc, dut.cpu.r[0], dut.cpu.psw,
                         debug_status[22], frame_nonblack,
                         dut.scroll[0], dut.scroll[1], dut.scroll[3],
                         dut.scroll[53], dut.scroll[56], dut.scroll[58],
                         spr_peek(0), spr_peek(1), spr_peek(2), spr_peek(3),
                         spr_peek(4), spr_peek(5), spr_peek(6), spr_peek(7),
                         spr_peek(8), spr_peek(9), spr_peek(10), spr_peek(11),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 0),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 1),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 2),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 3),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 4),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 5),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 6),
                         spr_peek(((spr_peek(5) & 16'h7fff) << 2) + 7),
                         dut.palette_ram.even_words.sim_peek(0),
                         dut.palette_ram.odd_words.sim_peek(0),
                         dut.palette_ram.even_words.sim_peek(1),
                         dut.palette_ram.odd_words.sim_peek(1),
                         dut.sprite_renderer.cache_count,
                         dut.sprite_renderer.state, retire_count,
                         cpu_activity_count, irq_entries_post_ve,
                         dut.cpu.st, dut.cpu.bus_req, dut.cpu.bus_we,
                         dut.cpu.bus_addr, dut.cpu.bus_ack,
                         dut.cpu.pf_busy, dut.cpu.fetch_ack, dut.cpu.pf_addr,
                         dut.cpu.if_req, dut.cpu.if_ack, dut.cpu.fb_base,
                         dut.cpu.fb_valid, dut.cpu.fb_wr,
                         dut.video_enable, dut.vcnt, dut.hcnt,
                         dut.background_renderer.state,
                         dut.background_renderer.busy,
                         dut.background_renderer.done,
                         dut.sprite_renderer.state,
                         dut.sprite_renderer.busy,
                         dut.sprite_renderer.done,
                         dut.sprite_renderer.cache_ready,
                         dut.sprite_renderer.cache_busy);
            // Attract proof is descriptor-agnostic but deliberately stronger
            // than a boot-logo check: require two seconds of uninterrupted
            // visible frames with CPU retirement activity and natural raster
            // timing. With no inputs applied by attract_idle, this is the
            // shared runtime gate for reaching a title's attract/demo loop.
            if (frame_nonblack > 1000)
                attract_visible_frames <= attract_visible_frames + 1;
            else
                attract_visible_frames <= 0;
            if (cpu_activity_count > attract_last_activity)
                attract_active_frames <= attract_active_frames + 1;
            else
                attract_active_frames <= 0;
            if (post_ve_frames >= 120 &&
                attract_visible_frames >= 119 &&
                attract_active_frames >= 119)
                attract_reached <= 1'b1;
            attract_last_retire <= retire_count;
            attract_last_activity <= cpu_activity_count;
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
                if (post_ve_frames >= state_start_frame) begin
                    $fdisplay(crc_fd, "FRAME %0d %08x %08x",
                              post_ve_frames,
                              ~idx_crc,
                              ~rgb_crc);
                    $fflush(crc_fd);
                    if (post_ve_frames == 0)
                        $display("FRAME0 px=%0d idx=%08x rgb=%08x",
                                 px_count, ~idx_crc, ~rgb_crc);
                end
                if ((dump_frame_diag && post_ve_frames < 4) ||
                    (state_fd != 0 && post_ve_frames >= state_start_frame)) begin
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
                    // scroll[0] is read-overlaid by vblank status in MAME.
                    // Hash only the 63 directly readable RAM words so live
                    // differential state compares the same storage surface.
                    for (diag_i = 1; diag_i < 64; diag_i = diag_i + 1) begin
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
                                    diag_i[14:0])),
                            8'd0);
                    end
                    $display("FRAMEDIAG f=%0d retire=%0d dretire=%0d irq_entries=%0d vb_pulses=%0d list512=%08x spr8k=%08x scroll63=%08x pal512=%08x scr0=%04x scr1=%04x scr3=%04x scr53=%04x scr56=%04x scr58=%04x scr59=%04x scr61=%04x cache_cnt=%0d pc=%08x",
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
                            "STATE %0d list512=%08x spr8k=%08x scroll63=%08x pal512=%08x",
                            post_ve_frames, ~list_crc, ~spr8k_crc,
                            ~scroll_crc, ~pal_crc);
                        $fflush(state_fd);
                    end
                    last_vb_retire = retire_count;
                end
                apply_inputs(post_ve_frames);
`ifdef SSV_VISUAL
                // ssv_visual_present caches the completed native surface.
                // Commit only after the CRC/state streams above are flushed;
                // this makes the token an exact evidence barrier rather than
                // an early notification from inside the renderer callback.
                visual_status = ssv_visual_frame_commit(
                    post_ve_frames, ~in_p1, ~in_p2, ~in_system, debug_pc,
                    ~list_crc, ~spr8k_crc, ~scroll_crc, ~pal_crc,
                    sim_cfg.has_st010, dut.st010.dbg_pc,
                    dut.st010.dbg_a, dut.st010.dbg_b,
                    dut.st010.dbg_dp, dut.st010.dbg_dr,
                    dut.st010.dbg_k, dut.st010.dbg_l,
                    dut.st010.dbg_m, dut.st010.dbg_n);
                if (visual_status != 0) begin
                    $display("SSV_VISUAL_LOCKSTEP_EXIT frame=%0d",
                             post_ve_frames);
                    visual_user_quit = 1'b1;
                end
`endif
                post_ve_frames <= post_ve_frames + 1;
                frame_idx <= frame_idx + 1;
            end
            idx_crc <= 32'hffffffff;
            rgb_crc <= 32'hffffffff;
            px_count <= 0;
            select_header_pixels <= 0;
            frame_nonblack <= 0;
            gameplay_green_pixels <= 0;
`ifdef SSV_VISUAL
            visual_index_nonzero <= 0;
            visual_palette_nonblack <= 0;
            visual_active_pixels <= 0;
            visual_line_starts <= 0;
            visual_renderer_starts <= 0;
            visual_bg_done <= 0;
            visual_obj_done <= 0;
            visual_cache_busy_cycles <= 0;
            visual_cache_ready_cycles <= 0;
            visual_cache_overflows <= 0;
            visual_cache_blocked_swaps <= 0;
            visual_irq_req_cycles <= 0;
            visual_irq_active_cycles <= 0;
            visual_irq_acks <= 0;
            visual_ram0_writes <= 0;
            visual_irq_reg_writes <= 0;
            visual_bg_plot_pixels <= 0;
            visual_obj_plot_pixels <= 0;
            visual_gfx_acks <= 0;
            visual_gfx_nonzero_acks <= 0;
            visual_bg_fetch_done <= 0;
            visual_obj_fetch_done <= 0;
            visual_bg_nonzero_rows <= 0;
            visual_obj_nonzero_rows <= 0;
            visual_bg_nonzero_pens <= 0;
            visual_obj_nonzero_pens <= 0;
`endif
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
                for (diag_i = 1; diag_i < 64; diag_i = diag_i + 1) begin
                    scroll_crc = ssv_crc32_byte(
                        ssv_crc32_byte(scroll_crc,
                            dut.scroll[diag_i][7:0]),
                        dut.scroll[diag_i][15:8]);
                end
                $display("CACHESNAP retire=%0d next_f=%0d list512=%08x spr8k=%08x scroll63=%08x scr0=%04x scr1=%04x scr3=%04x",
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
            if (dump_late_line && !late_line_dumped) begin
                // The line list stores a low descriptor page plus seven low
                // bits. Reconstruct the full descriptor index exactly as the
                // renderer does, then classify the first late line without
                // changing the synthesised or normal simulation path.
                late_line_dumped <= 1'b1;
                late_count = int'(dut.sprite_renderer.render_line_count);
                late_base = int'(dut.sprite_renderer.line_base_q);
                late_page = int'(dut.sprite_renderer.line_page_q);
                late_nonzero_local = 0;
                late_tile_candidates = 0;
                for (late_i = 0; late_i < 16; late_i = late_i + 1)
                    late_g0[late_i] = 0;
                $display("LATE_LINE f=%0d y=%0d state=%0d slots=%0d/%0d base=%0d page_meta=%h",
                         post_ve_frames, dut.renderer_target_y,
                         dut.sprite_renderer.state,
                         dut.sprite_renderer.render_line_slot, late_count,
                         late_base, late_page);
                for (late_i = 0; late_i < late_count; late_i = late_i + 1) begin
                    late_entry = {
                        dut.sprite_renderer.line_page_for_slot(
                            dut.sprite_renderer.render_line_pages, late_i),
                        dut.sprite_renderer.line_entries[late_base + late_i]
                    };
                    late_desc = dut.sprite_renderer.descriptor_cache[late_entry];
                    // Keep the census compact: this is the high nibble of
                    // global word 0, not the full six-bit tilemap selector.
                    late_g0[late_desc[111:108]] =
                        late_g0[late_desc[111:108]] + 1;
                    if (late_desc[63:48] != 16'd0)
                        late_nonzero_local = late_nonzero_local + 1;
                    if ((late_desc[63:48] <= 16'd7) &&
                        (late_desc[47:32] == 16'd0))
                        late_tile_candidates = late_tile_candidates + 1;
                    if (late_i < 32)
                        $display("LATE_DESC i=%0d idx=%0d g0=%04x g2=%04x g3=%04x l0=%04x l1=%04x l2=%04x l3=%04x",
                                 late_i, late_entry,
                                 late_desc[111:96], late_desc[95:80],
                                 late_desc[79:64], late_desc[63:48],
                                 late_desc[47:32], late_desc[31:16],
                                 late_desc[15:0]);
                end
                $display("LATE_CLASS nonzero_local=%0d tile_candidates=%0d g0=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                         late_nonzero_local, late_tile_candidates,
                         late_g0[0], late_g0[1], late_g0[2], late_g0[3],
                         late_g0[4], late_g0[5], late_g0[6], late_g0[7],
                         late_g0[8], late_g0[9], late_g0[10], late_g0[11],
                         late_g0[12], late_g0[13], late_g0[14], late_g0[15]);
            end
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
            $display("FIRST_CACHE_OVERFLOW f=%0d state=%0d cache=%0d writes=%0d bucket_y=%0d line_count=%0d pool_alloc=%0d",
                     post_ve_frames, dut.sprite_renderer.state,
                     dut.sprite_renderer.cache_count,
                     dut.sprite_renderer.cache_write_count,
                     dut.sprite_renderer.bucket_y,
                     dut.sprite_renderer.line_count_q,
                     dut.sprite_renderer.line_pool_alloc);
            overflow_tile_desc = 0;
            overflow_sprite_desc = 0;
            for (overflow_i = 0; overflow_i < 8; overflow_i = overflow_i + 1)
                overflow_tile_groups[overflow_i] = 0;
            for (overflow_i = 0;
                 overflow_i < dut.sprite_renderer.line_count_q;
                 overflow_i = overflow_i + 1) begin
                overflow_entry = {
                    dut.sprite_renderer.line_page_for_slot(
                        dut.sprite_renderer.line_page_starts[
                            dut.sprite_renderer.bucket_y],
                        overflow_i),
                    dut.sprite_renderer.line_entries[
                        dut.sprite_renderer.line_bases[
                            dut.sprite_renderer.bucket_y] + overflow_i]
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
            // Count the current renderer states by name-equivalent constants;
            // stale hard-coded values here previously mislabeled descriptor
            // evaluation as graphics fetch and hid the Vasara 2 failure mode.
            if (dut.sprite_renderer.state == ST_FETCH_WAIT)
                obj_rom_wait_cycles <= obj_rom_wait_cycles + 1;
            if (dut.sprite_renderer.state == ST_RENDER_PREP)
                obj_line_descriptors <= obj_line_descriptors + 1;
            if (dut.sprite_renderer.state == ST_FETCH_START) begin
                obj_line_fetches <= obj_line_fetches + 1;
                if (dut.sprite_renderer.render_tilemap)
                    obj_line_tilemap_fetches <= obj_line_tilemap_fetches + 1;
            end
            if (dut.sprite_renderer.state == ST_PLOT)
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

// ---------------------------------------------------------------------
// V60 per-instruction cycle-cost profiler -- the actual monitor.
// dbg_retire pulses for exactly one clk_sys cycle when the CPU's decode
// stage begins a new instruction (rtl/cpu/v60/s32_v60.sv: "Pulses one
// clk_sys cycle whenever an instruction retires into decode"). At that
// same edge, dbg_pc/cur_op (read here BEFORE this edge's non-blocking
// update lands, per standard SV NBA scheduling) still hold the PC/opcode
// of the instruction that is finishing, not the one starting -- so this
// correctly tags the OUTGOING instruction with the elapsed clk_sys ticks
// since its own retirement pulse, i.e. its total fetch+decode+EA+
// execute+writeback cost. Purely observational: no RTL signal is written,
// no synthesizable behavior is touched.
always @(posedge clk_sys) begin
    if (v60_prof_enable && !rst && dut.cpu.dbg_retire) begin
        v60_prof_delta  = cycle_count - v60_prof_last_tick;
        v60_prof_op_tmp = dut.cpu.cur_op;
        if (v60_prof_started &&
            post_ve_frames >= v60_prof_lo_frame &&
            post_ve_frames <= v60_prof_hi_frame) begin
            v60_prof_op_count[v60_prof_op_tmp]  <= v60_prof_op_count[v60_prof_op_tmp] + 1;
            v60_prof_op_cycles[v60_prof_op_tmp] <= v60_prof_op_cycles[v60_prof_op_tmp] + v60_prof_delta;
            if (v60_prof_delta < v60_prof_op_min[v60_prof_op_tmp])
                v60_prof_op_min[v60_prof_op_tmp] <= v60_prof_delta;
            if (v60_prof_delta > v60_prof_op_max[v60_prof_op_tmp])
                v60_prof_op_max[v60_prof_op_tmp] <= v60_prof_delta;
            v60_prof_total_instrs <= v60_prof_total_instrs + 1;
        end
        v60_prof_last_tick <= cycle_count;
        v60_prof_started   <= 1'b1;
    end
end

always @(posedge clk_sys) begin
    if (v60_stateprof_enable && !rst && dut.cpu.cur_op == v60_stateprof_target_op) begin
        v60_stateprof_cycles[dut.cpu.st] <= v60_stateprof_cycles[dut.cpu.st] + 1;
        if (!v60_stateprof_prev_valid || dut.cpu.st != v60_stateprof_prev_st)
            v60_stateprof_entries[dut.cpu.st] <= v60_stateprof_entries[dut.cpu.st] + 1;
        v60_stateprof_prev_st    <= dut.cpu.st;
        v60_stateprof_prev_valid <= 1'b1;
    end else begin
        v60_stateprof_prev_valid <= 1'b0;
    end
end

always @(posedge clk_sys) begin
    if (v60_memtrace_enable && !rst && v60_memtrace_printed < v60_memtrace_max) begin
        // S_OP2_LD=11, S_WB_MEM=14 per rtl/cpu/v60/s32_v60.sv's st_t enum order
        if (dut.cpu.cur_op == v60_memtrace_target_op &&
            (dut.cpu.st == 7'd14 || dut.cpu.st == 7'd11)) begin
            if (!v60_memtrace_prev_valid || dut.cpu.st != v60_memtrace_prev_st)
                v60_memtrace_entry_tick <= cycle_count;
            v60_memtrace_prev_st    <= dut.cpu.st;
            v60_memtrace_prev_valid <= 1'b1;
        end
        else begin
            if (v60_memtrace_prev_valid) begin
                $display("V60_MEM_TRACE op=%02x state=%0d addr=%06x sel_wram=%0b sel_sprram=%0b sel_rom=%0b sel_palette=%0b wait_clk_sys=%0d",
                          v60_memtrace_target_op, v60_memtrace_prev_st, dut.a,
                          dut.sel_wram, dut.sel_sprram, dut.sel_rom, dut.sel_palette,
                          cycle_count - v60_memtrace_entry_tick);
                v60_memtrace_printed <= v60_memtrace_printed + 1;
            end
            v60_memtrace_prev_valid <= 1'b0;
        end
    end
end

// Keep the terminal proof gates in one place for both the legacy timed driver
// and the externally clocked, savable visual profile.
task automatic finalize_run;
begin
    run_done = 1'b1;
    if (v60_prof_enable) begin
        integer v60_prof_buckets;
        v60_prof_buckets = 0;
        v60_prof_fd = $fopen(v60_prof_path, "w");
        if (v60_prof_fd == 0)
            $fatal(1, "cannot open V60_CYCLE_PROFILE_OUT path %s", v60_prof_path);
        $fwrite(v60_prof_fd, "opcode_hex,count,total_clk_sys,min_clk_sys,max_clk_sys,avg_clk_sys\n");
        for (i = 0; i < 256; i = i + 1) begin
            if (v60_prof_op_count[i] != 0) begin
                $fwrite(v60_prof_fd, "%02x,%0d,%0d,%0d,%0d,%0f\n",
                        i, v60_prof_op_count[i], v60_prof_op_cycles[i],
                        v60_prof_op_min[i], v60_prof_op_max[i],
                        real'(v60_prof_op_cycles[i]) / real'(v60_prof_op_count[i]));
                v60_prof_buckets = v60_prof_buckets + 1;
            end
        end
        $fclose(v60_prof_fd);
        $display("V60_CYCLE_PROFILE wrote %0d opcode buckets, %0d instructions, window frames [%0d,%0d] to %s",
                  v60_prof_buckets, v60_prof_total_instrs,
                  v60_prof_lo_frame, v60_prof_hi_frame, v60_prof_path);
    end
    if (v60_stateprof_enable) begin
        integer v60_stateprof_j;
        v60_stateprof_fd = $fopen(v60_stateprof_path, "w");
        if (v60_stateprof_fd == 0)
            $fatal(1, "cannot open V60_STATE_PROFILE_OUT path %s", v60_stateprof_path);
        $fwrite(v60_stateprof_fd, "state_id,cycles,entries\n");
        for (v60_stateprof_j = 0; v60_stateprof_j < 128; v60_stateprof_j = v60_stateprof_j + 1) begin
            if (v60_stateprof_cycles[v60_stateprof_j] != 0)
                $fwrite(v60_stateprof_fd, "%0d,%0d,%0d\n", v60_stateprof_j,
                        v60_stateprof_cycles[v60_stateprof_j], v60_stateprof_entries[v60_stateprof_j]);
        end
        $fclose(v60_stateprof_fd);
        $display("V60_STATE_PROFILE op=%02x wrote to %s",
                  v60_stateprof_target_op, v60_stateprof_path);
    end
    if (crc_fd != 0) begin
        $fclose(crc_fd);
        crc_fd = 0;
    end
    if (state_fd != 0) begin
        $fclose(state_fd);
        state_fd = 0;
    end

`ifdef SSV_VISUAL
    if (visual_user_quit) begin
        $display("SSV_VISUAL_SAMPLE_SUMMARY fetches=%0d nonzero_fetches=%0d",
                 visual_sample_fetches, visual_nonzero_sample_fetches);
        $display("SSV_VISUAL_RUNTIME_EXIT 0");
        $finish;
    end else begin
`endif
    if (!ve_seen) begin
        $display("SDR_CENSUS p0 req=%0d ack=%0d | p2 req=%0d ack=%0d | wr req=%0d ack=%0d | ready=%0b",
                 dbg_p0_req_cnt, dbg_p0_ack_cnt,
                 dbg_p2_req_cnt, dbg_p2_ack_cnt,
                 dbg_wr_req_cnt, dbg_wr_ack_cnt, sdram_ready);
        $fatal(1, "software video-enable write never accepted pc=%08x", debug_pc);
    end
    if (post_ve_frames < max_frames)
        $display("WARNING CYCLE_BUDGET_TRUNCATED frames=%0d requested=%0d cycles=%0d -- raise +CYCLES to reach the requested frame",
                 post_ve_frames, max_frames, max_cycles);
    if (post_ve_frames < soak_frames)
        $fatal(1, "soak frames=%0d need=%0d", post_ve_frames, soak_frames);
    if (require_attract && !attract_reached)
        $fatal(1, "attract milestone not reached for GAME_ID=%0d", selected_game_id);
    if (require_verilator_screenshot &&
        (!dump_ppm_en || ppm_shots_done < 1))
        $fatal(1, "Verilator attract screenshot was not emitted for GAME_ID=%0d",
               selected_game_id);
    if (!ignore_overrun && (bg_overruns != 0 || obj_overruns != 0))
        $fatal(1, "renderer overrun bg=%0d obj=%0d", bg_overruns, obj_overruns);
    if (!ignore_nonblack && post_ve_nonblack < 1000)
        $fatal(1, "post-VE nonblack too low: %0d", post_ve_nonblack);
    if (!ignore_overrun && debug_status[16])
        $fatal(1, "renderer_overrun sticky set");
    if (watchdog_soft_resets != 0)
        $fatal(1, "unexpected watchdog soft resets=%0d", watchdog_soft_resets);
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
    $display("GFX_TRANSACTIONS=%0d", p1_transactions);
    $display("EXTRA_PORT $500008 reads=%0d", extra_reads);
    $display("SIM_LINE_DEM_TOTAL=%0d SIM_LINE_DEM_MAX=%0d POOL_ALLOC=%0d",
             dut.sprite_renderer.sim_line_demand_total,
             dut.sprite_renderer.sim_line_demand_max,
             dut.sprite_renderer.line_pool_alloc);
    $display("CACHE_PEAK=%0d of %0d entries (frame %0d)",
             cache_peak, dut.sprite_renderer.CACHE_ENTRIES, cache_peak_frame);
    $display("SIM_DUPLICATE_SKIPS=%0d",
             dut.sprite_renderer.sim_duplicate_skips);
    if (bg_ack_while_obj_owns != 0)
        $fatal(1, "background renderer latched %0d acks it did not own",
               bg_ack_while_obj_owns);
    if (dump_renderer_budget) begin
        $display("=== PHASE0 C3 line occupancy (LINE_SLOTS=%0d) ===",
                 dut.sprite_renderer.LINE_SLOTS);
        $display("C3_OCC max=%0d frame=%0d at_cap=%0d lines=%0d",
                 occ_max, occ_max_frame, occ_at_cap, occ_lines_sampled);
        for (diag_i = 0; diag_i < OCC_BINS; diag_i = diag_i + 1)
            if (occ_hist[diag_i] != 0)
                $display("C3_HIST %0d %0d", diag_i, occ_hist[diag_i]);
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
`ifndef SSV_VISUAL_BEHAVIORAL_ONLY
        if (use_real_sdram)
            u_sdram.controller.sdram_dump_stats("frame_crc");
`endif
    end

`ifdef SSV_VISUAL
    $display("SSV_VISUAL_SAMPLE_SUMMARY fetches=%0d nonzero_fetches=%0d",
             visual_sample_fetches, visual_nonzero_sample_fetches);
`endif
    $display("PASS tb_ssv_frame_crc game_id=%0d scenario=%s frames=%0d attract=%0b nonblack=%0d pc=%08x crc=%s overruns bg=%0d obj=%0d watchdog_resets=%0d max_line_entries=%0d",
             selected_game_id, scenario, post_ve_frames, attract_reached,
             post_ve_nonblack, debug_pc, crc_path,
             bg_overruns, obj_overruns, watchdog_soft_resets,
             obj_max_line_entries);
    $finish;
`ifdef SSV_VISUAL
    end
`endif
end
endtask

initial begin
    selected_game_id = 0;
    if (!$value$plusargs("GAME_ID=%d", selected_game_id))
        selected_game_id = 0;
    if (selected_game_id < 0 || selected_game_id > 9)
        $fatal(1, "GAME_ID must be in the universal profile range 0..9");
    sim_cfg = cfg_for_game(4'(selected_game_id));
    // visual_width/height feed the +DUMP_PPM header, which is used outside
    // SSV_VISUAL too (e.g. the plain run_gameplay_sims.sh-style build) --
    // previously only assigned under `ifdef SSV_VISUAL below, leaving a
    // plain-build PPM dump with a degenerate "P6\n0 0\n255\n" header (found
    // while gathering pixel-diff evidence for a real divergence).
    visual_width = int'(active_width_cfg(sim_cfg));
    visual_height = int'(active_height_cfg(sim_cfg));
`ifdef SSV_VISUAL
    visual_diag = $test$plusargs("VISUAL_DIAG");
    visual_expected_pixels = visual_width * visual_height;
    if (visual_width < 1 || visual_width > 352 ||
        visual_height < 1 || visual_height > 240)
        $fatal(1, "SSV visual dimensions out of range: %0dx%0d",
               visual_width, visual_height);
`endif
    prog_bytes = int'(stream_prog_size_cfg(sim_cfg));
    gfx_stream_bytes = int'(stream_gfx_size_cfg(sim_cfg));
    gfx_quarter_bytes = int'(gfx_quarter_bytes_cfg(sim_cfg));
    sample_bytes = int'(stream_samples_size_cfg(sim_cfg));
    if (!$value$plusargs("DSW1=%h", dsw1_value))
        dsw1_value = 16'hffff;
    if (!$value$plusargs("DSW2=%h", dsw2_value))
        dsw2_value = 16'hfffd;
    $display("UNIVERSAL_GAME id=%0d prog=%0d gfx_stream=%0d gfx_quarter=%0d samples=%0d quarters=%0d st010=%0b",
             selected_game_id, prog_bytes, gfx_stream_bytes,
             gfx_quarter_bytes, sample_bytes, sim_cfg.gfx_quarters,
             sim_cfg.has_st010);
    if (!$value$plusargs("MAINROM=%s", main_path))
        main_path = "sim_output/rom/maincpu.bin";
    if (!$value$plusargs("SPRROM=%s", sprite_path))
        sprite_path = "sim_output/rom/sprites.bin";
    if (!$value$plusargs("FRAME_CRC=%s", crc_path))
        crc_path = "sim_output/diff/rtl_attract_idle_frames.crc";
    state_fd = 0;
    if (!$value$plusargs("STATE_START_FRAME=%d", state_start_frame))
        state_start_frame = 0;
    if (!$value$plusargs("CPU_LOOP_TRACE_AT=%d", visual_loop_trace_start))
        visual_loop_trace_start = 0;
    if ($value$plusargs("STATE_CRC=%s", state_path)) begin
        state_fd = $fopen(state_path, "w");
        if (state_fd == 0)
            $fatal(1, "cannot open STATE_CRC path %s", state_path);
    end
    if (!$value$plusargs("SCENARIO=%s", scenario))
        scenario = "attract_idle";
    if (!$value$plusargs("COIN_FRAME_LO=%d", coin_frame_lo))
        coin_frame_lo = 30;
    if (!$value$plusargs("COIN_FRAME_HI=%d", coin_frame_hi))
        coin_frame_hi = 34;
    if (!$value$plusargs("START_FRAME_LO=%d", start_frame_lo))
        start_frame_lo = 165;
    if (!$value$plusargs("START_FRAME_HI=%d", start_frame_hi))
        start_frame_hi = 170;
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
    v60_prof_enable = $test$plusargs("V60_CYCLE_PROFILE");
    if (!$value$plusargs("V60_CYCLE_PROFILE_LO=%d", v60_prof_lo_frame))
        v60_prof_lo_frame = 0;
    if (!$value$plusargs("V60_CYCLE_PROFILE_HI=%d", v60_prof_hi_frame))
        v60_prof_hi_frame = 999999;
    if (!$value$plusargs("V60_CYCLE_PROFILE_OUT=%s", v60_prof_path))
        v60_prof_path = "sim_output/diff/v60_cycle_profile.csv";
    v60_prof_started = 1'b0;
    v60_prof_total_instrs = 0;
    for (i = 0; i < 256; i = i + 1) begin
        v60_prof_op_count[i]  = 0;
        v60_prof_op_cycles[i] = 0;
        v60_prof_op_min[i]    = 64'hFFFF_FFFF_FFFF_FFFF;
        v60_prof_op_max[i]    = 0;
    end
    v60_stateprof_enable = $value$plusargs("V60_STATE_PROFILE_OP=%h", v60_stateprof_target_op);
    if (!$value$plusargs("V60_STATE_PROFILE_OUT=%s", v60_stateprof_path))
        v60_stateprof_path = "sim_output/diff/v60_state_profile.csv";
    v60_stateprof_prev_valid = 1'b0;
    for (i = 0; i < 128; i = i + 1) begin
        v60_stateprof_cycles[i]  = 0;
        v60_stateprof_entries[i] = 0;
    end
    v60_memtrace_enable = $value$plusargs("V60_MEM_TRACE_OP=%h", v60_memtrace_target_op);
    if (!$value$plusargs("V60_MEM_TRACE_MAX=%d", v60_memtrace_max))
        v60_memtrace_max = 20;
    v60_memtrace_printed    = 0;
    v60_memtrace_prev_valid = 1'b0;
    dump_pixels = $test$plusargs("DUMP_PIXELS");
    dump_frame_diag = $test$plusargs("DUMP_FRAME_DIAG");
    dump_renderer_budget = $test$plusargs("DUMP_RENDERER_BUDGET");
    dump_late_line = $test$plusargs("DUMP_LATE_LINE");
    stop_on_renderer_overrun =
        $test$plusargs("STOP_ON_RENDERER_OVERRUN");
    ignore_overrun = $test$plusargs("IGNORE_OVERRUN");
    ignore_nonblack = $test$plusargs("IGNORE_NONBLACK");
`ifdef SSV_VISUAL
`endif
`ifdef SSV_VISUAL_BEHAVIORAL_ONLY
    if ($test$plusargs("REAL_SDRAM"))
        $fatal(1, "+REAL_SDRAM is unavailable in the behavioural-only visual build");
    use_real_sdram = 1'b0;
`else
    use_real_sdram = $test$plusargs("REAL_SDRAM");
`endif
    if (!$value$plusargs("SMPROM=%s", sample_path))
        sample_path = "sim_output/rom/samples.bin";
    sample_fd = $fopen(sample_path, "rb");
    sample_count = 0;
`ifdef SSV_VISUAL
    if (sample_fd == 0)
        $fatal(1, "cannot open visual sample ROM: %s", sample_path);
    sample_count = $fread(sample_rom, sample_fd);
    $fclose(sample_fd);
    if (sample_count != sample_bytes)
        $fatal(1, "short visual sample ROM read %0d/%0d",
               sample_count, sample_bytes);
    if (sample_word_be(8'hcd, 8'hab) !== 16'hcdab)
        $fatal(1, "visual sample endian proof failed");
    $display("SSV_VISUAL_SAMPLE_ENDIAN_PROOF bytes=cd,ab word=%04x",
             sample_word_be(8'hcd, 8'hab));
    $display("SSV_VISUAL_SAMPLE_ROM_LOADED path=%s bytes=%0d first_word=%04x last_word=%04x",
             sample_path, sample_count,
             sample_word_be(sample_rom[0], sample_rom[1]),
             sample_word_be(sample_rom[sample_count-2],
                            sample_rom[sample_count-1]));
`endif
    st010_count = 0;
    if (sim_cfg.has_st010) begin
        if (!$value$plusargs("ST010ROM=%s", st010_path))
            st010_path = "sim_output/rom/st010.bin";
        st010_fd = $fopen(st010_path, "rb");
        if (st010_fd == 0)
            $fatal(1, "cannot open ST010 ROM image: %s", st010_path);
        st010_count = $fread(st010_rom, st010_fd);
        $fclose(st010_fd);
        if (st010_count != STREAM_ST010_SIZE)
            $fatal(1, "short ST010 ROM read %0d/%0d",
                   st010_count, STREAM_ST010_SIZE);
`ifdef SSV_VISUAL
        $display("SSV_VISUAL_ST010_ROM_LOADED path=%s bytes=%0d first=%02x%02x%02x%02x",
                 st010_path, st010_count, st010_rom[0], st010_rom[1],
                 st010_rom[2], st010_rom[3]);
`endif
    end
    require_play = $test$plusargs("REQUIRE_PLAY");
    require_gameplay = $test$plusargs("REQUIRE_GAMEPLAY");
    require_attract = $test$plusargs("REQUIRE_ATTRACT");
    require_verilator_screenshot =
        $test$plusargs("REQUIRE_VERILATOR_SCREENSHOT");
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
`ifdef SSV_VISUAL_EXTERNAL_CLOCK
        // The generated model represents force/release state as VlForceVec,
        // which is not
        // serializable. Checkpoint runs use the board's natural IRQ schedule;
        // the legacy timing diagnostic retains forced differential IRQs.
        $fatal(1, "DIFF_IRQ_SCHEDULE is unavailable in checkpoint builds");
`else
        irq_schedule_fd = $fopen(irq_schedule_path, "r");
        if (irq_schedule_fd == 0)
            $fatal(1, "cannot open IRQ schedule: %s", irq_schedule_path);
        irq_scan_result = $fscanf(
            irq_schedule_fd, "%d\n", next_irq_retire);
        if (irq_scan_result != 1)
            $fatal(1, "empty IRQ schedule: %s", irq_schedule_path);
        diff_irq_enabled = 1'b1;
        force dut.vblank_pulse = diff_vblank_pulse;
`endif
    end

    main_fd = $fopen(main_path, "rb");
    sprite_fd = $fopen(sprite_path, "rb");
    if (main_fd == 0 || sprite_fd == 0)
        $fatal(1, "cannot open ROM images");
    main_count = $fread(main_rom, main_fd);
    sprite_count = $fread(sprite_rom, sprite_fd);
    $fclose(main_fd);
    $fclose(sprite_fd);
    if (main_count != prog_bytes || sprite_count != gfx_stream_bytes)
        $fatal(1, "short ROM read main=%0d/%0d sprite=%0d/%0d",
               main_count, prog_bytes, sprite_count, gfx_stream_bytes);

    // With the real controller the ROM loader is bypassed exactly as it is for
    // the behavioural model, so the chip has to be preloaded with the same
    // image the behavioural model synthesises on the fly. The layouts must
    // agree bit for bit, otherwise the two runs would differ for reasons that
    // have nothing to do with memory timing -- and the whole point of this
    // harness is that frame CRCs stay identical while only timing changes.
`ifndef SSV_VISUAL_BEHAVIORAL_ONLY
    if (use_real_sdram) begin
        $display("REAL_SDRAM preloading chip image");
        // V60 program at SDR_MAINCPU_BASE = 0.
        for (i = 0; i < prog_bytes / 2; i = i + 1)
            u_sdram.chip.preload_word(i[25:0],
                {main_rom[i*2+1], main_rom[i*2]});
        // Graphics at SDR_GFX_BASE. One aligned 16-byte record per 16-pixel
        // tile row: Q0 | Q1 | Q2 | Q3. This mirrors the
        // behavioural p2 model above and ssv_pkg::gfx_plane_addr; a divergence
        // between the three is exactly the fake-bug generator the design doc
        // warns about, so the arithmetic below is deliberately the same shape.
        //
        // The raw image is the MRA graphics stream, including erased holes.
        for (i = 0; i < (int'(sim_cfg.gfx_mb) * 1048576) / 2; i = i + 1) begin : preload_packed
            automatic integer byte_off  = i * 2;
            automatic integer pk_code   = byte_off >> 7;
            automatic integer pk_row    = (byte_off >> 4) & 7;
            automatic integer q0        = pk_code * 32 + pk_row * 4;
            automatic integer in_rec    = byte_off & 15;
            automatic integer quarter   = in_rec >> 2;
            automatic integer src       = quarter * gfx_quarter_bytes + q0 + (in_rec & 3);
            u_sdram.chip.preload_word(((SDR_GFX_BASE >> 1) + i),
                (quarter >= sim_cfg.gfx_quarters) ? 16'h0000
                               : {sprite_rom[src+1], sprite_rom[src]});
        end
        // ES5506 samples.
        if (sample_count == 0 && sample_fd != 0) begin
            sample_count = $fread(sample_rom, sample_fd);
            $fclose(sample_fd);
            if (sample_count != sample_bytes)
                $fatal(1, "short sample ROM read %0d/%0d", sample_count, sample_bytes);
        end
        if (sample_count == sample_bytes) begin
            for (i = 0; i < sample_bytes / 2; i = i + 1)
                u_sdram.chip.preload_word(((SDR_SAMPLES_BASE >> 1) + i),
                    sample_word_be(sample_rom[i*2], sample_rom[i*2+1]));
            $display("REAL_SDRAM samples preloaded");
        end
        else
            $display("REAL_SDRAM no sample image (+SMPROM=) - audio path unexercised");
        $display("REAL_SDRAM preload done");
    end
`endif

    crc_fd = $fopen(crc_path, "w");
    if (crc_fd == 0)
        $fatal(1, "cannot open FRAME_CRC path %s", crc_path);

    for (i = 0; i < 229376; i = i + 1)
        external_ram[i] = 16'd0;

    apply_inputs(0);
`ifdef SSV_VISUAL
    visual_user_quit = 1'b0;
    ssv_visual_set_geometry(visual_width, visual_height);
    visual_status = ssv_visual_init();
    if (visual_status != 0)
        $fatal(1, "SSV visual SDL initialization failed");
`endif
    rst = 1'b1;
    run_done = 1'b0;
`ifdef SSV_VISUAL_EXTERNAL_CLOCK
    cycle_count = 0;
    external_reset_edges = 0;
    external_setup_complete = 1'b1;
`else
    repeat (8) @(posedge clk_sys);
    rst = 1'b0;

    for (cycle_count = 0; cycle_count < max_cycles; cycle_count = cycle_count + 1) begin
        @(posedge clk_sys);
`ifdef SSV_VISUAL
        // Keep the native window responsive during real-ROM boot, before the
        // first complete video frame is available to present.
        if ((cycle_count & 64'h0000_0000_0000_ffff) == 0 &&
            ssv_visual_poll() != 0) begin
            $display("SSV_VISUAL_EXIT during boot/run cycle=%0d", cycle_count);
            visual_user_quit = 1'b1;
            break;
        end
        if (visual_user_quit)
            break;
        if (!ve_seen && cycle_count[23:0] == 24'd0)
            $display("SSV_VISUAL_BOOT_PROGRESS cycle=%0d pc=%08x cpu_st=%0d bus=%0b/%0b/%06x ext=%0b/%0b wdog=%0d st010_pc=%04x",
                     cycle_count, debug_pc, dut.cpu.st, dut.m_req, dut.m_we,
                     dut.a, dut.ext_busy, dut.sdr_wr_req,
                     watchdog_soft_resets, dut.st010.dbg_pc);
`endif
        if (stuck > 500000)
            $fatal(1, "STUCK pc=%08x cyc=%0d", debug_pc, cycle_count);
        if (ve_seen && post_ve_frames >= max_frames &&
            post_ve_frames >= soak_frames)
            break;
    end

    // This is the legacy timed driver's own inline termination path -- it does
    // NOT call task finalize_run (that copy serves the externally clocked,
    // savable visual profile only; see its own "Keep the terminal proof gates
    // in one place" comment, which is aspirational, not yet actually shared).
    // The V60 cycle profiler dump has to be duplicated here too, or +GAME_ID
    // runs through this default (non-SSV_VISUAL, non-EXTERNAL_CLOCK) path --
    // i.e. every plain `run_gameplay_sims.sh`-style build -- silently never
    // write a CSV despite v60_prof_enable being set correctly.
    if (v60_prof_enable) begin
        integer v60_prof_buckets;
        v60_prof_buckets = 0;
        v60_prof_fd = $fopen(v60_prof_path, "w");
        if (v60_prof_fd == 0)
            $fatal(1, "cannot open V60_CYCLE_PROFILE_OUT path %s", v60_prof_path);
        $fwrite(v60_prof_fd, "opcode_hex,count,total_clk_sys,min_clk_sys,max_clk_sys,avg_clk_sys\n");
        for (i = 0; i < 256; i = i + 1) begin
            if (v60_prof_op_count[i] != 0) begin
                $fwrite(v60_prof_fd, "%02x,%0d,%0d,%0d,%0d,%0f\n",
                        i, v60_prof_op_count[i], v60_prof_op_cycles[i],
                        v60_prof_op_min[i], v60_prof_op_max[i],
                        real'(v60_prof_op_cycles[i]) / real'(v60_prof_op_count[i]));
                v60_prof_buckets = v60_prof_buckets + 1;
            end
        end
        $fclose(v60_prof_fd);
        $display("V60_CYCLE_PROFILE wrote %0d opcode buckets, %0d instructions, window frames [%0d,%0d] to %s",
                  v60_prof_buckets, v60_prof_total_instrs,
                  v60_prof_lo_frame, v60_prof_hi_frame, v60_prof_path);
    end
    if (v60_stateprof_enable) begin
        integer v60_stateprof_j;
        v60_stateprof_fd = $fopen(v60_stateprof_path, "w");
        if (v60_stateprof_fd == 0)
            $fatal(1, "cannot open V60_STATE_PROFILE_OUT path %s", v60_stateprof_path);
        $fwrite(v60_stateprof_fd, "state_id,cycles,entries\n");
        for (v60_stateprof_j = 0; v60_stateprof_j < 128; v60_stateprof_j = v60_stateprof_j + 1) begin
            if (v60_stateprof_cycles[v60_stateprof_j] != 0)
                $fwrite(v60_stateprof_fd, "%0d,%0d,%0d\n", v60_stateprof_j,
                        v60_stateprof_cycles[v60_stateprof_j], v60_stateprof_entries[v60_stateprof_j]);
        end
        $fclose(v60_stateprof_fd);
        $display("V60_STATE_PROFILE op=%02x wrote to %s",
                  v60_stateprof_target_op, v60_stateprof_path);
    end
    if (crc_fd != 0)
        $fclose(crc_fd);
    if (state_fd != 0)
        $fclose(state_fd);

`ifdef SSV_VISUAL
    if (visual_user_quit) begin
        $display("SSV_VISUAL_SAMPLE_SUMMARY fetches=%0d nonzero_fetches=%0d",
                 visual_sample_fetches, visual_nonzero_sample_fetches);
        $display("SSV_VISUAL_RUNTIME_EXIT 0");
        $finish;
    end else begin
`endif
    if (!ve_seen) begin
        // Port-level handshake census. "video-enable write never arrived" says
        // the CPU stalled but not where; these counts separate "never asked"
        // from "it asked and was never answered", which are opposite bugs.
        $display("SDR_CENSUS p0 req=%0d ack=%0d | p2 req=%0d ack=%0d | wr req=%0d ack=%0d | ready=%0b",
                 dbg_p0_req_cnt, dbg_p0_ack_cnt,
                 dbg_p2_req_cnt, dbg_p2_ack_cnt,
                 dbg_wr_req_cnt, dbg_wr_ack_cnt, sdram_ready);
        $fatal(1, "software video-enable write never accepted pc=%08x", debug_pc);
    end
    // The loop above also exits when the cycle budget runs out, and it used to
    // do so silently: +FRAMES=250 with the default +CYCLES=200000000 stops at
    // post-VE frame 215, because a frame is 262 x 3064.2 = ~803k clk_sys and
    // ~35 frames go by before the software video-enable write. Every
    // measurement in
    // docs/PHASE0_MEASUREMENT.md was taken from such a run and therefore never
    // reached this scenario's controllable gameplay, which begins at post-VE
    // frame 820. Say so loudly rather than reporting a short run as a full one.
    if (post_ve_frames < max_frames)
        $display("WARNING CYCLE_BUDGET_TRUNCATED frames=%0d requested=%0d cycles=%0d -- raise +CYCLES to reach the requested frame",
                 post_ve_frames, max_frames, max_cycles);
    if (post_ve_frames < soak_frames)
        $fatal(1, "soak frames=%0d need=%0d", post_ve_frames, soak_frames);
    if (require_attract && !attract_reached)
        $fatal(1, "attract milestone not reached for GAME_ID=%0d", selected_game_id);
    if (require_verilator_screenshot &&
        (!dump_ppm_en || ppm_shots_done < 1))
        $fatal(1, "Verilator attract screenshot was not emitted for GAME_ID=%0d",
               selected_game_id);
    if (!ignore_overrun && (bg_overruns != 0 || obj_overruns != 0))
        $fatal(1, "renderer overrun bg=%0d obj=%0d", bg_overruns, obj_overruns);
    if (!ignore_nonblack && post_ve_nonblack < 1000)
        $fatal(1, "post-VE nonblack too low: %0d", post_ve_nonblack);
    if (!ignore_overrun && debug_status[16])
        $fatal(1, "renderer_overrun sticky set");
    if (watchdog_soft_resets != 0)
        $fatal(1, "unexpected watchdog soft resets=%0d", watchdog_soft_resets);
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
    $display("SIM_LINE_DEM_TOTAL=%0d SIM_LINE_DEM_MAX=%0d POOL_ALLOC=%0d",
             dut.sprite_renderer.sim_line_demand_total,
             dut.sprite_renderer.sim_line_demand_max,
             dut.sprite_renderer.line_pool_alloc);
    $display("CACHE_PEAK=%0d of %0d entries (frame %0d)",
             cache_peak, dut.sprite_renderer.CACHE_ENTRIES, cache_peak_frame);
    $display("SIM_DUPLICATE_SKIPS=%0d",
             dut.sprite_renderer.sim_duplicate_skips);
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
`ifndef SSV_VISUAL_BEHAVIORAL_ONLY
        if (use_real_sdram)
            u_sdram.controller.sdram_dump_stats("frame_crc");
`endif
    end

`ifdef SSV_VISUAL
    $display("SSV_VISUAL_SAMPLE_SUMMARY fetches=%0d nonzero_fetches=%0d",
             visual_sample_fetches, visual_nonzero_sample_fetches);
`endif
    $display("PASS tb_ssv_frame_crc game_id=%0d scenario=%s frames=%0d attract=%0b nonblack=%0d pc=%08x crc=%s overruns bg=%0d obj=%0d watchdog_resets=%0d max_line_entries=%0d",
              selected_game_id, scenario, post_ve_frames, attract_reached,
              post_ve_nonblack, debug_pc, crc_path,
              bg_overruns, obj_overruns, watchdog_soft_resets,
              obj_max_line_entries);
    $finish;
`ifdef SSV_VISUAL
    end
`endif
`endif
end

`ifdef SSV_VISUAL_EXTERNAL_CLOCK
// Process-local streams are not valid across VerilatedSave/Restore. The host
// pulses prepare at clk_sys=0 after a completed native frame, serializes only
// after these handles are zero, then pulses restore both after a save (to keep
// running) and after a fresh-process restore.
always @(posedge checkpoint_prepare) begin
    if (ppm_fd != 0)
        $fatal(1, "checkpoint requested while a PPM stream is open");
    if (crc_fd != 0) begin
        $fclose(crc_fd);
        crc_fd = 0;
    end
    if (state_fd != 0) begin
        $fclose(state_fd);
        state_fd = 0;
    end
    if (irq_schedule_fd != 0) begin
        $fclose(irq_schedule_fd);
        irq_schedule_fd = 0;
    end
end

always @(posedge checkpoint_restore) begin
    if (diff_irq_enabled)
        $fatal(1, "checkpoint restore does not support DIFF_IRQ_SCHEDULE");
    // Proof and capture controls are process/request configuration, not game
    // state.  A checkpoint made in a non-proof chunk otherwise restores them
    // as false and silently bypasses the requested gameplay/screenshot gate.
    require_play = $test$plusargs("REQUIRE_PLAY");
    require_gameplay = $test$plusargs("REQUIRE_GAMEPLAY");
    require_attract = $test$plusargs("REQUIRE_ATTRACT");
    require_verilator_screenshot =
        $test$plusargs("REQUIRE_VERILATOR_SCREENSHOT");
    void'($value$plusargs("STATE_START_FRAME=%d", state_start_frame));
    void'($value$plusargs("FRAMES=%d", max_frames));
    void'($value$plusargs("SOAK_FRAMES=%d", soak_frames));
    void'($value$plusargs("SCENARIO=%s", scenario));
    dump_ppm_en = 1'b0;
    ppm_count = 1;
    ppm_step = 1;
    ppm_shots_done = 0;
    dump_ppm_open = 1'b0;
    ppm_pixels = 0;
    if ($value$plusargs("DUMP_PPM_PREFIX=%s", ppm_prefix)) begin
        dump_ppm_en = 1'b1;
        void'($value$plusargs("DUMP_PPM_START=%d", ppm_start));
        void'($value$plusargs("DUMP_PPM_COUNT=%d", ppm_count));
        void'($value$plusargs("DUMP_PPM_STEP=%d", ppm_step));
    end else if ($value$plusargs("DUMP_PPM=%s", ppm_path)) begin
        dump_ppm_en = 1'b1;
        ppm_prefix = "";
        void'($value$plusargs("DUMP_PPM_FRAME=%d", ppm_frame));
        ppm_start = ppm_frame;
        ppm_count = 1;
        ppm_step = 1;
    end
    // File descriptors are process-local and their serialized integer values
    // are meaningless in a fresh Verilator process.  Always discard the
    // restored handle value and reopen from the process-local path, rather
    // than testing the stale integer for zero.
    if (crc_fd != 0)
        $fclose(crc_fd);
    crc_fd = 0;
    crc_fd = $fopen(crc_path, "a");
    if (crc_fd == 0)
        $fatal(1, "cannot reopen FRAME_CRC after checkpoint: %s", crc_path);
    if (state_fd != 0)
        $fclose(state_fd);
    state_fd = 0;
    if (state_path.len() != 0) begin
        state_fd = $fopen(state_path, "a");
        if (state_fd == 0)
            $fatal(1, "cannot reopen STATE_CRC after checkpoint: %s", state_path);
    end
end

// External host clock driver. The reset phase preserves the legacy repeat(8)
// contract: eight rising edges observe reset asserted, and normal execution
// begins on the following edge. Terminal checks remain in SystemVerilog so the
// checkpoint profile cannot bypass proof, renderer, watchdog, or soak gates.
always @(posedge clk_sys) begin
    if (external_setup_complete && !run_done) begin
        if (rst) begin
            if (external_reset_edges == 7)
                rst <= 1'b0;
            else
                external_reset_edges <= external_reset_edges + 1;
        end else begin
`ifdef SSV_VISUAL
            if ((cycle_count & 64'h0000_0000_0000_ffff) == 0 &&
                ssv_visual_poll() != 0) begin
                $display("SSV_VISUAL_EXIT during boot/run cycle=%0d", cycle_count);
                visual_user_quit = 1'b1;
                finalize_run();
            end else if (visual_user_quit) begin
                finalize_run();
            end else
`endif
            if (stuck > 500000) begin
                $fatal(1, "STUCK pc=%08x cyc=%0d", debug_pc, cycle_count);
            end else if (ve_seen && post_ve_frames >= max_frames &&
                         post_ve_frames >= soak_frames) begin
                finalize_run();
            end else if (cycle_count + 1 >= max_cycles) begin
                finalize_run();
            end else begin
                cycle_count <= cycle_count + 1;
            end
        end
    end
end
`endif

endmodule
