// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed Dyna Gear index-0 stream (the MRA is unchanged by the repack):
//   0x0000000..0x00fffff  V60 program (16-bit interleaved by the MRA)
//   0x0100000..0x0cfffff  graphics, 3 x 4 MB MAME quarters
//   0x0d00000..0x10fffff  ES5506 sample ROM
//
// SDRAM destinations (ssv_pkg):
//   program  -> 0x0000000 identity
//   graphics -> 0x0100000, repacked into one aligned 16-byte record per
//               16-pixel tile row (Q0|Q1|Q2|pad), so ssv_gfx_row_fetch reads
//               a whole row with one 128-bit p2 burst. 16 MB.
//   samples  -> SDR_SAMPLES_BASE = 0x1160000, above XRAM and CPU RAM. The
//               graphics region grew into the gap the samples vacated.

`timescale 1ns/1ps

module ssv_rom_loader (
    input              clk,
    input              rst,
    input              mem_ready,
    input              ioctl_download,
    input        [7:0] ioctl_index,
    input              ioctl_wr,
    input       [26:0] ioctl_addr,
    input        [7:0] ioctl_dout,
    output             ioctl_wait,
    output logic       sdr_wr_req,
    output logic [24:1] sdr_wr_addr,
    output logic [15:0] sdr_wr_din,
    output logic [1:0] sdr_wr_be,
    input              sdr_wr_ack,
    output logic       rom_loaded,
    // Highest index-0 stream address accepted during the active download.
    // Used by the diagnostic overlay; does not affect load behavior.
    output logic [26:0] download_max_addr
);

import ssv_pkg::*;

logic [7:0] byte_lo;
logic       busy;
logic       index0_seen;

function automatic logic [24:0] stream_byte_address(
    input logic [26:0] stream_addr
);
    logic [23:0] gfx_offset;     // 0 .. 0xBFFFFF within the graphics stream
    logic [21:0] within_quarter; // byte offset inside one 4 MiB quarter
    logic  [1:0] quarter;        // 0=Q0 1=Q1 2=Q2  (Q3 absent on dynagear)
    begin
        gfx_offset     = stream_addr[23:0] - STREAM_SPRITES[23:0];
        within_quarter = gfx_offset[21:0];
        quarter        = gfx_offset[23:22];

        if ((stream_addr >= STREAM_SPRITES) &&
            (stream_addr <  STREAM_SPRITES + STREAM_GFX_SIZE)) begin
            // All THREE populated quarters collapse into one aligned 16-byte
            // record per 16-pixel tile row, so the row fetcher gets a whole
            // row from a single 128-bit p2 burst. Bytes 12..15 of every record
            // are the absent quarter 3 and are deliberately never written --
            // ssv_gfx_row_fetch forces plane67 to zero. If a family title ever
            // populates Q3, this function already places it and only the
            // fetcher's constant has to go.
            //
            // The "quarters" model is supported by the physical board: a
            // SAM-5127 carries four graphics banks A/B/C/D of four `16M-MASK`
            // sockets each, and Dyna Gear populates six of the sixteen (photos,
            // 28 Jul 2026 — docs/hardware/SSV_BOARD_HARDWARE.md). What is *not*
            // established -- and is UNCHANGED by the repack -- is which
            // physical bank feeds which quarter here. The mapping is known-good
            // only in the sense that Dyna Gear's graphics decode CRC-exact with
            // it. If a second SSV title ever decodes with scrambled graphics
            // under this same loader, this function is the first thing to
            // suspect.
            stream_byte_address = gfx_plane_addr(
                within_quarter[21:5],   // tile code
                within_quarter[4:2],    // row within the tile
                quarter,
                within_quarter[1:0]     // byte within the 32-bit row
            );
        end
        else if (stream_addr >= STREAM_SAMPLES) begin
            // The sample region no longer sits at its stream offset: the
            // graphics records displaced it above XRAM and CPU RAM.
            stream_byte_address = SDR_SAMPLES_BASE +
                                  (stream_addr[24:0] - STREAM_SAMPLES[24:0]);
        end
        else begin
            stream_byte_address = stream_addr[24:0];  // V60 program, identity
        end
    end
endfunction

wire [24:0] mapped_ioctl_addr = stream_byte_address(ioctl_addr);

assign ioctl_wait = busy | ~mem_ready;

always_ff @(posedge clk) begin
    if (rst) begin
        byte_lo     <= 8'h00;
        busy        <= 1'b0;
        index0_seen <= 1'b0;
        sdr_wr_req  <= 1'b0;
        sdr_wr_addr <= '0;
        sdr_wr_din  <= '0;
        sdr_wr_be   <= 2'b00;
        rom_loaded  <= 1'b0;
        download_max_addr <= 27'd0;
    end
    else begin
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            busy       <= 1'b0;
        end

        if (mem_ready && ioctl_download && ioctl_wr && !busy &&
            ioctl_index == 8'd0 && ioctl_addr < STREAM_END) begin
            if (ioctl_addr > download_max_addr)
                download_max_addr <= ioctl_addr;
            if (!ioctl_addr[0])
                byte_lo <= ioctl_dout;
            else begin
                sdr_wr_req  <= 1'b1;
                sdr_wr_addr <= mapped_ioctl_addr[24:1];
                sdr_wr_din  <= {ioctl_dout, byte_lo};
                sdr_wr_be   <= 2'b11;
                busy        <= 1'b1;
            end
        end

        if (mem_ready && ioctl_download && ioctl_wr &&
            ioctl_index == 8'd0 && ioctl_addr == 27'd0) begin
            rom_loaded  <= 1'b0;
            index0_seen <= 1'b1;
            download_max_addr <= 27'd0;
        end

        if (mem_ready && !ioctl_download && index0_seen &&
            !busy && !sdr_wr_req) begin
            rom_loaded  <= 1'b1;
            index0_seen <= 1'b0;
        end
    end
end

endmodule
