# Action plan from the PCB evidence

Written 28 July 2026, after photographs of a real **STA-0001B** motherboard and a **SAM-5127**
Dyna Gear cartridge resolved a set of previously unconfirmed assumptions.

## The honest headline: the board mostly *validated* the core

This is worth stating plainly before listing work, because it changes what is worth doing.
Of everything the photographs settled, **nothing contradicted the implementation**:

| Assumption | Was | Now |
|---|---|---|
| Pixel clock 42.9545 MHz ÷ 6 | inherited from an emulator | ✅ crystal legible on the board |
| V60 at 16.000 MHz | inherited | ✅ 48.000 MHz crystal ÷ 3 |
| ES5506 shares the CPU clock domain | convenient simplification | ✅ only two crystals exist, so OTTO must divide from 48.000 |
| Two 8-position DIP banks | from emulator dip tables | ✅ two 8-way banks on the silkscreen |
| 16-bit CPU bus, byte-split ROMs | inferred by the loader | ✅ `PRL` / `PRH` positions |
| Graphics in four "quarters", fourth absent | MAME comment, no justification | ✅ four banks `A/B/C/D`, sockets unpopulated |
| GFX 12 MB + samples 4 MB SDRAM budget | sized from the ROM set | ✅ `16M-MASK` sockets, population matches |

**So there is no corrective RTL work arising from the photographs.** The temptation is to
manufacture changes to show the research paid off; the correct response is to record the
confirmations and spend effort where evidence actually points at a gap.

Two real gaps *were* found, and both are about the wider family rather than Dyna Gear.

---

## Item 1 — 3P/4P inputs are real hardware we do not implement

**Evidence.** The SAM-5127 carries `3P` and `4P` connector positions with an `I/O-FILTER`
stage at U30/U31 conditioning them. This is not a stuffing option on a generic board — the
filtering is dedicated to those inputs.

**Current state.** `ssv_core` implements `in_p1` / `in_p2` only. The extra-input window at
CPU `$500008` is tied to `16'hFFFF` in `Arcade-SSV.sv`, with the comment *"Tied `0xFFFF` — OK
for Dyna Gear"*.

**Hypothesis worth testing:** `$500008` is where the third and fourth player ports read back.
That would explain why the address exists, why it is decoded at all, and why the cartridge has
filtered 3P/4P inputs.

**Work:**
1. Confirm or refute by probing which addresses a 3P/4P-capable SSV title reads. Cheap in
   simulation with another game's ROM; free if someone with a board can strap an input.
2. If confirmed, widen the input path: `in_p3` / `in_p4` through to the `$500008` read mux,
   and OSD/joystick plumbing in the wrapper.
3. Keep Dyna Gear's behaviour byte-identical — it never reads those ports, so the 950-frame
   golden CRC must not move. That is the acceptance test.

**Priority: medium.** No effect on Dyna Gear; a hard blocker for any 4-player family title.

---

## Item 2 — the ROM budget is Dyna-Gear-shaped and should be parameterised

**Evidence.** `16M-MASK` × 16 sockets = a **32 MB graphics ceiling** on SAM-5127. Dyna Gear
uses 12 MB of that, plus 4 MB of samples.

**Current state.** `ssv_pkg.sv` hard-codes one layout:

```
SDR_SPRITES_BASE = 0x0100000    GFX   0x100000-0xcfffff  (12 MB)
SDR_SAMPLES_BASE = 0x0D00000    samp  0xd00000-0x10fffff (4 MB)
SDR_XRAM_BASE    = 0x1100000
SDR_DYNA_RAM_BASE= 0x1120000
```

Those constants are correct for Dyna Gear and confirmed against the physical chip complement.
But `SDR_DYNA_RAM_BASE` is named after the game, and the offsets assume its exact ROM sizes.

**Work:**
1. Rename `SDR_DYNA_RAM_BASE` to something board-descriptive — this window is the CPU RAM at
   `$400000`, not a Dyna Gear invention.
2. Treat the base addresses as a per-title layout block rather than loose localparams, so a
   second game is a new layout rather than an edit of shared constants.
3. Add a compile-time assertion that the layout does not overlap and fits the 32 MB SDRAM.

**Priority: medium.** Pure hygiene, zero behavioural change, but it is the difference between
"a Dyna Gear core" and "an SSV core". Do it before adding a second title, not after.

---

## Item 3 — verify the bank→quarter mapping (cheap, closes a real unknown)

**Evidence.** Four graphics banks `A0–A3`, `B0–B3`, `C0–C3`, `D0–D3`. Our
`ssv_gfx_row_fetch.sv` fetches "quarters" Q0/Q1 packed and Q2 separate, with the fourth
"absent, reads as zero".

The board having four banks with positions unpopulated is strong support. What it does **not**
establish is *which* bank feeds which quarter.

**Why it may not matter:** the graphics decode correctly across 950 CRC-verified frames, so
whatever mapping the loader uses is behaviourally right for this ROM set. This is therefore a
*confidence* task, not a bug fix.

**Work:** when a second SSV title is added, if its graphics decode wrongly with the same
loader interleave, this is the first thing to suspect. Record that pointer now — currently
nothing links the loader's interleave to the physical bank layout.

**Priority: low now, high the moment a second game misbehaves.**

---

## Item 4 — measurement checklist (unchanged, still the biggest lever)

Nothing in the photographs can settle these. They need a board.

| Measurement | Unblocks | Effort |
|---|---|---|
| **Scope HSYNC / VSYNC**: period, pulse width, polarity | The only remaining *invented* constants in the video path (`ssv_video_timing.sv` admits this in its own comment) | 10 minutes |
| Capture a frame to confirm the 336/240 active split | A2/A3, currently only "the product is right" | 30 minutes |
| **Close-up of the upper-right motherboard QFP (~U14)** | Completely unread. By size and position, the likely sprite/tilemap engine — the one part with no documentation anywhere | one photograph |
| Close-ups of the centre QFP (`ST0007`?) and lower-left QFP (`ST0005`?) | Confirms or corrects part numbers I currently record as *probable* | one photograph |
| `JP1`–`JP4` strap positions | Unknown configuration options | one photograph |
| ES5506 clock pin frequency | Turns `ce_snd = ce_cpu` from strongly-implied into confirmed | 5 minutes |

---

## What this plan deliberately does not do

- **No renderer changes.** Nothing in the photographs contradicts it, and it is CRC-locked to
  MAME across 950 frames plus pixel-exact at eight sampled character-select frames. Changing
  it on the strength of a photograph would trade a verified reference for a guess.
- **No CPU clock ppm "fix".** 21702 → 21704 would improve 71 ppm to 22 ppm, but shifts the
  CPU-to-raster phase and invalidates the golden CRC. Recorded in `Arcade-SSV.sv` as a
  deliberate non-change; revisit only if the golden is being re-cut anyway.
- **No speculative Seta custom modelling.** Until that QFP is identified there is nothing to
  model against.

---

## Recommended order

1. **Item 2** (ROM layout hygiene) — free, no behavioural risk, and it is cheapest before a
   second title exists rather than after.
2. **Item 1** (3P/4P) — start with the `$500008` investigation; only build the input path if
   the hypothesis holds.
3. **Item 4** measurements — whenever a board is to hand. The sync-width scope trace is ten
   minutes and closes the last invented constants in the video path.
4. **Item 3** — record the pointer now, act only if a second game decodes wrongly.
