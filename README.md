# SSV MiSTer FPGA Core

Work-in-progress MiSTer FPGA implementation of the Sammy, Seta, and Visco
(SSV) arcade platform. The initial target is Sammy's **Dyna Gear**.

## Legal notice

No copyrighted game ROMs are included. Place locally owned ROM archives under
`rom/`; that directory is deliberately ignored by Git.

## Current status

The first synthesizable bring-up baseline is in place:

- MiSTer shell, PLL, SDRAM controller, and V60 CPU ported from the nearby
  System 32 core.
- Dyna Gear ROM stream layout and MRA.
- SSV CPU map, board RAM, input ports, interrupt controller, and raster timing.
- Real Dyna Gear program-ROM reset test reaches `0x00f10120` in 292 cycles.
- Quartus 17 analysis and synthesis passes; the board RAMs infer as block RAM.

Sprite rendering and ES5506 audio are not implemented yet, so this is not a
playable release.

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
`docs/ARCHITECTURE.md` for the current board model.
