`timescale 1ns/1ps
// Real-ROM frame CRC dump + attract/coin soak for Dyna Gear G1/G2/G3.
// Plusargs:
//   +MAINROM= +SPRROM= +FRAME_CRC=path +FRAMES=N +SOAK_FRAMES=N
//   +SCENARIO=attract_idle|coin_start_p1
//   +DUMP_FRAME_DIAG (IRQ/list/scroll/pal snapshots at vb-edge)
//   +USE_FRAC_CE (default on) uses ssv_tb_ce_cpu

module tb_ssv_frame_crc;
`include "ssv_tb_crc32.svh"

logic clk_sys = 1'b0;
always #5 clk_sys = ~clk_sys;

logic rst, ce_cpu;
logic sdr_p0_req, sdr_p0_ack;
logic [24:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p1_req, sdr_p1_ack;
logic [24:3] sdr_p1_addr;
logic [63:0] sdr_p1_dout;
logic sdr_wr_req, sdr_wr_ack;
logic sdr_p4_req, sdr_p4_ack;
logic [24:1] sdr_p4_addr;
logic [15:0] sdr_p4_dout;
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
logic [15:0] external_ram [0:196607];

string main_path, sprite_path, crc_path, scenario;
integer main_fd, sprite_fd, crc_fd;
integer main_count, sprite_count, cycle_count, max_cycles, i;
integer p1_transactions;
integer frame_idx, post_ve_frames, max_frames, soak_frames;
integer active_pixels, nonblack_pixels, post_ve_nonblack;
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
integer dump_x, dump_y, dump_count;
logic dump_pixels, dump_frame_diag;
string irq_schedule_path;
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

// Sticky multi-cycle ack (covers CE gaps from fractional enable).
always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= 1'b0;
    sdr_p1_ack <= 1'b0;
    sdr_wr_ack <= 1'b0;
    sdr_p4_ack <= 1'b0;
    if (rst) begin
        p0_seen <= 1'b0; p1_seen <= 1'b0;
        wr_seen <= 1'b0; p4_seen <= 1'b0;
        p0_hold <= 4'd0; p1_hold <= 4'd0;
        wr_hold <= 4'd0; p4_hold <= 4'd0;
        p1_transactions <= 0;
    end else begin
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1'b1;
            p0_byte_addr = {sdr_p0_addr, 1'b0};
            if (p0_byte_addr < 25'h0100000)
                sdr_p0_dout <= {main_rom[p0_byte_addr+1], main_rom[p0_byte_addr]};
            else if (p0_byte_addr >= 25'h1100000 && p0_byte_addr < 25'h1160000) begin
                ext_index = (p0_byte_addr - 25'h1100000) >> 1;
                sdr_p0_dout <= external_ram[ext_index];
            end else
                sdr_p0_dout <= 16'hffff;
            p0_hold <= 4'd2;
        end
        if (p0_hold != 0) begin
            sdr_p0_ack <= 1'b1;
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
                sdr_p1_dout <= {
                    sprite_rom[raw_q1_index+3], sprite_rom[raw_q1_index+2],
                    sprite_rom[raw_q1_index+1], sprite_rom[raw_q1_index],
                    sprite_rom[raw_q0_index+3], sprite_rom[raw_q0_index+2],
                    sprite_rom[raw_q0_index+1], sprite_rom[raw_q0_index]
                };
            end else if (sprite_index >= 0 && sprite_index + 7 < 12582912) begin
                sdr_p1_dout <= {
                    sprite_rom[sprite_index+7], sprite_rom[sprite_index+6],
                    sprite_rom[sprite_index+5], sprite_rom[sprite_index+4],
                    sprite_rom[sprite_index+3], sprite_rom[sprite_index+2],
                    sprite_rom[sprite_index+1], sprite_rom[sprite_index]
                };
            end else
                sdr_p1_dout <= 64'd0;
            p1_hold <= 4'd2;
            p1_transactions <= p1_transactions + 1;
        end
        if (p1_hold != 0) begin
            sdr_p1_ack <= 1'b1;
            p1_hold <= p1_hold - 1'd1;
        end else if (!sdr_p1_req)
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
            sdr_wr_ack <= 1'b1;
            wr_hold <= wr_hold - 1'd1;
        end else if (!sdr_wr_req)
            wr_seen <= 1'b0;

        if (sdr_p4_req && !p4_seen) begin
            p4_seen <= 1'b1;
            sdr_p4_dout <= 16'd0;
            p4_hold <= 4'd2;
        end
        if (p4_hold != 0) begin
            sdr_p4_ack <= 1'b1;
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
    if (scenario == "coin_start_p1") begin
        if (f >= 30 && f < 34) in_system = 16'hfffe; // COIN1
        if (f >= 60 && f < 64) in_p1 = 16'hff7f;     // START
        if (f >= 90 && f < 100) in_p1 = 16'hfffe;    // UP
        if (f >= 100 && f < 110) in_p1 = 16'hffef;   // B1
    end
endtask

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
        bg_overruns <= 0;
        obj_overruns <= 0;
        stuck <= 0;
        last_pc <= 32'hffffffff;
        irq_entries_post_ve <= 0;
        vb_pulses_post_ve <= 0;
    end else begin
        if (debug_status[22])
            ve_seen <= 1'b1;

        if (ce_pixel && !hb && !vb && debug_status[22]) begin
            active_pixels <= active_pixels + 1;
            if (rgb != 24'd0) begin
                nonblack_pixels <= nonblack_pixels + 1;
                if (ve_seen)
                    post_ve_nonblack <= post_ve_nonblack + 1;
            end
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
            end
        end

        // Emit + reset on entering vblank so the first active pixel is included.
        if (ve_seen && !vb_d && vb) begin
            if (crc_fd != 0 && post_ve_frames < max_frames && px_count != 0) begin
                $fdisplay(crc_fd, "FRAME %0d %08x %08x",
                          post_ve_frames,
                          ~idx_crc,
                          ~rgb_crc);
                $fflush(crc_fd);
                if (post_ve_frames == 0)
                    $display("FRAME0 px=%0d idx=%08x rgb=%08x",
                             px_count, ~idx_crc, ~rgb_crc);
                if (dump_frame_diag && post_ve_frames < 4) begin
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
                    last_vb_retire = retire_count;
                end
                apply_inputs(post_ve_frames);
                post_ve_frames <= post_ve_frames + 1;
                frame_idx <= frame_idx + 1;
            end
            idx_crc <= 32'hffffffff;
            rgb_crc <= 32'hffffffff;
            px_count <= 0;
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

        if (dut.renderer_line_start && dut.bg_busy)
            bg_overruns <= bg_overruns + 1;
        if (dut.renderer_line_start && dut.obj_busy)
            obj_overruns <= obj_overruns + 1;

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
    if (!$value$plusargs("SCENARIO=%s", scenario))
        scenario = "attract_idle";
    if (!$value$plusargs("FRAMES=%d", max_frames))
        max_frames = 120;
    if (!$value$plusargs("SOAK_FRAMES=%d", soak_frames))
        soak_frames = 30;
    if (!$value$plusargs("CYCLES=%d", max_cycles))
        max_cycles = 200000000;
    dump_pixels = $test$plusargs("DUMP_PIXELS");
    dump_frame_diag = $test$plusargs("DUMP_FRAME_DIAG");
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

    if (!ve_seen)
        $fatal(1, "video_enable never rose pc=%08x", debug_pc);
    if (post_ve_frames < soak_frames)
        $fatal(1, "soak frames=%0d need=%0d", post_ve_frames, soak_frames);
    if (bg_overruns != 0 || obj_overruns != 0)
        $fatal(1, "renderer overrun bg=%0d obj=%0d", bg_overruns, obj_overruns);
    if (post_ve_nonblack < 1000)
        $fatal(1, "post-VE nonblack too low: %0d", post_ve_nonblack);
    if (debug_status[16])
        $fatal(1, "renderer_overrun sticky set");

    $display("PASS tb_ssv_frame_crc scenario=%s frames=%0d nonblack=%0d pc=%08x crc=%s",
             scenario, post_ve_frames, post_ve_nonblack, debug_pc, crc_path);
    $finish;
end
endmodule
