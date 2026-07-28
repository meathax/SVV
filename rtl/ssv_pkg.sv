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
    // -----------------------------------------------------------------------
    localparam logic [24:0] SDR_MAINCPU_BASE = 25'h0000000; // 1 MB  program
    localparam logic [24:0] SDR_SPRITES_BASE = 25'h0100000; // 12 MB graphics
    localparam logic [24:0] SDR_SAMPLES_BASE = 25'h0D00000; // 4 MB  ES5506

    // CPU-writable regions parked in SDRAM because they do not fit beside the
    // board RAMs in Cyclone V block memory.
    //
    // SDR_CPU_RAM_BASE backs the CPU window at $400000. It was previously
    // called SDR_DYNA_RAM_BASE, which read as though the region were a Dyna
    // Gear invention; it is not, it is the board's RAM at that address.
    localparam logic [24:0] SDR_XRAM_BASE    = 25'h1100000; // $160000 window
    localparam logic [24:0] SDR_CPU_RAM_BASE = 25'h1120000; // $400000 window

    localparam logic [26:0] STREAM_MAINCPU   = 27'h0000000;
    localparam logic [26:0] STREAM_SPRITES   = 27'h0100000;
    localparam logic [26:0] STREAM_SAMPLES   = 27'h0D00000;
    localparam logic [26:0] STREAM_END       = 27'h1100000;

    // Region sizes, so the assertions below are checkable rather than implied.
    localparam logic [24:0] SDR_MAINCPU_SIZE = 25'h0100000; //  1 MB
    localparam logic [24:0] SDR_SPRITES_SIZE = 25'h0C00000; // 12 MB
    localparam logic [24:0] SDR_SAMPLES_SIZE = 25'h0400000; //  4 MB
    localparam logic [24:0] SDR_XRAM_SIZE    = 25'h0020000; // 128 KB
    localparam logic [24:0] SDR_CPU_RAM_SIZE = 25'h0040000; // 256 KB

    // MiSTer SDRAM module fitted on the target board.
    localparam logic [25:0] SDR_TOTAL_BYTES  = 26'h2000000; // 32 MB

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
        if (SDR_MAINCPU_BASE + SDR_MAINCPU_SIZE > SDR_SPRITES_BASE) return 1;
        if (SDR_SPRITES_BASE + SDR_SPRITES_SIZE > SDR_SAMPLES_BASE) return 2;
        if (SDR_SAMPLES_BASE + SDR_SAMPLES_SIZE > SDR_XRAM_BASE)    return 3;
        if (SDR_XRAM_BASE    + SDR_XRAM_SIZE    > SDR_CPU_RAM_BASE) return 4;
        if ({1'b0, SDR_CPU_RAM_BASE} + {1'b0, SDR_CPU_RAM_SIZE}
                                                > SDR_TOTAL_BYTES)  return 5;
        if (STREAM_MAINCPU != {2'b0, SDR_MAINCPU_BASE})             return 6;
        if (STREAM_SPRITES != {2'b0, SDR_SPRITES_BASE})             return 7;
        if (STREAM_SAMPLES != {2'b0, SDR_SAMPLES_BASE})             return 8;
        if (STREAM_END     != {2'b0, SDR_XRAM_BASE})                return 9;
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
