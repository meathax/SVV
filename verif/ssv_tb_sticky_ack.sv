// SPDX-License-Identifier: GPL-3.0-or-later
// Sticky one-beat SDRAM ack: assert until req falls so fractional CE cannot miss it.
`timescale 1ns/1ps

module ssv_tb_sticky_ack (
    input  logic clk,
    input  logic rst,
    input  logic req,
    output logic ack
);
    logic pending;
    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= 1'b0;
            ack     <= 1'b0;
        end else begin
            if (req && !pending) begin
                pending <= 1'b1;
                ack     <= 1'b1;
            end else if (pending) begin
                ack <= 1'b1;
                if (!req) begin
                    pending <= 1'b0;
                    ack     <= 1'b0;
                end
            end else begin
                ack <= 1'b0;
            end
        end
    end
endmodule
