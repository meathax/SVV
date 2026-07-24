# SSV core-issue differential debugging method

This is the governing debugging procedure for the SSV core. It adopts
`D:\Arcade\AI\core-issue-difftest-method.md` and maps that procedure to this
repository's MAME, Verilator, GTKWave, Quartus, and MiSTer tools.

The required outcome is a reproducible statement:

> MAME and RTL match through event N. At N+1, path X produces A in MAME and B
> in RTL. Module Z causes the mismatch, regression R proves it, and patch P
> corrects it.

## Governing principles

1. Reproduce before editing, using the same ROM, configuration,
   initialization, and frame-indexed inputs.
2. Treat MAME as an architectural reference, not a V60 timing oracle. Compare
   retirements, registers, PSW, exceptions, and observable bus effects.
3. Find and solve the first divergence. Later differences are downstream
   noise.
4. Descend the comparison ladder only as far as needed.
5. State one testable root-cause hypothesis before editing RTL.
6. Apply the smallest justified fix and add a regression.
7. Finish with a timing-qualified build and real-MiSTer validation.

## Existing infrastructure to reuse

- `verif/tb_ssv_realrom_boot.sv`: deterministic Dyna Gear ROM boot and
  architectural tracing.
- `verif/tb_ssv_realrom_video.sv`: long graphics-aware real-ROM regression.
- `tools/mame-capture-ssv-writes.lua` and
  `tools/compare-ssv-write-traces.py`: ordered accepted board writes.
- `tools/compare-v60-pc-traces.py`,
  `tools/compare-v60-state-traces.py`, and
  `tools/compare-v60-hash-traces.py`: V60 retirement comparisons.
- `tools/extract-v60-irq-schedule.py`: deterministic reference IRQ schedule.
- `tools/mame-capture-es5506.lua` and `tools/decode-mame-es5506.py`: ES5506
  semantic trace foundation.
- Focused subsystem benches under `verif/`.
- Verilator and GTKWave MCP for narrow proof around a known divergence.
- MiSTerClaw for load, input, capture, and hardware verification.
- `tools/build-ssv.ps1`, `tools/report-quartus.ps1`, and
  `tools/deploy-ssv.ps1`: release gates.

Scratch traces, screenshots, waveforms, binaries, and logs belong under
`scratch/` or ignored `sim_output/`. Permanent scenarios and regressions belong
under `verif/`; issue reports belong under `docs/issues/`.

## Per-issue workflow

### 0. Issue contract

Record the set/MRA/ROM identity, symptom, correct MAME behaviour, shortest
reproduction, affected platforms, objective pass/fail condition, and unknowns.
Split symptoms if evidence shows different first divergences.

### 1. Deterministic scenario

Define one input schedule for both runners under `verif/scenarios/`. Inputs use
emulated frames or shared architectural boundaries, never wall time. Record
ROM SHA-256, MAME version, DIP settings, isolated NVRAM/config policy, RAM
initialization, input edges, and stop condition.

Run each side twice and require identical local hashes/events before comparing
them. Use randomized RTL initialization where practical; a zero-init-only pass
indicates a reset defect.

### 2. Behavioural boundary

Use screenshots, frame CRCs, or short summaries to identify:

- the last matching frame/event;
- the first differing frame/event;
- the first subsystem or object that becomes wrong.

Visual evidence brackets a defect; it does not prove its cause.

### 3. Comparison ladder

1. Frame/state summary.
2. Semantic writes to the relevant RAM, palette, sprite, sound, or I/O range.
3. CPU retirement aligned by retirement sequence: PC, opcode, changed
   registers, PSW, exception/interrupt, and instruction-attributed writes.
4. Accepted bus effects, preserving ordered writes, side-effecting reads, byte
   enables, endianness, and the V60's external 16-bit cycles.
5. Subsystem semantics: IRQ source/vector/ack, sprite fields, palette indices,
   graphics fetches, ES5506 registers, and PCM blocks.
6. A narrow FST waveform, approximately 2,000 relevant cycles before and 500
   after the proven first divergence.

Do not compare MAME and RTL V60 cycle counts. A timing-only discrepancy is
`TIMING_UNVERIFIABLE` until supported by chip documentation or hardware
evidence.

### 4. Efficient tracing

Long scenarios use per-frame rolling hashes, a bounded ring of recent detailed
events, and full tracing only inside the narrowed window. High-volume traces
use fixed records with schema/version headers.

Comparators must reject incompatible versions, stop at the first unexplained
divergence, distinguish missing/extra/reordered/wrong-data events, show
preceding context, and never silently suppress a mismatch.

### 5. Root-cause proof

Before editing RTL, write:

> Path X computes or writes Y incorrectly because Z. This predicts first
> divergent event E and downstream symptom S.

Inspect MAME and RTL, consult hardware documentation where required, and add a
directed test or assertion that fails on the old design. A module remains a
`suspect` until a test or waveform proves responsibility.

### 6. Minimal correction

Do not patch game RAM, skip instructions, weaken comparisons, regenerate a
golden trace, or add a game-specific workaround. Correct the proven
architectural defect: CPU semantics, lanes, IRQ/exception behaviour,
accepted-transfer arbitration, reset state, or subsystem behaviour.

### 7. Verification gates

Run in order:

1. focused regression for the exact first divergence;
2. relevant subsystem suite;
3. V60 differential/random-seed tests if CPU RTL changed;
4. full repository regression;
5. fresh MAME and RTL traces with a passing comparator;
6. frame/visual evidence;
7. fresh Quartus build and `tools/report-quartus.ps1 -RequireReady`;
8. hashed MiSTer deployment and scripted hardware reproduction.

Never deploy a stale or timing-failing RBF.

### 8. Report proof and limits

Every issue report records:

```text
Issue:
Deterministic scenario:
Last matching event:
First divergence:
Root-cause hypothesis:
Evidence tier:
RTL change:
Focused regression:
Subsystem/full regression:
Fresh MAME-to-RTL result:
Quartus timing/result:
MiSTer result:
What this fix explains:
What this fix does not explain:
Artifacts:
```

## Evidence tiers

1. `CONFIRMED`: original-board logic-analyser or silicon evidence.
2. `DOCUMENTED`: schematics, service manual, or chip documentation.
3. `OBSERVED`: repeatable original-board or trusted hardware capture.
4. `MAME_ASSUMED`: MAME source or behaviour only.
5. `UNKNOWN`: insufficient evidence.

MAME is strong for visible CPU architecture, register effects, and software
paths, but weaker for exact V60 timing, contention, arbitration, and analog
output. Confirmed hardware takes precedence, with the deviation documented.

## Dyna Gear ladders

- CPU/game: frame → work-RAM field → update PC → retirement/registers/PSW →
  accepted write → focused CPU regression.
- Video: frame CRC → scanline → layer → sprite/tile/palette state → graphics
  fetch/index → mixer pixel → narrow waveform.
- Audio: V60 host write → page/register/voice → sample/loop → envelope/filter
  → PCM block CRC → sample comparison.
- IRQ: source → requested/enabled/priority → acknowledge/vector → handler
  retirement → clear/completion.

## Definition of done

An issue is complete only when it has a deterministic reproduction, documented
last match and first divergence, a focused before/after regression, a
correction explaining both divergence and symptom, passing subsystem/full
regressions, a fresh comparison at the required depth, and—where hardware is
in scope—a current timing-qualified RBF verified on MiSTer. Any remaining
symptom is stated explicitly.
