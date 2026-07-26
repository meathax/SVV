# SSV core architecture

The initial bitstream is deliberately Dyna Gear-specific. It uses the proven
System 32 V60 and MiSTer shell while implementing the SSV board around it.

## Memory placement

On-chip RAM holds latency-sensitive work RAM, sprite/list RAM, and palette RAM.
The two additional CPU RAM windows are placed in unused SDRAM above the 17 MiB
ROM image so the design stays within Cyclone V block-RAM capacity.

**MiSTer SDRAM: one stick (32 MiB).** The controller addresses `[24:1]`
(32 MiB byte space). Dyna Gear's image + CPU windows top out near `0x115FFFF`
(~18 MiB). `MISTER_DUAL_SDRAM` is not defined.

| SDRAM byte range | Content |
|---|---|
| `0000000-00fffff` | V60 program |
| `0100000-0cfffff` | sprite graphics; Q0/Q1 rows packed, Q2 native |
| `0d00000-10fffff` | ES5506 samples |
| `1100000-111ffff` | CPU RAM `160000-17ffff` |
| `1120000-115ffff` | CPU RAM `400000-43ffff` |

## Bring-up order

1. V60 reset-vector fetch, RAM test, I/O and vblank IRQ.
2. Exact sprite-list and tilemap-sprite replay against MAME.
3. Scanline renderer and 32-bit palette path.
4. ES5506 register and voice engine.
5. MRA, Quartus fit/timing, MiSTer deployment, and frame/audio comparison.

Steps 1-3 now pass focused tests and a 60-million-clock real-ROM video
simulation. Quartus analysis and synthesis also passes with the scanline
buckets and four-bank compositor inferred as M10K memory. Audio, full fitting
and timing closure, and physical MiSTer validation remain open.
