# Session handover — 2026-08-21/22

## 1. RTL fixes committed (dfed31a)

- **ES5506 ECOUNT-freeze ramp abort** (`rtl/audio/ssv_es5506_regs.sv`): a host
  write that zeroes ECOUNT for a voice mid-slot now also aborts the
  LVOL/RVOL/K1/K2 ramp step for that voice, not just ECOUNT's own register.
  Per OTTO Rev 2.3 spec sec 11.5 (p35): the whole group is aborted together
  if ECOUNT is zero, checked "immediately before updating the oscillator."
- **V60 XCH memory-to-memory** (`rtl/cpu/v60/s32_v60.sv`): implemented via new
  states `S_XCH_MMRD1/2`, `S_XCH_MMWR1/2` — load op1, load op2, store op1,
  store op2.

Both pushed to `main` before this session's later work.

## 2. Sound debug overlay (uncommitted)

Added to chase the still-unresolved ES5506 warble (see §3):

- [rtl/debug/ssv_debug_overlay.sv](rtl/debug/ssv_debug_overlay.sv) — new
  module. Draws a column of squares over the right edge of the active
  picture. Rows 0-7 are toggle flip-flops (flip on each pulse of their
  monitored signal — green=1/red=0); row 8 is 5 squares showing the raw
  5-bit last-serviced voice index. Row order top-to-bottom: `sound_commit`,
  `irq_promote`, `voice_writeback`, `sample_req`, `sample_done`,
  `sample_tick`, `sample_underrun`, `frame_boundary`, `voice_index[4:0]`.
- [rtl/ssv_core.sv](rtl/ssv_core.sv) — added a new **unconditional** `ovl_*`
  port block mirroring the sound-path signals the overlay needs. Necessary
  because the existing `debug_*` bus is gated `` `ifdef SIMULATION `` and is
  stripped from synthesis — the overlay needs these signals in a real RBF,
  not just sim.
- [Arcade-SSV.sv](Arcade-SSV.sv) — wires `ovl_*` from `ssv_core`, instantiates
  `ssv_debug_overlay`, muxes its output into `av_r/g/b` ahead of the
  scandoubler, gated by `localparam DEBUG_OVERLAY_EN` (currently **`1`** —
  **flip to 0 before any real release build**).
- [files.qip](files.qip) — added the new source file.

Interpretation caveat baked into the module's own header comment: a square
whose monitored signal pulses faster than once per video frame (e.g.
`voice_writeback`, `irq_promote`, which fire per-voice every frame) will
show as red/green speckle rather than a flat color — that's scanout
sampling a flip-flop that changed value mid-frame, not a rendering bug.

## 3. RBF build

Built clean with the overlay enabled: `releases/Arcade-SSV_20260822.rbf`
(SHA-256 `b7bdf1f3aaa6b4323c6dd60adb6240e4c0121c9b3e028ee094bc412fff76f7fd`),
0 errors, positive setup/hold slack, 98% ALM. Full report already given
earlier in-session. **Ships with the debug overlay visible on-screen** —
intentional, for the screenshot/video capture below. Not yet committed.

First compile attempt failed (`can't find port "debug_hpos"` etc.) because
the top level wired the sim-only `debug_*` bus into synthesis — fixed by
adding the unconditional `ovl_*` ports instead (§2).

## 4. Sound warble investigation — user-supplied clips

Two screen recordings of the attract-mode name-entry/flag-select screen,
confirmed by the user to contain the actual "warped sound plays in and out"
bug. Overlay readout across both clips:

- **`sample_underrun`**: fires once early, then holds steady — does **not**
  keep re-firing through the clip. SDRAM sample-fetch starvation is
  therefore *not* the ongoing/repeating cause — rules out that failure
  class for the continuing warble (though the one early hit is worth
  keeping in mind).
- **`irq_promote` / `voice_writeback`**: continuous speckle throughout, as
  expected for normal per-voice servicing every frame — not informative by
  itself.
- **`sound_commit`**: sparse — few host register writes during this
  screen. The warble keeps occurring even between commits, so it is **not**
  new host writes racing the engine each time (i.e. not simply more
  instances of the §1 ECOUNT-freeze race, which needs a fresh host write to
  trigger).
- **`sample_req`/`sample_done`**: moderate steady cadence, no widening gap
  visible — fetch pipeline isn't stalling.

**Working theory**: the recurring warble is most likely an ES5506
frequency/phase-accumulator or ECOUNT-ramp arithmetic defect that doesn't
depend on host-write timing or SDRAM starvation — i.e. something in the
core interpolation/ramp math itself, not a timing race. The §1 fix
(ECOUNT-freeze ramp abort) is real and correct per spec, but evidently isn't
the whole story since the warble is still audible on this build.

**Next step (not started)**: reproduce this exact attract-mode scenario in
MAME and Verilator side by side and find the first sample-value divergence
in the ES5506 output — pins the actual arithmetic error rather than just
its timing envelope. Use the `mister-mame-diff` skill /
`mister-differential-debug.md` workflow.

## Outstanding / not done this session

- Debug overlay files are **uncommitted** (`git status`: `Arcade-SSV.sv`,
  `rtl/ssv_core.sv`, `files.qip` modified; `rtl/debug/` and
  `releases/Arcade-SSV_20260822.rbf` untracked).
- `DEBUG_OVERLAY_EN` must be set back to `0` before any real release build.
- No MAME/Verilator differential run has been done yet for the warble
  itself — only the on-screen overlay read from user-supplied video.
- Not deployed to hardware.
