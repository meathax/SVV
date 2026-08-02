# Dyna Gear MAME / Verilator gameplay validation

> Historical evidence only: this report predates the current universal-model
> matched-gameplay gate. It does not satisfy the owner-required current
> same-run Verilator gameplay proof.

## Result

The Verilated core now accepts coin and Start, clears character selection,
passes the story/map transitions, and reaches controllable jungle gameplay.
The final deterministic run completed 950 post-video-enable frames with all
assertions enabled.

Final gate:

```text
GAMEPLAY_FRAME f=850 green=31553 nonblack=74917
PASS ... frames=950 ... overruns bg=0 obj=0 max_line_entries=86
```

## MAME reference

Two independent MAME 0.288 replays match for all 950 frame CRC records and all
950 captured state records. The reference reaches the same jungle scene and
uses movement plus two attack intervals.

Before input begins, stable attract frames 2 and 3 match RTL exactly:

- index proxy CRC: `7063ffe9`
- RGB CRC: `9ecf2e6e`
- pixel comparison: 80,640 / 80,640 exact

The first post-coin visual phase split occurs at frame 36. Through frame 49,
the comparable sprite-list, sprite-RAM, and palette hashes still match MAME.
The scroll hash is excluded because the MAME address-space capture and RTL
register array are not equivalent layouts. Late gameplay images therefore
show animation/input phase differences and are not treated as same-frame pixel
goldens.

## Core issues corrected

1. P1 port bits were mapped in the wrong order, so Start/B1 became movement.
2. The final visible line was never exposed because the display buffer did not
   perform the target-y 240 swap.
3. The PPM harness omitted the first active coordinate and produced 80,639
   pixels, masking scan-pipeline analysis; it now writes all 80,640.
4. A 56-entry sprite line table overflowed at frame 172. A 64-entry table then
   exposed a real 65+ sprite line at frame 485. The measured 950-frame maximum
   is 86; the implementation uses 96 entries.
5. Dense lines exceeded the object-render deadline. Registered next-descriptor
   prefetch and transparent-row bypass close the deadline without relaxing the
   SDRAM handshake or assertions.
6. The 96-entry table originally stored a full 11-bit descriptor index in all
   23,040 slots. It now stores a 7-bit low index plus per-line 128-entry page
   boundaries. Descriptor order makes this encoding lossless; raw index
   storage falls from 253,440 to 179,760 bits while retaining all 96 slots.
   Cyclone V geometry predicts about ten fewer M10Ks than the unpacked table.
   This estimate still requires confirmation by the next non-concurrent fit.

Focused dense-renderer result: `2573` clocks against the conservative unit
limit of `2691` (formerly `2624`). The real 950-frame run reports no deadline
miss.

## Audio status

The gameplay MAME trace contains 9,784 completed ES5506 writes and exercises
all 32 voices. RTL register and voice unit tests pass; the natural-IRQ real-ROM
gate reports `audio_peak=32768`.

Audio is functional, not complete: no sample-accurate MAME PCM comparison or
physical MiSTer audio validation has been completed.

## Remaining release gates

- Quartus Fast Fit, M10K utilization, and timing after the packed 96-entry
  line table (target: approximately 23 M10Ks for indices + page metadata)
- generated RBF smoke test on MiSTer
- longer/full-game input scripting beyond the first controllable stage window
- sample-accurate ES5506 PCM comparison

GTKWave was not used in this pass. Exact CRC, pixel, cache-state, and cycle
counters localized every reproduced defect before a waveform was warranted;
the installed environment also has no GTKWave executable. A narrow FST should
only be added if a later failure cannot be isolated by these deterministic
gates.
