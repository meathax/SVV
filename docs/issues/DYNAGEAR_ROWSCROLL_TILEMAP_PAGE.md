# Issue contract: Dyna Gear — white blocks while scrolling right

## Issue

Reported from hardware play: *"during gameplay when we move right, large
sections of the game render as white boxes, then load in normally after a few
seconds."*

This is the same shape as the symptom `fd37ce6` addressed ("large parts of the
level draw as white boxes that render in again further on, with the game's own
font glyphs appearing as scenery"). That fix stopped the tilemap page moving
*along* a scanline. It did not stop the page moving *between* scanlines, which
is what this issue is about.

## Deterministic scenario

- Set: `dynagear`, MRA `Dyna Gear.mra`
- Scenario: `verif/scenarios/dynagear/coin_start_p1_long.json`
  (`+SCENARIO=coin_start_p1_long`), which holds P1 RIGHT for 140 of every 240
  frames from post-VE frame 950 onward.
- Determinism: `+verilator+seed+1 +verilator+rand+reset+2`, assertions on,
  default fast SDRAM model.
- ROM images: `sim_output/rom/{maincpu,sprites}.bin`.

## Hypothesis (recorded before the test)

**H1.** The tilemap page is derived from the row-scrolled position rather than
from the raw scroll register, so a per-line row-scroll offset can move an entire
scanline onto the neighbouring tilemap.

MAME `src/mame/seta/ssv_v.cpp`, `draw_row_64pixhigh()`:

```c
int tilemap_scrollx = m_scroll[scrollreg * 4 + 0];
const int size = 1 << (8 + ((mode & 0xe000) >> 13));
const int page = (tilemap_scrollx & 0x7fff) / size;      // raw scroll
...
if ((unknown & 0x05ff) == 0x0440) tilemap_scrollx += -0x10;   // after page
if (BIT(mode, 12))                                            // after page
    tilemap_scrollx += m_spriteram[scrolltable_base + (realy & 0x1ff)];
int x = tilemap_scrollx;
for (...) { get_tile(x, realy, size, page, ...); x += 0x10; }
```

`page` is fixed by the **raw** scroll register. The RTL instead passes
`scroll_x + rowscroll` as the page-selecting origin, in
`ssv_cached_sprite_renderer.sv` `TILE_ROW_WAIT` and `ssv_bg_renderer.sv`
`ROW_WAIT`.

Consequence: while the raw scroll sits just below a multiple of the map size,
every scanline whose row-scroll offset carries it over that multiple reads the
next page — a different map — for its whole width. Because a row-scroll table
varies smoothly down the screen, the affected lines form contiguous bands. Once
the raw scroll itself passes the multiple, RTL and MAME agree again and the
picture repairs itself: "loads in normally after a few seconds".

**Refutation condition.** If, over the scrolling scenario, the page computed
from `scroll_x + rowscroll` never differs from the page computed from raw
`scroll_x`, H1 is refuted and the remaining corruption has another cause.

## Detector

`verif/ssv_tilemap_page_check.sv` binds into `ssv_core` and compares the two
page computations on every row-scrolled scanline, in both renderers. Counting
mode by default; `+TMPAGE_FATAL` turns it into a hard gate.

`verif/tb_ssv_tilemap_page.sv` is the unit-level version: it drives
`ssv_bg_renderer` with a scroll value just below a page boundary plus a
row-scroll offset that crosses it, and checks the sprite-RAM address at the
module boundary against the formula transcribed from `get_tile()`.

## Result — CONFIRMED and FIXED

**H1 confirmed.** Over a 1500-frame run of `coin_start_p1_long` the detector
counted 11,887 row-scrolled scanlines that selected a different page from the
one MAME's rule gives, across 51 frames. The worst case is total:

```
TMPAGE_BAD f=372 src=BG y=119 mode=3628 size=512 raw=1024 used=66559 page_ref=2 page_used=1
TMPAGE_FRAME f=373 obj_bad=0 bg_bad=240      <- every scanline of the frame
TMPAGE_TOTAL obj_rows=459286 obj_bad=0 bg_rows=241635 bg_bad=11887
```

The row-scroll word is `0xffff`, a one-pixel step back. MAME adds it to an int
(1024 -> 66559) and keeps `page = 1024>>9 = 2`; the RTL masked the sum to 15
bits first (`66559 & 0x7fff = 1023`) and got page 1, so the whole background
layer read the neighbouring tilemap.

The trigger is therefore *not* "near a page boundary" as the hypothesis assumed.
It is "raw scroll at or just above a multiple of the map size, with any negative
row-scroll offset", which is common — and it explains the self-repair, because
the picture corrects as soon as the raw scroll moves past the multiple.

**Fix.** `tile_address()` now receives the raw scroll register as the page
origin in both renderers, while the running position still carries the offset:
`ssv_bg_renderer.sv` ROW_WAIT and `ssv_cached_sprite_renderer.sv` TILE_ROW_WAIT.
Two functional lines each.

**Verified on hardware.** The user confirmed the white boxes are gone after
deploying the resulting RBF. That is stronger evidence than the simulation gate
this document originally planned, which is why it is recorded here as the
primary result.

Note the object renderer never picked a wrong page in this scenario
(`obj_bad=0` over 459,286 row-scrolled scanlines) — the exercised defect was
entirely in the background layer. The object-side change is correct by the same
rule but is currently unexercised by any test.

### Separately found and NOT fixed

`ssv_bg_renderer` sets `screen_x` from `scroll_x[3:0]` only, ignoring the
row-scroll offset, where MAME uses `0 - ((tilemap_scrollx + rowscroll) & 0xf)`
and the object renderer does include it. On row-scrolled lines that misplaces
the background layer by up to 15 pixels horizontally. The path is live —
241,635 row-scrolled scanlines in 1500 frames — so this is exercised, real, and
untested. It is left alone deliberately rather than bundled into an unrelated
fix.
