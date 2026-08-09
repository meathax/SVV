# Issue contract: Attract frame CRC vs MAME

> Historical investigation below used CPU increment 21702. The current shared
> profile uses 21701, selected from the PCB's 704:315 CPU-to-pixel clock ratio;
> current release evidence is tracked in `docs/implementation-status.md`.

## Issue

Per-frame RGB/IDX CRC streams are now produced for Dyna Gear attract.

**Current state (re-measured 2026-07-30): 119 of 120 frames match MAME. Frame 1
is the only divergence** — see "2026-07-30 re-measure" below, which supersedes
the older Wave C findings in this file. The sections above that heading are kept
as the record of how the investigation went, but their conclusion that RTL
freezes on a wrong image is no longer true.

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

### 2026-07-30 re-measure: 119 of 120 frames now match

Everything above this heading predates the tilemap-page fix, the renderer
`renderer_busy` gating and the `LINE_SLOTS` raise. Re-measured against the same
committed baseline (`sim_output/diff/mame_attract_idle_frames.crc`, 120 frames,
MAME 0.288) with `tb_ssv_frame_crc` attract_idle, 120 frames / soak 60:

| Frame | MAME IDX/RGB | RTL IDX/RGB | Result |
|---|---|---|---|
| 0 | `d3b2fac2` / `7fdb4700` | same | **PASS** |
| 1 | `7aa4714d` / `839d76aa` | `7063ffe9` / `9ecf2e6e` | DIVERGE |
| 2–119 | `7063ffe9` / `9ecf2e6e` | same | **PASS** |

**120 frames compared, 1 mismatch — frame 1 and only frame 1.**

This supersedes the Wave C table above, which is now wrong in its key claim.
RTL does *not* "freeze on a wrong static and never reach MAME's `7063ffe9`": it
reaches `7063ffe9` / `9ecf2e6e` and holds it for 118 consecutive frames. The
stale RTL value `2419ab87` no longer occurs at all.

What remains is a **one-frame phase difference, not a wrong image**. MAME renders
a single transitional field at frame 1; RTL arrives at the final attract image
one frame earlier. `CACHE_PEAK=1277 of 2048 (frame 1)` in the same run says
frame 1 is the first cached-sprite field, so the likely cause is that the RTL
populates the whole descriptor cache in one vblank while the board builds it
across the frame.

Not yet established, and deliberately not assumed: whether MAME's extra
transitional field is a real rendered field or an artifact of where the capture
arms. **Do not close this by shifting a frame index** — that would make the
comparison pass without explaining the difference, and
`CORE_ISSUE_DIFFTEST_METHOD.md` §6 forbids weakening the comparison.

Reproduce:

    verif/build_frame_crc.sh /tmp/ssv-frame-crc
    /tmp/ssv-frame-crc/tb_ssv_frame_crc +verilator+seed+1 +verilator+rand+reset+2 \
      +SCENARIO=attract_idle +FRAMES=120 +SOAK_FRAMES=60 \
      +FRAME_CRC=/tmp/rtl_attract_120.crc
    python3 tools/compare-ssv-frame-crcs.py \
      sim_output/diff/mame_attract_idle_frames.crc /tmp/rtl_attract_120.crc

(Under WSL Verilator: the committed `.sh` files are CRLF, so `build_frame_crc.sh`
needs a CR-stripped copy run from `verif/`.)

## Required next evidence

0. **Explain frame 1** (now the only residual). Does MAME really render a
   transitional field there, or does its capture arm one field earlier than the
   RTL's? Compare the first post-VE `cache_start` on both sides and count
   rendered fields, rather than comparing CRCs alone.
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
