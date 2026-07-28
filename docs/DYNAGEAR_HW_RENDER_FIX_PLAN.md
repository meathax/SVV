# Dyna Gear — hardware render fix plan

Created 28 July 2026, after the first timing-clean RBF booted on MiSTer and
failed to render.

## The problem in one paragraph

The core boots on real hardware and gets further than any previous build: ROM
download, SDRAM init, the program signature probe, V60 reset and execution, and
the game's own `$21000E` video-enable write all complete. But the active area
is a uniform palette-index-0 field with a handful of coloured blocks in the
upper-left, identical across captures 20 s apart. The renderer is not writing
pixels into the line buffer. The **same RTL renders 950 frames pixel-perfectly
under Verilator**, CRC-identical to a MAME-referenced golden. So the defect
lives in something the behavioural testbenches model differently from silicon,
not in the rendering algorithm.

This also refuted the previous theory. The old hypothesis was that a
timing-failing RBF (−1.284 ns through the descriptor cache) corrupted sprite
rendering; the current build passes every check at all four corners with
+0.392 ns worst setup, and the symptom is unchanged.

## Governing principle

**Do not change rendering logic to chase this.** The renderer is CRC-locked
against MAME across the full validated window. Any edit that changes those CRCs
is almost certainly wrong. Every fix below must either leave
`rtl_final96_gameplay_frames.crc` byte-identical, or come with an explicit,
justified re-baseline.

Work strictly cheapest-first. Steps 1–3 need no hardware round-trip at all.

---

## Phase 1 — Free evidence, no rebuild (hours)

### 1.1 Audit `s32_big_dpram` read-during-write assumptions

The prime suspect. `rtl/common/s32_big_dpram.sv` configures hardware as:

```
read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ"
read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ"
read_during_write_mode_mixed_ports = "OLD_DATA"
```

while the behavioural branch returns **old** data on a same-port write
(`q_a_r <= mem[address_a];` sampled before the write). The module comment
justifies the divergence with "core clients ignore q on a write cycle". That
assumption has never been verified.

Check every instance — `work_ram`, `sprite_ram`, and both `ssv_palette_ram`
banks — for any path where `q` is consumed on a cycle when `wren` is high on
the same port. In `ssv_core` the CPU read mux latches `wram_q`/`spr_q`/`pal_q`
one cycle after `m_req`, and `m_we` and `!m_we` are mutually exclusive per
transaction, so the CPU side is probably safe. **The port-B side of
`sprite_ram` is the one to scrutinise**: the renderer reads it continuously via
`renderer_spr_addr` while the CPU writes port A, which is a *mixed-port*
collision (`OLD_DATA`, matching sim) — but confirm the fitter honoured that,
because `NEW_DATA_NO_NBE_READ` on port A can override mixed-port behaviour in
some Cyclone V configurations.

Deliverable: a table of every client, the cycle its `q` is sampled, and whether
a write can be active on that port in that cycle.

### 1.2 Look for anything else that is modelled rather than real

Same class of bug, same zero cost to check:

- `ssv_mlab32_sdp` — hardware `read_during_write_mode_mixed_ports = "DONT_CARE"`,
  sim returns old data. The header already flags this ("the regs host-steal
  path avoids relying on conflicted reads") — verify that claim.
- The `descriptor_cache` / `line_entries` / `line_page_starts` arrays in
  `ssv_cached_sprite_renderer` carry `no_rw_check`. That is an assertion to the
  fitter that a simultaneous read and write to the same address never happens.
  If it *can* happen, hardware returns undefined data where sim returns
  something deterministic. Prove the build and render phases never overlap on
  one address — note `cache_busy` gates `line_buffer_start` in `ssv_core`, so
  the intent is there, but the bypass path in `RENDER_PREP` prefetches while
  `BUILD_*` could still be finishing on the frame the cache is first armed.
- `icache_data` / `icache_tag` also carry `no_rw_check`, now backed by real
  LUTRAM after this pass's fix. The fill writes and the hit reads are in the
  same `always_ff`; confirm a fill write and a lookup read cannot target the
  same line in the same cycle.

### 1.3 Primary hypothesis: cache-build starvation locks the line buffer

This is the one that explains the *exact* symptom, and it connects directly to
1.1. In `ssv_core`:

```systemverilog
wire line_buffer_start = video_enable && ce_pixel &&
                         (hcnt == SSV_HBSTART - 1'd1) &&
                         (renderer_target_y <= SSV_VBSTART) &&
                         !obj_cache_busy;
```

`line_buffer_start` is what flips `front_select` in `ssv_line_buffer4`. **If
`obj_cache_busy` stays high across active display, no line ever swaps**, the
displayed buffer is frozen at whatever it last held, and every pixel the
renderer never wrote reads back as cleared index 0. That is precisely what is
on screen: a uniform index-0 field, a few stale blocks, and no animation.

The descriptor cache is built during vblank by walking the sprite list until
`global_w1[15]` terminates it. On hardware the CPU is writing sprite RAM at the
same time, through port A of the same `s32_big_dpram` whose port B the build is
reading. If a mixed-port collision returns different data on silicon than in
the behavioural model (see 1.1), the build can miss its terminator and scan all
1024 global entries every frame — overrunning vblank, holding `obj_cache_busy`
into active display, and freezing the picture. Verilator cannot reproduce this
because its model and the fitter's configuration disagree about exactly this
case.

Deliverable: instrument the build to count cycles and confirm whether it fits
inside vblank, and confirm whether `obj_cache_busy` is ever high at
`hcnt == SSV_HBSTART-1` during active lines.

### 1.4 Secondary: the `sdr_p1` ownership mux

`rtl/mem/sdram.sv` documents a hard contract: *"one transaction per req RISING
EDGE… a requester expecting re-service from a held level will hang."*
`ssv_core` muxes p1 between the two renderers on `obj_busy`:

```systemverilog
assign sdr_p1_req  = obj_busy ? obj_rom_req : bg_rom_req;
assign sdr_p1_addr = obj_busy ? obj_rom_addr : bg_rom_addr;
```

A switch while either fetcher has a request in flight would present the wrong
address on a req rising edge. **First inspection suggests this is safe** — the
BG renderer only raises `done` (which starts the object renderer) from `PLOT`,
by which point `ssv_gfx_row_fetch` is back in `IDLE` with `rom_req` low, so the
mux only moves while both fetchers are idle. Record that as a written proof
rather than an assumption, but do not prioritise it over 1.3.

---

## Phase 2 — Cheap hardware observation (one boot each)

### 2.1 Read the overrun LED

`LED_DISK` is now driven from the sticky `renderer_overrun` bit
(`debug_status[16]`), which latches on a line-deadline miss **or** a descriptor
/ line-slot truncation. Boot and look at the I/O board HDD LED:

- **Lit** → the renderer ran and missed deadlines, or a list was truncated.
  Points at SDRAM arbitration latency, since real p1 service is far slower than
  the behavioural model.
- **Dark** → the renderer never started. Strongly supports 1.3: `line_start`
  is gated off by `obj_cache_busy`, so `renderer_overrun` (which only latches
  on `line_buffer_start && renderer_busy`, or a cache overflow) would never
  trip because the renderer is never launched in the first place.

This single bit splits the search space in half and costs one boot.

### 2.2 Distinguish stall from watchdog loop

`wdog_rst` fires 180 frames (~3 s) after the last `$210000` read and drops
`video_enable`, which blanks the screen. Capture at ~1 s intervals for 10 s. A
steady image means a hard stall with the CPU still kicking the watchdog; a
periodic blank means the CPU has hung and the board is reset-looping.

### 2.3 Widen the debug surface if 2.1 and 2.2 are inconclusive

`debug_status` is 24 bits and fully used, but with `ENABLE_DIAG_VIDEO=0`
nothing consumes it. Temporarily re-enable the diag video overlay, or repoint
`LED_POWER` and `LED_USER` at `obj_cache_ready` / `obj_busy`, to see whether
the cache ever arms and whether the object renderer ever runs.

---

## Phase 3 — Targeted reproduction in simulation

Only after Phase 1/2 name a suspect. The point is to make Verilator able to
*fail*, because right now it cannot.

1. **Replace the behavioural SDRAM in `tb_ssv_frame_crc` with the real
   `rtl/mem/sdram.sv`** plus a behavioural SDRAM *chip* model. This is the
   single highest-value verification investment available: it puts genuine
   arbitration, ack stretching and refresh stalls in front of the renderer.
   Every current full-core bench fakes the controller, which is precisely the
   layer where hardware and sim differ.
2. Add an assertion that `sdr_p1_addr` is stable from each `sdr_p1_req` rising
   edge until its ack.
3. Make `s32_big_dpram`'s behavioural branch match the hardware
   `NEW_DATA_NO_NBE_READ` semantics, then re-run the 950-frame CRC. If the CRC
   changes, the divergence is real and that is the bug.

---

## Phase 4 — Fix and re-qualify

For whatever Phase 3 reproduces:

1. Fix it, keeping the 950-frame CRC byte-identical.
2. Re-run `run_bringup_sims.sh` and the 950-frame soak.
3. Full Quartus compile, `report-quartus.ps1 -RequireReady`.
4. Deploy with the backup preserved, boot, capture.
5. Update `DYNAGEAR_FROZEN_VIDEO.md` with last-match / first-divergence.

## Explicit non-goals

- Do **not** rewrite the renderer to "make hardware work". It is CRC-locked to
  MAME; changing it to chase a hardware symptom will destroy the one solid
  reference this project has.
- Do **not** start V60 area reduction or the descriptor-coordinate refactor.
  Both are large, both are unrelated, and the core does not render.
- Do **not** relax the SDRAM request contract or the SDC multicycle exceptions
  to make a symptom disappear. Both were audited on 28 Jul and are sound;
  weakening them would trade a visible bug for an intermittent one.

## Running notes

| Date | Finding |
|---|---|
| 28 Jul | Timing-clean RBF (`846c7b02…`) deployed; renderer still emits almost nothing. Timing hypothesis refuted. |
| 28 Jul | Phase 1 complete. One real defect found and fixed (1.3); three suspects cleared with recorded reasoning. |
| 28 Jul | **Fix confirmed on hardware.** RBF `a23cbf06…` boots into the game and runs the full attract sequence — title, gameplay demo, world map, stage with live HUD. The frozen frame is gone. |
| 28 Jul | **New symptom:** horizontal tearing/striping, worst in the upper third of the frame. Different signature (per-line, not whole-frame). Promotes Phase 3.1 from optional to load-bearing — see below. |

## 1.5 Shared p1 ack delivered to both renderers — REAL DEFECT, FIXED

Found from a user observation that the earlier "tearing" description had
missed: *large parts of the level draw as white cross-hatch boxes, then render
in correctly further on*. That is not tearing, it is **wrong tile data**.

`ssv_core` muxes `sdr_p1_req`/`sdr_p1_addr` between the background and object
renderers on `obj_busy`, but handed the **raw `sdr_p1_ack` to both**. Both
fetchers are level-sensitive on `rom_ack`, so a renderer that does not own the
port still completes its transaction and latches `sdr_p1_dout` — the *other*
renderer's tile data.

It is reachable because `renderer_line_start` is **not** gated on
`renderer_busy`: a still-busy renderer only *records* `renderer_overrun`. So a
line that misses its deadline starts the background renderer while the object
renderer is still fetching, and both sit in `WAIT_ACK` on the same ack.

Simulation never saw it because the behavioural SDRAM is fast enough that lines
never overrun (`overruns bg=0 obj=0` across 950 frames). On hardware, where p1
is shared with the CPU and audio through one chip, lines do overrun and the
background gets painted with sprite graphics until the scene thins out.

Fix: steer the ack to the owner.

```systemverilog
wire p1_owner_obj = obj_busy;
wire bg_rom_ack   = sdr_p1_ack && !p1_owner_obj;
wire obj_rom_ack  = sdr_p1_ack &&  p1_owner_obj;
```

Reproduction harness: `+P1_LATENCY=N` in `tb_ssv_frame_crc` starves the GFX
fetch so lines genuinely miss deadlines — the precondition the default model
can never create. The check is written against observable behaviour (the
background fetcher leaving `WAIT_ACK` while `obj_busy`), so it is valid with or
without the fix.

| Run (120 frames, `+P1_LATENCY=40`) | `bg_ack_while_obj_owns` |
|---|---:|
| Without the fix | **1,166,752** |
| With the fix | **0** |

Both runs show the same starvation (22,372 bg + 24,337 obj line-deadline
misses), so the difference is the ownership fix alone, not a change in load.

## 1.6 Scroll-triggered background corruption — OPEN, localised

Found by the long-scenario stream (`work/v60-opcode-audit`), reproduced
independently in `main`. **This is the defect that matches the reported
hardware symptom** ("large parts of the level draw as white boxes, then render
in correctly further on"), and unlike everything else in this document it
reproduces on the **default fast SDRAM model** — so it is a pure RTL/data bug,
not a timing artefact, and it iterates in minutes.

### Reproduction

`+SCENARIO=coin_start_p1_long`, black fraction inside the play area
(x 8–327, y 20–189), measured in `main`:

| post-VE frame | 900 | 950 | 1000 | 1050 | 1100 | 1150 | 1200 |
|---|---:|---:|---:|---:|---:|---:|---:|
| moving | 1.14 | 0.74 | **5.23** | **14.94** | **25.83** | **25.97** | **25.94** |

Matches the originating stream's numbers to two significant figures. The
stationary control holds ~0.8% for 3000 frames, so **scrolling is the trigger**.

Frame 950 renders a flawless jungle scene. Frame 1100 shows a hard vertical
edge at screen x≈152: background correct to the left, **black to the right**,
with font glyphs mixed into the left portion. Sprites, the tree, the grass and
the whole HUD render correctly throughout.

### What the tilemap trace ruled out

`+DUMP_TILEMAP=<frame>` traces every tilemap tile fetch (group, mode, scroll,
map_x/y, computed address, code, attr). On frame 1100 all three active groups
are `size=1` (512-pixel pages); groups 1 and 3 use row-scroll (`mode[12]`).

**Refuted — the page-boundary theory.** Addresses are continuous across it:
map_x `0x7ff → 0x80f` gives address `0x1FE8 → 0x2028`, exactly the +0x40
one-column stride. `tile_address()` computes correctly here.

**Refuted — dropped or truncated columns.** Every group emits 22 tiles on all
240 lines (5,280 each). Nothing is skipped; the renderer covers the full width.

Also checked and *not* the cause, though it is a genuine latent defect worth
fixing separately: in `tile_address()` the shift amount `size_shift + 2'd2` is
self-determined to 4 bits, so it wraps for `size_shift` 14/15 (`mode[15:13]`
6 or 7). Those page sizes are wider than the screen so `page` stays 0 in
practice — it cannot produce this symptom.

### What the trace points at

The renderer faithfully draws what it reads; the **tile codes themselves go
flat** exactly where the picture goes black. On y=100 of frame 1100, group 1
codes vary through the visible region (`8002, 803e, 801a`…) then hold constant
`0x8002` from `scrx=145` — the black band. Group 3 is constant `0x8000` across
the entire line.

Scroll values are large and growing (2015 / 2686 / 3080 across the three
groups), and `tile_address` turns those into `page = x >> 9`, `base = page << 11`,
marching further into sprite RAM as the player advances.

**Working hypothesis:** the tilemap is meant to wrap within a fixed-size map and
the renderer instead pages off the end of it, reading blank memory (and
occasionally the font tilemap). Fits every observation: clean while stationary,
progressive once scrolling, sprites unaffected.

**Refutation condition:** if the frame-950 trace shows the same groups at lower
scroll with varied codes across the full line, the only difference is how far
right we have paged, and the fix is in how `x` is masked before the page term —
the stride is already proven correct.

**Still unseparated:** "renderer reads too far" versus "CPU never wrote that
region". Deciding needs the tilemap RAM contents compared against MAME at the
same frame — and MAME/RTL game state has already diverged by frame 1100, so
that comparison has to be built carefully to mean anything.

## Status after the 28 Jul hardware test

The freeze is fixed and the core reaches game content on real hardware for the
first time. What remains is a *different* defect with a different shape:
per-line tearing rather than a whole-frame stall.

That reprioritises the plan. **Phase 3.1 is now the critical path**, not an
optional verification investment:

> Verilator reports `overruns bg=0 obj=0` across all 950 frames, yet hardware
> visibly misses line deadlines. The one structural difference is that every
> full-core bench drives the renderer through a behavioural SDRAM model with
> fixed low latency, while the real controller round-robins six ports,
> stretches ack across two `clk_ram` cycles, and stalls for refresh. The
> renderer's GFX fetch on `sdr_p1` is the bandwidth-critical consumer and the
> one thing no bench exercises realistically.

Until `rtl/mem/sdram.sv` plus an SDRAM chip model sits in front of
`tb_ssv_frame_crc`, simulation cannot reproduce, regress, or even detect this
class of defect. Everything else is guesswork by comparison.

Cheap confirming step first: read the overrun LED. If `renderer_overrun` has
latched, the per-line deadline miss is confirmed directly and no inference is
needed.

## Phase 1 results — completed 28 Jul 2026

### 1.1 `s32_big_dpram` read-during-write — CLEARED

Port B never writes in any of the four instances (`work_ram`, `sprite_ram`, and
both palette banks), so the only same-port RDW case is port A, and every client
samples `q_a` exclusively on read transactions: `ssv_core`'s read mux reaches
`wram_q`/`spr_q`/`pal_q` only through the `!m_we` path, and `s32_v60_bus` is
single-outstanding so a read and a write can never overlap. The `NEW_DATA` vs
old-data divergence between silicon and the behavioural model is therefore
unobservable. Mixed-port collisions (CPU write vs renderer/video read) are
configured `OLD_DATA`, which matches the model.

Corroborating evidence: the 28 Jul compile produced **no read-during-write or
altsyncram warnings at all** in `map.smsg` or `fit.smsg`, so Quartus honoured
the configuration as written.

### 1.2 `no_rw_check` arrays — ONE REAL COLLISION, PROVEN HARMLESS

`descriptor_cache` and `line_entries` are written only in `BUILD_*` states and
read only in `RENDER_*` states, which are mutually exclusive. Clean.

`line_counts` and `line_page_starts` are **not**: their reads are
unconditional, use the same `line_count_addr` as the `BUILD_CLEAR_LINES` and
`BUILD_BUCKET_WRITE` writes, and therefore collide on every one of those
cycles — exactly the case `no_rw_check` promises cannot happen. It is safe only
because the colliding read is never consumed: `line_count_q` is overwritten by
the next `BUILD_BUCKET_READ` (at the incremented address) before any state
reads it. Now documented in the RTL, because a future change that samples one
cycle earlier turns this into a live divergence.

`ssv_mlab32_sdp` in `ssv_es5506_regs` has the same shape and is also safe, for
a different reason: `wr_addr` and `rd_addr` are both `eng_voice` during the
one-cycle writeback, so they do collide, but that cycle has `ce` low and the
voice engine only samples `q` in `S_START` under `ce` — at least three
`clk_sys` cycles later, by which point `rd_addr` has moved on.

### 1.3 Cache-build starvation — REAL DEFECT, FIXED

The vblank descriptor build had **no deadline**. It is bounded only by 1024
globals × 32 locals × up to 240 bucket lines, which is orders of magnitude
longer than a frame. If it ever overran into active display, `ssv_core`'s
`line_buffer_start` — which gates on `!obj_cache_busy` — stopped firing, so no
line swapped and the picture froze. And it could not recover: the next vblank
sets `cache_pending`, which re-arms the build the moment it finishes, holding
`cache_busy` high forever. **A single overrun latches the core into a dead
display permanently.**

That is an exact match for the hardware symptom: a static frame showing stale
buffer content, with everything the renderer never wrote reading back as
cleared index 0.

Fix: `cache_deadline` (asserted by `ssv_core` for `vcnt >= SSV_VTOTAL-2`, the
two lines that prepare display rows 0 and 1) forces `BUILD_ADVANCE` to publish
the partial cache and release `cache_busy`, raising `cache_overflow` — which
feeds `renderer_overrun` and therefore the overrun LED. One frame of degraded
sprites, flagged, instead of a permanent freeze.

Regression test: `tb_ssv_cached_sprite_renderer` builds a sprite list that
never terminates itself and asserts the deadline mid-build. **Observed to fail
with the abort removed** (`cache_deadline ignored: still busy after 2000
cycles`) and pass with it (`released cache_busy in 20 cycles, overflow=1`).

**How close it already was.** Instrumentation added to `tb_ssv_frame_crc` for
this pass measures the build against its window:

```
CACHE_BUILD max=44020 cycles (frame 527) deadline_aborts=0
```

The window is lines 240–259, i.e. 20 lines × 454 pixels at 6.749 `clk_sys` per
pixel (`PIXEL_INC` 9710/65536) = **61,284 cycles**. So the worst frame in the
validated window already consumed **72% of the budget, leaving 17,264 cycles
of margin**. That is not a comfortable design point for something whose failure
mode is a permanent freeze — a walk 40% longer than the observed peak is enough
to fall off the cliff, and the cliff had no floor.

Note this is a containment fix. It converts an unrecoverable freeze into a
visible, flagged degradation — it does not explain *why* a build would overrun
on silicon but not in Verilator. Leading theory: the slower real SDRAM leaves
the V60 further behind the raster, so at vblank the sprite list can still be
mid-update and lack its `global_w1[15]` terminator, sending the walk through
all 1024 global entries. If the overrun LED lights on the next board test, that
root cause is still open and the next move is to make the build *cheaper*
rather than merely to survive it.

**Two build-cost levers, and one trap.** The obvious idea — skip globals whose
local count is zero — is **wrong and must not be attempted**. `BUILD_GLOBAL_3`
enters the local loop unconditionally, and with the `local_index <
global_w0[4:0]` test in `BUILD_ADVANCE` that produces count+1 iterations, which
is exactly what MAME's `for (; num >= 0; num--)` does. Skipping would drop a
descriptor MAME draws and break CRC parity. This is now commented in the RTL.

The real lever is the bucket loop, which dominates the 44,020 cycles: every
visible descriptor costs two cycles per scanline it covers
(`BUILD_BUCKET_READ` + `BUILD_BUCKET_WRITE`), so a 64-pixel-tall sprite costs
128 cycles on its own. Halving that to one cycle per line requires the running
count to be available without a separate read cycle — either a small
combinational count cache or pipelining the next line's read under the current
write. That roughly halves the peak build and would restore real margin, but it
touches CRC-locked logic and should only be done with the full soak as a gate.

### 1.4 `sdr_p1` ownership mux — CLEARED

The mux moves on `obj_busy`, and the BG renderer only raises `done` (which
starts the object renderer) from its `PLOT` state, by which point
`ssv_gfx_row_fetch` is back in `IDLE` with `rom_req` low. The two fetchers are
never concurrently active, so the mux cannot switch mid-transaction and cannot
manufacture or destroy a request edge.
