// SPDX-License-Identifier: GPL-3.0-or-later
// Fixed Dyna Gear index-0 stream:
//   0x000000..0x0fffff  V60 program (16-bit interleaved by the MRA)
//   0x100000..0xcfffff  sprite graphics
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
    output logic       rom_loaded
);

import ssv_pkg::*;

logic [7:0] byte_lo;
logic       busy;
logic       index0_seen;

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
    end
    else begin
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            busy       <= 1'b0;
        end

        if (mem_ready && ioctl_download && ioctl_wr && !busy &&
            ioctl_index == 8'd0 && ioctl_addr < STREAM_END) begin
            if (!ioctl_addr[0])
                byte_lo <= ioctl_dout;
            else begin
                sdr_wr_req  <= 1'b1;
                sdr_wr_addr <= ioctl_addr[24:1];
                sdr_wr_din  <= {ioctl_dout, byte_lo};
                sdr_wr_be   <= 2'b11;
                busy        <= 1'b1;
            end
        end

        if (mem_ready && ioctl_download && ioctl_wr &&
            ioctl_index == 8'd0 && ioctl_addr == 27'd0) begin
            rom_loaded  <= 1'b0;
            index0_seen <= 1'b1;
        end

        if (mem_ready && !ioctl_download && index0_seen &&
            !busy && !sdr_wr_req) begin
            rom_loaded  <= 1'b1;
            index0_seen <= 1'b0;
        end
    end
end

endmodule
