`timescale 1ns/1ps

module tb_ssv_realrom_video;
logic clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;

logic rst, ce_cpu;
logic [1:0] ce_div;
logic sdr_p0_req, sdr_p0_ack;
logic [24:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p1_req, sdr_p1_ack;
logic [24:3] sdr_p1_addr;
logic [63:0] sdr_p1_dout;
logic sdr_wr_req, sdr_wr_ack;
logic [24:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;

byte main_rom [0:1048575];
byte sprite_rom [0:12582911];
logic [15:0] external_ram [0:196607];
string main_path, sprite_path;
integer main_fd, sprite_fd, main_count, sprite_count;
integer cycle_count, i;
integer max_cycles;
integer p1_transactions;
integer active_pixels;
integer nonblack_pixels;
integer plot_events;
integer nonzero_indices;
integer palette_writes;
integer irq_acks;
integer irq_low_cycles;
integer wram0_writes;
integer bg_overruns;
integer obj_overruns;
logic booted;
logic p0_seen, p1_seen;
logic [2:0] p0_ack_hold, p1_ack_hold;
logic [24:0] p0_byte_addr;
logic [24:0] p1_byte_addr;
logic [31:0] pc_ring [0:63];
logic [31:0] last_pc;
integer pc_ring_pos;
integer ring_i;
integer ext_index;
integer sprite_index;
integer packed_code;
integer packed_row;
integer raw_q0_index;
integer raw_q1_index;
integer nonzero_global_words;
integer nonzero_palette_entries;
integer first_nonzero_global;

ssv_core dut (
    .clk_sys(clk_sys), .rst(rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p1_req(sdr_p1_req), .sdr_p1_addr(sdr_p1_addr),
    .sdr_p1_dout(sdr_p1_dout), .sdr_p1_ack(sdr_p1_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hfffd),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

always_ff @(posedge clk_sys) begin
    if (rst) begin
        ce_div <= 2'd0;
        ce_cpu <= 1'b0;
    end
    else begin
        ce_cpu <= (ce_div == 2'd2);
        ce_div <= (ce_div == 2'd2) ? 2'd0 : ce_div + 1'd1;
    end
end

always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= 1'b0;
    sdr_p1_ack <= 1'b0;
    sdr_wr_ack <= 1'b0;

    if (rst) begin
        p0_seen <= 1'b0;
        p1_seen <= 1'b0;
        p0_ack_hold <= 3'd0;
        p1_ack_hold <= 3'd0;
        p1_transactions <= 0;
    end
    else begin
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1'b1;
            p0_byte_addr = {sdr_p0_addr, 1'b0};
            if (p0_byte_addr < 25'h0100000) begin
                sdr_p0_dout <= {
                    main_rom[p0_byte_addr + 1],
                    main_rom[p0_byte_addr]
                };
            end
            else if (p0_byte_addr >= 25'h1100000 &&
                     p0_byte_addr < 25'h1160000) begin
                ext_index = (p0_byte_addr - 25'h1100000) >> 1;
                sdr_p0_dout <= external_ram[ext_index];
            end
            else begin
                sdr_p0_dout <= 16'hffff;
            end
            p0_ack_hold <= 3'd2;
        end
        if (!sdr_p0_req)
            p0_seen <= 1'b0;
        if (p0_ack_hold != 0) begin
            p0_ack_hold <= p0_ack_hold - 1'd1;
            sdr_p0_ack <= 1'b1;
        end

        if (sdr_p1_req && !p1_seen) begin
            p1_seen <= 1'b1;
            p1_byte_addr = {sdr_p1_addr, 3'b000};
            sprite_index = p1_byte_addr - 25'h0100000;
            if (sprite_index >= 0 && sprite_index < 8388608) begin
                // Hardware download interleaves corresponding Q0/Q1 rows
                // into one 64-bit beat. Reconstruct that packed SDRAM view
                // from MAME's raw 4 MiB quarter layout.
                packed_code = sprite_index >> 6;
                packed_row = (sprite_index >> 3) & 7;
                raw_q0_index = packed_code * 32 + packed_row * 4;
                raw_q1_index = 4194304 + raw_q0_index;
                sdr_p1_dout <= {
                    sprite_rom[raw_q1_index + 3],
                    sprite_rom[raw_q1_index + 2],
                    sprite_rom[raw_q1_index + 1],
                    sprite_rom[raw_q1_index],
                    sprite_rom[raw_q0_index + 3],
                    sprite_rom[raw_q0_index + 2],
                    sprite_rom[raw_q0_index + 1],
                    sprite_rom[raw_q0_index]
                };
            end
            else if (sprite_index >= 0 &&
                     sprite_index + 7 < 12582912) begin
                sdr_p1_dout <= {
                    sprite_rom[sprite_index + 7],
                    sprite_rom[sprite_index + 6],
                    sprite_rom[sprite_index + 5],
                    sprite_rom[sprite_index + 4],
                    sprite_rom[sprite_index + 3],
                    sprite_rom[sprite_index + 2],
                    sprite_rom[sprite_index + 1],
                    sprite_rom[sprite_index]
                };
            end
            else begin
                sdr_p1_dout <= 64'd0;
            end
            p1_ack_hold <= 3'd2;
            p1_transactions <= p1_transactions + 1;
        end
        if (!sdr_p1_req)
            p1_seen <= 1'b0;
        if (p1_ack_hold != 0) begin
            p1_ack_hold <= p1_ack_hold - 1'd1;
            sdr_p1_ack <= 1'b1;
        end

        if (sdr_wr_req) begin
            if ({sdr_wr_addr, 1'b0} >= 25'h1100000 &&
                {sdr_wr_addr, 1'b0} < 25'h1160000) begin
                ext_index = ({sdr_wr_addr, 1'b0} - 25'h1100000) >> 1;
                if (sdr_wr_be[0])
                    external_ram[ext_index][7:0] <= sdr_wr_din[7:0];
                if (sdr_wr_be[1])
                    external_ram[ext_index][15:8] <= sdr_wr_din[15:8];
            end
            sdr_wr_ack <= 1'b1;
        end
    end
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        active_pixels <= 0;
        nonblack_pixels <= 0;
        plot_events <= 0;
        nonzero_indices <= 0;
        palette_writes <= 0;
        irq_acks <= 0;
        irq_low_cycles <= 0;
        wram0_writes <= 0;
        bg_overruns <= 0;
        obj_overruns <= 0;
    end
    else if (ce_pixel && !hb && !vb) begin
        active_pixels <= active_pixels + 1;
        if (rgb != 24'd0)
            nonblack_pixels <= nonblack_pixels + 1;
    end
    if (!rst && |dut.renderer_plot_we)
        plot_events <= plot_events + 1;
    if (!rst && dut.line_color != 15'd0)
        nonzero_indices <= nonzero_indices + 1;
    if (!rst && dut.m_req && dut.m_we && dut.sel_palette)
        palette_writes <= palette_writes + 1;
    if (!rst && dut.cpu_irq_ack)
        irq_acks <= irq_acks + 1;
    if (!rst && !dut.irq_n)
        irq_low_cycles <= irq_low_cycles + 1;
    if (!rst && dut.m_req && dut.m_we && dut.sel_wram && dut.a[15:1] == 15'd0)
        wram0_writes <= wram0_writes + 1;
    if (!rst && dut.renderer_line_start && dut.bg_busy)
        bg_overruns <= bg_overruns + 1;
    if (!rst && dut.renderer_line_start && dut.obj_busy) begin
        obj_overruns <= obj_overruns + 1;
        if (obj_overruns < 16)
            $display("OBJ_LATE y=%0d state=%0d entry=%0d/%0d tile=%0d/%0d",
                     dut.renderer_target_y, dut.sprite_renderer.state,
                     dut.sprite_renderer.cache_render_index,
                     dut.sprite_renderer.cache_count,
                     dut.sprite_renderer.sprite_tile_x,
                     dut.sprite_renderer.sprite_xnum);
    end
end

always_ff @(posedge clk_sys) begin
    if (rst) begin
        last_pc <= 32'hffff_ffff;
        pc_ring_pos <= 0;
    end
    else if (ce_cpu && debug_pc != last_pc) begin
        pc_ring[pc_ring_pos & 63] <= debug_pc;
        pc_ring_pos <= pc_ring_pos + 1;
        last_pc <= debug_pc;
    end
end

initial begin
    if (!$value$plusargs("MAINROM=%s", main_path))
        main_path = "sim_output/rom/maincpu.bin";
    if (!$value$plusargs("SPRROM=%s", sprite_path))
        sprite_path = "sim_output/rom/sprites.bin";
    if (!$value$plusargs("CYCLES=%d", max_cycles))
        max_cycles = 10000000;

    main_fd = $fopen(main_path, "rb");
    sprite_fd = $fopen(sprite_path, "rb");
    if (main_fd == 0 || sprite_fd == 0)
        $fatal(1, "cannot open Dyna Gear simulation images");
    main_count = $fread(main_rom, main_fd);
    sprite_count = $fread(sprite_rom, sprite_fd);
    $fclose(main_fd);
    $fclose(sprite_fd);
    if (main_count != 1048576 || sprite_count != 12582912)
        $fatal(1, "short ROM image read main=%0d sprite=%0d",
               main_count, sprite_count);

    for (i = 0; i < 196608; i = i + 1)
        external_ram[i] = 16'd0;

    rst = 1'b1;
    repeat (8) @(posedge clk_sys);
    rst = 1'b0;
    booted = 1'b0;

    for (cycle_count = 0; cycle_count < max_cycles; cycle_count = cycle_count + 1) begin
        @(posedge clk_sys);
        if (debug_pc == 32'h00f10120)
            booted = 1'b1;
    end

    $display("LAST PC TRACE:");
    $display("STATUS debug=%06x requested=%02x enabled=%02x irq_n=%b",
             debug_status, dut.irq_requested, dut.irq_enabled, dut.irq_n);

    for (ring_i = 0; ring_i < 64; ring_i = ring_i + 1)
        $display("%0d %08x", ring_i,
                 pc_ring[(pc_ring_pos + ring_i) & 63]);
    $display("SCROLL 0=%04x 1=%04x 3=%04x 53=%04x 56=%04x 58=%04x 59=%04x 61=%04x",
             dut.scroll[0], dut.scroll[1], dut.scroll[3], dut.scroll[53],
             dut.scroll[56], dut.scroll[58], dut.scroll[59], dut.scroll[61]);
    $display("V60 R0=%08x R1=%08x R2=%08x",
             dut.cpu.r[0], dut.cpu.r[1], dut.cpu.r[2]);
    $display("VIDEO p1=%0d plots=%0d indices=%0d palette_writes=%0d line=%04x",
             p1_transactions, plot_events, nonzero_indices,
             palette_writes, dut.line_color);
    $display("PAL0=%04x/%04x PAL1=%04x/%04x PAL65=%04x/%04x",
             dut.palette_ram.even_words.sim_peek(15'd0),
             dut.palette_ram.odd_words.sim_peek(15'd0),
             dut.palette_ram.even_words.sim_peek(15'd1),
             dut.palette_ram.odd_words.sim_peek(15'd1),
             dut.palette_ram.even_words.sim_peek(15'd65),
             dut.palette_ram.odd_words.sim_peek(15'd65));
    $display("IRQ ack=%0d low_cycles=%0d psw=%08x vector3=%0d wram0=%04x writes0=%0d",
             irq_acks, irq_low_cycles, dut.cpu.psw,
             dut.irqs.vectors[3],
             dut.work_ram.sim_peek(15'd0),
             wram0_writes);
    $display("CACHE ready=%0b busy=%0b overflow=%0b count=%0d render=%0d state=%0d",
             dut.obj_cache_ready, dut.obj_cache_busy,
             dut.obj_cache_overflow, dut.sprite_renderer.cache_count,
             dut.sprite_renderer.cache_render_index,
             dut.sprite_renderer.state);
    $display("OVERRUN bg=%0d obj=%0d",
             bg_overruns, obj_overruns);
    for (ring_i = 0; ring_i < 16; ring_i = ring_i + 1)
        $display("GLOBAL[%0d]=%04x", ring_i,
                 dut.sprite_ram.sim_peek(ring_i));
    for (ring_i = 16'h1000; ring_i < 16'h1010; ring_i = ring_i + 1)
        $display("LOCAL[%0h]=%04x", ring_i,
                 dut.sprite_ram.sim_peek(ring_i));
    nonzero_global_words = 0;
    nonzero_palette_entries = 0;
    first_nonzero_global = -1;
    for (ring_i = 0; ring_i < 4096; ring_i = ring_i + 1) begin
        if (dut.sprite_ram.sim_peek(ring_i) != 16'd0) begin
            nonzero_global_words = nonzero_global_words + 1;
            if (first_nonzero_global < 0)
                first_nonzero_global = ring_i;
        end
    end
    for (ring_i = 0; ring_i < 32768; ring_i = ring_i + 1)
        if ((dut.palette_ram.even_words.sim_peek(ring_i) != 16'd0) ||
            (dut.palette_ram.odd_words.sim_peek(ring_i) != 16'd0))
            nonzero_palette_entries = nonzero_palette_entries + 1;
    $display("MEMORY global_nonzero=%0d first=%0d palette_nonzero=%0d",
             nonzero_global_words, first_nonzero_global,
             nonzero_palette_entries);
    if (!booted)
        $fatal(1, "V60 did not reach Dyna Gear entry point");
    if (p1_transactions == 0)
        $fatal(1, "renderer issued no graphics SDRAM reads");
    if (active_pixels == 0 || nonblack_pixels == 0)
        $fatal(1, "no visible rendered pixels active=%0d nonblack=%0d",
               active_pixels, nonblack_pixels);
    if (debug_status[16])
        $fatal(1, "renderer missed a scanline deadline");

    $display("PASS tb_ssv_realrom_video p1=%0d active=%0d nonblack=%0d pc=%08x",
             p1_transactions, active_pixels, nonblack_pixels, debug_pc);
    $finish;
end
endmodule
