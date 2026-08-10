// SPDX-License-Identifier: GPL-3.0-or-later
// Focused pin-sequence regression for the SDRAM output timing cone.
`timescale 1ns/1ps

module tb_ssv_sdram_command_timing;
logic clk = 1'b0;
always #5 clk = ~clk;

logic init = 1'b1;
wire ready;
tri [15:0] dq;
wire [12:0] a;
wire [1:0] ba;
wire dqml, dqmh, ncs, ncas, nras, nwe, cke;
logic p0_req = 1'b0;
logic [26:1] p0_addr = '0;
wire [15:0] p0_dout;
wire p0_ack;

sdram dut (
    .clk(clk), .init(init), .ready(ready),
    .SDRAM_DQ(dq), .SDRAM_A(a), .SDRAM_BA(ba),
    .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_nCS(ncs),
    .SDRAM_nCAS(ncas), .SDRAM_nRAS(nras), .SDRAM_nWE(nwe),
    .SDRAM_CKE(cke),
    .wr_req(1'b0), .wr_addr('0), .wr_din('0), .wr_be('0), .wr_ack(),
    .p0_req(p0_req), .p0_addr(p0_addr), .p0_dout(p0_dout), .p0_ack(p0_ack),
    .p1_req(1'b0), .p1_addr('0), .p1_dout(), .p1_ack(),
    .p2_req(1'b0), .p2_addr('0), .p2_dout(), .p2_ack(),
    .p3_req(1'b0), .p3_addr('0), .p3_dout(), .p3_ack(),
    .p4_req(1'b0), .p4_addr('0), .p4_dout(), .p4_ack(),
    .p5_req(1'b0), .p5_addr('0), .p5_dout(), .p5_ack()
);

function automatic [26:1] word_addr(
    input logic dev,
    input logic col9,
    input logic [1:0] bank,
    input logic [12:0] row,
    input logic [8:0] col
);
    word_addr = {dev, col9, bank, row, col};
endfunction

task automatic start_read(input logic [26:1] addr);
    begin
        while (p0_ack) @(posedge clk);
        @(posedge clk); #1;
        p0_addr = addr;
        p0_req = 1'b1;
        @(posedge clk); #1;
        p0_req = 1'b0;
    end
endtask

task automatic expect_command(
    input logic [2:0] wanted,
    input logic dev,
    input logic [1:0] bank,
    input logic [12:0] addr,
    input integer max_cycles
);
    integer cycles;
    begin
        cycles = 0;
        while ({nras,ncas,nwe} != wanted && cycles < max_cycles) begin
            @(posedge clk); #1;
            cycles = cycles + 1;
        end
        if ({nras,ncas,nwe} != wanted)
            $fatal(1, "command %03b not observed", wanted);
        if (ncs != dev || ba != bank || a != addr)
            $fatal(1, "command %03b pins dev=%0b/%0b bank=%0d/%0d a=%h/%h",
                   wanted, ncs, dev, ba, bank, a, addr);
    end
endtask

localparam logic [2:0] CMD_ACT  = 3'b011;
localparam logic [2:0] CMD_READ = 3'b101;
localparam logic [2:0] CMD_PRE  = 3'b010;

logic [26:1] first_addr;
logic [26:1] hit_addr;
logic [26:1] miss_addr;

initial begin
    first_addr = word_addr(1'b0, 1'b1, 2'd2, 13'h123, 9'h045);
    hit_addr   = word_addr(1'b0, 1'b1, 2'd2, 13'h123, 9'h046);
    miss_addr  = word_addr(1'b0, 1'b0, 2'd2, 13'h321, 9'h012);

    repeat (4) @(posedge clk);
    init = 1'b0;
    wait (ready);

    // Closed row: ACT then READ with the original command cadence.
    start_read(first_addr);
    expect_command(CMD_ACT, 1'b0, 2'd2, 13'h123, 12);
    expect_command(CMD_READ, 1'b0, 2'd2, {3'b000,1'b1,9'h045}, 8);
    wait (p0_ack);

    // Same open row: no PRE/ACT is needed, only the next column READ.
    start_read(hit_addr);
    expect_command(CMD_READ, 1'b0, 2'd2, {3'b000,1'b1,9'h046}, 8);
    wait (p0_ack);

    // Same bank, different row: registered conflict decision emits PRE,
    // observes tRP, then ACTs the new row and issues its READ.
    start_read(miss_addr);
    expect_command(CMD_PRE, 1'b0, 2'd2, 13'h0000, 8);
    expect_command(CMD_ACT, 1'b0, 2'd2, 13'h321, 8);
    expect_command(CMD_READ, 1'b0, 2'd2, {3'b000,1'b0,9'h012}, 8);

    $display("tb_ssv_sdram_command_timing: PASS");
    $finish;
end
endmodule
