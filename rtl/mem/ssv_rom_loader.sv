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
    output logic [ssv_pkg::SDR_AW:1] sdr_wr_addr,
    output logic [15:0] sdr_wr_din,
    output logic [1:0] sdr_wr_be,
    input              sdr_wr_ack,
    // Per-game configuration, parsed from MRA <rom index="1">.
    output ssv_pkg::ssv_cfg_t cfg,
    output logic       cfg_valid,
    // ST010 data ROM ("dspdata"): 2048 x 16 on chip, so it is written straight
    // into the DSP wrapper's block RAM rather than read back from SDRAM. The
    // program half ("dspprg") is 48 M10K and goes to SDRAM instead.
    output logic       st010_drom_we,
    output logic [10:0] st010_drom_wa,
    output logic [15:0] st010_drom_wd,
    output logic       rom_loaded,
    // Highest index-0 stream address accepted during the active download.
    // Used by the diagnostic overlay; does not affect load behavior.
    output logic [26:0] download_max_addr
);

import ssv_pkg::*;

logic [7:0] byte_lo;
logic       busy;
logic       index0_seen;

// ---------------------------------------------------------------------------
// Per-game configuration, MRA <rom index="1">, 16 bytes little-endian.
//
//   0  magic 'S' (0x53)      8  bank_valid
//   1  version (2)           9  flags0: b0 tile_code_identity
//   2  prog_mb                        b1 irq_level1_line0
//   3  gfx_mb                         b2 has_add_buttons
//                                     b3 has_st010
//   4  gfx_code_k           10  wdog_mode
//   5  gfx_code_mul3        11  game_id
//   6  gfx_quarters         12  samples_mb   (version 2)
//   7  bank_map             13..14 reserved (0)
//                           15  checksum: bytes 0..14 summed, negated
//
// Version 2 added byte 12, samples_mb. Version 1 blocks are REJECTED rather
// than defaulted: a v1 block carries 0 there, and a zero sample size would put
// the st010 block on top of the samples. Rejecting is the same no-fallback rule
// the magic and checksum enforce.
//
// The block MUST precede <rom index="0"> in the MRA, because index-0 bytes
// cannot be placed without knowing the layout. A mis-ordered or malformed
// block leaves cfg_valid low, index 0 is then discarded, rom_loaded never
// asserts and LED_USER stays lit.
//
// There is deliberately NO silent fallback to Dyna Gear defaults. A fallback
// turns a packaging mistake into a corrupt-graphics bug hunt, which is exactly
// the class of fake bug this core has spent effort avoiding elsewhere.
// ---------------------------------------------------------------------------
localparam int CFG_BYTES = 16;
logic [7:0] cfg_raw [0:CFG_BYTES-1];
logic [7:0] cfg_sum;
logic       cfg_seen_last;

function automatic ssv_pkg::ssv_cfg_t cfg_decode();
    cfg_decode = '{
        game_id:            cfg_raw[11][3:0],
        prog_mb:            cfg_raw[2][2:0],
        gfx_mb:             cfg_raw[3][5:0],
        gfx_code_k:         cfg_raw[4][4:0],
        gfx_code_mul3:      cfg_raw[5][0],
        // Derived here, ONCE, rather than in the wrap. As a variable shift in
        // the wrap it cost -12.7 ns on the path to the SDRAM address.
        gfx_code_mask:      (20'd1 << cfg_raw[4][4:0]) - 20'd1,
        gfx_quarters:       cfg_raw[6][2:0],
        samples_mb:         cfg_raw[12][3:0],
        bank_map:           cfg_raw[7],
        bank_valid:         cfg_raw[8][3:0],
        tile_code_identity: cfg_raw[9][0],
        irq_level1_line0:   cfg_raw[9][1],
        has_add_buttons:    cfg_raw[9][2],
        has_st010:          cfg_raw[9][3],
        wdog_mode:          cfg_raw[10][1:0]
    };
endfunction

// ---------------------------------------------------------------------------
// PER-GAME STREAM MAP.
//
// These were STREAM_* localparams holding Dyna Gear's geometry, so no other set
// could load: the graphics quarter stride was hardwired to 4 MB via
// gfx_offset[23:22], gfx_offset itself was 24 bits and so wrapped at 16 MB
// (fatal for Vasara's 32 MB region), and index-0 writes were clipped at
// STREAM_END = 0x1111000, which silently truncated Vasara's 44 MB stream at 39%.
//
// Everything below is computed ONCE, when the config block validates, and held
// in registers. That matters for two reasons:
//
//  * The quarter stride is gfx_mb<<18 -- 2, 3, 4, 6 or 8 MB across the family.
//    3 MB and 6 MB are not powers of two, so recovering the quarter index by
//    arithmetic would need a divide. Instead the three quarter boundaries are
//    precomputed and the lookup is three compares and one subtract. A variable
//    shifter on this exact path cost -12.7 ns once already (commit 2b44914);
//    a divider here would be worse.
//  * ioctl_addr is combinational into the SDRAM write address, so nothing here
//    may depend on the order bytes arrive.
// ---------------------------------------------------------------------------
logic [26:0] str_gfx_base, str_samp_base, str_st010_base, str_end;
logic [26:0] qtr_size, qtr_base1, qtr_base2, qtr_base3;

always_comb begin
    // Region sizes straight out of the record.
    qtr_size       = 27'(cfg.gfx_mb) << 18;            // region / 4
    qtr_base1      = qtr_size;
    qtr_base2      = qtr_size + qtr_size;
    qtr_base3      = qtr_base2 + qtr_size;
    str_gfx_base   = 27'(cfg.prog_mb) << 20;
    // quarters is 3 or 4, so this is a select, not a multiplier.
    str_samp_base  = str_gfx_base +
                     ((cfg.gfx_quarters == 3'd4) ? (qtr_base3 + qtr_size)
                                                 : qtr_base3);
    str_st010_base = str_samp_base + (27'(cfg.samples_mb) << 20);
    str_end        = str_st010_base +
                     (cfg.has_st010 ? STREAM_ST010_SIZE : 27'd0);
end

function automatic logic [SDR_AW:0] stream_byte_address(
    input logic [26:0] stream_addr
);
    logic [26:0] gfx_offset;     // 0 .. 32 MB within the graphics stream
    logic [26:0] within_quarter; // byte offset inside one quarter
    logic  [1:0] quarter;        // which MAME graphics quarter
    begin
        gfx_offset = stream_addr - str_gfx_base;
        // Three compares against precomputed boundaries -- no divide.
        if (gfx_offset >= qtr_base3) begin
            quarter        = 2'd3;
            within_quarter = gfx_offset - qtr_base3;
        end
        else if (gfx_offset >= qtr_base2) begin
            quarter        = 2'd2;
            within_quarter = gfx_offset - qtr_base2;
        end
        else if (gfx_offset >= qtr_base1) begin
            quarter        = 2'd1;
            within_quarter = gfx_offset - qtr_base1;
        end
        else begin
            quarter        = 2'd0;
            within_quarter = gfx_offset;
        end

        if ((stream_addr >= str_gfx_base) &&
            (stream_addr <  str_samp_base)) begin
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
            // 18-bit tile code: a quarter is up to 8 MB (32 MB region / 4), so
            // the code field is within_quarter[22:5]. It was [21:5] when the
            // quarter was hardwired to 4 MB, which is one bit short for every
            // 32 MB title.
            stream_byte_address = gfx_plane_addr(
                within_quarter[22:5],   // tile code
                within_quarter[4:2],    // row within the tile
                quarter,
                within_quarter[1:0]     // byte within the 32-bit row
            );
        end
        else if (stream_addr >= str_st010_base) begin
            // st010.bin, placed contiguously in the free bank 2. MUST be tested
            // before the sample branch below, which is an open-ended `>=`.
            stream_byte_address = st010_stream_dest(stream_addr, str_st010_base);
        end
        else if (stream_addr >= str_samp_base) begin
            // The sample region no longer sits at its stream offset: the
            // graphics records displaced it above XRAM and CPU RAM.
            stream_byte_address = SDR_SAMPLES_BASE +
                                  (stream_addr[SDR_AW:0] - str_samp_base[SDR_AW:0]);
        end
        else begin
            stream_byte_address = stream_addr[SDR_AW:0];  // V60 program, identity
        end
    end
endfunction

wire [SDR_AW:0] mapped_ioctl_addr = stream_byte_address(ioctl_addr);

// The "dspdata" half of st010.bin also feeds the DSP's on-chip 2048 x 16 data
// ROM. MAME's region is ROM_REGION16_BE, so the word at index i is
// { rom[2i], rom[2i+1] } -- the OPPOSITE order from the little-endian pairing
// the SDRAM path uses, which is why wd is {byte_lo, ioctl_dout} and not
// {ioctl_dout, byte_lo}.
// Per-game st010 window. Also gated on has_st010 so a set without the
// daughterboard can never write the DSP data ROM even if str_st010_base happens
// to coincide with the end of its stream.
wire st010_data_byte = cfg.has_st010 &&
                       (ioctl_addr >= str_st010_base + ST010_DATA_OFFSET) &&
                       (ioctl_addr <  str_st010_base + STREAM_ST010_SIZE);

assign ioctl_wait = busy | ~mem_ready;

always_ff @(posedge clk) begin
    if (rst) begin
        byte_lo     <= 8'h00;
        busy        <= 1'b0;
        index0_seen <= 1'b0;
        cfg_valid   <= 1'b0;
        cfg_seen_last <= 1'b0;
        cfg         <= '0;
        sdr_wr_req  <= 1'b0;
        sdr_wr_addr <= '0;
        sdr_wr_din  <= '0;
        sdr_wr_be   <= 2'b00;
        rom_loaded  <= 1'b0;
        download_max_addr <= 27'd0;
        st010_drom_we <= 1'b0;
        st010_drom_wa <= '0;
        st010_drom_wd <= '0;
    end
    else begin
        st010_drom_we <= 1'b0;
        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            busy       <= 1'b0;
        end

        // --- index 1: capture the configuration block ---
        if (ioctl_download && ioctl_wr && ioctl_index == 8'd1 &&
            ioctl_addr < CFG_BYTES) begin
            cfg_raw[ioctl_addr[3:0]] <= ioctl_dout;
            cfg_seen_last <= (ioctl_addr == CFG_BYTES - 1);
        end

        // Validate one cycle after the last byte lands, so cfg_raw is settled.
        if (cfg_seen_last) begin
            cfg_seen_last <= 1'b0;
            cfg_sum = 8'd0;
            for (int i = 0; i < CFG_BYTES - 1; i++)
                cfg_sum = cfg_sum + cfg_raw[i];
            // Version 2. A v1 block carries 0 in byte 12, and a zero
            // samples_mb would place the st010 block on top of the samples, so
            // an old block is rejected rather than defaulted -- same rule as the
            // magic and the checksum.
            cfg_valid <= (cfg_raw[0] == 8'h53) && (cfg_raw[1] == 8'd2) &&
                         (cfg_raw[CFG_BYTES-1] == (-cfg_sum));
            cfg <= cfg_decode();
        end

        if (mem_ready && ioctl_download && ioctl_wr && !busy && cfg_valid &&
            ioctl_index == 8'd0 && ioctl_addr < str_end) begin
            if (ioctl_addr > download_max_addr)
                download_max_addr <= ioctl_addr;
            if (!ioctl_addr[0])
                byte_lo <= ioctl_dout;
            else begin
                sdr_wr_req  <= 1'b1;
                sdr_wr_addr <= mapped_ioctl_addr[SDR_AW:1];
                sdr_wr_din  <= {ioctl_dout, byte_lo};
                sdr_wr_be   <= 2'b11;
                busy        <= 1'b1;
                // Second destination for the same pair of bytes. Big-endian, so
                // byte_lo (the EVEN stream byte) is the HIGH half of the word.
                if (st010_data_byte) begin
                    st010_drom_we <= 1'b1;
                    st010_drom_wa <= st010_drom_word(ioctl_addr, str_st010_base);
                    st010_drom_wd <= {byte_lo, ioctl_dout};
                end
            end
        end

        if (mem_ready && ioctl_download && ioctl_wr && cfg_valid &&
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
