# Gameplay validation past 950 frames — `coin_start_p1_long`

Branch: `work/v60-opcode-audit`  ·  Worktree: `SVV-v60`

## What was missing

The Dyna Gear sim gate stopped at **950 post-video-enable frames**
(`coin_start_p1_gameplay`), which reaches the first controllable jungle window
and nothing after it. Everything past the first ~16 seconds of play was
unvalidated.

## What was added

`verif/scenarios/dynagear/coin_start_p1_long.json`, with the generator in
`verif/tb_ssv_frame_crc.sv` (`apply_inputs()`, branch
`scenario == "coin_start_p1_long"`).

* Post-VE frames **0–949 are byte-identical** to `coin_start_p1_gameplay`, so
  the existing gate result is unchanged and the two runs are directly
  comparable.
* From frame 950 the schedule is a repeating **240-frame** cycle — hold Right
  for 140 frames, mash B1 on a 12-frame period, jump at two fixed phases, Up /
  Down / Left windows, plus Start every 30 s and a coin every 60 s so a
  respawn or continue prompt is always answered.
* The cycle is a **pure function of the frame index**, so the scenario stays
  deterministic and needs no external input file.

Two supporting changes were required:

* `cycle_count` / `max_cycles` widened from `integer` to `longint`. 32-bit
  `integer` caps `+CYCLES` at 2^31−1, which is only ~2640 post-VE frames at
  ~805k `clk_sys` per frame plus ~26 M of boot — the scenario could not
  otherwise run to completion.
* `verif/build_frame_crc.sh`, which builds the frame-CRC testbench with
  `/usr/bin/verilator` directly. The repo's `run_*.sh` wrappers call a
  `verilator-safe.exe` Windows launcher that stalls under a non-interactive
  nested WSL shell.

## Runs

```
# baseline, to confirm the existing gate still passes in this worktree
tb_ssv_frame_crc +SCENARIO=coin_start_p1_gameplay +FRAMES=950 \
    +SOAK_FRAMES=940 +CYCLES=900000000 +REQUIRE_GAMEPLAY

# the long scenario
tb_ssv_frame_crc +SCENARIO=coin_start_p1_long +FRAMES=3000 \
    +SOAK_FRAMES=2990 +CYCLES=3000000000 +REQUIRE_GAMEPLAY \
    +DUMP_PPM_PREFIX=<dir>/long +DUMP_PPM_START=100 \
    +DUMP_PPM_COUNT=30 +DUMP_PPM_STEP=100

# control: same build, old scenario, run to the same length.  No input after
# frame 920, so the player stands still - isolates "does scrolling matter".
tb_ssv_frame_crc +SCENARIO=coin_start_p1_gameplay +FRAMES=3000 ...
```

Verilator 5.032, `--binary --timing --assert`, single-threaded, ~7.7 ms of
simulated time per wall second.

## Results

**Baseline is unchanged.** The 950-frame gate passes in this worktree:

```
PASS tb_ssv_frame_crc scenario=coin_start_p1_gameplay frames=950
     nonblack=34414974 pc=00f10575 overruns bg=0 obj=0 max_line_entries=86
```

**The control passes 3000 frames.** Same build, old scenario, no input after
frame 920, run to the same length:

```
PASS tb_ssv_frame_crc scenario=coin_start_p1_gameplay frames=3000
     nonblack=188877173 pc=00f10575 overruns bg=0 obj=0 max_line_entries=86
```

So neither run length nor the widened `longint` cycle budget is what breaks —
3000 frames of a *stationary* player is clean.

**The long scenario fails.** It renders all 3000 frames, but trips the
end-of-run renderer check:

```
FIRST_CACHE_OVERFLOW f=2834 state=14 cache=1536 writes=499 bucket_y=201 line_count=96
OVERFLOW_LINE_CONTENT tilemaps=0 sprites=96 groups=0,0,0,0,0,0,0,0
FIRST_CACHE_OVERFLOW f=2835 state=14 cache=1536 writes=543 bucket_y=193 line_count=96
FIRST_CACHE_OVERFLOW f=2836 state=0  cache=1536 writes=1536 bucket_y=7  line_count=37
%Fatal: tb_ssv_frame_crc.sv:881: Assertion failed in tb_ssv_frame_crc:
        renderer_overrun sticky set
LONG_RC=134
```

So there are **two distinct defects**, and they are independent:

| # | Symptom | First seen | Caught by an existing assertion? |
|---|---|---|---|
| 1 | background tile layer corrupts while scrolling | post-VE frame ~1000 | **No — completely silent** |
| 2 | sprite descriptor / line cache overflows | post-VE frame 2834 | Yes, `renderer_overrun` sticky |

Defect 2 is the sprite line cache filling: 1536 entries full with **96 sprites
on a single scanline** (`tilemaps=0 sprites=96`). `bg_overruns` and
`obj_overruns` are both still 0 — it is the cache, not the per-line budget.
That load only occurs deep in real gameplay, which is why 950 frames never
saw it.

Defect 1 is the more concerning of the two **because nothing in the testbench
notices it**. It corrupts the display for ~1800 frames without setting a single
flag. Any future gate needs a check that would catch it.


### Finding: the background layer corrupts once the player scrolls, starting just after the old gate

This is the substantive result, and it lands **exactly in the window the old
950-frame gate could not see**.

Objective measure — percentage of pure-black pixels inside the play area
(x 8–327, y 20–189), sampled every 100 post-VE frames:

| post-VE frame | 800 | 900 | 1000 | 1100 | 1200 | 1300 | 1400 | 1500 | 1600 |
|---|---|---|---|---|---|---|---|---|---|
| long (player moving) | 2.8 | 1.1 | **5.2** | **25.8** | **25.9** | 0.0 | 0.1 | **27.3** | **54.7** |
| control (player still) | 2.8 | 1.1 | 0.8 | 0.8 | 0.8 | 0.7 | 0.7 | 0.8 | 0.7 |
| MAME, same schedule | — | 1.2 | 0.2 | 0.1 | 0.0 | 0.0 | — | — | — |

| post-VE frame | 1700 | 1800 | 1900 | 2000 | 2200 | 2300 | 2500 | 2800 | 2900 |
|---|---|---|---|---|---|---|---|---|---|
| long (player moving) | **5.0** | **41.6** | **31.6** | **5.7** | **14.5** | **35.8** | **3.4** | **43.3** | **50.3** |
| control (player still) | 0.8 | 0.8 | 0.8 | 0.8 | 0.8 | 0.7 | 0.8 | 0.7 | 0.8 |

The two RTL runs are bit-identical through frame 900, as they must be — the
scenarios only differ from frame 950. From frame 1000 the moving run degrades:

* **frame 1000** — a narrow fully-black vertical column through the jungle.
* **frames 1100–1200** — a wide region where the right of the screen is drawn
  at a *different horizontal scroll offset* from the left, black band between.
* **frame 1600** — severe. Multiple black bands, and the background is partly
  filled with **font glyphs** (`↓` arrows, boxed `X`, `ᴜ`, a stray `J`) where
  scenery tiles belong.
* **frame 2900** — worse still, 50.3% of the play area black, with the same
  font-glyph tiles. It never recovers for long: from frame 1000 to the end the
  moving run oscillates between roughly 3% and 55% black, and never returns to
  the ~0.8% baseline the control holds for all 3000 frames.

Throughout, the **player sprite, enemy sprites and the whole HUD render
correctly**, the score advances and the stage timer counts down — so the CPU is
still executing game logic normally. Only the background tile layer is wrong.

Screenshots: `sim_output/mame/rtl_long_f1000.png`, `..._f1100.png`,
`..._f1200.png`, `..._f1300.png`, `..._f1600.png`.

MAME driven with the identical nominal schedule
(`tools/mame-scenario-long.lua`) renders a clean full-screen background at the
same frame indices (`sim_output/mame/mame_long_f1100.png`, `..._f1200.png`).

### How far this is, and is not, proof

**It is a real rendering defect.** A jungle background containing the game's own
*font glyphs* as scenery is not a legitimate state of any game, and the
stationary control run never produces it over the same 3000 frames.

**What it is not is *localised*.** Two explanations remain open and the evidence
here does not separate them:

1. the background renderer fetching wrong tile indices / dropping columns when
   the horizontal scroll advances, or
2. something upstream corrupting tilemap RAM — a bad CPU or DMA write — which
   the renderer then faithfully displays.

The sprite and HUD paths being simultaneously correct argues for a
background-specific fault, but does not rule out a scroll-register or
tilemap-address write going astray.

**One caveat on the MAME comparison.** By frame 1100 the RTL and MAME runs have
diverged in *game state* — score 1020 vs 20, lives ×1 vs ×3 — because an action
game amplifies a one-frame input offset quickly and this scenario has no golden
CRC reference past the early attract window. The MAME frames therefore show that
MAME does not corrupt its background, not that it was at the identical point in
the game. The defect call rests on the font-glyph corruption and the control
run, not on the MAME image comparison.

### Recommended follow-up

0. **Add a black-fraction or frame-difference check to the gate.** Defect 1
   above ran for ~1800 frames without tripping anything. A cheap guard —
   post-VE frames whose play-area black fraction exceeds a threshold while the
   game is in gameplay — would have caught it at frame 1000 instead of never.
1. **Separate the two hypotheses first**, because they lead to different files.
   Dump the tilemap/scroll RAM contents at frame 1600 and compare them with
   MAME's at an equivalent state. If the RAM already contains font tile indices,
   the fault is upstream of `ssv_bg_renderer` and the renderer is innocent.
2. Bisect the onset between frames 900 and 1000 with a fine PPM step
   (`+DUMP_PPM_START=900 +DUMP_PPM_STEP=5`) to pin the exact frame and the
   scroll offset at which the first column goes black.
3. Put the scenario in **lockstep with MAME** using the existing
   `+DIFF_IRQ_SCHEDULE` machinery so the two stay in the same game state and
   frames can be CRC-compared rather than eyeballed.
4. Check `bg_overruns` / `obj_overruns` and the `OBJ_LATE` /
   `OVERFLOW_LINE_CONTENT` diagnostics, which the testbench already emits but
   only flushes at end of run.

This lands in `rtl/` territory, which **stream 1 owns**. Nothing in `rtl/` was
changed here — see `git diff c80d8f8 HEAD -- rtl/ sys/`, which is empty.
