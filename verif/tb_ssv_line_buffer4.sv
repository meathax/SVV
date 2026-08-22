`timescale 1ns/1ps

module tb_ssv_line_buffer4;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, frame_sync, line_start, render_start, render_done;
logic [3:0] plot_we;
logic [35:0] plot_x;
logic [59:0] plot_color;
logic plot_shadow;
logic [31:0] plot_pen;
logic shadow_4bit;
logic [8:0] scan_x;
logic [14:0] scan_color;
logic render_ready, render_go, scan_underrun;

ssv_line_buffer4 dut (.*);

integer lane;
integer timeout;

task automatic pulse(input string signal_name);
begin
    @(negedge clk);
    case (signal_name)
        "frame_sync":   frame_sync = 1'b1;
        "line_start":   line_start = 1'b1;
        "render_start": render_start = 1'b1;
        "render_done":  render_done = 1'b1;
        default: $fatal(1, "unknown pulse %s", signal_name);
    endcase
    @(negedge clk);
    frame_sync = 1'b0;
    line_start = 1'b0;
    render_start = 1'b0;
    render_done = 1'b0;
end
endtask

task automatic wait_ready;
begin
    timeout = 0;
    while (!render_ready && timeout < 500) begin
        @(negedge clk);
        timeout = timeout + 1;
    end
    if (!render_ready)
        $fatal(1, "render slot did not become clean");
end
endtask

task automatic begin_line;
begin
    wait_ready();
    pulse("render_start");
    if (!dut.render_active)
        $fatal(1, "render epoch did not open");
end
endtask

task automatic end_line;
begin
    repeat (2) @(negedge clk);
    pulse("render_done");
end
endtask

task automatic plot_batch(
    input logic [8:0] base_x,
    input logic [59:0] colors,
    input logic shadow,
    input logic four_bit,
    input logic [31:0] pens
);
begin
    for (lane = 0; lane < 4; lane = lane + 1)
        plot_x[lane * 9 +: 9] = base_x + 9'(lane);
    plot_color = colors;
    plot_shadow = shadow;
    shadow_4bit = four_bit;
    plot_pen = pens;
    plot_we = 4'hf;
    @(negedge clk);
    plot_we = 4'h0;
end
endtask

task automatic expect_pixel(
    input logic [8:0] x,
    input logic [14:0] expected
);
begin
    scan_x = x;
    repeat (2) @(posedge clk);
    #1;
    if (scan_color !== expected)
        $fatal(1, "pixel %0d got %h expected %h", x, scan_color, expected);
end
endtask

task automatic publish_and_consume;
begin
    end_line();
    pulse("line_start");
    if (scan_underrun)
        $fatal(1, "completed line was reported as an underrun");
end
endtask

task automatic publish_empty;
begin
    begin_line();
    publish_and_consume();
end
endtask

initial begin
    rst = 1'b1;
    frame_sync = 1'b0;
    line_start = 1'b0;
    render_start = 1'b0;
    render_done = 1'b0;
    plot_we = 4'h0;
    plot_x = '0;
    plot_color = '0;
    plot_shadow = 1'b0;
    plot_pen = '0;
    shadow_4bit = 1'b0;
    scan_x = '0;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    pulse("frame_sync");

    begin_line();

    // Later opaque list entries win. A pen-zero renderer pixel is represented
    // by no write and therefore cannot erase an earlier opaque object.
    plot_batch(9'd10,
        {15'h0555, 15'h0444, 15'h0333, 15'h0222},
        1'b0, 1'b0, 32'd0);
    plot_batch(9'd10,
        {15'h3456, 15'h2345, 15'h1234, 15'h0123},
        1'b0, 1'b0, 32'd0);
    repeat (2) @(negedge clk);

    // Two-bit and four-bit shadow pens replace only the documented high
    // palette-index bits of the pixel already underneath them.
    plot_batch(9'd10, 60'd0, 1'b1, 1'b0,
        {8'h00, 8'h03, 8'h02, 8'h01});
    plot_batch(9'd14,
        {15'h0567, 15'h0456, 15'h0345, 15'h0234},
        1'b0, 1'b0, 32'd0);
    plot_batch(9'd14, 60'd0, 1'b1, 1'b1,
        {8'h0d, 8'h0c, 8'h0b, 8'h0a});

    // A shadow before a later character is replaced by that character; a
    // shadow after it modifies it. This is SSV list order, not priority bits.
    plot_batch(9'd20,
        {15'h0000, 15'h0000, 15'h1111, 15'h1111},
        1'b0, 1'b0, 32'd0);
    plot_batch(9'd20, 60'd0, 1'b1, 1'b0,
        {8'h00, 8'h00, 8'h01, 8'h01});
    plot_batch(9'd20,
        {15'h0000, 15'h0000, 15'h0456, 15'h0456},
        1'b0, 1'b0, 32'd0);
    plot_batch(9'd21, 60'd0, 1'b1, 1'b0,
        {8'h00, 8'h00, 8'h00, 8'h02});

    publish_and_consume();
    expect_pixel(9'd9,  15'h0000);
    expect_pixel(9'd10, 15'h2123);
    expect_pixel(9'd11, 15'h5234);
    expect_pixel(9'd12, 15'h6345);
    expect_pixel(9'd13, 15'h1456);
    expect_pixel(9'd14, 15'h5234);
    expect_pixel(9'd15, 15'h5b45);
    expect_pixel(9'd16, 15'h6456);
    expect_pixel(9'd17, 15'h6d67);
    expect_pixel(9'd20, 15'h0456);
    expect_pixel(9'd21, 15'h4456);

    // An empty ring repeats the prior completed line and reports the miss.
    pulse("line_start");
    if (!scan_underrun)
        $fatal(1, "empty ring did not report an underrun");
    expect_pixel(9'd10, 15'h2123);

    // Walk all four slots and return to slot zero. The old pixels must have
    // been cleared before reuse, proving no stale line can reappear.
    publish_empty();
    publish_empty();
    publish_empty();
    publish_empty();
    expect_pixel(9'd10, 15'h0000);
    expect_pixel(9'd21, 15'h0000);

    $display("PASS tb_ssv_line_buffer4");
    $finish;
end
endmodule
