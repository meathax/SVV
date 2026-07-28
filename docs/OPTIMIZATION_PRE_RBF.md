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

## Remaining levers, ranked

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
3. **`ascal o_dpram` → MLAB (−4 M10K).** `i_dpram` is already done. `o_dpram`
   is the same 32×128 shape, but its read port is on the 148.5 MHz `o_clk` —
   the only domain currently missing setup. Do this *after* the next STA shows
   that domain clean, not before.
4. **Descriptor-cache geometry (up to −4 M10K, cheap).** Quartus packed the
   1536×106 cache as 2 slices of 1024×10 = 22 blocks; 3 slices of 512×20 would
   have been 18. Splitting the array into two ~53-bit halves usually steers
   this. Test it against the fit report — do not assume the mode.
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
