# Vasara 2 gameplay + sound — investigation journal

Scope: continuation of `docs/debug/vasara2/ATTRACT_DIVERGENCE.md` after the
user directed moving on from the attract-mode CPU-timing root cause (no safe
fix found; see that file) to gameplay parity and sound.

## Gameplay lockstep (coin_start_p1 scenario)

No vasara2-specific gameplay input scenario exists yet — `verif/scenarios/vasara2/`
only has `attract_idle.json`, and the per-frame input scripts in
`verif/tb_ssv_frame_crc.sv:apply_inputs()` (`coin_start_p1`, `_gameplay`,
`_long`, `_runright`, `coin_start_2p_dense`) are all written for Dyna Gear
(character-select "Roger" confirms, stage-specific story-beat frame windows).
Vasara 2 doesn't have a character-select screen, so those Dyna-specific
button presses land on whatever vasara2 actually shows at that frame — not
meaningful, but not harmful either (extra/irrelevant input, not malformed
input). Ran with the generic `coin_start_p1` scenario (coin at frame 30-34,
START at 165-170, then Dyna-specific presses that are no-ops for vasara2's
actual UI) as a first-order smoke test, since building a properly-tuned
vasara2 scenario (shmup movement/shoot pattern) is separate work.

Commands:
```
tools/run_ssv_lockstep.ps1 -Set vasara2 -Frames 300 -Scenario coin_start_p1 -FreezeOn never -TimeoutSeconds 400 -Session sim_output\lockstep\vasara2-coinstart300
tools/run_ssv_lockstep.ps1 -Set vasara2 -Frames 500 -Scenario coin_start_p1 -FreezeOn never -TimeoutSeconds 500 -Session sim_output\lockstep\vasara2-coinstart500   # timed out at frame 473/500 (wall-clock budget too tight, not a functional failure)
```

### Findings

Frames 1-54 are pixel-exact (coin insertion itself causes no visible
divergence). From frame 55 on, the pattern is **qualitatively different**
from pure attract mode's compounding divergence — most of it is bounded and
self-correcting, not runaway:

- **Frames 55-58**: brief, large (91% of pixels, full-screen bbox) mismatch,
  then back to pixel-exact at frame 59 and holds through frame 70. This
  looks like a screen-transition timing skew (a fade/wipe or state-change
  cue firing a few frames apart on the two sides) that resolves, not a
  compounding lag — consistent with the coin-insert response being one of
  the timing-sensitive events affected by the same CPU-throughput gap
  documented for attract mode, but bounded here rather than growing.
- **Frames ~71-200**: a small, periodic mismatch (72-836 differing pixels,
  narrow bbox around `[20-31, 51-185]`) recurring roughly every 10-20
  frames — reads like a blinking/animated UI element (credit counter or
  "PUSH START" prompt) a few frames out of phase between RTL and MAME. Small
  and does not grow over this window.
- **Frame 218**: another large brief spike (94.4% differing, full-screen
  bbox), self-correcting by ~frame 228.
- **Frames 228-252**: a different small periodic mismatch (2,138 pixels,
  bbox `[90,79,140,160]`) — likely the same class of out-of-phase animated
  element as the 71-200 window, different element/location.
- **Frames 253-472** (end of the captured run): pixel-exact, no further
  mismatches recorded before the second run's wall-clock timeout.

129/300 frames (run 1) have a state (sprite-list CRC) mismatch — more than
the pixel-diff frame count, i.e. some state drift doesn't reach visibility,
consistent with the same underlying CPU-timing skew as attract mode but
**not visibly compounding** in this particular 472-frame window the way pure
attract mode compounded to 47.6% differing pixels by frame 357. Whether this
stays bounded over a much longer real-play session is untested.

**No renderer overrun, no crash, no stuck/black frames** in either run —
the core reaches and sustains a plausible gameplay-adjacent state through
frame 472 without hard failures.

## Sound

No MAME-vs-RTL audio comparison is wired into the lockstep pipeline for any
set (`core-debug.toml`/lockstep `completion.json`: `coverage.audio:
"captured_only"` — RTL audio is captured, never diffed against a MAME
reference stream). This is a pre-existing gap in the shared harness, not
specific to vasara2.

What was checked instead: RTL-side audio output during the
`vasara2-coinstart300` run (`SSV_VISUAL_AUDIO_SAMPLE` lines in
`sim_output/lockstep/vasara2-coinstart300/logs/rtl.log`). Audio is clearly
active and not silent or stuck: sample values vary continuously (e.g.
`left/right` swinging from 0 up to several thousand and back, values like
`-4441`, `1452`, `-2901` across the run), `nonzero` sample count climbs
steadily to 138,039 of 156,284 total by the run's end, and there are no
`errors` or `resets` reported (`dropped_frames=0`, `errors=0`). `underflows`
climbs to 101 by the end of the run, which is a buffering/priming
characteristic of the SDL playback path in this headless comparison harness
(no listener, `--comparison` mode), not necessarily evidence of an RTL
audio-generation bug — it was not investigated further this session.

The ES5506 unit-level regression tests (`verif/tb_ssv_es5506_regs.sv`,
`tb_ssv_es5506_ulaw.sv`, `tb_ssv_es5506_voice.sv`, run via
`verif/run_audio_sims.sh`) are game-agnostic (they exercise the ES5506 model
directly, not through any specific SSV title's ROM) and were not rerun this
session — attempting to invoke them hit a WSL quoting issue in this session
and was not worth further time given they don't add vasara2-specific
evidence. They should be part of the normal focused-test routine
(`core-debug.toml: audio_tests`) rather than re-verified per-game.

## Assessment

Vasara 2's post-coin/gameplay-adjacent behavior tracks MAME **substantially
better** than pure attract mode over the frames tested (472 frames, only
brief/bounded mismatches, no compounding runaway). This is a materially more
encouraging result than the attract-mode finding and suggests the CPU
throughput gap's practical impact is scene-dependent — it compounds badly
over attract mode's long uninterrupted idle-loop stretch, but stays bounded
across this shorter, more input-varied window. That said:

- This used generic (non-shmup-tuned) inputs, not a real vasara2 play
  pattern — a proper scenario (movement + shoot) has not been built or run.
- Only 472 frames (~8s of gameplay) were observed; whether divergence stays
  bounded over a full stage is unknown.
- Sound was confirmed *active*, not confirmed *correct* (no MAME reference
  comparison exists in the harness for any title).

## Next steps

1. Build a proper vasara2 gameplay input scenario (movement + shoot,
   shmup-appropriate) if deeper gameplay validation is wanted, rather than
   continuing to reuse the Dyna-tuned `coin_start_p1` script.
2. Extend the observation window well past 472 frames to check whether the
   bounded-mismatch pattern holds or eventually compounds like attract mode.
3. Sound has no MAME-comparison path in this project's harness at all
   (any title) — building one is out of scope for a per-game investigation.
