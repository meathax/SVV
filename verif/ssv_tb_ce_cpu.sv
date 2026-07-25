// SPDX-License-Identifier: GPL-3.0-or-later
// MAME-accurate V60 clock enable for SSV benches.
// Matches Arcade-SSV.sv: 21702/65536 * clk ~= 16 MHz at 48.317307 MHz.
// Wired into realrom/hang/frame TBs with sticky multi-cycle SDRAM acks
// (see DYNAGEAR_NATURAL_IRQ_SKEW).
`timescale 1ns/1ps

module ssv_tb_ce_cpu (
    input  logic clk,
    input  logic rst,
    output logic ce_cpu
);
    logic [15:0] cpu_acc;
    always_ff @(posedge clk) begin
        logic [16:0] cpu_sum;
        if (rst) begin
            cpu_acc <= 16'd0;
            ce_cpu  <= 1'b0;
        end else begin
            cpu_sum = {1'b0, cpu_acc} + 17'd21702;
            ce_cpu  <= cpu_sum[16];
            cpu_acc <= cpu_sum[15:0];
        end
    end
endmodule
