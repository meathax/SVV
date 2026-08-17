`timescale 1ns/1ps

// The SSV PCB derives V60/OTTO from 48 MHz / 3 and pixels from
// 42.954545 MHz / 6, so the observable CPU-to-pixel ratio is 704/315.
// A long finite window rejects the former +42 ppm drift while allowing the
// unavoidable one-pulse quantization at the two accumulator boundaries.
module tb_ssv_clock_ratio;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst;
logic ce_cpu;
logic ce_pixel, ce_pix_x2;
logic [8:0] hcnt, vcnt;
logic hblank, vblank, hsync, vsync, vblank_pulse, irq3_pulse;

ssv_tb_ce_cpu cpu_clock (
    .clk(clk), .rst(rst), .ce_cpu(ce_cpu)
);

ssv_video_timing video_clock (
    .clk(clk), .rst(rst),
    .active_width(9'd336), .active_height(9'd240),
    .ce_pixel(ce_pixel), .ce_pix_x2(ce_pix_x2),
    .hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
    .hsync(hsync), .vsync(vsync), .vblank_pulse(vblank_pulse),
    .irq3_pulse(irq3_pulse)
);

longint unsigned cpu_ticks, pixel_ticks;
longint signed ratio_error;
real ratio_ppm;
integer cycle;

initial begin
    rst = 1'b1;
    repeat (4) @(posedge clk);
    rst = 1'b0;
    cpu_ticks = 0;
    pixel_ticks = 0;
    for (cycle = 0; cycle < 2_000_000; cycle = cycle + 1) begin
        @(posedge clk); #1;
        if (ce_cpu) cpu_ticks = cpu_ticks + 1;
        if (ce_pixel) pixel_ticks = pixel_ticks + 1;
    end

    // Exact target: cpu_ticks / pixel_ticks = 704 / 315.
    ratio_error = $signed(cpu_ticks * 315) - $signed(pixel_ticks * 704);
    ratio_ppm = ((real'(cpu_ticks) / real'(pixel_ticks)) /
                 (704.0 / 315.0) - 1.0) * 1_000_000.0;
    if (ratio_error < -1500 || ratio_error > 1500)
        $fatal(1,
            "SSV clock ratio drift cpu=%0d pixel=%0d cross_error=%0d ppm=%f",
            cpu_ticks, pixel_ticks, ratio_error, ratio_ppm);
    $display("PASS tb_ssv_clock_ratio cpu=%0d pixel=%0d cross_error=%0d ppm=%f",
             cpu_ticks, pixel_ticks, ratio_error, ratio_ppm);
    $finish;
end
endmodule
