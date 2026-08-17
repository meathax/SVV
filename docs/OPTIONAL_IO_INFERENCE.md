# Optional I/O devices — RAM inference and ALM cost

Date: 2026-08-13
Scope: `rtl/io/` only (`ssv_93c46_16.sv`, `ssv_adc0809.sv`, `ssv_upd4701.sv`,
`ssv_upd7001.sv`, `ssv_mahjong_matrix.sv`, `ssv_input_ports.sv`).

## Why this exists

`AGENTS.md` requires exactly one universal `Arcade-SSV.rbf` covering every
qualified set, with optional devices selected by the MRA descriptor rather than
by a compile-time fork. Commit `f0622c5` did the opposite for the GDFS optional
I/O block: `rtl/ssv_core.sv:221-226` records that the EEPROM and its siblings
were left un-instantiated because the design was at ~95% ALMs and the EEPROM was
"the largest optional block". That is a resource workaround, not a design
decision, and it blocks the one-RBF target.

## Measured cost (retained fit report)

| Module | ALMs | Storage | Verdict |
|---|---|---|---|
| `ssv_93c46_16` | **509.7** | 64 x 16 = 1024 bits | array in logic — fixed below |
| `ssv_adc0809` | 14.4 | none | already cheap, left alone |
| `ssv_upd4701` | 21.8 | none | already cheap, left alone |
| `ssv_upd7001` | 18.0 | none | already cheap, left alone |
| `ssv_mahjong_matrix` | 9.9 | none (one 16-bit selector register) | already cheap, left alone |
| `ssv_input_ports` | not in the retained data | none | pure combinational + 2-bit phase counter |

509.7 ALMs for 1024 bits of storage is the classic signature from CLAUDE.md
("Diagnosing a design that does not fit"): the array became ~1024 registers plus
a 64:1 read mux. The other five modules contain **no arrays at all** — an
exhaustive grep for `logic [..] name [0:N]` across `rtl/io/` returns exactly one
hit, `mem` in `ssv_93c46_16.sv`. Their costs are ordinary control logic and
there is nothing to recover; they were deliberately not touched.

## Root cause

`logic [15:0] mem [0:63]` in the old `ssv_93c46_16.sv` violated Quartus 17's
inference template on both ports at once:

- **Three conditional write sites** — reset erase (`mem[init_addr] <= 16'hffff`
  under `init_busy`), the ERASE command (`mem[{command[4:0],di}] <= 16'hffff`),
  and the WRITE command (`mem[address] <= {shift[14:0],di}`), all nested at
  different depths of the same FSM.
- **A conditional read** — `shift <= mem[...]` / `dout <= mem[...][15]` nested
  under `if (bit_count == 8)` inside a `case` inside `if (sk && !sk_d)`, reading
  the array **twice** with different bit slices. This is the "uninferred due to
  asynchronous read logic" shape.

No `ramstyle` attribute was present, and even with one Quartus would have
ignored it for this shape (a `ramstyle` attribute is a request, not a
guarantee).

## The fix

The array is split by address bit 0 into two independent **32 x 16** arrays,
`mem0` (A0=0) and `mem1` (A0=1). Each is written by one muxed write port and
read by one *unconditional* registered read, each in its own `always_ff`
containing nothing else — Altera's simple-dual-port template:

```systemverilog
always_ff @(posedge clk) begin
    if (mem_we && !mem_waddr[0]) mem0[mem_waddr[5:1]] <= mem_wdata;
    mem_q0 <= mem0[mem_raddr];
end
```

The three write sites collapse into one combinational `mem_we` / `mem_waddr` /
`mem_wdata` mux carrying exactly the original conditions.

### Storage choice: MLAB, not M10K

32 words deep x 16 bits wide is exactly one MLAB (32 x 20), so the pair costs
two MLABs, roughly 20 memory ALMs, and **zero M10K**. M10K is wrong on both
counts here: the design already sits at ~93% M10K occupancy, and a 32-word array
is the "inappropriate RAM size" case CLAUDE.md warns about. ALM pressure is the
constraint being relieved, and MLAB relieves it without spending the scarcer
resource. `no_rw_check` is applied and is proven safe (see below), not assumed.

### Serial timing is preserved — and why the split was necessary to do it

The externally observable contract, asserted by `verif/tb_ssv_gdfs_devices.sv`,
is that a READ command presents D15 on `dout` on the **same** clk edge that
clocks in the last address bit (the ninth `sk` rising edge). A registered-read
memory normally adds one clk of latency and would break that.

It does not here:

1. The read address is `{command[4:0], di}`. `command[4:0]` (A5..A1) is a
   register that last changed on the *eighth* `sk` rising edge. `di` (A0) is a
   combinational input valid only at the ninth edge itself — the bench drives
   `di` and `sk` together on one negedge, so `di` has no full-cycle setup. The
   low bit is the only late term.
2. Therefore both banks are read continuously at index `command[4:0]`, and `di`
   selects between the two *already-registered* results with a 2:1 mux at the
   edge. The memory latency hides behind the `sk` period; the di-dependent part
   costs a mux, not a cycle.
3. The capture is correct provided `command` did not change on the immediately
   preceding clk edge. It cannot: a detected `sk` rising edge needs `sk_d == 0`
   (sk low for at least one sampled cycle) and `sk == 1`, so two detected rising
   edges are always >= 2 clk apart and the cycle before a rising edge is never
   itself a rising edge. `command`'s only other writer is the `!cs` idle branch,
   which also forces `bit_count` to 0, so no `bit_count == 8` completion — and
   hence no use of the read data — can follow it.
4. Same reasoning proves `no_rw_check` free: every array write is on an `sk`
   rising edge or during the reset erase, the consumed capture is on the
   non-edge cycle immediately before a rising edge, and the reset erase holds
   the serial FSM idle for its whole 64-clk duration.

The reset-erase behaviour is bit-identical (one word per clk, `init_addr` 0..63,
`dout` held at the idle high level), which `tb_ssv_gdfs_devices.sv` also checks.

## Expected saving — UNMEASURED

**The numbers below are estimates. They are not measured and must not be treated
as measured until an authorized `quartus_map` / fit run confirms them.** No
Quartus run, RBF build, or Verilator simulation was performed for this change.

Post-fix the module should contain: two MLABs (~20 memory ALMs), ~81 flops
(`shift`, `command`, `mem_q0/1`, `address`, `bit_count`, `init_addr`, plus the
odd control bits), the write mux and a handful of comparators. Expect roughly
**60–100 ALMs**, i.e. a saving of about **410–450 ALMs** against the measured
509.7. On the 5CSEBA6U23I7 (41,910 ALMs) that is ~1.0–1.1 percentage points of
occupancy, plus 2 MLABs and no change to M10K.

That is the headroom that would let the GDFS optional-I/O block be
re-instantiated in the single universal RBF instead of being pruned.

## Verification status

- `verilator --lint-only -Wall rtl/io/ssv_93c46_16.sv` produces the **identical**
  warning set to `git show HEAD:rtl/io/ssv_93c46_16.sv` (`cs_d`, `command[8]`,
  `shift[15]` unused — all pre-existing). No new lint findings.
- Focused benches that exercise these modules and still lint clean
  (`verilator --lint-only`, simulations **not** run — that lane is owned
  elsewhere):
  - `verif/tb_ssv_gdfs_devices.sv` — ADC0809 + 93C46 EEPROM + ST0020 control;
    this is the bench that pins the EEPROM serial bit timing.
  - `verif/tb_ssv_optional_io.sv` — uPD4701 + uPD7001.
  - `verif/tb_ssv_mahjong_matrix.sv` — mahjong key matrix.
  - `verif/tb_ssv_input_matrix.sv` — cabinet input ports + matrix.
- Source-integrated only. Not focused-simulation tested, not real-game tested,
  not timing-clean, not hardware-tested.
