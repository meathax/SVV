`timescale 1ns/1ps
// Board watchdog: exact master-clock timeout with descriptor read/write strobes.

module tb_ssv_watchdog #(
    // Which watchdog the board has. Per game, and not cosmetic:
    //   1 read-kick   dynagear, survarts, twineag2, ultrax
    //   2 write-kick  vasara, vasara2
    //   0 no device   drifto94, stmblade
    // A core that always read-kicks would never be kicked by vasara and would
    // reset drifto94 forever, so all three modes are exercised here.
    parameter int WDOG_MODE = 1,
    parameter int TEST_TIMEOUT_CYCLES = 256
) ;

// Layout comes from ssv_pkg, not a local copy: five benches used to
// restate 0x0100000/0x1100000/0x1160000 and a divergence between them and
// the RTL is the classic "wrong ROM load offset" fake bug.
import ssv_pkg::*;
logic clk_sys = 0;
always #5 clk_sys = ~clk_sys;

logic boot_rst = 1;
logic wdog_rst;
logic watchdog_hold = 1'b0;

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
logic [15:0] input_system = 16'hffff;
logic [1:0] coin_lockout;

integer i, cycles, accepted_kicks;

ssv_core #(.WDOG_TIMEOUT_CYCLES(TEST_TIMEOUT_CYCLES)) dut (
    .cfg(cfg_under_test),
    .clk_sys(clk_sys), .rst(rst), .cold_rst(boot_rst), .ce_cpu(ce_cpu),
    .watchdog_hold(watchdog_hold),
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
    .in_system(input_system), .in_extra(16'hffff), .in_mahjong_rows(24'hffffff),
    .in_coord_x(12'h800), .in_coord_y(12'h800), .in_paddle(8'h80), .in_ball_switch(1'b0),
    .rgb(rgb), .ce_pixel(ce_pixel), .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .audio_l(audio_l), .audio_r(audio_r),
    .wdog_rst(wdog_rst),
    .coin_lockout(coin_lockout)
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

initial accepted_kicks = 0;
always @(posedge clk_sys)
    if (dut.wdog_kick)
        accepted_kicks = accepted_kicks + 1;

task automatic kick_watchdog(input bit do_write = 1'b0,
                             input bit expect_kick = 1'b1);
    integer kicks_before;
    kicks_before = accepted_kicks;
    // Claim the bus from an idle edge. The real V60 remains live in this
    // integration test, so merely releasing a previous force can expose one
    // of its requests and leave ack_r/read_mux posted for the next helper.
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    force dut.m_we = do_write;
    force dut.m_addr = 23'h108000; // byte 0x210000
    force dut.m_be = 2'b11;
    force dut.m_req = 1'b1;
    for (cycles = 0; cycles < 16; cycles = cycles + 1) begin
        @(posedge clk_sys); #1;
        if (dut.m_ack)
            break;
    end
    if (!dut.m_ack)
        $fatal(1, "watchdog read did not ack");
    // Keep the V60 request asserted through the accepted ACK edge. The core's
    // watchdog/lockout strobes intentionally sample ack_r && !ack_r_d on this
    // following clock, just as the real CPU holds its transaction through ACK.
    @(posedge clk_sys); #1;
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    if (dut.m_ack)
        $fatal(1, "watchdog helper did not clear posted ACK");
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_be;
    repeat (1) @(posedge clk_sys); #1;
    if (accepted_kicks != kicks_before + (expect_kick ? 1 : 0))
        $fatal(1, "watchdog accepted-kick count changed by %0d, expected %0d",
               accepted_kicks - kicks_before, expect_kick ? 1 : 0);
endtask

task automatic write_lockout(input logic [7:0] data);
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    force dut.m_we = 1'b1;
    force dut.m_addr = 23'h108007; // byte 0x21000e
    force dut.m_be = 2'b01;
    force dut.m_wdata = {8'h00, data};
    force dut.m_req = 1'b1;
    for (cycles = 0; cycles < 16; cycles = cycles + 1) begin
        @(posedge clk_sys); #1;
        if (dut.m_ack)
            break;
    end
    if (!dut.m_ack)
        $fatal(1, "lockout write did not ack");
    @(posedge clk_sys); #1;
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    if (dut.m_ack)
        $fatal(1, "lockout helper did not clear posted ACK");
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_be;
    release dut.m_wdata;
endtask

task automatic bus_read(input logic [23:0] byte_addr,
                        output logic [15:0] data,
                        input integer hold_ack_cycles = 0);
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    force dut.m_we = 1'b0;
    force dut.m_addr = byte_addr[23:1];
    force dut.m_be = 2'b11;
    force dut.m_req = 1'b1;
    for (cycles = 0; cycles < 16; cycles = cycles + 1) begin
        @(posedge clk_sys); #1;
        if (dut.m_ack)
            break;
    end
    if (!dut.m_ack)
        $fatal(1, "read %06x did not ack", byte_addr);
    data = dut.m_rdata;
    repeat (hold_ack_cycles) begin
        @(posedge clk_sys); #1;
        if (!dut.m_ack)
            $fatal(1, "read %06x dropped ack while request held", byte_addr);
    end
    // Hold through the accepted ACK edge so read-side effects (watchdog and
    // Drift/Storm random cadence) observe exactly one completed transaction.
    @(posedge clk_sys); #1;
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    if (dut.m_ack)
        $fatal(1, "read %06x did not clear posted ACK", byte_addr);
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_be;
endtask

task automatic bus_write_word(input logic [23:0] byte_addr,
                              input logic [15:0] data);
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    force dut.m_we = 1'b1;
    force dut.m_addr = byte_addr[23:1];
    force dut.m_be = 2'b11;
    force dut.m_wdata = data;
    force dut.m_req = 1'b1;
    for (cycles = 0; cycles < 16; cycles = cycles + 1) begin
        @(posedge clk_sys); #1;
        if (dut.m_ack)
            break;
    end
    if (!dut.m_ack)
        $fatal(1, "write %06x did not ack", byte_addr);
    // Register writes commit on the accepted ACK edge, one clock after ack_r
    // is posted. Keep ownership until that edge, then force an idle cleanup.
    @(posedge clk_sys); #1;
    force dut.m_req = 1'b0;
    @(posedge clk_sys); #1;
    if (dut.m_ack)
        $fatal(1, "write %06x did not clear posted ACK", byte_addr);
    release dut.m_req;
    release dut.m_we;
    release dut.m_addr;
    release dut.m_be;
    release dut.m_wdata;
endtask

logic [15:0] read0, read1;

initial begin : watchdog_test
    repeat (4) @(posedge clk_sys);
    // Change reset away from the sampling edge. Deasserting in the same
    // active region as a posedge races the DUT always_ff blocks and makes an
    // exact-N-cycle timeout appear one cycle early in Verilator.
    @(negedge clk_sys);
    boot_rst = 0;
    #1;
    if (dut.video_enable !== 1'b1)
        $fatal(1, "MAME power-on video enable was not set");

    // Phase 1: timeout starts immediately when reset is released. It is
    // independent of video_enable, VBLANK, and frame rate.
    for (i = 0; i < TEST_TIMEOUT_CYCLES - 1; i = i + 1) begin
        @(posedge clk_sys); #1;
        if (wdog_rst)
            $fatal(1, "wdog_rst early at master cycle %0d", i + 1);
    end
    @(posedge clk_sys); #1;
    if (WDOG_MODE == 0) begin
        if (wdog_rst)
            $fatal(1, "wdog_rst asserted with WDOG_MODE=0 (no watchdog device)");
        repeat (TEST_TIMEOUT_CYCLES) @(posedge clk_sys);
        if (wdog_rst)
            $fatal(1, "mode0 watchdog appeared after an additional timeout");
        $display("PASS tb_ssv_watchdog mode0 never resets cycles=%0d",
                 TEST_TIMEOUT_CYCLES * 2);
        $finish;
        disable watchdog_test;
    end
    if (!wdog_rst)
        $fatal(1, "wdog_rst did not assert at exact master-cycle timeout");
    // Wrapper OR into rst self-clears the sticky after rst is applied.
    feed_wdog_to_rst = 1'b1;
    @(posedge clk_sys);
    @(posedge clk_sys);
    if (wdog_rst)
        $fatal(1, "wdog_rst stuck after rst clear");
    $display("PASS tb_ssv_watchdog timeout trips at %0d master cycles",
             TEST_TIMEOUT_CYCLES);

    // A MiSTer host pause stops the V60, so it cannot perform the watchdog
    // access. Holding must preserve elapsed time rather than grant a fresh
    // interval, and it must remain safe for longer than a complete timeout.
    feed_wdog_to_rst = 1'b0;
    boot_rst = 1;
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    boot_rst = 0;
    repeat (TEST_TIMEOUT_CYCLES / 4) begin
        @(posedge clk_sys); #1;
    end
    @(negedge clk_sys);
    watchdog_hold = 1'b1;
    repeat (TEST_TIMEOUT_CYCLES + 8) begin
        @(posedge clk_sys); #1;
        if (wdog_rst)
            $fatal(1, "watchdog advanced while host pause was held");
    end
    @(negedge clk_sys);
    watchdog_hold = 1'b0;
    for (i = 0; i < TEST_TIMEOUT_CYCLES -
         (TEST_TIMEOUT_CYCLES / 4) - 1; i = i + 1) begin
        @(posedge clk_sys); #1;
        if (wdog_rst)
            $fatal(1, "watchdog tripped early after host pause at %0d", i + 1);
    end
    @(posedge clk_sys); #1;
    if (!wdog_rst)
        $fatal(1, "watchdog pause did not preserve elapsed interval");
    feed_wdog_to_rst = 1'b1;
    repeat (2) @(posedge clk_sys); #1;
    if (wdog_rst)
        $fatal(1, "watchdog pause trip did not self-clear through reset");
    $display("PASS tb_ssv_watchdog host pause freezes elapsed interval");

    // Phase 2: correct-direction strobes restart the complete interval.
    feed_wdog_to_rst = 1'b1;
    boot_rst = 1;
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    boot_rst = 0;
    repeat (4) @(posedge clk_sys);
    for (i = 0; i < 4; i = i + 1) begin
        kick_watchdog(WDOG_MODE == 2);
        repeat (TEST_TIMEOUT_CYCLES / 2) begin
            @(posedge clk_sys); #1;
        end
        if (wdog_rst)
            $fatal(1, "wdog_rst between correct kicks at period %0d", i);
    end
    $display("PASS tb_ssv_watchdog mode%0d kicked path stays clear", WDOG_MODE);

    // MAME's V60 address space defaults to zero, while mapped active-low
    // controls remain high when idle. Keep those two contracts distinct.
    kick_watchdog(WDOG_MODE == 2);
    bus_read(24'h210006, read0);
    if (read0 !== 16'h0000)
        $fatal(1, "unmapped I/O returned %04x, expected zero", read0);
    bus_read(24'h210008, read0);
    if (read0 !== 16'h00ff)
        $fatal(1, "mapped idle P1 returned %04x, expected 00ff", read0);
    bus_read(24'h210002, read0);
    if (read0 !== 16'h00ff)
        $fatal(1, "mapped idle DSW1 returned %04x, expected 00ff", read0);
    bus_read(24'h210004, read0);
    if (read0 !== 16'h00ff)
        $fatal(1, "mapped idle DSW2 returned %04x, expected 00ff", read0);
    bus_read(24'h21000a, read0);
    if (read0 !== 16'h00ff)
        $fatal(1, "mapped idle P2 returned %04x, expected 00ff", read0);
    bus_read(24'h21000c, read0);
    if (read0 !== 16'h00ff)
        $fatal(1, "mapped idle SYSTEM returned %04x, expected 00ff", read0);
    bus_read(24'h500008, read0);
    if (read0 !== 16'hffff)
        $fatal(1, "Dyna decoded-idle input window returned %04x", read0);
    cfg_under_test.extra_input_mode = 2'd0;
    bus_read(24'h500008, read0);
    if (read0 !== 16'h0000)
        $fatal(1, "disabled optional input window returned %04x", read0);
    cfg_under_test.extra_input_mode = 2'd1;
    $display("PASS tb_ssv_watchdog mapped-idle and open-bus values");

    // Drift/Storm random reads advance exactly once per completed handler
    // transaction, even when the V60 holds its request through/after ACK.
    kick_watchdog(WDOG_MODE == 2);
    cfg_under_test.has_drifto_unknown = 1'b1;
    bus_read(24'h510000, read0, 3);
    bus_read(24'h520000, read1, 3);
    if (read0 !== 16'h0001 || read1 !== 16'h0002)
        $fatal(1, "random transaction cadence %04x/%04x expected 0001/0002",
               read0, read1);
    cfg_under_test.has_drifto_unknown = 1'b0;
    bus_read(24'h510000, read0);
    if (read0 !== 16'h0000)
        $fatal(1, "disabled random window returned %04x", read0);
    $display("PASS tb_ssv_watchdog random reads advance once per transaction");

    // MAME derives the live top/left clip from $62/$64 and $6a/$6c. Cover an
    // interior value and both clamp sides so descriptor geometry and CRTC
    // windowing cannot silently compete.
    kick_watchdog(WDOG_MODE == 2);
    bus_write_word(24'h1c0062, 16'd0);
    bus_write_word(24'h1c0064, 16'd163);
    if (dut.crtc_min_x !== 9'd10)
        $fatal(1, "CRTC x interior=%0d expected 10", dut.crtc_min_x);
    bus_write_word(24'h1c0064, 16'd200);
    if (dut.crtc_min_x !== 9'd0)
        $fatal(1, "CRTC x low clamp=%0d", dut.crtc_min_x);
    bus_write_word(24'h1c0062, 16'd1);
    bus_write_word(24'h1c0064, 16'd0);
    if (dut.crtc_min_x !== 9'd336)
        $fatal(1, "CRTC x high clamp=%0d", dut.crtc_min_x);
    kick_watchdog(WDOG_MODE == 2);
    bus_write_word(24'h1c006a, 16'd0);
    bus_write_word(24'h1c006c, 16'd229);
    if (dut.crtc_min_y !== 9'd11)
        $fatal(1, "CRTC y interior=%0d expected 11", dut.crtc_min_y);
    bus_write_word(24'h1c006c, 16'd300);
    if (dut.crtc_min_y !== 9'd0)
        $fatal(1, "CRTC y low clamp=%0d", dut.crtc_min_y);
    bus_write_word(24'h1c006a, 16'd1);
    bus_write_word(24'h1c006c, 16'd0);
    if (dut.crtc_min_y !== 9'd240)
        $fatal(1, "CRTC y high clamp=%0d", dut.crtc_min_y);
    $display("PASS tb_ssv_watchdog live CRTC clip and geometry clamps");

    // Shared cabinet I/O on the same register. Reset is unlocked; normal
    // polarity locks coin 0 when data bit 1 is low, while the inverted maps
    // lock it when bit 1 is high. A locked active-low coin is forced released.
    kick_watchdog(WDOG_MODE == 2);
    input_system = 16'hfffe; // coin 0 pressed
    if (coin_lockout !== 2'b00)
        $fatal(1, "coin slots not unlocked after reset");
    cfg_under_test.lockout_inverted = 1'b0;
    write_lockout(8'h03);
    if (coin_lockout[0] || dut.in_system_gated[0] !== 1'b0)
        $fatal(1, "normal unlocked coin input was not live");
    write_lockout(8'h01);
    if (!coin_lockout[0] || dut.in_system_gated[0] !== 1'b1)
        $fatal(1, "normal lockout did not force active-low coin released");

    cfg_under_test.lockout_inverted = 1'b1;
    write_lockout(8'h03);
    if (!coin_lockout[0])
        $fatal(1, "inverted lockout did not lock on high bit");
    write_lockout(8'h01);
    if (coin_lockout[0] || dut.in_system_gated[0] !== 1'b0)
        $fatal(1, "inverted lockout did not unlock/live-gate coin");
    input_system = 16'hffff;
    $display("PASS tb_ssv_watchdog shared lockout semantics");

    // MAME machine_reset() clears only pending IRQ causes. The board's
    // scroll/CRTC RAM, video-enable latch, IRQ mask/vector RAM and cabinet
    // bookkeeping survive the watchdog reset driven into rst; only boot_rst
    // is cold. Program representative state, issue a focused soft reset, and
    // require exact retention without a game-name conditional.
    cfg_under_test.lockout_inverted = 1'b0;
    // Program a non-default lockout state alongside retained board state.
    write_lockout(8'h0c);              // video off, both slots locked
    bus_write_word(24'h230030, 16'h0006); // IRQ level-3 vector
    bus_write_word(24'h260000, 16'h0008); // enable level 3
    force dut.vblank_pulse = 1'b1;
    @(posedge clk_sys); #1;
    release dut.vblank_pulse;
    if (dut.video_enable !== 1'b0 || dut.scroll[49] !== 16'd1 ||
        dut.irq_enabled !== 8'h08 || dut.irqs.vectors[3] !== 3'd6 ||
        dut.irq_requested !== 8'h08 || coin_lockout !== 2'b11)
        $fatal(1, "soft-reset retention precondition mismatch");

    // Restart the interval after setup, then let the descriptor-selected
    // watchdog itself drive the wrapper reset. This proves the real path, not
    // merely an independently asserted test reset.
    kick_watchdog(WDOG_MODE == 2);
    for (cycles = 0; cycles < TEST_TIMEOUT_CYCLES + 4 && !wdog_rst;
         cycles = cycles + 1) begin
        @(posedge clk_sys); #1;
    end
    if (!wdog_rst)
        $fatal(1, "watchdog did not drive the retention soft reset");
    // A watchdog is a machine reset, not a video-clock reset. Restarting the
    // raster here creates a shortened frame/sync interval and can make HDMI
    // receivers lose lock exactly when a game trips its watchdog.
    while (!dut.ce_pixel) begin
        @(posedge clk_sys); #1;
    end
    cycles = dut.hcnt;
    do begin
        @(posedge clk_sys); #1;
    end while (!dut.ce_pixel);
    if (dut.hcnt !== ((cycles == 453) ? 0 : cycles + 1))
        $fatal(1, "watchdog reset interrupted raster: hcnt %0d -> %0d",
               cycles, dut.hcnt);
    repeat (2) @(posedge clk_sys); #1;
    if (dut.video_enable !== 1'b0 || dut.scroll[49] !== 16'd1 ||
        dut.irq_enabled !== 8'h08 || dut.irqs.vectors[3] !== 3'd6 ||
        dut.irq_requested !== 8'h00 || coin_lockout !== 2'b11)
        $fatal(1, "watchdog soft reset lost retained board state");
    $display("PASS tb_ssv_watchdog soft reset retains video/CRTC/IRQ/bookkeeping");

    // Phase 3: the WRONG direction must NOT kick. This is the half that
    // matters -- a core that read-kicks regardless would pass phase 2 on
    // vasara's write-kick board and then reset in play.
    //
    // wdog_rst must stay sticky here: with feed_wdog_to_rst still set from
    // phase 1 it feeds rst, which clears it again before it can be sampled.
    feed_wdog_to_rst = 1'b0;
    boot_rst = 1;
    repeat (4) @(posedge clk_sys);
    @(negedge clk_sys);
    boot_rst = 0;
    repeat (4) @(posedge clk_sys);
    if (dut.video_enable !== 1'b1 || dut.scroll[49] !== 16'd0 ||
        dut.irq_enabled !== 8'h00 || dut.irqs.vectors[3] !== 3'd0)
        $fatal(1, "cold reset did not initialize retained board state");
    kick_watchdog(WDOG_MODE != 2, 1'b0);   // deliberately the wrong direction
    repeat (TEST_TIMEOUT_CYCLES) begin
        @(posedge clk_sys); #1;
    end
    if (!wdog_rst)
        $fatal(1, "mode%0d: wrong-direction access kicked the watchdog", WDOG_MODE);
    $display("PASS tb_ssv_watchdog mode%0d wrong-direction access does not kick",
             WDOG_MODE);
    $finish;
end
endmodule

module tb_ssv_watchdog_mode0;
    tb_ssv_watchdog #(.WDOG_MODE(0)) test();
endmodule

module tb_ssv_watchdog_mode2;
    tb_ssv_watchdog #(.WDOG_MODE(2)) test();
endmodule
