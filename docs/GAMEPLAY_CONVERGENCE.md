# Nine-set gameplay convergence

This record is the implementation ledger for the gameplay gate. A scenario is
not qualified until two cold MAME captures and two cold headless RTL captures
are identical within each producer, reach a verified gameplay marker, consume
the same journal, and sustain 120 native neutral frames. The current scenario
files are intentionally marked `pending_live_validation`; their entry frame is
a bounded starting hypothesis, not an acceptance result.

| Set | Scenario | Entry target | Current state | First evidence target |
|---|---|---:|---|---|
| Dyna Gear | `verif/scenarios/dynagear/gameplay_neutral.json` | 820 | fresh full MAME/RTL receipts are complete and deterministic within each producer; the streaming strict comparator matches through ordinal 535665, then MAME is idle at `PC=0xF10575` while RTL writes `0x0100` to `0x7908` (BE2), with a bounded RTL window showing the VBlank level-3 handler as the producer. Native RGB CRC streams still match for gameplay/soak frames 820–940, but CPU/IRQ equivalence is open. Direct input, system-only, and player-only control gates pass; the combined control matrix passes with one explicit expected watchdog reset in the Test/service transition window, matching MAME's reset-image CRC transition. ES5506 unit vectors pass, while real-ROM audio remains open. No RTL change selected | natural VBlank/CPU cadence, common V60/video, extra RAM, read watchdog, ES5506 bank 2 |
| Vasara | `verif/scenarios/vasara/gameplay_neutral.json` | 260 | two cold RTL receipts/frame/state/audio/PPM artifacts are byte-identical; 381/381 frames and neutral soak pass; visual stream is one initial frame ahead and strict `cpu_data` first differs at ordinal 68 (`0x00330E`, MAME `1` vs RTL `0`) | two sample banks and system input wiring |
| Vasara 2 | `verif/scenarios/vasara2/gameplay_neutral.json` | 260 | two cold RTL receipts/frame/state/audio/bounded-trace artifacts are byte-identical; 381/381 frames and 120-frame neutral soak pass; final native RGB CRC matches MAME reference | resolve strict cross-side CPU-data window and initial frame alignment |
| Change Air Blade | `verif/scenarios/cairblad/gameplay_neutral.json` | 820 | pending marker; historical phase boundary at frames 12–14 | identity tiles, inverted lockout, 64 KiB NVRAM, 338-pixel geometry |
| Drift Out '94 | `verif/scenarios/drifto94/gameplay_neutral.json` | 820 | pending marker; live-race path and ST010 phase remain open | redundant byte read and random-window classification |
| Storm Blade | `verif/scenarios/stmblade/gameplay_neutral.json` | 260 | pending marker; first known strict mismatch at frame 6 | ST010 host/program/data ordering, 24 MiB graphics |
| Twin Eagle II | `verif/scenarios/twineag2/gameplay_neutral.json` | 260 | pending marker; boot alignment and palette-write semantics open | ST010, IRQ1, extra RAM and four ES5506 aliases |
| Ultra X | `verif/scenarios/ultrax/gameplay_neutral.json` | 260 | pending marker; state difference appears near frame 2 | IRQ1, extra RAM and 12 MiB modulo graphics |
| Survival Arts (USA) | `verif/scenarios/survartsu/gameplay_neutral.json` | 820 | pending marker; descriptor and six-button journal path added, live attract/gameplay capture not yet run | 24 MiB graphics, `ADD_BUTTONS` B4-B6, extra RAM and read watchdog |

The compiled journals are generated under `sim_output/gameplay_journals/` and
are never tracked. Both adapters consume the same directory packets; the RTL
runner inverts the active-high logical masks at the testbench boundary to the
core's active-low input pins.

The supplied MAME 0.289 headless adapter has two cold, byte-identical full
barrier/audio receipts for the previous eight sets. Survival Arts is now in the
scenario matrix but has no gameplay capture yet. Matching two-cold strict
`cpu_data` windows around each gameplay-entry barrier also pass with zero drops
and identical canonical digests for the previously captured sets. Dyna's current strict-only pair covers the full
941-frame scenario while emitting the bounded native 841–843 window; the
cross-side receipt is intentionally a mismatch at the active earliest target
(`docs/debug/DYNAGEAR_FRESH_EVIDENCE_20260816.md`). The low-volume control
adapter uses independently closed barrier-record files because MAME's mixed
low-volume Lua stream can contain a deterministic sparse NUL hole; the merged
receipt is accepted only after all 341 frame records and the complete receipt
parse successfully.
Full scenario captures cover Twin Eagle II and
Ultra X (381 packets through gameplay entry plus the 120-frame neutral soak);
their earlier 80-emulated-frame `missing_video_epoch` results were only a
short-window artifact, not an RTL verdict.

The empty-cache path that caused the first cold RTL smoke's shared sprite
line-pool ownership/overflow failure is now guarded and has a focused
regression. Dyna, Vasara and Vasara 2 now have receipt-validating two-cold RTL
pairs; none is qualified until its strict cross-side comparison and earliest
divergence gate pass.
