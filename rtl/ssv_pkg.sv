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
    // BANK MAP (128 MB module: 64M x 16 = 4 banks x 8192 rows x 2048 cols).
    //
    // The controller decodes bank from word address bits [26:25], i.e. BYTE
    // address [27:26], so each bank is 32 MB:
    //
    //   bank 0  0x0000000  V60 program, XRAM ($160000), CPU RAM ($400000)
    //   bank 1  0x2000000  packed graphics records
    //   bank 2  0x4000000  free
    //   bank 3  0x6000000  ES5506 samples
    //
    // Regions are placed in SEPARATE banks on purpose, and it is not
    // cosmetic. Every bank holds one open row; two clients in the same bank
    // evict each other's row and pay PRE + tRP + ACT + tRCD = 6 clk_ram, twice.
    //
    // Measured (docs/PHASE0_MEASUREMENT.md): with the old 32 MB map the whole
    // layout fell inside one bank once the geometry widened, and row conflicts
    // rose from 564,030 to 1,033,032 over 215 gameplay frames while the
    // graphics port's row-hit rate fell from 92.0% to 89.0%. Separating the
    // regions is what takes that back.
    //
    // Do NOT "tidy" these into one contiguous ascending block. layout_fault()
    // below checks pairwise non-overlap precisely so this map is legal.

    localparam int SDR_AW = 26;

    localparam logic [SDR_AW:0] SDR_MAINCPU_BASE = 27'h0000000; // bank 0
    localparam logic [SDR_AW:0] SDR_GFX_BASE     = 27'h2000000; // bank 1

    // CPU-writable regions parked in SDRAM because they do not fit beside the
    // board RAMs in Cyclone V block memory.
    //
    // SDR_CPU_RAM_BASE backs the CPU window at $400000. It was previously
    // called SDR_DYNA_RAM_BASE, which read as though the region were a Dyna
    // Gear invention; it is not, it is the board's RAM at that address.
    localparam logic [SDR_AW:0] SDR_XRAM_BASE    = 27'h0400000; // bank 0
    localparam logic [SDR_AW:0] SDR_CPU_RAM_BASE = 27'h0420000; // bank 0
    localparam logic [SDR_AW:0] SDR_SAMPLES_BASE = 27'h6000000; // bank 3

    // ST010 (NEC uPD96050) program ROM, for the three drifto94_state titles.
    //
    // Bank 2 was entirely free, so this costs nothing in row conflicts: the
    // DSP's fetch port never shares a bank with the V60, the graphics fetcher
    // or the sample engine, and 68 KB is 17 of the bank's 8192 rows.
    //
    // The whole 69,632-byte st010.bin image is placed here contiguously:
    //   + 0x00000 .. 0x0ffff   "dspprg", 16384 x 32-bit big-endian, 24 used
    //   + 0x10000 .. 0x10fff   "dspdata", 2048 x 16-bit big-endian
    // Only the program half is ever READ from SDRAM -- the data half is 4 M10K
    // on chip and is written there directly by the loader -- but placing both
    // keeps the loader's stream mapping a single identity offset instead of a
    // special case, and the 4 KB costs nothing.
    //
    // The base MUST be 8-byte aligned: program fetch uses the controller's
    // 64-bit p5 port, whose address is [SDR_AW:3].
    localparam logic [SDR_AW:0] SDR_ST010_BASE = 27'h4000000; // bank 2

    // Sizes of the regions inside the MRA index-0 STREAM. These are the
    // shipped game's actual byte counts and are NOT the SDRAM slot sizes
    // below; conflating the two is why the map previously only described
    // Dyna Gear.
    localparam logic [26:0] STREAM_MAINCPU_SIZE = 27'h0100000; //  1 MB
    localparam logic [26:0] STREAM_SAMPLES_SIZE = 27'h0400000; //  4 MB

    localparam logic [26:0] STREAM_MAINCPU   = 27'h0000000;
    localparam logic [26:0] STREAM_SPRITES   = 27'h0100000;
    localparam logic [26:0] STREAM_SAMPLES   = 27'h0D00000;
    // st010.bin, appended after the samples. Present only in the MRAs for the
    // three drifto94_state titles; a title without it simply never sends bytes
    // in this range, which is why extending STREAM_END is not observable for
    // Dyna Gear.
    localparam logic [26:0] STREAM_ST010      = 27'h1100000;
    localparam logic [26:0] STREAM_ST010_SIZE = 27'h0011000; // 69,632 bytes
    localparam logic [26:0] STREAM_END       = 27'h1111000;

    // Byte offset inside st010.bin where "dspdata" begins (ssv.cpp ROM_COPY).
    localparam logic [26:0] ST010_DATA_OFFSET = 27'h0010000;

    // Region sizes, so the assertions below are checkable rather than implied.
    localparam logic [SDR_AW:0] SDR_MAINCPU_SIZE = 27'h0400000; //  4 MB slot
    localparam logic [SDR_AW:0] SDR_GFX_SIZE     = 27'h2000000; // 32 MB slot
    localparam logic [SDR_AW:0] SDR_XRAM_SIZE    = 27'h0020000; // 128 KB
    localparam logic [SDR_AW:0] SDR_CPU_RAM_SIZE = 27'h0040000; // 256 KB
    localparam logic [SDR_AW:0] SDR_SAMPLES_SIZE = 27'h0800000; //  8 MB slot
    localparam logic [SDR_AW:0] SDR_ST010_SIZE   = 27'h0011000; // 68 KB exact

    // Raw graphics bytes in the MRA stream: 3 populated quarters x 4 MB.
    // The MRA itself is unchanged; only where the loader puts the bytes is.
    localparam logic [26:0] STREAM_GFX_SIZE  = 27'h0C00000;

    // Quarters the loader writes vs. slots the record reserves. The 4/3
    // expansion in SDR_GFX_SIZE is exactly this ratio, and it is zero for a
    // title that populates all four quarters.
    localparam logic [26:0] GFX_QUARTERS_LOADED = 27'd3;
    localparam logic [26:0] GFX_QUARTERS_PACKED = 27'd4;

    // MiSTer SDRAM module fitted on the target board.
    localparam logic [SDR_AW+1:0] SDR_TOTAL_BYTES = 28'h8000000; // 128 MB

    // -----------------------------------------------------------------------
    // PER-GAME CONFIGURATION
    //
    // The core is being generalised from Dyna Gear to nine SSV titles. What
    // varies between them is small but not derivable from the ROM stream, so
    // it is carried explicitly. Sizes come from MAME's ROM_REGION declarations
    // (src/mame/seta/ssv.cpp), which is the authority for every field here.
    //
    // Tile-code wrapping is the subtle one. MAME does
    // `code % gfxelement->elements()` (ssv_v.cpp), a true MODULO, and
    // elements() = sprites_region / 128:
    //
    //   ultrax                       0xC00000 -> 0x18000 = 3 * 2^15
    //   dynagear                    0x1000000 -> 0x20000 =     2^17
    //   survarts/twineag2/stmblade  0x1800000 -> 0x30000 = 3 * 2^16
    //   cairblad/drifto94/vasara*   0x2000000 -> 0x40000 =     2^18
    //
    // Three of the nine are NOT powers of two, so the existing
    // `wrap_code = code[16:0]` mask is wrong for them twice over: wrong width
    // and wrong wrap rule. Every case is either 2^k or 3*2^k, and for 3*2^k
    //     code % (3<<k) == ((code >> k) % 3) << k | code[k-1:0]
    // with (code>>k) at most 5 bits, so the modulo is a small LUT rather than
    // a divider.
    // -----------------------------------------------------------------------
    typedef struct packed {
        logic [3:0] game_id;
        logic [2:0] prog_mb;            // 1, 2 or 4
        logic [5:0] gfx_mb;             // 12, 16, 24 or 32 (MAME region size)
        logic [4:0] gfx_code_k;         // tile modulus exponent
        logic       gfx_code_mul3;      // modulus is 3<<k, not 1<<k
        // (1<<gfx_code_k)-1, precomputed. It is derived, not independent, but
        // it MUST be a stored field rather than recomputed in the wrap: as a
        // variable shift it put a 20-bit barrel shifter in the combinational
        // path from this record to the SDRAM address and cost -12.7 ns.
        logic [19:0] gfx_code_mask;
        logic [2:0] gfx_quarters;       // populated quarters: 3 or 4
        logic [7:0] bank_map;           // 2 bits per ES5506 CR bank
        logic [3:0] bank_valid;         // which CR banks carry data
        logic       tile_code_identity; // init_ssv_tilescram vs init_ssv
        logic       irq_level1_line0;   // init_ssv_irq1 (twineag2, ultrax)
        logic       has_add_buttons;    // decodes $500008 (survarts)
        // ST010 (uPD96050) daughterboard present: drifto94, stmblade, twineag2.
        // Carried in the spare bit 3 of the config block's flags0 byte, beside
        // tile_code_identity / irq_level1_line0 / has_add_buttons.
        logic       has_st010;
        logic [1:0] wdog_mode;          // 0 none, 1 read-kick, 2 write-kick
    } ssv_cfg_t;

    // Dyna Gear (SAM-5127). Reproduces today's hardwired behaviour exactly, so
    // it is the reference the generalisation is regression-tested against.
    function automatic ssv_cfg_t cfg_dynagear();
        cfg_dynagear = '{
            game_id:            4'd0,
            prog_mb:            3'd1,
            gfx_mb:             6'd16,
            gfx_code_k:         5'd17,   // 0x20000 tiles
            gfx_code_mul3:      1'b0,
            gfx_code_mask:      20'h1FFFF, // (1<<17)-1
            gfx_quarters:       3'd3,    // quarter 3 never populated
            bank_map:           8'b11_10_01_00,
            bank_valid:         4'b0100, // bank 2 only
            tile_code_identity: 1'b0,
            irq_level1_line0:   1'b0,
            has_add_buttons:    1'b0,
            has_st010:          1'b0,
            wdog_mode:          2'd1     // read-kick at $210000
        };
    endfunction

    // code % (mul3 ? 3<<k : 1<<k), returned at the full 18 bits a 32 MB
    // graphics region needs (0x40000 tiles).
    // n mod 3 for a 5-bit n, as a LUT. This is what the comment above always
    // claimed the implementation was; writing `high % 20'd3` instead put a
    // 20-bit divider in the SDRAM address path.
    //
    // Five bits is sufficient and not a guess: the modulus is 3<<k with
    // k = 15..18 across the four SSV graphics region sizes, and the code is 20
    // bits, so code>>k is at most 20-15 = 5 bits. Rule 14 in layout_fault()
    // bounds the region against the code width, which is what keeps that true.
    function automatic logic [1:0] mod3_5(input logic [4:0] n);
        case (n % 5'd3)
            5'd0:    mod3_5 = 2'd0;
            5'd1:    mod3_5 = 2'd1;
            default: mod3_5 = 2'd2;
        endcase
    endfunction

    function automatic logic [17:0] wrap_code_cfg(
        input ssv_cfg_t cfg, input logic [19:0] code
    );
        logic  [4:0] high5;
        logic  [1:0] rem3;
        logic [19:0] low;
        // One AND against the stored mask -- no shifter.
        low = code & cfg.gfx_code_mask;
        if (!cfg.gfx_code_mul3) begin
            wrap_code_cfg = 18'(low);
        end
        else begin
            // The only remaining variable shifts. Truncating to 5 bits BEFORE
            // the mod is the whole point: it turns a 20-bit divide into a
            // 32-entry lookup.
            high5 = 5'(code >> cfg.gfx_code_k);
            rem3  = mod3_5(high5);
            wrap_code_cfg = 18'(low | (20'(rem3) << cfg.gfx_code_k));
        end
    endfunction

    // -----------------------------------------------------------------------
    // THE authority on where a tile row lives. The ROM loader, the row fetcher
    // and every testbench SDRAM model must call these; a divergence between
    // them is precisely the "wrong ROM load offset" failure that CLAUDE.md
    // warns produces fake bugs.
    //
    // Widths are spelled out because a silent truncation here is the whole
    // bug. All four concatenations are 27 bits, matching SDR_AW+1:
    //   {3'd0, code[16:0], 7'd0} = 27, {20'd0, row, 4'd0}     = 27,
    //   {23'd0, quarter, 2'd0}   = 27, {25'd0, byte_in_row}   = 27.
    // -----------------------------------------------------------------------
    function automatic logic [SDR_AW:0] gfx_record_addr(
        input logic [16:0] code, input logic [2:0] row
    );
        gfx_record_addr = SDR_GFX_BASE + {3'd0, code, 7'd0}
                                       + {20'd0, row, 4'd0};
    endfunction

    function automatic logic [SDR_AW:0] gfx_plane_addr(
        input logic [16:0] code, input logic [2:0] row,
        input logic  [1:0] quarter, input logic [1:0] byte_in_row
    );
        gfx_plane_addr = gfx_record_addr(code, row)
                       + {23'd0, quarter, 2'd0}
                       + {25'd0, byte_in_row};
    endfunction

    // -----------------------------------------------------------------------
    // ST010 addressing. As with gfx_record_addr above, these are THE authority:
    // the ROM loader, the program-fetch cache and tb_ssv_rom_loader all call
    // them, so a divergence is impossible rather than merely unlikely.
    // -----------------------------------------------------------------------

    // Where an st010.bin stream byte lands in SDRAM. Identity offset inside the
    // region, so the image is contiguous and the "dspprg"/"dspdata" split is a
    // property of the READERS, not of the placement.
    function automatic logic [SDR_AW:0] st010_stream_dest(
        input logic [26:0] stream_addr
    );
        st010_stream_dest = SDR_ST010_BASE +
                            (stream_addr[SDR_AW:0] - STREAM_ST010[SDR_AW:0]);
    endfunction

    // Byte address of instruction `pc`. MAME's dspprg is a 32-bit big-endian
    // region and the fetch is read_dword(pc) >> 8, so the instruction occupies
    // bytes 4*pc + 0..2 and byte 4*pc + 3 is never used.
    function automatic logic [SDR_AW:0] st010_prg_byte_addr(
        input logic [13:0] pc
    );
        st010_prg_byte_addr = SDR_ST010_BASE + {11'd0, pc, 2'd0};
    endfunction

    // 2048-word on-chip data ROM index for an st010.bin stream byte in the
    // "dspdata" half. Two BYTES per word, big-endian.
    function automatic logic [10:0] st010_drom_word(
        input logic [26:0] stream_addr
    );
        st010_drom_word =
            (stream_addr[26:0] - (STREAM_ST010 + ST010_DATA_OFFSET)) >> 1;
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
    // Pairwise overlap test. The rules used to assume the regions were in
    // ascending address order, which stopped being true once they were placed
    // in separate SDRAM banks: with bank = byte address [27:26], a
    // bank-separated map is deliberately NOT ascending-contiguous.
    function automatic bit overlaps(
        input logic [SDR_AW:0] a_base, input logic [SDR_AW:0] a_size,
        input logic [SDR_AW:0] b_base, input logic [SDR_AW:0] b_size
    );
        overlaps = (a_base < b_base + b_size) && (b_base < a_base + a_size);
    endfunction

    function automatic int layout_fault();
        // --- SDRAM regions: pairwise non-overlapping, inside the module ---
        if (overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_GFX_BASE,     SDR_GFX_SIZE))               return 1;
        if (overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_XRAM_BASE,    SDR_XRAM_SIZE) ||
            overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 2;
        if (overlaps(SDR_GFX_BASE, SDR_GFX_SIZE,
                     SDR_XRAM_BASE,    SDR_XRAM_SIZE) ||
            overlaps(SDR_GFX_BASE, SDR_GFX_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_GFX_BASE, SDR_GFX_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 3;
        if (overlaps(SDR_XRAM_BASE, SDR_XRAM_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_XRAM_BASE, SDR_XRAM_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE) ||
            overlaps(SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 4;
        if ({1'b0, SDR_SAMPLES_BASE} + {1'b0, SDR_SAMPLES_SIZE}
                                                > SDR_TOTAL_BYTES ||
            {1'b0, SDR_GFX_BASE} + {1'b0, SDR_GFX_SIZE}
                                                > SDR_TOTAL_BYTES)  return 5;

        // --- MRA stream: contiguous, and independent of the SDRAM map ---
        // The repack breaks the old "stream offset == SDRAM base" identity,
        // so these rules check the stream against itself instead.
        if (STREAM_MAINCPU != 27'h0000000)                          return 6;
        if (STREAM_SPRITES != STREAM_MAINCPU + STREAM_MAINCPU_SIZE)
                                                                    return 7;
        if (STREAM_SAMPLES != STREAM_SPRITES + STREAM_GFX_SIZE)     return 8;
        if (STREAM_ST010   != STREAM_SAMPLES + STREAM_SAMPLES_SIZE)
                                                                    return 9;

        // --- The repack itself ---
        // Every 12 raw bytes becomes a 16-byte record, so the packed
        // footprint is GFX_QUARTERS_PACKED/GFX_QUARTERS_LOADED of the
        // stream's. That was asserted as an EQUALITY against the region size,
        // which silently required the region to be sized for one specific
        // game. It is now a bound: the packed data must FIT the slot, so the
        // same 32 MB slot serves every title from Ultra X Weapons' 12 MB to
        // Vasara's 32 MB.
        if ((STREAM_GFX_SIZE / GFX_QUARTERS_LOADED) * GFX_QUARTERS_PACKED
                                            > SDR_GFX_SIZE)         return 10;
        // p2 bursts are 16-byte aligned (sdram.sv p2_addr is [AW:4]), and the
        // record address is BASE + code<<7 + row<<4, so BASE must be too.
        if (SDR_GFX_BASE[3:0] != 4'd0)                              return 11;

        // --- ST010 ---
        // Appended to the checks above rather than folded into rules 1-4, so
        // the existing rule numbers keep meaning what the git history says.
        if (overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_MAINCPU_BASE, SDR_MAINCPU_SIZE) ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_GFX_BASE,     SDR_GFX_SIZE)     ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_XRAM_BASE,    SDR_XRAM_SIZE)    ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_CPU_RAM_BASE, SDR_CPU_RAM_SIZE) ||
            overlaps(SDR_ST010_BASE, SDR_ST010_SIZE,
                     SDR_SAMPLES_BASE, SDR_SAMPLES_SIZE))           return 12;
        if ({1'b0, SDR_ST010_BASE} + {1'b0, SDR_ST010_SIZE}
                                                > SDR_TOTAL_BYTES)  return 13;
        // p5 bursts are 8-byte aligned (sdram.sv p5_addr is [AW:3]).
        if (SDR_ST010_BASE[2:0] != 3'd0)                            return 14;
        // The whole image must fit the region, and "dspdata" must start where
        // MAME's ROM_COPY says it does.
        if (SDR_ST010_SIZE != STREAM_ST010_SIZE)                    return 15;
        if (ST010_DATA_OFFSET + 27'h1000 != STREAM_ST010_SIZE)      return 16;
        if (STREAM_END != STREAM_ST010 + STREAM_ST010_SIZE)         return 17;
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
