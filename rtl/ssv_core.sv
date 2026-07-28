// SPDX-License-Identifier: GPL-3.0-or-later
// Dyna Gear SSV board core: V60, memory map, inputs, IRQs and scanline video.
// ES5506 host/register file + voice PCM engine (bank-2 linear PCM for Dyna Gear).

module ssv_core (
    input              clk_sys,
    input              rst,
    input              ce_cpu,

    output logic       sdr_p0_req,
    output logic [24:1] sdr_p0_addr,
    input       [15:0] sdr_p0_dout,
    input              sdr_p0_ack,

    output logic       sdr_p1_req,
    output logic [24:3] sdr_p1_addr,
    input       [63:0] sdr_p1_dout,
    input              sdr_p1_ack,

    output logic       sdr_wr_req,
    output logic [24:1] sdr_wr_addr,
    output logic [15:0] sdr_wr_din,
    output logic [1:0] sdr_wr_be,
    input              sdr_wr_ack,

    // ES5506 sample fetches (16-bit SDRAM words)
    output logic       sdr_p4_req,
    output logic [24:1] sdr_p4_addr,
    input       [15:0] sdr_p4_dout,
    input              sdr_p4_ack,

    input       [15:0] in_dsw1,
    input       [15:0] in_dsw2,
    input       [15:0] in_p1,
    input       [15:0] in_p2,
    input       [15:0] in_system,
    input       [15:0] in_extra,

    output logic [23:0] rgb,
    output logic       ce_pixel,
    output logic       hs,
    output logic       vs,
    output logic       hb,
    output logic       vb,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    // Sticky one-shot: no $210000 kick for 180 frames (~3s @ 60 Hz / FBNeo).
    // Wrapper ORs into core reset (self-clears when rst returns).
    output logic       wdog_rst,
    output logic [31:0] debug_pc,
    output logic [23:0] debug_status
);

import ssv_pkg::*;

logic        c_req, c_we, c_ack;
logic [31:0] c_addr, c_wdata, c_rdata;
logic  [1:0] c_size;
logic        m_req, m_we, m_ack;
logic [23:1] m_addr;
logic [15:0] m_wdata, m_rdata;
logic  [1:0] m_be;
logic        cpu_irq_ack;
logic        irq_n;
logic  [7:0] irq_vector;
logic        cpu_halted;

// Dedicated wide instruction-fetch port (FAST_IFETCH): prefetch reads whole
// 8-byte ROM icache lines at clk_sys latency, bypassing the ce-gated 16-bit
// data adapter that otherwise bottlenecks fetch bandwidth.
wire        if_req;
wire [23:0] if_addr;
logic [63:0] if_data;
logic        if_served;
wire         if_ack = if_served;

// FAST_IFETCH defaults on; override at build time (+define+FAST_IFETCH_EN=1'b0)
// to A/B-test the wide fetch path against the legacy ce-gated adapter fetch.
`ifndef FAST_IFETCH_EN
 `define FAST_IFETCH_EN 1'b1
`endif

s32_v60 #(.START_PC(32'hFFFF_FFF0), .FAST_IFETCH(`FAST_IFETCH_EN)) cpu (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr),
    .bus_size(c_size), .bus_wdata(c_wdata),
    .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(cpu_irq_ack),
    .nmi_n(1'b1), .dbg_pc(debug_pc), .dbg_halted(cpu_halted)
);

s32_v60_bus bus_adapter (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
    .m_wdata(m_wdata), .m_be(m_be),
    .m_rdata(m_rdata), .m_ack(m_ack)
);

wire [23:0] a = {m_addr, 1'b0};
wire sel_wram    = (a <= 24'h00ffff);
wire sel_sprram  = (a >= 24'h100000) && (a <= 24'h13ffff);
wire sel_palette = (a >= 24'h140000) && (a <= 24'h15ffff);
wire sel_xram    = (a >= 24'h160000) && (a <= 24'h17ffff);
wire sel_scroll  = (a >= 24'h1c0000) && (a <= 24'h1c007f);
wire sel_io      = (a >= 24'h210000) && (a <= 24'h210011);
wire sel_irqvec  = (a >= 24'h230000) && (a <= 24'h230071);
wire sel_irqack  = (a >= 24'h240000) && (a <= 24'h240071);
wire sel_irqen   = (a >= 24'h260000) && (a <= 24'h260001);
wire sel_sound   = (a >= 24'h300000) && (a <= 24'h30007f);
wire sel_dynaram = (a >= 24'h400000) && (a <= 24'h43ffff);
wire sel_extra   = (a >= 24'h500008) && (a <= 24'h500009);
wire sel_rom     = (a >= 24'hf00000);
wire sel_extmem  = sel_xram | sel_dynaram;

(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] scroll [0:63];

wire [14:0] wram_addr = a[15:1];
wire [16:0] spr_addr  = a[17:1];
wire [15:0] pal_addr  = a[16:1];
wire  [5:0] scr_addr  = a[6:1];

wire [15:0] wram_q, spr_q, pal_q;
logic [15:0] scroll_q;
wire [16:0] renderer_spr_addr;
wire [16:0] bg_spr_addr, obj_spr_addr;
wire [255:0] sprite_offsets;
wire [511:0] tilemap_scrolls;
wire [15:0] spr_video_q;
wire [14:0] line_color;
wire [23:0] palette_video_rgb;
integer scroll_init_i;

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) work_ram (
    .clock_a(clk_sys), .address_a(wram_addr), .data_a(m_wdata),
    .byteena_a(m_be), .wren_a(m_req && m_we && sel_wram), .q_a(wram_q),
    .clock_b(clk_sys), .address_b(15'd0), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b()
);

s32_big_dpram #(.ADDR_WIDTH(17), .NUM_WORDS(131072)) sprite_ram (
    .clock_a(clk_sys), .address_a(spr_addr), .data_a(m_wdata),
    .byteena_a(m_be), .wren_a(m_req && m_we && sel_sprram), .q_a(spr_q),
    .clock_b(clk_sys), .address_b(renderer_spr_addr), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(spr_video_q)
);

ssv_palette_ram palette_ram (
    .clk(clk_sys), .cpu_addr(pal_addr), .cpu_data(m_wdata),
    .cpu_be(m_be), .cpu_we(m_req && m_we && sel_palette), .cpu_q(pal_q),
    .video_index(line_color), .video_rgb(palette_video_rgb)
);

always_ff @(posedge clk_sys) begin
    if (rst) begin
        scroll_q <= 16'd0;
        for (scroll_init_i = 0; scroll_init_i < 64;
             scroll_init_i = scroll_init_i + 1)
            scroll[scroll_init_i] <= 16'd0;
    end
    else begin
        scroll_q <= scroll[scr_addr];
    if (m_req && m_we && sel_scroll) begin
        if (m_be[0]) scroll[scr_addr][7:0]  <= m_wdata[7:0];
        if (m_be[1]) scroll[scr_addr][15:8] <= m_wdata[15:8];
    end
    end
end

genvar sprite_offset_i;
generate
    for (sprite_offset_i = 0; sprite_offset_i < 16; sprite_offset_i = sprite_offset_i + 1) begin : g_sprite_offsets
        assign sprite_offsets[sprite_offset_i * 16 +: 16] = scroll[32 + sprite_offset_i];
    end
endgenerate

genvar tilemap_scroll_i;
generate
    for (tilemap_scroll_i = 0; tilemap_scroll_i < 32;
         tilemap_scroll_i = tilemap_scroll_i + 1) begin : g_tilemap_scrolls
        assign tilemap_scrolls[tilemap_scroll_i * 16 +: 16] =
            scroll[tilemap_scroll_i];
    end
endgenerate

logic [8:0] hcnt, vcnt;
logic vblank_pulse;
logic video_enable;
ssv_video_timing timing (
    .clk(clk_sys), .rst(rst), .ce_pixel(ce_pixel),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hb), .vblank(vb),
    .hsync(hs), .vsync(vs), .vblank_pulse(vblank_pulse)
);

logic [8:0] renderer_target_y;
always_comb begin
    if (vcnt >= SSV_VTOTAL - 2)
        renderer_target_y = vcnt - (SSV_VTOTAL - 2);
    else
        renderer_target_y = vcnt + 2'd2;
end

// Swap completed lines as active display enters horizontal blank. The extra
// target_y==240 swap exposes the already-rendered final visible line; it must
// not launch another renderer. Lines 0 and 1 are prepared at vblank's tail.
wire line_buffer_start = video_enable && ce_pixel &&
                         (hcnt == SSV_HBSTART - 1'd1) &&
                         (renderer_target_y <= SSV_VBSTART) &&
                         !obj_cache_busy;
wire renderer_line_start = line_buffer_start &&
                           (renderer_target_y < SSV_VBSTART);

// Look ahead one address to cover the line-buffer/palette read pipeline.  The
// output observed at coordinate x is the value requested on the preceding
// pixel clock; x=0 is preloaded throughout horizontal blank.
wire [8:0] scan_x_ahead = (hcnt < SSV_HBSTART - 1'd1)
                          ? hcnt + 1'd1 : 9'd0;
wire line_clear_busy, line_clear_done;
wire [3:0] renderer_plot_we;
wire renderer_plot_shadow, renderer_shadow_4bit;
wire [35:0] renderer_plot_x;
wire [59:0] renderer_plot_color;
wire [31:0] renderer_plot_pen;
wire renderer_busy, renderer_done;
wire [3:0] bg_plot_we;
wire bg_plot_shadow, bg_shadow_4bit;
wire [35:0] bg_plot_x;
wire [59:0] bg_plot_color;
wire [31:0] bg_plot_pen;
wire [3:0] obj_plot_we;
wire obj_plot_shadow, obj_shadow_4bit;
wire [35:0] obj_plot_x;
wire [59:0] obj_plot_color;
wire [31:0] obj_plot_pen;
wire bg_rom_req, obj_rom_req;
wire [24:3] bg_rom_addr, obj_rom_addr;
wire bg_busy, bg_done, obj_busy, obj_done;
wire obj_cache_busy, obj_cache_ready, obj_cache_overflow;
logic renderer_overrun;

assign renderer_spr_addr = (obj_cache_busy || obj_busy) ? obj_spr_addr : bg_spr_addr;
assign sdr_p1_req = obj_busy ? obj_rom_req : bg_rom_req;
assign sdr_p1_addr = obj_busy ? obj_rom_addr : bg_rom_addr;
assign renderer_plot_we = obj_busy ? obj_plot_we : bg_plot_we;
assign renderer_plot_x = obj_busy ? obj_plot_x : bg_plot_x;
assign renderer_plot_color = obj_busy ? obj_plot_color : bg_plot_color;
assign renderer_plot_shadow = obj_busy ? obj_plot_shadow : bg_plot_shadow;
assign renderer_plot_pen = obj_busy ? obj_plot_pen : bg_plot_pen;
assign renderer_shadow_4bit = obj_busy ? obj_shadow_4bit : bg_shadow_4bit;
assign renderer_busy = bg_busy | obj_busy;
assign renderer_done = obj_done;

ssv_line_buffer4 line_buffer (
    .clk(clk_sys), .rst(rst), .line_start(line_buffer_start),
    .plot_we(renderer_plot_we), .plot_x(renderer_plot_x),
    .plot_color(renderer_plot_color), .plot_shadow(renderer_plot_shadow),
    .plot_pen(renderer_plot_pen), .shadow_4bit(renderer_shadow_4bit),
    .scan_x(scan_x_ahead), .scan_color(line_color),
    .clear_busy(line_clear_busy), .clear_done(line_clear_done)
);

ssv_bg_renderer background_renderer (
    .clk(clk_sys), .rst(rst), .line_start(renderer_line_start),
    .target_y(renderer_target_y), .clear_done(line_clear_done),
    .scroll_x(scroll[0]), .scroll_y(scroll[1]), .scroll_mode(scroll[3]),
    .global_y_base(scroll[56]), .global_y_adjust(scroll[53]),
    .flip_control(scroll[58]), .shadow_4bit(scroll[59][7]),
    .spr_addr(bg_spr_addr), .spr_data(spr_video_q),
    .rom_req(bg_rom_req), .rom_addr(bg_rom_addr),
    .rom_data(sdr_p1_dout), .rom_ack(sdr_p1_ack),
    .plot_we(bg_plot_we), .plot_x(bg_plot_x),
    .plot_color(bg_plot_color),
    .plot_shadow(bg_plot_shadow), .plot_pen(bg_plot_pen),
    .plot_shadow_4bit(bg_shadow_4bit),
    .busy(bg_busy), .done(bg_done)
);

ssv_cached_sprite_renderer sprite_renderer (
    .clk(clk_sys), .rst(rst),
    .cache_start(video_enable && vblank_pulse),
    .start(bg_done),
    .target_y(renderer_target_y),
    .local_control(scroll[59]), .flip_control(scroll[58]),
    .coordinate_control(scroll[61]),
    .global_y_base(scroll[56]), .global_y_adjust(scroll[53]),
    .sprite_offsets(sprite_offsets), .shadow_4bit(scroll[59][7]),
    .tilemap_scrolls(tilemap_scrolls),
    .spr_addr(obj_spr_addr), .spr_data(spr_video_q),
    .rom_req(obj_rom_req), .rom_addr(obj_rom_addr),
    .rom_data(sdr_p1_dout), .rom_ack(sdr_p1_ack),
    .plot_we(obj_plot_we), .plot_x(obj_plot_x),
    .plot_color(obj_plot_color),
    .plot_shadow(obj_plot_shadow), .plot_pen(obj_plot_pen),
    .plot_shadow_4bit(obj_shadow_4bit),
    .cache_busy(obj_cache_busy),
    .cache_ready(obj_cache_ready),
    .cache_overflow(obj_cache_overflow),
    .busy(obj_busy), .done(obj_done)
);

always_ff @(posedge clk_sys) begin
    if (rst)
        renderer_overrun <= 1'b0;
    else if ((line_buffer_start && renderer_busy) || obj_cache_overflow)
        // Line deadline miss, or descriptor/line-slot cache overflow.
        renderer_overrun <= 1'b1;
end

wire vector_we = m_req && m_we && sel_irqvec;
wire ack_we    = m_req && m_we && sel_irqack;
wire enable_we = m_req && m_we && sel_irqen;
wire [2:0] irq_reg_level = a[6:4];
logic [7:0] irq_requested, irq_enabled;

ssv_irq irqs (
    .clk(clk_sys), .rst(rst), .vblank_pulse(vblank_pulse),
    .vector_we(vector_we), .vector_level(irq_reg_level),
    .vector_data(m_wdata),
    .enable_we(enable_we), .enable_be(m_be), .enable_data(m_wdata),
    .ack_we(ack_we), .ack_level(irq_reg_level),
    .cpu_irq_ack(cpu_irq_ack), .irq_n(irq_n), .irq_vector(irq_vector),
    .requested(irq_requested), .enabled(irq_enabled)
);

always_ff @(posedge clk_sys) begin
    if (rst)
        video_enable <= 1'b0;
    else if (m_req && m_we && (a == 24'h21000e) && m_be[0])
        video_enable <= m_wdata[7];
end

// Line-buffer indices resolve through the live xRGB888 palette.
always_comb begin
    rgb = (!video_enable || hb || vb) ? 24'h000000 :
          palette_video_rgb;
end

function automatic [24:0] external_byte_addr(input [23:0] cpu_addr);
    if (cpu_addr >= 24'h400000)
        external_byte_addr = SDR_DYNA_RAM_BASE + (cpu_addr - 24'h400000);
    else
        external_byte_addr = SDR_XRAM_BASE + (cpu_addr - 24'h160000);
endfunction

wire [24:0] ext_phys_addr = external_byte_addr(a);
logic      ext_busy;
logic      ext_is_write;
logic [15:0] ext_read_data;
logic      ext_done;
logic      ext_p0_req_r;
logic [24:1] ext_p0_addr_r;

// Forward-declared: icache lookup suppresses re-arming a completed ROM read
// while the V60 bus still holds m_req (ack_r driven in the read-mux block).
logic        ack_r;
logic [15:0] read_mux;
logic        read_wait;

// ---------------------------------------------------------------------------
// V60 ROM fetch via SDRAM p0, through a small I/D cache (from s32):
//   32 lines x 8 bytes direct-mapped. Hit = 1 clk_sys; miss = 4 sequential
//   p0 word reads to fill the line. Reset (incl. ROM download) invalidates.
// p0 is shared with XRAM/Dyna RAM reads — icache fills have priority.
// ---------------------------------------------------------------------------
logic        rom_req_r;
logic [23:1] rom_addr_r;
// Fill words land in this register, and the completed 8-byte line is written
// to the array in one piece. A per-word bit-select write into the array made
// Quartus give up on memory inference (warning 10999), so the 32x64 array was
// built from 2048 flops plus three 64-bit 32:1 read muxes; whole-word writes
// map to LUTRAM like icache_tag already did.
logic [63:0] fill_buf;
(* ramstyle = "MLAB, no_rw_check" *) logic [63:0] icache_data [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [12:0] icache_tag  [0:31]; // addr[20:8]
logic [31:0] icache_valid;

// MAME: map(0xf00000, 0xffffff).rom().region("maincpu", 0) — top window
// mirrors the FIRST megabyte (reset stub at 0xFFFFF0 → maincpu 0xFFFF0).
wire [20:0] rom_byte_a = {1'b0, a[19:0]};
wire [4:0]  ic_line    = rom_byte_a[7:3];
wire [12:0] ic_tag     = rom_byte_a[20:8];
wire        ic_hit     = icache_valid[ic_line] && (icache_tag[ic_line] == ic_tag);
wire [63:0] ic_ldata   = icache_data[ic_line];
wire [15:0] ic_word    = ic_ldata[{rom_byte_a[2:1], 4'b0000} +: 16];

// Instruction-fetch lookup (whole 8-byte line). Same romhi mirroring as data.
wire        if_romhi   = (if_addr[23:20] == 4'hF);
wire [20:0] if_byte_a  = if_romhi ? {1'b0, if_addr[19:3], 3'b000}
                                  : {if_addr[20:3], 3'b000};
wire [4:0]  if_line_ix = if_byte_a[7:3];
wire [12:0] if_tag_ix  = if_byte_a[20:8];
wire        if_hit     = icache_valid[if_line_ix] &&
                         (icache_tag[if_line_ix] == if_tag_ix);
// Pre-align so byte 0 is the frontier byte (if_addr[2:0] = intra-line offset).
wire [63:0] if_hit_data = icache_data[if_line_ix] >> {if_addr[2:0], 3'b000};

logic [1:0]  fill_word;
logic        rom_filling;
logic        rom_ready;
logic [15:0] rom_word_r;
logic [4:0]  fill_line;
logic [12:0] fill_tag;
logic [17:0] fill_wbase;
logic        fill_isfetch;
logic [1:0]  fill_dsel;
logic [2:0]  fill_foff;
logic        fill_awaiting;   // waiting for rising ack of current fill word
logic        fill_need_req;   // issue next word req after stretched ack falls
logic        sdr_p0_ack_d;
wire         sdr_p0_ack_rise = sdr_p0_ack && !sdr_p0_ack_d;
// Complete line as of the final fill word: three buffered words plus the beat
// being acked this cycle.
wire [63:0]  fill_line_data = {sdr_p0_dout, fill_buf[47:0]};

wire icache_p0_busy = rom_filling || rom_req_r || (if_req && !if_served);

assign sdr_p0_req  = ext_p0_req_r | rom_req_r;
assign sdr_p0_addr = ext_p0_req_r ? ext_p0_addr_r
                                  : {5'b00000, rom_addr_r[19:1]};

always_ff @(posedge clk_sys) begin
    if (rst) begin
        rom_req_r     <= 1'b0;
        rom_filling   <= 1'b0;
        rom_ready     <= 1'b0;
        icache_valid  <= 32'h0;
        if_served     <= 1'b0;
        fill_awaiting <= 1'b0;
        fill_need_req <= 1'b0;
        sdr_p0_ack_d  <= 1'b0;
    end
    else begin
        sdr_p0_ack_d <= sdr_p0_ack;
        rom_req_r <= 1'b0;
        rom_ready <= 1'b0;
        // Re-arm the fetch port once the CPU drops if_req (consumed if_ack).
        if (!if_req)
            if_served <= 1'b0;

        if (rom_filling) begin
            // Wait for stretched ack to drop before the next rising-edge req
            // (TB models and the real SDRAM both need a fresh req edge).
            if (fill_need_req && !sdr_p0_ack && !ext_p0_req_r) begin
                fill_need_req <= 1'b0;
                fill_awaiting <= 1'b1;
                rom_req_r     <= 1'b1;
                rom_addr_r    <= {3'b000, fill_wbase, fill_word};
            end
            else if (fill_awaiting && sdr_p0_ack_rise && !ext_p0_req_r) begin
                fill_buf[{fill_word, 4'b0000} +: 16] <= sdr_p0_dout;
                fill_awaiting <= 1'b0;
                if (fill_word == 2'd3) begin
                    rom_filling <= 1'b0;
                    icache_data[fill_line]  <= fill_line_data;
                    icache_tag[fill_line]   <= fill_tag;
                    icache_valid[fill_line] <= 1'b1;
                    if (fill_isfetch) begin
                        if_data   <= fill_line_data >> {fill_foff, 3'b000};
                        if_served <= 1'b1;
                    end
                    else begin
                        rom_word_r <=
                            fill_line_data[{fill_dsel, 4'b0000} +: 16];
                        rom_ready  <= 1'b1;
                    end
                end
                else begin
                    fill_word     <= fill_word + 1'd1;
                    fill_need_req <= 1'b1;
                end
            end
        end
        // Instruction fetch has priority (common ROM access path).
        else if (if_req && !if_served && !ext_p0_req_r) begin
            if (if_hit) begin
                if_data   <= if_hit_data;
                if_served <= 1'b1;
            end
            else begin
                rom_filling   <= 1'b1;
                fill_isfetch  <= 1'b1;
                fill_foff     <= if_addr[2:0];
                fill_line     <= if_line_ix;
                fill_tag      <= if_tag_ix;
                fill_wbase    <= if_byte_a[20:3];
                fill_word     <= 2'd0;
                fill_awaiting <= 1'b1;
                fill_need_req <= 1'b0;
                rom_req_r     <= 1'b1;
                rom_addr_r    <= {3'b000, if_byte_a[20:3], 2'b00};
            end
        end
        // Data ROM read (constants/tables). See !ack_r note above.
        else if (m_req && !m_we && sel_rom && !rom_ready && !ack_r &&
                 !ext_p0_req_r) begin
            if (ic_hit) begin
                rom_word_r <= ic_word;
                rom_ready  <= 1'b1;
            end
            else begin
                rom_filling   <= 1'b1;
                fill_isfetch  <= 1'b0;
                fill_line     <= ic_line;
                fill_tag      <= ic_tag;
                fill_wbase    <= rom_byte_a[20:3];
                fill_dsel     <= rom_byte_a[2:1];
                fill_word     <= 2'd0;
                fill_awaiting <= 1'b1;
                fill_need_req <= 1'b0;
                rom_req_r     <= 1'b1;
                rom_addr_r    <= {3'b000, rom_byte_a[20:3], 2'b00};
            end
        end
    end
end

// XRAM / Dyna Gear RAM via SDRAM p0/wr (not cached). Yields to icache fills.
always_ff @(posedge clk_sys) begin
    if (rst) begin
        ext_busy      <= 1'b0;
        ext_is_write  <= 1'b0;
        ext_read_data <= 16'hffff;
        ext_done      <= 1'b0;
        ext_p0_req_r  <= 1'b0;
        ext_p0_addr_r <= '0;
        sdr_wr_req    <= 1'b0;
        sdr_wr_addr   <= '0;
        sdr_wr_din    <= '0;
        sdr_wr_be     <= 2'b00;
    end
    else begin
        ext_done <= 1'b0;
        if (sdr_p0_ack_rise && ext_p0_req_r) begin
            ext_p0_req_r  <= 1'b0;
            ext_busy      <= 1'b0;
            ext_read_data <= sdr_p0_dout;
            ext_done      <= 1'b1;
        end
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            ext_busy   <= 1'b0;
            ext_done   <= 1'b1;
        end

        // Do not start a new SDRAM beat while ack_r is still posted. With a
        // sparse ce_cpu the CPU may leave m_req high for several clk_sys
        // cycles after ext_done; without this guard the TB/hardware can
        // issue a spurious second fetch and corrupt the outstanding read.
        // Also wait for the ROM icache to release p0.
        if (m_req && sel_extmem && !ext_busy && !ext_done && !ack_r &&
            !icache_p0_busy) begin
            if (m_we) begin
                sdr_wr_req   <= 1'b1;
                sdr_wr_addr  <= ext_phys_addr[24:1];
                sdr_wr_din   <= m_wdata;
                sdr_wr_be    <= m_be;
                ext_is_write <= 1'b1;
                ext_busy     <= 1'b1;
            end
            else begin
                ext_p0_req_r  <= 1'b1;
                ext_p0_addr_r <= ext_phys_addr[24:1];
                ext_is_write  <= 1'b0;
                ext_busy      <= 1'b1;
            end
        end
    end
end
wire [7:0] sound_rdata;
// ES5506 MLAB banks need 2 wait cycles: steal addr, then latch q → read_latch.
logic [1:0] sound_rd_cnt;
wire sound_host_we = m_req && m_we && sel_sound && !ack_r && m_be[0];
wire sound_host_re = m_req && !m_we && sel_sound &&
                     !ack_r && (sound_rd_cnt == 2'd0);
wire sound_irq_n;
wire sound_commit;
wire [6:0] sound_commit_page;
wire [3:0] sound_commit_reg;
wire [31:0] sound_commit_data;
wire [4:0] sound_active_voices;
wire [4:0] eng_voice;
wire [15:0] eng_cr;
wire        eng_cr_valid;
wire [16:0] eng_fc;
wire [15:0] eng_lvol, eng_rvol, eng_k1, eng_k2;
wire [7:0]  eng_lvramp, eng_rvramp;
wire [8:0]  eng_ecount, eng_k1ramp, eng_k2ramp;
wire [31:0] eng_start, eng_end, eng_accum;
wire [17:0] eng_o4n1, eng_o3n1, eng_o3n2, eng_o2n1, eng_o2n2, eng_o1n1;
wire        eng_wr_accum, eng_wr_cr, eng_wr_filt, eng_wr_env;
wire [31:0] eng_accum_w;
wire [15:0] eng_cr_w, eng_lvol_w, eng_rvol_w, eng_k1_w, eng_k2_w;
wire [17:0] eng_o4n1_w, eng_o3n1_w, eng_o3n2_w, eng_o2n1_w, eng_o2n2_w, eng_o1n1_w;
wire [8:0]  eng_ecount_w;
wire        eng_irq_set;
wire [4:0]  eng_irq_voice;
wire        sound_sample_tick, sound_underrun;

// Share the CPU enable so voice and V60 stay phase-aligned (saves a second
// fractional accumulator and matches board 16 MHz OTTO / V60 clocking).
wire ce_snd = ce_cpu;

ssv_es5506_regs sound_registers (
    .clk(clk_sys),
    .rst(rst),
    .host_we(sound_host_we),
    .host_re(sound_host_re),
    .host_addr(a[6:1]),
    .host_wdata(m_wdata[7:0]),
    .host_rdata(sound_rdata),
    .par_data(10'd0),
    .irq_set(eng_irq_set),
    .irq_voice(eng_irq_voice),
    .irq_n(sound_irq_n),
    .current_page(),
    .active_voices(sound_active_voices),
    .mode(),
    .word_clock_start(),
    .word_clock_end(),
    .lr_clock_end(),
    .commit(sound_commit),
    .commit_page(sound_commit_page),
    .commit_reg(sound_commit_reg),
    .commit_data(sound_commit_data),
    .eng_voice(eng_voice),
    .eng_cr(eng_cr), .eng_cr_valid(eng_cr_valid),
    .eng_fc(eng_fc),
    .eng_lvol(eng_lvol), .eng_lvramp(eng_lvramp),
    .eng_rvol(eng_rvol), .eng_rvramp(eng_rvramp),
    .eng_ecount(eng_ecount),
    .eng_k1(eng_k1), .eng_k1ramp(eng_k1ramp),
    .eng_k2(eng_k2), .eng_k2ramp(eng_k2ramp),
    .eng_start(eng_start), .eng_end(eng_end), .eng_accum(eng_accum),
    .eng_o4n1(eng_o4n1), .eng_o3n1(eng_o3n1), .eng_o3n2(eng_o3n2),
    .eng_o2n1(eng_o2n1), .eng_o2n2(eng_o2n2), .eng_o1n1(eng_o1n1),
    .eng_wr_accum(eng_wr_accum), .eng_accum_w(eng_accum_w),
    .eng_wr_cr(eng_wr_cr), .eng_cr_w(eng_cr_w),
    .eng_wr_filt(eng_wr_filt),
    .eng_o4n1_w(eng_o4n1_w), .eng_o3n1_w(eng_o3n1_w), .eng_o3n2_w(eng_o3n2_w),
    .eng_o2n1_w(eng_o2n1_w), .eng_o2n2_w(eng_o2n2_w), .eng_o1n1_w(eng_o1n1_w),
    .eng_wr_env(eng_wr_env),
    .eng_lvol_w(eng_lvol_w), .eng_rvol_w(eng_rvol_w),
    .eng_k1_w(eng_k1_w), .eng_k2_w(eng_k2_w), .eng_ecount_w(eng_ecount_w)
);

ssv_es5506_voice sound_voices (
    .clk(clk_sys), .rst(rst), .ce(ce_snd),
    .active_voices(sound_active_voices),
    .eng_voice(eng_voice),
    .eng_cr(eng_cr), .eng_cr_valid(eng_cr_valid),
    .eng_fc(eng_fc),
    .eng_lvol(eng_lvol), .eng_lvramp(eng_lvramp),
    .eng_rvol(eng_rvol), .eng_rvramp(eng_rvramp),
    .eng_ecount(eng_ecount),
    .eng_k1(eng_k1), .eng_k1ramp(eng_k1ramp),
    .eng_k2(eng_k2), .eng_k2ramp(eng_k2ramp),
    .eng_start(eng_start), .eng_end(eng_end), .eng_accum(eng_accum),
    .eng_o4n1(eng_o4n1), .eng_o3n1(eng_o3n1), .eng_o3n2(eng_o3n2),
    .eng_o2n1(eng_o2n1), .eng_o2n2(eng_o2n2), .eng_o1n1(eng_o1n1),
    .eng_wr_accum(eng_wr_accum), .eng_accum_w(eng_accum_w),
    .eng_wr_cr(eng_wr_cr), .eng_cr_w(eng_cr_w),
    .eng_wr_filt(eng_wr_filt),
    .eng_o4n1_w(eng_o4n1_w), .eng_o3n1_w(eng_o3n1_w), .eng_o3n2_w(eng_o3n2_w),
    .eng_o2n1_w(eng_o2n1_w), .eng_o2n2_w(eng_o2n2_w), .eng_o1n1_w(eng_o1n1_w),
    .eng_wr_env(eng_wr_env),
    .eng_lvol_w(eng_lvol_w), .eng_rvol_w(eng_rvol_w),
    .eng_k1_w(eng_k1_w), .eng_k2_w(eng_k2_w), .eng_ecount_w(eng_ecount_w),
    .eng_irq_set(eng_irq_set), .eng_irq_voice(eng_irq_voice),
    .sdr_req(sdr_p4_req), .sdr_addr(sdr_p4_addr),
    .sdr_dout(sdr_p4_dout), .sdr_ack(sdr_p4_ack),
    .audio_l(audio_l), .audio_r(audio_r),
    .sample_tick(sound_sample_tick), .underrun(sound_underrun)
);

assign m_rdata = read_mux;
assign m_ack   = ack_r;

// Watchdog: FBNeo / board ~3s @ 60 Hz = 180 frames without $210000 read.
// Count only after video_enable so the long pre-lockout RAM clear cannot
// self-reset the core before the game starts servicing the port.
logic       ack_r_d;
logic [8:0] wdog_frame_cnt;
wire        wdog_kick = m_req && !m_we && sel_io && (a[4:1] == 4'h0) &&
                        ack_r && !ack_r_d;

always_ff @(posedge clk_sys) begin
    if (rst) begin
        wdog_frame_cnt <= 9'd0;
        wdog_rst       <= 1'b0;
        ack_r_d        <= 1'b0;
    end
    else begin
        ack_r_d <= ack_r;
        if (wdog_kick)
            wdog_frame_cnt <= 9'd0;
        else if (vblank_pulse && video_enable) begin
            if (wdog_frame_cnt >= 9'd180)
                wdog_rst <= 1'b1;
            else
                wdog_frame_cnt <= wdog_frame_cnt + 9'd1;
        end
    end
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ack_r        <= 1'b0;
        read_wait    <= 1'b0;
        sound_rd_cnt <= 2'd0;
        read_mux     <= 16'hffff;
    end
    else if (!m_req) begin
        ack_r        <= 1'b0;
        read_wait    <= 1'b0;
        sound_rd_cnt <= 2'd0;
    end
    else if (!ack_r) begin
        // ROM reads complete via the icache (rom_ready). ROM writes are nops
        // (MAME image is read-only) but must still ack or a push into 0xFxxxxx
        // hangs forever.
        if (sel_rom && !m_we) begin
            if (rom_ready) begin
                read_mux <= rom_word_r;
                ack_r    <= 1'b1;
            end
        end
        else if (sel_extmem) begin
            if (ext_done) begin
                read_mux <= ext_is_write ? 16'hffff : ext_read_data;
                ack_r    <= 1'b1;
            end
        end
        else if (m_we) begin
            ack_r <= 1'b1;
        end
        else if (sel_sound) begin
            if (sound_rd_cnt < 2'd2)
                sound_rd_cnt <= sound_rd_cnt + 2'd1;
            else begin
                sound_rd_cnt <= 2'd0;
                ack_r        <= 1'b1;
                read_mux     <= {8'h00, sound_rdata};
            end
        end
        else if (!read_wait) begin
            read_wait <= 1'b1;
        end
        else begin
            read_wait <= 1'b0;
            ack_r <= 1'b1;
            unique case (1'b1)
                sel_wram:    read_mux <= wram_q;
                sel_sprram:  read_mux <= spr_q;
                sel_palette: read_mux <= pal_q;
                sel_scroll:  read_mux <= (a == 24'h1c0000)
                    ? {2'b00, vb, vb, hb, 11'b0} : scroll_q;
                sel_io: begin
                    unique case (a[4:1])
                        // MAME survarts/dynagear: watchdog_timer reset16_r.
                        // Read kicks the 180-frame board timeout (wdog_rst).
                        4'h0: read_mux <= 16'h0000;
                        4'h1: read_mux <= in_dsw1;
                        4'h2: read_mux <= in_dsw2;
                        4'h4: read_mux <= in_p1;
                        4'h5: read_mux <= in_p2;
                        4'h6: read_mux <= in_system;
                        default: read_mux <= 16'hffff;
                    endcase
                end
                sel_extra: read_mux <= in_extra;
                default:   read_mux <= 16'hffff;
            endcase
        end
    end
end

always_comb debug_status = {
    cpu_halted, video_enable, irq_n, vb, hb, ext_busy, ext_done, renderer_overrun,
    irq_requested, irq_enabled
};

endmodule
