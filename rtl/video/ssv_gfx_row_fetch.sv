// SPDX-License-Identifier: GPL-3.0-or-later
// Fetch one 16-pixel Dyna Gear tile row with a single 128-bit SDRAM burst.
//
// The ROM loader packs the three populated MAME graphics quarters into one
// aligned 16-byte record per tile row (ssv_pkg::gfx_record_addr), so what used
// to be two serial p1 transactions -- the packed Q0/Q1 beat, then the Q2 beat
// of which half was discarded -- is now one p2 transaction. MAME's absent
// fourth quarter reads as zero.
`timescale 1ns/1ps

module ssv_gfx_row_fetch (
    input  logic         clk,
    input  logic         rst,
    input  logic         start,
    input  logic  [19:0] tile_code,
    input  logic   [2:0] tile_row,

    output logic         rom_req,
    output logic  [24:4] rom_addr,
    input  logic [127:0] rom_data,
    input  logic         rom_ack,

    output logic         busy,
    output logic         done,
    output logic  [31:0] plane01,
    output logic  [31:0] plane23,
    output logic  [31:0] plane45,
    output logic  [31:0] plane67
);

import ssv_pkg::*;

typedef enum logic {IDLE, WAIT_ACK} state_t;
state_t state;

function automatic logic [16:0] wrap_code(input logic [19:0] code);
    // MAME's 16 MiB region contains 0x20000 16x8 tiles.
    wrap_code = code[16:0];
endfunction

// Quartus 17's Verilog parser rejects a bit-select applied straight to a
// function call: `gfx_record_addr(...)[24:4]` is a syntax error there even
// though the simulator accepts it. Naming the result keeps both toolchains
// happy. (A comment line may not begin with the simulator's name either --
// that is read as a lint pragma.)
wire [24:0] start_record_addr =
    gfx_record_addr(wrap_code(tile_code), tile_row);

always_ff @(posedge clk) begin
    if (rst) begin
        state    <= IDLE;
        rom_req  <= 1'b0;
        rom_addr <= '0;
        busy     <= 1'b0;
        done     <= 1'b0;
        plane01  <= 32'd0;
        plane23  <= 32'd0;
        plane45  <= 32'd0;
        plane67  <= 32'd0;
    end
    else begin
        done <= 1'b0;
        unique case (state)
            IDLE: begin
                rom_req <= 1'b0;
                busy    <= 1'b0;
                if (start) begin
                    rom_addr <= start_record_addr[24:4];
                    rom_req  <= 1'b1;
                    busy     <= 1'b1;
                    state    <= WAIT_ACK;
                end
            end

            WAIT_ACK: begin
                if (rom_ack) begin
                    rom_req <= 1'b0;
                    plane01 <= rom_data[31:0];
                    plane23 <= rom_data[63:32];
                    plane45 <= rom_data[95:64];
                    // Bytes 12..15 are the record's quarter-3 slot. The loader
                    // never writes them, so they are whatever the chip powered
                    // up holding -- X in a chip-model simulation. This constant
                    // is therefore load-bearing, not cosmetic: do NOT "improve"
                    // it to rom_data[127:96] unless GFX_QUARTERS_LOADED becomes
                    // 4.
                    plane67 <= 32'd0;
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    state   <= IDLE;
                end
            end
        endcase
    end
end

endmodule
