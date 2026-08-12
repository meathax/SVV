# Verification plan

The attainable behavioral target and permanently unavailable PCB evidence are
defined in [REFERENCE_PROFILE.md](REFERENCE_PROFILE.md).  Hardware and Quartus
gates remain recorded even when unavailable; they are not silently converted
to passes.

## Success definition

A scenario passes only when:

- reference and RTL identities are pinned;
- both sides are independently deterministic;
- every compared domain has a proven observability contract;
- strict normalized event streams match for the declared interval;
- configured output artifacts match under documented transforms;
- no earlier unresolved divergence is skipped;
- regressions pass;
- any required implementation/hardware gates pass.

## Scenarios

| Scenario | Start anchor | Stop anchor | Input file | Strict domains | Artifacts | Release gate |
|---|---|---|---|---|---|---|
| boot | reset_assert | first_fetch | scenarios/boot.input.jsonl |  |  | NO |
| attract | reset_assert | attract_checkpoint |  |  |  | NO |
| gameplay | named checkpoint | named checkpoint |  |  |  | NO |

## Milestone regressions

Run the complete serialized, headless focused gate without Quartus or RBF generation with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File verif/run_all_focused_no_rbf.ps1
```

The runner fails on the first unsuccessful stage and writes a machine-readable
receipt under `sim_output/receipts/`. Use `-DryRun` to inspect the exact command
sequence without starting any simulator.

| ID | Subsystem | Failure protected against | Command/task | Status |
|---|---|---|---|---|
| R001 | reset/clock |  |  | NOT CONFIGURED |

## Reset and initialization matrix

Test relevant combinations of:

- cold/power-on reset;
- warm/core reset;
- ROM download then reset;
- multiple seeds/initial values;
- short/long reset duration;
- independently phased clocks where appropriate.

A passing two-state simulation does not close reset/X-state risk by itself.

## Output artifacts

### Video

Define active crop, orientation, pixel format, frame/line range, border policy and hash method. Compare earliest differing frame, then line/region/pixel.

### Audio

Define sample rate, width, signedness, channel mapping, warm-up/latency alignment and comparison method. Prefer command/device-event checks before waveform correlation.

### State

Define exact memory/register regions, width/endian transform and capture phase.

## Quartus gates

| Gate | Requirement | Status |
|---|---|---|
| Analysis & Synthesis | configured and clean enough for policy | NOT RUN |
| Resource budget | within project limits | NOT RUN |
| Unconstrained paths | none unless justified | NOT RUN |
| Setup slack | meets configured threshold | NOT RUN |
| Hold slack | meets configured threshold | NOT RUN |
| Fresh RBF | full compile output verified | NOT RUN |

## Hardware gates

| Test | Build/revision | Procedure/input | Expected evidence | Status |
|---|---|---|---|---|
| cold boot |  |  |  | NOT RUN |

## Release scenarios

List scenarios explicitly in `.mister/project.json`. Absence of a configured release scenario is a block, not an implicit pass.
