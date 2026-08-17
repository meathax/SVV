# Vasara (1) — mister-mame-diff session notes

## Baseline (2026-08-06)

- MAME executable: `D:\arcade\ai\mameexe\mame.exe` (per skill pin)
- MAME source tree consulted: `D:\Arcade\AI\mame289\src\mame\seta\ssv.cpp`
  (driver), cross-referenced against project's own pinned
  `D:\Arcade\AI\MAMESOURCE\mame` (core-debug.toml: "0.288 pinned contract;
  current mame0289 checkout SSV drivers byte-identical") — not independently
  re-diffed this session, treated as consistent per that existing record.
- MAME MCP repo: configured server `mame` (tools available: ping,
  config_check, audit_romset, get_ioports, mame_launch/session_status/
  run_frames/pause/resume/send_input/get_regs/read_memory/exec_lua_live/
  save_state/load_state/session_stop, run_lua_script, trace_memory_access).
- ROM path: `D:\Arcade\AI\SVV\rom` (project-local, not a global MAME rompath
  — passed explicitly on every MCP call). `audit_romset` result: "romset
  vasara is good".
- Machine config: `void ssv_state::vasara(...)` → `ryorioh_map` (ssv.cpp:2593,
  2598) → shared `ssv_map(map, 0xc00000)` base. Watchdog write-kick at
  `$210000`. SYSTEM port read at `$21000C` (`ssv.cpp` shared io block,
  confirmed live at `.mame_mcp` trace logs). CPU tag `:maincpu` confirmed
  (`V60(config, m_maincpu, SSV_MASTER_CLOCK)`, ssv.cpp:2433).
- `get_ioports` result: SYSTEM = {Service 1, Coin 2, Coin 1}; P1 = {Up/Down/
  Left/Right, Button 1/2/3, 1 Player Start}; DSW1/DSW2 dip fields. Full list
  in `.mame_mcp/vasara_ioports_*.log`.
- No `core-debug.toml` changes made — project's existing one is current and
  sufficient (see repo root `core-debug.toml`).

## Iteration 1 — vasara1 coin-accept root cause (2026-08-06)

**Scenario / first divergence before fix:** `coin_start_p1` /
`coin_start_probe` scenarios showed byte-identical RTL and MAME-reference
trajectories to pure `attract_idle` — i.e. apparently zero response to coin
input on *both* sides (per `docs/debug/vasara/GAMEPLAY_AND_SOUND.md`,
sessions predating this one). Root cause was left unidentified; hypotheses
of pulse-width and port-bit-polarity had already been ruled out.

**MAME MCP preflight/session status:** `ping` OK; `config_check` resolved
executable/paths OK; `audit_romset vasara` — "romset vasara is good" (0
errors); `get_ioports` returned the full SYSTEM/P1/P2/DSW field inventory.

**MAME tools called + request/response/artifact paths:**
- `trace_memory_access` (injectPreset=none, 3600 frames, range
  `$210000-$21001F`) → `.mame_mcp/vasara_trace_20260806_181805.log` — found
  the natural per-frame coin-poll loop (PC `0xF01046`/`0xF01094` reading
  SYSTEM, `0xF01063` writing lockout, `0xF00FF5` kicking watchdog),
  starting at frame ~73 and running every frame thereafter (827/900 and
  3527/3600 iteration counts observed across two run lengths, both
  consistent with a "frame ~73 onward, every frame" loop).
- `trace_memory_access` (injectPreset=coin_start, 900 frames, same range)
  → `.mame_mcp/vasara_trace_20260806_182003.log` — SYSTEM read value was
  `$FF` on all 827 samples despite the preset's coin(240-260,320-340)/
  start(460-490) injection landing inside the active polling window.
- Live session (`mame_launch`/`mame_pause`/`mame_exec_lua_live`) — direct
  `ioport_field:set_value()` test while paused showed **no** change to
  `port:read()` even after `mame_run_frames(2)`; but `mame_send_input`
  (Coin 1, value 1) on the same live session immediately changed the
  SYSTEM port from `$00FF` to `$00FE` after one `run_frames(1)`. Field mask
  for Coin 1 confirmed `$0001` via `field.mask`.
- Live session `mame_read_memory` before/after: `addr=0 len=1024` snapshot
  before pressing coin vs. after coin+30 frames — `byte[0x0009]`: `$00` →
  `$14`, stable across 40 further frames with no input (rules out a
  free-running counter). After also pressing "1 Player Start" and running
  120 more frames: substantial additional RAM churn at offsets ~44-51,
  consistent with a real state transition (not confirmed as "gameplay
  entered" with the same rigor as the coin result — see Next steps).
- `run_lua_script` custom harness #1
  (`.mame_mcp/vasara_capture_method_test.lua`) replicating
  `tools/mame-capture-ssv-frames.lua`'s exact coin(30-34)/start(165-170)
  `field:set_value()` calls from cold boot → `byte[9]` stayed `$00` through
  frame 400. Confirms the capture script's *own* timing fails for vasara1.
- `run_lua_script` custom harness #2
  (`.mame_mcp/vasara_capture_method_test2.lua`), identical mechanism, coin
  window moved to 100-110 → `byte[9]`: `$00` at frame 99, `$14` from frame
  115 onward. **Isolates the cause to frame timing, not mechanism.**
- Read `D:\Arcade\AI\mcp\mame-mcp\mame_mcp\bridge.lua:147-154`
  (`handlers.send_input`) to confirm it is mechanistically identical to the
  capture script's own `field:set_value()` calls (same `pairs(ioport.ports)`
  iteration, same `set_value` call) — ruling out an MCP-vs-script mechanism
  difference as an explanation.

**MAME reference tainted:** NO for the diagnostic conclusion (the harness
tests are read-only observations of a normal input injection, not
`mame_write_memory`/`mame_set_reg` state forcing). The live session used for
manual `mame_send_input` experiments is diagnostic-only and was not
preserved as a golden reference.

**Checkpoint used:** none (cold boot / live free-run for each experiment;
no save-state checkpoints created this session — see Next steps).

**Root cause + evidence:** `tools/mame-capture-ssv-frames.lua`'s coin
injection window (frames 30-34) fires ~40 frames before vasara1's coin-poll
loop starts (~frame 73, per the `$210000-$21001F` access trace). The
injection mechanism itself (`ioport_field:set_value()`) is correct and
identical to the MCP server's own `mame_send_input` implementation.

**Change (files, one-line summary):**
- `tools/mame-capture-ssv-frames.lua`: added `SSV_COIN_FRAME_LO/HI` and
  `SSV_START_FRAME_LO/HI` env-var overrides, defaulting to the existing
  Dyna Gear-tuned 30-34/165-170 (zero behavior change when unset).
- `docs/debug/vasara/GAMEPLAY_AND_SOUND.md`: corrected the prior "MAME
  genuinely does not respond" conclusion with the resolved root cause.
- `.gitignore`: added `.mame_mcp/` (generated MCP scripts/logs/state).

**Targeted test:** PASS — standalone Lua harness (#2 above) confirms the
fix's underlying premise (coin accepted with corrected timing). Smoke-tested
the edited capture script with default env (no overrides): completes
identically to before the edit (`SSV_FRAME_CRC_DONE frames=120`, no errors) —
confirms zero behavior change for existing callers.

**Regressions:** Dyna Gear/other-title capture behavior unchanged by
construction (env vars default to prior hardcoded values); not re-run this
session (no RTL/Verilator rebuild performed) — see Next steps.

**Checkpoints refreshed/invalidated:** none existed for this scenario yet.

**New first divergence:** not yet known — the actual RTL/MAME lockstep with
corrected coin timing has not been re-run yet (that requires a Verilator
rebuild + `tools/run_ssv_lockstep.ps1`-equivalent invocation with the new
`SSV_COIN_FRAME_LO/HI` env vars threaded through, which this iteration did
not reach).

**Warnings/resource/timing delta:** N/A (no RTL/Quartus touched this
iteration).

**Open observability gaps / next action:**
1. Vasara1's exact required *start*-button window is not yet isolated with
   the same precision as the coin window (only a generous live-session
   observation, not a byte-level before/after RAM test at a specific
   frame boundary).
2. The actual RTL-side Verilator scenario config
   (`verif/tb_ssv_frame_crc.sv:apply_inputs()`, a *separate* SystemVerilog
   implementation of the same Dyna-tuned schedule) has the identical
   hardcoded-frame-window problem and needs the equivalent fix before an
   RTL/MAME lockstep comparison with real post-coin state is possible for
   vasara1. This session only fixed the MAME-side Lua capture script.
3. Vasara2's coin-accept timing was never independently confirmed with this
   rigor (RAM byte-flip test) — its "the same script worked" conclusion in
   `docs/debug/vasara2/GAMEPLAY_AND_SOUND.md` rests on RTL-side pixel/audio
   observations only. Worth a quick confirmatory pass.
4. No MAME or Verilator save-state checkpoints were created this session
   (`mame_save_state`/`VerilatedSave`) — every experiment re-booted from
   cold or continued a single long-lived live session. Future iterations on
   this scenario should create a `vasara1-post-coin` checkpoint pair once
   the RTL side is fixed, per the skill's checkpoint discipline.

## Iteration 2 — RTL-side timing fix + first real post-coin RTL/MAME comparison (2026-08-06)

**Scenario / first divergence before fix:** vasara1's `coin_start_p1` had
never produced a real post-coin comparison — the RTL testbench's
`apply_inputs()` shared the same Dyna-tuned hardcoded frame window (30-34)
as the MAME Lua script fixed in Iteration 1.

**Change (files, one-line summary):**
- `verif/tb_ssv_frame_crc.sv`: `apply_inputs()` coin/start window
  parameterized via `+COIN_FRAME_LO/HI=`/`+START_FRAME_LO/HI=` plusargs,
  defaulting to the original 30/34/165/170 (zero behavior change for every
  existing scenario/caller).

**Build:** direct build of the tracked file hit one remaining pre-existing,
unrelated break (`visual_loop_trace_start` declared under `ifdef SSV_VISUAL`
but used unconditionally — NOT the `debug_hud_en` break from Iteration 1,
which has since been resolved elsewhere in the tree). Worked around in a
scratch copy only, as in Iteration 1; not fixed in the tracked file.

**Runs:**
- MAME: `tools/mame-capture-ssv-frames.lua`, `SSV_SCENARIO=coin_start_p1
  SSV_COIN_FRAME_LO=100 SSV_COIN_FRAME_HI=110 SSV_START_FRAME_LO=200
  SSV_START_FRAME_HI=210 SSV_MAX_FRAMES=300` → 300 frames, clean.
- RTL: `+GAME_ID=2 +SCENARIO=coin_start_p1 +COIN_FRAME_LO=100
  +COIN_FRAME_HI=110 +START_FRAME_LO=200 +START_FRAME_HI=210 +FRAMES=300`
  → truncated at frame 249 by the default `+CYCLES=200000000` budget
  (`WARNING CYCLE_BUDGET_TRUNCATED`, not a failure — needs a higher
  `+CYCLES` next time for the full range).

**Comparison** (`tools/compare-ssv-frame-crcs.py --skip 1`, frame 0 excluded
as the known boot-epoch warmup mismatch):
- Frames 1-111: pixel-exact.
- State CRCs (list512/spr8k/scroll64/pal512): **exact across the entire
  248-frame window, zero exceptions.**
- Frames 112-201: small periodic 1-2 frame mismatches every ~14-20 frames —
  same signature as vasara2's documented "blinking UI element" pattern.
- Frames 229-248 (run end): continuous mismatch every frame — new, not yet
  classified (no pixel-percentage/PPM evidence gathered this session).

**Root cause + evidence:** identical to Iteration 1 (coin-poll loop timing).
This iteration's new finding is that with corrected timing, the RTL and
MAME state trajectories are state-identical throughout, and the only
divergence is in rendered pixels — localizing any real remaining issue to
the video/presentation path, not CPU/gameplay logic.

**Targeted test:** PASS (comparison produced real, meaningful data for the
first time). **Regressions:** not re-run this session (Dyna Gear/other-set
behavior unchanged by construction, since the plusarg defaults match prior
hardcoded values — not independently re-verified by an actual regression
run this session).

**Checkpoints refreshed/invalidated:** none created this session (see
Iteration 1's same open item).

**New first divergence:** frame 112 (pixel-only; frame 229 for the
continuous/sustained pattern) — see `docs/debug/vasara/GAMEPLAY_AND_SOUND.md`
for full detail.

**Open observability gaps / next action:**
1. Get PPM captures (`+DUMP_PPM_*` on RTL, an equivalent MAME capture) and
   run `compare_ppm.py` on frames 229+ to quantify the sustained divergence
   (pixel %, bounding box) before deciding whether it's a real bug.
2. Re-run with a higher `+CYCLES` budget for the full 300+ frame range.
3. The one remaining pre-existing unrelated build break
   (`visual_loop_trace_start`/`ifdef SSV_VISUAL`) is still unfixed in the
   tracked file — trivial one-line fix (move the declaration outside the
   ifdef) but out of scope for this task; flagged for whoever owns that
   area.

## Iteration 3 — pixel-diff evidence on frame 229+ divergence; second unrelated bug found and fixed (2026-08-06)

**Change (files, one-line summary):**
- `verif/tb_ssv_frame_crc.sv`: hoisted `visual_width`/`visual_height`
  assignment out of `` `ifdef SSV_VISUAL`` (unconditional now, same computed
  value) — the plain-build `+DUMP_PPM` path was silently writing degenerate
  `P6\n0 0\n255\n` headers before this fix. Zero behavior change for the
  SSV_VISUAL path.

**Runs:** RTL (`+DUMP_PPM_PREFIX=... +DUMP_PPM_START=228 +DUMP_PPM_COUNT=15
+DUMP_PPM_STEP=1`, scratch build) and MAME
(`SSV_PPM_PREFIX=`/`SSV_PPM_FRAMES=228,...,242`) PPM captures for the same
15 frames, both re-run after the fix and confirmed `336 240` headers.

**Comparison** (`compare_ppm.py`, per-frame):
- Frames 228-234: constant 76/80640 (0.094%) mismatch, bbox
  `(1,94)-(10,103)` — same benign small-region pattern already documented.
- Frames 235-242: growing mismatch (3.5% → 35.0%), left edge of the
  mismatched bbox moving from x=312 to x=144 at a constant -24px/frame,
  right edge pinned to the screen edge, full height — diagnostic of a
  horizontal wipe/transition rendered one frame out of phase between RTL
  and MAME. State CRCs remain exact throughout (Iteration 2 finding) —
  this is a presentation-timing question, not a gameplay-logic difference.

**New first divergence:** none beyond what Iteration 2 found; this
iteration classifies (does not newly discover) the frame 229+ divergence.

**Open observability gaps / next action:**
1. Capture frames ~243-255 to test whether the mismatch shrinks back down
   as the wipe completes on both sides (predicted by the "1-frame skew"
   hypothesis) or stays elevated (would refute it) — not done this session.
2. If confirmed, find the specific RTL register/signal driving the
   transition wipe and compare its write timing against MAME.

## Iteration 4 — correction: state comparison had a field-name bug; wipe-convergence test refuted; real picture is a bounded +3-frame offset (2026-08-06)

**Correction of Iteration 2/3 claims**: the state-CRC comparison script used
in Iteration 2 required `scroll64=` on both sides; RTL actually emits
`scroll63=`, so the regex never matched any RTL line and `set(mame) &
set(rtl)` was empty. This was silently reported as "zero exceptions" —
a false negative, not a real result. Fixed the regex (`scroll6[34]=`) and
re-ran the comparison across the full frame 0-259 range (needed a fresh
RTL run with `+STATE_CRC=` added, since the PPM-focused reruns in
Iteration 3 hadn't requested it).

**Corrected findings:**
- `list512`/`spr8k`: first differ at frame 22 -- a 2-frame-early transition
  boundary (MAME switches at 24, RTL at 22), both plateau afterward through
  at least frame 39. Same benign pattern documented project-wide.
- `pal512`: first differs at frame 69; `MAME[f] == RTL[f-3]` exactly across
  every 15-frame window tested from 70 to 255 except the 220-234 block
  (which overlaps the still-unexplained pixel anomaly below). **Constant
  offset, not growing** -- different in kind from vasara2's documented
  compounding CPU-throughput divergence. Frame ~70 aligns closely with
  vasara1's independently-measured coin-poll-loop start (~frame 73),
  suggesting this is the same already-documented "CPU-phase boundary"
  shift from vasara1's original attract-mode journal, not a new defect.

**Wipe-convergence test (requested next step from Iteration 3), REFUTED**:
captured frames 243-255 (both sides, `+DUMP_PPM_START=243 +DUMP_PPM_COUNT=13`
RTL / `SSV_PPM_FRAMES=243,...,255` MAME). The predicted shrink-back-to-~0%
did not happen: mismatch grew to 90.7% at frame 249 (wipe boundary reaching
x=0 at the same -24px/frame rate), then dropped to a different, fixed bbox
`(0,56)-(271,183)` from frame 250, shrinking 37.6%->11.9% by frame 255. The
"1-frame timing skew, otherwise-identical, self-converging" hypothesis from
Iteration 3 is refuted -- something larger than a fixed frame offset is
happening in this window.

**Root cause + evidence**: NOT fully resolved. The +3-frame state offset
(bounded, likely a known/pre-existing effect) is understood; the frames
220-255 pixel/state anomaly is not.

**Regressions:** none run this session beyond the comparisons above.

**Open observability gaps / next action:**
1. The frames 220-255 anomaly needs a PC/bus-level trace (not just frame/
   state CRC snapshots) on both sides to find where execution genuinely
   diverges beyond the constant +3-frame offset -- the one real open
   question remaining from this whole investigation chain.
2. Re-check vasara2's own state comparison for the same scroll63/scroll64
   field-name bug -- its "state matches" conclusions (if any used the same
   comparison approach) should be treated as unverified until re-checked.
