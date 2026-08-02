# Pre-RBF optimization notes

## Where the design stands (28 Jul 2026, 12:28 compile — TIMING CLOSED)

| Resource | Used | Available | % | vs. 09:45 fit |
|---|---:|---:|---:|---:|
| ALMs | **34,366** | 41,910 | **82** | −2,966 |
| M10K | **532** | 553 | **96** | −10 |
| Block memory bits | 4,326,704 | 5,662,720 | 76 | −10,689 |
| Registers | 20,456 | — | — | −1,582 |
| DSP | 59 | 112 | 53 | — |

Setup slack, worst corner (Slow 1100 mV −40 C):

| Clock | Freq | Slack | was |
|---|---:|---:|---:|
| `pll_hdmi` scaler pixel | 148.54 MHz | **+0.392** | −0.121 |
| `clk_ram` / SDRAM | 96.63 MHz | +1.304 | +1.415 |
| `clk_sys` core | 48.32 MHz | +2.511 | +2.175 |

**All setup, hold, recovery, removal and minimum-pulse-width checks pass at all
four corners.** Worst hold is +0.100 ns. `releases/SSV.rbf` is staged
(SHA256 `846c7b02…a48e21`).

These fit and timing numbers predate the universal pooled line-entry table and
are therefore historical evidence, not release evidence for the current RTL.
The current 65,536-entry pool is steered to MLAB to protect the nearly-full
M10K budget; a fresh Quartus fit is still required after all ten attract gates
pass.

The `ascal` `o_vlastcpt` fix closed the HDMI domain by itself under the
codified Fast Fit profile — a +0.513 ns swing attributable to the RTL change
rather than to placement effort, which is why the escalation was deliberately
not spent.

**M10K, not ALM, is still the binding resource.** 448 of the 532 blocks are
`sprite_ram` (256), `palette_ram` (128) and `work_ram` (64), each already at
the Cyclone V floor of `bits / 8192` for a true-dual-port 16-bit memory. They
are board-accurate sizes; there is nothing to reclaim there. Free blocks went
from 11 to 21.

## Changes landed this pass

| Change | Effect | Verified by |
|---|---|---|
| `icache_data` fill buffered into a register, whole 64-bit line written once | Kills Quartus warning 10999; 32×64 array stops being 2,048 flops + 64-bit 32:1 muxes and maps to LUTRAM like `icache_tag` | bring-up suite + 950-frame frame-CRC equality |
| `ssv_irq`: clear before set | Same-cycle `$240000` ack no longer eats a vblank IRQ | `tb_ssv_irq`, bring-up suite |
| `AUTO_SHIFT_REGISTER_RECOGNITION OFF` | −4 M10K (two `altshift_taps` holding 449 bits total) | fit needed to confirm |
| `ascal .PALETTE("false")` | −2 M10K (`pal1_mem` is dead with `MISTER_FB` undefined; matches upstream MiSTer) | fit needed to confirm |
| `ascal i_dpram` → `ramstyle "MLAB"` | −4 M10K (32×128 DDR staging FIFO was 4 blocks for 4,096 bits; read port is on the 100 MHz `avl_clk`) | fit needed to confirm |
| `AUTO_SHIFT_REGISTER_RECOGNITION OFF` kept; `FITTER_EFFORT`/router effort left on the codified Fast Fit + NORMAL profile | The `ascal` fix deletes the add+compare chain that caused the miss, so it should close without spending fitter effort — and proving that is better information. Escalation held in reserve. | fit needed to confirm |
| `tools/report_worst_timing.tcl` emits per-clock worst paths | The global worst list is all `ascal`, which hid the core's own margin | — |
| Universal pooled `line_entries` (65,536 × 7 bits) steered to `MLAB` | Avoids spending the remaining M10Ks on the frame-wide table; accepts an ALM/mux trade that must be measured | Fresh current-source Verilator model builds cleanly; Quartus fit pending |

## Earlier changes (26 Jul, still in force)

| Change | Why |
|---|---|
| Voice FSM `S_PROC → S_POLE12 → S_FILT → S_MIX` | Break ~72 ns filter/lerp chain for timing |
| `SSV.sdc` voice MCP scoped to CE regs only | Prior MCP covered SDRAM handshake regs (unsafe) |
| `ce_snd = ce_cpu` | Phase-align OTTO with V60; drop 2nd accumulator |
| Icache + scroll `ramstyle=MLAB` | Pull distributed RAM out of ALMs |
| Sprite `CACHE_ENTRIES` 2048→1536 | Free M10K (attract used ~1277) |
| `ENABLE_DIAG_VIDEO=0` | Strip diag raster for release candidate |
| ES5506 banks → `ssv_mlab32_sdp` (altsyncram MLAB) | Inference failed on array-in-always_ff; map rose to ~42.4k ALMs |

## Pass of 28 Jul 2026 (evening) — M10K hunt before the next fit

Starting point: **532 / 553 M10K (96%)** against **34,524 / 41,910 ALMs (82%)**. M10K is the
binding resource by a wide margin, so anything that trades block RAM for logic is a good
trade at this operating point even when it looks like a regression on paper.

### Where the 532 blocks actually live

| Owner | Blocks | Reclaimable? |
|---|---:|---|
| `sprite_ram` 256, `palette_ram` 128, `work_ram` 64 | **448** | **No.** Each is exactly its decode window — `$100000-$13ffff`, `$140000-$15ffff`, `$000000-$00ffff` — and each sits at the Cyclone V floor for a 16-bit dual-port memory |
| `sys/` — `ascal` 30, two OSD buffers 8, `shadowmask` 1 | **39** | **No.** Upstream framework; editing it is a hard stop in `CLAUDE.md` |
| Sprite renderer — `descriptor_cache` 22, `line_entries` 21, `line_page_starts` 2 | **45** | Partly — see below |

The 448 deserve a word, because "76% of block memory bits but 96% of blocks" invites the
theory that something is packed wastefully. It is not. A 16-bit memory can only use 8,192 of
an M10K's 10,240 bits, because the useful geometries are 256×40 / 512×20 / 1024×10 — none of
which divides 16 evenly. That 20% is a device property, not a design flaw, and the only way
to capture it would be to pack five 16-bit words into four 20-bit locations. **448 is the
floor for this memory map**, and the memory map is board-accurate.

### Taken this pass

| Change | Expected | Why it is safe |
|---|---|---|
| `line_page_starts` (240×180 with the universal 2048-entry descriptor cache) `ramstyle` M10K → **MLAB** | **−2 M10K**, MLAB cost to confirm | Shares `line_count_addr`, its access shape *and* its read/write states with `line_counts` three lines above, which has been MLAB all along. The `no_rw_check` argument documented there covers it unchanged; the wider universal metadata table must be checked in the next fit. |
| `descriptor_cache` split into **`_lo[52:0]` + `_hi[127:53]`** | up to **−4 M10K** | Lever 4 below. Same bits, same addresses, same cycle — a packing hint, not a capacity change |

The split point is **53, not the natural 64**. Bits 106..127 are dead, so a 64/64 split
leaves all the slack bunched in the upper half and saves nearly nothing; splitting the *live*
106 bits evenly is what lets each half land on 3 slices of 512×20 across 3 depth rows.

**Verified behaviour-neutral.** Same 1,250-frame `coin_start_p1_long` soak before and after,
CRC streams compared as whole files rather than eyeballed:

```
$ md5sum baseline_rename.crc long_frames.crc
a8abacd020b8662609a4cb7defdaa26f  baseline_rename.crc
a8abacd020b8662609a4cb7defdaa26f  long_frames.crc
```

Every derived counter matched too — `CACHE_BUILD max=44020 (frame 527)`, `P1_LATENCY=0`,
`bg_ack_while_obj_owns=0`, `nonblack=59948119`, `pc=00f1057b`, `max_line_entries=86`,
`overruns bg=0 obj=0`.

Both figures are still **predictions until the next fit**. The changes are behaviourally
proven; the M10K savings are not, because only the Fitter RAM Summary can confirm which
packing mode Quartus actually chose. Check `line_page_starts` has moved to the MLAB column,
and that `descriptor_cache_lo` + `descriptor_cache_hi` together come to fewer than 22 blocks.
If either is unchanged, the change is inert rather than harmful — but say so rather than
carrying a claimed −6 that never happened.

### Ruled out this pass, with the reason

- **`ascal o_dpram` → MLAB (−4).** Lever 3's stated precondition is now met — the 148.5 MHz
  domain came back clean at +0.392 ns. But `ascal.vhd` lives in `sys/`, and `CLAUDE.md` makes
  that a hard stop rather than a judgement call. Left alone deliberately; it is available if
  the framework rule is ever revisited.
- **`descriptor_cache` 1536 → 1024 entries (−11).** Already a recorded dead end on attract
  (~1,277 descriptors). The testbench now prints `CACHE_PEAK` every run, and gameplay is far
  worse than attract:

  ```
  CACHE_PEAK=1519 of 1536 entries (frame 527)
  ```

  **Seventeen spare slots — 1.1% headroom.** This is not merely "1024 is too small"; it says
  1,536 is itself close to marginal, and it was chosen when attract's ~1,277 was the only
  number anyone had. Nothing overflowed across 1,250 frames (`overruns obj=0`), so there is
  no defect to fix and no justification for spending 22 more M10K on a bigger cache when only
  21 blocks are free. But **growing** this cache is now a known future cost, and any change
  that raises descriptor counts should re-read `CACHE_PEAK` before being believed. Worth a
  wider scenario sweep at some point purely to find the real ceiling.
- **The `scroll` file (~1k flops).** Carried `ramstyle = "MLAB"`, which was never achievable
  and was being silently ignored — the fit report lists `scroll[63][1]`, `scroll[62][0]` and
  friends as discrete registers. All 64 words are read combinationally in parallel by
  `sprite_offsets`, `tilemap_scrolls` and the individual control words, and the array takes a
  reset; both rule out memory inference. The attribute is removed and replaced with a comment
  explaining why flops are correct here. **No resource change** — this is documentation
  honesty, not an optimisation.

### ALMs: one honest answer

`s32_v60` is **20,015 ALMs — 58% of the entire design**. Nothing else is close
(`sprite_renderer` 2,032, `ascal` 2,147, `sound_registers` 936). There is no meaningful ALM
reduction available anywhere else, and the V60 route is opcode gating, which the audit that
produced the hit list explicitly recommended shipping *enabled*. So: no ALM change this pass,
by choice rather than by omission. At 82% that is the right call — ALMs are not what is
scarce.

## Remaining levers, ranked

0. **Check the two M10K predictions from the 28 Jul evening pass** in the next
   Fitter RAM Summary: `line_page_starts` should leave the M10K column for
   MLAB (−2), and `descriptor_cache_lo` + `descriptor_cache_hi` should total
   under 22 blocks (−4 if they land on 512×20). Expected total: 532 − 6 = **526**.
   Both are behaviourally verified already; only the packing is unproven.
1. **Re-fit and re-STA.** Everything above is uncompiled. Nothing here counts
   until `report-quartus.ps1 -RequireReady` is true. Two specific things to
   check in that report rather than assume:
   - `Arcade-SSV.map.rpt` must be free of warning **10999** (`can't infer
     memory`). `i_dpram` is now asked for LUTRAM; if Quartus declines the
     dual-clock MLAB it should fall back to M10K (status quo, harmless), but a
     fall back to *logic* would cost ~4,096 flops and must be reverted.
   - The Fitter RAM Summary should show `pal1_mem` gone and both
     `altshift_taps` gone. Expected total: 542 − 4 (shift taps) − 2 (`pal1_mem`)
     − 4 (`i_dpram`) = **532**.
2. **V60 area (up to several thousand ALMs).** `s32_v60` is 19,917 ALMs —
   nearly half the device. The decimal (`0x59`), bit-string (`0x5B`),
   bit-field (`0x5D`) and FP (`0x5C`/`0x5F`) groups are all partial
   implementations. Produce a MAME opcode hit list over a full Dyna Gear
   playthrough, then parameter-gate whatever never executes. Do **not** guess.
3. **`ascal o_dpram` → MLAB (−4 M10K).** *Precondition met, but blocked.* The
   148.5 MHz domain came back clean at +0.392 ns, so the "wait for the STA"
   condition is satisfied. `ascal.vhd` is in `sys/`, however, and `CLAUDE.md`
   treats that as a hard stop rather than a cost/benefit call — so this is
   deliberately **not** taken. It remains the cheapest −4 available if the
   framework rule is ever revisited for this core.
4. ~~**Descriptor-cache geometry (up to −4 M10K, cheap).**~~ **Taken 28 Jul
   2026** — split into `descriptor_cache_lo[52:0]` + `descriptor_cache_hi[127:53]`.
   Split at 53 rather than 64 because bits 106..127 are dead. Confirm the
   realised packing in the next Fitter RAM Summary; the change is behaviourally
   neutral by construction, so a null result costs nothing but is worth knowing.
5. **Precompute sprite descriptor coordinates (~−8 M10K, ~−400 ALMs).**
   Storing resolved `sx`/`sy`/`code`/`color` instead of raw local+global words
   gets the descriptor under ~60 bits and deletes the duplicated render-side
   coordinate maths. Needs full frame-CRC re-validation and freezes
   `flip_control` / `local_control` at vblank.
6. **Seed sweep.** For a sub-nanosecond miss, sweeping `SEED` is cheaper than
   any RTL change. Currently 1.
7. **Fitter effort escalation, held in reserve.** If the STA after the `ascal`
   fix still misses, `FITTER_EFFORT "STANDARD FIT"` +
   `ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM` are the next lever — the design
   is at ~89% ALMs (lower after the icache fix), so the extra placement effort
   is affordable now in a way it was not at 99%. Note `tools/build-ssv.ps1`
   `Assert-BuildPolicy` pins the Fast Fit profile, so changing it means
   updating that guard deliberately, not drifting past it.

### Running the build on this host

`tools/build-ssv.ps1` defaults `-QuartusRoot` to `C:\intelFPGA_lite\17.1`,
which does not exist here. Quartus 17 is installed at **`D:\Q17`**:

```
pwsh tools/build-ssv.ps1 -QuartusRoot D:\Q17
```

The script also refuses to start while any `quartus*` process is running. That
guard is correct — this host shares the toolchain with other cores, and the QSF
pins `NUM_PARALLEL_PROCESSORS 1` because of an Access Violation at 4-way.

### Measured dead ends (do not retry)

- Narrowing the descriptor "losslessly": the genuinely-used bits total 102
  (`l2[15:12]` is the depth field when `local_control[14]` selects the local
  size fields), which is very unlikely to cross a packing boundary on its own.
- `LINE_ENTRY_LOW_WIDTH` 7 → 10 to delete the page table: `line_entries`
  (23040×7) landed on 21 blocks, uniquely `3 depth slices × 7 bit-planes`, i.e.
  ×1 packing where every extra bit of width costs 3 more blocks. **+9, not −2.**
- `CACHE_ENTRIES` → 1024 (−11 M10K) and `LINE_SLOTS` → 68 (−7 M10K) both drop
  real sprites: attract already uses ~1277 descriptors and the measured peak is
  86 on one scanline.

## Explicit non-goals until ReadyToDeploy

- Deploying a timing-failing or stale RBF
- Inventing ES5506→`ssv_irq` wiring for Dyna Gear
- Growing BRAM
