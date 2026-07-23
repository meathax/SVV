`timescale 1ns/1ps

module tb_ssv_video_timing;
logic clk = 0;
always #5 clk = ~clk;
logic rst;
logic ce_pixel, hblank, vblank, hsync, vsync, vblank_pulse;
logic [8:0] hcnt, vcnt;

ssv_video_timing #(.PIXEL_INC(16'hffff)) dut (.*);

integer pixels = 0;
integer vb_pulses = 0;
initial begin
    $dumpfile("ssv_video_timing.vcd");
    $dumpvars(0, tb_ssv_video_timing);
    rst = 1;
    repeat (2) @(posedge clk);
    rst = 0;
    while (pixels < (454 * 262 + 10)) begin
        @(posedge clk); #1;
        if (ce_pixel) begin
            pixels = pixels + 1;
            if (hcnt == 336 && !hblank) $fatal(1, "hblank late");
            if (vcnt == 240 && !vblank) $fatal(1, "vblank late");
        end
        if (vblank_pulse) vb_pulses = vb_pulses + 1;
    end
    if (vb_pulses != 1) $fatal(1, "expected one vblank pulse, got %0d", vb_pulses);
    $display("PASS tb_ssv_video_timing");
    $finish;
end
endmodule
