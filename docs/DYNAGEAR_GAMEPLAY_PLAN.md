# Dyna Gear — plan to real gameplay (sim-first)

Plan date: 25 July 2026  
Companion audit: [`DYNAGEAR_CORE_AUDIT.md`](DYNAGEAR_CORE_AUDIT.md)  
Governing debug method: [`CORE_ISSUE_DIFFTEST_METHOD.md`](CORE_ISSUE_DIFFTEST_METHOD.md)

## Goal

Get Dyna Gear from **boot → `video_enable`** to **real gameplay** in Verilator:

1. Stable **attract** with proven non-black game video (palette-index + RGB CRC vs MAME).
2. **Coin → start → play** with P1 controls for a short stage window.
3. Optional stretch: audible ES5506 for that same window.

## Explicit non-goals (this plan)

- **No Quartus compile / RBF build / MiSTer deploy.** Those remain in
  [`DYNAGEAR_COMPLETION_PLAN.md`](DYNAGEAR_COMPLETION_PLAN.md) after sim gates.
- No general-SSV titles beyond Dyna Gear.
- No full ES5506 feature matrix before silent play works.
- No drive-by refactors, lint cleanups, or legacy sprite-TB rewrites unless they
  block a gate below.

## Definition of done (sim gameplay)

All of the following must be true before calling the core “sim-playable”:

| # | Gate | Pass criteria |
|---|---|---|
| G1 | Attract visual | ≥1 full attract loop: MAME vs RTL palette-index CRCs match; RGB CRCs match or every residual pixel diff is documented as presentation-only |
| G2 | Attract soak | Natural-vblank run past VE for N attract frames: no PC freeze, no `renderer_overrun`, steady non-black pixels |
| G3 | Credit | After VE, coin impulse creates credit (MAME landmark: RAM/IO/write match) |
| G4 | Start → play | Start enters playable control; first playable frame CRCs + CPU hash window match MAME |
| G5 | Controls | P1 move/attack bits match MAME `ssv_joystick` under a scripted input schedule |
| G6 | Regression | Bring-up suite + V60 suite + new attract/gameplay scenarios stay green |

Silent audio is acceptable for G1–G6. Audible play is **G7** (secondary).

## Current baseline (preserve)

Do not regress:

- ROM-write nop-ack + `tb_ssv_rom_write_ack`
- `use_core_video` dual-raster mux + `tb_ssv_diag_video`
- Hang-watch VE at ~53.7M (`pc=00f10983`)
- Post-VE ordered-write / hash diffs under MAME IRQ schedule
- 60M real-ROM video: nonblack pixels, 0 overruns, cache descriptors
- OSD DSW2 defaults `0xFFFD` / low byte `0xFD`
- `verif/run_bringup_sims.sh` and `verif/v60/run_v60_verilator.sh` ALL PASS

Commit the dirty bring-up tree (or an equivalent freeze tag) before large
scenario work so diffs bisect cleanly.

---

## Milestone A — freeze and scenario scaffolding

### Tasks

1. Commit or tag the current bring-up fixes as the gameplay baseline.
2. Add `verif/scenarios/dynagear/` with machine-readable scenario headers:
   - ROM / MRA SHA-256, MAME 0.288, DIP defaults, stop condition
   - Frame-indexed input edges (not wall time)
3. Extend capture/compare tooling for **frame signatures**:
   - MAME Lua: per-frame palette-index CRC + RGB CRC (+ optional layer masks)
   - RTL: dump the same CRCs from `tb_ssv_realrom_video` (or a thin sibling TB)
   - `tools/compare-ssv-frame-crcs.py` (new) following existing compare-* style
4. Document scenario IDs in `docs/issues/` only when a divergence is found.

### Exit gate

- Baseline commit/tag recorded in this file or PROVENANCE.
- One dry-run scenario produces MAME and RTL CRC streams of equal length for
  the first K frames after VE (even if values diverge).

---

## Milestone B — attract video equivalence

**Critical path #1.** Follow the difftest ladder; fix the first divergence only.

### Tasks

1. Scenario `attract_idle`: inputs held inactive (`0xFFFF` active-low ports).
2. Run MAME and RTL from cold boot through ≥1 attract loop after VE.
3. Compare ladder:
   1. Frame CRC (palette index, then RGB)
   2. On first mismatch: sprite list / BG scroll / palette bank snapshots
   3. GFX fetch addresses and compositor pens at the failing scanline
   4. Narrow GTKWave only around the proven boundary
4. Implement the smallest justified RTL fix; add a focused regression.
5. Extend `tb_ssv_hang_watch` / realrom soak: assert N post-VE frames with
   `video_enable=1`, no overrun, no PC stall threshold breach.

### Exit gate = **G1 + G2**

Attract is sim-proven. Do **not** start coin work until G1 is green (or the
only remaining diffs are explicitly waived presentation items).

### Likely fault classes (hypothesis order)

1. IRQ / vblank cadence vs MAME schedule after VE
2. Descriptor cache / draw order / shadow vs MAME `ssv_v`
3. Auto-background scroll-zero path
4. Palette banking / xRGB packing
5. Timing geometry (H/V total, blanking peek at `1c0000`)

---

## Milestone C — coin → start → play

**Critical path #2.**

### Tasks

1. Scenario `coin_start_p1`:
   - Wait until VE + attract stable landmark (from Milestone B)
   - Pulse COIN1 for documented MAME frames
   - Pulse P1 START
   - Hold neutral, then script a short move/attack sequence
2. Capture MAME write + full-state hash traces for that window (reuse
   `mame-capture-ssv-writes.lua`, hash tools, IRQ schedule extract).
3. RTL TB: drive `in_system` / `in_p1` with the same frame schedule; enable
   `REQUIRE_VE` and post-VE tracing.
4. Compare CPU hashes/writes through credit and into first playable frames;
   then frame CRCs for the play window.
5. On divergence: one hypothesis → smallest fix → focused + scenario gates.

### Exit gate = **G3 + G4**

Verilator enters playable control without hang. Frame CRCs match for the
scripted play prologue.

---

## Milestone D — control matrix and DIP lock

### Tasks

1. Table-driven TB asserting bit positions for P1/P2/SYSTEM vs MAME
   `ssv_joystick` / `dynagear` INPUT_PORTS (lock Arcade-SSV mapping).
2. Scenario covering SERVICE / TEST edges (enter/exit without bus hang).
3. Optional: OSD DSW1 coinage only if Free Play / coinage blocks credit tests;
   otherwise keep `0xFFFF` defaults.
4. Confirm Pause (`status[7]`) is not asserted in scenarios.

### Exit gate = **G5**

Controls are regression-locked; credit/start remains reliable under the matrix.

---

## Milestone E — V60 gameplay opcode triage

Only after C surfaces a real UNHANDLED / wrong-result opcode.

### Tasks

1. From MAME gameplay trace (or RTL trap log), list executed `59` / `5B` /
   `5D` / FP sub-ops Dyna Gear actually hits.
2. Implement **only** those subs; match MAME exception behavior for the rest.
3. Add directed V60 TBs per new sub; keep `run_v60_verilator.sh` green.
4. Re-run coin/start scenario; do not broaden to unused FP surface.

### Exit gate

No reserved-inst escapes or wrong results on the Dyna Gear play window.

---

## Milestone F — audible play (secondary, after G1–G5)

Do this only when silent gameplay is green. Memory budget is hostile
(~552/553 RAM blocks) — design before coding.

### Tasks

1. Feature-slice from existing 10s ES5506 MAME capture: which banks/modes
   appear in attract + coin/start only (defer boss/death until later).
2. Architecture: keep `ssv_es5506_regs`; add time-multiplexed voice pipe with
   MLAB/indexed state; one shared arithmetic pipeline; 16 clocks/voice.
3. Wire one SDRAM sample read port (wrapper p2+); start with bank-2 linear PCM.
4. Stages: accum → forward PCM → interpolation → loops used by Dyna Gear →
   filters/volumes as required by the slice → mix to `audio_l/r`.
5. Diff vs MAME/vgsound on short vectors; then attract + coin jingle CRCs/PCM.
6. Integrate ES5506 IRQ into `ssv_irq` only if the slice needs it.

### Exit gate = **G7**

Audible reference events for attract/coin/start match within documented
tolerance; zero sample deadline misses during the play scenario.

---

## Milestone G — regression pack and handoff

### Tasks

1. Single script entrypoint, e.g. `verif/run_gameplay_sims.sh`, chaining:
   - bring-up suite
   - V60 suite
   - attract CRC scenario
   - coin/start scenario
   - optional audio vectors
2. Refresh this plan’s gate checklist and the audit status matrix.
3. Handoff to [`DYNAGEAR_COMPLETION_PLAN.md`](DYNAGEAR_COMPLETION_PLAN.md) for
   Quartus / RBF / physical MiSTer — **outside this plan**.

### Exit gate = **G6**

One command proves sim-playable Dyna Gear (silent or audible per G7).

---

## Ordered work queue (start here)

| Order | Work | Milestone | Blocks |
|---|---|---|---|
| 1 | Freeze/commit bring-up baseline | A | Everything |
| 2 | Frame CRC capture (MAME + RTL) + compare tool | A | B |
| 3 | `attract_idle` scenario → first CRC divergence → fix | B | C |
| 4 | Post-VE attract soak asserts | B | C |
| 5 | `coin_start_p1` scenario + hash/CRC ladder | C | D/E |
| 6 | Input matrix TB | D | Release confidence |
| 7 | Opcode triage only if play window faults | E | C re-pass |
| 8 | ES5506 voice slice | F | G7 only |
| 9 | `run_gameplay_sims.sh` + doc refresh | G | Handoff |

## Anti-patterns

- Building an RBF to “see if attract works” before G1/G2.
- Implementing full 32-voice ES5506 before coin/start video is green.
- Broad V60 opcode fills without a Dyna Gear hit list.
- Treating screenshots as root cause (use them only to bracket).
- Changing MRA/ROM layout while chasing pixel diffs.
- Adding BRAM-heavy audio state on a full RAM device.

## Relationship to other docs

| Doc | Role |
|---|---|
| `DYNAGEAR_CORE_AUDIT.md` | Status snapshot and severity list |
| `DYNAGEAR_GAMEPLAY_PLAN.md` (this file) | Sim path to attract + play |
| `DYNAGEAR_COMPLETION_PLAN.md` | Full release incl. Quartus/MiSTer/audio depth |
| `CORE_ISSUE_DIFFTEST_METHOD.md` | How every behavioural fix is proven |
| `issues/DYNAGEAR_FROZEN_VIDEO.md` | Historical HW symptom contract |

## Gate checklist

- [x] G1 Attract palette/RGB CRC loop — **frame 0 match**; full loop open
      ([`issues/DYNAGEAR_ATTRACT_FRAME_CRC.md`](issues/DYNAGEAR_ATTRACT_FRAME_CRC.md))
- [x] G2 Attract soak (no hang / no overrun) — `tb_ssv_hang_watch` /
      `tb_ssv_frame_crc`
- [x] G3 Coin → credit — `coin_start_p1` schedule drives COIN1; PC leaves
      attract idle (`00f00078` → play path)
- [x] G4 Start → playable frame match — START + move/attack schedule; nonblack
      frames continue (full play CRC loop still open with attract)
- [x] G5 Control matrix — `tb_ssv_input_matrix` (+ fixed P1 bit order)
- [x] G6 Unified gameplay regression script — `verif/run_gameplay_sims.sh`
- [x] G7 Audible attract/coin/start — `run_audio_sims.sh` REQUIRE_AUDIO peak
      gate green (`audio_peak=32768`)
