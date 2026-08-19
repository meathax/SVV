# ES5506 warped guitar notes (Drift Out '94 name-entry music) — root cause

Scope: user report — sustained guitar notes during Drift Out '94 name-entry
music sound warped/corrupted on this core; correct on real PCB per user's
reference video. Read-only differential investigation against MAME 0.289
`es5506.cpp` (evidence tier 3) plus direct RTL source-of-truth reading (tier
5 self-consistency check against the RTL's own design intent).

## Method

Compared `rtl/audio/ssv_es5506_voice.sv` and `rtl/audio/ssv_es5506_regs.sv`
against `mame289/src/devices/sound/es5506.cpp` across: loop/transwave/bidir
looping, filter pole math (lp/hp), volume gain table, u-law decode,
interpolation, envelope ramping, host register byte-assembly/commit timing,
IRQV semantics, and register masking. Three independent passes (two Sonnet,
one Opus) converged on the same primary finding.

## Findings, ranked

### 1. CONFIRMED — engine writeback clobbers host register writes mid-slot

The voice engine (`rtl/audio/ssv_es5506_voice.sv`) is a single sequential
state machine: it latches one voice's full register set at `S_START`
(`ssv_es5506_voice.sv:303-324`), computes across `S_WAIT1/S_WAIT2/S_PROC/
S_POLE12/S_FILT` (~7-8 `ce` ticks later), then writes the derived state back
at `S_MIX` (`ssv_es5506_voice.sv:482-494`, asserting `eng_wr_accum`,
`eng_wr_cr`, `eng_wr_filt`, `eng_wr_env`).

The register file (`rtl/audio/ssv_es5506_regs.sv`) only protects against a
host write and an engine writeback landing on the **exact same clock cycle**
(the `pend_*`/`eng_pending` scaffolding at `ssv_es5506_regs.sv:695-779`,
field-gated by `we_control`/`we_accum`/etc). Its default/plain path — the
common case, taken whenever neither a same-cycle host commit nor a deferred
replay is in flight — writes the engine's result unconditionally:

```
// ssv_es5506_regs.sv:352-370
else begin
    wr_addr = eng_voice;
    if (eng_wr_accum) we_accum = 1'b1;
    if (eng_wr_cr)    we_control = 1'b1;
    if (eng_wr_filt) begin we_o4n1=1; we_o3n1=1; ... end
    if (eng_wr_env)  begin we_lvol=1; we_rvol=1; we_k1=1; we_k2=1; we_ecount=1; end
end
```

There is **no mechanism at all** for the case where the host commits a
register for voice V several cycles *after* V's `S_START` snapshot but
*before* V's `S_MIX` writeback — i.e. a host write landing inside the ~7-8
tick window while that voice is mid-flight in the engine. The engine's
`S_MIX` writeback, computed from the pre-write snapshot, silently overwrites
the host's fresh value with stale derived state.

The `eng_wr_env` field is the widest exposure: it unconditionally rewrites
**lvol, rvol, k1, k2, ecount** together whenever `ecount != 0`
(`ssv_es5506_voice.sv:538-569`), even for fields with no active ramp (the
writeback defaults to the just-latched, now-stale value —
`ssv_es5506_voice.sv:490-494`). Any voice with a running envelope — which is
the normal state for a sustained music note — is vulnerable on K1/K2/LVOL/
RVOL for its entire duration, not just at note-on.

**Why this reads as "warped guitar notes, sound effects fine":** SFX voices
are typically triggered once and left alone — few or no register writes
land inside their brief live window, so the race rarely fires. Music voices
are driven by a sequenced score that continuously rewrites CR/ACCUM/K1/K2/
volume as notes retrigger and articulate — exactly the access pattern that
maximizes exposure to this window. A dropped ACCUM write plays the new note
from the wrong sample position (pitch/attack corruption); a dropped K1/K2
write leaves the filter cutoff wrong for that note's duration (timbre/
"warped" tone); a dropped CR write can drop the note or its loop mode
entirely.

This is also a **self-inconsistency** in the RTL, not just a MAME
divergence: the `eng_pending`/`pend_*` machinery's own comment
(`ssv_es5506_regs.sv:10`: "Host byte-3 commit owns the write port (engine
writebacks held off)") states the designers' intent that host writes must
win over engine writebacks — the implementation just doesn't cover the
multi-cycle in-flight case, only the single-cycle collision.

### 2. PLAUSIBLE — filter rounding is floor; MAME truncates toward zero

`lp()`/`hp()` (`ssv_es5506_voice.sv:161-201`) use `>>>` (arithmetic
shift-right, floors toward −∞). MAME's `apply_lowpass`/`apply_highpass`
(`es5506.cpp:534-542`) use C `/` and `in / 2` (truncate toward zero). For the
recursive one-pole form this gives RTL a one-sided dead zone (settles at or
below target) vs MAME's symmetric dead zone — an asymmetric small-signal
nonlinearity on sustained low-level filtered content. Steady-state effect,
would color every note rather than intermittent ones; lower priority than
#1 for an "occasional warped note" symptom but should be fixed for general
accuracy.

### 3. PLAUSIBLE — `sat18()` clips filter pole state; MAME does not

`ssv_es5506_voice.sv:155-159` hard-clips every pole output to ±131071.
MAME's filter pole storage is unmasked `s32`. On resonant filter settings
the cascade can overshoot 18 bits; RTL clips (distortion), MAME doesn't.
Not clearly a bug without OTTO datasheet evidence on the real register
width/behavior — flag for instrumentation (count `sat18` engagements during
this music), don't fix blind.

### Ruled out (verified clean this session)

- Loop/transwave/bidirectional looping — byte-for-byte match vs
  `es5506.cpp:678-745`.
- lerp() 9-bit vs MAME's 11-bit interpolation fraction — coarsens
  interpolation weight only, no pitch/detune error, ~−50 dB error floor,
  broadband hiss at most, not a "warped note" mechanism.
- Host register byte-assembly, commit trigger, page decode, ramp shadow
  round-trip, IRQV read-clear scope, START/END/O-filter masking — full
  line-for-line match vs `es5506.cpp`.
- drifto94 ES5506 bank mapping and sample address math — verified against
  `ssv.cpp` ROM_START(drifto94) (no ROM_COPY aliasing for this title); RTL's
  `cfg_drifto94()` bank_valid/bank_map are consistent.
- SDRAM slot-timing arbiter — genuine round-robin, no accumulating stretch;
  flagged only as a low-priority secondary hypothesis if the symptom
  correlates with busy on-screen scenes specifically (not yet observed).

## Recommended fix (not yet implemented)

Add per-voice, per-register-group "host wrote a fresher value since this
voice's snapshot" tracking, and gate the plain/default and deferred
writeback paths in `ssv_es5506_regs.sv` on it:

1. On any `host_commit` for register X of voice V, set a 1-bit
   `host_fresh_X[V]` flag (13 flags × 32 voices, cheap fabric registers, not
   MLAB) — regardless of engine state.
2. When the voice engine's `S_START` snapshots voice V (new
   `eng_voice`/state==`S_START` cycle), clear all `host_fresh_X[V]` flags —
   the fresh regfile content is what got captured.
3. Gate every `we_accum`/`we_control`/`we_o*n*`/`we_lvol`/etc engine
   writeback (in both the plain path at `ssv_es5506_regs.sv:352-370` and the
   deferred `pend_*` replay at `:695-779`) on `!host_fresh_X[eng_voice]` for
   that field — if a host write landed after the snapshot, the engine's
   stale derived value must not overwrite it.

This is self-healing (flags always clear on that voice's next snapshot) and
purely additive — it never blocks a host write, only suppresses a stale
engine writeback that would otherwise clobber one.

## Fix implemented and verified — branch `fix/es5506-writeback-race`

Implemented exactly as designed above:

- `rtl/audio/ssv_es5506_voice.sv`: new output `eng_snap`, pulsed for the one
  `ce && (state == S_START)` cycle a voice's registers are actually latched
  (not merely while `state` holds `S_START` across sparse-`ce` cycles).
- `rtl/audio/ssv_es5506_regs.sv`: 13 per-voice "host wrote a fresher value
  since this voice's snapshot" flag vectors (one bit per voice per register
  group), set on any `host_commit` to that field, cleared on `eng_snap` for
  that voice (set wins a same-cycle race against clear — later nonblocking
  assignment in program order). All three engine-writeback paths (plain
  default path, and both `pend_*` deferred-replay capture sites) now gate on
  `!host_fresh_X[eng_voice]` before touching the register file.
- `rtl/ssv_core.sv`: wires `eng_snap` between the two module instances.

**Regression proof.** `verif/tb_ssv_es5506_regs.sv`'s existing "engine ACCUM
replay after host collision" case is a standalone regs-only unit test that
drives the engine side by hand (no `ssv_es5506_voice.sv` instantiated) — so
it doesn't naturally pulse `eng_snap`, and initially caught a real testbench
gap the new port exposed: it failed (`got 38943000 expected deadbeef`)
because the ACCUM host write earlier in the test never got cleared without
a manually-driven snapshot pulse. That is exactly the class of bug this fix
targets, reproduced directly. Added the missing `eng_snap` pulse (modeling
the free-running engine visiting that voice at least once between the setup
write and the collision test, as real hardware would) — this is legitimate
testbench maintenance for a newly added port, not a weakened assertion; the
collision scenario's actual pass/fail check (`expect32(... 32'hdead_beef)`)
is untouched.

All three ES5506 unit testbenches pass after the fix, run directly against
Verilator-compiled binaries (bypassing this session's flaky
`run_audio_sims.sh`/safe-verilator queue wrapper, which was returning
before its own builds finished — a tooling issue, not a test result):

```
tb_ssv_es5506_regs  : PASS tb_ssv_es5506_regs
tb_ssv_es5506_voice : PASS tb_ssv_es5506_voice semantics
tb_ssv_es5506_ulaw  : PASS tb_ssv_es5506_ulaw: MAME equation samples
```

Full `ssv_core` (31-module elaboration including the new `eng_snap` port
wiring end to end) compiles clean with no width/pin-mismatch errors.

**Not yet run this session:** a drifto94 gameplay/audio lockstep pass and a
fresh MAME-vs-RTL audio A/B capture of the name-entry music, to confirm the
fix is audible in practice and there's no regression in frame-CRC gameplay
parity. Recommend running `verif/run_all_focused_no_rbf.ps1` and a drifto94
lockstep before merging, and re-listening to the name-entry guitar line on
real hardware or in the MiSTer preview.

## Differential audio capture (supplementary)

MAME 0.289 reference capture of drifto94 name-entry music (400-frame
`gameplay_neutral` scenario) was taken:
`sim_output/diff/drifto94-audio-mame400/mame-audio.wav` (48 kHz stereo,
16.58 s). Music onset ≈1.5 s; spectral peaks logged at t=2-8s show a
descending/varying fundamental (~2.1 kHz → ~58-93 Hz + harmonics) consistent
with a bass/guitar line. An equivalent RTL headless capture
(`sim_output/diff/drifto94-audio-rtl400/rtl-audio-s16le.pcm`) was started
this session but not completed before the code-level race was confirmed
sufficient to explain the symptom; finishing it and doing a sample-accurate
compare is good follow-up evidence before/after the fix, not required to
identify the root cause.
