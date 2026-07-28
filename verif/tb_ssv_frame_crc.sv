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
//   +SDRAM_REAL          drive the core through rtl/mem/sdram.sv plus
//                        verif/sdram_chip_model.sv instead of the per-port stub
//   +SDRAM_FULLLOAD      (with +SDRAM_REAL) install the ROM image by driving
//                        ssv_rom_loader through the real controller instead of
//                        backdooring the chip array
//   +SDRAM_STRICT        make chip-model protocol violations fatal
//   +SDRAM_IMAGE_ONLY    install + fingerprint the SDRAM image, then stop
//   +SDRAM_CHECK_DATA    assert every p0/p1/p4 word equals the stub's layout
//   +SDRAM_STATS=path    per-frame overrun/latency CSV
//
// The default path is the original per-port stub and is preserved bit-for-bit,
// because sim_output/diff/rtl_final96_gameplay_frames.crc was produced against
// it.  Under +SDRAM_REAL the CPU/raster ratio legitimately changes, so that
// golden does not apply; judge that mode on assertions and overrun counts.

module tb_ssv_frame_crc;
`include "ssv_tb_crc32.svh"

// clk_sys and clk_ram are synchronous, clk_ram = 2 * clk_sys, rising edges
// aligned -- the relationship rtl/mem/sdram.sv's 2-cycle ack stretch assumes.
// clk_ram runs unconditionally; in stub mode the controller is held in init so
// it issues nothing and costs nothing.
logic clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;
logic clk_ram = 1'b1;
always #2.5 clk_ram = ~clk_ram;

logic sdram_real, sdram_fullload;

logic rst, ce_cpu;
logic sdr_p0_req;
wire  sdr_p0_ack;
logic [24:1] sdr_p0_addr;
wire  [15:0] sdr_p0_dout;
logic sdr_p1_req;
wire  sdr_p1_ack;
logic [24:3] sdr_p1_addr;
wire  [63:0] sdr_p1_dout;
logic sdr_wr_req;
wire  sdr_wr_ack;
logic sdr_p4_req;
wire  sdr_p4_ack;
logic [24:1] sdr_p4_addr;
wire  [15:0] sdr_p4_dout;
logic [24:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;

logic [15:0] in_p1, in_p2, in_system, in_extra, in_dsw1, in_dsw2;

byte main_rom [0:1048575];
byte sprite_rom [0:12582911];
byte sample_rom [0:4194303];
logic [15:0] external_ram [0:196607];

string main_path, sprite_path, sample_path, crc_path, state_path, scenario;
string sdram_stats_path;
integer main_fd, sprite_fd, sample_fd, crc_fd, state_fd, sdram_stats_fd;
integer main_count, sprite_count, sample_count, cycle_count, max_cycles, i;
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
logic [24:0] p0_byte_addr, p1_byte_addr;
integer ext_index, sprite_index, packed_code, packed_row;
integer raw_q0_index, raw_q1_index;
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

ssv_tb_ce_cpu u_ce (.clk(clk_sys), .rst(rst), .ce_cpu(ce_cpu));

ssv_core dut (
    .clk_sys(clk_sys), .rst(rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p1_req(sdr_p1_req), .sdr_p1_addr(sdr_p1_addr),
    .sdr_p1_dout(sdr_p1_dout), .sdr_p1_ack(sdr_p1_ack),
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

logic stub_p0_ack, stub_p1_ack, stub_wr_ack, stub_p4_ack;
logic [15:0] stub_p0_dout, stub_p4_dout;
logic [63:0] stub_p1_dout;

// Sticky multi-cycle ack (covers CE gaps from fractional enable).
always_ff @(posedge clk_sys) begin
    stub_p0_ack <= 1'b0;
    stub_p1_ack <= 1'b0;
    stub_wr_ack <= 1'b0;
    stub_p4_ack <= 1'b0;
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
    end else begin
        // Ownership check, written against observable behaviour rather than
        // against the fix, so it is valid with or without it: the background
        // fetcher must never complete a transaction (leave WAIT_ACK=1) while
        // the object renderer owns p1. If it does, it has just latched the
        // object renderer's tile data as its own background tile.
        bg_fetch_state_d <= dut.background_renderer.fetch.state;
        obj_owned_d      <= dut.obj_busy;
        if (bg_fetch_state_d == 2'd1 &&
            dut.background_renderer.fetch.state != 2'd1 &&
            obj_owned_d)
            bg_ack_while_obj_owns <= bg_ack_while_obj_owns + 1;
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1'b1;
            p0_byte_addr = {sdr_p0_addr, 1'b0};
            if (p0_byte_addr < 25'h0100000)
                stub_p0_dout <= {main_rom[p0_byte_addr+1], main_rom[p0_byte_addr]};
            else if (p0_byte_addr >= 25'h1100000 && p0_byte_addr < 25'h1160000) begin
                ext_index = (p0_byte_addr - 25'h1100000) >> 1;
                stub_p0_dout <= external_ram[ext_index];
            end else
                stub_p0_dout <= 16'hffff;
            p0_hold <= 4'd2;
        end
        if (p0_hold != 0) begin
            stub_p0_ack <= 1'b1;
            p0_hold <= p0_hold - 1'd1;
        end else if (!sdr_p0_req)
            p0_seen <= 1'b0;

        if (sdr_p1_req && !p1_seen) begin
            p1_seen <= 1'b1;
            p1_byte_addr = {sdr_p1_addr, 3'b000};
            sprite_index = p1_byte_addr - 25'h0100000;
            if (sprite_index >= 0 && sprite_index < 8388608) begin
                packed_code = sprite_index >> 6;
                packed_row = (sprite_index >> 3) & 7;
                raw_q0_index = packed_code * 32 + packed_row * 4;
                raw_q1_index = 4194304 + raw_q0_index;
                stub_p1_dout <= {
                    sprite_rom[raw_q1_index+3], sprite_rom[raw_q1_index+2],
                    sprite_rom[raw_q1_index+1], sprite_rom[raw_q1_index],
                    sprite_rom[raw_q0_index+3], sprite_rom[raw_q0_index+2],
                    sprite_rom[raw_q0_index+1], sprite_rom[raw_q0_index]
                };
            end else if (sprite_index >= 0 && sprite_index + 7 < 12582912) begin
                stub_p1_dout <= {
                    sprite_rom[sprite_index+7], sprite_rom[sprite_index+6],
                    sprite_rom[sprite_index+5], sprite_rom[sprite_index+4],
                    sprite_rom[sprite_index+3], sprite_rom[sprite_index+2],
                    sprite_rom[sprite_index+1], sprite_rom[sprite_index]
                };
            end else
                stub_p1_dout <= 64'd0;
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
            stub_p1_ack <= 1'b1;
            p1_hold <= p1_hold - 1'd1;
        end else if (!sdr_p1_req && p1_delay == 0)
            p1_seen <= 1'b0;

        if (sdr_wr_req && !wr_seen) begin
            wr_seen <= 1'b1;
            if ({sdr_wr_addr, 1'b0} >= 25'h1100000 &&
                {sdr_wr_addr, 1'b0} < 25'h1160000) begin
                ext_index = ({sdr_wr_addr, 1'b0} - 25'h1100000) >> 1;
                if (sdr_wr_be[0])
                    external_ram[ext_index][7:0] <= sdr_wr_din[7:0];
                if (sdr_wr_be[1])
                    external_ram[ext_index][15:8] <= sdr_wr_din[15:8];
            end
            wr_hold <= 4'd2;
        end
        if (wr_hold != 0) begin
            stub_wr_ack <= 1'b1;
            wr_hold <= wr_hold - 1'd1;
        end else if (!sdr_wr_req)
            wr_seen <= 1'b0;

        if (sdr_p4_req && !p4_seen) begin
            p4_seen <= 1'b1;
            stub_p4_dout <= 16'd0;
            p4_hold <= 4'd2;
        end
        if (p4_hold != 0) begin
            stub_p4_ack <= 1'b1;
            p4_hold <= p4_hold - 1'd1;
        end else if (!sdr_p4_req)
            p4_seen <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// Real SDRAM path (+SDRAM_REAL): rtl/mem/sdram.sv in front of a behavioural
// SDR chip model.  All four ports the core uses are serialised through one
// chip with tRCD, CL2, the 2-cycle ack stretch and refresh stalls, which is
// what makes a scanline able to miss its rendering deadline.
//
// The controller is held in `init` in stub mode, so it issues no commands and
// the chip model stays silent; the default path is unaffected.
// ---------------------------------------------------------------------------
logic sdram_init;
logic loader_rst;
wire  sdram_ready;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH;
wire        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

// ROM download.  The loader is always instantiated: +SDRAM_FULLLOAD drives it
// for real, and the backdoor image install calls its address-mapping function
// hierarchically so both paths use exactly the same layout.
logic        ioctl_download, ioctl_wr;
logic  [7:0] ioctl_index, ioctl_dout;
logic [26:0] ioctl_addr;
wire         ioctl_wait;
wire         ld_wr_req, rom_loaded;
wire  [24:1] ld_wr_addr;
wire  [15:0] ld_wr_din;
wire   [1:0] ld_wr_be;
wire  [26:0] download_max_addr;

wire real_p0_ack, real_p1_ack, real_p4_ack, real_wr_ack;
wire [15:0] real_p0_dout, real_p4_dout;
wire [63:0] real_p1_dout;
wire        ld_wr_ack;

ssv_rom_loader u_loader (
    .clk(clk_sys), .rst(loader_rst), .mem_ready(sdram_ready),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_wait(ioctl_wait),
    .sdr_wr_req(ld_wr_req), .sdr_wr_addr(ld_wr_addr),
    .sdr_wr_din(ld_wr_din), .sdr_wr_be(ld_wr_be),
    .sdr_wr_ack(ld_wr_ack), .rom_loaded(rom_loaded),
    .download_max_addr(download_max_addr)
);

// Same write-port arbitration as Arcade-SSV.sv: the loader outranks the core.
wire        loader_owns_write = ld_wr_req;
wire        sw_req  = loader_owns_write ? ld_wr_req  : sdr_wr_req;
wire [24:1] sw_addr = loader_owns_write ? ld_wr_addr : sdr_wr_addr;
wire [15:0] sw_din  = loader_owns_write ? ld_wr_din  : sdr_wr_din;
wire  [1:0] sw_be   = loader_owns_write ? ld_wr_be   : sdr_wr_be;
assign      ld_wr_ack   = loader_owns_write ? real_wr_ack : 1'b0;
wire        core_wr_ack = loader_owns_write ? 1'b0 : real_wr_ack;

sdram u_sdram (
    .clk(clk_ram), .init(sdram_init), .ready(sdram_ready),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
    .wr_req(sw_req), .wr_addr(sw_addr), .wr_din(sw_din), .wr_be(sw_be),
    .wr_ack(real_wr_ack),
    .p0_req(sdr_p0_req), .p0_addr(sdr_p0_addr),
    .p0_dout(real_p0_dout), .p0_ack(real_p0_ack),
    .p1_req(sdr_p1_req), .p1_addr(sdr_p1_addr),
    .p1_dout(real_p1_dout), .p1_ack(real_p1_ack),
    .p2_req(1'b0), .p2_addr('0), .p2_dout(), .p2_ack(),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(), .p3_ack(),
    .p4_req(sdr_p4_req), .p4_addr(sdr_p4_addr),
    .p4_dout(real_p4_dout), .p4_ack(real_p4_ack),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

logic        bd_we;
logic [23:0] bd_addr;
logic [15:0] bd_din;
wire [31:0] chip_act, chip_read, chip_write, chip_ref, chip_pre,
            chip_violations;

sdram_chip_model u_chip (
    .clk(clk_ram), .cke(SDRAM_CKE),
    .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .BA(SDRAM_BA), .A(SDRAM_A), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH),
    .DQ(SDRAM_DQ),
    .bd_we(bd_we), .bd_addr(bd_addr), .bd_din(bd_din),
    .n_act(chip_act), .n_read(chip_read), .n_write(chip_write),
    .n_ref(chip_ref), .n_pre(chip_pre), .n_violation(chip_violations)
);

assign sdr_p0_ack  = sdram_real ? real_p0_ack  : stub_p0_ack;
assign sdr_p0_dout = sdram_real ? real_p0_dout : stub_p0_dout;
assign sdr_p1_ack  = sdram_real ? real_p1_ack  : stub_p1_ack;
assign sdr_p1_dout = sdram_real ? real_p1_dout : stub_p1_dout;
assign sdr_p4_ack  = sdram_real ? real_p4_ack  : stub_p4_ack;
assign sdr_p4_dout = sdram_real ? real_p4_dout : stub_p4_dout;
assign sdr_wr_ack  = sdram_real ? core_wr_ack  : stub_wr_ack;

// ---------------------------------------------------------------------------
// Service-latency instrumentation (clk_sys cycles, request rising edge to ack).
// Sampled only after video_enable so boot traffic does not skew the numbers
// the hardware stream needs.
// ---------------------------------------------------------------------------
localparam int LAT_BUCKETS = 40;   // 4-cycle buckets, last = >= 156
logic p1_req_d, p1_lat_active, p1_lat_owner_obj;
logic p0_req_d, p0_lat_active;
int   p1_lat_cnt, p0_lat_cnt;
int   p1_lat_n, p1_lat_max, p0_lat_n, p0_lat_max;
int   p1_lat_n_obj, p1_lat_max_obj, p1_lat_n_bg, p1_lat_max_bg;
longint unsigned p1_lat_sum, p0_lat_sum, p1_lat_sum_obj, p1_lat_sum_bg;
int   p1_lat_hist [0:LAT_BUCKETS-1];
int   lat_i;

always_ff @(posedge clk_sys) begin
    int b;
    if (rst) begin
        p1_req_d <= 1'b0; p1_lat_active <= 1'b0; p1_lat_cnt <= 0;
        p1_lat_owner_obj <= 1'b0;
        p0_req_d <= 1'b0; p0_lat_active <= 1'b0; p0_lat_cnt <= 0;
        p1_lat_n <= 0; p1_lat_max <= 0; p1_lat_sum <= 0;
        p1_lat_n_obj <= 0; p1_lat_max_obj <= 0; p1_lat_sum_obj <= 0;
        p1_lat_n_bg <= 0; p1_lat_max_bg <= 0; p1_lat_sum_bg <= 0;
        p0_lat_n <= 0; p0_lat_max <= 0; p0_lat_sum <= 0;
        for (b = 0; b < LAT_BUCKETS; b = b + 1) p1_lat_hist[b] <= 0;
    end
    else begin
        p1_req_d <= sdr_p1_req;
        p0_req_d <= sdr_p0_req;
        if (sdr_p1_req && !p1_req_d) begin
            p1_lat_active    <= 1'b1;
            p1_lat_cnt       <= 1;
            p1_lat_owner_obj <= dut.obj_busy;
        end
        else if (p1_lat_active) begin
            if (sdr_p1_ack) begin
                p1_lat_active <= 1'b0;
                if (ve_seen) begin
                    b = p1_lat_cnt / 4;
                    if (b >= LAT_BUCKETS) b = LAT_BUCKETS - 1;
                    p1_lat_hist[b] <= p1_lat_hist[b] + 1;
                    p1_lat_n   <= p1_lat_n + 1;
                    p1_lat_sum <= p1_lat_sum + p1_lat_cnt;
                    if (p1_lat_cnt > p1_lat_max) p1_lat_max <= p1_lat_cnt;
                    if (p1_lat_owner_obj) begin
                        p1_lat_n_obj   <= p1_lat_n_obj + 1;
                        p1_lat_sum_obj <= p1_lat_sum_obj + p1_lat_cnt;
                        if (p1_lat_cnt > p1_lat_max_obj)
                            p1_lat_max_obj <= p1_lat_cnt;
                    end
                    else begin
                        p1_lat_n_bg   <= p1_lat_n_bg + 1;
                        p1_lat_sum_bg <= p1_lat_sum_bg + p1_lat_cnt;
                        if (p1_lat_cnt > p1_lat_max_bg)
                            p1_lat_max_bg <= p1_lat_cnt;
                    end
                end
            end
            else
                p1_lat_cnt <= p1_lat_cnt + 1;
        end

        if (sdr_p0_req && !p0_req_d) begin
            p0_lat_active <= 1'b1;
            p0_lat_cnt    <= 1;
        end
        else if (p0_lat_active) begin
            if (sdr_p0_ack) begin
                p0_lat_active <= 1'b0;
                if (ve_seen) begin
                    p0_lat_n   <= p0_lat_n + 1;
                    p0_lat_sum <= p0_lat_sum + p0_lat_cnt;
                    if (p0_lat_cnt > p0_lat_max) p0_lat_max <= p0_lat_cnt;
                end
            end
            else
                p0_lat_cnt <= p0_lat_cnt + 1;
        end
    end
end

// ---------------------------------------------------------------------------
// Per-frame line-deadline overrun accounting.
// ---------------------------------------------------------------------------
logic   vb_d2;
integer bg_over_prev, obj_over_prev;
integer frame_bg_over, frame_obj_over;
integer max_frame_bg_over, max_frame_obj_over;
integer frames_with_over, frames_counted;

always_ff @(posedge clk_sys) begin
    if (rst) begin
        vb_d2 <= 1'b1;
        bg_over_prev = 0; obj_over_prev = 0;
        frame_bg_over = 0; frame_obj_over = 0;
        max_frame_bg_over = 0; max_frame_obj_over = 0;
        frames_with_over = 0; frames_counted = 0;
    end
    else begin
        vb_d2 <= vb;
        if (ve_seen && !vb_d2 && vb) begin
            frame_bg_over  = bg_overruns  - bg_over_prev;
            frame_obj_over = obj_overruns - obj_over_prev;
            bg_over_prev   = bg_overruns;
            obj_over_prev  = obj_overruns;
            frames_counted = frames_counted + 1;
            if (frame_bg_over > max_frame_bg_over)
                max_frame_bg_over = frame_bg_over;
            if (frame_obj_over > max_frame_obj_over)
                max_frame_obj_over = frame_obj_over;
            if (frame_bg_over != 0 || frame_obj_over != 0)
                frames_with_over = frames_with_over + 1;
            if (sdram_stats_fd != 0) begin
                $fdisplay(sdram_stats_fd, "%0d,%0d,%0d,%0d,%0d",
                          post_ve_frames, frame_bg_over, frame_obj_over,
                          p1_lat_max, obj_max_line_cycles);
                $fflush(sdram_stats_fd);
            end
        end
    end
end

task automatic report_sdram_stats();
    real mean_all, mean_obj, mean_bg;
    // 64-bit: at ~56 M p1 transactions per 950-frame soak, acc*100 overflows
    // a 32-bit integer and the percentile search reports garbage.
    longint acc, total;
    integer p50, p90, p99;
    mean_all = (p1_lat_n == 0) ? 0.0 : real'(p1_lat_sum) / real'(p1_lat_n);
    mean_obj = (p1_lat_n_obj == 0) ? 0.0 :
               real'(p1_lat_sum_obj) / real'(p1_lat_n_obj);
    mean_bg  = (p1_lat_n_bg  == 0) ? 0.0 :
               real'(p1_lat_sum_bg)  / real'(p1_lat_n_bg);
    $display("SDRAM_MODE %s chip act=%0d read=%0d write=%0d refresh=%0d violations=%0d",
             sdram_real ? "real" : "stub",
             chip_act, chip_read, chip_write, chip_ref, chip_violations);
    $display("P1_LATENCY_STATS n=%0d mean=%0.2f max=%0d | obj n=%0d mean=%0.2f max=%0d | bg n=%0d mean=%0.2f max=%0d (clk_sys cycles, post-VE)",
             p1_lat_n, mean_all, p1_lat_max,
             p1_lat_n_obj, mean_obj, p1_lat_max_obj,
             p1_lat_n_bg, mean_bg, p1_lat_max_bg);
    $display("P0_LATENCY_STATS n=%0d mean=%0.2f max=%0d",
             p0_lat_n,
             (p0_lat_n == 0) ? 0.0 : real'(p0_lat_sum) / real'(p0_lat_n),
             p0_lat_max);
    acc = 0; p50 = -1; p90 = -1; p99 = -1;
    total = longint'(p1_lat_n);
    for (lat_i = 0; lat_i < LAT_BUCKETS; lat_i = lat_i + 1) begin
        acc = acc + longint'(p1_lat_hist[lat_i]);
        if (p50 < 0 && total != 0 && acc * 100 >= total * 50)
            p50 = lat_i * 4 + 3;
        if (p90 < 0 && total != 0 && acc * 100 >= total * 90)
            p90 = lat_i * 4 + 3;
        if (p99 < 0 && total != 0 && acc * 100 >= total * 99)
            p99 = lat_i * 4 + 3;
    end
    $display("P1_LATENCY_PCTL p50<=%0d p90<=%0d p99<=%0d", p50, p90, p99);
    for (lat_i = 0; lat_i < LAT_BUCKETS; lat_i = lat_i + 1)
        if (p1_lat_hist[lat_i] != 0)
            $display("P1_LATENCY_HIST %0d-%0d %0d",
                     lat_i * 4, lat_i * 4 + 3, p1_lat_hist[lat_i]);
    $display("OVERRUN_PER_FRAME frames=%0d with_overrun=%0d bg_total=%0d obj_total=%0d bg_per_frame=%0.3f obj_per_frame=%0.3f bg_max=%0d obj_max=%0d",
             frames_counted, frames_with_over, bg_overruns, obj_overruns,
             (frames_counted == 0) ? 0.0 :
                real'(bg_overruns) / real'(frames_counted),
             (frames_counted == 0) ? 0.0 :
                real'(obj_overruns) / real'(frames_counted),
             max_frame_bg_over, max_frame_obj_over);
endtask


// ---------------------------------------------------------------------------
// Data-path equivalence check (+SDRAM_CHECK_DATA).
//
// expected_p1/expected_p0 are a transcription of the per-port stub's byte
// layout.  Running the check in STUB mode proves the transcription is exactly
// what the stub returns (and therefore what the golden CRC stream was produced
// against); running it in REAL mode then proves the chip model plus the ROM
// loader's address mapping return the same bytes for the same addresses.
// ---------------------------------------------------------------------------
logic chk_data;
int   chk_p1_n, chk_p1_bad, chk_p0_n, chk_p0_bad, chk_p4_n, chk_p4_bad;
logic [24:3] p1_addr_lat;
logic [24:1] p0_addr_lat, p4_addr_lat;

function automatic logic [63:0] expected_p1(input logic [24:3] a);
    logic [24:0] byte_addr;
    integer si, pc_, pr_, q0, q1;
    begin
        byte_addr = {a, 3'b000};
        si = byte_addr - 25'h0100000;
        if (si >= 0 && si < 8388608) begin
            pc_ = si >> 6;
            pr_ = (si >> 3) & 7;
            q0  = pc_ * 32 + pr_ * 4;
            q1  = 4194304 + q0;
            expected_p1 = {
                sprite_rom[q1+3], sprite_rom[q1+2],
                sprite_rom[q1+1], sprite_rom[q1],
                sprite_rom[q0+3], sprite_rom[q0+2],
                sprite_rom[q0+1], sprite_rom[q0]
            };
        end
        else if (si >= 0 && si + 7 < 12582912) begin
            expected_p1 = {
                sprite_rom[si+7], sprite_rom[si+6],
                sprite_rom[si+5], sprite_rom[si+4],
                sprite_rom[si+3], sprite_rom[si+2],
                sprite_rom[si+1], sprite_rom[si]
            };
        end
        else
            expected_p1 = 64'd0;
    end
endfunction

function automatic logic [15:0] expected_p0(input logic [24:1] a);
    logic [24:0] byte_addr;
    begin
        byte_addr = {a, 1'b0};
        expected_p0 = {main_rom[byte_addr+1], main_rom[byte_addr]};
    end
endfunction

function automatic logic [15:0] expected_p4(input logic [24:1] a);
    logic [24:0] byte_addr;
    integer si;
    begin
        byte_addr = {a, 1'b0};
        si = byte_addr - 25'h0d00000;
        expected_p4 = {sample_rom[si+1], sample_rom[si]};
    end
endfunction

always_ff @(posedge clk_sys) begin
    if (rst) begin
        chk_p1_n <= 0; chk_p1_bad <= 0;
        chk_p0_n <= 0; chk_p0_bad <= 0;
        chk_p4_n <= 0; chk_p4_bad <= 0;
        p1_addr_lat <= '0; p0_addr_lat <= '0; p4_addr_lat <= '0;
    end
    else if (chk_data) begin
        if (sdr_p1_req && !p1_req_d) p1_addr_lat <= sdr_p1_addr;
        if (sdr_p0_req && !p0_req_d) p0_addr_lat <= sdr_p0_addr;
        if (sdr_p4_req)              p4_addr_lat <= sdr_p4_addr;

        // p1: whole GFX ROM window.
        if (sdr_p1_ack) begin
            chk_p1_n <= chk_p1_n + 1;
            if (sdr_p1_dout !== expected_p1(p1_addr_lat)) begin
                chk_p1_bad <= chk_p1_bad + 1;
                if (chk_p1_bad < 8)
                    $display("SDRAM_DATA_MISMATCH p1 addr=%06x got=%016x want=%016x",
                             {p1_addr_lat, 3'b000}, sdr_p1_dout,
                             expected_p1(p1_addr_lat));
            end
        end
        // p0: V60 program window only.  Anything above it is work/XRAM, which
        // lives in the SDRAM array in real mode and in a tb array in stub mode,
        // so the two are not comparable by construction.
        if (sdr_p0_ack && {p0_addr_lat, 1'b0} < 25'h0100000) begin
            chk_p0_n <= chk_p0_n + 1;
            if (sdr_p0_dout !== expected_p0(p0_addr_lat)) begin
                chk_p0_bad <= chk_p0_bad + 1;
                if (chk_p0_bad < 8)
                    $display("SDRAM_DATA_MISMATCH p0 addr=%06x got=%04x want=%04x",
                             {p0_addr_lat, 1'b0}, sdr_p0_dout,
                             expected_p0(p0_addr_lat));
            end
        end
        // p4: ES5506 sample window.  Only meaningful in real mode; the stub
        // returns a constant zero and never touches sample_rom.
        if (sdram_real && sdr_p4_ack &&
            {p4_addr_lat, 1'b0} >= 25'h0d00000 &&
            {p4_addr_lat, 1'b0} <  25'h1100000) begin
            chk_p4_n <= chk_p4_n + 1;
            if (sdr_p4_dout !== expected_p4(p4_addr_lat)) begin
                chk_p4_bad <= chk_p4_bad + 1;
                if (chk_p4_bad < 8)
                    $display("SDRAM_DATA_MISMATCH p4 addr=%06x got=%04x want=%04x",
                             {p4_addr_lat, 1'b0}, sdr_p4_dout,
                             expected_p4(p4_addr_lat));
            end
        end
    end
end

// ---------------------------------------------------------------------------
// Image install.
// ---------------------------------------------------------------------------
function automatic logic [7:0] stream_byte(input integer a);
    if (a < 32'h100000)       stream_byte = main_rom[a];
    else if (a < 32'hd00000)  stream_byte = sprite_rom[a - 32'h100000];
    else if (a < 32'h1100000) stream_byte = sample_rom[a - 32'hd00000];
    else                      stream_byte = 8'h00;
endfunction

// Backdoor install: same 16-bit word and the same mapped address the loader
// would have produced (its mapping function is called hierarchically), written
// straight into the chip array instead of paying 8.9 M controller writes.
task automatic backdoor_install();
    integer s;
    logic [24:0] mapped;
    $display("SDRAM_REAL backdoor image install (%0d bytes)...", 32'h1100000);
    for (s = 0; s < 32'h1100000; s = s + 2) begin
        mapped = u_loader.stream_byte_address(27'(s + 1));
        @(posedge clk_ram);
        bd_addr <= mapped[24:1];
        bd_din  <= {stream_byte(s + 1), stream_byte(s)};
        bd_we   <= 1'b1;
    end
    @(posedge clk_ram);
    bd_we <= 1'b0;
    @(posedge clk_ram);
    $display("SDRAM_REAL backdoor install done");
endtask

// Full install: drive the real ioctl download stream into ssv_rom_loader and
// let every word go through rtl/mem/sdram.sv.  Slow; used to prove the
// backdoor image is identical to what the loader plus controller write.
task automatic fullload_install();
    integer s;
    $display("SDRAM_REAL full loader install (%0d bytes)...", 32'h1100000);
    @(posedge clk_sys);
    ioctl_index    <= 8'd0;
    ioctl_download <= 1'b1;
    @(posedge clk_sys);
    for (s = 0; s < 32'h1100000; s = s + 1) begin
        @(posedge clk_sys);
        while (ioctl_wait) @(posedge clk_sys);
        ioctl_addr <= 27'(s);
        ioctl_dout <= stream_byte(s);
        ioctl_wr   <= 1'b1;
        @(posedge clk_sys);
        ioctl_wr   <= 1'b0;
        if ((s & 32'hfffff) == 0 && s != 0)
            $display("  ... %0d MiB", s >> 20);
    end
    @(posedge clk_sys);
    while (ioctl_wait) @(posedge clk_sys);
    ioctl_download <= 1'b0;
    repeat (32) @(posedge clk_sys);
    $display("SDRAM_REAL full loader install done rom_loaded=%0b", rom_loaded);
endtask

// Image fingerprint over the regions the game actually reads, so the backdoor
// and full-loader installs can be compared word-for-word without dumping 32 MiB.
function automatic logic [31:0] image_fingerprint();
    integer k;
    logic [31:0] h;
    h = 32'hffffffff;
    for (k = 0; k < 32'h80000; k = k + 1)            // 1 MiB V60 program
        h = ssv_crc32_byte(ssv_crc32_byte(h, u_chip.mem[k][7:0]),
                           u_chip.mem[k][15:8]);
    for (k = 32'h80000; k < 32'h880000; k = k + 257) // sprite ROM, strided
        h = ssv_crc32_byte(ssv_crc32_byte(h, u_chip.mem[k][7:0]),
                           u_chip.mem[k][15:8]);
    for (k = 32'h680000; k < 32'h880000; k = k + 131) // sample ROM, strided
        h = ssv_crc32_byte(ssv_crc32_byte(h, u_chip.mem[k][7:0]),
                           u_chip.mem[k][15:8]);
    image_fingerprint = ~h;
endfunction

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
        scenario == "coin_start_p1_gameplay") begin
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
        if (scenario == "coin_start_p1_gameplay") begin
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
                                dut.sprite_ram.sim_peek(diag_i[16:0])[7:0]),
                            dut.sprite_ram.sim_peek(diag_i[16:0])[15:8]);
                        if (diag_i < 512)
                            list_crc = ssv_crc32_byte(
                                ssv_crc32_byte(list_crc,
                                    dut.sprite_ram.sim_peek(diag_i[16:0])[7:0]),
                                dut.sprite_ram.sim_peek(diag_i[16:0])[15:8]);
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
                            dut.sprite_ram.sim_peek(diag_i[16:0])[7:0]),
                        dut.sprite_ram.sim_peek(diag_i[16:0])[15:8]);
                    if (diag_i < 512)
                        list_crc = ssv_crc32_byte(
                            ssv_crc32_byte(list_crc,
                                dut.sprite_ram.sim_peek(diag_i[16:0])[7:0]),
                            dut.sprite_ram.sim_peek(diag_i[16:0])[15:8]);
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
                         dut.obj_rom_req, sdr_p1_ack);
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
            if (dut.sprite_renderer.state == 6'd33)
                obj_rom_wait_cycles <= obj_rom_wait_cycles + 1;
            if (dut.sprite_renderer.state == 6'd22)
                obj_line_descriptors <= obj_line_descriptors + 1;
            if (dut.sprite_renderer.state == 6'd32) begin
                obj_line_fetches <= obj_line_fetches + 1;
                if (dut.sprite_renderer.render_tilemap)
                    obj_line_tilemap_fetches <= obj_line_tilemap_fetches + 1;
            end
            if (dut.sprite_renderer.state == 6'd34)
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
    if (!$value$plusargs("SMPROM=%s", sample_path))
        sample_path = "sim_output/rom/samples.bin";
    sdram_real     = $test$plusargs("SDRAM_REAL");
    sdram_fullload = $test$plusargs("SDRAM_FULLLOAD");
    chk_data       = $test$plusargs("SDRAM_CHECK_DATA");
    sdram_stats_fd = 0;
    if ($value$plusargs("SDRAM_STATS=%s", sdram_stats_path)) begin
        sdram_stats_fd = $fopen(sdram_stats_path, "w");
        if (sdram_stats_fd == 0)
            $fatal(1, "cannot open SDRAM_STATS path %s", sdram_stats_path);
        $fdisplay(sdram_stats_fd,
                  "frame,bg_overruns,obj_overruns,p1_lat_max,obj_max_line_cycles");
    end
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
    // The sample ROM only matters in real-SDRAM mode, where the ES5506 fetch
    // is genuine p4 traffic through the same chip.  The stub returns zeros.
    sample_count = 0;
    if (sdram_real) begin
        sample_fd = $fopen(sample_path, "rb");
        if (sample_fd == 0)
            $fatal(1, "cannot open sample ROM %s", sample_path);
        sample_count = $fread(sample_rom, sample_fd);
        $fclose(sample_fd);
        if (sample_count != 4194304)
            $fatal(1, "short sample ROM read %0d", sample_count);
    end

    crc_fd = $fopen(crc_path, "w");
    if (crc_fd == 0)
        $fatal(1, "cannot open FRAME_CRC path %s", crc_path);

    for (i = 0; i < 196608; i = i + 1)
        external_ram[i] = 16'd0;

    apply_inputs(0);
    rst = 1'b1;
    // Stub mode holds the controller in init forever, so it issues no commands
    // and the default data path is untouched.
    sdram_init     = 1'b1;
    loader_rst     = 1'b1;
    ioctl_download = 1'b0;
    ioctl_wr       = 1'b0;
    ioctl_index    = 8'd0;
    ioctl_addr     = 27'd0;
    ioctl_dout     = 8'd0;
    bd_we          = 1'b0;
    bd_addr        = 24'd0;
    bd_din         = 16'd0;
    repeat (8) @(posedge clk_sys);
    if (sdram_real) begin
        loader_rst = 1'b0;
        sdram_init = 1'b0;
        @(posedge clk_ram);
        while (!sdram_ready) @(posedge clk_ram);
        $display("SDRAM_REAL controller ready at %0t", $time);
        if (sdram_fullload)
            fullload_install();
        else
            backdoor_install();
        // Same read-back signature Arcade-SSV.sv probes before releasing the
        // core: a wrong image or a wrong address map shows up here, not 200
        // million cycles later as a blank screen.
        if (u_chip.mem[24'h000000] !== 16'h207a ||
            u_chip.mem[24'h00f9e8] !== 16'h0c7a)
            $fatal(1, "SDRAM image signature wrong: [0]=%04x [0x1f3d0>>1]=%04x",
                   u_chip.mem[24'h000000], u_chip.mem[24'h00f9e8]);
        $display("SDRAM_IMAGE fingerprint=%08x", image_fingerprint());
        if ($test$plusargs("SDRAM_IMAGE_ONLY")) begin
            $display("SDRAM_IMAGE_ONLY: image install verified, stopping");
            $finish;
        end
        repeat (8) @(posedge clk_sys);
    end
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
    if (sdram_stats_fd != 0)
        $fclose(sdram_stats_fd);

    report_sdram_stats();
    if (chk_data) begin
        $display("SDRAM_DATA_CHECK p1 %0d/%0d bad, p0 %0d/%0d bad, p4 %0d/%0d bad",
                 chk_p1_bad, chk_p1_n, chk_p0_bad, chk_p0_n,
                 chk_p4_bad, chk_p4_n);
        if (chk_p1_bad != 0 || chk_p0_bad != 0 || chk_p4_bad != 0)
            $fatal(1, "SDRAM data path does not match the stub byte layout");
    end
    if (sdram_real && chip_violations != 0)
        $display("WARNING: %0d SDRAM protocol violations from rtl/mem/sdram.sv",
                 chip_violations);

    if (!ve_seen)
        $fatal(1, "video_enable never rose pc=%08x", debug_pc);
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
    if (bg_ack_while_obj_owns != 0)
        $fatal(1, "background renderer latched %0d acks it did not own",
               bg_ack_while_obj_owns);
    $display("PASS tb_ssv_frame_crc scenario=%s frames=%0d nonblack=%0d pc=%08x crc=%s overruns bg=%0d obj=%0d max_line_entries=%0d",
             scenario, post_ve_frames, post_ve_nonblack, debug_pc, crc_path,
             bg_overruns, obj_overruns, obj_max_line_entries);
    $finish;
end
endmodule
