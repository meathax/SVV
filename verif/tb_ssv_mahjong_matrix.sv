// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps
module tb_ssv_mahjong_matrix;
	logic clk=0, rst=1, req=0, we=0;
	logic [2:0] mode=0;
	logic [23:0] addr=0, rows=24'hffffff;
	logic [15:0] wdata=0;
	logic [1:0] be=2'b11;
	logic selected;
	logic [15:0] rdata;
	always #5 clk=~clk;
	ssv_mahjong_matrix dut(.*);
	task automatic wr(input [23:0] a, input [15:0] d);
		begin @(negedge clk); req=1; we=1; addr=a; wdata=d; @(negedge clk); req=0; we=0; end
	endtask
	initial begin
		repeat(2) @(negedge clk); rst=0;
		mode=1; rows={6'h3f,6'h3f,6'h3f,6'h3e}; wr(24'hc00006,16'h0001);
		req=1; addr=24'hc00000; #1;
		if (!selected || rdata !== 16'h00fe) $fatal(1,"hypreact select/read %h",rdata);
		req=0; mode=4; rows={6'h3f,6'h3f,6'h3d,6'h3f}; wr(24'hc0000e,16'h0008);
		req=1; addr=24'hc0000a; #1;
		if (!selected || rdata !== 16'hffef) $fatal(1,"srmp4 permutation %h",rdata);
		$display("PASS tb_ssv_mahjong_matrix"); $finish;
	end
endmodule
