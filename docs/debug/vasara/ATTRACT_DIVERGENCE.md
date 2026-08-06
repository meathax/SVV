# Vasara (1) attract-mode divergence — investigation journal

Scope: `mister-mame-diff` on `vasara` (Vasara 1), attract mode
(`attract_idle` scenario), continuing the `/goal` sequence after `vasara2`
(see `docs/debug/vasara2/ATTRACT_DIVERGENCE.md` and
`GAMEPLAY_AND_SOUND.md`).

## Baseline reproduction (2026-08-05)

Prior evidence (`sim_output/lockstep/vasara-current-120-20260802/`,
2026-08-02) predates the same 2026-08-03 RTL changes noted in the vasara2
journal, so it was re-run fresh rather than trusted as-is.

```
tools/run_ssv_lockstep.ps1 -Set vasara -Frames 120 -Scenario attract_idle -FreezeOn never -TimeoutSeconds 300 -Session sim_output\lockstep\vasara1-attract120-rebase
tools/run_ssv_lockstep.ps1 -Set vasara -Frames 360 -Scenario attract_idle -FreezeOn never -TimeoutSeconds 600 -Session sim_output\lockstep\vasara1-attract360-full
```

Unlike vasara2's runs, this preflight had CPU bus tracing available
(`coverage.cpu_bus: "compared"`, though only for frame 1 —
`trace_frames_compared: 1`). The one trace divergence found there is the
same benign artifact as vasara2's: a watchdog kick at `$210000` (device 6,
`ryorioh_map`/`ssv.cpp:602`) that fires one extra time in RTL's trace window
relative to where reference's frame-1 trace capture ends — not a real
divergence.

## Root cause: same as vasara2

`FIRST_STATE_DIVERGENCE` at **frame 22**: `list512_crc`/`spr8k_crc` show the
exact same two CRC values seen in vasara2's frame-8 divergence
(`2341613344`/`2606955932` "idle" ↔ `4021661486`/`2874462854` "populated"),
with reference already at the "populated" value and RTL still at "idle" —
RTL lagging reference, same direction as vasara2. `scroll63_crc` also
differs here (reference `181691683` vs RTL's constant `2221412293`) — a
scroll-register update vasara2's equivalent frame did not yet show, but the
same class of "reference has moved on, RTL hasn't caught up yet" symptom.

This is the same shared V60 CPU-throughput root cause documented in
`docs/debug/vasara2/ATTRACT_DIVERGENCE.md` — Vasara and Vasara 2 are by the
same developer (Visco) and boot through near-identical early program
addresses (`~$00f001xx`/`~$00effxxx`), consistent with shared boot/attract
setup code. The deep RTL investigation (loop-cache behavior, per-instruction
FSM cost, missing V60 AC timing evidence) done for vasara2 was **not
repeated** here — the same conclusion applies: no narrow, evidence-backed
fix is available, only a core-wide, currently-unverifiable CPU-timing
question. See the vasara2 journal for the full trace/analysis.

## Full 360-frame trajectory — materially better than vasara2

This is the important difference from vasara2. Despite the same underlying
state-timing lag, **the visible impact stays small**:

- Only **3 of 360 frames** (116, 117, 118) show any pixel difference at
  all — everything before frame 116 and everything from frame 119 through
  360 is pixel-exact.
- Worst frame: 116, `exact_ratio` 0.9845 (1,252/80,640 differing pixels,
  bbox `[150,56,173,185]`) — essentially the same small logo-area glitch
  vasara2 showed, not a full-screen event, and it does **not** recur or
  grow later in the run.
- Average `exact_ratio` across all 360 frames: **99.987%**.
- By contrast, **294 of 360 frames have a state (sprite-list CRC)
  mismatch** — more state-drift frames than vasara2 had (80/360), yet far
  fewer of them become visible. The CPU-timing lag is still there
  underneath, it just doesn't translate into a compounding on-screen
  difference the way it did for vasara2 (which reached 47.6% differing
  pixels by frame 357).

Plausible explanation (not verified): vasara2's version of this
attract-setup routine happens to touch a sprite that's on-screen and
animating through the compared window, so the state lag becomes visible and
compounds as later transitions keep landing later and later. Vasara 1's
equivalent state changes evidently affect sprite-list entries that are
off-screen, static, or otherwise not rendered-visible for most of the
window, so the same underlying lag stays invisible.

## Assessment

Vasara 1 attract mode is **already about as close to MAME as this core
gets** given the known, unresolved CPU-timing question: 357/360 frames
pixel-exact, worst case a modest 1.55% difference confined to three frames,
no compounding. No further action taken here — the remaining gap has the
identical root cause and identical missing-evidence blocker already
documented for vasara2, and forcing a fix without real V60 AC timing data
carries the same cross-title regression risk noted there.
