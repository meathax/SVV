// SPDX-License-Identifier: GPL-3.0-or-later
// 32768-entry xRGB888 palette on a 16-bit CPU bus.
`timescale 1ns/1ps

module ssv_palette_ram (
    input  logic        clk,
    input  logic [15:0] cpu_addr,
    input  logic [15:0] cpu_data,
    input  logic  [1:0] cpu_be,
    input  logic        cpu_we,
    output logic [15:0] cpu_q,

    input  logic [14:0] video_index,
    output logic [23:0] video_rgb
);

logic cpu_bank_d;
wire [14:0] bank_addr = cpu_addr[15:1];
wire [15:0] even_cpu_q, odd_cpu_q;
wire [15:0] even_video_q, odd_video_q;

always_ff @(posedge clk)
    cpu_bank_d <= cpu_addr[0];

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) even_words (
    .clock_a(clk), .address_a(bank_addr), .data_a(cpu_data),
    .byteena_a(cpu_be), .wren_a(cpu_we && !cpu_addr[0]), .q_a(even_cpu_q),
    .clock_b(clk), .address_b(video_index), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(even_video_q)
);

s32_big_dpram #(.ADDR_WIDTH(15), .NUM_WORDS(32768)) odd_words (
    .clock_a(clk), .address_a(bank_addr), .data_a(cpu_data),
    .byteena_a(cpu_be), .wren_a(cpu_we && cpu_addr[0]), .q_a(odd_cpu_q),
    .clock_b(clk), .address_b(video_index), .data_b(16'd0),
    .byteena_b(2'b00), .wren_b(1'b0), .q_b(odd_video_q)
);

always_comb begin
    cpu_q = cpu_bank_d ? odd_cpu_q : even_cpu_q;
    // Raw 32-bit entry is 00RRGGBB: even word GGBB, odd word 00RR.
    video_rgb = {odd_video_q[7:0], even_video_q[15:8], even_video_q[7:0]};
end

endmodule
