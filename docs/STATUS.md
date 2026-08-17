# Project status

## Current objective

Freeze a trustworthy nine-set differential baseline and close the active
Dyna Gear CPU-data divergence before cross-side pinned MAME 0.289 versus
headless-Verilator qualification.

Gameplay-convergence plumbing is now implemented: the shared scenario format
and immutable packet journals are in `tools/ssv_gameplay_scenario.py` and
`verif/scenarios/*/gameplay_neutral.json`. No set is qualified until the cold
same-side and 120-frame neutral-soak gates in
[`GAMEPLAY_CONVERGENCE.md`](GAMEPLAY_CONVERGENCE.md) pass.

| Field | Value |
|---|---|
| Profile | One `Arcade-SSV` model/RBF; descriptor-selected games only |
| Sets | Dyna Gear, Vasara, Vasara 2, Change Air Blade, Drift Out '94, Storm Blade, Twin Eagle II, Ultra X, Survival Arts (USA) |
| Static hardware audit | No major supported-game block missing |
| Differential path | Source-integrated headless RTL host, shared-journal MAME adapter, strict comparator |
| Candidate strict domain | `cpu_data`; `mainbus` remains diagnostic because fetch granularity differs |
| Current active divergence | Fresh full Dyna pair (`goal-dynagear-mame-a` vs `goal-dynagear-rtl-b`) matches through strict `cpu_data` ordinal `535665`. MAME is at `PC=0x00F10575` performing an idle read at `0x000000`; RTL event sequence `583729` writes `0x0100` to work RAM `0x007908` (BE2). A bounded RTL causal window shows the same write sequence immediately after a level-3 VBlank request/acknowledge and handler entry `0x00F11124`. This is the current inferred natural CPU-throughput/IRQ-phase blocker; no RTL patch is selected. Full evidence: `docs/debug/DYNAGEAR_FRESH_EVIDENCE_20260816.md`. |
| MAME 0.289 same-side status | Two cold barrier/journal captures are byte-identical for the previous eight sets through their gameplay/120-frame stops. Survival Arts is newly integrated but has no same-side capture yet. Two cold strict `cpu_data` windows pass for every previously captured set; Dyna's current strict-only pair covers the full 941-frame journal run and emits 65,275 bounded transactions for frames 841–843 with identical trace/receipt hashes. The native Windows PowerShell runner selects a compatible UTF-8 receipt encoding. |
| Verilator in this readiness turn | Dyna's fresh full RTL replay reaches all 941 frames with zero drops/renderer overruns and the native RGB stream still matches MAME in the established gameplay/soak window, but the fresh streaming strict comparator exposes the ordinal-535665 CPU/IRQ mismatch. Direct input vectors pass; isolated system-only and player-only journals pass with zero watchdog resets. The combined control journal now passes with exactly one manifest-declared watchdog reset in the Test/service transition window, matching MAME's reset-image CRC transition. A short cold-boot smoke also completes Dyna Gear, Cairblad, Vasara, Vasara 2, and Drift Out '94 with zero renderer overruns; Storm Blade stops at its existing video-enable boot gate, so this is not complete nine-set qualification. Survival Arts has not yet had a real-ROM Verilator replay. ES5506 register/µ-law/voice vectors pass on a fresh rerun. An explicit audio-isolation diagnostic proves nonzero ES5506 output with zero sample underruns, but the normal 120M-cycle real-ROM gate still stops at renderer ownership and the full Dyna PCM remains zero because CPU cadence has not reached the sound programming stream. No game is qualified. |
| Same-side IRQ cadence checks | The headless bench now rejects duplicate VBlank handler entries universally. Dyna's opt-in `+ASSERT_IRQ_CADENCE` smoke passed 20 frames with one level-3 entry per completed VBlank; Cairblad's four-frame diagnostic boot passed the no-duplicate check with the pre-existing nonblack gate disabled because its CPU had not begun retiring. |
| Quartus/RBF in this readiness turn | Fresh Quartus 17.0.2 Lite Analysis & Synthesis/map and Fast Fit passed on 2026-08-18; no assembler/RBF or standalone STA rerun |
| Hardware in this readiness turn | NOT RUN |

## Latest build checkpoint

The clean tracked RTL at `91a9e31` was rebuilt with the universal
`Arcade-SSV` revision after the rejected exact-successor-metadata experiment
was reverted. Analysis & Synthesis/map completed with exit code 0, followed by
Fast Fit exit code 0 and zero Quartus errors. The fit summary reports 40,001 /
41,910 ALMs (95%), 25,994 registers, 517 / 553 RAM blocks (93%), 4,248,848 /
5,662,720 block-memory bits (75%), 44 / 112 DSP blocks (39%), and 3 / 6 PLLs
(50%). Placement and routing succeeded; the router reported 35% average and
60% peak interconnect usage. The authoritative receipts are retained under
`.codex-mister-build/Arcade-SSV/20260818-042906-131-map/` and
`.codex-mister-build/Arcade-SSV/20260818-043408-960-fit/`.

This is a synthesis/fit checkpoint only. It does not claim standalone
TimeQuest closure, a fresh compressed RBF, or physical MiSTer validation.

## Baseline boundary

Pre-readiness SHA-256 fingerprints were recorded for the dirty RTL, descriptor,
harness, MAME adapter and configuration inputs on 14 August 2026. Existing V60
multiply, EEPROM, address-width and renderer optimizations remain user changes;
they must complete their focused regressions before this source is promoted to
the frozen differential baseline. No additional resource optimization should
be stacked until then.

## Evidence reconciliation

Historical Vasara 2 records disagreed: older aligned CRC evidence reported a
visible attract logo while a stale strict 360-frame gate reported black RTL.
The current fix5 pair reaches gameplay entry and the 120-frame neutral soak in
both cold runs; its final native RGB CRC matches the pinned MAME reference.
The initial frame/epoch offset and strict CPU-data comparison remain open, so
this is gameplay readiness evidence, not equivalence qualification.

## Next valid action

Measure or schedule the natural VBlank-to-CPU cadence before editing RTL. The
cursor-483 cold MAME falsification shows that the active cursor-482 state is
not a removable frame-label translation. If evidence selects a clock/IRQ
producer, make one shared, descriptor-independent correction and rerun the
Dyna causal window plus all nine V60-dependent sets.
Do not patch a later RAM write, delay an IRQ arbitrarily, or use a frame offset
while the PCB phase remains unknown.
