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
- Residual kept open: IRQ period / CPI skew — see
  [`DYNAGEAR_NATURAL_IRQ_SKEW.md`](DYNAGEAR_NATURAL_IRQ_SKEW.md). No compositor
  pen fix justified from frame-0 evidence.
- **120-frame gate:** not met; gameplay continue-criteria = frame-0 match + soak.

### 2026-07-26 Wave C residual probe

Re-ran `verif/run_wave_c_crc.sh` (LF script; no CRLF fix needed):

| Frame | MAME IDX | RTL IDX | Result |
|---|---|---|---|
| 0 | `d3b2fac2` | `d3b2fac2` | **PASS** (RGB `7fdb4700`) |
| 1 | `7aa4714d` | `2419ab87` | DIVERGE |
| 2–29 | `7063ffe9` (static) | `2419ab87` (static) | both freeze; different image |

MAME: one transitional frame 1, then static attract. RTL: freezes on a wrong
static from frame 1 and never reaches MAME’s `7063ffe9`.

**`+DIFF_IRQ_SCHEDULE` CRC probe (inconclusive for video):** frame 0 still
matches; frame 1 still diverges (`b741c1c9`, animating ≠ natural freeze). The
TB `force dut.vblank_pulse` drives both IRQ **and** `cache_start`, so scheduled
CRC desyncs sprite rebuild from CRT — not a fair compositor gate. Write/hash
schedule PASS elsewhere remains the architectural CPU gate.

**Natural `+DUMP_FRAME_DIAG` (tb plusarg) at vb-edge / `cache_start`:**

| Probe | f0 | f1 | f2 | f3 |
|---|---|---|---|---|
| list512 / spr8k / scroll64 | frozen identical across f0–f3 | | | |
| pal512 | `a877d702` | `252574cc` | `252574cc` | `bf2d6d7c` |
| `cache_count` at vb-edge | `0` | `1277` | `1277` | `1277` |
| IRQ entry period (retire) | first @ `730673` (MAME `731058`, **−385**) | steady **~32760** vs MAME **~33230** | | |

So post-VE, RTL does **not** walk sprite list / scroll out of phase — those
snapshots are bit-stable while frame CRC still changes f0→f1. What does change
is palette RAM and the sprite cache becoming populated (0 → 1277) for frame 1.
Frame 0’s matched field was drawn with an empty sprite cache; frame 1 is the
first cached-sprite field and is already wrong vs MAME.

No tiny synthesizable RTL fix proven — do not speculative-rewrite video.

## Last matching event

Natural: post-VE frame 0 (full active field).

## First divergence

Natural: frame 1 CRC. Pixel spot-checks at later frames can still match local
sprites, but the full-frame CRC does not stay locked for a whole attract loop.

## Root-cause hypothesis

Suspect (updated): **frame-1 is the first post-VE field drawn from a rebuilt
sprite cache + updated palette**, while list/scroll stay constant. Remaining
IRQ/CPI skew (first IRQ −385 retirements; period ~32760 vs ~33230) can still
poison *when* those palette/list fills committed relative to the first
`cache_start` after VE — without further list motion after that point. Prior
“scroll-list walks out of phase every frame” is **not** supported by the
natural FRAMEDIAG snapshots.

Status: `suspect`; evidence tier: `BOUNDARY`.

## Required next evidence

1. MAME vs RTL **palette + list** snapshot at the first post-VE `vblank_pulse`
   (the `cache_start` that builds frame 1) — confirm whether pen RAM or
   descriptors already differ before any frame-1 pixel.
2. TB: retire-schedule IRQ **without** forcing `dut.vblank_pulse` (keep
   `cache_start` on CRT) and re-compare frame CRC.
3. Continue natural CPI/period close-out in
   [`DYNAGEAR_NATURAL_IRQ_SKEW.md`](DYNAGEAR_NATURAL_IRQ_SKEW.md) (~470
   instr/frame residual under `+21702` CE).

## Exit gate

Close when `tools/compare-ssv-frame-crcs.py` passes for ≥120 post-VE frames
(or every residual is documented as presentation-only). Until then the
gameplay gate requires **frame 0 match + soak**.
