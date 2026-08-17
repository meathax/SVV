# Phase 6 — the line doubler, tested for the first time

`rtl/ssv_scandoubler.sv` replaced `sys/arcade_video.v` in commit `095d3b2`,
whose own message records:

> Verified by parse and elaboration only… **Not built, not simulated, no
> hardware — and the line doubler in particular has never produced a pixel.**

`verif/tb_ssv_scandoubler.sv` is that missing test. It found **three** defects,
all of which would have been visible on a real 31 kHz monitor.

## Method

The bench drives the **real** `ssv_video_timing` and, originally, a **verbatim
copy** of the `ce_pix_x2` generator from `Arcade-SSV.sv:604-617`. That matters:
the doubler's stated contract is "ce_pix_x2 is exactly twice ce_pix and
phase-locked to it", and the generator is the thing that has to satisfy it.
Testing against an idealised 2× enable would have passed while the shipped
design failed.

Every pixel carries its own coordinate in its RGB value
(`rgb = {vcnt[7:0], hcnt[8:0], 7'b0}`), so a failure decodes to a coordinate
rather than "the picture looks wrong".

Each defect was **observed failing before its fix**, per `CLAUDE.md`.

## D1 — every doubled line was one pixel short

`ssv_video_timing`'s `pixel_acc` free-runs; `Arcade-SSV.sv`'s `ce2_acc` was a
**second** accumulator reset on every line reference. A line is
454 × 65536 / 9710 = **3064.2** clk_sys, so the two could not stay in step.

Measured: **907** `ce_pix_x2` ticks per line, constant, where exact doubling of
a 454-pixel line needs **908**. The second copy of every line was truncated by
one pixel.

**Fix.** Delete the wrapper's generator and derive both enables from **one**
accumulator in `ssv_video_timing`, running at twice the pixel increment with
`ce_pixel` taken as every second carry.

This is bit-identical to the old single-rate version, which is why it moves no
frame CRC: the k-th native tick was the smallest N with
`floor(N*INC/65536) == k`, and the 2k-th double-rate carry is the smallest N
with `floor(N*2*INC/65536) == 2k` — the same condition.

> **Verified: 215-frame gameplay frame-CRC md5 `0f45c3c0…` identical before and
> after.**

## D2 — every stored line was shifted by one pixel

The write at the line reference targeted the **old** bank at index `wr`, and
`hmax <= wr` included it. But the line reference is the *end* of hsync, so that
pixel is the **first pixel of the new line**. Every stored line therefore lost
its own first pixel and gained the next line's.

Bench output before the fix:

```
A2 FAIL line=3 outpix=1 got(x=401,y=0) want(x=402,y=0)
```

**Fix.** At the reference, write the pixel to index 0 of the **new** bank and
set `hmax <= wr - 1`.

## D3 — vsync emitted three times per frame

Not predicted; found by assertion A4. The doubler's line runs hsync-to-hsync
(hcnt 400) while `vcnt` increments at hcnt 453, so **a stored line straddles a
vcnt boundary**. Replaying it twice replayed the vsync transition inside it
twice, giving 3 `vs_out` pulses per frame where a monitor expects 1.

**Fix.** vsync and vblank are **per-frame** signals. Doubling changes the pixel
rate, not the frame rate, so they are already correct at the output and must not
be replayed. They now pass straight through; only the per-line signals (hsync,
hblank) are stored. The stored word drops 28 → 26 bits.

## Results

| assertion | before | after |
|---|---:|---:|
| A1 line-doubling ratio (908/line) | 763 fail | **0** |
| A2 pixel content and order | 691,270 fail | **0** |
| A3 hsync replay (2 pulses/line) | 0 | **0** |
| A4 vsync (1 pulse/frame) | 2 fail | **0** |
| A6 active DE (161,280 px/frame) | 4 fail | **0** |

`PASS tb_ssv_scandoubler`. Added to `verif/run_bringup_sims.sh`.

## Two bench bugs worth recording

Both would have produced false verdicts:

1. **A1 undercounted by one.** `ce_pixel` high implies `ce_pix_x2` high on the
   same clock (they register the same carry), so resetting both counters on the
   line reference discarded that tick. The DUT read 907 when it was already
   correct at 908. Both counts now add the boundary tick back.
2. **A6 was too strict.** It demanded 672 active pixels on *every* line,
   including blanked ones, and then on the two vblank **boundary** lines, which
   legitimately split one active region between them (measured 52 + 620 = 672).
   It is now a per-frame total, the only form invariant to the straddle.

## Not addressed

- **Startup.** `hmax` is `'1` until a full line has been measured, so the first
  two lines after a video reset replay 512 uninitialised entries. That is by
  design and invisible in practice; the bench skips those lines.
- **Hardware.** Still never run on a real 31 kHz monitor. That remains the
  outstanding check.
