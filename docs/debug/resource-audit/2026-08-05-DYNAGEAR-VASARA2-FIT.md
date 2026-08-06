# Resource audit — getting Dyna Gear + Vasara 2 to fit together

Context: the current committed codebase (before this pass) cannot produce
an RBF at all — confirmed by a real Quartus 17.0.2 build, isolated from any
of this session's other changes. This audit's goal was pure static analysis
and implementation of safe, evidence-backed resource reductions — **no
Verilator, fit, or build run as part of this pass** (per explicit
instruction); everything below is reasoned from source code, prior
documented measurements, and one real build's error output/resource report
captured earlier in this session, not from a fresh fit.

## Finding 1 — `line_entries` was catastrophically oversized (the build blocker)

`rtl/video/ssv_cached_sprite_renderer.sv`: the sprite-line cache pool
(`LINE_POOL_ENTRIES`) was 65,536 entries, steered to MLAB. Confirmed by a
real build this session:
- As MLAB: needs ~1,024 MLAB depth-slices; the device has 985 total, for
  every MLAB consumer in the whole design combined.
- As M10K (tested by reverting the `ramstyle`): needs more than the
  device's entire 553-block M10K budget, by itself.

`docs/M10K_REDUCTION.md` (an earlier session's real-fit-based analysis)
had already measured this exact structure at its *previous* size — 23,040
entries, fixed 96-per-line × 240-line table, M10K-placed — against real
Dyna Gear gameplay: **zero drops, peak occupancy only 57-90 of the 96
per-line cap**, costing 21 M10K blocks. A later, undocumented "universal
profile" change (2026-08-02) tripled it to 65,536 and moved it to MLAB,
explicitly noting *"the later Quartus fit must confirm the expected ALM
trade and timing"* — that confirmation never happened until this session,
and it fails completely.

**Fix:** `LINE_POOL_ENTRIES` set to 32,768 (half of the broken value, ~1.5×
Dyna Gear's measured hard cap, ~1.5-2.4× its actual observed peak usage),
`ramstyle` reverted to `M10K, no_rw_check` (the placement that was actually
measured to work). Estimated cost ≈30 M10K blocks (scaled from the
21-block/23,040-entry measurement). **Vasara 2's own requirement is not
independently measured** — this is a reasoned margin over Dyna Gear's
number, not a confirmed bound for Vasara 2. Documented in the source
comment: re-check via `cache_overflow` (already wired to the overrun LED)
across both games' regression scenarios once simulation resumes; raise the
pool if it ever asserts.

## Finding 2 — ST010 DSP costs real ALMs on every build, used by neither target game

`upd96050_st010`/`ssv_st010_prg_fetch` (the ST010/uPD96050 daughterboard
DSP) were instantiated unconditionally in `rtl/ssv_core.sv`. `cfg.has_st010`
already gates all *runtime* behavior correctly (idle when unused), but
runtime-idle logic still occupies its full static ALM footprint at
synthesis time. Neither Dyna Gear nor Vasara 2 uses ST010 — only
drifto94/stmblade do, and per the new incremental-game workflow those
aren't in scope for this RBF.

**Fix:** wrapped both instantiations in `` `ifdef SSV_ST010_ENABLED ``,
undefined by default (excluded from the Quartus/RBF build — `Arcade-SSV.qsf`
does not define it). Added `+define+SSV_ST010_ENABLED` to every full-core
*simulation* build script (`verif/run_*.sh`, `tools/build_ssv_visual.ps1`)
so simulation behavior for drifto94/stmblade testing is **unchanged** —
only the hardware release build's resource footprint changes. Re-enable by
defining `SSV_ST010_ENABLED` (already documented at the instantiation site)
when drifto94/stmblade become the active target.

Resource savings not independently measured this pass (no build run) —
expect a genuine but currently-unquantified ALM reduction; the module
includes a full ALU/multiply/divide DSP core plus control FSM.

## Finding 3 — `hiscore.v`'s score-table RAM was silently falling into logic, again

`rtl/hiscore.v`'s `dpram_hs` (the high-score save/load true-dual-port RAM,
used for the two 256-byte score buffers) had an existing `ramstyle = "M10K,
no_rw_check"` fix from a prior session, with a code comment documenting a
prior cost of **1,003 + 384 ALMs (≈3.3% of the device)** when Quartus fell
back to logic. Despite the attribute, **the current build hit the identical
failure** — `Warning (10999): can't infer memory for variable 'ram'` at
exactly this array, confirmed as the only occurrence of this warning
anywhere in the design.

Root cause: a documented Quartus 17 limitation (also noted in this
project's global CLAUDE.md) — the registered read (`q_a <= ram[addr_a]`)
sat inside a conditional (`else`, only when `!we_a`). `no_rw_check` waives
same-address read/write *coherency*, but does not fix this separate
requirement for an *unconditional* registered read to infer a real M10K
read port.

**Fix:** restructured both ports so the array read happens unconditionally
every cycle, with the write-first bypass applied on the output from a
one-cycle-delayed copy of `we`/`d` instead of conditioning the read itself.
Verified the new structure is cycle-for-cycle timing-identical to the
original (traced both branches by hand; `q_a`/`q_b` update on the exact
same clock edge as before in both the write and non-write cases). If this
now infers correctly, recovers the documented ~1,387 ALMs; unconfirmed
without a build.

## Investigated, not a bug

- **`icache_data`/`icache_tag` MLAB duplication** (`rtl/ssv_core.sv`): the
  map report showed two physical MLAB copies of each. Confirmed legitimate
  — two genuinely independent simultaneous readers (the regular CPU
  data-bus ROM path and the separate FAST_IFETCH wide-fetch path), not an
  accidental duplication. Only ~2.4 KB total; not worth the architectural
  risk of time-multiplexing for this pass.
- **`s32_big_dpram`** (work RAM, sprite RAM, palette RAM): uses an explicit
  `altsyncram` primitive under `` `ifdef ALTERA_RESERVED_QIS `` for real
  synthesis, not generic-array inference — immune to the class of bug found
  in `hiscore.v`. No issue.
- **Other `ramstyle`-tagged arrays in `ssv_cached_sprite_renderer.sv`**
  (`line_bases`, `line_counts`, `line_page_starts`, `descriptor_cache`):
  the same build's map report already showed these successfully inferring
  as MLAB/M10K with correct dimensions (not falling back to logic) before
  this pass — their read/write *shape* was never the problem, only
  `line_entries`' size and placement type.

## Open question, not acted on

`CACHE_ENTRIES` (descriptor cache depth) is currently 2048;
`docs/M10K_REDUCTION.md` references a peak-occupancy measurement of
"1519 of 1536" from when it was apparently 1536. Git history for the exact
string `CACHE_ENTRIES = ` shows no change — the discrepancy is unexplained
and not investigated further this pass (descriptor_cache is not
catastrophically over budget the way `line_entries` was, so this wasn't
prioritized). Worth a look if more M10K slack is ever needed.

## Summary of changes (all uncommitted)

| File | Change |
|---|---|
| `rtl/video/ssv_cached_sprite_renderer.sv` | `LINE_POOL_ENTRIES` 65,536→32,768; `line_entries` ramstyle MLAB→M10K |
| `rtl/ssv_core.sv` | ST010 instantiation wrapped in `` `ifdef SSV_ST010_ENABLED `` (undefined by default) |
| `rtl/hiscore.v` | `dpram_hs` deep-array read restructured for M10K inference (both ports) |
| `verif/run_*.sh` (9 files), `tools/build_ssv_visual.ps1` | Added `+define+SSV_ST010_ENABLED` so simulation coverage is unaffected |

**None of this has been verified by a build.** The next step is a real
Quartus compile to confirm these estimates and find the actual remaining
M10K/MLAB/ALM headroom for Dyna Gear + Vasara 2.
