`timescale 1ns/1ps

module tb_ssv_video_wave_small;
logic clk = 0;
always #5 clk = ~clk;
logic rst;
logic ce_pixel, hblank, vblank, hsync, vsync, vblank_pulse;
logic [8:0] hcnt, vcnt;

ssv_video_timing #(.PIXEL_INC(16'hffff)) dut (.*);

initial begin
    rst = 1;
    repeat (2) @(posedge clk);
    rst = 0;
    wait (vcnt == 239 && hcnt == 300);
    $dumpfile("ssv_video_boundary_small.vcd");
    $dumpvars(0, tb_ssv_video_wave_small);
    wait (vcnt == 240 && hcnt == 380);
    $display("PASS tb_ssv_video_wave_small");
    $finish;
end
endmodule
