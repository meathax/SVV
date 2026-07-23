`timescale 1ns/1ps

module tb_ssv_line_buffer;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, line_start;
logic plot_we;
logic [8:0] plot_x;
logic [14:0] plot_color;
logic plot_shadow;
logic [7:0] plot_pen;
logic shadow_4bit;
logic [8:0] scan_x;
logic [14:0] scan_color;
logic clear_busy, clear_done;

ssv_line_buffer dut (.*);

task automatic pulse_line_start;
    begin
        @(negedge clk);
        line_start = 1'b1;
        @(negedge clk);
        line_start = 1'b0;
        wait (clear_done);
        @(negedge clk);
    end
endtask

task automatic plot(
    input [8:0] x,
    input [14:0] color,
    input shadow,
    input [7:0] pen
);
    begin
        plot_x = x;
        plot_color = color;
        plot_shadow = shadow;
        plot_pen = pen;
        plot_we = 1'b1;
        @(negedge clk);
        plot_we = 1'b0;
    end
endtask

initial begin
    rst = 1'b1;
    line_start = 1'b0;
    plot_we = 1'b0;
    plot_x = 9'd0;
    plot_color = 15'd0;
    plot_shadow = 1'b0;
    plot_pen = 8'd0;
    shadow_4bit = 1'b0;
    scan_x = 9'd0;

    repeat (3) @(negedge clk);
    rst = 1'b0;

    // Swap once and clear the new back (line0), then draw into it.
    pulse_line_start();
    plot(9'd10, 15'h0123, 1'b0, 8'd0);
    plot(9'd11, 15'h1234, 1'b0, 8'd0);
    plot(9'd10, 15'd0, 1'b1, 8'h03);
    // Exercise same-address forwarding: the shadow request immediately
    // follows the normal write, so block-RAM read-during-write cannot be
    // relied upon to return the new pixel.
    plot(9'd13, 15'h0456, 1'b0, 8'd0);
    plot(9'd13, 15'd0, 1'b1, 8'h02);
    shadow_4bit = 1'b1;
    plot(9'd14, 15'h0234, 1'b0, 8'd0);
    plot(9'd14, 15'd0, 1'b1, 8'h0a);

    // Make the completed line visible and verify synchronous scanout.
    pulse_line_start();
    scan_x = 9'd10;
    repeat (2) @(posedge clk);
    #1;
    if (scan_color !== 15'h6123)
        $fatal(1, "two-bit shadow got %h", scan_color);

    scan_x = 9'd11;
    repeat (2) @(posedge clk);
    #1;
    if (scan_color !== 15'h1234)
        $fatal(1, "normal plot got %h", scan_color);

    scan_x = 9'd12;
    repeat (2) @(posedge clk);
    #1;
    if (scan_color !== 15'h0000)
        $fatal(1, "clear got %h", scan_color);

    scan_x = 9'd13;
    repeat (2) @(posedge clk);
    #1;
    if (scan_color !== 15'h4456)
        $fatal(1, "same-cycle two-bit shadow got %h", scan_color);

    scan_x = 9'd14;
    repeat (2) @(posedge clk);
    #1;
    if (scan_color !== 15'h5234)
        $fatal(1, "same-cycle four-bit shadow got %h", scan_color);

    $display("PASS tb_ssv_line_buffer");
    $finish;
end
endmodule
