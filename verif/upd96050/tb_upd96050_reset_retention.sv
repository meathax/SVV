// SPDX-License-Identifier: GPL-3.0-or-later
// MAME uPD96050 device_start versus device_reset retention contract.
`timescale 1ns/1ps

module tb_upd96050_reset_retention;
logic clk = 1'b0;
always #5 clk = ~clk;

logic rst = 1'b0;
logic soft_rst = 1'b0;
logic ce = 1'b0;
logic [23:0] prom [0:16383];
wire [13:0] prg_addr;
wire prg_req;
wire [23:0] prg_data = prom[prg_addr];
wire prg_valid = prg_req;
wire [11:0] drom_addr;

logic host_dp_rd = 1'b0, host_dp_wr = 1'b0;
logic [7:0] host_dp_din = 8'h00;
wire [7:0] host_dp_dout, host_sr;
logic [10:0] host_ram_addr = 11'd0;
logic host_ram_high = 1'b0;
logic host_ram_wr = 1'b0;
logic [7:0] host_ram_din = 8'h00;
wire [7:0] host_ram_dout;

wire dbg_retire;
wire [13:0] dbg_pc;
wire [15:0] dbg_a, dbg_b, dbg_k, dbg_dp, dbg_rp, dbg_dr, dbg_sr;
wire [5:0] dbg_flaga, dbg_flagb;

upd96050 dut (
    .clk(clk), .ce(ce), .rst(rst), .soft_rst(soft_rst),
    .prg_addr(prg_addr), .prg_req(prg_req),
    .prg_data(prg_data), .prg_valid(prg_valid),
    .drom_addr(drom_addr), .drom_data(16'h0000),
    .host_dp_rd(host_dp_rd), .host_dp_wr(host_dp_wr),
    .host_dp_din(host_dp_din), .host_dp_dout(host_dp_dout),
    .host_sr(host_sr),
    .host_ram_addr(host_ram_addr), .host_ram_high(host_ram_high),
    .host_ram_wr(host_ram_wr), .host_ram_din(host_ram_din),
    .host_ram_dout(host_ram_dout),
    .int_req(1'b0), .p0(), .p1(),
    .dbg_retire(dbg_retire), .dbg_pc(dbg_pc),
    .dbg_a(dbg_a), .dbg_b(dbg_b),
    .dbg_flaga(dbg_flaga), .dbg_flagb(dbg_flagb),
    .dbg_k(dbg_k), .dbg_l(), .dbg_m(), .dbg_n(),
    .dbg_dp(dbg_dp), .dbg_rp(dbg_rp), .dbg_tr(), .dbg_trb(),
    .dbg_dr(dbg_dr), .dbg_sr(dbg_sr), .dbg_so(), .dbg_idb(), .dbg_sp()
);

`include "upd96050_asm.svh"

task automatic check(input logic condition, input string message);
    if (!condition)
        $fatal(1, "uPD96050 reset retention: %s", message);
endtask

task automatic step;
    @(negedge clk);
    ce = 1'b1;
    @(negedge clk);
    ce = 1'b0;
    while (!dbg_retire)
        @(negedge clk);
endtask

task automatic ram_poke(input logic [10:0] addr,
                         input logic [15:0] data);
    @(negedge clk);
    host_ram_addr = addr;
    host_ram_high = 1'b0;
    host_ram_din = data[7:0];
    host_ram_wr = 1'b1;
    @(negedge clk);
    host_ram_high = 1'b1;
    host_ram_din = data[15:8];
    @(negedge clk);
    host_ram_wr = 1'b0;
    host_ram_high = 1'b0;
endtask

task automatic ram_peek(input logic [10:0] addr,
                         output logic [15:0] data);
    @(negedge clk);
    host_ram_addr = addr;
    host_ram_high = 1'b0;
    @(posedge clk); #1;
    data[7:0] = host_ram_dout;
    @(negedge clk);
    host_ram_high = 1'b1;
    @(posedge clk); #1;
    data[15:8] = host_ram_dout;
endtask

integer i;
logic [15:0] ram_value;
initial begin
    for (i = 0; i < 16384; i = i + 1)
        prom[i] = 24'h000000;

    // Seed retained registers, status/flags, and data RAM.
    prom[0] = LDW(16'h7fff, 4'd1);   // A
    prom[1] = LDW(16'h5678, 4'd2);   // B
    prom[2] = LDW(16'h0123, 4'd4);   // DP
    prom[3] = LDW(16'h0456, 4'd5);   // RP
    prom[4] = LDW(16'h1111, 4'd10);  // K
    prom[5] = LDW(16'h9abc, 4'd6);   // DR + RQM
    prom[6] = LDW(16'he783, 4'd7);   // nonzero SR fields
    prom[7] = ALUI(4'h9, 1'b0, 4'd0); // INC A, nonzero flags

    rst = 1'b1;
    repeat (2060) @(posedge clk); // complete the 2048-word cold clear
    @(negedge clk);
    rst = 1'b0;
    repeat (8) step();
    ram_poke(11'h155, 16'hc35a);
    ram_peek(11'h155, ram_value);
    check(ram_value == 16'hc35a, "host RAM seed failed");
    check(dbg_a == 16'h8000 && dbg_b == 16'h5678,
          "register seed failed");
    check(dbg_dp == 16'h0123 && dbg_rp == 16'h0456 &&
          dbg_k == 16'h1111 && dbg_dr == 16'h9abc,
          "retained-register seed failed");
    check(dbg_sr != 16'h0000 && dbg_flaga != 6'd0,
          "reset-cleared fields were not seeded");

    // MAME device_reset: clear PC/SR/flags, preserve general registers and RAM.
    @(negedge clk);
    soft_rst = 1'b1;
    @(posedge clk); #1;
    soft_rst = 1'b0;
    check(dbg_pc == 14'd0 && dbg_sr == 16'h0000 &&
          dbg_flaga == 6'd0 && dbg_flagb == 6'd0,
          "soft reset did not clear PC/SR/flags");
    check(dbg_a == 16'h8000 && dbg_b == 16'h5678 &&
          dbg_dp == 16'h0123 && dbg_rp == 16'h0456 &&
          dbg_k == 16'h1111 && dbg_dr == 16'h9abc,
          "soft reset destroyed retained registers");
    ram_peek(11'h155, ram_value);
    check(ram_value == 16'hc35a, "soft reset destroyed data RAM");

    // Cold/download reset is device-start state and clears both.
    @(negedge clk);
    rst = 1'b1;
    repeat (2060) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    check(dbg_a == 16'h0000 && dbg_b == 16'h0000 &&
          dbg_dp == 16'h0000 && dbg_rp == 16'h0000 &&
          dbg_k == 16'h0000 && dbg_dr == 16'h0000,
          "cold reset did not clear general registers");
    ram_peek(11'h155, ram_value);
    check(ram_value == 16'h0000, "cold reset did not clear data RAM");

    $display("UPD96050 RESET RETENTION PASS");
    $finish;
end
endmodule
