`timescale 1ns/1ps

module tb_ssv_bg_renderer;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, line_start;
logic [8:0] target_y;
logic clear_done;
logic [15:0] scroll_x, scroll_y, scroll_mode;
logic [15:0] global_y_base, global_y_adjust, flip_control;
logic shadow_4bit;
logic [16:0] spr_addr;
logic [15:0] spr_data;
logic rom_req;
logic [24:3] rom_addr;
logic [63:0] rom_data;
logic rom_ack;
logic [3:0] plot_we;
logic [35:0] plot_x;
logic [59:0] plot_color;
logic plot_shadow;
logic [31:0] plot_pen;
logic plot_shadow_4bit;
logic busy, done;

ssv_bg_renderer dut (.*);

logic [15:0] sprite_mem [0:131071];
always_ff @(posedge clk)
    spr_data <= sprite_mem[spr_addr];

logic rom_req_d;
integer rom_delay;
integer rom_quarter;
integer requests;
logic [24:3] first_rom_addr;
always_ff @(posedge clk) begin
    rom_req_d <= rom_req;
    rom_ack <= 1'b0;
    if (rom_req && !rom_req_d) begin
        if (requests == 0)
            first_rom_addr <= rom_addr;
        requests <= requests + 1;
        rom_delay <= 2;
    end
    if (rom_delay > 0) begin
        rom_delay <= rom_delay - 1;
        if (rom_delay == 1) begin
            // Quarter zero supplies pen bit zero at pixel zero.
            rom_data <= (rom_quarter == 0) ? 64'h0000000000000080
                                           : 64'd0;
            rom_ack <= 1'b1;
            rom_quarter <= (rom_quarter + 1) & 1;
        end
    end
end

integer plots;
integer first_x;
integer last_x;
integer monitor_lane;
integer batch_plot_count;
integer batch_first_lane;
always_comb begin
    batch_plot_count = 0;
    batch_first_lane = -1;
    for (monitor_lane = 0; monitor_lane < 4;
         monitor_lane = monitor_lane + 1) begin
        if (plot_we[monitor_lane]) begin
            batch_plot_count = batch_plot_count + 1;
            if (batch_first_lane < 0)
                batch_first_lane = monitor_lane;
        end
    end
end

always_ff @(posedge clk) begin
    if (batch_plot_count != 0) begin
        if (plots == 0)
            first_x <= plot_x[batch_first_lane * 9 +: 9];
        plots <= plots + batch_plot_count;
    end
    for (monitor_lane = 0; monitor_lane < 4;
         monitor_lane = monitor_lane + 1) begin
        if (plot_we[monitor_lane]) begin
            last_x <= plot_x[monitor_lane * 9 +: 9];
            if (plot_color[monitor_lane * 15 +: 15] !== 15'd65 ||
                plot_pen[monitor_lane * 8 +: 8] !== 8'd1 ||
                plot_shadow || plot_shadow_4bit)
                $fatal(1, "plot metadata mismatch lane=%0d",
                       monitor_lane);
        end
    end
end

integer i;
initial begin
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;
    // Each column's descriptor is 64 words apart for a 512-pixel map.
    for (i = 0; i <= 20; i = i + 1) begin
        sprite_mem[i * 64] = 16'd0;
        sprite_mem[i * 64 + 1] = 16'h0001;
    end

    rst = 1'b1;
    line_start = 1'b0;
    target_y = 9'd0;
    clear_done = 1'b0;
    scroll_x = 16'd0;
    scroll_y = 16'hfffe; // cancels the renderer's documented +2 tweak
    scroll_mode = 16'h2000; // enabled, 512-pixel map, six-bpp mode
    global_y_base = 16'd0;
    global_y_adjust = 16'd0;
    flip_control = 16'd0;
    shadow_4bit = 1'b0;
    spr_data = 16'd0;
    rom_data = 64'd0;
    rom_ack = 1'b0;
    rom_req_d = 1'b0;
    rom_delay = 0;
    rom_quarter = 0;
    requests = 0;
    first_rom_addr = '0;
    plots = 0;
    first_x = -1;
    last_x = -1;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    line_start = 1'b1;
    @(negedge clk);
    line_start = 1'b0;
    repeat (3) @(negedge clk);
    clear_done = 1'b1;
    @(negedge clk);
    clear_done = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 21 || first_x != 0 || last_x != 320)
        $fatal(1, "plot coverage count=%0d first=%0d last=%0d",
               plots, first_x, last_x);
    if (first_rom_addr != 22'h20000)
        $fatal(1, "normal row address got %h", first_rom_addr);

    // Vertical flip must select code+1 and row 7 for source line zero.
    for (i = 0; i <= 20; i = i + 1)
        sprite_mem[i * 64 + 1] = 16'h4001;
    @(negedge clk);
    requests = 0;
    first_rom_addr = '0;
    rom_quarter = 0;
    plots = 0;
    first_x = -1;
    last_x = -1;
    line_start = 1'b1;
    @(negedge clk);
    line_start = 1'b0;
    repeat (3) @(negedge clk);
    clear_done = 1'b1;
    @(negedge clk);
    clear_done = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 21 || first_x != 0 || last_x != 320)
        $fatal(1, "flipped plot coverage count=%0d first=%0d last=%0d",
               plots, first_x, last_x);
    if (first_rom_addr != 22'h2000f)
        $fatal(1, "vertical-flip row address got %h", first_rom_addr);

    $display("PASS tb_ssv_bg_renderer");
    $finish;
end
endmodule
