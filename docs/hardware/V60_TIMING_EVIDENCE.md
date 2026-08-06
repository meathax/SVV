# V60 timing evidence — primary sources

**Status: the "missing V60 AC timing" evidence gate is now partially OPEN.**
This file records the real, citable per-instruction and bus-cycle timing data
recovered on 2026-08-06, its provenance, and exactly how far it can be trusted
for the V60 (µPD70616) in SSV. It directly addresses the blocker recorded in
`docs/debug/vasara2/ATTRACT_DIVERGENCE.md` ("missing: hardware AC timing
(clocks per bus cycle, wait states)") and `SSV_SILICON.md` §1.

## Sources on file (docs/hardware/refs/)

| File | What it is | Provenance |
|---|---|---|
| `Komoto_1990_Overview_32bit_V-Series_JIP.pdf` | **Komoto, Saito, Mine (NEC Microcomputer Div.), "Overview of 32-bit V-Series Microprocessor", Journal of Information Processing (IPSJ), Vol. 13 No. 2, pp. 110-122, Aug 1990.** Invited paper by the V60/V70/V80 design team. Tables 1, 4, 5 carry the timing data below. | `[PRIMARY]` — NEC authors. Open-access IPSJ PDF, recovered via Wayback Machine (original IPSJ ixsq URL is dead post-migration) |
| `1987_Microcomputer_Products_Vol_2.pdf` | NEC 1987 Microcomputer Data Book Vol 2. V60 entry (pp. 3-229..3-232) is the same 3-page PRELIMINARY short-form as the DSAIH000102840 excerpt — **no AC section**. Also contains the complete µPD70216 (V50) per-instruction clocks table (pp. 3-218..3-227) and the µPD72191 FPP datasheet (3-233+). | `[PRIMARY]`, bitsavers |
| `1987_Microcomputer_Products_Vol_1.pdf` | Vol 1 — single-chip microcontrollers only; no V-series 32-bit content. Kept for completeness. | `[PRIMARY]`, bitsavers |

Additional primary references identified but not yet obtained (all paywalled):

- Kimura, Komoto, Yano, "Implementation of the V60/V70 and Its FRM Function",
  IEEE Micro Vol. 8 No. 2, pp. 22-36, Apr 1988. (doi:10.1109/40.527) —
  the V60/V70 implementation paper; likely the deepest µ-architecture source.
- Kaneko et al., "A 32-bit CMOS Microprocessor with Six-Stage Pipeline
  Structure", Proc. 1986 FJCC, pp. 1000-1007 — the V60 pipeline paper.
- Yano et al., "A 32b CMOS VLSI microprocessor with on-chip virtual memory
  management", ISSCC 1986, pp. 36-37.
- Kani, "Vシリーズマイクロコンピュータ 2", Maruzen, Apr 1987,
  ISBN 978-4621031575 — Japanese book, reportedly carries V60 bus T-state
  detail (cited by Wikipedia for the 3-4-clock bus claim).
- The **full** µPD70616 datasheet with DC/AC characteristics: confirmed to
  exist (the Programmer's Reference §11 refers to it) but **not found in any
  scanned archive searched** (bitsavers, Datasheet Archive, archive.org,
  datasheet.directory — the last serves the 1995 Selection Guide mislabeled
  as `uPD70616.pdf`).

## Table 1 facts (V60 column) — architecture and bus

| Item | V60 (µPD70616) | V70 for comparison |
|---|---|---|
| Pipeline | **6-unit, 6-stage, executes max 4 instructions concurrently** | same |
| TLB | 16-entry full-associative, **firmware (microcode) replace** | same |
| **External bus cycle** | **3 clocks/cycle or 4 clocks/cycle** (T1-T3/T4), 16-bit data bus | 2 clocks/cycle (T1-T2), 32-bit |
| Clock (max) | 16 MHz | 16/20 MHz |
| Performance (max) | 3.5 MIPS @16 MHz | 5.3 MIPS @16 MHz |
| Transistors / process | 375,000 / 1.5 µm CMOS | 385,000 / 1.2 µm |

Note: the Programmer's Reference (Nov 1986, p.1-18) describes 6 functional
units — PFU (16-byte prefetch queue filled during idle bus periods, zero
latency on hit), IDU (+ decoded-instruction queue), EAG, MMU (TLB-pipelined,
zero effective translation time), BCU, microprogrammed EXU. The "four stage
instruction pipeline" phrase in its preface undercounts; Table 1 of Komoto
and the Kaneko FJCC title agree on **six** stages.

## Table 5 — per-instruction clock counts (V70 column; applicability below)

| Category | Instruction | V70 clocks |
|---|---|---:|
| Transfer | MOV.W mem,reg | 4 |
| Transfer | MOV.W reg,mem | 4 |
| Primitive op | ADD.W reg,reg | **2** |
| | ADD.W mem,reg | 4 |
| Multiply | MUL.W | **23** |
| Divide | DIV.W | **43** |
| Shift | SHA.W | **17** |
| Branch | taken | **11** |
| Branch | not taken | **4** |
| Procedure | CALL+RET | 44 |
| Multi push/pop | PUSHM (N words) | 14+6N |
| | POPM (N words) | 20+7N |
| Bit field | EXTBFZ | 30 |
| | INSBFL | 28 |
| 32-bit float | ADDF.S / MULF.S / DIVF.S | 120 / 116 / 137 |
| 64-bit float | ADDF.L / MULF.L / DIVF.L | 178 / 270 / 590 |
| Return from INT | RETIS | 8 |
| Context switch | LDTASK / STTASK(max) | 347 / 200 |
| Asynchronous | Trap | 195 |
| TLB replace | (V70, same/different area) | 58 |
| INT response | until handler executes | **165** |
| Char string | MOVCU.B (N bytes) | 20+5N |

Table 4 (branch detail, V70): JMP 11; Bcond 11 taken / 4 not-taken;
DBcond 12/8; TB 12/8.

### How the V70 numbers map to the V60

The V60 and V70 share the same 6-stage pipeline, microcode
and execution units (Table 1; V80 §3.2.1 confirms full ISA continuity).
The differences are the external bus (V60: 16-bit wide, 3-4 clocks/cycle;
V70: 32-bit wide, 2 clocks/cycle) and process speed. Therefore:

- **Execution-bound (register-only / microcode-bound) costs transfer
  directly to the V60**: ADD reg,reg = 2, SHA = 17, MUL.W = 23, DIV.W = 43,
  branch not-taken = 4, RETIS = 8, trap = 195, INT response = 165, FP costs.
  These are EXU/microcode step counts, not bus-limited.
- **Memory-operand and fetch-heavy costs are LOWER BOUNDS for the V60**: a
  32-bit memory operand on the V60 needs two 16-bit bus cycles of 3-4 clocks
  each (6-8 clocks) versus one 2-clock cycle on the V70. E.g. MOV.W mem,reg:
  V70 = 4; V60 expectation ≈ 2 (exec) + 6..8 (bus) with overlap, i.e. high
  single digits when the prefetch queue and EAG pipeline can't hide it.
- **Branch-taken (11 on V70) is partially bus-bound** (prefetch-queue refill
  through the instruction fetch path); the V60 equivalent is somewhat higher.
- The 3.5 MIPS (V60) vs 5.3 MIPS (V70) ratio at the same 16 MHz (0.66×) is a
  measured NEC-published aggregate of exactly this bus difference; it can be
  used to sanity-check any V60-scaled model: average ≈ 4.6 clocks/instruction
  at 16 MHz for the V60 (16 MHz / 3.5 MIPS).

## Implications for `rtl/cpu/v60/s32_v60.sv`

`clk_sys` = 48.317307 MHz with the 704/315 ratio gives 3.019 `clk_sys` ticks
per 16 MHz V60 clock. The vasara2 investigation measured RTL costs of
15-58 `clk_sys` (~5-19 V60 clocks) per instruction in the attract hot loop.
Against the real targets (2 clocks for reg-reg ALU, ~4-8 for 16-bit-bus
memory ops, 4 not-taken / ~11+ taken branches), the RTL is roughly **2-3×
too slow on simple instructions** — consistent in both direction and rough
magnitude with the estimated 40-60% throughput shortfall behind the
vasara/vasara2 attract divergence, and with the structural difference: the
real chip overlaps decode/EA of instruction N+1 with execution of N (6-stage
pipeline, decoded-instruction queue), while the RTL FSM serializes
fetch→decode→EA→exec→writeback per instruction.

MAME's V60 (`src/devices/cpu/v60/v60.cpp:626`) charges a flat 8
clocks/instruction and its own comment says "Actual cycles / instruction is
unknown" — that flat average is close to the *mean* implied by 3.5 MIPS
(4.6 clocks) only within a factor of ~2, and has no per-instruction shape at
all. Chasing exact frame-for-frame MAME parity is therefore chasing MAME's
guess, not hardware; the defensible target is a per-instruction cycle model
built from Table 5 + bus scaling, which will land *between* today's RTL and
MAME's flat 8 on different instruction mixes.

## What is still missing

- V60 bus T-state protocol detail: what distinguishes the 3-clock from the
  4-clock cycle (likely read vs write or aligned vs crossing), READY wait
  insertion rules, and FAS/BCY sequencing — the full datasheet or the Kani
  book would settle it.
- Per-addressing-mode EA overhead table (the Programmer's Reference has the
  modes but no costs; the V50 table in the 1987 databook shows NEC's format).
- Interrupt-acknowledge bus sequence timing (Table 5's 165-clock INT response
  is an aggregate).
- Confirmation via real hardware (Phase 0 of `SSV_ACCURACY_PLAN.md`) remains
  the gold standard; a logic-analyser capture of a real V60's BCY/ST2-0 pins
  would confirm the 3/4-clock bus rule directly.
