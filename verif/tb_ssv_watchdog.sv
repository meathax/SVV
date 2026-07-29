`timescale 1ns/1ps
// Board watchdog: $210000 read kicks; 180 frames without kick → wdog_rst.

module tb_ssv_watchdog #(
    // Which watchdog the board has. Per game, and not cosmetic:
    //   1 read-kick   dynagear, survarts, twineag2, ultrax
    //   2 write-kick  vasara, vasara2
    //   0 no device   drifto94, stmblade
    // A core that always read-kicks would never be kicked by vasara and would
    // reset drifto94 forever, so all three modes are exercised here.
    parameter int WDOG_MODE = 1
) ;

// Layout comes from ssv_pkg, not a local copy: five benches used to
// restate 0x0100000/0x1100000/0x1160000 and a divergence between them and
// the RTL is the classic "wrong ROM load offset" fake bug.
import ssv_pkg::*;
logic clk_sys = 0;
always #5 clk_sys = ~clk_sys;

logic boot_rst = 1;
logic wdog_rst;

ssv_pkg::ssv_cfg_t cfg_under_test;
initial begin
    cfg_under_test = ssv_pkg::cfg_dynagear();
    cfg_under_test.wdog_mode = 2'(WDOG_MODE);
end
// Hold off OR-into-rst while observing the sticky trip (else it self-clears
// on the next edge before the TB can sample it).
logic feed_wdog_to_rst = 1'b0;
wire  rst = boot_rst | (wdog_rst && feed_wdog_to_rst);
logic ce_cpu = 1;

logic sdr_p0_req, sdr_p0_ack;
logic [SDR_AW:1] sdr_p0_addr;
logic [15:0] sdr_p0_dout;
logic sdr_p2_req, sdr_p2_ack;
logic [SDR_AW:4] sdr_p2_addr;
logic [127:0] sdr_p2_dout;
logic sdr_wr_req, sdr_wr_ack;
logic [SDR_AW:1] sdr_wr_addr;
logic [15:0] sdr_wr_din;
logic [1:0] sdr_wr_be;
logic sdr_p4_req, sdr_p4_ack;
logic [SDR_AW:1] sdr_p4_addr;
logic [15:0] sdr_p4_dout;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb;
logic signed [15:0] audio_l, audio_r;
logic [31:0] debug_pc;
logic [23:0] debug_status;

integer i, cycles;

ssv_core dut (
    .cfg(cfg_under_test),
    .clk_sys(clk_sys), .rst(rst), .ce_cpu(ce_cpu),
    .sdr_p0_req(sdr_p0_req), .sdr_p0_addr(sdr_p0_addr),
    .sdr_p0_dout(sdr_p0_dout), .sdr_p0_ack(sdr_p0_ack),
    .sdr_p2_req(sdr_p2_req), .sdr_p2_addr(sdr_p2_addr),
    .sdr_p2_dout(sdr_p2_dout), .sdr_p2_ack(sdr_p2_ack),
    .sdr_wr_req(sdr_wr_req), .sdr_wr_addr(sdr_wr_addr),
    .sdr_wr_din(sdr_wr_din), .sdr_wr_be(sdr_wr_be),
    .sdr_wr_ack(sdr_wr_ack),
    .sdr_p4_req(sdr_p4_req), .sdr_p4_addr(sdr_p4_addr),
    .sdr_p4_dout(sdr_p4_dout), .sdr_p4_ack(sdr_p4_ack),
    .in_dsw1(16'hffff), .in_dsw2(16'hffff),
    .in_p1(16'hffff), .in_p2(16'hffff),
    .in_system(16'hffff), .in_extra(16'hffff),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .wdog_rst(wdog_rst),
    .debug_pc(debug_pc), .debug_status(debug_status)
);

always_ff @(posedge clk_sys) begin
    sdr_p0_ack <= sdr_p0_req;
    sdr_p2_ack <= sdr_p2_req;
    sdr_wr_ack <= sdr_wr_req;
    sdr_p4_ack <= sdr_p4_req;
    sdr_p0_dout <= 16'hffff;
    sdr_p2_dout <= 128'd0;
    sdr_p4_dout <= 16'd0;
end

task automatic pulse_vblank;
    force dut.vblank_pulse = 1'b1;
    @(posedge clk_sys);
    force dut.vblank_pulse = 1'b0;
    @(posedge clk_sys);
endtask

task automatic kick_watchdog(input bit do_write = 1'b0);
    force dut.m_req = 1'b1;
    force dut.m_we = do_write;
    force dut.m_addr = 23'h108000; // byte 0x210000
    force dut.m_be = 2'b11;
    for (cycles = 0; cycles < 16; cycles = cycles + 1) begin
        @(posedge clk_sys);
        if (dut.m_ack)
            break;
    end
    if (!dut.m_ack)
        $fatal(1, "watchdog read did not ack");
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_be;
    @(posedge clk_sys);
endtask

initial begin
    repeat (4) @(posedge clk_sys);
    boot_rst = 0;
    repeat (4) @(posedge clk_sys);

    // Pre-VE: frames must not trip (RAM-clear soak).
    for (i = 0; i < 200; i = i + 1)
        pulse_vblank();
    if (wdog_rst)
        $fatal(1, "wdog_rst asserted before video_enable");

    force dut.video_enable = 1'b1;
    @(posedge clk_sys);

    // Phase 1: withhold kicks → trip at frame 180 after VE.
    for (i = 0; i < 180; i = i + 1) begin
        if (wdog_rst)
            $fatal(1, "wdog_rst early at frame %0d", i);
        pulse_vblank();
    end
    pulse_vblank(); // frame count reaches 180 -> fire (unless there is no device)
    if (WDOG_MODE == 0) begin
        // drifto94 / stmblade have no watchdog device at all. An
        // unconditional counter here would reset them forever.
        if (wdog_rst)
            $fatal(1, "wdog_rst asserted with WDOG_MODE=0 (no watchdog device)");
        $display("PASS tb_ssv_watchdog mode0 never resets");
        $finish;
    end
    // $finish does not abandon the current process immediately, so everything
    // below must be explicitly skipped for mode 0 rather than relying on it.
    if (WDOG_MODE != 0 && !wdog_rst)
        $fatal(1, "wdog_rst did not assert after 180 idle frames");
    // Wrapper OR into rst self-clears the sticky after rst is applied.
    feed_wdog_to_rst = 1'b1;
    @(posedge clk_sys);
    @(posedge clk_sys);
    if (wdog_rst)
        $fatal(1, "wdog_rst stuck after rst clear");
    $display("PASS tb_ssv_watchdog timeout trips at 180 frames");

    // Phase 2: kick every frame → never trips for 200 frames.
    release dut.video_enable;
    feed_wdog_to_rst = 1'b1;
    boot_rst = 1;
    repeat (4) @(posedge clk_sys);
    boot_rst = 0;
    repeat (4) @(posedge clk_sys);
    force dut.video_enable = 1'b1;
    @(posedge clk_sys);
    // Kick in THIS mode's direction: read for mode 1, write for mode 2.
    for (i = 0; i < 200; i = i + 1) begin
        kick_watchdog(WDOG_MODE == 2);
        pulse_vblank();
        if (wdog_rst)
            $fatal(1, "wdog_rst while kicked every frame at %0d", i);
    end
    release dut.video_enable;
    $display("PASS tb_ssv_watchdog mode%0d kicked path stays clear", WDOG_MODE);

    // Phase 3: the WRONG direction must NOT kick. This is the half that
    // matters -- a core that read-kicks regardless would pass phase 2 on
    // vasara's write-kick board and then reset in play.
    //
    // wdog_rst must stay sticky here: with feed_wdog_to_rst still set from
    // phase 1 it feeds rst, which clears it again before it can be sampled.
    feed_wdog_to_rst = 1'b0;
    boot_rst = 1;
    repeat (4) @(posedge clk_sys);
    boot_rst = 0;
    repeat (4) @(posedge clk_sys);
    force dut.video_enable = 1'b1;
    @(posedge clk_sys);
    for (i = 0; i < 190; i = i + 1) begin
        kick_watchdog(WDOG_MODE != 2);   // deliberately the wrong direction
        pulse_vblank();
    end
    if (!wdog_rst)
        $fatal(1, "mode%0d: wrong-direction access kicked the watchdog", WDOG_MODE);
    release dut.video_enable;
    $display("PASS tb_ssv_watchdog mode%0d wrong-direction access does not kick",
             WDOG_MODE);
    $finish;
end
endmodule
