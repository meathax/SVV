`timescale 1ns/1ps
// Real-ROM boot watch: memory clear takes tens of millions of cycles, then
// lockout bit7 must raise video_enable. Also guards the ROM-write ack hole
// that freezes the CPU at an exception PC with ext_busy=0.

module tb_ssv_hang_watch;

// Layout comes from ssv_pkg, not a local copy: five benches used to
// restate 0x0100000/0x1100000/0x1160000 and a divergence between them and
// the RTL is the classic "wrong ROM load offset" fake bug.
import ssv_pkg::*;
logic clk_sys = 0;
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
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;
byte main_rom [0:1048575];
logic [15:0] external_ram [0:196607]; // 0x1100000..0x115ffff
integer fd, n, cycles;
logic p0_seen, wr_seen;
logic [3:0] p0_hold, wr_hold;
logic [31:0] last_pc;
integer stuck;
integer ve_rise;
logic ve_d;
integer f3_hits;
integer lockout_writes;
integer rom_writes;
logic [SDR_AW:0] p0_byte;
integer post_ve_frames;
logic vs_d;
integer soak_frames;
integer post_ve_nonblack;
integer bg_overruns, obj_overruns;

ssv_tb_ce_cpu u_ce (.clk(clk_sys), .rst(rst), .ce_cpu(ce_cpu));

ssv_core dut (
    .cfg(ssv_pkg::cfg_dynagear()),
    .clk_sys(clk_sys), .rst(rst), .cold_rst(rst), .ce_cpu(ce_cpu),
    .watchdog_hold(1'b0),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hfffd),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff), .in_mahjong_rows(24'hffffff),
    .in_coord_x(12'h800), .in_coord_y(12'h800), .in_paddle(8'h80), .in_ball_switch(1'b0),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= 0;
    sdr_p2_ack <= 0;
    sdr_wr_ack <= 0;
    sdr_p4_ack <= 0;
    sdr_p2_dout <= 128'd0;
    if (rst) begin
        p0_seen <= 0;
        wr_seen <= 0;
        p0_hold <= 0;
        wr_hold <= 0;
    end
    else begin
        if (sdr_p0_req && !p0_seen) begin
            p0_seen <= 1;
            p0_byte = {sdr_p0_addr, 1'b0};
            if (p0_byte >= SDR_XRAM_BASE && p0_byte < SDR_SAMPLES_BASE)
                sdr_p0_dout <= external_ram[(p0_byte - SDR_XRAM_BASE) >> 1];
            else if (p0_byte < SDR_XRAM_BASE)
                sdr_p0_dout <= {
                    main_rom[p0_byte[19:0] + 1],
                    main_rom[p0_byte[19:0]]
                };
            else
                sdr_p0_dout <= 16'hffff;
            p0_hold <= 4'd2;
        end
        if (p0_hold != 0) begin
            sdr_p0_ack <= 1;
            p0_hold <= p0_hold - 1'd1;
        end else if (!sdr_p0_req)
            p0_seen <= 0;

        if (sdr_wr_req && !wr_seen) begin
            wr_seen <= 1;
            p0_byte = {sdr_wr_addr, 1'b0};
            if (p0_byte >= SDR_XRAM_BASE && p0_byte < SDR_SAMPLES_BASE) begin
                if (sdr_wr_be[0])
                    external_ram[(p0_byte - SDR_XRAM_BASE) >> 1][7:0] <=
                        sdr_wr_din[7:0];
                if (sdr_wr_be[1])
                    external_ram[(p0_byte - SDR_XRAM_BASE) >> 1][15:8] <=
                        sdr_wr_din[15:8];
            end
            wr_hold <= 4'd2;
        end
        if (wr_hold != 0) begin
            sdr_wr_ack <= 1;
            wr_hold <= wr_hold - 1'd1;
        end else if (!sdr_wr_req)
            wr_seen <= 0;

        if (sdr_p2_req)
            sdr_p2_ack <= 1;
        if (sdr_p4_req) begin
            sdr_p4_dout <= 16'd0;
            sdr_p4_ack <= 1'b1;
        end
    end
end

initial begin
    fd = $fopen("sim_output/rom/maincpu.bin", "rb");
    if (!fd)
        $fatal(1, "cannot open sim_output/rom/maincpu.bin");
    n = $fread(main_rom, fd);
    $fclose(fd);
    $display("ROM bytes=%0d head=%02x%02x @1f3d0=%02x%02x", n,
             main_rom[0], main_rom[1],
             main_rom[32'h1f3d0], main_rom[32'h1f3d1]);

    if (!$value$plusargs("SOAK_FRAMES=%d", soak_frames))
        soak_frames = 30;

    rst = 1;
    last_pc = 0;
    stuck = 0;
    ve_rise = -1;
    ve_d = 0;
    vs_d = 1;
    f3_hits = 0;
    lockout_writes = 0;
    rom_writes = 0;
    post_ve_frames = 0;
    post_ve_nonblack = 0;
    bg_overruns = 0;
    obj_overruns = 0;
    for (n = 0; n < 196608; n = n + 1)
        external_ram[n] = 16'd0;
    repeat (8) @(posedge clk_sys);
    rst = 0;

    for (cycles = 0; cycles < 200000000; cycles = cycles + 1) begin
        @(posedge clk_sys);
        if (dut.m_req && dut.m_we && dut.sel_rom && !dut.m_ack) begin
            rom_writes = rom_writes + 1;
            if (rom_writes <= 8)
                $display("ROM_WR cyc=%0d pc=%08x a=%06x",
                         cycles, debug_pc, dut.a);
        end
        if (dut.m_req && dut.m_we && (dut.a == 24'h21000e) && !dut.m_ack) begin
            lockout_writes = lockout_writes + 1;
            if (lockout_writes <= 4)
                $display("LOCKOUT cyc=%0d pc=%08x data=%04x",
                         cycles, debug_pc, dut.m_wdata);
        end
        if (debug_status[22] && !ve_d) begin
            ve_rise = cycles;
            $display("VE_RISE cyc=%0d pc=%08x", cycles, debug_pc);
        end
        ve_d = debug_status[22];

        if (debug_status[22] && !vs_d && vs)
            post_ve_frames = post_ve_frames + 1;
        vs_d = vs;
        if (debug_status[22] && ce_pixel && !hb && !vb && rgb != 24'd0)
            post_ve_nonblack = post_ve_nonblack + 1;
        if (dut.renderer_line_start && dut.bg_busy)
            bg_overruns = bg_overruns + 1;
        if (dut.renderer_line_start && dut.obj_busy)
            obj_overruns = obj_overruns + 1;

        if (debug_pc == 32'h00F1F3D6) begin
            f3_hits = f3_hits + 1;
            if (f3_hits == 1)
                $display("HIT_F3D6 cyc=%0d ve=%b busy=%b",
                         cycles, debug_status[22], dut.ext_busy);
            if (f3_hits == 20000) begin
                $fatal(1, "frozen in DIP string at F3D6 cyc=%0d rom_wr=%0d",
                       cycles, rom_writes);
            end
        end
        else
            f3_hits = 0;

        if (ce_cpu && (debug_pc == last_pc))
            stuck = stuck + 1;
        else
            stuck = 0;
        if (ce_cpu)
            last_pc = debug_pc;
        if (stuck > 500000)
            $fatal(1, "STUCK pc=%08x cyc=%0d a=%06x we=%b ack=%b busy=%b",
                   debug_pc, cycles, dut.a, dut.m_we, dut.m_ack, dut.ext_busy);

        if (debug_status[22] && (ve_rise >= 0) &&
            post_ve_frames >= soak_frames)
            break;
    end
    if (!(debug_status[22] && (ve_rise >= 0)))
        $fatal(1, "TIMEOUT pc=%08x ve=%b ve_rise=%0d lockouts=%0d",
               debug_pc, debug_status[22], ve_rise, lockout_writes);
    if (post_ve_frames < soak_frames)
        $fatal(1, "soak frames=%0d need=%0d", post_ve_frames, soak_frames);
    if (bg_overruns != 0 || obj_overruns != 0)
        $fatal(1, "renderer overrun bg=%0d obj=%0d", bg_overruns, obj_overruns);
    // This TB has no sprite ROM; nonblack pixels are checked in tb_ssv_frame_crc.
    $display("PASS tb_ssv_hang_watch pc=%08x cyc=%0d frames=%0d lockouts=%0d rom_wr=%0d nonblack=%0d",
             debug_pc, cycles, post_ve_frames, lockout_writes, rom_writes,
             post_ve_nonblack);
    $finish;
end
endmodule
