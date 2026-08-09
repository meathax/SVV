# SSV MiSTer FPGA Core

Work-in-progress MiSTer FPGA implementation of the Sammy, Seta, and Visco
(SSV) arcade platform. One universal `Arcade-SSV.rbf` contains all shared and optional
hardware paths; each MRA selects its board geometry at runtime.

## Legal notice

No copyrighted game ROMs are included. Place locally owned ROM archives under
`rom/`; that directory is deliberately ignored by Git.

## Current status

Full audit and sim-first path to attract/gameplay:
[`docs/DYNAGEAR_CORE_AUDIT.md`](docs/DYNAGEAR_CORE_AUDIT.md),
[`docs/DYNAGEAR_GAMEPLAY_PLAN.md`](docs/DYNAGEAR_GAMEPLAY_PLAN.md).
The pinned MAME contract and current deterministic baseline are recorded in
[`docs/DYNAGEAR_REFERENCE_CONTRACT.md`](docs/DYNAGEAR_REFERENCE_CONTRACT.md).
The single-profile set list and hardware-feature matrix are recorded in
[`docs/GAME_COVERAGE.md`](docs/GAME_COVERAGE.md).

**Multi-game, stated plainly (2026-08-09):** all eight qualified sets load
through one runtime descriptor and one shared source profile. The ST010 used by
Drift Out '94, Storm Blade and Twin Eagle II is always present in the RBF and
parks when `cfg.has_st010` is clear; there is no per-game compile switch. Every
set now has bounded real-ROM execution evidence, but none has completed the
current 360-frame Verilator screenshot plus matched-gameplay release gate. See
[`docs/GAME_COVERAGE.md`](docs/GAME_COVERAGE.md) for the per-game boundary.

The synthesizable Dyna Gear bring-up now includes:

- MiSTer shell, PLL, SDRAM controller, and V60 CPU ported from the nearby
  System 32 core.
- Dyna Gear ROM stream layout and MRA.
- SSV CPU map, board RAM, input ports, interrupt controller, and raster timing.
- MAME-derived palette, automatic background, normal sprites, tilemap sprites,
  depth modes, flips, shadows, and descriptor draw order.
- Vblank descriptor caching with per-scanline M10K buckets.
- A four-bank scanline compositor and packed two-beat graphics-row fetch.
- A 60-million-clock real-ROM Verilator run that reaches `0x00f10575`, caches
  1,277 descriptors, renders visible pixels, and reports zero background or
  object scanline overruns.
- Historical Quartus reports are retained for resource comparison only. They
  predate the mandatory universal ST010 integration and are not release proof.
- A synthesizable ES5506 host interface and complete low/high/test register
  pages, validated against the Dyna Gear MAME trace with a self-checking
  Verilator test.
- A deliberately small video chain: `rtl/ssv_scandoubler.sv` (a plain 2x line
  doubler for 31 kHz monitors) and `video_freak` (integer-scaling modes).
  Scanline FX come from `sys_top`, which applies them itself from `VGA_SL`.
  `arcade_video` was tried and removed: its scandoubler carries HQ2x line
  stores and it pulls in `gamma_corr`, together about 13 M10K, which this
  design cannot afford. Neither HQ2x nor gamma is missed on an arcade board.
- High score save/load plumbing via a `.nvm` dump, through the second port of the
  SSV main RAM. **Not currently reachable:** `tools/gen_ssv_mras.py` emits no
  hiscore.dat entry, so no MRA carries one, `hs_configured` stays 0 and the
  "Autosave Hiscores" OSD line stays hidden (`Arcade-SSV.sv:211`). The module is
  wired; the MRA side is missing.
- DIP switches driven from the MRA's `<switches>` block instead of hand-mapped
  OSD options, so the bytes the game reads at `$210002`/`$210004` are the ones
  the MRA states.

Sim gameplay gates (attract frame-0 CRC, soak, coin/start schedule, input
matrix, ES5506 PCM peak) are wired through `verif/run_gameplay_sims.sh`.
Full attract-loop CRC match and physical MiSTer play testing remain open, so
this is not yet a playable release.

## Visual Verilator checkpoints

The persistent checkpointable visual launcher is:

```powershell
# Interactive: F5 or Ctrl+S saves on the next completed native frame.
.\tools\run_ssv_checkpoint_visual.ps1 -Set dynagear -Detached

# Gameplay-proof chunks include an immutable RTL-owned input journal.
.\tools\run_ssv_checkpoint_visual.ps1 -Set dynagear `
    -Checkpoint .\sim_output\checkpoints\dynagear-gameplay.vltsv `
    -InputJournal .\sim_output\checkpoints\dynagear-gameplay.inputs `
    -ProofMode gameplay -SaveFrame 50
.\tools\run_ssv_checkpoint_visual.ps1 -Set dynagear `
    -Checkpoint .\sim_output\checkpoints\dynagear-gameplay.vltsv `
    -Restore .\sim_output\checkpoints\dynagear-gameplay.vltsv `
    -InputJournal .\sim_output\checkpoints\dynagear-gameplay.inputs `
    -ProofMode gameplay -SaveFrame 100
```

This is a separate external-clock `--no-timing --savable` build. It writes a
binary `.vltsv` only after a completed native framebuffer boundary and closes
the visible process after an automated chunk. The legacy timing visual build
still reports F5 as unavailable. A checkpoint is simulator state, not gameplay
proof; final qualification still requires the current Verilator gameplay gate
and matched reference evidence. Gameplay checkpoints carry a versioned sidecar
binding the archive, build, media, scenario, proof target, and canonical input
journal; a pre-journal checkpoint cannot be promoted into a matched proof.

## Build

Quartus 17 is required. To run analysis and synthesis only:

```powershell
./tools/build-ssv.ps1 -MapOnly
```

For a complete compile that replaces the single bitstream at `releases/Arcade-SSV.rbf`:

```powershell
./tools/build-ssv.ps1
```

MAME is the behavioral reference. Verilator tests live under `verif/`; GTKWave
is used for waveform inspection. See `docs/MAME_REFERENCE.md` and
`docs/ARCHITECTURE.md` for the current board model, and
`docs/ES5506_RESEARCH.md` for the audio sources, measurements, and roadmap.
