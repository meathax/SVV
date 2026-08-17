# Issue contract: Dyna Gear frozen/corrupt MiSTer video

> **RESOLVED 28 Jul 2026 (frozen half).** The static-frame symptom is gone.
> With the vblank cache deadline in RBF `a23cbf06…`, the core boots into the
> game on hardware and runs the whole attract sequence: title screen, gameplay
> demo, world map, and a playable-looking stage with HUD. Root cause was the
> descriptor-build latch-up documented in `DYNAGEAR_HW_RENDER_FIX_PLAN.md`
> §1.3, **not** the timing failure this issue originally blamed.
>
> A **separate, new** symptom remains and is tracked in the fix plan: horizontal
> tearing/striping concentrated in the upper part of the frame. That is a
> different failure with a different signature — see "Post-fix state" below.

## Issue

The current Dyna Gear core loads on the physical MiSTer but displays a mostly
black static frame with sparse corrupt grey/coloured graphics near the upper
left. Two framebuffer captures taken seconds apart were byte-identical.

## Deterministic scenario

- Set: `dynagear`
- MRA: `Dyna Gear.mra`
- MRA SHA-256:
  `73958e5a9f6dee5f29f0559d3f05ea71c0fb3cf8ff339daffe0ac05ec3195cf3`
- MiSTer: `192.168.0.69`
- Installed core observed: `SSV_20260724`
- Deployed RBF SHA-256:
  `43595e016efd46968207104ed36368f1f0586f99068356f0bd95ad63a7cf8064`
- MAME reference: 0.288 (`mame0288`)
- Local ROM archive SHA-256:
  `e0088d91679feaff026de267919700c86243c3823f5a1fb55894e1dbc4f7109d`
- Extracted main CPU image SHA-256:
  `c29d3bf37b761aad1f13b01be7da9904c0a975826744b820fdc664c098c66289`
- Extracted sprite image SHA-256:
  `5738ad3ac51f70d20702b564169b5516eb475b55af9a656181770461e86eab4f`
- Inputs: none; cold-load the MRA and observe attract boot.
- Stop: first stable attract frame or ten seconds after load.

## Current evidence

- Verilator PC and full V60 state match MAME through 1,072,678 available RTL
  retirements.
- 549,383 ordered accepted RTL writes match MAME.
- The 60-million-cycle real-ROM video test passes with 707,008 graphics reads
  and 118,457 nonblack pixels.
- The deployed RBF fails timing with worst setup slack of -1.284 ns.
- Its worst path is the sprite descriptor-cache M10K output to coordinate
  logic in `rtl/video/ssv_cached_sprite_renderer.sv`.
- A decode pipeline stage was added and passes the focused sprite test and the
  60-million-cycle real-ROM test.
- A fresh Quartus 17.1 fit then crashed in `quartus_fit.exe` during register
  packing. Timing improvement is therefore not yet measured.

## Last matching event

Not yet established at the frame/scanline level. The architectural trace
matches through the retirement and ordered-write counts above.

## First divergence

Unknown. The timing failure is a proven release blocker but is not yet proven
to cause the frozen image.

## Root-cause hypothesis — FALSIFIED 28 Jul 2026

Suspect *was*: the deployed timing-failing RBF violates the descriptor-cache to
coordinate path and corrupts or stalls sprite rendering. This predicted that a
timing-qualified build would change or eliminate the static corrupt frame.

**That prediction failed.** Steps 1 and 2 of "required next evidence" below were
executed on 28 Jul 2026 and the symptom survived a fully timing-clean build.

Status: `refuted`; evidence tier: `BOUNDARY` (hardware capture).

### The falsifying experiment

| | Value |
|---|---|
| RBF SHA-256 | `846c7b0269ee4e71b3f5a2aad1dec3d57d221ed7b9120cdd10a8c263a3a48e21` |
| RBF MD5 verified on device | `4d17331497639b08993bc8a5f59097c0` (4,400,796 bytes) |
| Deployed to | `/media/fat/_Arcade/cores/SSV.rbf`, MiSTer `192.168.0.69` |
| Quartus | 17.0.2, Fast Fit profile, `NUM_PARALLEL_PROCESSORS 1` |
| Fit | 34,366/41,910 ALMs (82%), 532/553 M10K (96%), 59 DSP |
| Setup slack, worst corner | **+0.392 ns** (`pll_hdmi`, Slow 1100 mV −40 C) |
| Worst hold | +0.100 ns |
| Multicorner | setup/hold/recovery/removal/MPW all pass, 4 corners, TNS 0 |
| `report-quartus.ps1` | `Deployable: True`, unconstrained clocks 0 |

The previously deployed core was the Jul 24 build (MD5 `aeb6834219c1694e2448a626e56355d7`),
preserved on the device as `SSV_backup_20260724.rbf`.

### Observed symptom on the timing-clean build

- Uniform **teal** active area with a short row of coloured blocks in the
  upper-left corner.
- Two screenshots ~20 s apart are identical — the frame is static, not animating.
- The core later returned to `MENU`; not established whether it self-exited.

Note the background is teal here, where the original report says "mostly
black". The symptom may have shifted rather than reproduced exactly. Do not
treat the two captures as the same failure until that is checked.

### What the teal field proves is working

`ssv_core` forces `rgb` to `24'h000000` whenever `!video_enable || hb || vb`.
A non-black active area therefore proves the CPU reached and executed the
`$21000E` bit-7 write. That places the following on the working side of the
boundary **on real hardware**:

- HPS ROM download and `ssv_rom_loader` interleave
- SDRAM controller init, the two-word program signature probe, and `rom_loaded`
- V60 reset, boot, and enough execution to reach the video-enable write
- vblank IRQ delivery (the game polls/services it before enabling video)
- `ssv_video_timing`, palette RAM, and the line-buffer scanout path

A uniform index-0 field means the line buffer is being scanned correctly and
`palette[0]` happens to be teal. **The renderer is simply not writing pixels
into it.**

## Post-fix state — 28 Jul 2026, RBF `a23cbf06…`

Deployed `a23cbf0622e65e7f467a6f43dcbeb43d1a0a11a2a89cc9f4db0e96d20e9a1c08`
(md5 `b2f0964117406e47779bfdd041609e3f`, 4,395,216 bytes). Fit: 34,433 ALMs
(82%), 532 M10K, all corners pass, worst setup +0.119 ns, `Deployable: True`.

**The frozen frame is gone.** Successive captures show the attract sequence
advancing on its own: Dyna Gear title with logo and Sammy copyright → an
animated gameplay demo → the WORLD MAP screen → a stage scene with the
character, platforms, and a live `AUTO SHOT` / `ROGER x 1` HUD. The core boots
into the game.

**New symptom: horizontal tearing/striping, worst near the top of the frame.**
The lower part of a frame is generally clean; the upper third breaks into
torn horizontal bands, and whole screens made largely of one big image (the
world map) are striped throughout.

Working interpretation — this signature is a *per-line deadline* failure, not
the whole-frame stall that was just fixed. The renderer is failing to finish
some lines before the buffer swap, so those lines show a mix of old and new
content. Verilator reports `overruns bg=0 obj=0` across all 950 frames, which
is exactly what you would expect if the difference is SDRAM service time: every
full-core bench drives the renderer through a **behavioural SDRAM model with
fixed low latency**, while the real controller round-robins six ports, stretches
ack over two `clk_ram` cycles, and stalls for refresh. The renderer's GFX fetch
(`sdr_p1`) is the bandwidth-critical consumer, and it is the one thing no
current testbench exercises realistically.

This makes Phase 3.1 of the fix plan (put `rtl/mem/sdram.sv` plus an SDRAM chip
model in front of `tb_ssv_frame_crc`) the load-bearing next step rather than an
optional investment: until it exists, simulation cannot reproduce or regress
this class of defect at all.

Confirming evidence to collect next: the state of the overrun LED
(`LED_DISK`/HDD LED). If it is lit, `renderer_overrun` has latched and the
per-line deadline miss is confirmed directly.

## Required next evidence

1. ~~Complete a fresh Quartus fit and pass `-RequireReady`.~~ **Done 28 Jul.**
2. ~~Deploy the exact hashed candidate and recapture.~~ **Done 28 Jul — symptom
   persists. Hypothesis refuted.**
3. Audit every `s32_big_dpram` client for whether it samples `q` on a write
   cycle. Hardware is configured `read_during_write_mode_port_a/b =
   "NEW_DATA_NO_NBE_READ"` while the behavioural model returns **old** data on
   a same-port write. The module comment justifies this with "core clients
   ignore q on a write cycle" — that assumption has never been checked, and if
   it is wrong anywhere in the sprite-RAM or palette path, Verilator can never
   reproduce the hardware behaviour. This is checkable in RTL with no hardware
   round-trip and is the cheapest remaining lead.
4. Confirm whether the frame is static because the renderer stalls or because
   it is reset-looping: `wdog_rst` fires 180 frames (~3 s) after the last
   `$210000` read and drops `video_enable`, which would blank the screen
   briefly. Capture at ~1 s intervals for 10 s to distinguish a hard stall from
   a ~3 s watchdog cycle.
5. Read the renderer overrun flag. `LED_DISK` is now driven from the sticky
   `renderer_overrun` bit (`debug_status[16]`), so the I/O board HDD LED lights
   on a line-deadline miss or a truncated descriptor/line-slot list. This
   distinguishes "renderer ran and overran" from "renderer never started".
6. If the renderer never started, instrument `sdr_p1` (GFX fetch) — the
   behavioural SDRAM in the testbenches acks on a fixed schedule, whereas the
   real controller round-robins six ports and stretches ack across two
   `clk_ram` cycles.
7. Only then add per-frame and per-scanline hashes to MAME and RTL to locate a
   first differing scanline, and a narrow GTKWave capture around it.

## Exit gate

Close only after the hardware symptom is reproducible, last-match and
first-divergence points are documented, a focused regression fails before and
passes after the correction, fresh MAME/RTL comparison passes, Quartus timing
is ready, and the hashed RBF reaches correct stable attract video on MiSTer.
