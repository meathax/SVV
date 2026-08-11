# V60 pre-prefetch-change baseline (Phase 0)

Captured 2026-07-23 before the fetch/prefetch redesign (docs/v60-prefetch-plan.md).
Re-run `bash verif/v60/run_v60_verilator.sh` and compare after each phase.

## Unit suite (verif/v60/run_v60_verilator.sh)
- **26 passed, 0 failed** (19 Verilator + 6 Icarus white-box + SMC + gated-ce)
- `tb_v60_fetch`: **cycles=3129, reads=10** (gate: <=4000 / <=32)
- `tb_v60_smc` (NEW): PASS ce=1 (146 cyc) and ce=/3 (438 cyc) — SMC window coherency
- `tb_v60_bus_lanes`: PASS (exact 1/2/3 external-cycle counts — must stay unchanged)

## Differential (verif/cosim/run_diff.sh)
- **20/20 seeds** match the Python reference (full regression runs 50/50)

## Real-game CPI (tb_core_romboot +PCHIST, ga2)
- Attract gameplay demo: **22.70 cyc/instr**; idle 23% / work 77%
- Char select (light): work 42% / idle 58%
- FSM state distribution: **S_FILLW=40%, S_FILL=16%** (56% of all cycles = fetch),
  decode/EA/exec/data each 2-5%
- vblank period: 805649 clk_sys, rock-stable (video timing is NOT the bug)

## MAME reference (same scenes, cycle-clean; MAME = flat 8 cyc/instr)
- Char select: MAME **15% work** vs ours 42% -> ~2.8x
- Attract: MAME ~70-90% idle vs ours 23%

## Targets after prefetch (docs/v60-prefetch-plan.md)
- CPI ~10-12 (P2), ~9-11 (P3); S_FILLW < 10%
- select work ~18-22%, attract idle ~55-65% (within DESIGN.md +/-20% policy band)
- tb_v60_fetch budget tightened to ~<=2200 cyc at P4

## 2026-08-11 SSV throughput update

- `tb_v60_fetch`: **cycles=2097, reads=12** for 256 MOVW/DBcc iterations.
  The immediately preceding SSV implementation measured 2353 cycles / 14 reads;
  the current System 32 working tree measured 2101 cycles / 12 reads.
- Imported selectively: held CPU ACK/re-arm cadence, exact retained-loop reuse,
  registered exact successor predecode, and same-instruction F2 EA overlap.
- SSV-specific extension: the F2 overlap reuses the existing second register-file
  read port instead of adding System 32's third 32:1 mux.
- SSV-specific extension: integer MUL/MULU and MULX/MULUX use an exact radix-4
  iterative magnitude datapath (16 steps), retaining SSV's no-combinational-
  multiplier resource contract and qword EA behavior.
- Verification: 26 executable V60 tests pass, including fetch, bus lanes,
  qword EA, MUL flags, MULX/DIVX memory, SMC and gated-CE. Six legacy
  Icarus-only white-box entries remain blocked at elaboration by the existing
  enum-ternary cast incompatibility and did not simulate.
- Integrated Vasara 2 cold boot: native video becomes nonblack/changing at frame
  61 and continues with watchdog service and audio activity in the visible model.
