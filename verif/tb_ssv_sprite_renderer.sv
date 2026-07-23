`timescale 1ns/1ps

module tb_ssv_sprite_renderer;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst, start;
logic [8:0] target_y;
logic [15:0] local_control, flip_control, coordinate_control;
logic [15:0] global_y_base, global_y_adjust;
logic [255:0] sprite_offsets;
logic shadow_4bit;
logic [16:0] spr_addr;
logic [15:0] spr_data;
logic rom_req;
logic [24:3] rom_addr;
logic [63:0] rom_data;
logic rom_ack;
logic plot_we;
logic [8:0] plot_x;
logic [14:0] plot_color;
logic plot_shadow;
logic [7:0] plot_pen;
logic plot_shadow_4bit;
logic busy, done;

ssv_sprite_renderer dut (.*);

logic [15:0] sprite_mem [0:131071];
always_ff @(posedge clk)
    spr_data <= sprite_mem[spr_addr];

logic rom_req_d;
integer rom_delay;
integer rom_quarter;
always_ff @(posedge clk) begin
    rom_req_d <= rom_req;
    rom_ack <= 1'b0;
    if (rom_req && !rom_req_d)
        rom_delay <= 2;
    if (rom_delay > 0) begin
        rom_delay <= rom_delay - 1;
        if (rom_delay == 1) begin
            rom_data <= (rom_quarter == 0) ? 64'h0000008000000080
                                           : 64'd0;
            rom_ack <= 1'b1;
            rom_quarter <= (rom_quarter + 1) & 3;
        end
    end
end

integer plots;
integer first_x;
always_ff @(posedge clk) begin
    if (plot_we) begin
        plots <= plots + 1;
        if (plots == 0)
            first_x <= plot_x;
        if (plot_color !== 15'd65 || plot_pen !== 8'd1 ||
            plot_shadow || plot_shadow_4bit)
            $fatal(1, "plot metadata mismatch");
    end
end

integer i;
initial begin
    for (i = 0; i < 131072; i = i + 1)
        sprite_mem[i] = 16'd0;

    // One global entry pointing at one 16x8, six-bpp local sprite.
    sprite_mem[0] = 16'h6000;
    sprite_mem[1] = 16'h0400;
    sprite_mem[2] = 16'd0;
    sprite_mem[3] = 16'd0;
    sprite_mem[5] = 16'h8000; // end marker in the next global entry

    sprite_mem[16'h1000] = 16'd0;
    sprite_mem[16'h1001] = 16'h0001;
    sprite_mem[16'h1002] = 16'd10;
    sprite_mem[16'h1003] = 16'h03e3; // -29 -> final screen y 20

    rst = 1'b1;
    start = 1'b0;
    target_y = 9'd20;
    local_control = 16'd0;
    flip_control = 16'd0;
    coordinate_control = 16'd0;
    global_y_base = 16'd0;
    global_y_adjust = 16'd0;
    sprite_offsets = 256'd0;
    shadow_4bit = 1'b0;
    spr_data = 16'd0;
    rom_data = 64'd0;
    rom_ack = 1'b0;
    rom_req_d = 1'b0;
    rom_delay = 0;
    rom_quarter = 0;
    plots = 0;
    first_x = -1;

    repeat (4) @(negedge clk);
    rst = 1'b0;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    wait (done);
    @(posedge clk);
    if (plots != 1 || first_x != 10)
        $fatal(1, "plot coverage count=%0d first=%0d", plots, first_x);
    if (rom_addr < 22'h20000)
        $fatal(1, "graphics ROM address outside sprite region: %h", rom_addr);

    $display("PASS tb_ssv_sprite_renderer");
    $finish;
end
endmodule
