# SSV MiSTer FPGA Core

Work-in-progress MiSTer FPGA implementation of the Sammy, Seta, and Visco
(SSV) arcade platform. One universal `SSV.rbf` contains all shared and optional
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
- Quartus 17 analysis and synthesis with 17,075 registers, 4,392,866 block
  memory bits, and 39 DSP blocks. All eight line-buffer banks infer as M10Ks.
- A synthesizable ES5506 host interface and complete low/high/test register
  pages, validated against the Dyna Gear MAME trace with a self-checking
  Verilator test.
- Direct DB15 arcade controls on the User I/O port for both players, for the
  Antonio Villena SNAC splitter / JAMMA SNAC (`rtl/ssv_joy_db15.sv`, OSD
  "DB15 Devices"). This is the core-side reader, as used by Arcade-TNKIII: it
  drives the adapter's shift register from the core, so it controls the GAME
  only. It is not the MiSTer-DB9 fork's framework mode, so it does not give
  the pad control of the OSD and does not present the fork's "UserIO Joystick"
  / "UserIO Players" options. Not yet confirmed against real hardware.
- A deliberately small video chain: `rtl/ssv_scandoubler.sv` (a plain 2x line
  doubler for 31 kHz monitors) and `video_freak` (integer-scaling modes).
  Scanline FX come from `sys_top`, which applies them itself from `VGA_SL`.
  `arcade_video` was tried and removed: its scandoubler carries HQ2x line
  stores and it pulls in `gamma_corr`, together about 13 M10K, which this
  design cannot afford. Neither HQ2x nor gamma is missed on an arcade board.
- High score save/load via the MRA's hiscore.dat entry and a `.nvm` dump,
  through the second port of the SSV main RAM.
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

For a complete compile that copies a dated bitstream to `releases/SSV_YYYYMMDD.rbf`:

```powershell
./tools/build-ssv.ps1
```

MAME is the behavioral reference. Verilator tests live under `verif/`; GTKWave
is used for waveform inspection. See `docs/MAME_REFERENCE.md` and
`docs/ARCHITECTURE.md` for the current board model, and
`docs/ES5506_RESEARCH.md` for the audio sources, measurements, and roadmap.
