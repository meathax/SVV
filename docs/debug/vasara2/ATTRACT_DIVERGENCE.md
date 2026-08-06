# Vasara 2 attract-mode divergence — investigation journal

Scope: `mister-mame-diff` differential loop on `vasara2`, attract mode
(`attract_idle` scenario), goal per `/goal`: get attract as close to MAME as
possible, then gameplay + sound, then repeat for `vasara`.

## Baseline reproduction (2026-08-05)

Reran the lockstep comparison fresh (RTL rebuilt from current `main`,
commit `83ef919`) since the last recorded evidence
(`sim_output/lockstep/vasara2-attract120-20260802/`, 2026-08-02) predates
RTL changes landed 2026-08-03 (`rtl/video/ssv_palette_ram.sv`,
`ssv_line_buffer4.sv`, `ssv_bg_renderer.sv`, `rtl/ssv_core.sv`,
`rtl/cpu/v60/s32_v60.sv`).

Command:
```
tools/run_ssv_lockstep.ps1 -Set vasara2 -Frames 120 -Scenario attract_idle -FreezeOn pixel -TimeoutSeconds 300 -Session sim_output\lockstep\vasara2-attract120-rebase
```

Result: **identical** to the 2026-08-02 baseline — the Aug 3 changes did not
move this divergence at all.
- First state divergence: frame 8 (`list512_crc`/`spr8k_crc` mismatch; palette
  and scroll CRCs match).
- First pixel divergence: frame 55, bbox `[148,56,174,185]`, 1,375/80,640
  differing pixels (98.29% exact, 99.22% exact-channel ratio).
- `FIRST_CAUSAL_DIVERGENCE` (frame 7, watchdog write at `$210000`) is a
  tooling artifact, not a real divergence — RTL bus tracing wasn't enabled in
  this run (`coverage.cpu_bus: "missing_evidence"`); the watchdog kick itself
  is benign (`ssv.cpp:602`, `ryorioh_map`).

## Root cause chain

1. **Frame-55 pixel diff ← stale sprite-list entry.** `list512_crc`/`spr8k_crc`
   hash SSV sprite RAM (`$100000`, first 512/8192 words). Reference and RTL
   both eventually visit the *same* sequence of sprite-list CRC values
   (`2341613344 → 4021661486 → 544922745 → 1921285163 → 2158543294 → …`), but
   RTL reaches each one several frames later than reference:

   | transition | reference frame | RTL frame | lag |
   |---|---|---|---|
   | idle → populated | 8 | 13 | 5 |
   | next state | 16/17 | 19/20/21 | 3-4 |
   | next state | 25 | 29 | 4 |
   | next state | 52 | *not reached by frame 55* | ≥4 |

   RTL is not stuck or broken — it performs the identical state sequence,
   just later. By frame 55 the animating attract logo has a stale sprite
   entry on the RTL side because RTL hasn't caught up to the reference's
   frame-52 transition yet. This is what the frame-55 pixel bbox is.

2. **Frame lag ← CPU throughput deficit in the idle-poll loop.** Reference
   `R0` (a per-frame accumulator/timer visible in the reference state dump)
   increments by **~8860/frame** during the idle wait (frames 1-6); RTL's R0
   increments by only **~5290/frame** over the same wall-clock frames — RTL
   runs this loop at **~60% of reference's rate**. The ratio (8860/5290 ≈
   1.67) is consistent with the observed lag (13/8 ≈ 1.625, 29/25 = 1.16 once
   partially caught up — lag isn't perfectly constant but the direction and
   rough magnitude match). `cpu_activity_count` (a raw ce_cpu-gated
   retirement-state counter, `verif/tb_ssv_frame_crc.sv:1063`) roughly
   doubles per-frame right when R0 jumps into the sprite-populate routine
   (frame 11→12: 19,839 → 28,358 → 37,174 → ~41,975), confirming the CPU is
   genuinely busy doing real work in this window, not stalled/deadlocked.

3. **Throughput deficit ← per-instruction fetch cost in the idle loop.**
   Added a temporary retirement-cadence trace (`+CPU_LOOP_TRACE`, gated
   behind existing `+VISUAL_DIAG`, see `verif/tb_ssv_frame_crc.sv` next to
   `BOOT_TRACE`) to catch the actual idle loop. It spans roughly
   `$00f00192`-`$00f001f0` (~94 bytes — bigger than the CPU's 24-byte fetch
   window, `fb_valid`/`fb`, `rtl/cpu/v60/s32_v60.sv:174-181`). Steady-state
   (deep into frame 0, long past any cold-cache warmup) per-instruction cost
   is **15-58 `clk_sys` cycles**. `clk_sys` = 48.317307 MHz; `ce_cpu` (the
   V60's own clock enable, `verif/ssv_tb_ce_cpu.sv` /
   `ssv_pkg::SSV_CPU_INC=21701/65536`) averages **~16.00 MHz**, i.e. one
   `ce_cpu` pulse per ~3.02 `clk_sys` cycles. Normalized: **~1-19 V60 cycles
   per instruction** in this loop, which is not obviously wrong for V60 CISC
   instructions on its own — but the loop's 94-byte span versus a 24-byte
   fetch window means the front end likely re-bases/refills on most loop
   passes (see `s32_v60.sv:750-799` — `fb_base != pc` triggers a window
   shift/rebase whenever decode has moved outside the current window), adding
   fetch overhead on *every* iteration rather than only on the branch.

## Full 360-frame attract-gate trajectory (2026-08-05)

Ran the complete `core-debug.toml` attract-gate window (360 post-video-enable
frames) to see whether the frame-55 mismatch stays small or compounds:

```
tools/run_ssv_lockstep.ps1 -Set vasara2 -Frames 360 -Scenario attract_idle -FreezeOn never -TimeoutSeconds 600 -Session sim_output\lockstep\vasara2-attract360-full
```

Result: **it compounds substantially**. `completion.json`: 360/360 frames
compared, no renderer overrun, but `all_pixels_equal:false` and
`all_states_equal:false`.

- 122/360 frames have at least one differing pixel; 80/360 frames have a
  state (sprite-list CRC) mismatch.
- Average `exact_ratio` across all 360 frames: 98.89% — looks fine as an
  average, but the *trend* is what matters.
- Worst frame is **357**, not 55: `exact_ratio` 0.5244 (only 52.4% of pixels
  match), bbox `[80,0,255,239]` — nearly the *entire visible frame*, not a
  small logo-corner glitch. Frames 356-360 are all in the 52-62%
  exact-pixel range.
- This is the accumulating CPU-throughput lag compounding over time, exactly
  as the frame-8→13→19→29→(never-by-55) sprite-list-transition pattern
  predicted: by frame 357 RTL and reference are showing visibly different
  points in the same attract sequence, not just a one-off stale sprite.

This raises the stakes on the root cause materially — it is not a cosmetic
one-frame nit, it is the dominant, worsening reason vasara2 attract mode
does not track MAME. Fixing it requires resolving the CPU-throughput root
cause below, not a local sprite/video fix.

## Open question — genuinely blocked

Whether the measured per-instruction cost is **correct** (real V60 hardware
has its own finite prefetch queue and would also reload on a loop bigger than
that queue) or a **fixable RTL inefficiency** cannot be settled with evidence
currently available:

- `docs/hardware/SSV_SILICON.md` already flags this exact gap: *"Still
  missing: hardware AC timing (clocks per bus cycle, wait states)."* The one
  primary source on file (NEC V60 Programmer's Reference Manual,
  archive.org `NEC_V60pgmRef`) does not include instruction-timing tables in
  the sections fetched this session — timing appendices are apparently not
  part of the archived Programmer's Reference at all (a separate Hardware/
  User's Manual would normally carry AC timing).
- `verif/v60/BASELINE.md` (2026-07-23, pre-`FAST_IFETCH`) already documents
  this exact class of problem (`S_FILLW=40%, S_FILL=16%` — the fetch state
  machine, not exec, dominates cycle count) as a known, actively-worked,
  cross-cutting issue, not specific to vasara2. `FAST_IFETCH` (commit
  `9c4b7c7`, 2026-07-26) landed a wide-fetch ROM icache since that baseline,
  and a later change removed `S_FILLW` from the reachable states (comment at
  `s32_v60.sv:803`), but no post-change CPI re-measurement was ever recorded,
  and the residual throughput gap measured here shows real, unresolved cost
  remains.
- MAME's own V60 timing is *also* explicitly an approximation
  (`verif/v60/BASELINE.md`: "MAME reference ... MAME = flat 8 cyc/instr"),
  so matching MAME exactly would not by itself prove hardware accuracy —
  per project doctrine (`CLAUDE.md`: "Do not copy a known MAME bug or
  software-only implementation detail into RTL"), closing this gap by
  blindly speeding up RTL to match MAME's flat model without real-hardware
  timing evidence would be exactly the kind of unproven fix the differential
  loop is supposed to reject.

**No RTL change has been made against this root cause.** Per project rules
("No speculative functional RTL changes to 'see if they help'"), that fix is
deferred until real V60 AC timing evidence (or a narrower, structurally-clear
RTL inefficiency, e.g. confirming the fetch-window-rebase-on-loop theory with
a cycle trace of `fb_base`/`fb_valid` directly) is available.

## Attempted RTL investigation (2026-08-05, user-authorized best-effort)

User authorized a best-effort, risk-accepted RTL timing change. Before making
one, extended `+CPU_LOOP_TRACE` to dump the full per-cycle FSM state
(`st`, `fb_base`, `fb_valid`, `pf_suppress`, `pf_busy`) rather than just
retirement cadence, and captured a clean run of the exact idle loop
(`$00f00192`-`$00f001ca`-`$00f001f0`, 14 instructions, backward branch
`$00f001f0`→`$00f00192`), starting the trace at `cycle=240400` (well past any
cold-boot warmup).

**Findings that refute the leading hypothesis:**
- `pf_suppress=1` and `pf_busy=0` for the *entire* captured window — the
  single-slot loop-cache (`fb_prev`/`fb_prev_base`/`fb_prev_valid`,
  `s32_v60.sv:182-184`) is being hit on every single backward branch, with
  zero SDRAM/icache-miss latency. My initial theory — that a loop bigger
  than the 24-byte fetch window would evict the single-slot loop-cache
  before the closing branch could use it — is **wrong**: the snapshot guard
  (`fb_prev_valid == 0`, `s32_v60.sv:762`) means the *first* window of a
  forward streak is captured once and kept for the whole streak, not
  overwritten on each subsequent in-window shift. This is confirmed
  structurally in the trace: `$00f001ee→$00f00192` (the loop-closing branch)
  costs only ~6 clk_sys cycles, not a full re-fetch.
- No fetch-side stall of any kind was observed in this loop: `pf_busy` never
  goes high long enough to explain the measured per-instruction cost, and no
  cold-rebase (`fb_valid<=0`/full reload) fires after the initial warmup.

**What the cost actually is:** one full 14-instruction loop iteration takes
607 `clk_sys` cycles (~202 `ce_cpu`/V60 cycles), i.e. **~14.4 V60 cycles per
instruction average**. Per-instruction, the FSM legitimately visits multiple
states — `S_FILL`(window management) → `S_DECODE` → `S_IF2` →
`S_EA_MODE`↔`S_EA_DONE` (visited **twice** per instruction, consistent with a
2-operand instruction such as a memory-operand `CMP` needing EA resolution
on each operand) → `S_EXEC` → `S_WB_MEM` (1 tick usually, 7 ticks on some
iterations, consistent with a genuine external bus write's wait states) →
`S_NEXT`. Nothing in this sequence looks like an accidental repeat or an
avoidable extra cycle — it reads as a real CISC multi-state instruction
pipeline doing the work its own design says it should.

**Conclusion: no narrow, evidence-backed RTL bug was found.** The measured
cost is plausibly correct for a memory-operand compare + conditional branch
on real V60 hardware (a classically expensive CISC instruction pair), and
without the missing AC timing data there is no way to distinguish "correct"
from "still too slow" here. Making an arbitrary cycle-count cut at this
point would be exactly the unproven, speculative change the project's rules
prohibit (`CLAUDE.md`: "No speculative functional RTL changes to 'see if
they help'"; "Never obtain a pass by ... weakening arithmetic accuracy") —
it could regress every SSV title for an unproven benefit, on a core-wide
shared CPU model, with no way to verify the new numbers are any more correct
than the old ones. **No RTL timing change was made.**

## Instrumentation added this session

`verif/tb_ssv_frame_crc.sv`: `+CPU_LOOP_TRACE` plusarg (gated behind the
existing `+VISUAL_DIAG`), prints `cycle/frame/pc/r0/psw` on every CPU
retirement pulse, capped at 6000 lines. Modeled directly on the existing
`BOOT_TRACE` mechanism but not PC-range-restricted, so it's reusable for any
future CPU-throughput investigation on any SSV title. Zero cost when the
plusarg isn't passed. Left in place (uncommitted as of this journal entry;
functional fixes, if any come later, must land in a separate commit from
this instrumentation per repo convention).

## Decisive follow-up evidence (2026-08-05, continued)

Pushed further on two fronts before accepting the CPU-timing question as
closed for this session:

**1. MAME's own V60 core proves its timing is not a valid target.**
`D:\Arcade\AI\MAMESOURCE\mame\src\devices\cpu\v60\v60.cpp:614,626`:
```
// Actual cycles / instruction is unknown
...
m_icount -= 8;  /* fix me -- this is just an average */
```
This is not the SSV driver's simplification — it is baked into the V60 CPU
*device* itself, MAME-wide. MAME's own authors explicitly flag the flat
8-cycle model as an unverified placeholder. This is a primary-source,
tier-3 confirmation that "make RTL match MAME's CPU speed" is not a
hardware-accuracy improvement — it would mean tuning RTL to agree with a
number MAME's own maintainers call unknown. Per project doctrine (`CLAUDE.md`:
"Do not copy a known MAME bug or software-only implementation detail into
RTL"), this closes off cycle-count-matching as a legitimate technique here,
independent of whether real V60 AC timing is ever found.

**2. The V60 clock rate itself is verified correct, ruling out a clock bug.**
`ssv.cpp:2422,2433`: `SSV_MASTER_CLOCK = XTAL(48'000'000) / 3` = exactly
16.000000 MHz, sourced from "STA-0001 & STA-0001B System boards" (a real
board reference, not a guess). `ssv_pkg::SSV_CPU_INC = 21701` against a
65536-entry accumulator at `clk_sys` = 48.317307 MHz computes to
15.999973 MHz — matching to within 0.002%. The RTL's CPU clock generation
is correct; the entire measured gap is specifically in per-instruction
cycle *cost* within the core, not clock rate.

**3. The visible divergence is clean, not corrupted.** Viewed
`sim_output/lockstep/vasara2-attract360-full/diff/frame_000357.png` (the
worst frame, 47.6% differing): the diff shows sharp, recognizable
logo/glyph shapes, not noise or garbled pixels — consistent with "the same
correctly-rendered asset, just at a different point in its animation" (pure
timing lag), not a separate rendering defect. No additional renderer bug
was found hiding behind the CPU-timing divergence.

**Bus-arbitration check:** also traced `S_WB_MEM`'s variable cost (1 vs 7
`ce_cpu` ticks observed for the same instruction across loop iterations,
`s32_v60.sv:1815`) back to `s32_v60_bus.sv`'s real `m_ack`-gated handshake —
the variability is consistent with genuine external-bus ack timing (shared
with the video renderer's SDRAM/sprite-RAM traffic), not an artificial
fixed delay. No fix attempted here either, for the same reason: no
authoritative bound exists to compare against.

**Conclusion, now on stronger footing:** this is not merely "insufficient
evidence to act safely" — it is now proven that the one convenient
comparison target (MAME's CPU timing) is not a valid one, that the parts of
the RTL that *can* be checked without hardware datasheets (clock rate,
cache/fetch-window correctness, bus-ack behavior, rendering-content
correctness) all check out, and that the residual divergence is a clean,
explainable symptom of the same underlying per-instruction cost question.
Forcing a change here remains an uncontrolled experiment with a real chance
of making RTL wrong in a new way while looking more "correct" by a
metric (MAME parity) that MAME's own maintainers don't trust. No RTL
change was made.

## Experiment: widened fetch-window realign shift (2026-08-05, tried and reverted)

User authorized implementing and Quartus-validating the one concretely
pre-identified, bounded lever in this file: `s32_v60.sv`'s fetch-window
realign shift, capped at 4 bytes/cycle with an explicit code comment saying
it was kept conservative pending a real STA report ("Revisit only with a
real STA report" — the widening was estimated in-code at "~0.5 cyc/instr").
Widened it to 8 bytes/cycle in both sites that implement this pattern
(`S_FILL`'s top-up branch and `S_NEXT`'s fused-shift dispatch path,
including raising the `total_len<=4 → direct-to-S_DECODE` fast-path
threshold to 8 to actually realize the benefit for 5-8 byte instructions).

**Functional validation, both clean:**
- `verif/v60/run_v60_verilator.sh`: 32/32 passed (unit + Icarus white-box +
  SMC + gated-ce).
- `verif/cosim/run_diff.sh 50`: 50/50 seeds matched the Python reference
  model.

**Measured effect on the actual target (vasara2 360-frame attract lockstep):**
before vs. after, same commands as the full-trajectory run above:

| | before | after |
|---|---|---|
| non-exact frames | 122/360 | 118/360 |
| avg `exact_ratio` | 0.98894 | 0.98919 |
| worst frame | 357 | 357 (unchanged) |
| worst-frame `exact_ratio` | 0.52439 | 0.52439 (bit-identical) |
| worst-frame differing pixels | 38,353 | 38,353 (bit-identical) |

The change is real and functionally correct — a handful fewer frames
diverge early on — but the frame-357 catastrophic divergence (the actual
target: 47.6% of the screen differing) is **completely unmoved**, down to
the exact pixel count. This confirms with a real, measured experiment (not
just analysis) what the documented "~0.5 cyc/instr" estimate implied: this
lever is roughly two orders of magnitude too small to touch a divergence
that needs something like a 40-60% throughput change, not a fraction of a
percent.

**Reverted.** Per this project's own rule for the differential-debugging
loop, a fix is rejected if it doesn't close the gap it targets — that
applies even to a change that passes every regression, since the point of
the loop is closing the divergence, not accumulating unproven timing
changes. Given the payoff is this small, spending a full Quartus 17.0.2
Analysis & Synthesis + timing-report cycle (the STA validation the user
authorized, needed because this touches a mux already reported at only
~0.054ns setup slack) is not defensible for a change that empirically
doesn't move the target metric. `git checkout -- rtl/cpu/v60/s32_v60.sv`
restored the pre-experiment source; no Quartus build was run.

This closes off the last concretely-identified lever in this investigation.
Every other cost center found (the doubled `S_EA_MODE`/`S_EA_DONE` EA
resolution, `S_WB_MEM`'s variable bus-ack wait) is either correctness-
sensitive computation logic or bus-timing behavior with no known-safe,
bounded, pre-analyzed adjustment available — attempting either would be a
larger, less-understood, higher-risk change than this one, which itself
turned out too small to matter.

## Next steps

1. Run the full 360-frame `REQUIRE_ATTRACT` proof-mode gate to see whether
   the pixel mismatch stays bounded near ~1.7% or grows once RTL's growing
   lag pushes further state transitions out of the comparison window.
2. If real V60 AC timing can be sourced (a proper Hardware/User's Manual,
   not just the Programmer's Reference), compare against the measured
   15-58 `clk_sys` (~1-19 V60 cycle) per-instruction costs in this loop
   before touching `s32_v60.sv` timing.
3. Independent of the CPU-timing question, proceed to check vasara2
   gameplay-scenario parity and sound/ES5506 behavior, which have not been
   evaluated yet this session and may surface separate, more tractable
   issues.
4. Repeat this whole loop for `vasara` (Vasara 1) once vasara2 attract is
   judged as close as it can get without the deferred CPU-timing fix.
