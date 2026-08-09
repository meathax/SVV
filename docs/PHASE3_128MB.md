# Phase 3 — retarget to the 128 MB SDRAM module

Target hardware: a single **64M × 16** SDR module on GPIO0 (XS-D class),
replacing the 32 MB part.

## Geometry

128 MB = 2^26 word addresses. The DE10-Nano exposes only `SDRAM_A[12:0]` and
`SDRAM_BA[1:0]`, so the row address caps at 13 bits and:

```
bank_bits + row_bits + col_bits = 26
    2     +    13    +    11    = 26
```

**4 banks × 8192 rows × 2048 columns × 16 bit = 128 MB.** No other
decomposition is reachable: 8 banks needs `BA[2]`, 16384 rows needs `A[13]`,
neither routed. `A10` remains auto-precharge (JEDEC), so the 11th column bit
rides on **A11**.

| | bank | row | column | CAS A-field |
|---|---|---|---|---|
| was (32 MB) | `a[24:23]` | `a[22:10]` | `a[9:1]` | `{2'b00, AP, a[10:1]}` |
| **now (128 MB)** | `a[26:25]` | `a[24:12]` | `a[11:1]` | `{1'b0, a[11], AP, a[10:1]}` |

`rtl/mem/sdram.sv` is now parameterised (`BANK_BITS`/`ROW_BITS`/`COL_BITS`/
`TRFC_CYC`/`REF_CYC`) and slices every address through derived localparams
(`BANK_HI/BANK_LO/ROW_HI/ROW_LO/COL_HI`) rather than literal bit numbers — a
stale literal slice is exactly how silent aliasing gets in. `verif/ssv_sdram_chip.sv`
and `verif/ssv_sdram_harness.sv` take the same parameters.

`refw_cnt` was widened 3 → 4 bits: it **could not express a tRFC of 11**, and a
tRFC violation is silent bit rot rather than a hang.

## Bank map — and why it is not contiguous

`ssv_pkg.sv` now places regions in **separate banks** (bank = byte address
`>> 25`, i.e. 32 MB per bank):

| bank | base | contents |
|---|---|---|
| 0 | `0x0000000` | V60 program, XRAM (`$160000`), CPU RAM (`$400000`) |
| 1 | `0x2000000` | packed graphics records |
| 2 | `0x4000000` | free |
| 3 | `0x6000000` | ES5506 samples |

Each bank holds one open row, so two clients sharing a bank evict each other and
pay PRE + tRP + ACT + tRCD = 6 clk_ram, twice.

**This was measured, not assumed.** Widening the geometry while leaving the old
32 MB map in place put the *entire* layout inside bank 0, because the bank field
moved from `a[24:23]` to `a[26:25]`:

| metric | 32 MB baseline | 128 MB, old map | 128 MB, bank-separated |
|---|---:|---:|---:|
| row conflicts (215 frames) | 564,030 | **1,033,032** | **387,367** |
| p2 row-hit rate | 92.04 % | 88.98 % | **93.33 %** |
| p2 latency avg (clk_ram) | 14.66 | 15.07 | 14.69 |

Cross-client conflicts go to **exactly zero** with the bank map — p0→p2, p2→p0
and every p4 pairing are 0. What remains is purely self-conflict (p2→p2
202,708, p4→p4 170,995, p0→p0 13,662), which is what bank separation is
supposed to leave behind: each client now owns its bank.

`layout_fault()` was reworked from ordered-adjacency to **pairwise
non-overlap**, because a bank-separated map is deliberately not ascending and
contiguous. Rule 5 now bounds both graphics and samples against
`SDR_TOTAL_BYTES` (128 MB).

High-water is 104 MB once the slots are sized for the worst case across the
nine titles (4 MB program, 32 MB graphics, 8 MB samples), against 44.4 MB of
actual data in the largest set.

## Verification

**The frame CRC cannot gate this change, and pretending otherwise would be
wrong.** Changing bank/row/column mapping changes memory latency, which changes
V60 instruction timing, which changes frame content at the margins in a
timing-sensitive game. The 32 MB golden legitimately does not reproduce.

What *is* asserted:

- **`tb_ssv_sdram_loopback` PASS at COL_BITS 9, 10 and 11**, with identical
  transaction costs at all three: `SDRAM_COST p1=9 p0=6 p4=6` — the same values
  the 32 MB build produced, so the parameterisation is cost-neutral.
- **Negative test: controller at COL_BITS=11 against a COL_BITS=9 part FAILS**,
  as it must:
  ```
  %Fatal: MISMATCH p0 addr 000000 (bank 0 row 0 col 0): got 126a expected 126e
  ```
  A self-test that cannot fail proves nothing; this one detects the exact
  aliasing a wrong module would cause.
- The parameterisation **at COL_BITS=9 is bit-neutral**: 215-frame gameplay
  frame-CRC md5 `0f45c3c0…`, identical to the pre-change baseline.
- Full-core run at 128 MB: `PASS`, **0 background and 0 object overruns**, peak
  line occupancy 57 of 96 unchanged.

**Limit of the loopback evidence, added 2026-07-30.** `verif/ssv_sdram_chip.sv`
takes the same `BANK_BITS`/`ROW_BITS`/`COL_BITS` and derives its read-return
alignment from the same `CL` as the controller, so a `tb_ssv_sdram_loopback` PASS
asserts that controller and model are *mutually consistent* — not that either
matches the physical part. The negative test above detects a geometry
disagreement; nothing here can detect a shared wrong assumption about latency or
capture margin, and `SSV.sdc` places no constraint on the SDRAM pins at all. See
[`issues/SDRAM_READ_LATENCY_BLACK_SCREEN.md`](issues/SDRAM_READ_LATENCY_BLACK_SCREEN.md).

## Still open

- ~~tRFC and the refresh period have not been read off the fitted part.~~
  **CLOSED, by deduction rather than datasheet.**

  The open risk was the row count: if the part had 16384 rows / 64 ms, a 700-cycle
  refresh interval would have been too slow, and that failure is silent bit rot
  rather than a hang. But the row count is not a free variable. The DE10-Nano
  routes only `SDRAM_A[12:0]` and `SDRAM_BA[1:0]`, so 128 MB is reachable ONLY as
  4 banks x 8192 rows x 2048 columns -- 8 banks needs `BA[2]`, 16384 rows needs
  `A[13]`, neither exists. **Any 128 MB part that works on this pinout at all has
  8192 rows**, so the requirement is fixed at 8192 / 64 ms = one REF every
  7.8125 us.

  | | value | requirement | margin |
  |---|---|---|---|
  | `REF_CYC` 700 | 7.2428 us | <= 7.8125 us | **7.3 %** |
  | `TRFC_CYC` 11 | 12 cycles = 124.2 ns | >= 110 ns (120 ns worst common) | **13 %** |

  Refresh costs about 2 % of the bus. Both values are chosen to be safe for any
  plausible 1 Gbit part rather than tuned to one; a part number would only let us
  tighten them, and there is no correctness risk in not having it.
- **No `sdram_sz` gate** (explicit decision). A user with a 32 MB module gets
  silent 4:1 aliasing.

  **Corrected 2026-07-30: "looks like corrupt graphics" understated this
  badly.** On a 32 MB part the byte address wraps at `0x2000000`, and all four
  region bases are exact multiples of it — `SDR_MAINCPU_BASE 0x0000000`,
  `SDR_GFX_BASE 0x2000000`, `SDR_ST010_BASE 0x4000000`,
  `SDR_SAMPLES_BASE 0x6000000` (`rtl/ssv_pkg.sv:66-95`). All four therefore
  alias onto address 0: the graphics stream lands on top of the V60 program and
  **destroys it**. The symptom is a core that does not run at all, not a
  cosmetic one.

  The remedy, if it ever matters, is the power-on aliasing self-test — the
  loopback negative test above shows the detection works. The wrapper's existing
  ROM-signature probe (`Arcade-SSV.sv:290-397`) is already most of it; see
  [`issues/SDRAM_READ_LATENCY_BLACK_SCREEN.md`](issues/SDRAM_READ_LATENCY_BLACK_SCREEN.md)
  for what happens when its result is not visible on hardware.
- The graphics region is 32 MB of address space in one bank, so graphics still
  self-conflicts (202,708). Interleaving graphics across banks would attack
  that, but at ~0.6 % of the bus it is not currently worth it.
