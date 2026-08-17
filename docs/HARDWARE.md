# Hardware truth model

This project currently targets pinned MAME behavior where qualifying PCB
measurements are unavailable. MAME is an evidence tier, not a claim of
nanosecond-exact physical behavior.

## Universal board shape

| Function | Shared RTL | Selection | Evidence/status |
|---|---|---|---|
| Main CPU | `rtl/cpu/v60/s32_v60.sv` | always present | MAME V60 source and real-set execution; retirement phase still diagnostic |
| Video | `rtl/video/*`, `ssv_video_timing` | descriptor geometry/tile mode | MAME SSV driver/video source; palette/renderer timing remains reference-sensitive |
| Audio | `ssv_es5506_regs`, `ssv_es5506_voice` | descriptor sample banks/aliases | MAME ES5506 plus focused source-derived tests; waveform equivalence pending |
| ST010 | `upd96050_st010`, shared program fetcher | `cfg.has_st010` | MAME SSV/uPD96050 maps for Drift Out, Storm Blade and Twin Eagle II |
| IRQ/watchdog | `ssv_irq`, `ssv_core` | descriptor IRQ/watchdog mode | MAME maps and machine configuration |
| Work/sprite/palette/extra RAM | shared core memories/SDRAM windows | descriptor geometry/mode | MAME address maps and release descriptors |
| NVRAM/inputs | shared runtime-selected windows | descriptor mode/polarity | MAME maps/input ports and generated MRAs |

No qualified behavior is selected by a compile-time game name and there is no
per-game RBF. Optional devices remain single shared instances.

## Qualified family matrix

| Set/family | Required variant behavior |
|---|---|
| Dyna Gear | extra RAM, read watchdog, ES5506 bank-2 mapping |
| Vasara / Vasara 2 | two sample banks, write watchdog, system-input wiring |
| Change Air Blade | identity tile mapping, inverted lockout, 64 KiB NVRAM, 338-pixel width |
| Drift Out '94 | ST010, 2 KiB NVRAM, random-read window |
| Storm Blade | ST010, 24 MiB graphics, 352-pixel width |
| Twin Eagle II | ST010, IRQ1, extra RAM, four ES5506 aliases |
| Ultra X | IRQ1, extra RAM, 12 MiB non-power-of-two graphics, no ST010 |

## Explicit uncertainties

| ID | Classification | Unknown | Rule |
|---|---|---|---|
| U1 | HYPOTHESIS | Drift Out random-read electrical/model behavior | Do not change until it is the active first divergence |
| U2 | HYPOTHESIS | Exact ST010 oscillator/instruction cadence | Keep current descriptor-shared clock pending causal evidence |
| U3 | HYPOTHESIS | Palette write visibility versus MAME frame snapshot | Diagnose only after earlier CPU/bus causes close |
| U4 | HYPOTHESIS | Renderer ownership/deadline behavior under long lists | Fail on ownership violations; do not mask late completion |
| U5 | INFERRED | FAST_IFETCH normalization against MAME program taps | Keep `v60_ifetch` diagnostic until sampling proof exists |

## Observability mapping

`ssv_core` exposes a synthesis-excluded verification interface for completed
V60 bus cycles, instruction boundaries, IRQ/watchdog, ST010, ES5506 and native
video timing. `verif/ssv_diff_probe.sv` is the sole canonical consumer. Debug
logic is not listed in `files.qip` or the Quartus project.
