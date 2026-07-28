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
