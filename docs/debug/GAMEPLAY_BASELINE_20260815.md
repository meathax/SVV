# Gameplay-convergence baseline — 2026-08-15

This is an implementation checkpoint, not an acceptance result. The supplied
MAME 0.289 executable and merged-ROM directory are now configured; clean
MAME capture status is recorded below.

## Static contract

- The eight authoritative sets, universal profile, hardware-shape audit and
  descriptor-v3 checks pass.
- All eight `gameplay_neutral` scenario-v1 files compile to immutable
  input-journal-v2 packets with a 120-frame neutral tail. Their gameplay
  markers remain `pending_live_validation`.
- The strict differential candidate is `cpu_data`; program-ROM device 1 is
  excluded because the MAME read tap and RTL cache-fill observables do not
  have equivalent granularity. `mainbus` remains diagnostic.
- The headless model is native UCRT64, timing/assertions enabled, one runtime
  thread, no SDL/display dependency. This installation lacks `lz4.h`, so the
  build uses compile-time VCD trace support as a diagnostic fallback; no wave
  is emitted by the acceptance run.

## First cold RTL smoke

Command:

```text
tools/run_ssv_headless.ps1 -Set dynagear -Session sim_output/diff/dynagear-gameplay-rtl-2 -Scenario gameplay_neutral -ScenarioFile verif/scenarios/dynagear/gameplay_neutral.json -ModelDir D:\Arcade\AI\SVV\sim_output\obj_headless -SkipBuild
```

Two cold RTL runs (`...-rtl-2` and `...-rtl-3`) reached the real core and
exercised the scenario journal, then stopped at the same renderer fail-fast
invariant:

```text
SSV_RENDERER_OWNERSHIP pc=00f1d33c frame=1 scanline=242 hpos=449
FIRST_CACHE_OVERFLOW f=0 ... line_count=3695 pool_alloc=0
CACHE_OVR reindex ... addr=26688
```

The earlier `SSV_DUPLICATE_ACK` assertion at `$210002` was proven to be a
level-handshake false positive: the V60 adapter holds `ack_r` while sparse
`ce_cpu` catches up. The assertion now checks repeated completion edges while
retaining the level handshake. The renderer overflow is the sole active RTL
blocker for this smoke and must be diagnosed before any later gameplay or
cross-game mismatch is considered.

A bounded sequential probe reached the same cache-overflow signature for
Vasara and Vasara 2 during their first post-video frame, and for Change Air
Blade at post-video frame 35 (the differing PC/scanline is downstream context,
not a new target). The RTL probe was stopped before Drift Out, Storm Blade,
Twin Eagle II and Ultra X completed; they remain unmeasured rather than being
declared passing or failing. Separate MAME 0.289 full scenario captures now
complete Twin Eagle II and Ultra X through gameplay entry and their 120-frame
neutral tails; that evidence does not qualify RTL.

## Required next evidence

1. Two cold MAME 0.289 barrier/journal captures are now deterministic for all
   eight authoritative sets. They use the supplied executable
   (`af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3`), each
   set's descriptor-v3 identity and immutable gameplay journal, and matching
   trace, receipt, native PPM and normalized PCM hashes. All run with
   `SSV_HEADLESS_BUS_MODE=none`, proving the adapter, input journal,
   gameplay-entry barrier and 120-frame neutral tail. Matching two-cold
   `SSV_HEADLESS_BUS_MODE=cpu_data` windows now also complete for all eight
   sets around their gameplay-entry barriers, with zero drops and identical
   trace hashes. The native Windows PowerShell runner now selects `UTF8`
   instead of the unsupported Core-only `utf8NoBOM` enum when writing receipts.
2. Re-run Dyna Gear beyond the old stop point with the repaired renderer and
   the corrected legacy stop-barrier publication, then repeat the same
   determinism and first-divergence workflow for the remaining seven sets.

The first full-bus attempt was intentionally stopped after its diagnostic
trace exceeded 2.5 GB by frame 83; it is not an acceptance artifact. The
bounded bus filter was added to prevent another accidental multi-gigabyte
capture while retaining full bus mode for the eventual strict window.

An evidence-backed RTL correction is now staged in
`rtl/video/ssv_cached_sprite_renderer.sv`: when the visible descriptor count
is zero, the prefix pass publishes an empty ready cache instead of entering
reindex on unwritten `descriptor_cache[0]`. The focused renderer bench has a
matching empty-cache assertion. The focused Icarus run passes, including the
empty-cache case and the existing dense-line/deadline checks. The legacy timed
headless bench now also sets `run_done` before `$finish`, allowing the
simulation-only probe to emit a complete stop receipt. The first long replay
reached the full 941-frame neutral tail without a renderer/watchdog failure but
exposed two harness boundaries: the entry log reported cursor 821 instead of
820, and the final frame attempted journal packet 941. Both are corrected in
`verif/tb_ssv_frame_crc.sv`. That replay also exposed a host receipt race: the
bench asserts `run_done` and `$finish` in one evaluation, so the C++ host must
trust the project-owned `run_done` signal even when `gotFinish()` is already
set. `verif/ssv_headless_main.cpp` now does so and records the scenario path;
the fresh fix4 detached replay is the first receipt-validating run. Its final
native frame (post-epoch 940) is pixel-identical to the pinned MAME 0.289
`mame-native_f000940.ppm` (80,640/80,640 pixels); this is visual evidence only
until the strict event-domain comparison is closed.
Gameplay closure and any newly exposed divergence remain open until its receipt
and a second cold replay are verified.

No Quartus build, RBF, or hardware validation was performed.

## Active Dyna strict divergence

The two-cold MAME `cpu_data` windows are byte-identical (digest
`908de70cc6def786ba000e59eebf2ac523f0e6f58cdbfd49dafd0926b7c16c71`). The
second cold RTL trace covers post-epoch frames 839–845; comparing its complete
840–841 subset against the matching pinned MAME window gives the sole active
earliest mismatch at ordinal 3, after a matching prefix of three transactions:

```text
device=2 (work RAM), write, address=0x7904, byte_enable=2
MAME address=0x007904, PC=0x00F10575, data=0x7500   RTL address=0x007904, PC=0x00F1057B, data=0x7B00
```

The preceding writes at `0x78A8`, `0x78AA`, and `0x78AC` match exactly. This
is a strict architectural value/PC mismatch, not a pixel tolerance or trace
resynchronization; it is the only active Dyna target. No RTL patch has been
made yet. The opt-in read-only MAME V60-state probe in
`tools/mame-ssv-headless.lua` is now available for this
address, but its Lua callback samples the architectural state after the bus
tap and therefore does not replace an instruction-boundary observation. The
corrected probe completed at `sim_output/diff/dynagear-mame-stateprobe-7904-840-841`
and reports the post-write MAME PSW as `0x90000001`; it is diagnostic only. The
next experiment is a paired narrow read/write/retirement context to distinguish
CPU-phase/state divergence from a memory mapping or initialization error before
changing shared RTL.
