`timescale 1ns/1ps
// Diagnostic raster must keep producing CE/HS/VS and non-black active pixels
// while the game core would be held in reset.

module tb_ssv_diag_video;
import ssv_pkg::*;

logic clk = 0;
always #5 clk = ~clk;

logic rst;
logic show_core;
logic video_enable;
logic [23:0] rgb;
logic ce_pixel, hs, vs, hb, vb, use_core_video;
logic [15:0] frame_count;
logic vs_d;
integer ce_seen, active_nonblack, cycles;

ssv_diag_video dut (
    .clk(clk), .rst(rst),
    .show_core(show_core), .core_rgb(24'h00ff00),
    .pll_locked(1'b1),
    .ioctl_download(1'b0),
    .rom_loaded(1'b1),
    .sdram_ready(1'b1),
    .video_reset(1'b0),
    .core_reset(1'b0),
    .video_enable(video_enable),
    .cpu_halted(1'b0),
    .cpu_pause(1'b0),
    .service_mode(1'b0),
    .irq_n(1'b1),
    .irq_enabled(8'h00),
    .ext_busy(1'b0),
    .rom_sig_ok(1'b1),
    .probe_done(1'b1),
    .probe_sig0(16'h207a),
    .probe_sig1(16'h0c7a),
    .debug_pc(32'hFFFF_FFF0),
    .ioctl_addr(27'd0),
    .download_max_addr(27'h010000),
    .frame_count(frame_count),
    .rgb(rgb), .ce_pixel(ce_pixel),
    .hs(hs), .vs(vs), .hb(hb), .vb(vb),
    .use_core_video(use_core_video)
);

always_ff @(posedge clk) begin
    if (rst) begin
        frame_count <= 0;
        vs_d <= 1'b1;
    end
    else begin
        vs_d <= vs;
        if (vs_d && !vs)
            frame_count <= frame_count + 1'd1;
    end
end

initial begin
    rst = 1;
    show_core = 1'b0;
    video_enable = 1'b0;
    ce_seen = 0;
    active_nonblack = 0;
    cycles = 0;
    repeat (4) @(posedge clk);
    rst = 0;

    // Phase 1: bring-up teal (ROM loaded, CPU up, video disabled) must keep
    // an independent diag raster and must NOT hand HDMI to the core.
    while (cycles < 200000) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (use_core_video)
            $fatal(1, "use_core_video asserted before video_enable");
        if (ce_pixel) begin
            ce_seen = ce_seen + 1;
            if (!hb && !vb && (rgb != 24'h000000))
                active_nonblack = active_nonblack + 1;
        end
        if (active_nonblack > 1000 && ce_seen > 1000)
            break;
    end

    if (ce_seen == 0)
        $fatal(1, "diagnostic timing produced no ce_pixel");
    if (active_nonblack == 0)
        $fatal(1, "diagnostic active area stayed black under video_enable=0");

    // Phase 2: once the game enables video, the wrapper must switch to core
    // CE/HS/VS (dual-timing bug guard).
    show_core = 1'b1;
    video_enable = 1'b1;
    @(posedge clk);
    @(posedge clk);
    if (!use_core_video)
        $fatal(1, "use_core_video stayed low after video_enable");

    $display("PASS tb_ssv_diag_video ce=%0d nonblack=%0d use_core_video=1",
             ce_seen, active_nonblack);
    $finish;
end

endmodule
