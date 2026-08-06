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

## Next steps

1. Find vasara1's actual coin-accept requirement — since duration isn't it,
   candidates are: a different exact sample frame/window than 20-170, a
   different system-port bit, or a service/test-mode gate that must be
   cleared first. Disassembling the input-poll routine (via the MAME
   debugger or a targeted bus trace) would settle this directly.
2. Once a working coin-start scenario exists, repeat the gameplay/sound
   checks done for vasara2 (pixel-trajectory trend, audio-activity check).
