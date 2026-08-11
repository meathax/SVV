# Pre-RBF optimization notes

## Scanline-buffer ALM relief (10 Aug 2026, fit pending)

The seed-3 fit closed the former SDRAM setup failure but remained just outside
the release gate at -0.055 ns hold in `clk_sys` and -0.017 ns setup in the
MiSTer HDMI domain.  Routing was not congested (34% average, 56% peak), so
broad floorplanning or framework/PLL edits are not justified.

The fitter's per-entity and RAM tables exposed a safer pressure reduction:
the eight 88x15 simple-dual-port banks in `ssv_line_buffer4` were implemented
as MLABs at about 42-44 ALMs each, roughly 346 ALMs total, and the router also
duplicated several of their output registers.  That fit had 36 spare M10Ks but
only 2,810 spare ALMs.  The banks are now explicitly steered to eight M10Ks,
preserving their registered-read/write schedule while removing distributed
RAM from the binding resource.  Expected balance from the retained fit is
about 38.75k ALMs and 525 M10Ks; only a fresh map/fit may claim the actual
numbers or timing effect.

`report-quartus.ps1` now fails closed unless a fresh fit proves exactly eight
M10K line-buffer placements.  Slang reports zero errors/warnings and the
standalone Icarus line-buffer regression passes (`clear_clocks=88`).  No new
Quartus build or RBF was run for this change.

## Shared multiplier and renderer placement pass (10 Aug 2026, no Quartus/RBF)

The newest retained fit completed placement at 39,397/41,910 ALMs (94%),
516/553 M10Ks and 53/112 DSP blocks, but failed `clk_ram` setup at -1.039 ns.
Its first failing paths were the SDRAM row-conflict/address cone into the fixed
SDRAM output cells.  The already-present registered `ST_PRE_CMD` correction
removes that cone and its focused command-sequence test passes; the timing gain
still requires a fresh authorized fit.

The fit's DSP detail table exposed one avoidable V60 structure: the single
`MULX/MULUX` 32x32 operation sign/zero-extended both operands to 64 bits before
using `*`.  Quartus decomposed that expression into nine logical multiplier
fragments consuming all ten V60 DSP blocks.  Extended multiply now reuses the
CPU's existing 32-step magnitude shift-add engine and applies sign correction
once to its complete 64-bit result.  No opcode or optional device was removed.
While proving the reuse, an existing carry-loss in the serial upper-half add
was found and corrected by retaining its 33rd carry bit.  Exact arithmetic
comparison passed 4,050 signed/unsigned edge and randomized 32-bit operand
pairs.  The directed memory-destination bench now also covers negative signed
and high-bit unsigned qword products.  Expected synthesis effect: remove the
ten V60 DSP blocks and their duplicated operand-routing fabric; no ALM/DSP
saving is claimed until a current map report confirms it.

The renderer's `line_bases` table appeared twice in the fit as two 120-MLAB
copies.  The second copy existed only because `reindex_pool_addr` read the
array asynchronously even though the FSM had already read the same bucket into
`line_base_q`.  The read-ahead schedule advances `line_count_addr` and
`bucket_y` together, so the registered base is cycle-aligned with
`line_count_q`; reindex now reuses it.  Base and count always share an address
and are consumed together, so the remaining 240x15 base and 240x12 count fields
are packed into one 240x27 M10K.  This trades one of 37 spare M10Ks for at least
240 memory ALMs, eliminates the duplicate read port/table, and avoids wasting a
second block on separately addressed metadata.  `report-quartus.ps1` now fails
closed unless a fresh fit shows exactly one M10K `line_meta` instance.

Static verification: Slang reports zero errors and warnings for the affected
V60 directed benches, cached-renderer bench, and SDRAM command-timing bench.
The SDRAM test also executes under Icarus and reports PASS.  The installed
Icarus cannot elaborate the full V60/renderer benches because of pre-existing
enum-cast and package-syntax limitations; the required visible-model
regressions remain pending.  No Quartus stage or RBF build was run.

## RTL placement and build-process audit (10 Aug 2026, no Quartus/RBF)

- The latest fit report is stale against the current source, but its resource
  table exposed the placement miss: `line_page_starts` was requested as MLAB
  and nevertheless consumed five M10Ks (`240 x 180` bits). With only 14 M10Ks
  free in that fit, the attribute was not evidence of the intended placement.
- Replaced the inferred `line_page_starts` array with the explicit
  `ssv_mlab240_sdp` one-write/one-read MLAB wrapper, while preserving the
  renderer's registered-read timing and reset masking. The Quartus source
  manifest and all direct simulation manifests now include the wrapper.
- `tools/report-quartus.ps1` now reads the fitter RAM-type table and requires
  `line_page_starts=MLAB` before reporting `ReadyToDeploy`. A fresh map/fit is
  required to measure the actual M10K reduction; no saving is claimed yet.
- `tools/build-ssv.ps1` now owns a machine-wide named Quartus mutex and writes
  a temporary owner record with the project, revision and process IDs. It
  queues behind any existing Quartus process (or fails fast with `-NoWait`),
  preventing concurrent projects from corrupting the shared toolchain state.
- `tools/seed-sweep.ps1` routes both per-seed QSF edits and the final seed pin
  through that same owner path, so a queued sweep cannot rewrite the project
  while another wrapper is between slot acquisition and Quartus launch.

Focused verification: the standalone MLAB wrapper test passed and Slang parsed
the cached-renderer top with zero errors or warnings. A full visible-SDL
Verilator run and Quartus map/fit remain pending; no final RBF was built.

## Exact RTL resource pass (10 Aug 2026, no Quartus/RBF)

- V60 MUL/MULU now uses the existing 32-cycle magnitude shift-add result for
  both writeback and overflow.  The completion path previously instantiated
  two additional 32x32 multipliers only to recompute signed and unsigned
  overflow.  Exhaustive byte plus randomized half/word comparison covered
  931,072 operand/mode cases with zero result or flag mismatches.
- The sprite descriptor cache stores an 88-bit resolved visual record instead
  of eight raw 16-bit words.  Coordinate, flip, code, size and scroll controls
  are frozen at the vblank cache boundary, removing 40 bits per entry and the
  duplicate render-side coordinate network while preserving list priority.
- Added frame-wide line-pool high-water telemetry.  Seven runnable qualified
  sets completed visible-SDL startup/attract samples without overflow; Dyna
  Gear was highest at 11,060 entries.  Ultra X remains untested because its
  private `sim_output/rom/ultrax/st010.bin` is absent.  The pool is reduced
  from 32,768 to 24,576 entries: over 2x the measured peak and above the older
  23,040-entry gameplay table.  Dyna Gear's before/after frame-CRC stream is
  byte-identical at the reduced depth.
- Hiscore configuration fields are one packed 16x48 MLAB table rather than
  four tiny independent memories, and the persistent/temporary 256-byte
  stores occupy opposite halves of one 512x8 true-dual-port M10K rather than
  two blocks.

Verification: Slang parsed the V60 and cached-renderer tops with zero errors or
warnings; Icarus elaborated the packed hiscore module.  Visible-SDL Verilator
completed Cairn Blade through native frame 120 and Dyna Gear, Vasara, Vasara 2,
Drift Out '94, Storm Blade and Twin Eagle II through frame 60 with empty error
logs and no `CACHE_OVR`.  Cairn Blade matched the historical `fc93d295` frame
checksum and Dyna Gear matched `9c39477d`; Dyna Gear's complete CRC artifact
SHA-256 stayed `D635A394...94077ACD8` before/after the pool reduction.

Resource savings remain estimates until an explicitly authorized Quartus map
and fit.  Expected structural changes are: two fewer V60 32x32 multipliers,
81,920 fewer descriptor-cache bits, 57,344 fewer line-pool bits (one 8,192-row
M10K tier), four config-table M10Ks moved to MLAB, and two score-store M10Ks
merged to one.  The repository profile audit currently stops because
`releases/Arcade-SSV.rbf` is intentionally absent; no stale release was
created to satisfy it.

## Universal release integration pass (9 Aug 2026, no Verilator/Quartus)

- Removed the `SSV_ST010_ENABLED` compile-time fork. The DSP and p5 program
  fetcher are now always synthesized and runtime-gated only by
  `cfg.has_st010`, as required by the one-RBF profile.
- Removed the stale `DBG_SDRAM_PAINT` release macro. The current `CONF_STR`
  contains no debug/diagnostic menu entries; Service Mode and CRT adjustment
  are user-facing controls and were retained.
- Removed an unfinished background-frame snapshot and live sprite-descriptor
  reread experiment before release. It had no focused functional coverage and
  would have added about 335 Kbits of tile/context storage plus its control and
  mux logic; the proven compact descriptor cache and bounded line pool remain.
- Made `files.qip` the sole user-source manifest. The QSF previously sourced it
  and then repeated an incomplete subset, obscuring whether optional devices
  were really in the RBF.
- Replaced the two deep hiscore true-dual-port descriptions with the actual
  simple-dual-port access shape. The 7 Aug map report says both were
  `uninferred due to asynchronous read logic`, previously measured at roughly
  1,387 ALMs. The new template uses one write port and one unconditional
  registered read port; expected cost is two M10Ks and far fewer ALMs.
- Extended the profile audit and build policy guard to reject diagnostic QSF
  macros, duplicate user-source declarations and a future compile-time ST010
  gate.

No resource or timing improvement is claimed yet. The latest available fit is
not a valid baseline for the next RBF: it omitted ST010, left the hiscore RAMs
in logic, used 39,418 ALMs and 523 M10Ks, and had -0.050 ns worst slack. The
next authorized flow must first run the affected visible-SDL Verilator
regressions, then map/fit to confirm ST010 cost, hiscore M10K inference and
timing.

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
M10K budget; a fresh Quartus fit is still required after all eight attract gates
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

0. **Confirm the explicit MLAB placement** in the next Fitter RAM Summary:
   `line_page_starts` must leave the M10K column for MLAB. The old inferred
   array was measured at five M10Ks; the replacement's actual savings remain
   unmeasured until a current fit.
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
   any RTL change. The current QSF seed is 2; `tools/seed-sweep.ps1` routes
   each edit through the global Quartus slot.
7. **Fitter effort escalation, held in reserve.** If the STA after the `ascal`
   fix still misses, `FITTER_EFFORT "STANDARD FIT"` +
   `ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM` are the next lever — the design
   is at ~89% ALMs (lower after the icache fix), so the extra placement effort
   is affordable now in a way it was not at 99%. Note `tools/build-ssv.ps1`
   `Assert-BuildPolicy` pins the Fast Fit profile, so changing it means
   updating that guard deliberately, not drifting past it.

### Running the build on this host

`tools/build-ssv.ps1` defaults `-QuartusRoot` to **`D:\Q17`**:

```
pwsh tools/build-ssv.ps1 -QuartusRoot D:\Q17
```

The script owns a machine-wide named slot, queues behind any `quartus*` process
started outside the wrapper, and records the owner in the system temp folder.
Use `-NoWait` only for a deliberate fail-fast probe. The QSF pins
`NUM_PARALLEL_PROCESSORS 1` because of an Access Violation at 4-way.

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
