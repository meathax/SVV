# Dyna Gear CPU-data decision record — 2026-08-15 (superseded)

> Historical record. The unaligned `0x78EC` window is no longer the active
> divergence. See `DYNAGEAR_IRQ_CADENCE_DECISION_20260815.md` for the sole
> corrected target and current evidence gate.

## Observation

After aligning the RTL pre-frame-boundary window with the corresponding MAME
post-frame-boundary window (`post_epoch_frames 839..841` versus RTL frames
840..841), the first strict `cpu_data` mismatch is later in the common V60
update block.  The first 21 comparable device events match; the first bad
event is a work-RAM write at `0x0078EC`:

| event | MAME 0.289 | RTL |
|---|---:|---:|
| address | `0x0078EC` | `0x0078EC` |
| write data | `0x5100` | `0x1100` |
| byte enable | `0b10` | `0b10` |
| device | work RAM (2) | work RAM (2) |

Both sides report `PC=0x00F11124` and the same word lane.  MAME samples this
event at scanline 0 immediately after its frame boundary; RTL samples it at
scanline 240 immediately before its corresponding boundary.  The comparison
is strict and has not been resynchronised or masked.  The older `0x7904`
`0x7500`/`0x7B00` result came from an unaligned MAME-only window and is retained
as diagnostic history, not the active target.

## Evidence

* Two cold RTL captures are byte-identical (receipt, state, frame, PCM and
  native PPM artifacts); both complete 941 frames with zero drops and no
  renderer/watchdog failure.
* Two cold MAME captures are byte-identical.  The strict MAME window is also
  byte-identical across its pair.
* The optional MAME instruction-boundary probe records `TESTB` at `0xF10575`
  followed by `0x64` at `0xF1057B`.  The RTL retirement stream contains the
  same pair when the trace window includes the preceding scanline; the initial
  apparent missing `TESTB` was a trace-window boundary artifact.
* A read-only MAME register probe at the first bad `PC=0xF11124` records
  `PSW=0x90000001`, `R2=0xFFFF7BFA`, and `R23=5201` before execution.  RTL's
  equivalent pre-execution retirement snapshot records the same PC/PSW but
  `R2=0xFFFE7BFA` and `R23=5393`.  The earlier CPU-state difference proves
  that the bad RAM value is not a renderer-only symptom.  The probe's old
  `R29..R31` labels were invalid because MAME exposes those aliases as
  `AP/FP/SP`; the Lua probe has been corrected and a fresh alias-qualified
  capture is required before interpreting those three fields.
* Pinned MAME source calls `debugger_instruction_hook(PC)` before executing
  each V60 instruction and implements `TESTB` in `op3.hxx` as a read-only
  operand test.  The RTL dispatch includes `0xF0..0xF5` in the short-format
  path and its `exec_op` implements the same flag update.

## Hypotheses and falsification

1. **Unimplemented TESTB or incorrect TESTB flags.**  Falsified for this
   event: both instruction streams contain `F0`; the state probe and retire
   records are sampled at different points and therefore do not establish a
   same-PSW claim.
2. **Shared V60 architectural state drift before the write.**  Active
   hypothesis: the same pre-execution PC/PSW has different R2/R23 values, so
   the producer's arithmetic or prior interrupt/stack state diverged before
   the first bad bus event.  It requires one earlier register-producing event,
   not a game-specific write patch.
3. **MAME bus-tap PC sampling is not instruction-equivalent.**  Plausible:
   the first writes occur before the Lua ROM tap reports the corresponding
   opcode-fetch event, so `state["PC"]` and tap order cannot yet prove the
   producer instruction.
4. **Frame/scanline capture phase only.**  Insufficient: the data value itself
   differs in a strict ordinal match; no timing exception permits changing a
   pushed architectural return address.

## Selected explanation

No causal explanation is selected.  The evidence blocker is the missing
earlier register-producing event (and a fresh alias-qualified AP/FP/SP probe).
The current record remains the sole active divergence; no synthesizable RTL
change is justified.

## Smallest change

None.  Only simulation-only observability was added: an opt-in MAME
`v60_instruction` event and an `instruction_pc` field on diagnostic bus events.
Normal canonical captures are unchanged.

## Verification and regression scope

The probe run used the cold Dyna Gear gameplay journal, pinned MAME 0.289,
isolated NVRAM/config/state directories, and the strict post-epoch 840–841
window.  It completed with a stop barrier, zero drops, and the declared 941
frames.  Re-run the two cold Dyna captures after any eventual CPU fix, then
rerun every common V60/stack dependent set before accepting it.

## Known unknowns / next experiment

The next read-only experiment must emit alias-qualified MAME architectural
state at the preceding V60 instruction boundaries and pair it with the RTL
retirement/register context.  Until the first causal producer is isolated, do
not change return-PC arithmetic, prefetch timing, IRQ timing, or bus PC
labeling.
