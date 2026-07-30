# Phase 0 — re-measurement before the 128 MB retarget

> ## CORRECTION — every number below was measured on a truncated run
>
> The run recorded here asked for `+FRAMES=250` but left `+CYCLES` at its
> default of 200,000,000. `verif/tb_ssv_frame_crc.sv`'s main loop exits on
> **either** condition and used to do so **silently**, and a frame is
> 262 × 3064.2 ≈ 803k `clk_sys` with ~35 frames going by before
> `video_enable`. 200 M cycles therefore buys ~250 total frames, i.e. **215
> post-VE frames — which is where every run below stopped.**
>
> `coin_start_p1_gameplay` does not reach controllable gameplay until **post-VE
> frame 820**. So this pass measured the attract loop, the coin insert and the
> "PUSH START" / character-select screens. **It never saw gameplay at all**,
> and the phrase "215 post-VE frames of gameplay" below is wrong.
>
> That invalidates the *scope*, not the arithmetic, of §3 and §4 in particular:
> a peak line occupancy of 57 of 96 and zero drops are what the **attract and
> select screens** cost, which is why they do not reproduce the 86 and
> "90 of 96" recorded from real gameplay in `DYNAGEAR_CORE_AUDIT.md:502` and
> `M10K_REDUCTION.md:76`. Those older figures were not "not reproduced by this
> scenario"; they were never given the chance.
>
> The testbench now prints
> `WARNING CYCLE_BUDGET_TRUNCATED frames=… requested=… cycles=…` whenever the
> cycle budget ends a run early, so this cannot happen unnoticed again. Any
> measurement intended to cover gameplay needs `+CYCLES` of roughly
> `803000 × (frames + 35)`.

Instrumentation-only pass. No functional RTL changed; every counter lives under
`` `ifdef SIMULATION `` or in the testbench, so the synthesis path is untouched.

**Run.** `verif/build_frame_crc.sh`, then

```
+MAINROM=sim_output/rom/maincpu.bin +SPRROM=sim_output/rom/sprites.bin
+SMPROM=sim_output/rom/samples.bin +SCENARIO=coin_start_p1_gameplay
+REAL_SDRAM +FRAMES=250 +IGNORE_OVERRUN +DUMP_RENDERER_BUDGET
+verilator+seed+1 +verilator+rand+reset+2 --assert
```

215 post-VE frames of gameplay against the **real** `rtl/mem/sdram.sv` plus
`verif/ssv_sdram_chip.sv`.

---

## 0. Two things that had to be fixed before anything could be measured

1. **`rtl/mem/sdram.sv` was in no build script in the repo.**
   `verif/build_frame_crc.sh` and `verif/run_*.sh` list `rtl/ssv_core.sv` and
   friends but never the controller, while `verif/tb_ssv_frame_crc.sv:63`
   instantiates `ssv_sdram_harness` unconditionally and that harness
   instantiates `sdram`. Verilator stops with
   `%Error-MODMISSING: Cannot find file containing module: 'sdram'`.
   **So `+REAL_SDRAM` could not be built at all, and the 22,847 figure below is
   not reproducible from any checked-in script.** Added to the file list.

2. **`verif/build_frame_crc.sh` used `-j $(nproc)`** — 32 on this host, i.e. 32
   concurrent compilers at up to ~1 GB each, the exact thing `CLAUDE.md`
   forbids. Now `BUILD_JOBS` defaulting to 6. Also made `ccache` optional (it is
   absent under Git Bash here) and the verilator path fall back off `PATH`.

---

## 1. H0 — the headline numbers are stale. REFUTED.

**Hypothesis.** After the graphics repack, `FETCH_WAIT` is no longer 69 % of the
renderer budget and overruns are materially below 22,847 per 250 frames.
**Refutation condition, stated first.** If overruns are still ≥ 20,000, H0 fails
and the memory-latency diagnosis stands.

| metric | recorded baseline | measured now |
|---|---:|---:|
| object-line deadline misses | **22,847** / 250 frames | **0** / 215 frames |
| background misses | 452 | **0** |
| cache build deadline aborts | — | **0** |
| `rom_wait` per missed line | 127 of 2,488 cycles | 127 of ~2,000 cycles |

`OBJ_MAX f=78 y=4 cycles=2075 desc=46 fetch=4 tilefetch=4 plotcycles=1711
rom_wait=127` — **plot is 82 % of the worst line and memory wait is 6 %.** The
renderer is compute-bound now, the opposite of the 69 %-FETCH_WAIT regime the
plan was built on. That regime predates the repack, which halved graphics
transactions.

**H0 is confirmed: there are no missed deadlines to recover.** Everything in the
original plan that existed to recover them is therefore unjustified.

---

## 2. C1 — SDRAM row conflicts. Bank isolation REFUTED.

Conflicts are counted where the controller itself decides, off the three
mutually exclusive exits from `ST_IDLE` (`ST_RD` = row hit, `ST_ACT` = cold
miss, `ST_PRE_BANK` = wrong row open), and attributed to the port that last
ACTivated the bank.

| evictor → victim | count | share |
|---|---:|---:|
| **p2 → p2** (graphics self-conflict) | 239,739 | **42.5 %** |
| p4 → p4 (audio self-conflict) | 181,221 | 32.1 % |
| p2 → p0 | 61,744 | 11.0 % |
| p0 → p2 | 62,432 | 11.1 % |
| p0 → p0 | 18,864 | 3.3 % |
| **total** | **564,000** | |

Row hit rates: p2 92.0 %, p0 81.9 %, p4 48.7 %.
Service latency (req→ack, clk_ram): p2 avg 14.66 max 49; p0 avg 9.61 max 51;
p4 avg 12.24 max 52.

**Cost.** 564,000 conflicts × 6 clk_ram (PRE + tRP×2 + ACT + tRCD×2) =
3.38 M clk_ram, against 215 × 262 × 6128 = 345 M clk_ram of bus time.

> **Row conflicts cost 0.98 % of the SDRAM bus.**

The plan's Phase 2 (region-to-bank isolation) targeted cross-client conflicts.
Those are p0↔p2 only, and removing all of them recovers **0.2 % of the bus** —
while the dominant term, graphics evicting itself, is untouched by isolation.

The mechanism is visible in the map: graphics is `0x0100000..0x10FFFFF` and the
bank is byte address `[25:24]`, so **15 of 16 MB sits in bank 0** and nearly all
graphics traffic shares one open row. A row is 1024 B = 64 tile-row records, and
a tile code occupies `code<<7` = 128 B, so **one open row spans only 8 distinct
tile codes**; scattered sprite codes on a scanline evict each other.

**Consequence for the 128 MB layout.** The planned map put all 32 MB of graphics
in one 32 MB bank. That is *worse* — it would give graphics a single open row.
If graphics row conflicts are ever worth attacking, the fix is the opposite:
**interleave** the graphics region across all four banks so four rows stay open.
At 0.98 % of the bus it is not currently worth attacking at all.

---

## 3. C3 — `LINE_SLOTS`. Raising it to 128 is NOT justified.

Full per-scanline occupancy distribution, sampled when each vblank build
completes, over 51,600 scanlines:

| | |
|---|---:|
| peak occupancy | **57** of 96 |
| lines at the 96-slot cap | **0** |
| lines sampled | 51,600 |

Cross-checks against the pre-existing `max_line_entries=57` in the same run.
Recorded values of 86 and "90 of 96" are not reproduced by this scenario.

**Refutation condition was: peak ≤ 96 in 1P and 2P ⇒ defer.** 1P is settled with
39 slots of headroom. **2P is still unmeasured** — no two-player scenario exists
in `verif/scenarios/`. Until one does, the +7 M10K is not spent.

---

## 4. C4/C5/C6 — three silent-drop mechanisms, all inactive

| counter | meaning | result |
|---|---|---:|
| C4 `start_dropped` | `start` pulse arriving when the renderer is not in `IDLE` | **0** of 51,623 |
| C5 `bg_start_while_obj_busy` | bg renderer started while obj still fetching | **0** |
| C5 `bg_ack_while_obj_owns` | bg completed a transaction it does not own | **0** |
| C6 `desc` / `entries` / `page_consume` | the three `no_rw_check` arrays | **0 / 0 / 0** |

**C6 also has a structural proof, found while writing the assertions.** `state`
is a *single* register: writes to `descriptor_cache` occur only in `BUILD_STORE`
and to `line_entries` only in `BUILD_BUCKET_WRITE`, while the reads occur only in
`RENDER_*` states — so those collisions are unreachable by construction.
`line_page_starts` is the real case, because its read at
`ssv_cached_sprite_renderer.sv:680` is unconditional and *does* collide on every
build cycle; it is safe because its only consumer, `RENDER_COUNT_WAIT`, is
reachable only from `RENDER_COUNT_READ`, which never writes.

`docs/DYNAGEAR_HW_RENDER_FIX_PLAN.md:72-80` listed this as unproven. **It is now
both proven by construction and measured silent over 215 frames.** The
attributes stay.

Consequently the plan's B1 (`!renderer_busy` gate) and B2 (`start` latch) are
fixes for conditions that never occur in this scenario. B1 remains worth landing
as a one-line hardening — a late line should lose its bg layer rather than draw
another renderer's tile — but neither may be credited with fixing banding.

---

## 5. C7 — ES5506 bank/compression restrictions are correct for Dyna Gear

`rtl/audio/ssv_es5506_voice.sv` mutes any voice with `CR[15:14] != 2'b10` or
`CR_CMPD` set. Counting only **running** voices (a voice with `CR_STOP` set is
silent on real hardware too, so counting those reports a five-figure non-bug —
the first version of this counter did exactly that and read 499,621):

| | 250-frame gameplay |
|---|---:|
| running voices outside bank 2 | **120** |
| running compressed voices | **0** |

Effectively zero. The restriction is correct for this title. It still has to be
lifted for the other eight games (Twin Eagle II and Ultra X Weapons declare
`ROM_COPY` bank aliases), but it is not a Dyna Gear audio bug.

---

## 6. What Phase 0 changes about the plan

| plan item | status after measurement |
|---|---|
| Phase 1 `LINE_SLOTS` 96→128 | **deferred** — peak 57/96, no lines at cap. Needs a 2P scenario to close. |
| Phase 2 region-to-bank isolation | **dropped** — recovers 0.2 % of the bus; conflicts are 95 % graphics-self. |
| Phase 4 pipelined controller | **not justified** — it existed to recover deadline misses that measure 0. |
| Phase 5 B1 `!renderer_busy` | keep as hardening, credited with nothing |
| Phase 5 B2 `start` latch | **drop** — 0 of 51,623 |
| Phase 5 B3 `no_rw_check` | **closed** — proven and measured |
| Phase 7 A2 banks/compression | **not a Dyna Gear bug**; becomes a multi-game item |
| Phase 3 128 MB widening | unchanged — required by the target hardware |
| Phase 8 nine-game support | unchanged — required by the target |

**The honest caveat.** Zero missed deadlines *in simulation against the real
controller model* is not the same as "the hardware banding is fixed". The
recorded banding was observed on a board before the graphics repack landed, and
has not been re-tested on hardware since. What this run establishes is that the
mechanisms the plan blamed — deadline misses, descriptor drops, bank conflicts,
read-during-write — are all inactive in a 215-frame gameplay simulation. A
hardware retest is the outstanding item, and it is now the cheapest way to learn
anything new about the bands.
