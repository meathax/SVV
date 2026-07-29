# Dyna Gear — plan for the drifting bands and distorted audio

Created 29 July 2026, after the SDRAM work closed the simulation gap and then
showed that memory is *not* the constraint.

> **CORRECTION, 29 Jul 2026 — the premise below was wrong.**
>
> This plan was written on the reading that the renderer is compute-bound,
> taken from the testbench's `plotcycles` / `rom_wait` counters. A direct
> state-occupancy histogram says otherwise:
>
> ```
> OBJ_BUDGET busy_cycles=145,101,035  fetches=7,575,611  cycles_per_fetch=19
> OBJ_STATE 34 (FETCH_WAIT)  100,080,898  = 69%
> OBJ_STATE 28-32 (code/attr)  25,185,895  = 17%
> OBJ_STATE 35 (PLOT)           1,087,952  = 0.75%
> ```
>
> Plotting is under 1%. **FETCH_WAIT is 69%** — the renderer is memory-bound,
> and `plotcycles` does not mean what it was read to mean. Each fetch waits
> ~13.2 core cycles against a 9-cycle SDRAM transaction, because every tile row
> costs TWO serial transactions (the packed Q0/Q1 beat, then the Q2 beat).
>
> Consequence for the ranking below: **2.5, the graphics repack, moves from last
> to first** — halving transactions per tile row attacks 69% of the budget
> directly. 2.1 and 2.2 (the code/attr sequence) attack the 17%. 2.4, widening
> the plot path, attacks 0.75% and should be dropped.
>
> Phase 1 also has its first result. With the sample image preloaded, p4 service
> latency is `worst=22 avg=5` clk_ram over 1,234,690 transactions — the sample
> engine is *not* being starved in simulation. Either the audio fault has a
> different cause from the banding, or it depends on hardware conditions the
> harness still does not reproduce. The "one root cause" reading of the two
> symptoms is therefore unproven and should not be assumed.

## The evidence this plan is built on

From `+REAL_SDRAM +DUMP_RENDERER_BUDGET`, on a scanline that missed its
deadline during gameplay:

```
line_cycles=2488  plotcycles=1720 (69%)  rom_wait=127 (5%)  fetch=85  desc=46
```

and, over 250 gameplay frames:

| model | overruns |
|---|---|
| ideal memory (behavioural) | bg 0, obj 0 |
| real controller | bg 452, **obj 22,847** |

Three things follow, and the plan depends on all three:

1. **The object renderer is the problem**, not the background renderer
   (22,847 against 452).
2. **It is compute-bound.** Only 5% of the line is spent waiting for SDRAM.
   The SDRAM open-row fix already took p1 from 12 cycles to 9 and moved
   gameplay overruns hardly at all.
3. **The margin is thin, not enormous.** The same scene fits with ideal memory
   and misses with real memory. We are looking for tens of percent, not an
   order of magnitude.

At ~85 fetches and ~1,720 plot cycles per line, the renderer spends roughly
**20 clk_sys cycles per 16-pixel tile row, of which only 4 are actual
plotting** (four pixels per cycle x four batches). The rest is per-tile
state-machine overhead.

## Success criteria — decide these before touching RTL

- **Primary:** `obj` overruns under `+REAL_SDRAM`, scenario
  `coin_start_p1_gameplay`, 250 frames, falls from 22,847 to **zero**.
- **Secondary:** frame CRCs under `+REAL_SDRAM` become byte-identical to the
  behavioural-model run, as they already are for `attract_idle`. This is the
  real correctness gate: it says the core renders the same picture through real
  memory as through infinite-bandwidth memory.
- **Regression:** behavioural-model CRCs unchanged for every scenario. Every
  existing gate was produced against that model.
- **Hardware:** banding gone or visibly reduced on the same scene, judged
  against a *matched* scene rather than an arbitrary frame. (A mistake already
  made once: comparing a busy scene on one build against a calm scene on
  another proves nothing.)

## Phase 0 — instrument before optimising

No RTL changes. The 20-cycles-per-tile figure is inferred from two aggregate
counters; before spending effort we need to know exactly which states consume
them.

- **0.1 Per-state cycle histogram.** Count clk_sys cycles spent in each
  `ssv_cached_sprite_renderer` state per scanline, dumped for the worst lines.
  This turns "roughly 20 cycles per tile" into a ranked list of what to cut.
- **0.2 Fetch overdraw histogram.** Count distinct `(code, row)` pairs per
  scanline against total fetches. 85 fetches for a 336-pixel line implies
  substantial repetition. If overdraw is high, a small per-line fetch cache
  removes both the memory traffic *and* the per-tile state overhead, which no
  other option does.
- **0.3 Descriptor efficiency.** 46 descriptors produced 85 fetches. Count how
  many descriptors are evaluated and then contribute nothing (off-screen,
  fully transparent). `RENDER_PREP -> RENDER_EVAL -> RENDER_ADVANCE` costs
  cycles even when nothing is drawn.

Deliverable: a table of cycles-per-line by cause. Everything below is
provisional until that table exists.

## Phase 1 — close the audio simulation gap (independent, do it in parallel)

**The ES5506 sample path has never been exercised with real data.**
`verif/tb_ssv_frame_crc.sv` answers every p4 read with `16'd0`, and the
`+REAL_SDRAM` preload loads program and graphics but not samples. So the audio
engine has been fetching silence in every full-core run this project has done,
and no simulation evidence about the reported distortion exists at all.

1. Preload the 4 MB sample image into the chip model at `SDR_SAMPLES_BASE`.
2. Add a p4 service-latency histogram: time from `p4_req` rising to `p4_ack`,
   worst case per frame.
3. Capture the audio output and check for the reported symptom — held or
   repeated samples, which is what "slowed down sounding" means.

Only then is it known whether the audio fault shares the renderer's cause,
shares the memory system's cause, or is a third thing. Right now that link is
inferred from the two symptoms moving together on hardware, which is
suggestive but not evidence.

## Phase 2 — renderer optimisations, ranked by expected return

Each is independently gated by the criteria above. Do not stack them; land and
measure one at a time.

**2.1 Fetch the tile code and attribute in one access.** They are adjacent
16-bit words, and the renderer currently spends
`TILE_CODE_ADDR -> TILE_CODE_WAIT -> TILE_ATTR_ADDR -> TILE_ATTR_WAIT` — four
cycles — reading them one after the other. A 32-bit read halves that.
Expected: ~2 cycles per tile (~10%). Risk: low; changes a RAM port width, and
the CRC gate catches any data error.

**2.2 Prefetch the next tile's descriptor during the current tile's ROM
fetch.** The sprite-RAM reads and the graphics ROM fetch use different memories
and are currently serialised. Overlapping them hides the entire code/attr
latency behind `FETCH_WAIT`. Expected: ~4-5 cycles per tile (~20-25%). Risk:
medium; needs a small pipeline register and careful handling of the
last-tile case.

**2.3 Per-line fetch cache**, if Phase 0.2 shows real overdraw. A small
`(code,row) -> pens` cache would skip both the SDRAM transaction and the
per-tile state sequence on a hit. Expected: proportional to measured overdraw,
potentially the largest single win. Risk: medium; costs M10K/MLAB in a design
already at 96% RAM-block usage, which is the binding constraint.

**2.4 Widen plotting from four pixels per cycle to eight.** Cuts the 4-cycle
`PLOT` batch to 2. Expected: ~2 cycles per tile (~10%). Risk: medium-high;
touches `ssv_line_buffer4` port widths and the shadow/forwarding logic, which
is subtle.

**2.5 Graphics repack — `docs/SDRAM_GFX_REPACK_DESIGN.md`.** One 128-bit p2
fetch per tile row instead of two 64-bit p1 fetches. Now worth *less* than when
it was specified, because it was scoped as a bandwidth fix and bandwidth is 5%
of the line. Its remaining value is removing one fetch round-trip per tile from
the *state machine*. Expected: modest. Risk: high — it changes ROM layout, and
CLAUDE.md names wrong load offsets as a common source of fake bugs. **Do this
last, if at all.**

## Phase 3 — timing and area

The design is at **83% ALMs and 96% RAM blocks**, and closes at 0.098 ns. Any
of 2.3 and 2.4 costs memory or logic in a design with very little of either
left.

- Every candidate must be checked for fit and slack before it is considered
  landed, not after.
- If slack regresses, restructure rather than accept it. Precedent from this
  work: a row comparator placed downstream of an address mux cost 137 ps and
  failed timing; comparing per-port in parallel and muxing one bit recovered
  it and ended up *better* than the baseline.
- Consider a seed sweep (`tools/seed-sweep.ps1`) only for the final build. The
  `.qsf` documents this design as seed-sensitive across roughly +/-0.5 ns, so a
  seed is not a substitute for a real timing fix.

## Verification protocol for each change

```bash
# 1. unit: memory path unaffected
/tmp/ssv-lb/tb_ssv_sdram_loopback                    # PASS + SDRAM_COST

# 2. behavioural regression: no existing gate may move
tb_ssv_frame_crc +SCENARIO=coin_start_p1_gameplay +FRAMES=250 \
  +FRAME_CRC=/tmp/beh.crc                            # must equal previous

# 3. real memory: the actual target
tb_ssv_frame_crc +REAL_SDRAM +SCENARIO=coin_start_p1_gameplay +FRAMES=250 \
  +IGNORE_OVERRUN +FRAME_CRC=/tmp/real.crc           # overruns -> 0
cmp /tmp/beh.crc /tmp/real.crc                       # -> identical

# 4. attract must stay clean
tb_ssv_frame_crc +REAL_SDRAM +SCENARIO=attract_idle +FRAMES=20 ...
```

Then Quartus, then hardware on a matched scene.

## Non-goals

- Do not re-attempt SDRAM arbitration priority. Measured: 10% improvement
  (22,847 -> 20,437) for a starved CPU. The reasoning is recorded in the
  arbiter comment so it is not retried blindly.
- Do not chase refresh. 1.6% of bandwidth.
- Do not modify `sys/`.

## Queued fixes — apply before the next synthesis

Ordering matters. The graphics repack is verified by frame CRCs coming out
**byte-identical** (only the memory layout moves). Fix 1 below legitimately
changes pixels, so bundling it into that run would destroy the only gate that
can prove the repack correct. Land the repack, pass its gate, then apply these.

| # | fix | changes pixels? |
|---|---|---|
| 1 | `ssv_bg_renderer` `screen_x` missing the row-scroll offset (see below) | **yes** — needs its own gate |
| 2 | 4-bit shift wrap in `tile_address()` `base` term, both renderers | no (page is 0 in the affected cases) |
| 3 | dead `act_bank` register in `sdram.sv` | no |

**Fix 2 detail.** `base = page << (size_shift + 2'd2)` — `size_shift` is
`logic [3:0]` and `2'd2` is two bits, so the sum is self-determined to 4 bits
and wraps for `size_shift` 14/15 (`mode[15:13]` 6 or 7), shifting by 0/1 instead
of 16/17. Latent for Dyna Gear because those maps are wider than the screen so
`page` stays 0. Widen the shift amount. Recorded in commit `69403b4` and
deliberately left then because it was not the symptom under investigation.

**Fix 3 detail.** `act_bank` is assigned in `ST_IDLE` and never read. Re-run the
loopback after removing it — `sdram.sv` closes at only +0.098 ns.

## Known open defect, unrelated but real

`ssv_bg_renderer` omits the row-scroll offset from `screen_x`, where MAME uses
`0 - ((tilemap_scrollx + rowscroll) & 0xf)` and the object renderer includes it.
Up to 15 pixels of horizontal misplacement on row-scrolled lines, on a path
that is definitely live (241,635 row-scrolled scanlines per 1500 frames). It
should be fixed on its own evidence, not folded into this work.
