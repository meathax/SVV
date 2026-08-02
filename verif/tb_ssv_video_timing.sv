`timescale 1ns/1ps

module tb_ssv_video_timing;
logic clk = 0;
always #5 clk = ~clk;
logic rst;
logic ce_pixel, ce_pix_x2, hblank, vblank, hsync, vsync, vblank_pulse;
logic [8:0] hcnt, vcnt;
logic [8:0] active_width = 9'd336;
logic [8:0] active_height = 9'd240;

ssv_video_timing #(.PIXEL_INC(16'hffff)) dut (.*);

integer pixels = 0;
integer vb_pulses = 0;
task automatic run_geometry(input logic [8:0] width,
                            input logic [8:0] height);
    begin
    active_width = width;
    active_height = height;
    rst = 1;
    repeat (2) @(posedge clk);
    rst = 0;
    pixels = 0;
    vb_pulses = 0;
    while (pixels < (454 * 262 + 10)) begin
        @(posedge clk); #1;
        if (ce_pixel) begin
            pixels = pixels + 1;
            if (hcnt == width - 1'd1 && hblank)
                $fatal(1, "hblank early width=%0d", width);
            if (hcnt == width && !hblank)
                $fatal(1, "hblank late width=%0d", width);
            if (vcnt == height - 1'd1 && vblank)
                $fatal(1, "vblank early height=%0d", height);
            if (vcnt == height && !vblank)
                $fatal(1, "vblank late height=%0d", height);
        end
        if (vblank_pulse) vb_pulses = vb_pulses + 1;
    end
    if (vb_pulses != 1)
        $fatal(1, "geometry %0dx%0d expected one vblank pulse, got %0d",
               width, height, vb_pulses);
    $display("PASS tb_ssv_video_timing geometry=%0dx%0d", width, height);
    end
endtask

initial begin
    $dumpfile("ssv_video_timing.vcd");
    $dumpvars(0, tb_ssv_video_timing);
    run_geometry(9'd336, 9'd240);
    run_geometry(9'd338, 9'd240);
    run_geometry(9'd352, 9'd240);
    run_geometry(9'd336, 9'd238);
    $finish;
end
endmodule
