# Issue contract: natural vblank IRQ retirement skew vs MAME

## Issue

With natural vblank (no `DIFF_IRQ_SCHEDULE`), the first V60 IRQ handler entry
at `0x00F11124` occurs later in RTL than in MAME, so stack/PC writes and
complete-state hashes diverge before lockout. With the MAME IRQ retirement
schedule forced, ordered writes and hashes match through multi-second attract.

## Deterministic scenario

- Set: `dynagear`
- ROM: `rom/dynagear.zip` → `sim_output/rom/maincpu.bin`
- MAME: 0.288 (`scratch/upstream/mame0288/bin/mame.exe`)
- DIP: DSW2 `0xFFFD`, inputs idle `0xFFFF`
- RTL: `verif/tb_ssv_realrom_boot.sv`, `TRACE_CYCLES=120000000`, no IRQ schedule
- Stop: first hash/write divergence

## Current evidence

| Compare | Result |
|---|---|
| Natural writes | `DIVERGE write=532907` stack word `0x7904` data `7500` vs `7b00` (idle PC high byte) |
| Natural hashes | `DIVERGE state=731058` MAME `pc=00f11124` vs RTL still in idle `00f1057b` |
| RTL first IRQ | retirement `733486` (**+2428** vs MAME `731058`) |
| RTL steady IRQ period | ~`32086` instr/frame |
| MAME IRQ period | ~`33230` instr/frame (= CPI-8 ideal at 16 MHz / 7.159 MHz) |
| Scheduled writes (8s MAME) | PASS through available RTL horizon (see session notes) |
| Scheduled hashes | PASS all `2027025` short MAME complete-state hashes |

## Root-cause hypothesis

Path: TB `ce_cpu` uses `clk/3`, while production `Arcade-SSV.sv` uses fractional
`cpu_acc + 21702` (~16 MHz at `clk_sys=48.317307 MHz`). Pixel enable uses
`PIXEL_INC=9710` tuned for that same `clk_sys`. Absolute TB clock cancels only
when the CE ratio matches production; `/3` is ~0.7% fast vs MAME, so vblank
IRQs arrive after fewer retirements. SDRAM behavioral latency further raises
effective CPI (~8.34 vs MAME's flat 8).

Evidence tier: `MAME_ASSUMED` for IRQ cadence; production CE matches MAME clock
math. Attempting to drop the fractional CE module into the TB without a
ce-safe memory ack model hung early boot — TB memory model work remains.

## Last matching event

Natural: last matching hash state `731057` (idle loop).  
Scheduled: all compared MAME hash records; all compared write records up to the
RTL write-trace end for that run.

## First divergence

Natural: state `731058` / write `532907` — first vblank IRQ timing.

## RTL change

None in synthesizable core for this issue (production CE already correct).
Verification changes:

- Extended MAME write capture (`mame_ssv_writes_long.trace`, 8s)
- Extended IRQ schedules from PC traces (`mame_irq_schedule_8s.txt`)
- `tools/extract-v60-irq-schedule.py` accepts `STATE` / `pc=` / `HASH` lines
- `verif/run_post_ve_diff.sh` prefers long write + long IRQ schedule artifacts
- Documented TB `/3` vs production fractional CE in `tb_ssv_realrom_boot.sv`

## Session results (25 July 2026)

- Extended MAME write capture to **8 emulated seconds** (`869699` writes).
- Extended IRQ schedule to **460** vblank entries (`mame_irq_schedule_8s.txt`).
- Scheduled RTL @ 500M cycles: **`PASS: 869693` writes match** (RTL exhausted 6
  writes before MAME end — essentially full 8s attract write equivalence).
- All `2027025` short MAME complete-state hashes still match under schedule.
- Attempts to drop `+21702` fractional CE into the boot TB (with pulse or
  level-hold ack) broke early boot (~state 25) or hung; root cause not yet
  isolated (`TIMING` / ce–memory phase). Keep `/3` + pulse-ack for gates.

## Required next evidence

1. Isolate why TB fractional `+21702` CE fails early with the behavioral SDRAM
   model while `/3` matches under schedule (ce-safe sticky `ext_done` candidate).
2. Re-run natural hash/write compare; expect first IRQ near `731058` and period
   near `33230`.
3. Only then chase post-IRQ architectural mismatches without the schedule.
4. Extend MAME complete-state hash capture past 2M retirements for longer
   scheduled hash gates.

## Exit gate

Natural (unscheduled) write + hash compares match through at least the current
scheduled horizon, or any remaining skew is documented as
`TIMING_UNVERIFIABLE` with board evidence.
