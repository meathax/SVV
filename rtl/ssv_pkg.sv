// SPDX-License-Identifier: GPL-3.0-or-later
// SSV memory / ROM layout. Currently carries the Dyna Gear (SAM-5127) sizes.
`timescale 1ns/1ps

package ssv_pkg;

    // -----------------------------------------------------------------------
    // SDRAM layout.
    //
    // Sizes CONFIRMED against a real SAM-5127 cartridge (28 Jul 2026): the
    // graphics sockets are silkscreened `16M-MASK`, i.e. 16 Mbit (2 MB) mask
    // ROMs, in four banks of four. Dyna Gear populates six of those sixteen
    // positions (6 x 2 MB = 12 MB of graphics) plus two more for samples
    // (4 MB). A fully populated SAM-5127 tops out at 32 MB of graphics, so a
    // family title needing more than that is not a plain SAM-5127 and will
    // need its own layout block below.
    //
    // See docs/hardware/SSV_BOARD_HARDWARE.md.
    //
    // GRAPHICS REPACK (see docs/SDRAM_GFX_REPACK_DESIGN.md).
    //
    // The graphics region is no longer a copy of MAME's sprite ROM. Every
    // 16-pixel tile row occupies one aligned 16-byte record:
    //
    //   byte  0.. 3  MAME graphics quarter 0 -> plane01
    //   byte  4.. 7  quarter 1               -> plane23
    //   byte  8..11  quarter 2               -> plane45
    //   byte 12..15  quarter 3 -- NEVER WRITTEN on Dyna Gear; the fetcher
    //                forces plane67 to zero rather than reading it.
    //
    // so one 128-bit p2 burst supplies a whole row instead of two 64-bit p1
    // bursts. The old SDR_SPRITES_* names are gone deliberately: they now
    // describe something that no longer exists.
    //
    // The region grew 12 MB -> 16 MB (the unwritten quarter-3 slot). To keep
    // XRAM and CPU RAM on their existing bases -- five testbenches hardcode
    // 0x1100000/0x1160000 -- graphics grows into the gap the sample region
    // vacates, and the samples move above CPU RAM. SDR_SAMPLES_BASE is the
    // ONLY constant whose value changes.
    //
    // NOTE: the graphics region ends at 0x10FFFFF and XRAM starts at
    // 0x1100000 -- exactly adjacent, zero slack. Any future growth of the
    // graphics region forces a full re-layout of everything above it.
    // -----------------------------------------------------------------------
    localparam logic [24:0] SDR_MAINCPU_BASE = 25'h0000000; //  1 MB program
    localparam logic [24:0] SDR_GFX_BASE     = 25'h0100000; // 16 MB packed rows

    // CPU-writable regions parked in SDRAM because they do not fit beside the
    // board RAMs in Cyclone V block memory.
    //
    // SDR_CPU_RAM_BASE backs the CPU window at $400000. It was previously
    // called SDR_DYNA_RAM_BASE, which read as though the region were a Dyna
    // Gear invention; it is not, it is the board's RAM at that address.
    localparam logic [24:0] SDR_XRAM_BASE    = 25'h1100000; // $160000 window
    localparam logic [24:0] SDR_CPU_RAM_BASE = 25'h1120000; // $400000 window
    localparam logic [24:0] SDR_SAMPLES_BASE = 25'h1160000; //  4 MB ES5506

    localparam logic [26:0] STREAM_MAINCPU   = 27'h0000000;
    localparam logic [26:0] STREAM_SPRITES   = 27'h0100000;
    localparam logic [26:0] STREAM_SAMPLES   = 27'h0D00000;
    localparam logic [26:0] STREAM_END       = 27'h1100000;

    // Region sizes, so the assertions below are checkable rather than implied.
    localparam logic [24:0] SDR_MAINCPU_SIZE = 25'h0100000; //  1 MB
    localparam logic [24:0] SDR_GFX_SIZE     = 25'h1000000; // 16 MB
    localparam logic [24:0] SDR_XRAM_SIZE    = 25'h0020000; // 128 KB
    localparam logic [24:0] SDR_CPU_RAM_SIZE = 25'h0040000; // 256 KB
    localparam logic [24:0] SDR_SAMPLES_SIZE = 25'h0400000; //  4 MB

    // Raw graphics bytes in the MRA stream: 3 populated quarters x 4 MB.
    // The MRA itself is unchanged; only where the loader puts the bytes is.
    localparam logic [26:0] STREAM_GFX_SIZE  = 27'h0C00000;

    // Quarters the loader writes vs. slots the record reserves. The 4/3
    // expansion in SDR_GFX_SIZE is exactly this ratio, and it is zero for a
    // title that populates all four quarters.
    localparam logic [26:0] GFX_QUARTERS_LOADED = 27'd3;
    localparam logic [26:0] GFX_QUARTERS_PACKED = 27'd4;

    // MiSTer SDRAM module fitted on the target board.
    localparam logic [25:0] SDR_TOTAL_BYTES  = 26'h2000000; // 32 MB

    // -----------------------------------------------------------------------
    // THE authority on where a tile row lives. The ROM loader, the row fetcher
    // and every testbench SDRAM model must call these; a divergence between
    // them is precisely the "wrong ROM load offset" failure that CLAUDE.md
    // warns produces fake bugs.
    //
    // Widths are spelled out because a silent truncation here is the whole
    // bug: {1'b0, code[16:0], 7'd0} = 25, {18'd0, row, 4'd0} = 25,
    // {21'd0, quarter, 2'd0} = 25, {23'd0, byte_in_row} = 25.
    // -----------------------------------------------------------------------
    function automatic logic [24:0] gfx_record_addr(
        input logic [16:0] code, input logic [2:0] row
    );
        gfx_record_addr = SDR_GFX_BASE + {1'b0, code, 7'd0}
                                       + {18'd0, row, 4'd0};
    endfunction

    function automatic logic [24:0] gfx_plane_addr(
        input logic [16:0] code, input logic [2:0] row,
        input logic  [1:0] quarter, input logic [1:0] byte_in_row
    );
        gfx_plane_addr = gfx_record_addr(code, row)
                       + {21'd0, quarter, 2'd0}
                       + {23'd0, byte_in_row};
    endfunction

    // -----------------------------------------------------------------------
    // Layout self-check.
    //
    // A package cannot hold an `initial` block, so the rule lives here as a
    // constant function and ssv_core reports on it at time 0. The point is that
    // when a second title arrives with different ROM sizes, a layout that
    // silently overlaps becomes a loud simulation failure instead of corrupt
    // graphics nobody traces back to this file.
    //
    // Returns 0 if the layout is sound, otherwise the number of the rule that
    // failed, so the message can say which one.
    // -----------------------------------------------------------------------
    function automatic int layout_fault();
        // --- SDRAM regions: ordered, non-overlapping, inside the module ---
        if (SDR_MAINCPU_BASE + SDR_MAINCPU_SIZE > SDR_GFX_BASE)     return 1;
        if (SDR_GFX_BASE     + SDR_GFX_SIZE     > SDR_XRAM_BASE)    return 2;
        if (SDR_XRAM_BASE    + SDR_XRAM_SIZE    > SDR_CPU_RAM_BASE) return 3;
        if (SDR_CPU_RAM_BASE + SDR_CPU_RAM_SIZE > SDR_SAMPLES_BASE) return 4;
        if ({1'b0, SDR_SAMPLES_BASE} + {1'b0, SDR_SAMPLES_SIZE}
                                                > SDR_TOTAL_BYTES)  return 5;

        // --- MRA stream: contiguous, and independent of the SDRAM map ---
        // The repack breaks the old "stream offset == SDRAM base" identity,
        // so these rules check the stream against itself instead.
        if (STREAM_MAINCPU != 27'h0000000)                          return 6;
        if (STREAM_SPRITES != STREAM_MAINCPU + {2'b0, SDR_MAINCPU_SIZE})
                                                                    return 7;
        if (STREAM_SAMPLES != STREAM_SPRITES + STREAM_GFX_SIZE)     return 8;
        if (STREAM_END     != STREAM_SAMPLES + {2'b0, SDR_SAMPLES_SIZE})
                                                                    return 9;

        // --- The repack itself ---
        // Every 12 raw bytes becomes a 16-byte record, so the SDRAM footprint
        // is exactly GFX_QUARTERS_PACKED/GFX_QUARTERS_LOADED of the stream's.
        if ({2'b0, SDR_GFX_SIZE} !=
            (STREAM_GFX_SIZE / GFX_QUARTERS_LOADED) * GFX_QUARTERS_PACKED)
                                                                    return 10;
        // p2 bursts are 16-byte aligned (sdram.sv p2_addr is [24:4]), and the
        // record address is BASE + code<<7 + row<<4, so BASE must be too.
        if (SDR_GFX_BASE[3:0] != 4'd0)                              return 11;
        return 0;
    endfunction

    localparam int SDR_LAYOUT_FAULT = layout_fault();

    // Video timing.
    //
    // CONFIRMED from a photograph of a real STA-0001B motherboard (28 Jul 2026):
    // the board carries two crystals, **42.9545 MHz** and **48.000 MHz**, both
    // legible on the silkscreen next to the can. See
    // docs/hardware/SSV_BOARD_HARDWARE.md.
    //
    //   42.9545 MHz / 6 = 7.159083 MHz pixel clock
    //   7.159083 MHz / (454 x 262) = 60.19 Hz
    //
    // so the divide-by-6 and the totals below are consistent with real board
    // hardware, not just with the emulator they were originally taken from.
    //
    // NOT yet confirmed: the active/blank split (336/240) and the sync pulse
    // positions in ssv_video_timing.sv. Those still need a scope on a board.
    localparam logic [8:0] SSV_HTOTAL  = 9'h1C6; // 454
    localparam logic [8:0] SSV_HBSTART = 9'h150; // 336
    localparam logic [8:0] SSV_VTOTAL  = 9'h106; // 262
    localparam logic [8:0] SSV_VBSTART = 9'h0F0; // 240

endpackage
