# Vasara (1) gameplay + sound — investigation journal

Scope: continuation of `docs/debug/vasara/ATTRACT_DIVERGENCE.md`, mirroring
`docs/debug/vasara2/GAMEPLAY_AND_SOUND.md`.

## Coin-start scenario did not actually start a game

Ran the same generic `coin_start_p1` scenario used for vasara2:
```
tools/run_ssv_lockstep.ps1 -Set vasara -Frames 300 -Scenario coin_start_p1 -FreezeOn never -TimeoutSeconds 400 -Session sim_output\lockstep\vasara1-coinstart300
```

Result: pixel divergence is **identical** to pure attract mode — only
frames 116-118 differ (same 1,252-pixel/1.55% logo-area mismatch documented
in the attract journal), nothing else across all 300 frames. Audio is
**completely silent** the entire run (`nonzero=0` in every
`SSV_VISUAL_AUDIO_SAMPLE` line, confirmed by grepping every line in the
run's log, not just the tail).

This looked at first like a real regression (vasara2's identical scenario
clearly registered — visible transitions, audio nonzero climbing to
138,039) but a direct comparison rules that out:

- `diff`'d the first 100 RTL state-dump lines (`rtl_state.jsonl`) between
  this coin-inserted run and a fresh coin-free `attract_idle` rerun
  (`sim_output/lockstep/vasara1-attract150-audiocheck`, 150 frames,
  `+STATE_START_FRAME`/CRC content) — **byte-identical**, zero diff.
- More importantly, **MAME's own reference trace is also byte-identical**
  between the two runs (`reference_state.jsonl`, compared by
  `list512_crc`/`scroll63_crc` transition points: frames 1, 24, 72, 73, 76,
  118 — same values, same frames, in both the coin-inserted and coin-free
  captures).

So this is not an RTL-vs-MAME divergence at all — **both sides show zero
response** to this scenario's coin+start input for vasara1. The
`coin_start_p1` input script (`verif/tb_ssv_frame_crc.sv:apply_inputs()`,
COIN1 pulsed frames 30-34, START pulsed 165-170) is tuned for Dyna Gear and
evidently does not land inside vasara1's actual coin-accept window/timing —
whatever the real requirement is (pulse width, exact sample frame, bit
polarity), this script doesn't meet it for this title. Silence on both
sides is consistent with the game simply never leaving attract mode in
either simulation.

**This scenario provides no real gameplay or sound evidence for vasara1.**
Unlike vasara2 (where the same script did visibly land a coin and produce
audio), vasara1 needs either a properly game-tuned input scenario or a
longer/differently-timed coin pulse before any gameplay-phase comparison is
meaningful.

## Follow-up: ruled out pulse width as the cause

Added a diagnostic-only `coin_start_probe` scenario to
`verif/tb_ssv_frame_crc.sv:apply_inputs()` (COIN1 held frames 20-60, a full
40-frame hold; START held frames 80-140, 60 frames — roughly 10-15x longer
than `coin_start_p1`'s 4-frame pulses) to test whether pulse duration was
the reason vasara1 doesn't respond. Result: **identical** state trajectory
to both the 4-frame-pulse run and the no-input-at-all run (same
`list512_crc`/`scroll63_crc` transition frames: 1, 24, 72, 73, 76, 118;
same 3-frame pixel mismatch at 116-118, nothing else). Confirms this is not
a "pulse too short" problem — MAME's reference genuinely does not respond
to a coin insertion at these frames/bit values for vasara1 regardless of
hold length, so the actual coin-accept requirement (timing window, or a
different port/bit) remains unidentified. `coin_start_probe` is left in
place, uncommitted, alongside `coin_start_p1`, as a reusable diagnostic for
whichever set needs this kind of check next — it changes no existing
scenario's behavior.

## Assessment

No gameplay-phase or sound evidence was obtained for vasara1 this session —
the available scenarios don't trigger a game start on either reference or
RTL, so there is nothing yet to compare or to fix. This is scenario/input
research work (most likely disassembling vasara1's actual coin-poll routine
to find the real requirement), not a known RTL bug — MAME's own reference
fails identically, which rules out an RTL-side input defect for this
specific symptom.

## Follow-up: raw input port confirmed correct via the new debug HUD (2026-08-05)

Built an OSD debug HUD (`rtl/video/ssv_debug_hud.sv`, see project root
`docs/debug/` session notes) that shows the raw `in_system`/`in_p1` port
values live, among other counters. Used it directly on vasara1 with
`coin_start_probe` (COIN1 held frames 20-60): at frame 40, the HUD's SYSTEM
row read `FFFE`, not `FFFF` — bit 0 (COIN1) is correctly asserted at the
core's input boundary.

This rules out an RTL input-wiring defect as the cause of vasara1's
non-response: the coin signal demonstrably reaches `ssv_core`'s `in_system`
port correctly. The remaining mystery is entirely downstream — in the
game's own poll routine, timing, or a config gate — not in the MiSTer
core's I/O path. Next investigator should look at *when* and *how* the
game code samples this port (a bus trace around the coin-poll routine)
rather than at the input wiring.

## RESOLVED (2026-08-06) — root cause found via MAME MCP: coin-poll loop starts at frame ~73, script asserts coin at frame 30

Using MAME MCP against the pinned `D:\Arcade\AI\mame289` build (ROM audit
passed for `vasara`), found the exact mechanism with live-session tools plus
a controlled `run_lua_script` diagnostic; see `.mame_mcp/vasara_*` logs for
raw evidence.

**1. Confirmed vasara's coin-poll loop timing directly (`trace_memory_access`,
range `$210000-$21001F`, the shared SSV I/O block).** With zero injected
input, no access to that range occurs before frame ~73; from frame ~73
onward a per-frame loop runs continuously:

```
R  PC=F01046  addr=21000C (SYSTEM)   -- coin/service read #1
W  PC=F01063  addr=21000E (lockout)  -- refresh lockout output
R  PC=F01072  addr=210008 (P1)
R  PC=F01083  addr=21000A (P2)
R  PC=F01094  addr=21000C (SYSTEM)   -- coin/service read #2
W  PC=F00FF5  addr=210000 (watchdog) -- per-iteration kick
```

**2. Confirmed MAME's live `mame_send_input` mechanism correctly asserts the
coin** — pressing "Coin 1" via the live session flips the SYSTEM port from
`$00FF` to `$00FE` (bit 0, matching the field's `mask=0x0001`), and produces
a real, persistent work-RAM state change (`byte[0x000009]`: `$00` → `$14`,
confirmed stable across 40+ subsequent frames with no further input — not a
free-running animation counter).

**3. Root-caused why the project's shared MAME capture script
(`tools/mame-capture-ssv-frames.lua`, "Capture ... for Dyna Gear" per its own
header) never worked for vasara1.** It uses the identical `field:set_value()`
mechanism as `mame_send_input` (verified byte-for-byte against the MCP
server's own `bridge.lua:handlers.send_input`) — the mechanism itself is not
broken. The problem is purely the **hardcoded frame window**: the script
asserts Coin 1 at frames 30-34, a full ~40 frames *before* vasara1's
coin-poll loop even starts (~frame 73). Any injection landing entirely
before frame ~73 is structurally invisible to the game, regardless of pulse
duration (already ruled out — the 40-frame `coin_start_probe` hold, frames
20-60, *also* ends before frame 73) or bit polarity (already ruled out — the
debug HUD confirmed the RTL-side port bit was correct).

Directly verified the fix with a standalone Lua harness replicating the
capture script's exact code path, coin window moved to frames 100-110
(comfortably inside the confirmed-active window): `byte[9]` reads `$00` at
frame 99, `$14` at frame 115 and after. **Confirmed: MAME's own reference
genuinely does accept vasara1's coin** — the opposite of this journal's
prior conclusion, which was correct about the symptom (zero response at
frames 20-170) but wrong about attributing it to an unknown/unfindable
requirement rather than simply "too early."

**Fix applied**: `tools/mame-capture-ssv-frames.lua` now reads
`SSV_COIN_FRAME_LO`/`_HI` and `SSV_START_FRAME_LO`/`_HI` env vars, defaulting
to the existing Dyna Gear-tuned 30-34/165-170 (zero behavior change for
Dyna Gear or any other set already relying on the defaults). Vasara1 (and
any other affected set) can now pass a correct window without touching the
shared default. Smoke-tested: default-path run (no env overrides) still
completes identically (`SSV_FRAME_CRC_DONE frames=120`, no errors).

**This also means every prior "vasara1 coin_start" RTL/MAME lockstep result
in this project used a MAME reference that was still in pure attract mode**,
not post-coin state — the RTL-side comparison to that reference was
comparing against the wrong ground truth the whole time. It does not mean
the RTL was ever tested against real post-coin MAME behavior and passed or
failed; it means that comparison has never actually been run yet.

## Next steps

1. Determine vasara1's exact required start-button window the same way
   (currently only coin's window is nailed down precisely; a generous
   estimate ≥frame 150 is likely safe based on live-session observation but
   not yet isolated to the same precision as the coin window).
2. Re-run the RTL/MAME lockstep for vasara1 with
   `SSV_COIN_FRAME_LO=100 SSV_COIN_FRAME_HI=110` (and a verified start
   window) to get the first real post-coin comparison evidence for this
   title, then repeat the vasara2-style gameplay/sound checks
   (pixel-trajectory trend, audio-activity check) against real gameplay
   instead of attract mode.
## RESOLVED (2026-08-06, continued) — RTL apply_inputs() fixed the same way; first real post-coin RTL/MAME comparison obtained

Applied the identical fix to the Verilator side: `verif/tb_ssv_frame_crc.sv`'s
`apply_inputs()` coin/start frame window is now `+COIN_FRAME_LO/HI=` and
`+START_FRAME_LO/HI=` plusargs (default 30/34/165/170, unchanged for every
existing caller). Rebuilt and ran both sides for vasara1's `coin_start_p1`
scenario with `COIN_FRAME_LO=100 COIN_FRAME_HI=110 START_FRAME_LO=200
START_FRAME_HI=210` (comfortably inside the confirmed-active window):

- MAME side: `tools/mame-capture-ssv-frames.lua` via
  `SSV_COIN_FRAME_LO/HI`/`SSV_START_FRAME_LO/HI` env vars, 300 frames,
  completed cleanly (`SSV_FRAME_CRC_DONE frames=300`).
- RTL side: same plusargs, `+FRAMES=300`; hit the default `+CYCLES=200000000`
  budget and stopped at frame 249 (`WARNING CYCLE_BUDGET_TRUNCATED`) — not a
  failure, just needs a higher `+CYCLES` for a full 300-frame run next time.

**Comparison** (`tools/compare-ssv-frame-crcs.py`, frame 0 skipped as the
known MAME-vs-RTL boot-epoch warmup mismatch per this project's existing
`--skip` convention):

- **Frames 1-111: pixel-exact.** Coin insertion itself (frames 100-110)
  produces zero visible divergence.
- **State CRC claim below was WRONG — see the correction two sections down.**
  ~~State CRCs (`list512`/`spr8k`/`scroll64`/`pal512`) match exactly across
  the entire 248-frame comparison window, with zero exceptions.~~ This was a
  false negative from a comparison-script bug (RTL emits `scroll63=`, the
  script looked for `scroll64=` on both sides, so the regex never matched a
  single RTL line and the "comparison" silently ran over an empty set).
  State genuinely does diverge — bounded and non-growing, not a new bug; see
  the correction below for the real picture.
- **Frames 112-201: small, periodic, self-correcting mismatches** (112,
  118-119, 133-134, 138-139, 149-150, 159-160, 164-165, 179-181, 195-196,
  200-201 — roughly every 14-20 frames, 1-2 frames each). This is the same
  signature already documented and understood for vasara2's post-coin
  behavior (`docs/debug/vasara2/GAMEPLAY_AND_SOUND.md`: "a small, periodic
  mismatch... recurring roughly every 10-20 frames... reads like a
  blinking/animated UI element... out of phase") — likely benign.
- **Frames 229-248 (end of the truncated run): every frame differs,
  continuously**, starting shortly after the Start press (200-210) —
  plausibly the point where the game transitions from select/intro into
  actual gameplay rendering. **Not yet classified** — no pixel-percentage or
  bounding-box evidence gathered yet (would need `+DUMP_PPM`/`compare_ppm.py`
  on both sides), so whether this is a real rendering bug or another benign
  timing artifact like the frame 112-201 pattern is unknown. The run was cut
  short at frame 249 by the cycle budget, so it's also unknown whether this
  stays bounded or compounds further.

**This is the first real evidence of any kind for vasara1 past the coin
insertion point** — every prior "vasara1 gameplay" investigation in this
project compared against a MAME reference that was still in attract mode.

## RESOLVED (2026-08-06, continued) — pixel-diff evidence classifies both divergence patterns

Got real PPM captures on both sides for frames 228-242 (`+DUMP_PPM_PREFIX=`
on RTL, `SSV_PPM_PREFIX=`/`SSV_PPM_FRAMES=` on MAME) and ran
`compare_ppm.py` frame by frame (`C:\Users\meath\.claude\skills\
mister-core-development\scripts\compare_ppm.py`).

**Found and fixed a second, unrelated pre-existing bug along the way**:
`verif/tb_ssv_frame_crc.sv`'s `visual_width`/`visual_height` (which feed the
`+DUMP_PPM` header) were only assigned under `` `ifdef SSV_VISUAL``, so the
plain (non-visual) build's PPM dumps silently wrote a degenerate
`P6\n0 0\n255\n` header — every non-SSV_VISUAL PPM capture in this project's
history has been an empty 0x0 image. Fixed by hoisting the assignment
outside the ifdef (unconditional, using the same build-variant-independent
`active_width_cfg`/`active_height_cfg` functions); zero behavior change for
the SSV_VISUAL path, which still computes the identical value.

**Results**:

| frame | different pixels | bbox | pattern |
|---|---|---|---|
| 228-234 | 76/80640 (0.094%), constant | `(1,94)-(10,103)`, unchanging | small, static, same signature as the 112-201 periodic blips |
| 235 | 2,800 (3.5%) | `(1,0)-(335,239)` | onset |
| 236 | 5,488 (6.8%) | | |
| 237 | 8,991 (11.1%) | left edge x=77 | |
| 238 | 11,651 (14.4%) | | |
| 239 | 16,644 (20.6%) | | |
| 240 | 19,254 (23.9%) | | growing linearly |
| 241 | 25,540 (31.7%) | | |
| 242 | 28,192 (35.0%) | left edge x=73 | |

**Frames 228-234 are the same benign, static, tiny-region mismatch already
characterized** (likely a blinking UI element a frame or two out of phase) —
not a new finding.

**Frames 235-242 show a distinct, diagnostic signature**: the mismatched
region's left edge moves steadily leftward and its right edge stays pinned
to the screen edge (335) — `first=(x,0)` at x = 312, 288, 264, 240, 216, 192,
168, 144 across frames 235-242, a constant **-24 px/frame**, with the
mismatch always spanning from that moving boundary to the right edge, full
screen height. This is the exact signature of **a horizontal wipe/curtain
transition rendered one frame out of phase between RTL and MAME** — not
random corruption, not a game-logic bug (state CRCs remain exactly identical
throughout, per the earlier finding), and not a growing/compounding
divergence in the sense of accumulating error: it is consistent with both
sides eventually rendering the identical final frame once the transition
completes, just reaching each intermediate step one frame apart. This is
architecturally the same *class* of presentation-timing artifact already
documented elsewhere in this project (e.g. Twin Eagle II's palette/scanline
split from a live-vs-snapshot palette update), not a new mechanism, applied
here to a transition wipe instead of a palette write.

**The wipe-convergence prediction was tested and refuted.** Captured frames
243-255 (both sides) as planned. The mismatch did **not** shrink back down —
it kept *growing* (46% at 243, up to 90.7% at frame 249, the wipe boundary
continuing left at the same -24px/frame all the way to x=0), then dropped to
a **different, fixed** bounding box `(0,56)-(271,183)` from frame 250
onward, shrinking steadily (37.6% → 11.9% by frame 255). This is not a
simple "off by one frame, otherwise identical" transition; a bigger effect
is in play during frames 220-255.

## CORRECTION (2026-08-06) — the earlier "state matches exactly" claim was a script bug; the real picture

Rechecking with the regex fixed (`scroll6[34]=` instead of a strict
`scroll64=`) found real state divergence that the broken check had silently
hidden:

- `list512`/`spr8k` (sprite list/RAM): first differ at frame 22, but it's a
  single **2-frame-early transition boundary** (MAME switches value at
  frame 24, RTL at frame 22) — the same benign "CPU-phase boundary" pattern
  already documented for *every* title in this project (Dyna Gear,
  Cairblad, vasara1's own attract-mode journal), not a new or growing issue.
  Confirmed via a shift search: both sides sit on an unchanging plateau
  value from frame 24 through at least 39, ruling out compounding drift in
  this window.
- `pal512`: first differs at frame 69, but **`MAME[f] == RTL[f-3]` exactly**
  for every tested window from frame 70 through 255 (checked in 15-frame
  blocks at 70,100,130,160,190,220,240,250; every one gives an exact
  15/15 match at shift=+3, except the 220-234 block, which sits inside the
  frames-235-249 anomaly above and doesn't resolve to a clean shift). **This
  offset is constant, not growing** — categorically different from the
  documented compounding V60-CPU-throughput divergence in vasara2's attract
  mode (`docs/debug/vasara2/ATTRACT_DIVERGENCE.md`), which grows without
  bound over hundreds of frames. Frame ~70 lines up closely with vasara1's
  independently-measured coin-poll-loop start (~frame 73, this same
  session) — this is very likely the *same* few-frame "CPU-phase boundary"
  shift vasara1's original attract-mode journal already found and assessed
  as benign ("already about as close to MAME as this core gets given the
  known, unresolved CPU-timing question"), not a new defect introduced by
  the coin-start scenario or this session's fixes.

**Net effect on this session's conclusions**: the "state is exactly
identical, only presentation differs" framing was too strong and is
withdrawn. The corrected picture is that vasara1's post-coin trajectory
carries the same small, bounded, already-documented CPU-phase-boundary
offset as its attract mode — not a new bug — but frames 220-255 show a
larger, not-yet-explained effect (the growing-then-relocating pixel
mismatch, and the one state window that doesn't resolve to a clean shift)
that is **not** accounted for by the constant +3 offset alone and needs
further investigation before being classified.

## Next steps (revised again)

1. Root-cause the frames 220-255 anomaly specifically: get a PC/bus trace
   (not just frame/state CRCs) spanning that window on both sides to find
   the first causal event where RTL and MAME's *execution*, not just
   presentation, diverges beyond the constant +3-frame offset. This is the
   one real open question from this session — everything else (coin timing,
   the +3 boundary shift) is now understood and consistent with prior
   documented findings.
2. Given vasara2's coin_start_p1 scenario "worked" with the *original*
   30-34 default (per `docs/debug/vasara2/GAMEPLAY_AND_SOUND.md`), vasara2's
   own coin-poll loop evidently starts earlier than vasara1's — worth a
   quick confirmatory trace_memory_access pass on vasara2 too, since its
   result was never independently verified against a MAME-side RAM/state
   check the way vasara1 now has been (it was inferred from RTL-side pixel
   transitions and audio activity, not directly confirmed on the MAME side
   with the rigor applied here). Also worth re-checking vasara2's own state
   comparison for the same `scroll63`/`scroll64` field-name bug found here.
