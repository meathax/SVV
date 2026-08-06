# NEC V60 (µPD70616) — Cycle & Timing Reference

**Compiled 2026-08-06** from every primary source recovered to date. This is the
definitive timing knowledge base for the SSV core's V60 work
(`rtl/cpu/v60/s32_v60.sv`, `rtl/cpu/v60/s32_v60_bus.sv`). Provenance and raw
source files: `docs/hardware/V60_TIMING_EVIDENCE.md` and
`docs/hardware/refs/`. Nothing here is MAME-derived unless explicitly marked.

---

## 1. Sources and trust tiers

| # | Source | Tier | On file |
|---|---|---|---|
| S1 | **Komoto, Saito, Mine (NEC Microcomputer Div.), "Overview of 32-bit V-Series Microprocessor", J. Information Processing (IPSJ) 13(2) pp.110-122, Aug 1990** — invited paper by the V60/V70/V80 design team; Tables 1/4/5 are the only published per-instruction clock data known to exist | PRIMARY | `refs/Komoto_1990_Overview_32bit_V-Series_JIP.pdf` |
| S2 | **NEC µPD70616 Programmer's Reference Manual, Nov 1986** (308 pp., preliminary) — architecture, pipeline units, instruction set, exceptions; **no clock counts** (confirmed cover-to-cover; the 1987 comp.arch thread reports NEC's own preliminary doc shipped with the cycle-times column blank) | PRIMARY | `D:\Downloads\NEC_V60pgmRef.pdf` |
| S3 | **µPD70616 preliminary datasheet** (3 pp., = NEC 1987 Microcomputer Data Book Vol 2 pp.3-229..3-232) — ordering info, pins, block diagram; **no AC section** | PRIMARY | `refs/1987_Microcomputer_Products_Vol_2.pdf` |
| S4 | NEC 1987 Data Book Vol 2, µPD70216 (V50) section — full per-instruction clocks table; **not V60 data**, kept as NEC's format exemplar | PRIMARY (other part) | same file, pp.3-218..3-227 |
| S5 | MAME `src/devices/cpu/v60/v60.cpp` — reference emulator model | REFERENCE ONLY | MAMESOURCE checkout |
| — | Identified, not yet obtained: Kimura et al., "Implementation of the V60/V70 and Its FRM Function", IEEE Micro 8(2) Apr 1988 pp.22-36; Kaneko et al., "A 32-bit CMOS Microprocessor with Six-Stage Pipeline Structure", FJCC 1986 pp.1000-1007; Yano et al. ISSCC 1986; Kani, "Vシリーズマイクロコンピュータ 2", Maruzen 1987; the **full** µPD70616 datasheet (existence confirmed by S2 §11, never found scanned) | — | — |

---

## 2. Device fundamentals [S1, S3]

| Item | Value |
|---|---|
| Part | µPD70616R, 68-pin PGA |
| Max clock | **16 MHz** (SSV runs it at its rated ceiling) |
| CLK input | single-phase CLK at operating frequency (design example: 32 MHz crystal → µPD71611 clock generator → 16 MHz into CPU) |
| Transistors / process | 375,000 / 1.5 µm double-metal CMOS |
| Published performance | **3.5 MIPS max at 16 MHz** → mean ≈ **4.57 clocks/instruction** |
| Buses | 24-bit address out (A23-A0), **16-bit data** (D15-D0) |
| V70 (µPD70632) same-ISA sibling | 32-bit bus, 2-clock cycle, 5.3 MIPS @ 16 MHz (0.66× ratio is pure bus/fetch effect) |

## 3. Microarchitecture [S1 Table 1, S2 pp.1-17..1-19]

**6-unit, 6-stage pipeline, executing up to 4 instructions concurrently.**
(S2's preface says "four stage" — undercounted; S1 Table 1 and the Kaneko FJCC
paper title agree on six.)

| Unit | Documented behavior (timing-relevant) |
|---|---|
| **PFU** — prefetch | **16-byte instruction queue**, filled from memory **during idle bus periods**; instruction fetch latency is **zero on queue hit**. Fetch competes with data accesses for the single external bus otherwise. |
| **IDU** — decode | Strips operand/addressing info to EAG; **decoded instructions are queued** ahead of the EXU (decode of N+1 overlaps execution of N). |
| **EAG** — effective address | "High-speed multi-way adder" — EA computation is pipelined, not serialized. |
| **MMU** | 16-entry full-associative TLB, pipelined with EAG: **effective translation time = zero** on TLB hit. TLB replacement is **microcode-driven ("firmware replace")** and stalls the pipeline (see §6). SSV runs flat physical addressing, so only the hit path matters. |
| **BCU** | Owns the external bus; supports bus-cycle re-run on error and a **"short cycle bus mode"** for fast memories (implies the 3-vs-4-clock distinction of §4 is externally selectable/condition-dependent). |
| **EXU** | **Microprogrammed** (µSEQ + µROM) 32-bit ALU + 32 GPRs + barrel shifter. Per-instruction execute costs are microcode step counts — inherently variable. |

## 4. External bus timing [S1 Table 1]

- **V60 bus cycle = 3 clocks or 4 clocks per cycle (T1-T3 / T1-T4), 16-bit wide.**
  (V70: 2 clocks T1-T2, 32-bit.) Which conditions select 3 vs 4 is **not yet
  documented** — candidates: read vs write, short-cycle mode, address setup.
- READY pin inserts wait states beyond that (S3 pin list); wait-state rules unlocated.
- A 32-bit operand costs **two** bus cycles (6-8 clocks + waits) on the V60.
- Bus-cycle status is externally visible on BCY, ST2-ST0, DL1-DL0, FAS, UBE,
  MRQ, R/W, DS pins [S3] — a real-hardware logic-analyzer capture of BCY/ST2-0
  would settle the 3-vs-4-clock rule directly.

## 5. Per-instruction clock counts [S1 Table 5, V70 column]

The only published per-instruction data for this microarchitecture. V60/V70
share pipeline + microcode; **applicability to V60 per row is flagged**:
`=` transfers directly (execution/microcode-bound), `≥` is a lower bound for
V60 (bus-involved; V60's narrower/slower bus adds cycles).

| Class | Instruction | V70 clocks | V60 applicability |
|---|---|---:|---|
| Transfer | MOV.W mem,reg | 4 | ≥ (≈6-10 w/ 2×16-bit bus cycles, partial overlap) |
| Transfer | MOV.W reg,mem | 4 | ≥ |
| ALU | **ADD.W reg,reg** | **2** | **=** |
| ALU | ADD.W mem,reg | 4 | ≥ |
| Multiply | **MUL.W** | **23** | **=** |
| Divide | **DIV.W** | **43** | **=** |
| Shift | **SHA.W** | **17** | **=** |
| Branch | taken (Bcond/JMP) | **11** (JMP 11, Bcond 11, DBcond 12, TB 12) [S1 T4] | ≥ (prefetch refill is bus-bound) |
| Branch | **not taken** | **4** (Bcond 4, DBcond 8, TB 8) [S1 T4] | **=** |
| Procedure | CALL+RET pair | 44 | ≥ |
| Stack | PUSHM (N words) | 14+6N | ≥ |
| Stack | POPM (N words) | 20+7N | ≥ |
| Bit field | EXTBFZ / INSBFL | 30 / 28 | ≈ (mostly exec-bound) |
| FP 32-bit | ADDF.S / MULF.S / DIVF.S | 120 / 116 / 137 | = (microcode) |
| FP 64-bit | ADDF.L / MULF.L / DIVF.L | 178 / 270 / 590 | = |
| Interrupt | RETIS | 8 | = |
| Interrupt | **response, INT asserted → handler executing** | **165** | ≥ |
| Exception | Trap | 195 | ≥ |
| Context | LDTASK / STTASK (max) | 347 / 200 | ≥ |
| TLB | replacement (microcode) | 58 | ≈ (n/a in SSV flat mapping) |
| String | MOVCU.B (N bytes) | 20+5N | ≥ (bus-limited by design [S1 §3.2.4(3)]) |

**Aggregate cross-check:** V60 mean = 16 MHz / 3.5 MIPS ≈ **4.6 clocks/instr**;
V70 mean ≈ 3.0. Any V60 cycle model should reproduce ≈4.6 on a typical mix.

## 6. Interrupt & exception timing [S1, S2 §8]

- INT response to first handler instruction: **165 clocks** (V70; V60 ≥).
  At 16 MHz that is ~10.3 µs — relevant to vblank IRQ-to-first-write latency
  comparisons in lockstep traces.
- Trap: 195 clocks. RETIS: 8 clocks.
- NMI and INT are sampled per instruction boundary (S5 behavior matches S2's
  model); vector fetch sequence is documented functionally in S2 §8 but has
  no published cycle count beyond the 165 aggregate.
- Reset: S2 §8 defines state; no cycle count published.

## 7. Mapping to the SSV RTL and Verilator model

- `clk_sys` = 48.317307 MHz; CPU enable ratio 704/315 → **3.019 `clk_sys`
  ticks per 16 MHz V60 clock**. Handy conversions:

| V60 clocks | `clk_sys` ticks | Example |
|---:|---:|---|
| 2 | ~6 | ADD reg,reg |
| 4 | ~12 | branch not-taken; MOV mem,reg (V70 floor) |
| 4.6 | ~13.9 | published V60 average |
| 8 | ~24 | MAME's flat guess; RETIS |
| 11 | ~33 | branch taken (V70 floor) |
| 23 | ~69 | MUL.W |
| 43 | ~130 | DIV.W |
| 165 | ~498 | INT response |

- Measured RTL (vasara2 attract hot loop, 2026-08-05 investigation):
  **15-58 `clk_sys` (~5-19 V60 clocks) per instruction** — i.e. simple
  instructions run **~2-3× over the hardware target** (2-4 clocks), which
  matches the estimated 40-60% throughput shortfall that produces the
  vasara/vasara2 attract-state lag.
- Root structural cause: the real chip **overlaps** fetch/decode/EA of the
  next instruction(s) with execution (6 stages, decoded-instruction queue,
  4 in flight); the RTL FSM serializes
  S_FILL→S_DECODE→S_EA_*→S_EXEC→S_WB_MEM→S_NEXT per instruction. No amount of
  per-state shaving reaches 2-clock ALU ops without overlap — this is why the
  0.5-clock S_FILL/S_NEXT experiment measurably could not move the target
  (reverted per project rules).

## 8. The reference emulator is NOT a timing authority [S5]

MAME `v60.cpp:614,626`:
```cpp
// Actual cycles / instruction is unknown
m_icount -= 8;  /* fix me -- this is just an average */
```
Every instruction costs a flat 8 clocks in MAME — no per-opcode shape, no bus
model, no branch/multiply distinction. Consequences for the differential
workflow:
- Frame-exact CPU-phase parity with MAME is parity with a guess. It remains
  useful as a *stability* reference (IRQ ordering, event sequence), not as a
  cycle-truth reference.
- The hardware-derived model (§5) will legitimately diverge from MAME in both
  directions on different instruction mixes (real mean 4.6 vs flat 8, but
  MUL 23 / DIV 43 / branch-taken 11+ vs flat 8).
- Long-horizon scene timing (attract-loop phase) on real hardware would match
  *neither* today's RTL nor MAME exactly; the defensible target is the S1
  table + measured aggregate.

## 9. Known unknowns (evidence still wanted)

1. **3-clock vs 4-clock bus cycle selection rule**, READY wait-state protocol,
   FAS/BCY sequencing → full µPD70616 datasheet, Kani 1987 book, or a
   logic-analyzer capture of a real board (SSV_ACCURACY_PLAN Phase 0).
2. Per-addressing-mode EA cost table (register indirect vs displacement vs
   double-displacement etc.) — S4 shows NEC published this format for the V50;
   nothing equivalent found for V60.
3. Prefetch-queue refill policy details (bytes per idle-bus opportunity,
   queue-low threshold).
4. Interrupt-acknowledge bus sequence cycle detail (165 is an aggregate).
5. The IEEE Micro Apr 1988 Kimura paper (deepest µarch source, paywalled) —
   worth obtaining; likely quantifies stage occupancy and stall conditions.

## 10. How to use this document

- Convert §5 targets to `clk_sys` via §7 and compare against per-opcode-class
  histograms from the Verilator model to produce a ranked overspend list
  before touching RTL.
- Any `s32_v60.sv` timing change must cite its target row here, pass
  `verif/v60/run_v60_verilator.sh` (32 tests), the Python cosim
  (`verif/cosim/run_diff.sh`), and preserve Dyna tokens 2-4 exactly.
- Do not tune toward MAME cycle behavior (§8). Where MAME and this document
  conflict on timing, this document wins; where *behavior* (not timing)
  differs, MAME remains the tier-3 reference per the evidence order.
