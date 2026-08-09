# SSV core architecture

The project produces one universal `Arcade-SSV.rbf`. It uses the proven System 32 V60
and MiSTer shell while selecting program/graphics/sample geometry, watchdog,
inputs, RAM/NVRAM, IRQ1 and ST010 behavior from the MRA index-1 descriptor.
Optional devices are synthesized once and runtime-gated; there are no
per-game Quartus revisions or compile-time game switches.

## Memory placement

On-chip RAM holds latency-sensitive work RAM, sprite/list RAM, palette RAM and
the ST010 data memories. The descriptor-sized program/graphics/sample streams,
extra CPU RAM, NVRAM and ST010 program image use one 128 MiB SDRAM module. The
regions intentionally occupy separate SDRAM banks to preserve row locality.

| SDRAM byte range | Content |
|---|---|
| `0000000-03fffff` | V60 program slot, up to 4 MiB |
| `0400000-045ffff` | descriptor-selected extra CPU RAM windows |
| `0460000-046ffff` | descriptor-selected NVRAM, up to 64 KiB |
| `2000000-3ffffff` | packed graphics records, up to 32 MiB |
| `6000000-67fffff` | ES5506 samples, up to 8 MiB |
| `6800000-6810fff` | optional ST010 program/data image |

## Bring-up order

1. V60 reset-vector fetch, RAM test, I/O and vblank IRQ.
2. Exact sprite-list and tilemap-sprite replay against MAME.
3. Scanline renderer and 32-bit palette path.
4. ES5506 register and voice engine.
5. MRA, Quartus fit/timing, MiSTer deployment, and frame/audio comparison.

The shared functional paths have focused and bounded real-ROM evidence recorded
in `docs/implementation-status.md`. A fresh universal-source fit, timing pass,
RBF generation and physical MiSTer validation remain open.
