# Dyna Gear fresh evidence — 2026-08-16

This record supersedes the older bounded ordinal-21 statement for the fresh
full gameplay pair. It does not claim MAME/RTL equivalence.

## Paired gameplay contract

- MAME 0.289 SHA-256:
  `af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3`.
- Scenario: `verif/scenarios/dynagear/gameplay_neutral.json`, journal SHA-256
  `8396230ffcefd1dc5d7c28bb9391b938c6293b6dd78b9a57daecaa260ab9fcc4`.
- MAME receipt: `sim_output/diff/goal-dynagear-mame-a/mame-trace.jsonl`,
  complete 941 frames, zero drops, `cpu_data=18,637,559`, file SHA-256
  `1291e63b402d53c69304ede09f61454ad03d491f4f2f470d00879144ba1ee3f1`.
- RTL receipt: `sim_output/diff/goal-dynagear-rtl-b/rtl-receipt.json`,
  complete 941 frames, zero drops, file SHA-256 of the canonical trace
  `f71af953c6fb024ed5c323f9f59af79f7348d61be8d68a886045b9c69b613ebd`.
- Streaming comparator receipt:
  `sim_output/diff/goal-dynagear-cpu-data-stream-receipt.json`.

## Active earliest divergence

The strict projection is `cpu_data_lane_mask_v1`, ordinal comparison with no
resynchronization. The complete fresh comparison matches through ordinal
`535665` and then diverges:

- MAME: `PC=0x00F10575`, idle read at address `0x000000`, byte enable 1,
  data 0, native frame 21.
- RTL: canonical event sequence `583729`, write at work RAM address
  `0x007908`, byte enable 2, data `0x0100`.

A bounded non-strict RTL causal window independently shows the same operation
shape immediately after a level-3 VBlank request/acknowledge at the idle-loop
PC: the handler stack/context writes begin at `0x007908` before execution
continues at handler PC `0x00F11124`. This identifies CPU/IRQ cadence as the first causal
producer, not a renderer crop or RAM mask. No RTL correction is selected:
the exact V60 wait-state and VBlank phase evidence needed to change shared CPU
timing is still missing.

## Simulation-only cadence falsification sweep

The testbench-only `+CPU_INC_OVERRIDE` probe in `verif/ssv_tb_ce_cpu.sv` was
used to vary the CPU enable without changing production RTL or the canonical
golden. A quick ordinal comparison against the pinned MAME trace produced the
following first mismatches:

| Override | Matching prefix | Ordering at first mismatch |
|---:|---:|---|
| 21,701 (canonical) | 535,665 | RTL handler write before MAME idle read |
| 18,000 | 537,565 | RTL handler write before MAME idle read |
| 17,900 | 534,841 | RTL handler write before MAME idle read |
| 17,950 | 536,203 | RTL handler write before MAME idle read |
| 17,975 | 536,884 | RTL handler write before MAME idle read |
| 17,750 | 540,200 | MAME handler write before RTL idle read |
| 17,500 | 540,200 | MAME handler write before RTL idle read |
| 17,000 | 540,200 | MAME handler write before RTL idle read |
| 16,000 | 540,200 | MAME handler write before RTL idle read |

The crossing and non-monotonic phase sensitivity support cadence as a real
contributor, but no override closes the strict stream and none proves the
physical board's wait-state/phase contract. The override remains diagnostic
only; no production clock or IRQ value was changed.

The separately validated `+IRQ3_DELAY_SYS` probe reaches the same controller:
ten system-clock edges are below one meaningful CPU-retire phase and leave the
handler entry unchanged; 200 edges shift each handler entry by ten RTL
retirements. The 23-frame strict run with the large delay still first differs
at ordinal `535670` (MAME idle read versus the RTL handler stack write), so
phase perturbation is contributory but not a justified RTL correction. The
reviewed exception record is
[`DYNAGEAR_MAME_TIMING_EXCEPTION_20260816.json`](DYNAGEAR_MAME_TIMING_EXCEPTION_20260816.json).

## Controls and DIPs

- `verif/test_ssv_mra_dips.py`: PASS, including the Dyna Gear DIP defaults,
  all controls, and the adapter Test bit (`SYSTEM` mask `0x10`).
- `sim_output/diff/input-matrix-goal/run.log`: PASS for every direct player,
  system, rapid-fire, Service, and Test port bit.
- System-only journal (`system_matrix`, SHA-256
  `e67e335a3ef833f2dcc21735e58ade2a65067045a6f6b07774217c022682bac2`): MAME
  sidecar receipt and RTL 181-frame replay pass with zero watchdog resets.
- Player-only journal (`player_matrix`, SHA-256
  `b5be11e9729a2b0ff324b1ebcc1b96d946eec02d27258187ee43055f2666798f`): RTL
  341-frame replay passes with zero watchdog resets.
- The combined `control_matrix` now has an explicit expected transition:
  `expected_watchdog={resets:1,min_post_video_frame:220,max_post_video_frame:245}`.
  MAME returns to its reset-image CRC in the corresponding window, and the
  rebuilt RTL gate passes exactly one watchdog reset at post-video frame 221,
  then resumes and completes all 341 frames with zero renderer overruns and
  no additional reset. The watchdog remains strict for every scenario whose
  manifest expectation is zero.

Control receipt fingerprints:

- MAME trace SHA-256: `C31D48680A148232F4C02C37697C69A04C60D1E0B153BA1EF8860F314A5029BC`;
  receipt SHA-256: `843EDA7DC773B1E3C6B7EC898DB78500DD781DFB2CD1DC87B1558C48E4F969CC`.
- RTL trace SHA-256: `204555E6E46E5065954393294FF93B68DD0D30FB8399B7F79705317DB3DB2D18`;
  receipt SHA-256: `94ABCB26B790DAC72B586410094960159D617B1BA4AD97B69BFA7B8852ECEB14`.
- RTL receipt is complete, zero-drop, 341 native frames, and carries the same
  expected watchdog declaration; the trace contains the single reset event at
  cycle `197068830`, post-video frame `221`, followed by reset epoch `1`.

## Post-watchdog regression checks

The rebuilt headless model also completed four cold frames for Dyna Gear,
Cairblad, Vasara, Vasara 2, and Drift Out '94 with zero renderer overruns and
zero watchdog resets.  Cairblad required the declared diagnostic exception for
the post-video nonblack gate because its CPU had not yet begun retiring.  The
same four-frame smoke reached the existing Storm Blade failure
(`video-enable write never accepted`) before its boot milestone; this is not
counted as an eight-set qualification.  The later-set short-budget result is
therefore retained as boot evidence only.

The independent ES5506 register, µ-law, and voice semantic suite was rerun with
the rebuilt model and passed all three benches (`UNIT_ONLY=1
bash verif/run_audio_sims.sh`).

The shared V60 directed suite also passed all 32 benches, including the
fetch-wide, bus-lane, SMC, frame-stack, DIVX, decimal/string, FP, and opcode
audit cases.  These are functional CPU regressions; they do not prove the
unresolved board-level VBlank cadence.

## Audio

The ES5506 register, µ-law, and voice semantic vectors pass. The 120M-cycle
real-ROM audio gate fails earlier at the existing renderer-ownership assertion;
the fresh 941-frame RTL PCM is all zero because the CPU/IRQ divergence has not
yet reached Dyna Gear's ES5506 programming stream. End-to-end sample-accurate
audio remains open in the normal full-core gate.

An explicit `AUDIO_ISOLATION_DIAGNOSTIC=1` rerun allows that simulation-only
renderer deadline fatal to report and continue, without relaxing the ES5506
checks. It completed 120,000,000 cycles with 2,448 host writes, 612 commits,
46,720 sample requests, 93,440 acknowledgements, 77,608 sample ticks, zero
underruns, 93,440 nonzero sample words, and `audio_peak=26833`. This proves
nonzero ES5506 audio and zero sample underruns in isolation; it does not close
the full-scene video/CPU-cadence gate because the renderer deadline remains
violated in that run.

The completed diagnostic log is
`C:\msys64\tmp\ssv-audio\boot\diagnostic-run.log` (SHA-256
`8305BD2A5EB31DED5E2BAAEF2A13C92B04E2E0F5C88D39ABB23099B4652000BA`). A
fresh default four-frame Dyna Gear strict smoke also passed with zero renderer
overruns and zero watchdog resets; this is only a short smoke and does not
replace the unresolved full-run divergence.

Quartus/RBF construction and physical MiSTer testing were not run.
