# Real-SDRAM full-core bench (Phase 3.1)

Closes the structural verification gap named in
`DYNAGEAR_HW_RENDER_FIX_PLAN.md` §3.1: every full-core testbench drove the core
through a per-port SDRAM stub that acked each of p0/p1/p4/wr independently after
one cycle, so `tb_ssv_frame_crc` reported `overruns bg=0 obj=0` across 950
frames while the board misses scanline deadlines constantly. Two defects
(`bc4b6ab`, `c80d8f8`) shipped to hardware because a deadline miss is their
precondition and no bench could produce one.

`tb_ssv_frame_crc` can now run the core through the **real**
`rtl/mem/sdram.sv` in front of a behavioural SDR SDRAM chip model. Under it,
line-deadline overruns happen on their own, with no `+P1_LATENCY` crutch.

Nothing under `rtl/` was modified.

---

## What was added

| File | Role |
|---|---|
| `verif/sdram_chip_model.sv` | Behavioural 256 Mbit x16 SDR SDRAM: 4 banks x 8192 rows x 512 columns, CL2, BL1, auto-precharge on A10, plus JEDEC protocol checking |
| `verif/tb_ssv_frame_crc.sv` | `+SDRAM_REAL` path, ROM image install, service-latency and per-frame overrun instrumentation, data-path equivalence checker |
| `verif/run_sdram_bench.sh` | Build/run entry point that calls `/usr/bin/verilator` directly |

### Clocking

`clk_sys` is unchanged (10 ns). `clk_ram` is added at 5 ns with rising edges
aligned to `clk_sys` — exactly the `clk_ram = 2 * clk_sys`, synchronous
relationship `rtl/mem/sdram.sv`'s two-cycle ack stretch assumes, and the one
`Arcade-SSV.sv` builds from the PLL.

In stub mode the controller is held in `init` forever, so it issues no
commands and the chip model stays silent.

### Address decode

The controller drives `SDRAM_A[9:0] <= xfer_addr[10:1]` on a column command and
`SDRAM_A[12:0] <= xfer_addr[22:10]` on ACT, so address bit 10 appears both as
column A[9] and as row bit 0. That is only unambiguous on a **512-column**
part, where A[9] is a column don't-care. The model is therefore built as
512 columns and decodes

```
word address [24:1] = { BA[1:0], row A[12:0], col A[8:0] }
```

which is 16 M words = 32 MiB, matching the `[24:1]` port width. The model
prints one informational note the first time A[9] is set on a column command,
because the same controller on a 1024-column part would alias the row.

### ROM image install

Two paths, both using the real `rtl/mem/ssv_rom_loader.sv` mapping:

* **default (backdoor)** — the tb calls `u_loader.stream_byte_address()`
  hierarchically for each stream word and writes the result straight into the
  chip array through a backdoor port. ~45 ms of sim time.
* **`+SDRAM_FULLLOAD`** — drives a real `ioctl_download` stream into
  `ssv_rom_loader`, so all 8.9 M words go through `rtl/mem/sdram.sv` writes.
  ~630 ms of sim time.

Both install `maincpu.bin` + `sprites.bin` + `samples.bin` (the sample ROM only
matters here — the stub returns zero on p4, the real path fetches genuine
sample data and that traffic contends for the same chip).

---

## Evidence

All runs: Verilator 5.032, `/usr/bin/verilator` invoked directly (the repo's
`verilator-safe.exe` launcher stalls under a non-interactive nested WSL shell).

### 1. The two install paths produce the same image

```
+SDRAM_REAL +SDRAM_IMAGE_ONLY +SDRAM_STRICT                  -> fingerprint=ba433aea
+SDRAM_REAL +SDRAM_FULLLOAD +SDRAM_IMAGE_ONLY +SDRAM_STRICT   -> fingerprint=ba433aea
```

Identical, with zero protocol violations on the full-loader run. That covers
`ssv_rom_loader`, the controller write path and the model's address decode in
one shot. Both also pass the same reset-vector signature `Arcade-SSV.sv`
probes before releasing the core (`[0x000000]=0x207a`, `[0x01f3d0]=0x0c7a`).

### 2. The real path returns exactly the bytes the stub returns

`+SDRAM_CHECK_DATA` compares every p0/p1/p4 word against a transcription of the
stub's byte layout. Running it in **stub** mode proves the transcription is
what the golden CRC stream was produced against; running it in **real** mode
then proves the chip model plus loader mapping agree.

| Run (`attract_idle`, 30 frames) | p1 | p0 | p4 |
|---|---:|---:|---:|
| stub + `+SDRAM_CHECK_DATA` | 0 / 4,140,944 bad | 0 / 160,048 bad | n/a |
| real + `+SDRAM_CHECK_DATA` + `+SDRAM_STRICT` | 0 / 1,871,774 bad | 0 / 79,524 bad | 0 / 51,378 bad |

`+SDRAM_STRICT` makes any chip-model protocol violation fatal. The real run
completes with `violations=0`: no column command to a closed bank, no ACT to an
open bank, no refresh with a bank open, no tRCD/tRP/tRC violation, no CL
mismatch, no write-during-read-data bus contention.

### 3. Overruns happen naturally

See "Numbers for the hardware stream" below. No `+P1_LATENCY`.

### 4. Reverting the ack-ownership fix is caught

A scratch copy of `rtl/` at `/tmp/rtl_scratch` with `c80d8f8` reverted
(`.rom_ack(bg_rom_ack)` and `.rom_ack(obj_rom_ack)` changed back to
`.rom_ack(sdr_p1_ack)`), built with `RTL_DIR=/tmp/rtl_scratch`. Identical
scenario, identical plusargs, no `+P1_LATENCY`:

| `+SDRAM_REAL +SCENARIO=coin_start_p1 +FRAMES=120` | `bg_ack_while_obj_owns` | bg overruns | obj overruns |
|---|---:|---:|---:|
| ack fix in place | **0** | 2,844 | 23,948 |
| ack fix reverted | **717,402** | 0 | 28,374 |

The bench aborts on the reverted build. This is the defect that painted large
parts of the level as white cross-hatch boxes on the board; before this stream
it was only reachable with the artificial `+P1_LATENCY=40` starvation crutch.

Note the `bg overruns = 0` in the reverted run: without the fix the background
fetcher completes on the object renderer's ack, so it finishes early and never
misses its own deadline. Overrun counters alone would have made the broken
build look *healthier*. The ownership assertion is the check that matters.

### 5. Default (stub) mode still reproduces the golden

```
+SCENARIO=coin_start_p1_gameplay +FRAMES=950 +SOAK_FRAMES=950
+CYCLES=900000000 +REQUIRE_GAMEPLAY
```

produces a 950-record stream with SHA-256

```
11213dd7bc0c46a698c988a5e8b48c748933bb752b6e7c117eb77ddc3ae0a26d
```

byte-identical (`cmp` clean) to `sim_output/diff/rtl_final96_gameplay_frames.crc`.
Confirmed three times: before the data checker was added, after it, and on the
final source. `PASS ... frames=950 overruns bg=0 obj=0 max_line_entries=86`,
unchanged from `main`.

---

## Numbers for the hardware stream

Measured with the real controller and chip model, `clk_sys` cycles, sampled
only after `video_enable` so boot traffic does not skew them.

Reference run: `+SDRAM_REAL +IGNORE_OVERRUN
+SCENARIO=coin_start_p1_gameplay +FRAMES=950 +SOAK_FRAMES=950
+CYCLES=900000000`. Result: `PASS ... frames=950 nonblack=33,609,713
pc=00f10575 overruns bg=27331 obj=167607 max_line_entries=86`,
`bg_ack_while_obj_owns=0`, chip-model `violations=0`,
`CACHE_BUILD max=44020 cycles (frame 527) deadline_aborts=0`.

Chip traffic over the run: 75,377,511 ACT / 243,558,027 READ / 131,328 WRITE /
2,266,379 REFRESH.

### p1 (GFX fetch) service latency — request rising edge to ack

`clk_sys` cycles, post-video-enable, 56,103,948 p1 transactions.

| | stub | real |
|---|---:|---:|
| mean | 2.00 | **6.76** |
| min | 2 | 4 |
| p50 | 2 | **<=7** |
| p90 | 2 | **<=11** |
| p99 | 2 | **<=15** |
| max | 2 | **21** |

Histogram (4-cycle buckets):

| bucket | count | share |
|---|---:|---:|
| 4–7 | 46,648,146 | 83.1% |
| 8–11 | 8,395,643 | 15.0% |
| 12–15 | 998,542 | 1.78% |
| 16–19 | 28,419 | 0.05% |
| 20–23 | 33,198 | 0.06% |

Split by owner: object renderer 47,543,546 transactions, mean 6.76, max 21;
background renderer 8,560,402, mean 6.74, max 21 — the two clients see the same
service, so arbitration is not favouring either.

The V60 (p0) fares **worse** than the renderer: 8,989,264 transactions,
mean **8.30**, max 21. The round-robin gives p1 its turn every rotation while
p0's single-word reads pay the same full ACT/tRCD/CL2/tRC sequence, so the CPU
is the port that actually loses throughput.

So the renderer's real GFX service time is ~3.4x the mean and ~10x the worst
case the renderer was designed and CRC-locked against.

### Line-deadline overruns per frame

| | stub | real |
|---|---:|---:|
| frames with any overrun | 0 / 950 | **864 / 950** |
| bg total | 0 | 27,331 |
| bg mean / median / p90 / max per frame | 0 | **28.8 / 33 / 39 / 46** |
| obj total | 0 | 167,607 |
| obj mean / median / p90 / max per frame | 0 | **176.4 / 199 / 205 / 219** |

The frame has 240 active display lines, so on a typical frame the object
renderer misses its deadline on roughly **83% of scanlines** (199/240) and the
background renderer on ~14% (33/240). 86 of 950 frames have no object overrun
at all and 111 have no background overrun — those are the vblank-heavy /
sparse-scene frames.

`+SDRAM_STATS=path` writes the per-frame CSV
(`frame,bg_overruns,obj_overruns,p1_lat_max,obj_max_line_cycles`) these came
from.

### `+SDRAM_REAL` is deterministic and can be baselined

Two independent 950-frame real-SDRAM runs (different builds, hours apart)
produced byte-identical CRC streams,
SHA-256 `0a44010a0f797691a05886f977333551fa55bc213cb220afa1bdea24914744fb`, and
identical latency/overrun statistics. So the real-SDRAM mode is a valid
regression baseline in its own right, separate from the stub golden. Local
copies (gitignored, `sim_output/` is not tracked):

* `sim_output/diff/rtl_sdramreal_gameplay_frames.crc`
* `sim_output/diff/rtl_sdramreal_perframe.csv`

### CRC divergence under `+SDRAM_REAL`

Frame 0 is CRC-identical to the stub run (`idx=d3b2fac2 rgb=7fdb4700`); frame 1
onward diverges, as the brief predicted — the CPU runs at a different rate
relative to the raster once real memory latency is in the loop. The real-mode
stream is not comparable to the golden and must not be used to re-baseline it.

---

## Reproducing

```bash
# Build (RTL_DIR=<dir> to build against a scratch copy of rtl/)
bash verif/run_sdram_bench.sh build

# Default stub path — must still reproduce the golden CRC stream
bash verif/run_sdram_bench.sh stub \
  +SCENARIO=coin_start_p1_gameplay +FRAMES=950 +SOAK_FRAMES=950 \
  +CYCLES=900000000 +REQUIRE_GAMEPLAY +FRAME_CRC=/tmp/stub950.crc
cmp /tmp/stub950.crc sim_output/diff/rtl_final96_gameplay_frames.crc

# Real controller + chip model
bash verif/run_sdram_bench.sh real +IGNORE_OVERRUN \
  +SCENARIO=coin_start_p1_gameplay +FRAMES=950 +SOAK_FRAMES=950 \
  +CYCLES=900000000 +FRAME_CRC=/tmp/real950.crc \
  +SDRAM_STATS=/tmp/real_perframe.csv

# Model self-checks
bash verif/run_sdram_bench.sh real +SDRAM_IMAGE_ONLY +SDRAM_STRICT
bash verif/run_sdram_bench.sh real +SDRAM_FULLLOAD +SDRAM_IMAGE_ONLY +SDRAM_STRICT
bash verif/run_sdram_bench.sh real +SDRAM_CHECK_DATA +SDRAM_STRICT +IGNORE_OVERRUN \
  +SCENARIO=attract_idle +FRAMES=30 +SOAK_FRAMES=15 +CYCLES=60000000
```

Write CRC streams to `/tmp`; writes to `/mnt/d` can truncate.

`tb_ssv_frame_crc` defaults to `+CYCLES=200000000`, which only reaches ~216
post-VE frames; a 950-frame soak needs about `+CYCLES=900000000`.

---

## Plusargs added

| Plusarg | Effect |
|---|---|
| `+SDRAM_REAL` | route p0/p1/p4/wr through `rtl/mem/sdram.sv` + the chip model |
| `+SDRAM_FULLLOAD` | install the ROM image by driving `ssv_rom_loader` for real |
| `+SDRAM_IMAGE_ONLY` | install + fingerprint the image, then stop |
| `+SDRAM_STRICT` | make chip-model protocol violations fatal |
| `+SDRAM_CHECK_DATA` | assert every p0/p1/p4 word equals the stub's byte layout |
| `+SDRAM_STATS=path` | per-frame overrun/latency CSV |
| `+SMPROM=path` | sample ROM image (default `sim_output/rom/samples.bin`) |

The default path is unchanged. `+SDRAM_REAL` legitimately produces a different
frame CRC stream — the CPU runs at a different rate relative to the raster, so
game state diverges from frame 1. Judge that mode on the assertions
(`bg_ack_while_obj_owns`, chip-model violations, data check, non-black pixel
count) and on overrun counts, not on CRC equality.

---

## Observations for Stream 1 (RTL owner) — not fixed here

1. **`ref_cnt` triggers at 700 `clk_ram`, and the first post-init interval is
   ~1212.** 8192 rows / 64 ms at 96.65 MHz is 755 cycles, so steady state at
   700 has margin. The one long gap comes from `ref_cnt` starting at the end of
   the init countdown, ~512 cycles after the last of the 8 init refreshes.
   Harmless (nothing is refreshed late; it is one 12.5 us gap after a burst of
   8 refreshes), but the chip model flags it unless suppressed, and it is worth
   knowing about. The model now skips the first interval after MRS.

2. **Address bit 10 is used as both column A[9] and row bit 0.** Correct on a
   512-column part, which is what MiSTer's 32 MB module is. It would silently
   alias on a 1024-column part. Worth a comment in `sdram.sv` so nobody
   "fixes" the row field later.

3. **Overrun counters alone cannot detect the ack-ownership bug** — reverting
   the fix *lowered* `bg_overruns` to zero (see §4 above). Any future gate on
   this class of defect must keep the `bg_ack_while_obj_owns` ownership
   assertion, not just the overrun counts.

4. **`renderer_line_start` is still not gated on `renderer_busy`.** With the
   real controller a line that misses its deadline now genuinely restarts a
   still-busy renderer on essentially every frame. The ack fix makes that safe
   with respect to *data* ownership, but the renderer state machines are still
   being restarted mid-transaction at that rate; whether the resulting output
   is what the hardware should show is a separate question this bench can now
   at least measure.

---

# Follow-up: where the bus time and the scanline budget actually go

Measured with `+SDRAM_REAL`, `coin_start_p1_gameplay`, 950 frames
(949-frame whole-frame occupancy window, 1,523,751,175 `clk_ram` cycles).
Every `clk_ram` cycle of the controller is attributed to exactly one bucket, so
the shares below sum to 100%.

## 1. Bus occupancy split — the bus is NOT saturated

| bucket | clk_ram cycles | share | txn/frame | clk_ram per txn |
|---|---:|---:|---:|---:|
| **p1 GFX fetch** | 673,126,416 | **44.18%** | 59,108 | 12.00 |
| **p4 ES5506 samples** | 90,959,985 | **5.97%** | 10,650 | 9.00 |
| **p0 V60** | 80,856,756 | **5.31%** | 9,467 | 9.00 |
| refresh | 19,563,138 | 1.28% | 2,388 | — |
| arbitration turnaround (`ST_IDLE` with work pending) | 77,358,299 | 5.08% | — | — |
| **truly idle (nothing pending)** | 581,886,581 | **38.19%** | — | — |
| core writes | 0 in window | 0% | 0 | — |

Total busy **61.81%**; data ports alone **55.45%**.

Two things follow immediately:

* **Bandwidth is not the binding constraint.** The chip is doing nothing at all
  38% of the time while 84% of scanlines miss their deadline.
* **All 131,328 core SDRAM writes happen during boot.** There is no write
  traffic at all in the post-video-enable window, so the write port is not a
  factor.

## 2. Arbitration is already almost free — do NOT raise p1 priority

A p1 4-word burst occupies the bus for exactly **12 `clk_ram` = 6.00 `clk_sys`**
(measured, `cycles_per_txn`). Measured p1 *service latency* is
**6.76 `clk_sys` = 13.5 `clk_ram`** mean.

> Queueing adds **1.5 `clk_ram` (0.76 `clk_sys`) on average**. p1 is already
> within 13% of the hardware floor.

Perfect arbitration — p1 always granted instantly — could recover at most
`0.76 x 250.9 = 191 clk_sys` per scanline out of a **1,315-cycle** overrun.
It cannot fix the renderer, and it would push p0 (already the slowest port at
8.30 mean) further out. **Recommendation: drop this option.**

## 3. Per-line-period anatomy — where the 3,063 cycles go

The scanline budget is **3,063.2 `clk_sys`** between `line_buffer_start`
pulses (measured, min 3,064). `ssv_core` chains the renderers — bg gets
`renderer_line_start`, and the sprite renderer's `start` input is `bg_done` —
so the two passes are serial within a line.

| per line period | on-time (35,376) | **late (192,624 = 84.4%)** |
|---|---:|---:|
| period length | 3,063.2 | 3,063.2 |
| bg busy | 560.1 | 1,839.9 |
| obj busy | 2,167.8 | 2,538.1 |
| **renderer busy (bg+obj)** | 2,728.0 | **4,378.0** |
| p1 round-trip stall | 1,661.5 | 1,952.9 |
| p1 transactions | 219.0 | 250.9 |
| stall share of busy time | 60.9% | **44.6%** |

(bg and obj busy can overlap when a period runs long, so their sum is renderer
work, not wall time.)

**A late line needs 4,378 renderer cycles and has 3,063 — it is 43% over
budget, and 1,953 of those cycles are pure SDRAM round trip.**

Both fetchers are single-outstanding (they sit in `WAIT_ACK`), so the renderer
spends ~45% of its busy time stalled while the bus is 38% idle. That is the
whole story: **the constraint is transaction count x round-trip latency, not
bandwidth and not contention.**

`OBJ_LINE_COMPLETION reached_done=200,561 ended_without_done=0` — every object
pass does finish, it just finishes after the deadline. Nothing is being
truncated.

## 4. Distribution shape — most lines, not a few pathological ones

`LINE_PERIOD_BUSY_HIST`, renderer-busy cycles per line period:

| renderer busy | on-time | late |
|---|---:|---:|
| 2,560–2,943 (under budget) | 28,977 | 0 |
| 2,944–3,071 (marginal) | 5,317 | 26,246 |
| 3,072–4,095 | 143 | 55,309 |
| 4,096–5,119 | 90 | 52,286 |
| 5,120–6,143 | 134 | 58,783 |

Only **13.6%** of late lines are marginal (the 2,944–3,071 bucket). The other
86% are spread broadly from 3,072 to 6,143 — up to **2x the budget**.

Late lines carry only **15% more p1 transactions** than on-time ones
(250.9 vs 219.0), and the per-line maximum (281) is barely above the mean.
p1 transactions per frame are **59,057 mean, 64,874 max**, and the dense jungle
window (frames 820–919) is actually *lighter* than attract at 56,991.

> This is not a dense-scene outlier problem. The load is nearly uniform and
> structurally above budget. Anything that removes outliers (per-line caps,
> descriptor limits) will barely move it; only a proportional cut to
> transactions or to round trips will.

## 5. Verdict on the two candidate fixes

### icache fill to p5: worth doing, but for the CPU, not the renderer

p0 is **5.31%** of bus time, 9,467 transactions/frame at 9 `clk_ram` each.
Folding each 4-read icache line fill into one 4-word p5 burst:

* bus time: 9,467 x 9 = 85,203 -> ~2,367 x 14 = 33,138 `clk_ram`/frame.
  Bus share **5.31% -> ~2.1%**. Real, but the bus already has 38% idle.
* CPU: an icache line fill goes from **4 serial round trips
  (4 x 8.30 = 33.2 `clk_sys`)** to **one (~9 `clk_sys`)** — a **~3.7x cut in
  icache miss cost** — and it removes ~7,100 arbitration entries per frame,
  which slightly lowers everyone's queueing.

**Cheap, low-risk, clearly positive — but it will not fix the scanline
overruns.** Budget it as a CPU-throughput fix.

### GFX fetch to p2: the only one of the two that moves the renderer

p1 is **44.18%** of bus and **250.9 transactions per line period**. An 8-word
p2 burst costs 16 `clk_ram` (12 + 4 extra READ cycles) = 8.0 `clk_sys`, plus
the same ~1.5 `clk_ram` queueing, so ~8.75 `clk_sys` served.

* transactions per line: 250.9 -> ~125.5
* round-trip stall per line: 250.9 x 6.76 = 1,696 -> 125.5 x 8.75 = 1,098,
  saving **~600 `clk_sys` per line**
* p1/p2 bus share: 44.18% -> **~29%**
* late-line renderer busy: 4,378 -> **~3,778** against a 3,063 budget

**It closes roughly 46% of the 1,315-cycle overrun. It does not close all of
it.** It is the right call only if you accept that a second change is still
needed afterwards.

### A third option the data points at (observation, not a recommendation)

The renderer stalls 45% of its busy time while the bus idles 38%, purely
because each fetcher keeps **one** transaction outstanding. Letting the GFX
fetcher issue the next address while it consumes the current word — two
outstanding requests — would hide most of a 6.76-cycle round trip with **no ROM
layout change and no arbitration change**, and it composes with the p2 change
rather than competing with it. Rough ceiling: it could recover most of the
1,953-cycle stall on a late line, which is more than the entire 1,315-cycle
overrun.

Caveat, and it is the same trap as before: a second outstanding request makes
the bg/obj ack steering harder, not easier — two in flight across an ownership
change is exactly the shape of `c80d8f8`. The `bg_ack_while_obj_owns`
assertion becomes more load-bearing, not less, if you go this way.

## 6. Also worth knowing

* **p4 (ES5506) is a bigger bus consumer than the CPU** — 5.97% vs 5.31%,
  10,650 single-word sample reads per frame. Not on the critical path while the
  bus has 38% idle, but it is the second-largest client and it is all
  single-word traffic.
* **Refresh is negligible** at 1.28%.
* **Arbitration turnaround** (`ST_IDLE` cycles with a request already pending)
  is 5.08% — one wasted cycle per transaction hand-off, by construction of the
  registered `ST_IDLE -> ST_ACT` arbitration. Removing it would recover ~1
  `clk_ram` in 13.5 of p1 latency: same order as the priority change, same
  verdict.

## 7. New plusarg output

`report_bus_occupancy()` and `report_line_periods()` run at the end of every
`+SDRAM_REAL` run. Lines emitted: `BUS_WINDOW`, `BUS_PORT`, `BUS_IDLE`,
`BUS_UTILISATION`, `LINE_BUDGET`, `OBJ_LINE_*`, `BG_LINE`, `RENDER_CHAIN`,
`P1_TXN_TOTAL`, `LINE_PERIOD`, `LINE_PERIOD_STALL_SHARE`,
`LINE_PERIOD_BUSY_HIST`. The `+SDRAM_STATS=path` CSV gained a `p1_txn` column
(p1 transactions in that frame).
