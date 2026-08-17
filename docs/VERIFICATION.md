# Verification plan

## Readiness gate

The differential infrastructure is source-integrated but not yet dynamically
qualified for release. This implementation turn ran strict headless
Verilator smoke lanes, focused V60 CPU regressions, Quartus Analysis &
Synthesis, and a full Quartus fit. Before the first cross-side comparison:

1. Run the static universal-profile, hardware-shape and differential-readiness
   audits.
   The pinned universal source set also passes the Slang SystemVerilog lint
   gate (0 errors; nine expected unconnected testbench ports).
2. Build one cold headless universal model with
   `tools/build_ssv_headless.ps1`; it forces timing, assertions, native UCRT64,
   `--threads 1`, `MISTER_DIFF_HEADLESS=1` and no display backend.
3. Capture two cold MAME 0.289 runs and two cold RTL runs for the same scenario.
4. Require byte-identical normalized traces within each producer.
5. Use `cpu_data` as the candidate strict projection; program-ROM device-1
   fetches remain diagnostic because MAME tap granularity differs from RTL
   64-bit V60 fills. `mainbus` is not an acceptance domain.

All traces require a stop barrier and complete zero-drop receipt. An invalid
descriptor, unimplemented V60 instruction, overlapping select, renderer
ownership violation or ES5506 underrun is a failed run with causal context.

## Eight Tier-1 scenarios

| Order | Scenario | Hardware emphasis |
|---:|---|---|
| 1 | Dyna Gear gameplay entry + 120 neutral frames | common V60/video, extra RAM, read watchdog, ES5506 bank 2 |
| 2 | Vasara gameplay entry + 120 neutral frames | two sample banks, write watchdog, system inputs |
| 3 | Vasara 2 gameplay entry + 120 neutral frames | same family with independent evidence |
| 4 | Change Air Blade gameplay entry + 120 neutral frames | identity tiles, inverted lockout, 64 KiB NVRAM, 338 pixels |
| 5 | Drift Out '94 gameplay entry + 120 neutral frames | ST010, 2 KiB NVRAM, random-read window |
| 6 | Storm Blade gameplay entry + 120 neutral frames | ST010, 24 MiB graphics, 352 pixels |
| 7 | Twin Eagle II gameplay entry + 120 neutral frames | ST010, IRQ1, extra RAM, four ES5506 aliases |
| 8 | Ultra X gameplay entry + 120 neutral frames | IRQ1, extra RAM, 12 MiB non-power-of-two graphics |

The exact order and scenario files live in `.mister/project.json`; the game
list itself remains authoritative only in `tools/ssv_supported_sets.py`.

## Commands

```powershell
python tools/verify_ssv_universal_profile.py --require-roms
python tools/verify_ssv_hardware_shapes.py
python tools/verify_ssv_diff_readiness.py
powershell -NoProfile -File tools/build_ssv_headless.ps1
powershell -NoProfile -File tools/run_ssv_mame_headless.ps1 -Set dynagear -ScenarioFile verif/scenarios/dynagear/gameplay_neutral.json -Session sim_output/diff/dynagear-mame-1
powershell -NoProfile -File tools/run_ssv_headless.ps1 -Set dynagear -Scenario gameplay_neutral -ScenarioFile verif/scenarios/dynagear/gameplay_neutral.json -Session sim_output/diff/dynagear-rtl-1 -SkipBuild
powershell -NoProfile -File tools/run_ssv_headless.ps1 -Set dynagear -Session sim_output/diff/irqassert-dynagear-final -Frames 20 -Scenario attract_idle -InputJournal sim_output/gameplay_journals/dynagear/gameplay_neutral -DiagnosticNoAttract -AssertIrqCadence -SkipBuild
python tools/compare_ssv_strict.py reference.jsonl candidate.jsonl --domain cpu_data
python tools/compare_ssv_strict_stream.py reference.jsonl candidate.jsonl --domain cpu_data --receipt-out sim_output/diff/strict-stream-receipt.json
```

The first three are static. The remaining commands belong to the next phase
and are not release qualification. The cadence smoke above passed with one
level-3 handler entry per completed VBlank interval; the corresponding
Cairblad diagnostic run used `-IgnoreNonblack` because its CPU remained in
boot, and passed the universal no-duplicate check. `+ASSERT_IRQ_CADENCE` is
scenario-qualified and must not be enabled blindly for every title.

Dyna Gear control evidence is split into independent cold journals so a
service/test mode transition is not confused with gameplay input: `system_matrix`
and `player_matrix` pass their RTL watchdog gates, and the combined
`control_matrix` passes with exactly one scenario-declared watchdog reset in
the Test/service transition window (MAME returns to its reset-image CRC in the
same window). The RTL gate still fails any extra reset or an out-of-window
reset. The direct `tb_ssv_input_matrix` passes all player/system/Test/Service
bit mappings.

The ES5506 register, µ-law, and voice vectors pass. The real-ROM audio gate is
not yet a release result: it stops at a renderer-ownership assertion before
the Dyna CPU reaches its sound programming stream, and the full Dyna PCM
capture remains zero pending the CPU/IRQ cadence repair.

Checkpoint/save builds are acceleration-only. Every accepted result requires
a matching timing-correct cold replay.

## Donor-derived V60 verification (2026-08-18)

The adjacent S32 V60 audit ported three shared hardware improvements into the
universal SVV CPU: request re-arm/held acknowledgement in the external bus
adapter, allowlisted execute-retire fetch-window overlap, and the RSR
non-sequential prefetch flush/old-ack guard. Focused post-change checks passed:
`V60 FRAME STACK PASS`, `AUDIT PASS`, `FETCH PERF PASS`, `V60 SMC PASS`, and
`V60 BUS LANES PASS`. A strict full SVV headless model also rebuilt before the
final RSR-only change; no game/MAME lane was resumed after the requested stop.

Quartus 17.0.2 Analysis & Synthesis after the RSR change passed with 0 errors
and 144 warnings: 70,291 implemented logic cells, 2,801 RAM segments, 44 DSP
elements, and 4 PLLs. A fresh full fit of the same source state then passed
with 0 errors and 12 warnings: 40,001/41,910 ALMs (95%), 517/553 RAM blocks
(93%), 44/112 DSP blocks, and 3/6 PLLs. Placement, routing, post-fit delay
annotation, and fitter timing analysis completed successfully. No standalone
STA, assembler, RBF generation, or real-MiSTer hardware test was run in this
turn; the existing STA report is older than this fit and is not a current
sign-off result.

## Quartus and hardware gates

The fit above is not a final timing/RBF verdict. TimeQuest signoff, assembler,
RBF generation, and real-MiSTer hardware validation remain pending.
