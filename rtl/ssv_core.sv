// SPDX-License-Identifier: GPL-3.0-or-later
// Initial Dyna Gear SSV board core: V60, memory map, inputs, IRQs and CRT.
// Sprite drawing and ES5506 synthesis are separate bring-up milestones.

module ssv_core (
    input              clk_sys,
    input              rst,
    input              ce_cpu,

    output logic       sdr_p0_req,
    output logic [24:1] sdr_p0_addr,
    input       [15:0] sdr_p0_dout,
    input              sdr_p0_ack,

    output logic       sdr_wr_req,
    output logic [24:1] sdr_wr_addr,
    output logic [15:0] sdr_wr_din,
    output logic [1:0] sdr_wr_be,
    input              sdr_wr_ack,

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

s32_v60 #(.START_PC(32'hFFFF_FFF0)) cpu (
    .clk(clk_sys), .ce(ce_cpu), .rst(rst),
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

logic [15:0] scroll [0:63];

wire [14:0] wram_addr = a[15:1];
wire [16:0] spr_addr  = a[17:1] - 17'h08000;
wire [15:0] pal_addr  = a[16:1] - 16'h0a000;
wire  [5:0] scr_addr  = a[6:1];

wire [15:0] wram_q, spr_q, pal_q;
logic [15:0] scroll_q;
wire [15:0] spr_video_q;
wire [15:0] palette_video_q;

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) work_ram (
    .clock_a(clk_sys), .address_a(wram_addr), .data_a(m_wdata),
    .byteena_a(m_be), .wren_a(m_req && m_we && sel_wram), .q_a(wram_q),
    .clock_b(clk_sys), .address_b(15'd0), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b()
);

s32_big_dpram #(.ADDR_WIDTH(17), .NUM_WORDS(131072)) sprite_ram (
    .clock_a(clk_sys), .address_a(spr_addr), .data_a(m_wdata),
    .byteena_a(m_be), .wren_a(m_req && m_we && sel_sprram), .q_a(spr_q),
    .clock_b(clk_sys), .address_b(17'd0), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(spr_video_q)
);

s32_big_dpram #(.ADDR_WIDTH(16), .NUM_WORDS(65536)) palette_ram (
    .clock_a(clk_sys), .address_a(pal_addr), .data_a(m_wdata),
    .byteena_a(m_be), .wren_a(m_req && m_we && sel_palette), .q_a(pal_q),
    .clock_b(clk_sys), .address_b(16'd0), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(palette_video_q)
);

always_ff @(posedge clk_sys) begin
    scroll_q <= scroll[scr_addr];
    if (m_req && m_we && sel_scroll) begin
        if (m_be[0]) scroll[scr_addr][7:0]  <= m_wdata[7:0];
        if (m_be[1]) scroll[scr_addr][15:8] <= m_wdata[15:8];
    end
end

logic [8:0] hcnt, vcnt;
logic vblank_pulse;
ssv_video_timing timing (
    .clk(clk_sys), .rst(rst), .ce_pixel(ce_pixel),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hb), .vblank(vb),
    .hsync(hs), .vsync(vs), .vblank_pulse(vblank_pulse)
);

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

logic video_enable;
always_ff @(posedge clk_sys) begin
    if (rst)
        video_enable <= 1'b1;
    else if (m_req && m_we && (a == 24'h21000e) && m_be[0])
        video_enable <= m_wdata[7];
end

// Backdrop colour is palette entry zero until the sprite pipeline is wired.
wire [15:0] backdrop = palette_video_q;

wire [7:0] red8   = {backdrop[7:0]};
wire [7:0] green8 = {backdrop[15:8]};
// MAME uses xRGB888 words in palette RAM. This provisional path exposes the
// two stored bytes for bring-up; the final renderer will use the full 32-bit
// palette representation discovered from hardware/MAME traces.
always_comb begin
    rgb     = (!video_enable || hb || vb) ? 24'h000000 :
              {red8, green8, 8'h00};
    audio_l = 16'sd0;
    audio_r = 16'sd0;
end

function automatic [24:0] external_byte_addr(input [23:0] cpu_addr);
    if (cpu_addr >= 24'h400000)
        external_byte_addr = SDR_DYNA_RAM_BASE + (cpu_addr - 24'h400000);
    else
        external_byte_addr = SDR_XRAM_BASE + (cpu_addr - 24'h160000);
endfunction

wire [24:0] ext_phys_addr = external_byte_addr(a);
wire [19:0] rom_offset = a[19:0];
logic      ext_busy;
logic      ext_is_write;
logic [15:0] ext_read_data;
logic      ext_done;

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ext_busy     <= 1'b0;
        ext_is_write <= 1'b0;
        ext_read_data <= 16'hffff;
        ext_done     <= 1'b0;
        sdr_p0_req   <= 1'b0;
        sdr_p0_addr  <= '0;
        sdr_wr_req   <= 1'b0;
        sdr_wr_addr  <= '0;
        sdr_wr_din   <= '0;
        sdr_wr_be    <= 2'b00;
    end
    else begin
        ext_done <= 1'b0;
        if (sdr_p0_ack) begin
            sdr_p0_req   <= 1'b0;
            ext_busy     <= 1'b0;
            ext_read_data <= sdr_p0_dout;
            ext_done     <= 1'b1;
        end
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            ext_busy   <= 1'b0;
            ext_done   <= 1'b1;
        end

        if (m_req && !ext_busy && !ext_done) begin
            if (!m_we && sel_rom) begin
                sdr_p0_req  <= 1'b1;
                sdr_p0_addr <= {5'b00000, rom_offset[19:1]};
                ext_busy    <= 1'b1;
                ext_is_write <= 1'b0;
            end
            else if (sel_extmem) begin
                if (m_we) begin
                    sdr_wr_req  <= 1'b1;
                    sdr_wr_addr <= ext_phys_addr[24:1];
                    sdr_wr_din  <= m_wdata;
                    sdr_wr_be   <= m_be;
                    ext_is_write <= 1'b1;
                end
                else begin
                    sdr_p0_req  <= 1'b1;
                    sdr_p0_addr <= ext_phys_addr[24:1];
                    ext_is_write <= 1'b0;
                end
                ext_busy <= 1'b1;
            end
        end
    end
end

logic [15:0] read_mux;
logic ack_r;
logic read_wait;
assign m_rdata = read_mux;
assign m_ack   = ack_r;

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ack_r     <= 1'b0;
        read_wait <= 1'b0;
        read_mux  <= 16'hffff;
    end
    else if (!m_req) begin
        ack_r     <= 1'b0;
        read_wait <= 1'b0;
    end
    else if (!ack_r) begin
        if (sel_rom || sel_extmem) begin
            if (ext_done) begin
                read_mux <= ext_is_write ? 16'hffff : ext_read_data;
                ack_r    <= 1'b1;
            end
        end
        else if (m_we) begin
            ack_r <= 1'b1;
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
                        4'h0: read_mux <= 16'hffff; // watchdog
                        4'h1: read_mux <= in_dsw1;
                        4'h2: read_mux <= in_dsw2;
                        4'h4: read_mux <= in_p1;
                        4'h5: read_mux <= in_p2;
                        4'h6: read_mux <= in_system;
                        default: read_mux <= 16'hffff;
                    endcase
                end
                sel_sound: read_mux <= 16'h00ff;
                sel_extra: read_mux <= in_extra;
                default:   read_mux <= 16'hffff;
            endcase
        end
    end
end

always_comb debug_status = {
    cpu_halted, video_enable, irq_n, vb, hb, ext_busy, ext_done, 1'b0,
    irq_requested, irq_enabled
};

endmodule
