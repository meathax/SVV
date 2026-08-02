`timescale 1ns/1ps

module tb_ssv_palette_ram;
logic clk = 1'b0;
always #5 clk = ~clk;

logic [15:0] cpu_addr, cpu_data;
logic [1:0] cpu_be;
logic cpu_we;
logic [15:0] cpu_q;
logic [14:0] video_index;
logic [23:0] video_rgb;

ssv_palette_ram dut (.*);

task automatic write_word(input [15:0] address, input [15:0] data);
    begin
        @(negedge clk);
        cpu_addr = address;
        cpu_data = data;
        cpu_be = 2'b11;
        cpu_we = 1'b1;
        @(negedge clk);
        cpu_we = 1'b0;
    end
endtask

initial begin
    cpu_addr = 16'd0;
    cpu_data = 16'd0;
    cpu_be = 2'b00;
    cpu_we = 1'b0;
    video_index = 15'd0;

    // Palette entry 0x1234 = RGB 56,34,12.
    write_word(16'h2468, 16'h3412);
    write_word(16'h2469, 16'haa56);

    @(negedge clk);
    video_index = 15'h1234;
    repeat (2) @(posedge clk);
    #1;
    if (video_rgb !== 24'h563412) begin
        $error("xRGB888 lookup got %h", video_rgb);
        $fatal(1);
    end

    // The even word is full-width. The odd word is physical 00RR in this core:
    // MAME retains the unused written upper byte, but no qualified trace reads
    // it and widening costs 32 M10Ks on the already RAM-bound target.
    @(negedge clk);
    cpu_addr = 16'h2468;
    repeat (2) @(posedge clk);
    #1;
    if (cpu_q !== 16'h3412) $fatal(1, "even CPU word mismatch");
    @(negedge clk);
    cpu_addr = 16'h2469;
    repeat (2) @(posedge clk);
    #1;
    if (cpu_q !== 16'h0056) $fatal(1, "odd CPU 00RR word mismatch");

    $display("PASS tb_ssv_palette_ram");
    $finish;
end
endmodule
