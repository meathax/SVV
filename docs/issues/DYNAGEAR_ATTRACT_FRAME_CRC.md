# Issue contract: Attract frame CRC vs MAME

## Issue

Per-frame RGB/IDX CRC streams are now produced for Dyna Gear attract. The
**first full post-`video_enable` frame matches MAME exactly**. Later frames
diverge (phase / content update skew), so a full attract-loop CRC match is not
yet closed.

## Deterministic scenario

- Set: `dynagear` / `attract_idle`
- Scenario: `verif/scenarios/dynagear/attract_idle.json`
- MAME: 0.288, Lua `tools/mame-capture-ssv-frames.lua` (arms on `$21000E` bit7)
- RTL: `verif/tb_ssv_frame_crc.sv` with `ssv_tb_ce_cpu` (+21702)
- Geometry: 336×240
- Stop: 120 frames after VE (MAME), ≥30 soak frames (RTL)

## Current evidence

| Compare | Result |
|---|---|
| Natural CE, frame 0 | **PASS** IDX=`d3b2fac2` RGB=`7fdb4700` |
| Natural CE, frame ≥1 | DIVERGE (stable CRCs differ) |
| Sample pixels @ frame 30 (130,48…) | RTL RGB bytes match MAME `screen:pixel` |
| Pixel count | 80640 after vb-edge CRC fix (was 80639) |
| G2 soak | PASS (no overrun, no stuck, nonblack) |

### 2026-07-26 close-out re-prove

- Re-ran `tb_ssv_frame_crc` attract_idle (30 frames / soak 15) after Wave B RTL.
- Frame 0 still matches MAME (`d3b2fac2` / `7fdb4700`).
- First mismatch remains **frame 1**: MAME IDX=`7aa4714d` vs RTL=`2419ab87`.
- Residual kept open: IRQ period / CPI skew (~32086 RTL vs ~33230 MAME) — see
  [`DYNAGEAR_NATURAL_IRQ_SKEW.md`](DYNAGEAR_NATURAL_IRQ_SKEW.md). No compositor
  pen fix justified from frame-0 evidence.
- **120-frame gate:** not met; gameplay continue-criteria = frame-0 match + soak.

## Last matching event

Natural: post-VE frame 0 (full active field).

## First divergence

Natural: frame 1 CRC. Pixel spot-checks at later frames can still match local
sprites, but the full-frame CRC does not stay locked for a whole attract loop.

## Root-cause hypothesis

Suspect: remaining vblank/IRQ retirement period skew vs MAME after frame 0
(SDRAM CPI / CE interaction), so game-driven list/scroll updates walk out of
phase even when the compositor itself is painting the correct pens for a given
descriptor snapshot.

Status: `suspect`; evidence tier: `BOUNDARY`.

## Exit gate

Close when `tools/compare-ssv-frame-crcs.py` passes for ≥120 post-VE frames
(or every residual is documented as presentation-only). Until then the
gameplay gate requires **frame 0 match + soak**.
