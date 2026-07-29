# Graphics repack: one 128-bit SDRAM read per tile row

**Status:** design proposal, nothing implemented. Read-only analysis of the tree
at `main` (working tree also carries another agent's in-flight row-scroll and
`+REAL_SDRAM` work — see "Interaction with work in flight").

**Scope:** change *where the graphics bytes sit in SDRAM*, not what they are.
Every rendered pixel must be identical before and after. That is the whole
verification story (§5).

---

## 0. The problem, restated against the RTL

### 0.1 Why a tile row costs two transactions today

`rtl/video/ssv_gfx_row_fetch.sv:40-60` computes two different addresses for one
16-pixel row, in two different SDRAM regions:

```systemverilog
// ssv_gfx_row_fetch.sv:47-57
if (!which_quarter[0])
    // Q0 and Q1 are packed into the low/high halves of one beat.
    byte_address = SPRITE_BASE  + ({8'd0, wrap_code(code)} << 6) + ({22'd0, row} << 3);
else
    // Q2 remains in its original 4 MiB range; row parity selects
    // the required 32-bit half of the aligned 64-bit beat.
    byte_address = PLANE45_BASE + ({8'd0, wrap_code(code)} << 5) + ({22'd0, row} << 2);
```

with `SPRITE_BASE = 25'h0100000` and `PLANE45_BASE = 25'h0900000`
(`ssv_gfx_row_fetch.sv:26-27`). The two are 8 MB apart, so they can never be one
burst. The state machine therefore runs `IDLE → WAIT_ACK → WAIT_ACK_LOW →
WAIT_ACK → IDLE` (`ssv_gfx_row_fetch.sv:82-132`), issuing two `p1` transactions
and, of the second one's 64 bits, using only the 32 selected by row parity
(`ssv_gfx_row_fetch.sv:62-63`). `plane67` is hard zero
(`ssv_gfx_row_fetch.sv:107`) because Dyna Gear populates six of sixteen graphics
sockets (`ssv_pkg.sv:10-16`).

### 0.2 What a transaction costs, derived from the controller

`rtl/mem/sdram.sv` serialises everything through one chip with auto-precharge.
Per read transaction the state machine occupies (all at `clk_ram`):

| state | cycles | reference |
|---|---|---|
| `ST_IDLE` (grant + address register) | 1 | `sdram.sv:347-379` |
| `ST_ACT` | 1 | `sdram.sv:382-387` |
| `ST_RCD1`, `ST_RCD2` (tRCD) | 2 | `sdram.sv:390-391` |
| `ST_RD` (one READ per word) | `rd_total` | `sdram.sv:409-419` |
| `ST_RDW` (CL2 + IOE + capture drain) | 5 | `sdram.sv:336-344`, `420-424` |

so **occupancy = 9 + `rd_total`**:

* `p1`, `rd_total = 4` (`sdram.sv:362`) → **13 cycles**
* `p2`, `rd_total = 8` (`sdram.sv:363`) → **17 cycles**

The 13 reproduces the measured figure in the brief exactly, which is the first
independent confirmation that the measurement and the RTL agree.

### 0.3 The budget

A scanline is 454 pixels at 7.159083 MHz (`ssv_pkg.sv:83-93`) = 63.415 µs =
**6128 `clk_ram` cycles** at 96.6 MHz.

| | transactions/line | cycles | % of scanline |
|---|---|---|---|
| today (2 × `p1` per tile row) | 296 | 3848 | **62.8 %** |
| proposed (1 × `p2` per tile row) | 148 | 2516 | **41.1 %** |

**1332 cycles/line returned to the CPU, audio and refresh — 21.7 % of the whole
scanline budget, a 61 % increase in non-graphics headroom** (2195 → 3527 cycles
after subtracting ~85 cycles/line of refresh: `sdram.sv:331-333` schedules a
refresh every 700 cycles, `sdram.sv:426-439` costs ~9 cycles each).

Two honest caveats on that table:

1. 148 tile-row fetches is a **busy line**, not the average. The saving on a
   sparse line is proportionally the same (−34.6 % of graphics cycles) but
   smaller in absolute terms. The busy line is the one that misses its
   deadline, so it is the right line to size against.
2. The reduction is 34.6 % of graphics cycles, not 50 %, because a 128-bit burst
   costs 17 cycles rather than 2 × 13 = 26. Halving *transactions* is not
   halving *cycles*; the 9-cycle fixed overhead is what is actually being
   amortised.

### 0.4 Secondary saving: the fetcher's own round trip disappears

`WAIT_ACK_LOW` (`ssv_gfx_row_fetch.sv:122-131`) waits for the stretched ack to
fall before re-asserting `rom_req`, because `sdram.sv:16-21` requires a fresh
rising edge per transaction. Acks are stretched to 2 `clk_ram`
(`sdram.sv:342`) = 1 `clk_sys`. Removing the second beat deletes that whole
handshake: roughly 2 `clk_sys` (4 `clk_ram`) of per-row latency on top of the
13 cycles of queueing, and it halves the duty cycle of `rom_req` presented to
the shared mux in `ssv_core` (relevant to §6, R8).

---

## 1. New SDRAM map

### 1.1 Record format

One **16-byte, 16-byte-aligned record per 16-pixel tile row**:

| byte offset | contents | consumer |
|---|---|---|
| `0..3` | MAME graphics quarter 0 row | `plane01` |
| `4..7` | quarter 1 row | `plane23` |
| `8..11` | quarter 2 row | `plane45` |
| `12..15` | quarter 3 row — **never written** on Dyna Gear | `plane67`, forced to 0 |

### 1.2 Address formula

```
gfx_record_addr(code, row) = SDR_GFX_BASE + (code[16:0] << 7) + (row[2:0] << 4)

gfx_plane_addr(code, row, quarter, byte)
                           = gfx_record_addr(code, row) + (quarter << 2) + byte
```

`code` is 17 bits — the same wrap as today (`ssv_gfx_row_fetch.sv:35-38`: "MAME's
16 MiB region contains 0x20000 16x8 tiles"). Confirmed by arithmetic: each
quarter of `sprites.bin` is 4 MB (`tb_ssv_frame_crc.sv:306` puts Q1 at raw byte
4 194 304, `:313` bounds Q2 at 12 582 911), and 4 MB / 32 bytes-per-tile =
131 072 = `0x20000` tiles.

Max address = `SDR_GFX_BASE + (0x1FFFF << 7) + (7 << 4) + 15` =
`SDR_GFX_BASE + 0xFFFFFF`.

### 1.3 Footprint

```
16 bytes/row × 8 rows/tile × 131,072 tiles = 16,777,216 bytes = 16 MB
```

**+4 MB over today's 12 MB.** The 4 MB is the unwritten quarter-3 slot.

### 1.4 Proposed map — minimum-churn ordering

The obvious map (graphics grows in place, everything after it slides up) moves
`SDR_XRAM_BASE` off `0x1100000`, and **five testbenches hardcode `0x1100000` /
`0x1160000`** (`tb_ssv_frame_crc.sv:285-286,339-341`,
`tb_ssv_realrom_video.sv:111-113,177-179`, `tb_ssv_realrom_boot.sv:116-118,
134-136`, `tb_ssv_hang_watch.sv:90-91,105-110`). Sliding XRAM would touch all of
them.

Instead, **move only the sample region** and let graphics grow exactly into the
gap that samples vacate:

| region | base | size | end | change |
|---|---|---|---|---|
| V60 program | `0x0000000` | 1 MB (`0x0100000`) | `0x00FFFFF` | none |
| **graphics records** | `0x0100000` | **16 MB (`0x1000000`)** | `0x10FFFFF` | **grew 12→16 MB** |
| XRAM (`$160000`) | `0x1100000` | 128 KB | `0x111FFFF` | **none** |
| CPU RAM (`$400000`) | `0x1120000` | 256 KB | `0x115FFFF` | **none** |
| **ES5506 samples** | **`0x1160000`** | 4 MB | `0x155FFFF` | **moved from `0x0D00000`** |

High-water mark `0x1560000` = 22 413 312 B = **21.375 MB of the 32 MB module**
(`SDR_TOTAL_BYTES = 26'h2000000`, `ssv_pkg.sv:46`). **10.6 MB spare.** It fits.

Exactly **one** constant changes value: `SDR_SAMPLES_BASE`. Its only RTL
consumer is `ssv_es5506_voice.sv:282,295`, which already reads it symbolically
(`SDR_SAMPLES_BASE[24:1] + …`) and therefore follows for free. Two testbenches
hardcode `0x0d00000` and must be updated: `tb_ssv_realrom_boot.sv:156-160` and
`tb_ssv_rom_loader.sv:76-79`.

The graphics region ends at `0x10FFFFF` and XRAM begins at `0x1100000` — exactly
adjacent, zero slack. That is deliberate (it is what keeps XRAM in place) but it
means **any future graphics growth forces the full re-layout**. Say so in the
package comment.

### 1.5 Stream (MRA) offsets — unchanged

| stream | offset | size |
|---|---|---|
| `STREAM_MAINCPU` | `0x0000000` | 1 MB |
| `STREAM_SPRITES` | `0x0100000` | 12 MB raw (3 × 4 MB quarters) |
| `STREAM_SAMPLES` | `0x0D00000` | 4 MB |
| `STREAM_END` | `0x1100000` | — |

Verified against `mra/Dyna Gear.mra`: two interleaved program halves, then six
2 MB graphics parts (`si002-01.u27`, `-04.u26`, `-02.u23`, `-05.u22`,
`-03.u17`, `-06.u16` — 12 MB), then four 1 MB sample parts. **The MRA does not
change** (§6, R6).

### 1.6 `ssv_pkg.sv` edits

Replace `SDR_SPRITES_BASE`/`SDR_SPRITES_SIZE` with graphics-record names — the
old name is now actively misleading, since the region is no longer a copy of
MAME's sprite ROM:

```systemverilog
    localparam logic [24:0] SDR_MAINCPU_BASE = 25'h0000000; //  1 MB  program
    localparam logic [24:0] SDR_GFX_BASE     = 25'h0100000; // 16 MB  packed rows
    localparam logic [24:0] SDR_XRAM_BASE    = 25'h1100000; // $160000 window
    localparam logic [24:0] SDR_CPU_RAM_BASE = 25'h1120000; // $400000 window
    localparam logic [24:0] SDR_SAMPLES_BASE = 25'h1160000; // 4 MB  ES5506

    localparam logic [24:0] SDR_MAINCPU_SIZE = 25'h0100000;
    localparam logic [24:0] SDR_GFX_SIZE     = 25'h1000000; // 16 MB
    localparam logic [24:0] SDR_XRAM_SIZE    = 25'h0020000;
    localparam logic [24:0] SDR_CPU_RAM_SIZE = 25'h0040000;
    localparam logic [24:0] SDR_SAMPLES_SIZE = 25'h0400000;

    // Raw graphics bytes in the MRA stream: 3 populated quarters x 4 MB.
    localparam logic [26:0] STREAM_GFX_SIZE  = 27'h0C00000;

    // Quarters the loader writes vs. slots the record reserves.  The 4/3
    // expansion in SDR_GFX_SIZE is exactly this ratio, and it is zero for a
    // title that populates all four quarters.
    localparam int GFX_QUARTERS_LOADED = 3;
    localparam int GFX_QUARTERS_PACKED = 4;
```

**One definition of the packing, shared by everything** — this is the single
most valuable risk control in the plan (§6, R1/R2):

```systemverilog
    // THE authority on where a tile row lives.  The ROM loader, the row
    // fetcher and every testbench SDRAM model must call these; a divergence
    // between them is precisely the "wrong ROM load offset" failure that
    // CLAUDE.md warns produces fake bugs.
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
```

(Width check, because this is the kind of file where a silent truncation is the
whole bug: `{1'b0, code[16:0], 7'd0}` = 25, `{18'd0, row, 4'd0}` = 25,
`{21'd0, quarter, 2'd0}` = 25, `{23'd0, byte_in_row}` = 25.)

### 1.7 `layout_fault()` update

The current rules 7-9 (`ssv_pkg.sv:68-70`) assert that stream offsets *equal*
SDRAM bases. That identity is what the repack destroys, so those rules must be
replaced rather than patched — otherwise the self-check fires at time 0
(`ssv_core.sv:61-64`) on a correct layout, and the temptation is to delete the
check instead of fixing it.

```systemverilog
    function automatic int layout_fault();
        // --- SDRAM regions: ordered, non-overlapping, inside the module ---
        if (SDR_MAINCPU_BASE + SDR_MAINCPU_SIZE > SDR_GFX_BASE)     return 1;
        if (SDR_GFX_BASE     + SDR_GFX_SIZE     > SDR_XRAM_BASE)    return 2;
        if (SDR_XRAM_BASE    + SDR_XRAM_SIZE    > SDR_CPU_RAM_BASE) return 3;
        if (SDR_CPU_RAM_BASE + SDR_CPU_RAM_SIZE > SDR_SAMPLES_BASE) return 4;
        if ({1'b0, SDR_SAMPLES_BASE} + {1'b0, SDR_SAMPLES_SIZE}
                                                > SDR_TOTAL_BYTES)  return 5;

        // --- MRA stream: contiguous, and independent of the SDRAM map ---
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
        // p2 bursts are 16-byte aligned (sdram.sv:59, :363), and the record
        // address is BASE + code<<7 + row<<4, so BASE must be too.
        if (SDR_GFX_BASE[3:0] != 4'd0)                              return 11;
        return 0;
    endfunction
```

Note rule 4/5 reorder to follow the new region order. `SDR_LAYOUT_FAULT`
(`ssv_pkg.sv:74`) and the `$fatal` at `ssv_core.sv:62-63` are unchanged.

---

## 2. `rtl/mem/ssv_rom_loader.sv`

### 2.1 What exists

The loader is a byte-pair packer: it holds even bytes in `byte_lo` and issues a
16-bit SDRAM write on the odd byte (`ssv_rom_loader.sv:98-106`), at
`sdr_wr_addr <= mapped_ioctl_addr[24:1]` (`:102`). The remap is entirely inside
one pure function:

```systemverilog
// ssv_rom_loader.sv:42-64
sprite_offset  = stream_addr - STREAM_SPRITES;
within_quarter = sprite_offset[21:0];
if ((stream_addr >= STREAM_SPRITES) &&
    (stream_addr < STREAM_SPRITES + 27'h0800000)) begin
    stream_byte_address = SDR_SPRITES_BASE +
        {2'd0,  within_quarter[21:5], 6'd0} +   // code    << 6
        {19'd0, within_quarter[4:2],  3'd0} +   // row     << 3
        {22'd0, sprite_offset[22],    2'd0} +   // quarter << 2  (Q0/Q1 only)
        {23'd0, within_quarter[1:0]};           // byte in row
end
else begin
    stream_byte_address = stream_addr[24:0];    // identity
end
```

So the field extraction is already exactly right — `within_quarter[21:5]` is the
tile code, `[4:2]` the row, `[1:0]` the byte within the 32-bit row. Verified
against `tb_ssv_rom_loader.sv:47-52`: stream `0x010004C` → `sprite_offset =
0x4C` → code 2, row 3, byte 0 → `0x100000 + (2<<6) + (3<<3) = 0x100098`, which
is what the test asserts.

Two things are wrong for our purposes: the `< STREAM_SPRITES + 0x800000` guard
excludes Q2 from the packer (`:44-45`), and the quarter selector is a single bit
`sprite_offset[22]` (`:63`) rather than the two bits the third quarter needs.

### 2.2 The change

```systemverilog
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
            // All THREE populated quarters now collapse into one aligned
            // 16-byte record per 16-pixel tile row, so the row fetcher gets a
            // whole row from a single 128-bit p2 burst.  Byte 12..15 of every
            // record is the absent quarter 3 and is deliberately never
            // written -- ssv_gfx_row_fetch forces plane67 to zero.  If a
            // family title ever populates Q3, this loop already places it and
            // only the fetcher's constant has to go.
            //
            // UNCHANGED from the previous layout, and still unproven: which
            // physical SAM-5127 graphics bank feeds which quarter.  See the
            // note this replaces and docs/hardware/SSV_BOARD_HARDWARE.md.
            stream_byte_address = gfx_plane_addr(
                within_quarter[21:5],   // tile code
                within_quarter[4:2],    // row within tile
                quarter,
                within_quarter[1:0]     // byte within the 32-bit row
            );
        end
        else if (stream_addr >= STREAM_SAMPLES) begin
            // The sample region no longer sits at its stream offset: the
            // graphics records displaced it above XRAM/CPU RAM.
            stream_byte_address = SDR_SAMPLES_BASE +
                                  (stream_addr[24:0] - STREAM_SAMPLES[24:0]);
        end
        else begin
            stream_byte_address = stream_addr[24:0];  // V60 program, identity
        end
    end
endfunction
```

Also update the file header comment (`ssv_rom_loader.sv:2-7`), which currently
documents the old two-region layout.

### 2.3 Worked examples (these become the unit test)

| MRA stream byte | quarter | code | row | byte | old SDRAM | **new SDRAM** |
|---|---|---|---|---|---|---|
| `0x010004C` | Q0 | 2 | 3 | 0 | `0x100098` | **`0x100130`** |
| `0x050004C` | Q1 | 2 | 3 | 0 | `0x10009C` | **`0x100134`** |
| `0x090004C` | Q2 | 2 | 3 | 0 | `0x09004C` | **`0x100138`** |
| `0x0D00000` | — | — | — | — | `0xD00000` | **`0x1160000`** |

The first three landing in one 16-byte record (`0x100130..0x10013F`) is the
entire point, and it is directly assertable.

### 2.4 What does *not* change

* Byte-pair packing, `ioctl_wait`, `rom_loaded`, `download_max_addr`
  (`ssv_rom_loader.sv:74-121`) — untouched.
* The `ioctl_addr < STREAM_END` gate (`:95`) — `STREAM_END` is unchanged.
* Write count: 8.5 M 16-bit writes, identical. The record pad is not written,
  so **download time is unchanged**. (Zero-filling the pad would need a
  separate post-download fill pass — 2 M extra writes and a new state machine.
  Not worth it; see §6 R3.)

---

## 3. `rtl/video/ssv_gfx_row_fetch.sv`

### 3.1 Bit mapping of the returned 128-bit word

`sdram.sv:280-281` assembles `p2_dout` little-endian — `cap_buf[0]` is the first
(lowest-address) 16-bit word and lands in bits `[15:0]`:

```systemverilog
3'd2: begin p2_dout <= {final_word, cap_buf[6], cap_buf[5], cap_buf[4],
                        cap_buf[3], cap_buf[2], cap_buf[1], cap_buf[0]}; ... end
```

So for a record at byte address `R`:

| record bytes | `p2_dout` bits | plane |
|---|---|---|
| `R+0 .. R+3` | `[31:0]` | `plane01` |
| `R+4 .. R+7` | `[63:32]` | `plane23` |
| `R+8 .. R+11` | `[95:64]` | `plane45` |
| `R+12 .. R+15` | `[127:96]` | **discarded**; `plane67 <= 32'd0` |

`[31:0]`/`[63:32]` are the same assignments the module already makes for the
Q0/Q1 beat (`ssv_gfx_row_fetch.sv:102-103`), so the low half is provably
unchanged.

### 3.2 The module after the change

```systemverilog
module ssv_gfx_row_fetch (
    input  logic         clk, rst, start,
    input  logic  [19:0] tile_code,
    input  logic   [2:0] tile_row,

    output logic         rom_req,
    output logic  [24:4] rom_addr,    // was [24:3]
    input  logic [127:0] rom_data,    // was [63:0]
    input  logic         rom_ack,

    output logic         busy, done,
    output logic  [31:0] plane01, plane23, plane45, plane67
);

import ssv_pkg::*;

typedef enum logic {IDLE, WAIT_ACK} state_t;
state_t state;

always_ff @(posedge clk) begin
    if (rst) begin
        state   <= IDLE;   rom_req <= 1'b0;  rom_addr <= '0;
        busy    <= 1'b0;   done    <= 1'b0;
        plane01 <= '0; plane23 <= '0; plane45 <= '0; plane67 <= '0;
    end
    else begin
        done <= 1'b0;
        unique case (state)
            IDLE: begin
                rom_req <= 1'b0;
                busy    <= 1'b0;
                if (start) begin
                    // wrap_code(): MAME's 16 MiB region holds 0x20000 tiles.
                    rom_addr <= gfx_record_addr(tile_code[16:0], tile_row)[24:4];
                    rom_req  <= 1'b1;
                    busy     <= 1'b1;
                    state    <= WAIT_ACK;
                end
            end
            WAIT_ACK: if (rom_ack) begin
                rom_req <= 1'b0;
                plane01 <= rom_data[31:0];
                plane23 <= rom_data[63:32];
                plane45 <= rom_data[95:64];
                // Bytes 12..15 are the record's quarter-3 slot.  The loader
                // never writes them, so they are whatever the chip powered up
                // holding -- X in a chip-model simulation.  This constant is
                // therefore load-bearing, not cosmetic: do NOT "improve" it to
                // rom_data[127:96] unless GFX_QUARTERS_LOADED becomes 4.
                plane67 <= 32'd0;
                busy    <= 1'b0;
                done    <= 1'b1;
                state   <= IDLE;
            end
        endcase
    end
end
endmodule
```

Deleted: the `quarter`, `code_latched`, `row_latched` registers, the
`selected_row` row-parity mux (`:62-63`), the `WAIT_ACK_LOW` state, the local
`SPRITE_BASE`/`PLANE45_BASE` params, and the two-branch `fetch_address`. Net
**−25 flops and −1 state**; this change costs negative FPGA area.

`start`→`done` remains purely event-driven — both callers block in a state
waiting on `fetch_done` (`ssv_bg_renderer.sv:273`,
`ssv_cached_sprite_renderer.sv:1229`), never on a cycle count. That is what
makes the byte-identical-CRC expectation in §5 sound.

`rtl/video/ssv_gfx_row_decode.sv` is **unchanged** — it consumes the four
32-bit planes and knows nothing about memory.

---

## 4. Wiring: `ssv_core.sv`, `Arcade-SSV.sv`, and the two renderers

### 4.1 `rtl/mem/sdram.sv` needs **zero** edits

`p2` is fully implemented — declared (`sdram.sv:59-63`), mailboxed
(`:146`, `:210-212`), in the round-robin (`:155-166`), given `rd_total = 8`
(`:363`) and delivered (`:280-281`). It is simply tied off at the top level
(`Arcade-SSV.sv:313`). This is the single strongest argument for the proposal:
the expensive half already exists and is dead code.

Alignment precondition, satisfied by construction: `a = {p2_addr_p, 3'b000}`
(`sdram.sv:363`) is 16-byte aligned, so the 8 column increments at
`sdram.sv:416` (`xfer_addr[10:1] + 1`) never carry out of bit 4 and the burst
cannot cross a row boundary.

### 4.2 The bg/obj arbiter in `ssv_core.sv` — structure preserved exactly

Both renderers already share one port through a mux, with the ack steered so a
renderer cannot latch a transaction it does not own (`ssv_core.sv:273-299`):

```systemverilog
// ssv_core.sv:286-291
wire p1_owner_obj = obj_busy;
wire bg_rom_ack   = sdr_p1_ack && !p1_owner_obj;
wire obj_rom_ack  = sdr_p1_ack &&  p1_owner_obj;
assign sdr_p1_req  = obj_busy ? obj_rom_req  : bg_rom_req;
assign sdr_p1_addr = obj_busy ? obj_rom_addr : bg_rom_addr;
```

The change is **renaming the port and widening two buses — nothing else**. The
ownership logic, the `obj_busy` selector and the ack steering (and the reasoning
in the comment at `:276-285`, which is about a real hardware-only hazard) stay
byte-for-byte:

```systemverilog
wire p2_owner_obj = obj_busy;
wire bg_rom_ack   = sdr_p2_ack && !p2_owner_obj;
wire obj_rom_ack  = sdr_p2_ack &&  p2_owner_obj;
assign sdr_p2_req  = obj_busy ? obj_rom_req  : bg_rom_req;
assign sdr_p2_addr = obj_busy ? obj_rom_addr : bg_rom_addr;
```

with the declarations at `ssv_core.sv:267-268` becoming
`wire [24:4] bg_rom_addr, obj_rom_addr;`.

Do **not** be tempted to "improve" the mux while here. Two independent changes
in one commit is exactly what makes a CRC mismatch uninterpretable.

### 4.3 Complete edit list

| file | edit |
|---|---|
| `ssv_core.sv:15-18` | port `sdr_p1_req/addr[24:3]/dout[63:0]/ack` → `sdr_p2_req/addr[24:4]/dout[127:0]/ack` |
| `ssv_core.sv:267-268` | `bg_rom_addr`, `obj_rom_addr` → `[24:4]` |
| `ssv_core.sv:286-291` | rename `p1`→`p2` (above) |
| `ssv_core.sv:318` | `.rom_data(sdr_p1_dout)` → `.rom_data(sdr_p2_dout)` (bg) |
| `ssv_core.sv:339` | same for the sprite renderer |
| `ssv_bg_renderer.sv:24-26` | `rom_addr` → `[24:4]`, `rom_data` → `[127:0]` |
| `ssv_cached_sprite_renderer.sv:32-34` | same |
| `Arcade-SSV.sv:279-281` | `p1_addr` → `p2_addr [24:4]`, `p1_dout` → `p2_dout [127:0]`; rename wires |
| `Arcade-SSV.sv:312-313` | swap: `p1` tied off, `p2` wired to the core |
| `Arcade-SSV.sv:392-393` | `.sdr_p2_req(p2_req) .sdr_p2_addr(p2_addr) .sdr_p2_dout(p2_dout) .sdr_p2_ack(p2_ack)` |
| `files.qip` | no change (no new files) |

**`p1` becomes unused.** Leave it tied off in `sdram.sv`'s instantiation rather
than deleting the port — the controller is shared with the s32 lineage
(`sdram.sv:1-21`) and `p1` is the natural home for the audio line-cache that
`docs/DYNAGEAR_COMPLETION_PLAN.md:200-204` earmarks (see §6 R7).

No arbitration fairness change: `sdram.sv:155-166` round-robins over *pending*
ports only, so moving the graphics client from slot 1 to slot 2 is invisible to
every other client.

### 4.4 Testbench SDRAM models

Five models decode the graphics region and all must move together. The new
decode is *simpler* than the two-branch one it replaces:

```systemverilog
// p2 model, replacing the p1 model in tb_ssv_frame_crc.sv:298-325
p2_byte_addr = {sdr_p2_addr, 4'b0000};
gfx_rec      = p2_byte_addr - 25'h0100000;   // SDR_GFX_BASE
rec_code     = gfx_rec >> 7;                 // 0..0x1ffff
rec_row      = (gfx_rec >> 4) & 7;
raw_q0       = rec_code * 32 + rec_row * 4;  // MAME quarter 0
raw_q1       = 4194304 + raw_q0;
raw_q2       = 8388608 + raw_q0;
beh_p2_dout <= {
    32'h0,                                   // Q3 slot: never loaded
    sprite_rom[raw_q2+3], sprite_rom[raw_q2+2],
    sprite_rom[raw_q2+1], sprite_rom[raw_q2],
    sprite_rom[raw_q1+3], sprite_rom[raw_q1+2],
    sprite_rom[raw_q1+1], sprite_rom[raw_q1],
    sprite_rom[raw_q0+3], sprite_rom[raw_q0+2],
    sprite_rom[raw_q0+1], sprite_rom[raw_q0]
};
```

| file | what to change |
|---|---|
| `verif/tb_ssv_frame_crc.sv:298-325` | p1 model → p2 model above; `beh_p1_dout` → `[127:0]` |
| `verif/tb_ssv_realrom_video.sv:127-167` | same |
| `verif/tb_ssv_realrom_boot.sv:150-160` | sample base `0x0d00000` → `SDR_SAMPLES_BASE` |
| `verif/tb_ssv_hang_watch.sv` | p1 → p2 port widths |
| `verif/ssv_sdram_harness.sv:86-91` | expose `p2` (currently tied off at `:90`), tie off `p1` |
| `verif/tb_ssv_rom_loader.sv:45-82` | new expected addresses (§2.3) |
| `verif/tb_ssv_gfx_row_fetch.sv:68-87` | one transaction, new address, `plane45` from `[95:64]` |

Find them all with: `grep -rn '4194304\|8388608\|12582912\|0d00000' verif/`.

---

## 5. Verification plan

### 5.1 The central gate: frame CRCs byte-identical

Only the memory *layout* changes. Not one pixel, not one CPU cycle, not one
rendering decision. Under the default behavioural SDRAM model every port is
served in a fixed 2 cycles regardless of burst width
(`tb_ssv_frame_crc.sv:317-330`), so removing a transaction can only make a
renderer finish a line *earlier*, never later — and both renderers block on
`fetch_done` rather than counting cycles (§3.2). **Therefore the frame CRC
stream must be byte-identical. Any difference at all means the repack is wrong;
do not go looking downstream for an explanation.**

**Baseline — capture this BEFORE touching anything:**

```bash
cd /d/Arcade/AI/SVV          # WSL path to the repo
ulimit -s unlimited
bash verif/build_frame_crc.sh /tmp/ssv-crc-before

/tmp/ssv-crc-before/tb_ssv_frame_crc \
  +MAINROM=$PWD/sim_output/rom/maincpu.bin \
  +SPRROM=$PWD/sim_output/rom/sprites.bin \
  +verilator+seed+1 +verilator+rand+reset+2 \
  +SCENARIO=coin_start_p1_gameplay \
  +FRAMES=950 +SOAK_FRAMES=30 +CYCLES=900000000 \
  +REQUIRE_GAMEPLAY \
  +FRAME_CRC=/tmp/ssv-crc-before/gameplay950.crc \
  2>&1 | tee /tmp/ssv-crc-before/run.log
```

**After the change** — same command with `before` → `after`, then:

```bash
cmp /tmp/ssv-crc-before/gameplay950.crc \
    /tmp/ssv-crc-after/gameplay950.crc && echo "CRC IDENTICAL"
wc -l /tmp/ssv-crc-after/gameplay950.crc     # must be 950
grep -c '^PASS' /tmp/ssv-crc-after/run.log   # must be 1
```

Pass condition: `cmp` silent, 950 lines, `PASS tb_ssv_frame_crc … overruns
bg=0 obj=0`.

Notes on the command: `+FRAMES/+SOAK_FRAMES/+CYCLES` match the established
gameplay capture in `tools/ab-run-captures.sh:20-31`; the determinism flags are
the CLAUDE.md requirement; `+REQUIRE_GAMEPLAY` makes the run assert it actually
reached jungle gameplay (`tb_ssv_frame_crc.sv:968-970`) rather than
CRC-matching two identically broken runs. Write CRCs under `/tmp` first —
`verif/run_gameplay_sims.sh:56` records that WSL `fwrite` onto `/mnt/d` can
truncate to zero.

Also run `+SCENARIO=attract_idle +FRAMES=30 +SOAK_FRAMES=15` and
`+SCENARIO=coin_start_p1 +FRAMES=40 +SOAK_FRAMES=35` (the pair
`verif/run_gameplay_sims.sh:58-71` gates on) with the same `cmp`.

### 5.2 Unit gates — each must be OBSERVED to fail first

| test | assertion | must fail before the fix because |
|---|---|---|
| `tb_ssv_rom_loader` | stream `0x010004C`→`0x100130`, `0x050004C`→`0x100134`, `0x090004C`→`0x100138`, `0x0D00000`→`0x1160000` | old loader produces `0x100098`/`0x10009C`/`0x09004C`/`0xD00000` |
| `tb_ssv_rom_loader` (new case) | the three graphics writes land in **one** 16-byte record: `addr[24:4]` equal for all three | the whole point of the change; nothing else asserts it |
| `tb_ssv_gfx_row_fetch` | `transaction == 1`, `rom_addr == 21'h10013`, `plane45 == rom_data[95:64]`, `plane67 == 0` | old fetcher issues 2 transactions (`tb_ssv_gfx_row_fetch.sv:84`) |
| `ssv_pkg` self-check | temporarily set `SDR_GFX_SIZE` to `0x0C00000`; `ssv_core.sv:62-63` must `$fatal` with rule 10 | proves the new rules are live, not vacuous. Revert immediately. |

### 5.3 The benefit — which the CRC gate does **not** measure

A byte-identical CRC proves nothing broke. It says nothing about bandwidth,
because the behavioural model has no bandwidth. The benefit is only observable
through `verif/ssv_sdram_harness.sv` + `verif/ssv_sdram_chip.sv` (the real
controller and a chip model at the true `clk_ram = 2 × clk_sys` ratio), selected
by `+REAL_SDRAM`.

Record, before and after, on the same scenario:

* `obj_overruns` / `bg_overruns` (`tb_ssv_frame_crc.sv` final `$fatal` check) —
  expect a fall, ideally to zero.
* `OBJ_MAX … cycles=` under `+DUMP_RENDERER_BUDGET` — worst-line cycle count.
* `rom_wait=` in the same line — cycles blocked in the fetch-wait state.
* A new per-line transaction counter: **assert it halves, 296 → 148.** This is
  the direct measurement of the claim and it is cheap to add.
* No `SDRAM CONTRACT WARNING` from `sdram.sv:250-255` (see §6 R8).

Under `+REAL_SDRAM` the CRCs will legitimately **differ** before vs after if the
old build was missing line deadlines — that difference *is* the result. Do not
conflate the two runs: the byte-identical gate is the default model only.

### 5.4 Lint

```bash
verilator --lint-only -Wall --top-module emu \
  rtl/ssv_pkg.sv rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv \
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_cached_sprite_renderer.sv \
  rtl/mem/sdram.sv rtl/mem/ssv_rom_loader.sv rtl/ssv_core.sv Arcade-SSV.sv
```

**Run this without `-Wno-WIDTH*`.** See §6 R9 — the project's build scripts
suppress exactly the warnings that would catch this change's most likely
mistake. No Quartus at any point in this loop.

---

## 6. Risks — the critical read

### R1. The loader remap is the classic fake-bug generator — HIGH

`CLAUDE.md`: "Wrong load offsets are a common source of fake bugs." This change
rewrites the load offset for **all 12 MB of graphics**. A one-bit error in the
shift amounts produces graphics that are subtly wrong in a way that looks like a
renderer bug and will burn days.

*Mitigations, in order of value:* (1) the shared `gfx_plane_addr`/
`gfx_record_addr` functions in `ssv_pkg` so the loader, fetcher and testbench
models cannot disagree — if they share one function, a wrong formula produces
*consistently* wrong data and the frame CRC catches it immediately; (2) the
byte-identical CRC gate, which is a 12 MB × 950-frame consistency check;
(3) the explicit three-quarter unit test.

### R2. Five SDRAM models must move in lockstep — HIGH

Listed in §4.4. Miss one and that testbench reports "corrupt graphics" that
reads as an RTL regression. The `grep` in §4.4 is the checklist. Note this risk
is **entirely a testbench-hygiene risk** — it cannot reach hardware.

### R3. The unwritten quarter-3 pad — MEDIUM, and permanent

4 MB of the graphics region is never written by the loader. `plane67 <= 32'd0`
in the fetcher is therefore load-bearing: reading `rom_data[127:96]` instead
would produce X in a chip-model sim and garbage on hardware. This is a booby
trap for a future maintainer who sees a hard-coded zero next to three
data-driven assignments and "fixes" it.

*Mitigation:* the `GFX_QUARTERS_LOADED` package parameter plus the comment in
§3.2, and a testbench assertion that `plane67` is never non-zero. Zero-filling
the pad at download time was considered and rejected: it needs a new
post-download fill state machine and 2 M extra writes, to defend against a
mistake the comment already defends against.

### R4. Does the 16-byte record push us over budget? — NO, but it costs headroom

21.375 MB of 32 MB used (§1.4), 10.6 MB spare. The core already required a 32 MB
module (`SDR_XRAM_BASE = 0x1100000` = 17 MB), so **the minimum board does not
change**.

The nuance worth stating plainly: the 33 % expansion exists **only because
quarter 3 is empty**. A family title populating all four quarters pays **zero**
overhead (16 raw bytes → a 16-byte record). A two-quarter title would pay 100 %
— but a two-quarter title needs no repack at all, since Q0/Q1 already fit one
64-bit `p1` beat, which is exactly what the current design does. So the repack
is precisely a three-quarter-title optimisation, and Dyna Gear is one.

What it does cost: the largest raw graphics set that fits drops from ~30 MB to
~22.5 MB. Given a fully-populated SAM-5127 is 32 MB of graphics and already does
not fit a 32 MB module, that ceiling was never reachable anyway.

### R5. Moving the sample base — LOW

One constant. `ssv_es5506_voice.sv:282,295` follows symbolically. Two testbench
hardcodes (`tb_ssv_realrom_boot.sv:156-160`, `tb_ssv_rom_loader.sv:76`). No
audio golden is keyed to the absolute address (`tb_ssv_es5506_voice.sv:61` uses
`SDR_SAMPLES_BASE`). Run `verif/run_audio_sims.sh` anyway.

### R6. Does the loader change break the existing MRA? — NO

`mra/Dyna Gear.mra` defines a *stream*: part order and sizes. `STREAM_MAINCPU/
SPRITES/SAMPLES/END` are unchanged (§1.5), and the loader consumes the stream
identically (`ssv_rom_loader.sv:94-107`) — only `stream_byte_address` differs.
The MRA never encodes the SDRAM map, so old and new RBFs both work with the same
`.mra` and the same `dynagear.zip`. **No user-visible packaging change.**

### R7. `p2` was earmarked for audio — MEDIUM, needs a doc update

`docs/DYNAGEAR_COMPLETION_PLAN.md:200-204` reserves "the 128-bit burst port plus
a small line cache" as the ES5506 fallback if the 16-bit port underruns. Taking
`p2` for graphics forecloses that.

*Resolution:* `p1` (64-bit, 4-word burst, 13 cycles) becomes free and is the
better audio port anyway — a sample line cache wants 4-8 consecutive words, not
16, and a 13-cycle transaction has lower worst-case latency than a 17-cycle one.
But this must be written into that plan, not left implicit.

### R8. The bg/obj mux and the SDRAM request contract — MEDIUM, pre-existing

`sdram.sv:16-21` requires one transaction **per rising edge** of `req`; a level
held across an ownership switch is serviced once and the loser hangs forever.
`ssv_core.sv:290` muxes two requesters' `req` lines onto one wire. Today this is
saved only by `obj_rom_req` happening to be low whenever `obj_busy` falls.

The repack does not change the mux, but it *does* halve the duty cycle of
`rom_req` (one pulse per row instead of two), which changes the phase
relationship. **Re-verify, do not assume.** The check is free: `sdram.sv:242-259`
already has a contract watchdog that prints `SDRAM CONTRACT WARNING: port N req
held …` — run the `+REAL_SDRAM` configuration and confirm it stays silent.

Related and also pre-existing: `ssv_core.sv:276-285` documents that a line which
misses its deadline starts the bg renderer while the obj renderer is still
fetching, and that the ack steering is what stops the bg renderer latching the
obj renderer's data. The `bg_ack_while_obj_owns` counter
(`tb_ssv_frame_crc.sv`) must stay at 0.

### R9. Width warnings are suppressed in every build script — MEDIUM, easy to miss

`verif/build_frame_crc.sh:23-27` passes `-Wno-WIDTH -Wno-WIDTHTRUNC
-Wno-WIDTHEXPAND`; `verif/run_gameplay_sims.sh:11-14` the same. This change's
most likely mechanical error is a bus-width typo across three modules' port
lists ([24:3]→[24:4], 64→128), and **the build will not warn**. §5.4's lint run
without those suppressions is not optional.

### R10. The 296/13/63 % figures are worst-case — LOW, but state it

296 is a busy line. `docs/DYNAGEAR_CORE_AUDIT.md:312` records
`max_line_entries=86` for the 950-frame gameplay run, so the peak is real, but
the average line saves less. The proposal should be justified on the *worst*
line, since that is the one that tears.

### R11. The benefit cannot be demonstrated until `+REAL_SDRAM` is trustworthy

`verif/ssv_sdram_harness.sv` and `verif/ssv_sdram_chip.sv` are another agent's
uncommitted work in progress. Until they are proven — including that the
*unmodified* core reproduces the hardware symptom under them — the bandwidth
claim rests on the arithmetic in §0, not on measurement. That arithmetic is
sound, and its 13-cycle figure independently reproduces the measured number, but
"sound arithmetic" is not this project's evidence standard.

**Sequencing consequence: land `+REAL_SDRAM`, reproduce the overruns with the
current layout, and only then do the repack.** Otherwise there is no before to
compare against.

---

## 7. Alternatives considered

### Option A — repack to 16-byte records + `p2` (this document)

−34.6 % graphics SDRAM cycles, deterministic and content-independent. Negative
FPGA area (deletes 25 flops and a state). Zero edits to `sdram.sv`. Costs 4 MB
of SDRAM and a rewrite of the load offsets.

### Option B — keep the layout, cache the Q2 beat across scanlines

The brief's suggestion. It is correct that the Q2 beat contains two rows: the
address `PLANE45_BASE + (code<<5) + (row<<2)` truncated to `[24:3]`
(`ssv_gfx_row_fetch.sv:55-58`) fetches rows `row&~1` and `row|1` of the *same*
tile, and `selected_row` (`:62-63`) throws half of it away.

The problem is **when** the other half is needed. Within one scanline every
fetch is a different screen column, i.e. a different code — the reuse is never
intra-line. It is strictly cross-scanline: line *y* fetches row *r*, line *y+1*
fetches row *r+1* of the same code. So a single-entry cache hits **never**; the
beat must survive ~148 intervening fetches. That needs a real cache — say
direct-mapped, 128 entries × (64 data + 11 tag) bits ≈ 1.5 M10K — in a design
already spending 22 M10K on the descriptor cache.

Ceiling: 50 % of Q2 fetches hit → 25 % of transactions removed → 3848 → 2886
cycles (62.8 % → 47.1 %). Realistically less, because it degrades exactly where
it is needed: dense, fast-moving scenes with vertical motion and flipped sprites
are where hit rate falls and where lines tear.

Its genuine advantage is real and should not be dismissed: **no layout change,
no loader change, no MRA risk, no 4 MB, R1/R2/R3/R5/R6 all vanish.**

### Option C — a per-line row cache in front of `ssv_gfx_row_fetch`

Tag on `(code, row)` and skip **both** beats on a repeat. Subsumes B. 148
tile-row fetches for a 336-pixel line is ~7× overdraw, so if repeated codes are
common (tilemap sky/ground bands are the obvious candidate) the hit rate could
exceed anything B achieves. Entirely data-dependent and currently unmeasured.

**Cheap to settle:** add a histogram of repeated `(code,row)` pairs per scanline
to `tb_ssv_frame_crc` and run the existing gameplay scenario. No RTL change, no
risk, one afternoon.

### Option D — 12-byte records (no pad)

Rejected. `p2` bursts are 16-byte aligned (`sdram.sv:59`, `:363`); a 12-byte
record at offset 12 mod 16 straddles two bursts. This is why the pad exists at
all — it is alignment, not carelessness.

### Recommendation

**Option A**, with Option C measured first and kept as a later, orthogonal
addition.

Reasoning, stated as the trade it actually is:

1. **A's saving is content-independent; B's and C's are not.** The defect being
   chased is a worst-case phenomenon — drifting bands on busy lines. A cache's
   hit rate is lowest exactly there. A 34.6 % reduction that holds on the worst
   line is worth more than a nominal 25 % that evaporates on it.
2. **A costs negative FPGA resources.** B and C cost M10K blocks in a design
   already at 22 M10K for descriptors alone.
3. **`sdram.sv` needs no edits.** The 128-bit port is fully built and dead. The
   risk is concentrated in one pure function that a unit test and a 950-frame
   CRC both bracket.
4. **A is exactly verifiable.** "Byte-identical CRC" is a binary, unarguable
   gate. A cache's correctness gate is the same CRC, but its *benefit* gate is a
   hit-rate number that varies by scene — much weaker evidence.
5. A and C compose: with A landed, a row cache removes whole 17-cycle
   transactions instead of 13-cycle ones.

Against my own recommendation, honestly: if the goal were solely "lowest risk of
introducing a regression," Option B wins outright, because it never touches the
ROM layout — the one thing this project's own conventions single out as a
generator of fake bugs. I recommend A anyway because B's payoff is roughly
two-thirds of A's *at best* and degrades under load, while A's is guaranteed and
free of silicon cost. But if `+REAL_SDRAM` shows the current layout misses
deadlines by a small margin rather than a large one, B becomes the right call —
so **measure the margin before committing**.

---

## 8. Interaction with work in flight

At the time of writing the working tree carries uncommitted changes from another
agent:

* `rtl/video/ssv_bg_renderer.sv`, `rtl/video/ssv_cached_sprite_renderer.sv` —
  a row-scroll / tilemap-page fix. **Conflicts with §4.3**: both files' port
  lists are edited by this proposal. Land the row-scroll fix and re-baseline the
  golden CRC first; a repack landed on top of an unstable baseline makes the
  byte-identical gate meaningless.
* `verif/tb_ssv_frame_crc.sv`, `verif/ssv_sdram_harness.sv`,
  `verif/ssv_sdram_chip.sv` — the `+REAL_SDRAM` harness. **This proposal
  depends on it** (§6 R11) and must not be started before it lands.

**Order of operations:** row-scroll fix → re-baseline golden CRC → `+REAL_SDRAM`
lands and reproduces the overruns → capture the "before" numbers → repack.
