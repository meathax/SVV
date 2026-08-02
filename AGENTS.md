# SSV project contract — one universal profile

These instructions apply to every chat, sub-agent, automation, and review
working in this repository.

## Non-negotiable target

This project has exactly one MiSTer core profile:

- Quartus revision: `Arcade-SSV`
- runtime bitstream: `SSV.rbf`
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
NORMAL router, Smart Recompile, compression-off, and machine-wide processor
limits intact. Inspect timing and resource reports before treating an RBF as
deployable. Preserve `db/` and `incremental_db/` for Smart Recompile.

## Scope boundary

`sys/` is the upstream MiSTer framework and is not a normal fix location.
Keep all game and board behavior in `rtl/`, the top-level glue, descriptor
generation, and verification. Do not change pin assignments or framework
files during a simulation/debug loop.
