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
