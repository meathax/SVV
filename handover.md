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

## 5. 2026-08-22 MAME-versus-Verilator audio continuation

The differential lane is now implemented and has current paired captures.
MAME 0.289 and RTL are independently deterministic for the 156-frame
`audio_coin_prefix` scenario (journal SHA-256
`228498b4f97400c564a3feb704482b59d00bfbba0c659cefe9d7573fa52a85ef`).

The first RTL PCM captures peaked at only +/-1 because the headless testbench
compiled out its sample-ROM backend: `samples.bin` loading and p4 readback were
guarded by `SSV_VISUAL`, which the strict headless build does not define. This
was a verification-harness defect, not ES5506 RTL. The strict build now defines
`SSV_HEADLESS_SAMPLE_ROM`, enabling only sample ROM loading/readback without
enabling SDL or other visual code.

Closure evidence:

- The first fetches are the expected `c400`, `d000`, `c400`, `d000`, `d000`,
  `0400`, `d000`, `0400`; 60,588 fetches complete, 60,459 nonzero.
- RTL PCM peak advances from 1 to 2,720 (MAME prefix peak 3,222).
- Same-window RTL A/B traces match 184,186 normalized `cpu_data` events with
  no resynchronization; comparator digest
  `edebadc4cde0561370446824db2b8e7315fc40af18590a0950467161e288af8b`.
- PCM, frame, state, native-frame, and trace hashes match independently.
- The first aligned 50 ES5506 host writes match MAME. Write 51 diverges because
  the V60 observes the `FB24` main-loop/IRQ handshake at a different raster
  phase, so longer CPU-driven audio comparison is not yet trustworthy.
- The initial aligned waveform reaches correlation 0.884 over 5,000 samples
  after deterministic 31.25 kHz to 48 kHz resampling and a two-sample phase
  adjustment (fitted gain 0.929).

The corrected diagnostic replay was then repeated with the real sample backend
and a bounded ES5506 event trace. It completed 156 frames with 217,375 ES5506
events: 61 host commits, 182,763 voice writebacks, 21,630 sample requests,
7,210 sample completions, and 5,711 sample ticks. There were no dropped events,
sample underruns, renderer deadline failures, or RTL assertions. The trace
SHA-256 is
`871532950b57a878be540c8bb635c4687efbc4e92034df415a383aa2ee581c41`.

This closes the identified silent-audio defect and the ES5506 RTL semantic
boundary in simulation: the focused register/voice regressions pass, the exact
Drift Out voice prefix fetches the expected bank-2 words and produces material
PCM, and independent corrected RTL runs are byte-identical. The remaining
MAME-vs-full-core mismatch is upstream of ES5506: after the first 50 matching
sound commits, the V60 observes the FB24 main-loop/IRQ handshake at a different
raster phase. That makes later CPU-driven audio command order an invalid audio
engine comparator, not evidence of a new ES5506 arithmetic fault.

No synthesizable RTL, clock, reset, CDC, SDC, framework, or RBF changed in this
continuation. Physical MiSTer audio and the original recurring hardware warble
remain unverified because no board capture was available; claiming hardware
closure would exceed the evidence. The next experiment, if hardware or a
sound-command replay barrier becomes available, is to validate the same ES5506
event contract at the exact name-entry passage without changing V60 timing.

## 6. 2026-08-22 full gameplay audio and command-capture continuation

The corrected sample-ROM backend was carried through the complete 941-frame
`gameplay_neutral` journal. The gameplay-only lane reached its explicit entry
barrier at frame 820 and the 120-frame neutral soak, with a complete receipt:
`sim_output/diff/drifto94-audio-gameplay-fixed-b/rtl-receipt.json`. The run is
headless, one-thread, dropped=0, and contains 511,898 stereo source frames;
PCM peak is 2,720, the first non-zero source frame is 62,975, and the PCM hash
is `587dd709919874eb69c52308a66ca242c75305201e5ecd34b46684bc97bed159`.
The bounded ES5506 trace hash is
`4578c31a888cd22ff83e7dd0a708e1b2daac6ec1c491fcd53b9018ff5a8e17f5` and
contains 531,158 events (515,062 voice writebacks and 16,096 sample ticks)
with no underrun event. A first full replay also reached frame 940 but stopped
at finalization because the attract-only assertion was incompatible with this
gameplay journal; its common PCM prefix is byte-identical to the corrected
gameplay run. The dedicated attract lane remains the attract assertion gate.

MAME ES5506 bus capture is now pinned for the same journal and MAME 0.289:
`sim_output/diff/drifto94-audio-gameplay-mame-bus-80/mame-trace.jsonl`, SHA-256
`b8e5d8a72d2ec28da13a9a337029515d197d81f22f34bf00eecdfa5ac2f452c9`, with
3901066 main-bus and 461871 cpu-data events. The mapped sound writes repeat a
stable sequence at `0x300000-0x30007f`; the first 50 semantic host commits
remain the exact matching prefix already recorded above. The first later
divergence is still the V60 `FB24` main-loop/IRQ phase, not an ES5506 register
or sample fetch mismatch.

A bounded temporary diagnostic build substituted MAME's 11-bit interpolation
fraction for the production OTTO-spec 9-bit fraction. It made the aligned
prefix materially worse (correlation 0.786 over 1,000 samples and 0.590 over
3,000, versus 0.886 and 0.910 for production), so that hypothesis is rejected
and the production RTL was restored unchanged. No production sound fix beyond
the headless sample-ROM backend correction is justified by current evidence.

The sound issue is therefore closed as a verified simulation-harness defect and
as a deterministic non-silent ES5506 path. It is not closed as perfect MAME
equivalence or original-PCB warble removal: exact command replay into an
isolated ES5506 comparator and a real MiSTer/PCB audio capture remain the next
evidence threshold. No RBF was built.
