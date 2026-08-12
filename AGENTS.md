# SSV project contract — one universal profile

These instructions apply to every chat, sub-agent, automation, and review
working in this repository.

## Non-negotiable target

This project has exactly one MiSTer core profile:

- Quartus revision: `Arcade-SSV`
- runtime bitstream: `Arcade-SSV.rbf`
- per-game selection: MRA index-1 descriptor loaded before index-0 ROM data
- authoritative qualified-set list: `tools/ssv_supported_sets.py`

Do not create a per-game Quartus revision, per-game RBF, compile-time game
macro, game-specific source fork, or hardwired game fallback. A new board
enhancement belongs in the shared RTL and is selected by descriptor fields
only when the behavior is genuinely board-specific. Preserve one instance of
each optional device (ST010, ES5506, extra-input window, watchdog mode, and
graphics/audio paths) for all sets.

The currently qualified local sets are the ten entries in
`tools/ssv_supported_sets.py`. Do not duplicate that list elsewhere; update
the manifest first, then regenerate and verify the MRAs.

## Read before editing

Read these files before changing RTL, MRAs, tests, or build settings:

- `core-debug.toml`
- `docs/GAME_COVERAGE.md`
- `docs/implementation-status.md`
- `docs/ARCHITECTURE.md`
- `docs/PHASE8_MULTIGAME.md`
- `docs/OPTIMIZATION_PRE_RBF.md`

Preserve unrelated user changes and private ROM/NVRAM/capture data. Never add
commercial ROMs or generated traces/models to Git.

## Required change path

Every new feature, bug fix, or game-support change must be integrated in this
order:

1. Identify the shared hardware family and descriptor field in
   `ssv_cfg_t`; do not branch on a set name in synthesizable RTL.
2. Update `tools/ssv_supported_sets.py`, `tools/gen_ssv_mras.py`, and the
   generated MRA descriptors when the qualified set matrix changes.
3. Keep ROM mapping, SDRAM placement, audio banking, video geometry, inputs,
   interrupts, watchdogs, and optional CPUs behind the existing runtime
   descriptor and shared interfaces.
4. Add or extend a focused regression and update the feature matrix and
   evidence ledger. A test must cover both sides of a new optional path.
5. Run the profile/media audit before handing off:

   `python tools/verify_ssv_universal_profile.py --require-roms`

Do not claim full-set support from an MRA-only change. Record whether the
change is source-integrated, focused-simulation tested, real-game tested,
full-matrix tested, timing-clean, or hardware-tested.

## Safe verification and builds

Use `verilator-safe`/`verilator-sim-safe` and reuse their generated models.
Never launch overlapping Verilator builds or a full waveform by default. The
focused bring-up command is recorded in `core-debug.toml`.

The real-game attract milestone is Verilator-only. A qualified set must reach
the attract assertion in the current universal-model Verilator run, complete
the required frame soak with zero renderer overruns, and emit a non-empty
Verilator PPM/PNG screenshot from that same run. MAME runs and screenshots are
behavioral-reference evidence only and never satisfy this milestone.

Do not launch Quartus merely to explore RTL. Hardware compilation is a final,
explicit step and requires user authorization. When authorized, use
`tools/build-ssv.ps1 -QuartusRoot D:\Q17`; keep the required Fast Fit,
NORMAL router, Smart Recompile, compression-on, and machine-wide processor
limits intact. Inspect timing and resource reports before treating an RBF as
deployable. Preserve `db/` and `incremental_db/` for Smart Recompile.

## Scope boundary

`sys/` is the upstream MiSTer framework and is not a normal fix location.
Keep all game and board behavior in `rtl/`, the top-level glue, descriptor
generation, and verification. Do not change pin assignments or framework
files during a simulation/debug loop.

<!-- MISTER-FPGA-AUTOPILOT-V4:START -->
# MiSTer FPGA autonomous engineering contract

This repository is operated through the installed `$mister` skill and `tools/mister.*` executor. These v4 rules supersede older MiSTer Autopilot instruction blocks and `fpga.py` workflows in this repository.

## Ownership

Codex owns inspection, setup, source research, donor analysis, builds, simulation, capture,
normalization, comparison, diagnosis, bounded RTL correction, regression and Quartus verification.
Do not hand routine commands back to the user. Ask for user action only when physical hardware,
a missing ROM owned by the user, credentials, or inaccessible evidence makes it unavoidable.

## Hardware truth and evidence

Rank evidence as:

1. Original schematics, manuals, measurements, decaps and verified PCB observations.
2. MAME source plus deterministic MAME runtime evidence.
3. Open-source implementations of the identical device or board revision.
4. Related hardware and other emulators as hypotheses.

MAME is the behavioral software oracle for configured comparisons. It is not automatically a
nanosecond-perfect description of the physical PCB. Label claims as KNOWN, INFERRED or HYPOTHESIS.

## Differential debugging

Always:

1. prove independent same-side determinism;
2. validate the observability contract;
3. compare canonical domain-local events;
4. find the first meaningful divergence;
5. trace backward to the first causal producer;
6. apply one smallest synthesizable correction;
7. add a focused regression;
8. replay the exact case and then cold-run from reset;
9. continue to the next earliest divergence.

Never accept screenshot similarity, a shifted/resynchronized trace, omitted fields, missing-as-zero,
or a later symptom as proof. Do not create a huge waveform until coarse traces localize a narrow
window.

## RTL rules

Preserve hardware architecture unless evidence justifies a change. Prefer clock enables over fabric
clocks. Audit reset, initialization, width, signedness, byte lanes, masks, bus phase, wait/ack,
interrupt acknowledgement, DMA ownership, memory latency and cross-clock crossings before inventing
game-specific patches. One functional writer at a time.

## Quartus rules

Use Quartus 17.0.2-compatible constructs and flows for this project. Run lint/focused simulation
frequently, Analysis & Synthesis at subsystem milestones, and a full fit/timing pass at integration
or release milestones. Never hide a real timing or CDC failure with false paths, multicycle paths,
relaxed periods or clock-group exceptions unless the physical architecture proves the exception.

## Donor-core reuse

Before copying or adapting donor HDL, record repository URL, immutable commit, license, notices,
files reused and whether code is copied, adapted or reimplemented. Preserve attribution and reject
unclear license provenance. Similar board families are not assumed behaviorally identical.

## Durable records

Keep these current:

- `docs/HARDWARE.md`
- `docs/OBSERVABILITY.md` and `docs/OBSERVABILITY.json`
- `docs/VERIFICATION.md`
- `docs/PROVENANCE.md` and `docs/PROVENANCE.json`
- `docs/STATUS.md`
- solved divergences under `docs/debug/`

Treat `.mister/state.json` and run manifests as machine state. Do not edit generated evidence to make
tests pass.
<!-- MISTER-FPGA-AUTOPILOT-V4:END -->
