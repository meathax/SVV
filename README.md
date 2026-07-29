# SSV MiSTer FPGA Core

Work-in-progress MiSTer FPGA implementation of the Sammy, Seta, and Visco
(SSV) arcade platform. The initial target is Sammy's **Dyna Gear**.

## Legal notice

No copyrighted game ROMs are included. Place locally owned ROM archives under
`rom/`; that directory is deliberately ignored by Git.

## Current status

Full audit and sim-first path to attract/gameplay:
[`docs/DYNAGEAR_CORE_AUDIT.md`](docs/DYNAGEAR_CORE_AUDIT.md),
[`docs/DYNAGEAR_GAMEPLAY_PLAN.md`](docs/DYNAGEAR_GAMEPLAY_PLAN.md).

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
- The standard MiSTer arcade video chain: `arcade_video` (gamma, scandoubler,
  HQ2x, scanline FX) and `video_freak` (integer-scaling modes). The scandoubler
  is sized to the game's 336-pixel active width rather than the library default
  of 768, which halves its line stores on a design where M10K is the binding
  resource.
- High score save/load via the MRA's hiscore.dat entry and a `.nvm` dump,
  through the second port of the SSV main RAM.
- DIP switches driven from the MRA's `<switches>` block instead of hand-mapped
  OSD options, so the bytes the game reads at `$210002`/`$210004` are the ones
  the MRA states.
- CRT Adjust — H-Size, H-Position and V-Shift for a 15 kHz analog CRT, from
  [rmonic79/MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust)
  (`rtl/crt_adjust.sv`, core-side variant, `sys/` untouched). Off is a pure
  passthrough. Not yet confirmed on a real CRT.

Sim gameplay gates (attract frame-0 CRC, soak, coin/start schedule, input
matrix, ES5506 PCM peak) are wired through `verif/run_gameplay_sims.sh`.
Full attract-loop CRC match and physical MiSTer play testing remain open, so
this is not yet a playable release.

## Build

Quartus 17 is required. To run analysis and synthesis only:

```powershell
./tools/build-ssv.ps1 -MapOnly
```

For a complete compile that copies the bitstream to `releases/SSV.rbf`:

```powershell
./tools/build-ssv.ps1
```

MAME is the behavioral reference. Verilator tests live under `verif/`; GTKWave
is used for waveform inspection. See `docs/MAME_REFERENCE.md` and
`docs/ARCHITECTURE.md` for the current board model, and
`docs/ES5506_RESEARCH.md` for the audio sources, measurements, and roadmap.
