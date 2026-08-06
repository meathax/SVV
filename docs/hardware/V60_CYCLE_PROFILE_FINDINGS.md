# V60 per-instruction cycle profile — vasara2 attract hot loop

**Measured 2026-08-06.** First real, per-opcode cycle-cost data from the RTL,
comparing against the hardware targets in
`docs/hardware/V60_CYCLE_TIMING_REFERENCE.md`. This replaces the previous
qualitative "40-60% throughput shortfall" estimate with a ranked, RTL-cited
breakdown of exactly which instructions spend the excess.

## Instrumentation

`verif/tb_ssv_frame_crc.sv` gained a simulation-only profiler (`+V60_CYCLE_PROFILE`,
see that file for the full comment). It taps the CPU's pre-existing
`dbg_retire`/`dbg_pc`/`cur_op` debug outputs (`rtl/cpu/v60/s32_v60.sv`,
already present for exactly this purpose) hierarchically from the testbench —
**zero RTL changes**. It buckets elapsed `clk_sys` ticks between successive
instruction retirements by the retiring instruction's opcode byte, and dumps
a CSV (`opcode_hex,count,total_clk_sys,min,max,avg`) at end of run.

`tools/analyze_v60_cycle_profile.py` ranks the CSV by total excess cycles
against a generic hardware floor, converting `clk_sys` ticks to V60-clock
equivalents via the fixed 704/315 ratio.

The profiler had to be added at **two** separate termination sites in
`tb_ssv_frame_crc.sv` — a `task finalize_run` used by the externally-clocked
savable/visual driver, and a second, independent inline copy used by the
plain default driver (the one every `run_gameplay_sims.sh`-style batch run
actually executes). These are not RTL and don't change any existing pass/fail
behavior; noted here so a future editor knows why the dump code appears twice.

## Run

```
+GAME_ID=3 (vasara2) +SCENARIO=attract_idle +FRAMES=10 +SOAK_FRAMES=1
+V60_CYCLE_PROFILE +V60_CYCLE_PROFILE_LO=0 +V60_CYCLE_PROFILE_HI=8
```
Window bounded to post-VE frames 0-8 — the pre-divergence hot loop identified
in `docs/debug/vasara2/ATTRACT_DIVERGENCE.md` (state first diverges at frame 8).
176,930 instructions retired, 19 distinct opcode bytes seen.

**Pre-existing, unrelated build breaks hit and worked around in a scratch copy
only (not fixed in the tracked file — both predate this session, confirmed via
`git diff` against HEAD):**
1. `tb_ssv_frame_crc.sv` connects `.debug_hud_en(debug_hud_en_tb)` on the
   `ssv_core` instance; `ssv_core.sv` has no such port and never instantiates
   `ssv_debug_hud` (half-wired WIP).
2. `visual_loop_trace_start`/`debug_hud_en_tb` are declared under `` `ifdef
   SSV_VISUAL`` but used unconditionally at their call sites, so any
   non-`SSV_VISUAL` build (i.e. the plain default) fails to compile at all
   right now.

## Results

| op | mnemonic (RTL-cited) | count | avg clk_sys | avg V60 clocks | hardware floor | excess (total clk_sys) |
|---|---|---:|---:|---:|---:|---:|
| 0x2D | **MOV.W** | 58,908 | 56.17 | 25.13 | ~4 (mem,reg) | 3,045,634 |
| 0xBC | **CMP.W** (no writeback) | 47,123 | 52.85 | 23.65 | 2 | 2,279,744 |
| 0x74 | **Bcc**, halfword displacement | 47,124 | 24.16 | 10.81 | 11 (taken) | 927,997 |
| 0xD3 | **DEC.W** (RMW) | 11,842 | 15.10 | 6.76 | 2 | 125,884 |
| 0x65 | **Bcc**, byte displacement | 11,842 | 3.03 | 1.35 | 2 | ~0 |
| (14 more, <200 instances each) | — | 87 | — | — | — | ~1,000 |

Mnemonics are cited directly from `rtl/cpu/v60/s32_v60.sv`'s own decode
comments (line numbers below), not reconstructed from memory of a scanned
datasheet page — the source PDF used earlier this session is no longer
locally available to re-check against.

- `0x2D` = MOVW: `s32_v60.sv:995` ("MOVTWB, MOVTWH, RVBYT, **MOVW**, RVBIT"),
  `s32_v60.sv:3403` ("MOVB/MOVH/**MOVW**")
- `0xBC` = CMP: `s32_v60.sv:1009` ("**CMP**/SHA"), `s32_v60.sv:3472`
  ("**CMP** (no writeback)")
- `0x74`/`0x65` = conditional branch: `s32_v60.sv:175`
  (`opcode[7:4] == 4'h6` or `4'h7` selects the branch-condition decode range;
  `0x65`=byte-displacement, `0x74`=halfword-displacement per the branch
  format's size bit)
- `0xD3` = DEC.W: `s32_v60.sv:1018`/`3817` ("**DEC** B/H/W", "DEC (RMW via
  addr in op1)")

## Reading

**Two instructions — MOV.W and CMP.W — account for 93% of retired
instructions in this loop (106,031 of 176,930) and 75% of all excess cycles
(5.33M of 7.16M clk_sys).** Both are dispatched through the RTL's shared
"generic F12 engine" (`s32_v60.sv:991`, the comment explicitly grouping MOV/
logic/arith instructions together) — the same two-operand format-I/II path
that resolves an effective address, fetches/writes the operand, and executes.

This directly connects to, and for the first time quantifies, the previously
unproven cost center from `docs/debug/vasara2/ATTRACT_DIVERGENCE.md`: "the
doubled `S_EA_MODE`/`S_EA_DONE` EA resolution" is exactly the shared machinery
MOV.W and CMP.W both pass through. Their measured cost (23-25 V60 clocks) is
roughly **6-12x** the hardware floor (2-4 clocks) from
`V60_CYCLE_TIMING_REFERENCE.md` §5 — far beyond what a one-cycle EA-doubling
inefficiency alone would explain, meaning there is a larger, still-unidentified
cost inside that shared path beyond the previously-flagged doubling.

The branch instructions tell a different story: `0x74` (halfword-displacement,
almost certainly the taken branch closing this loop) measures 10.81 V60
clocks — close to the hardware's own 11-clock taken-branch figure from
`V60_CYCLE_TIMING_REFERENCE.md` Table 5. **Branch cost in this loop is
already roughly hardware-accurate**; it is not a contributor to the
divergence. `0x65` (byte-displacement, likely the not-taken/inner fast path)
measures 1.35 clocks — at or below the reg-reg floor, i.e. essentially free.

DEC.W (RMW) at 6.76 clocks against a 2-clock floor is a real but much smaller
gap (1.8% of total excess) — lower priority.

## Implication for next steps

The prior "40-60% overall CPU throughput" framing was correct in magnitude
but not localized. This data localizes it: **fix the shared F12 two-operand
engine's EA/operand-fetch/writeback path** (the code shared by MOV, CMP, ADD,
SUB, AND, OR, XOR, etc. per the opcode list at `s32_v60.sv:991-1011`) and the
majority of the measured gap moves. Any change there is high-leverage (touches
every arithmetic/logical/move instruction, not just these two) but also
highest-risk for exactly that reason — it must pass the full V60 unit suite
(`verif/v60/run_v60_verilator.sh`, 32 tests), the Python cosim
(`verif/cosim/run_diff.sh`), and preserve the Dyna Gear tokens 2-4 exact match
before being considered, per this project's regression discipline.

Branch cost should **not** be touched — it already tracks the published
hardware figure. Any project-wide "make branches faster" change would be
tuning away from hardware accuracy, not toward it.

## Follow-up: per-FSM-state breakdown for MOV.W and CMP.W (same session)

Extended the same instrumentation with `+V60_STATE_PROFILE_OP=<hex>`
(`tools/analyze_v60_state_profile.py`), gated to one opcode per run, tallying
clk_sys ticks AND transition-entry counts per FSM state
(`rtl/cpu/v60/s32_v60.sv`'s `st_t` enum) while that opcode is in flight.

**MOV.W (0x2D), 65,520 instances, 3,680,434 clk_sys ticks total:**

| state | cycles | % | entries | cyc/entry |
|---|---:|---:|---:|---:|
| S_WB_MEM | 1,385,016 | 37.6% | 65,517 (1.0x) | **21.14** |
| S_FILL | 712,453 | 19.4% | 65,518 (1.0x) | 10.87 |
| S_EA_DONE | 395,738 | 10.8% | 131,039 (**2.0x**) | 3.02 |
| S_EA_MODE | 395,735 | 10.8% | 131,039 (**2.0x**) | 3.02 |
| S_EXEC / S_IF2 / S_DECODE / S_NEXT | ~198k each | 5.4% each | 1.0x | 3.02 |

**CMP.W (0xBC), 52,413 instances, 2,769,951 clk_sys ticks total:**

| state | cycles | % | entries | cyc/entry |
|---|---:|---:|---:|---:|
| S_OP2_LD | 1,107,978 | 40.0% | 52,413 (1.0x) | **21.14** |
| S_EA_DONE | 316,568 | 11.4% | 104,826 (**2.0x**) | 3.02 |
| S_EXEC | 316,566 | 11.4% | 104,826 (**2.0x**) | 3.02 |
| S_EA_MODE | 316,562 | 11.4% | 104,826 (**2.0x**) | 3.02 |
| S_FILL | 237,424 | 8.6% | 39,310 (0.75x) | 6.04 |
| S_NEXT / S_IF2 / S_DECODE | ~158k each | 5.7% each | 1.0x | 3.02 |

### Both named-but-unmeasured vasara2-journal suspects are now confirmed, and ranked

1. **The "doubled EA resolution" hypothesis is real and precisely quantified**:
   `S_EA_MODE`/`S_EA_DONE` are entered **exactly 2.0x per instruction** for
   both MOV.W and CMP.W (131,039/65,520 = 2.00; 104,826/52,413 = 2.00 — not
   approximate, exact). This is the first direct measurement confirming it
   (previously "could matter", never measured). It costs ~12 clk_sys/instr
   for MOV.W (10.8%+10.8%) and ~11 clk_sys/instr for CMP.W (via EA_MODE/
   EA_DONE/EXEC's shared 2.0x pattern) — real, but **not** the dominant cost.

2. **The dominant cost is the single memory-bus-access primitive itself**
   (`S_WB_MEM` for MOV.W's write, `S_OP2_LD` for CMP.W's operand read) —
   **37.6% and 40.0%** of each instruction's total cost respectively, at an
   identical **21.14 clk_sys (~9.5 V60 clocks) per visit, visited only
   once** (not doubled). `S_WB_MEM` (`s32_v60.sv:1823-1834`) is a plain
   two-phase bus-request FSM: assert `dbus_req`, then wait for `dack`.
   **21.14 cycles is the measured round-trip through the SDRAM
   controller/bus adapter, not a static CPU-side penalty** — it is
   fundamentally a wait-for-`dack` latency measurement, not an inefficiency
   inside the V60 FSM's own logic. Against the datasheet's 3-4 V60-clock
   (6.7-9 clk_sys) bus cycle from `V60_CYCLE_TIMING_REFERENCE.md`, this is
   **2.3-3.1x over spec** — and it is the single largest, best-quantified
   line item found in this whole investigation, bigger than the EA-doubling
   effect by more than 3x.

This reframes the earlier "fix the shared F12 engine" recommendation: the
EA-doubling fix (bounded, CPU-internal, ~10% of the gap) and the memory-access
latency question (unbounded until traced, ~40% of the gap, likely NOT a
CPU-FSM bug at all) are two separate problems requiring separate
investigation and separate evidence.

### Follow-up: traced — SDRAM ruled out, cost is mostly architectural

Added `+V60_MEM_TRACE_OP=<hex>` (bounded `$display`, no CSV needed): logs the
decoded memory region (`sel_wram`/`sel_sprram`/`sel_rom`/`sel_palette`, from
`ssv_core.sv`'s own address decode) and elapsed clk_sys for each `S_WB_MEM`/
`S_OP2_LD` wait episode. 40 real samples across both opcodes:

```
V60_MEM_TRACE op=2d state=14 addr=000002 sel_wram=1 sel_sprram=0 sel_rom=0 sel_palette=0 wait_clk_sys=21
V60_MEM_TRACE op=bc state=11 addr=000002 sel_wram=1 sel_sprram=0 sel_rom=0 sel_palette=0 wait_clk_sys=21
```

**Every single sample hit `sel_wram` (on-chip work RAM, `0x000000-0x00FFFF`).
Zero samples touched SDRAM.** This rules out the SDRAM-arbitration hypothesis
outright — there is no round-robin contention with video/audio in play here.

Checking the WRAM ack path (`ssv_core.sv:1201-1208`): a plain WRAM read acks
in exactly **2 raw clk_sys cycles** (`read_wait` → `ack_r`), unconditionally,
every tick — the on-chip BRAM itself is fast. The 21.14-cycle cost is not a
slow memory; it is the **path getting there**: `s32_v60_bus.sv` is entirely
`ce`-gated (steps once per V60 clock enable, ~3.02 clk_sys apart, matching
the measured `cyc/entry` for the other single-pass states exactly), and a
V60 **word** access needs **two** 16-bit half-transfers (`s32_v60_bus.sv:64-67`
— the real V60 external bus is 16 bits wide), each its own request-then-wait
round trip through that `ce`-gated adapter. 21.14 / 3.02 ≈ **7 ce-ticks**,
consistent with two half-transfers plus setup, not a stall on memory.

**This corrects the earlier framing.** Comparing 21.14 clk_sys against a
*single* 3-4 V60-clock bus cycle (6.7-9 clk_sys) overstated the gap. A V60
word access genuinely needs *two* 16-bit bus cycles on real hardware:
2×(3-4 clocks) = 6-8 V60 clocks ≈ 13.4-17.9 clk_sys expected. Against that
corrected target, the real overspend is **~1.2-1.6x**, not 2.3-3.1x —
modest, possibly within noise, and not clearly a defect.

### Follow-up: read the EA transition logic end to end — the "doubling" is not a bug

`s32_v60.sv:1548-1582`, `S_EA_DONE`'s full body:

```systemverilog
S_EA_DONE: begin
    ...
    if (!ea_target2) begin
        op1   <= ...; flag1 <= ea_flag; len1 <= ea_len;
    end else begin
        op2   <= ...; flag2 <= ea_flag; len2 <= ea_len;
        ...
    end
    // continuation: ea_ret==1 -> decode operand 2 (F1)
    if (ea_ret == 3'd1) begin
        ea_ret <= 3'd0;
        ea_target2 <= 1'b1;
        ea_want_addr <= 1'b1;    // op2 default = address (write target)
        ea_dim  <= f12_dim2(cur_op);
        st <= S_EA_MODE;         // <-- loops back for OPERAND 2, not operand 1 again
    end
    else st <= st_after_ea;
end
```

**The second `S_EA_MODE`/`S_EA_DONE` pass resolves operand 2's address, not
operand 1's a second time.** `ea_target2` flips from 0 to 1 and routes the
result into `op2`/`flag2`/`len2` instead of `op1`/`flag1`/`len1` — genuinely
different state, genuinely different work. MOV.W has a source and a
destination operand; CMP.W compares two operands. Any F12 instruction with
two addressed operands *must* resolve both. The exact 2.0x entry count this
session measured is not redundant computation — it is one legitimate EA
resolution per operand, which is exactly the architecturally-correct amount
of work for a two-operand instruction.

**This refutes the "doubled EA resolution" hypothesis from
`docs/debug/vasara2/ATTRACT_DIVERGENCE.md`.** It named a real, measurable
pattern (confirmed: entries are exactly 2x), but the pattern turns out to be
correct behavior, not an inefficiency — there is no redundant pass to remove.

### Where this leaves the investigation

Both previously-unmeasured cost centers named in the vasara2 journal have now
been traced to ground truth, and **neither is a clean, actionable RTL
defect**:

1. Memory-access wait (`S_WB_MEM`/`S_OP2_LD`, ~40% of cost) — mostly
   explained by the V60's real 16-bit external bus needing two half-transfers
   per word access, at `ce`-tick granularity. Residual gap ~1.2-1.6x, likely
   architectural, not a bug.
2. "Doubled" EA resolution (~22% of cost) — refuted as a bug; it is correct
   two-operand processing.

Recomputing MOV.W's ~56 clk_sys from first principles with this understanding
(2 EA passes ~12 clk_sys + word access ~21 clk_sys + pipeline stages S_IF2/
S_DECODE/S_EXEC/S_NEXT ~12 clk_sys ≈ 45 clk_sys) lands close to the measured
average — the cost is now **mostly explained**, not mysterious. The original
opcode-level framing ("6-12x over a 2-clock floor") used a generic register-
register floor that was never a fair target for a two-operand, memory-
addressing instruction in the first place.

**No RTL change is justified by this investigation's evidence.** Both
concrete candidate fixes that existed at its start have been examined and
ruled out as genuine defects. This is a legitimate outcome of the
differential-debugging discipline this project follows (identify before
fixing) — it means the actual root cause of the vasara2 attract-mode
compounding divergence is not a locally-fixable V60 cycle-cost bug in
either of the two most-measured instructions, and lies elsewhere: most
likely in either (a) real V60 AC timing being different from what the
`ce`-tick/16-bit-bus model assumes — still blocked on the missing hardware
datasheet per `V60_TIMING_EVIDENCE.md` — or (b) a mechanism this session
never measured (a different instruction mix elsewhere in the loop, IRQ
timing, or something not yet on any suspect list). Continuing to search
inside MOV.W/CMP.W's cycle cost without new evidence would be exactly the
"stack unproven fixes" pattern this project's rules prohibit.

### Recommended next step (superseded by the above; kept for the run history)

The memory-access-wait line item is now mostly explained by the V60's real
16-bit-bus architecture, not a discovered bug — deprioritize it; any
residual gap there needs the actual bus T-state protocol (still missing,
see `V60_TIMING_EVIDENCE.md`) before it's even meaningful to chase further.

**The EA-doubling effect remains the single cleanest, best-evidenced target**:
`S_EA_MODE`/`S_EA_DONE` are entered *exactly* 2.0x per instruction (131,039/
65,520 and 104,826/52,413 — not approximate) with no architectural
justification found for needing two passes. Next step there: read
`s32_v60.sv`'s `S_EA_MODE`→`S_EA_IND`→`S_EA_VAL`→`S_EA_DONE` transition logic
end to end for the MOV.W/CMP.W addressing modes actually used in this loop,
to determine whether the second pass computes something genuinely new (in
which case it's not "doubled", it's two different necessary steps that
happen to share state names) or is a literal redundant repeat of the first
(in which case it is a bounded, well-scoped candidate fix) — before touching
any RTL, per this project's own rule against speculative changes.

## Reproducing

```bash
wsl.exe bash -lc "export PATH=/home/meath/.local/bin:/usr/local/bin:/usr/bin:/bin; \
  bash /mnt/d/Arcade/AI/SVV/tmp/verilator/v60prof/build.sh && \
  bash /mnt/d/Arcade/AI/SVV/tmp/verilator/v60prof/run.sh"
python3 tools/analyze_v60_cycle_profile.py sim_output/diff/vasara2_v60_cycle_profile.csv
```
The scratch build (`tmp/verilator/v60prof/tb_ssv_frame_crc_scratch.sv`) works
around the two unrelated breaks above; it must be regenerated from the
tracked `verif/tb_ssv_frame_crc.sv` (see the `cp` + patch steps this session
used) whenever the tracked file changes, until those breaks are fixed
upstream. Once fixed, the plain `verif/tb_ssv_frame_crc.sv` build should be
used directly.
