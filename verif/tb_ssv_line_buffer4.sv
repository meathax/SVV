`timescale 1ns/1ps

module tb_ssv_line_buffer4;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, line_start, line_ready, render_start;
logic [3:0] plot_we;
logic [35:0] plot_x;
logic [59:0] plot_color;
logic plot_shadow;
logic [31:0] plot_pen;
logic shadow_4bit;
logic [8:0] scan_x;
logic [14:0] scan_color;
logic clear_busy, clear_done;

ssv_line_buffer4 dut (.*);

integer lane;
integer clear_clocks;
task automatic pulse_line_start(
    input logic ready,
    input logic start_render
);
    begin
        @(negedge clk);
        line_start = 1'b1;
        line_ready = ready;
        render_start = start_render;
        @(negedge clk);
        line_start = 1'b0;
        line_ready = 1'b0;
        render_start = 1'b0;
        if (!ready) begin
            @(negedge clk);
        end
        else begin
            clear_clocks = 0;
            while (!clear_done) begin
                @(negedge clk);
                clear_clocks = clear_clocks + 1;
                if (clear_clocks > 90)
                    $fatal(1, "four-bank clear exceeded 88-word deadline");
            end
            if (clear_clocks < 87 || clear_clocks > 89)
                $fatal(1, "four-bank 88-word clear took %0d clocks", clear_clocks);
            @(negedge clk);
        end
    end
endtask

task automatic plot_batch(
    input [8:0] base_x,
    input [59:0] colors,
    input shadow,
    input [31:0] pens
);
    begin
        for (lane = 0; lane < 4; lane = lane + 1)
            plot_x[lane * 9 +: 9] = base_x + lane;
        plot_color = colors;
        plot_shadow = shadow;
        plot_pen = pens;
        plot_we = 4'hf;
        @(negedge clk);
        plot_we = 4'd0;
    end
endtask

task automatic expect_pixel(
    input [8:0] x,
    input [14:0] expected
);
    begin
        scan_x = x;
        repeat (2) @(posedge clk);
        #1;
        if (scan_color !== expected)
            $fatal(1, "pixel %0d got %h expected %h",
                   x, scan_color, expected);
    end
endtask

initial begin
    rst = 1'b1;
    line_start = 1'b0;
    line_ready = 1'b0;
    render_start = 1'b0;
    plot_we = 4'd0;
    plot_x = 36'd0;
    plot_color = 60'd0;
    plot_shadow = 1'b0;
    plot_pen = 32'd0;
    shadow_4bit = 1'b0;
    scan_x = 9'd0;

    repeat (3) @(negedge clk);
    rst = 1'b0;

    // Clear the new back line, then exercise a batch that rotates across
    // physical banks 2, 3, 0 and 1.
    pulse_line_start(1'b1, 1'b1);
    plot_batch(
        9'd10,
        {15'h3456, 15'h2345, 15'h1234, 15'h0123},
        1'b0,
        32'd0
    );

    // A directly following same-address shadow batch must consume the values
    // forwarded from the preceding write rather than undefined M10K data.
    plot_batch(
        9'd10,
        60'd0,
        1'b1,
        {8'h00, 8'h03, 8'h02, 8'h01}
    );

    shadow_4bit = 1'b1;
    plot_batch(
        9'd14,
        {15'h0567, 15'h0456, 15'h0345, 15'h0234},
        1'b0,
        32'd0
    );
    plot_batch(
        9'd14,
        60'd0,
        1'b1,
        {8'h0d, 8'h0c, 8'h0b, 8'h0a}
    );
    plot_we = 4'd0;
    repeat (2) @(negedge clk);

    // Swap the completed line to scanout and check every bank.
    pulse_line_start(1'b1, 1'b1);
    expect_pixel(9'd9,  15'h0000);
    expect_pixel(9'd10, 15'h2123);
    expect_pixel(9'd11, 15'h5234);
    expect_pixel(9'd12, 15'h6345);
    expect_pixel(9'd13, 15'h1456);
    expect_pixel(9'd14, 15'h5234);
    expect_pixel(9'd15, 15'h5b45);
    expect_pixel(9'd16, 15'h6456);
    expect_pixel(9'd17, 15'h6d67);
    expect_pixel(9'd18, 15'h0000);

    // Model a renderer that misses its deadline. The incomplete producer bank
    // must not be published, and the previously displayed line must remain.
    pulse_line_start(1'b0, 1'b0);
    expect_pixel(9'd10, 15'h2123);

    // Late writes from the expired producer epoch must be rejected.
    plot_batch(
        9'd30,
        {15'h4444, 15'h3333, 15'h2222, 15'h1111},
        1'b0,
        32'd0
    );
    repeat (2) @(negedge clk);
    // Once the late renderer drains, reclaim its bank without swapping the
    // stale line into view and open a fresh producer epoch.
    pulse_line_start(1'b1, 1'b1);
    expect_pixel(9'd10, 15'h2123);

    // The newly opened clean epoch must still accept ordinary plots.
    @(negedge clk);
    plot_batch(
        9'd34,
        {15'h0555, 15'h0444, 15'h0333, 15'h0222},
        1'b0,
        32'd0
    );
    repeat (2) @(negedge clk);
    pulse_line_start(1'b1, 1'b1);
    expect_pixel(9'd34, 15'h0222);
    expect_pixel(9'd35, 15'h0333);
    expect_pixel(9'd36, 15'h0444);
    expect_pixel(9'd37, 15'h0555);

    $display("PASS tb_ssv_line_buffer4 clear_clocks=%0d",
             clear_clocks);
    $finish;
end
endmodule
