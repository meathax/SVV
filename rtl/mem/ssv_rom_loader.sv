// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed Dyna Gear index-0 stream:
//   0x000000..0x0fffff  V60 program (16-bit interleaved by the MRA)
//   0x100000..0xcfffff  sprite graphics; Q0/Q1 are interleaved by row
//                       during download so one 64-bit read supplies four
//                       bitplanes. Q2 stays at 0x900000..0xcfffff.
//   0xd00000..0x10fffff ES5506 sample ROM

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
    logic [23:0] sprite_offset;
    logic [21:0] within_quarter;
    begin
        sprite_offset = stream_addr - STREAM_SPRITES;
        within_quarter = sprite_offset[21:0];
        if ((stream_addr >= STREAM_SPRITES) &&
            (stream_addr < STREAM_SPRITES + 27'h0800000)) begin
            // MAME layout Q0/Q1 are separate 4 MiB quarters. Pack their
            // corresponding 32-bit rows into one aligned 64-bit beat:
            // [31:0]=Q0, [63:32]=Q1.
            //
            // The "quarters" model is supported by the physical board: a
            // SAM-5127 carries four graphics banks A/B/C/D of four `16M-MASK`
            // sockets each, and Dyna Gear populates six of the sixteen (photos,
            // 28 Jul 2026 — docs/hardware/SSV_BOARD_HARDWARE.md). What is *not*
            // established is which physical bank feeds which quarter here. This
            // interleave is known-good only in the sense that Dyna Gear's
            // graphics decode CRC-exact with it; the bank-to-quarter assignment
            // has never been checked against the board. If a second SSV title
            // ever decodes with scrambled graphics under this same loader, this
            // function is the first thing to suspect.
            stream_byte_address = SDR_SPRITES_BASE +
                {2'd0, within_quarter[21:5], 6'd0} +
                {19'd0, within_quarter[4:2], 3'd0} +
                {22'd0, sprite_offset[22], 2'd0} +
                {23'd0, within_quarter[1:0]};
        end
        else begin
            stream_byte_address = stream_addr[24:0];
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
