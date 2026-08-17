# Dyna Gear natural IRQ-cadence decision record — 2026-08-15

## Observation

The corrected input contract (`-coin_impulse -1`) closes the earlier frontend
adapter mismatch.  At the first remaining exact architectural state, both
lanes are at `PC=0x00F1E8E8`, `R2=0xFFFA1A72`, and `R16=0x00F29D94`.

The next MAME boundary is `0x00F1E8EB` (`mov.h R2,[R17+]`).  RTL instead
requests and acknowledges level-3 IRQ at its native frame boundary and the
next retirement is the level-3 handler at `0x00F11124`.  The active divergence
is therefore an interrupt-cadence/CPU-phase boundary, not the later RAM write.

## Evidence

* `sim_output/diff/dynagear-irq-cadence-exec-v2.json` is the fresh strict,
  no-resynchronisation comparison.  It records MAME next PC `F1E8EB`, RTL
  next PC `F11124`, RTL IRQ request at cycle `406962020`, and acknowledgements
  at cycles `406962038..040`.  The exact start state occurs once in the MAME
  trace; the comparator now fails closed if the requested occurrence is absent.
* The paired MAME capture is complete and pinned to MAME 0.289, journal digest
  `8396230ffcefd1dc5d7c28bb9391b938c6293b6dd78b9a57daecaa260ab9fcc4`, and
  `coin_impulse=-1`.  Its explicit handler artifact is
  `sim_output/diff/dynagear-exec-mame-irq-482-v5/mame-v60-irq-entry.jsonl`.
  The three marker entries are before the aligned state.  The beam-annotated
  debugger trace shows handler entry at `(beamx=2, beamy=240)` and the aligned
  state at `(beamx=220, beamy=215)` in the following raster; this rules out a
  wrong physical IRQ scanline and leaves CPU throughput/phase as the active
  producer class.
* The MAME debugger trace SHA-256 is
  `296a427aa728ffa63fbc53f90f1920c9fa1ec3eb58e360eed52c95ded6d58244`.
  The RTL causal trace SHA-256 is
  `fa28abe6ab439d694823bfaae2e7ca78acde11db7246b5a4d5cd6be16590091a`.
* Pinned MAME source independently fixes the producer class: `ssv.cpp:239-263`
  raises IRQ level 3 at scanline 240, and `ssv.cpp:2422-2440` configures the
  16 MHz V60 and raw 454x262 raster.  The MAME V60 device source
  (`src/devices/cpu/v60/v60.cpp:614,626`) explicitly charges an average
  instruction cost, so its retirement rate is not independent PCB timing
  evidence.
* ROM bytes at `0x00F29D94` and `0x00F29D96` are `0x1A72` and `0x1AC0` in
  both the pinned MAME image and RTL's loaded `maincpu.bin`; a ROM-content
  hypothesis is falsified.
* Two independent cold RTL runs reproduce the same first boundary (the
  complete long register run and the fresh causal window).  The fresh window
  is diagnostic-only and intentionally stopped after its declared trace
  barrier; the complete run remains the acceptance receipt.
* Two independent cold MAME causal captures (`dynagear-mame-irq-pe482-b` and
  `...-c`) produce byte-identical debugger traces (SHA-256
  `7e84807f929cb9e06df1a66c871b726cc60b6c1578f5a2ffe21abbf810559975`) and
  each contains exactly one cursor-482 occurrence of the aligned state at
  beam `(220,215)`.  This closes same-side MAME determinism for the causal
  observation; it does not make MAME's average V60 timing PCB evidence.

* A fresh strict headless RTL cadence run,
  `sim_output/diff/dynagear-rtl-cadence-pe482-a/rtl-receipt.json`, completed
  510 native frames and 428,638,144 cycles with zero drops.  Its receipt,
  frame stream, and state stream have SHA-256 digests
  `291BD12CB95D338E9B6794C04D460DA654A3A2D265CB9FC56919E073ADF60E75`,
  `6FED82ED218BDFCCE2792F67CD6EEF1C784161F6998CFF93CE202D03D4224B7F`, and
  `D2056A997696936A7ECFB9C589FC693E5DB080817FEDDC20725ADD3A514C60B5`.
  The trace reports one level-3 VBlank request/ack sequence per native frame;
  no assertion, watchdog, or line-pool overrun occurred.  Counting the
  model's `v60_retire` records gives 36,028--40,320 boundaries per steady
  frame (37,823 average for frames >=20; 36,260 at frame 482).  This is a
  same-side RTL measurement only: the MAME schedule's ~33,230 entries per
  IRQ is not yet proven to count the same architectural event, so the numeric
  difference is cadence evidence, not a cycle-equivalence verdict.

* The existing headless frame bench now has a simulation-only cadence
  assertion: duplicate level-3 entries are always fatal, while
  `+ASSERT_IRQ_CADENCE` opts into requiring exactly one entry after CPU
  activity has been established.  A rebuilt model passed the 20-frame Dyna
  Gear opt-in smoke with `irq_entries=vb_pulses` from frames 1--19, zero
  renderer overruns, and a complete receipt.  A four-frame Cairblad diagnostic
  smoke passed the universal no-duplicate check with the pre-existing
  nonblack-image gate disabled; its CPU remained in boot, so the exact-one
  contract was correctly not enabled.  These checks are same-side invariants;
  they do not gate or alter synthesised IRQ logic.

* The current strict-only gameplay-window pair is recorded in
  `sim_output/diff/dynagear-cross-strict-current-f841-843.json`. Two cold MAME
  captures match at 65,275 projected `cpu_data` events, and the current cold
  RTL window matches an independent RTL window at 61,854 events. The fresh
  cross comparison has no resynchronisation and reaches the same first
  downstream mismatch at ordinal 21: work-RAM write `0x790C`, BE2, MAME
  `0x5100` versus RTL `0x1100`. This confirms the active target under the
  explicit `cpu_data_lane_mask_v1` contract; it does not select a hardware
  correction.

## Hypotheses and falsification

1. **Program ROM/fetch data is wrong.** Falsified by the matching ROM words
   and matching architectural start state.
2. **IRQ latch/ack ordering is wrong.** Not selected: RTL's request, vector,
   and acknowledgement are internally ordered and are observed before the
   handler retirement; no MAME equivalent event has yet shown a latch-order
   violation.
3. **Natural CPU throughput/phase differs.** Selected as the supported
   explanation.  MAME has already serviced the level-3 handler before the
   aligned state, while RTL reaches that state at scanline 240 and services it
   immediately.  Existing natural-IRQ evidence in
   `docs/issues/DYNAGEAR_NATURAL_IRQ_SKEW.md` independently reports the same
   cadence class.  Both lanes use the same physical scanline-240 producer.

## Selected explanation

The first causal producer is the natural VBlank/CPU interrupt cadence.  This
is an **INFERRED** hardware conclusion: it is supported by paired instruction,
IRQ and raster observations, but exact PCB phase remains unmeasured.  No
synthesizable RTL correction is justified yet.

## Smallest change

Only read-only observability changed: the MAME runner now emits a validated
handler-entry artifact and `tools/compare_ssv_irq_cadence.py` binds one exact
architectural start state to the next instruction and RTL IRQ window.  No
core RTL, memory map, interrupt vector, clock, constraint, or framework file
was changed for this divergence.

## Verification and regression scope

The corrected MAME capture completed its stop barrier with zero drops and the
declared journal.  The strict instruction and IRQ-cadence comparators passed
their schema/receipt checks and produced the single active divergence above.
The Dyna Gear smoke run passed the new invariant.  The next full functional
run after any eventual timing correction must cover all eight qualified sets
because the V60 interrupt cadence is shared hardware.

## Known unknowns / next experiment

The exact board VBlank-to-CPU phase and the real V60 instruction/bus timing
remain open.  MAME's pinned V60 implementation documents its instruction cost
as an average placeholder, so matching its retirement rate is not independent
hardware evidence.  The read-only cadence measurement is complete.  The next
valid experiment is a cycle-faithful MAME IRQ schedule or independent V60
timing/PCB phase evidence before any RTL edit.  Do not compensate with a
delayed IRQ, frame offset, crop, or game-specific exception.

## Cursor-483 barrier falsification

A cold MAME diagnostic capture at the immediately following input cursor was
run with the same pinned executable, ROMs, descriptor and journal:
`sim_output/diff/dynagear-mame-irq-pe483-a`.  Its complete receipt reports
941 frames, gameplay marker 820, zero drops, and the same journal digest.  The
cursor-483 debugger trace contains no occurrence of the cursor-482 state
`PC=F1E8E8, R2=FFFA1A72, R16=F29D94`; it starts at the next natural handler
entry (`F11124`, beam `(2,240)`) and ends in the idle loop at `F10575`.
Therefore the mismatch cannot be repaired as a bookkeeping-only cursor
translation.  The existing cursor-482 comparison remains the sole active
target, and the producer explanation stays **INFERRED** natural CPU/IRQ
cadence with no synthesizable correction selected.

## Gameplay state-side evidence

The canonical journaled MAME adapter now has an opt-in read-only state-CRC
sidecar.  Two cold captures,
`sim_output/diff/dynagear-state-mame-a/mame-state.crc` and
`sim_output/diff/dynagear-state-mame-b/mame-state.crc`, are byte-identical:
both have 941 contiguous records and SHA-256
`309e2f028a47d7356b2eda02b33fcd14e58889d563939db538360c29650d3d65`.
The same-side receipt is
`sim_output/diff/dynagear-state-mame-sameside.json` (SHA-256
`ff13bfc07a9186aff693cfcddcc1538d9bb53627519c9393ecc9f3d6febefc7b`;
normalization `state_crc32_v1`).

Against the existing cold RTL state stream, the declared gameplay/soak window
820--940 first differs at frame 820 only in `scroll63` (MAME `15c7d3d4`, RTL
`5456bd80`); `list512`, `spr8k`, and `pal512` agree at that boundary.  The
machine-readable receipt is
`sim_output/diff/dynagear-state-gameplay-soak.json` (SHA-256
`5a65da81316a4185d6a430ecfd1e06a50f0b575ee2004cbb2f394a01024927ed`).
As a diagnostic control only, excluding `scroll63` yields a 121/121 match
for `list512`, `spr8k`, and `pal512` in
`sim_output/diff/dynagear-state-gameplay-soak-noscroll.json` (SHA-256
`26663c92b54e800636814d17b7f605a251ab277ac15dc0da237268a6e00c8fd0`).
This is a downstream diagnostic result, not a new active target: no scroll,
raster, crop, or state workaround is permitted while cursor 482's CPU/IRQ
divergence remains open.
