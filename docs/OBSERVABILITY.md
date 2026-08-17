# MAME ↔ RTL observability contract

The machine-readable contract is [OBSERVABILITY.json](OBSERVABILITY.json). The
candidate strict domain is `cpu_data`: completed 16-bit CPU data
transactions with program-ROM instruction fetches (device 1) projected out,
because MAME tap granularity is not equivalent to RTL's 64-bit V60 cache fills.
`mainbus` remains diagnostic until an equivalent full-space sampling contract
exists. Promotion still requires two byte-identical cold captures per producer
with the same immutable gameplay journal.

## Anchors

| Anchor | MAME definition | RTL definition | Status |
|---|---|---|---|
| reset release | first program-space observation after MAME reset | first observation after `core_rst` deasserts | Candidate |
| first fetch | first completed program-ROM read | first completed wide program fill (`if_req && if_ack`) | Diagnostic until granularity proof |
| first retirement | MAME `device_debug::instruction_hook(PC)` through the debugger `trace` action, immediately before execution | V60 `S_DECODE`: previous instruction complete, next `fb[0]` about to dispatch | Diagnostic; paired phase proven in a focused window |
| IRQ | V60 program/device observation plus driver state | accepted `cpu_irq_ack` with requested/enabled/vector | Diagnostic |
| VBlank | native screen frame callback | native timing boundary | Diagnostic |
| frame complete | `register_frame_done`, raw unrotated surface; the 360-frame stop budget begins after the accepted `$21000e` bit-7 epoch | `frame_tick`, completed native surface; the same post-epoch budget is enforced by `run_done` | Candidate |
| native RGB CRC | MAME `frame_complete.frame_crc32` over the 336x240 native RGB surface | RTL `FRAME` RGB CRC over the same native unrotated surface | Candidate only for an explicitly declared frame window; no resynchronization |
| state CRC | MAME read-only per-frame CRCs of the established list/sprite/scroll/palette ranges | RTL `STATE` CRC records at the native frame boundary | Diagnostic candidate; memory sampling phase is not PCB-cycle proof |
| input consumption | journal ordinal applied before the next frame with MAME frontend coin impulse disabled (`-coin_impulse -1`) | same raw board-input journal ordinal applied before the next frame | Candidate |

## Domain map

| Domain | Capture point | Phase | Ordering | Status |
|---|---|---|---|---|
| `cpu_data` | MAME program-space taps projected to devices 0 and 2–11 / explicit `ssv_core` completed-cycle outputs | completed | source mainbus ordinal projection | Candidate strict |
| `mainbus` | full MAME program-space taps / explicit `ssv_core` completed-cycle outputs | completed | domain ordinal | Diagnostic |
| `v60_ifetch` | RTL wide program fill | completed | domain ordinal | Diagnostic |
| `v60_retire` | MAME debugger instruction hook / explicit RTL V60 instruction boundary, with PC/opcode/PSW/all GPRs | before execution | domain ordinal within a paired post-epoch window | Diagnostic |
| `v60_irq_entry` | MAME debugger-trace handler-PC marker | before handler execution | handler-entry ordinal | Diagnostic |
| `irq` | request/mask/ack/vector events | completed | domain ordinal | Diagnostic |
| `st010` | retire, host access, program request/completion | event-specific | domain ordinal | Diagnostic |
| `es5506` | host commit, voice IRQ, sample request/completion/tick/underrun | event-specific | domain ordinal | Diagnostic |
| `video` | enable, line/frame boundary, ownership violation | event-specific | domain ordinal | Diagnostic |
| `native_rgb_crc` | completed native 336x240 RGB frame CRC | completed native 336x240 RGB frame CRC | domain ordinal | Candidate windowed |
| `state_crc` | per-frame CRCs of list512, spr8k, scroll63 and pal512 memory ranges | same four per-frame CRC fields | domain ordinal | Diagnostic |

`verif/ssv_diff_probe.sv` consumes only explicit simulation ports. It never
uses a hierarchical DUT path and is absent from Quartus manifests. Every trace
must end with a `stop` barrier and a complete, zero-drop receipt. Capacity
limits fail the run; they never silently truncate it.

## CPU-data normalization

Both producers emit byte addresses, 16-bit lane-numeric data, active-high
two-bit byte enables, `R`/`W`, stable device IDs and `phase=completed`.
The strict `cpu_data` projection excludes device 1 only; no other event may be
skipped or synthesized.
Before ordinal comparison, `tools/compare_ssv_strict.py` applies the named
`cpu_data_lane_mask_v1` normalization: unselected data lanes are masked using
the event's active-high `byte_enable` (`BE1=0x00ff`, `BE2=0xff00`, `BE3=0xffff`).
This does not rewrite source traces or the diagnostic `mainbus` domain; the
normalization name is recorded in every comparator receipt.
PC/reset/frame/scanline context is causal context and is not strict until its
sampling phase is separately proven. Device IDs are defined once in
`OBSERVABILITY.json` and implemented identically in RTL and Lua.

The immutable journal names the signal presented at the board input boundary.
Headless MAME must therefore use `-coin_impulse -1`; driver `PORT_IMPULSE`
shaping is an interactive frontend aid and must not extend a journal packet.
Every MAME contract record attests the effective `coin_impulse` value.

Acceptance uses `tools/compare_ssv_strict.py` for bounded traces and
`tools/compare_ssv_strict_stream.py` for full captures that exceed practical
memory. Both compare equal ordinals and never search, skip, or resynchronize;
the streaming receipt also hashes both source files while validating their
complete stop/receipt/count contracts. `tools/ssv_trace_semantics.py` remains
diagnostic-only.

Low-volume MAME barrier captures may use the opt-in
`run_ssv_mame_headless.ps1 -BarrierSidecar` mode. It closes one JSON file per
record, preserves the raw bus stream and record files separately, and merges
them only after MAME exits; malformed or missing sidecar records fail closed.

When a full bus stream is too large for a practical run, the bounded
`tools/project_ssv_strict_window.py` projector copies only source events in a
declared native-frame interval and emits a provenance-bound window receipt; it
does not rewrite event fields or alter ordinal comparison semantics.

For bounded strict runs, both headless producers support the
`strict_only=true` diagnostic profile. It emits only the canonical mainbus
fields needed for the `cpu_data` projection while preserving the real core,
reset, journal, stop barrier, and complete zero-drop receipt. It is an output
volume reduction, not a timing or state-model variant, and is never used to
omit events from the comparator projection.

Focused CPU causality uses
`tools/compare_ssv_instruction_boundaries.py` for exact PC/opcode/PSW/all-GPR
boundaries and `tools/compare_ssv_register_changes.py` for the low-volume
R2/R23 transition stream. Both align once at a declared barrier and then
compare strict ordinals; neither searches past a mismatch.

Natural interrupt cadence uses
`tools/compare_ssv_irq_cadence.py`. It binds one exact PC/R2/R16 state, compares
the next MAME and RTL retirements without resynchronising, and records the
nearby RTL request/ack/vector events plus MAME handler entries. A missing PCB
phase measurement remains an evidence blocker; do not repair it with an
arbitrary delayed IRQ or frame offset.

The headless frame bench also enforces a same-side IRQ invariant. Duplicate
VBlank handler entries are fatal in every run; `+ASSERT_IRQ_CADENCE` opts into
the stronger exact-one-entry-per-completed-VBlank contract for a scenario that
has already established CPU activity. The opt-in is intentionally not a
cross-title default: some supported sets remain in reset/boot while the first
post-epoch raster interval completes.

## Remaining proof work

- Prove two cold captures per side are byte-identical for the selected stop
  barrier and input journal.
- Reproduce two corrected cold instruction captures before promoting
  `v60_retire` beyond diagnostic use; the focused paired window currently
  proves 753 exact architectural boundaries.
- Establish ST010, ES5506 and video callback phases before comparing those
  domains strictly.
