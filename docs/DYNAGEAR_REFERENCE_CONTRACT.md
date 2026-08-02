# Dyna Gear reference contract

This file pins the behavioural reference and the current verification boundary
for the first SSV representative. It separates current measured facts from
older or incomplete evidence.

## MAME pin

The primary executable reference is:

```text
binary:      D:\Arcade\AI\mame\mame.exe
version:     0.288 (mame0288)
SHA-256:     DCF8677FCE188E8E2625D4A2928005565652930D3F85D930F5D49D939535B182
```

The inspected MAME source tree is pinned independently at:

```text
repository:  D:\Arcade\AI\MAMESOURCE\mame
commit:      affe701f9210d003d2cc5eff311f94053afa679b
driver:      src/mame/seta/ssv.cpp
ssv.cpp SHA: DF86A0E381A75C8027BFAD593B7AC047EE3B30FB91EA6EBBAA823D00038C9D01
```

On 1 Aug 2026 the external source checkout was at tag `mame0289`, commit
`f34f02505e32c1993c6a782b6814232cbfc74e36`. Its `ssv.cpp` blob
(`8d4623cf26f1cbe73665334211e7989fc939bd51`) and `ssv_v.cpp` blob
(`1efd4a8d9dab90e011a69cabfeaac844ed5cb1ba`) match the pinned commit exactly.
The behavioural contract therefore remains the pinned 0.288 source, with the
newer checkout recorded only as an independently verified equivalent source.

`GAME(1993, dynagear, 0, dynagear, dynagear, ...)` makes `dynagear` the sole
parent set for this release path; there is no Dyna Gear clone set. The MAME
XML entry identifies it as Sammy's 1993 Dyna Gear and uses the same ROM names,
CRCs, and SHA-1s as `mra/Dyna Gear.mra`.

The local ROM audit passed with the private ROM directory explicitly selected:

```text
D:\Arcade\AI\mame\mame.exe -rompath D:\Arcade\AI\SVV\rom -verifyroms dynagear
romset dynagear is good
1 romsets found, 1 were OK.
```

The current MRA hash is:

```text
mra/Dyna Gear.mra SHA-256: CC30D2E3BC07A46656588DAF642D2E63A6BF94221E5F074DDE25B1C632F531AF
```

All Dyna Gear scenario files use this MRA pin. `coin_start_p1_long.json` still
records MAME 0.285 as a legacy long-run artifact; it is not part of the
current 0.288 reference gate until regenerated.

## Hardware contract extracted from MAME

- V60 and ES5506 clocks: 16 MHz (`48 MHz / 3`).
- Native raster: 454 by 262, visible area 336 by 240.
- Main ROM: two 512 KiB byte-interleaved devices at `maincpu`.
- Graphics: six 2 MiB linear devices, 12 MiB total.
- Samples: four 1 MiB word-swapped devices in ES5506 region 2, 4 MiB total.
- Main map and IRQ behavior are recorded in `docs/MAME_REFERENCE.md`.

The source-derived contracts are from the SSV address map, `dynagear` input
ports, `dynagear` machine configuration, and the `dynagear` ROM declaration in
`ssv.cpp`; they are behavioural contracts, not a translation of MAME's
internal call order.

## Baseline observed 31 July 2026

Worktree starting point: `cb86793986eef0e28baa2c8abab431b71cc0595c`.

The following safe Verilator gates passed using WSL's
`verilator-safe`/`verilator-sim-safe`, `--threads 1`, `--verilate-jobs 4`, and
`--build-jobs 4`:

| Gate | Result |
|---|---|
| ROM loader | PASS |
| ST010 fetch boundary | PASS, 74 instruction fetches |
| Scandoubler | PASS, 3 frames and all replay checks |
| Loader/core boot | PASS, `rom_loaded=1`, first PC `fffffff0` |
| ROM-write acknowledgement | PASS, acknowledged in 0 cycles |
| Watchdog | PASS, timeout at 180 frames and correct kick direction |
| Natural-vblank hang watch | PASS, lockout/VE at cycle `26436581`, 30 frames, final PC `00f104c6` |
| Attract frame bench | PASS, 30 frames, `nonblack=347275`, renderer overruns `0/0`, cache peak `1277` |
| Real SDRAM model attract bench | PASS, 5 frames, `nonblack=47900`, renderer overruns `0/0`, `147136` graphics transactions |

The first attract frame is exactly MAME-matched:

```text
FRAME 0 d3b2fac2 7fdb4700
```

An index-aligned 30-frame comparison currently diverges first at frame 1:
MAME has `IDX=7aa4714d`, while RTL has `IDX=7063ffe9`, which is the stable
MAME frame-2 image. This is the known one-frame presentation phase boundary;
it is not evidence to alter the renderer. A complete attract-loop MAME match,
full 950-frame replay revalidation, and audio waveform equivalence remain open
for the current checkout.

The same frame model with `+REAL_SDRAM` also passed five attract frames. This
exercises the RTL SDRAM controller and the MiSTer 128 MB module model, not a
physical FPGA or the real board's signal integrity.

## Existing physical-RBF evidence

Dyna Gear is not a fresh hardware bring-up. RBF
`a23cbf0622e65e7f467a6f43dcbeb43d1a0a11a2a89cc9f4db0e96d20e9a1c08` was
deployed to MiSTer on 28 July 2026 and was observed to advance through the
title, animated gameplay demo, world map, and a stage with the live HUD. That
RBF still exhibited horizontal tearing/striping, worst near the top of the
frame. The repository records that result at source commit
`5384158aa319676a3c3646be5ebf8411f5746689`. This is a known-good functional
hardware reference, not a claim of pixel-perfect hardware equivalence.

The current checkout is later than that reference and includes the 128 MB
MiSTer SDRAM-module controller retarget. The current `releases/SSV.rbf` is
SHA-256
`F941EE3456F90CB5DCB1847540F1B69F0A2AF3ECBC3738DC8BFB01BDCB086687`.
The next hardware gate is therefore a regression comparison between this
artifact and the known-good RBF, followed by isolating any changed behavior in
the SDRAM/module contract, renderer bandwidth, video timing, or audio path.

The current highest verified automated gate is deterministic real-ROM CPU boot
plus non-black behavioral- and real-SDRAM-model attract soaks and a MAME
frame-0 differential match. Physical validation is established historically
for Dyna Gear, but the current post-retarget RBF still needs a fresh hardware
comparison before it can inherit the prior RBF's functional status.

Private ROMs, writable state, full traces, and frame captures remain local and
are not part of the tracked contract.
