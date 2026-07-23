// SPDX-License-Identifier: GPL-3.0-or-later
// Fetch one 16-pixel SSV graphics row from four 3 MiB ROM quarters.
`timescale 1ns/1ps

module ssv_gfx_row_fetch (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [19:0] tile_code,
    input  logic  [2:0] tile_row,

    output logic        rom_req,
    output logic [24:3] rom_addr,
    input  logic [63:0] rom_data,
    input  logic        rom_ack,

    output logic        busy,
    output logic        done,
    output logic [31:0] plane01,
    output logic [31:0] plane23,
    output logic [31:0] plane45,
    output logic [31:0] plane67
);

localparam logic [24:0] SPRITE_BASE = 25'h0100000;
localparam logic [24:0] QUARTER_SIZE = 25'h0300000;
localparam logic [19:0] TILE_COUNT = 20'h18000;

typedef enum logic [1:0] {IDLE, WAIT_ACK, WAIT_ACK_LOW} state_t;
state_t state;
logic [1:0] quarter;
logic [19:0] code_latched;
logic [2:0] row_latched;

function automatic logic [19:0] wrap_code(input logic [19:0] code);
    logic [19:0] reduced;
    begin
        reduced = code;
        if (reduced >= 20'hc0000) reduced = reduced - 20'hc0000;
        if (reduced >= 20'h60000) reduced = reduced - 20'h60000;
        if (reduced >= 20'h30000) reduced = reduced - 20'h30000;
        if (reduced >= TILE_COUNT) reduced = reduced - TILE_COUNT;
        wrap_code = reduced;
    end
endfunction

function automatic logic [24:3] fetch_address(
    input logic [1:0]  which_quarter,
    input logic [19:0] code,
    input logic [2:0]  row
);
    logic [24:0] byte_address;
    begin
        byte_address = SPRITE_BASE +
                       (which_quarter * QUARTER_SIZE) +
                       ({5'd0, wrap_code(code)} << 5) +
                       ({22'd0, row} << 2);
        fetch_address = byte_address[24:3];
    end
endfunction

wire [31:0] selected_row = row_latched[0] ? rom_data[63:32]
                                                        : rom_data[31:0];

always_ff @(posedge clk) begin
    if (rst) begin
        state        <= IDLE;
        quarter      <= 2'd0;
        code_latched <= 20'd0;
        row_latched  <= 3'd0;
        rom_req      <= 1'b0;
        rom_addr     <= '0;
        busy         <= 1'b0;
        done         <= 1'b0;
        plane01      <= 32'd0;
        plane23      <= 32'd0;
        plane45      <= 32'd0;
        plane67      <= 32'd0;
    end
    else begin
        done <= 1'b0;
        unique case (state)
            IDLE: begin
                rom_req <= 1'b0;
                busy    <= 1'b0;
                if (start) begin
                    code_latched <= tile_code;
                    row_latched  <= tile_row;
                    quarter      <= 2'd0;
                    rom_addr     <= fetch_address(2'd0, tile_code, tile_row);
                    rom_req      <= 1'b1;
                    busy         <= 1'b1;
                    state        <= WAIT_ACK;
                end
            end

            WAIT_ACK: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    unique case (quarter)
                        2'd0: plane01 <= selected_row;
                        2'd1: plane23 <= selected_row;
                        2'd2: plane45 <= selected_row;
                        2'd3: plane67 <= selected_row;
                    endcase
                    if (quarter == 2'd3) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= IDLE;
                    end
                    else begin
                        state <= WAIT_ACK_LOW;
                    end
                end
            end

            WAIT_ACK_LOW: begin
                if (!rom_ack) begin
                    quarter  <= quarter + 1'd1;
                    rom_addr <= fetch_address(
                        quarter + 1'd1, code_latched, row_latched
                    );
                    rom_req <= 1'b1;
                    state   <= WAIT_ACK;
                end
            end
        endcase
    end
end

endmodule
