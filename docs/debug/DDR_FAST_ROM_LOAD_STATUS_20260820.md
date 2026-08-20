# DDR3 fast ROM load — status

2026-08-20. Implements MiSTer-devel/Arcade-IGSPGM_MiSTer's DDR3-address-mode
ROM load pattern for this core: an MRA `<rom index="0" address="0x....">`
tells Main to memcpy the ROM blob straight into DDR3 instead of streaming it
over ioctl; the core reads it back at full DDR3 speed and replays it as a
synthetic ioctl byte stream in front of the unmodified `ssv_rom_loader`.

## What changed

- `rtl/mem/ssv_ddr_rom_loader.sv` (new): DDR3 read-back adaptor. Classifies
  each index-0 download as legacy (ioctl_wr observed -> pass-through, byte-
  for-byte identical to before) or address-mode (no ioctl_wr, `ioctl_addr`
  holds the final length -> replay from DDR3). Only ever acquires the
  `DDRAM_*` port while `video_reset` is asserted.
- `Arcade-SSV.sv`: instantiates the adaptor, muxes its replay output into
  `ssv_rom_loader`'s `ioctl_download`/`ioctl_wr`/`ioctl_addr`/`ioctl_dout`
  inputs, and arbitrates the `DDRAM_*` port between `screen_rotate` and the
  adaptor on `ddr_ld_acquire`. `ssv_rom_loader.sv` itself is untouched.
  `DDRAM_DOUT`/`DDRAM_DOUT_READY` moved out of the `unused_inputs` sink
  since they are now genuinely consumed.
- `files.qip`: added the new source file.
- `tools/ssv_supported_sets.py`: added `DDR_FAST_LOAD_SETS` (empty tuple —
  see below) and `DDR_FAST_LOAD_ADDR` (`0x30000000`, matching the adaptor's
  `DDR_BASE_BYTES` default).
- `tools/gen_ssv_mras.py`: emits `address=` on the index-0 `<rom>` element
  for any setname listed in `DDR_FAST_LOAD_SETS`.

## Verification done

- `rtl/mem/ssv_ddr_rom_loader.sv` lints clean standalone
  (`verilator --lint-only -Wall`, width warnings fixed).
- Full `emu` hierarchy elaborates cleanly through `verilator --lint-only`
  with the new instance and DDRAM mux wired in (vendor `sys/hps_io.sv`,
  `sys/arcade_video.v`, `sys/video_freak.sv` pre-existing dialect-only
  diagnostics unrelated to this change were the only remaining output —
  none reference the new file or the changed wiring).
- `python -m py_compile` clean on the touched generator/tools files.

## Verification NOT done — why this stays dormant

- **No functional simulation.** `verif/` has no testbench that exercises
  the full `emu` top or `sys/hps_io.sv`'s ioctl protocol, and nothing
  models `DDRAM_DOUT`/`DDRAM_DOUT_READY` read timing (confirmed by
  investigation: the one testbench touching `DDRAM_*`,
  `verif/tb_ssv_screen_rotate_ddram.sv`, only wires the write side and says
  so explicitly in its header). The adaptor's DDR3 read state machine has
  not been run against any DUT.
- **No hardware test.** This is a top-level-pin, DDR3-port-sharing change
  per `~/.claude/reference/mister-hardware-hazards.md` ("Hardware-visible
  changes require hardware verification"). Not yet loaded on a real MiSTer.
- **Consequently `DDR_FAST_LOAD_SETS` is deliberately left empty.** With no
  setname listed, `gen_ssv_mras.py` emits the exact same MRA output as
  before this change (no `address=` attribute anywhere), and at runtime
  `ddr_replay_active`/`ddr_ld_acquire` never assert, so every muxed signal
  in `Arcade-SSV.sv` reduces to the original direct wiring. No RBF was
  built for this change (no user authorization was given, and none should
  be sought until the items below close).

## Before enabling for any real game

1. Build a Verilator testbench that drives the full ioctl protocol plus a
   DDR3 read model (fixed-latency `DDRAM_DOUT`/`DDRAM_DOUT_READY`, `DDRAM_BUSY`)
   and confirms the replayed byte stream into `ssv_rom_loader` is bit-identical
   to the legacy ioctl stream for a real ROM set.
2. Confirm the target MiSTer Main build actually implements `address=`
   (this repo's own MRAs have never used it before). Add an explicit
   sanity check — if `length` at replay-start is 0 or implausible, hold
   `rom_loaded` low rather than run on a garbage DDR3 read.
3. Add exactly one setname to `DDR_FAST_LOAD_SETS`, regenerate that game's
   MRA (`python tools/gen_ssv_mras.py`), and re-run the focused/regression
   suite (`core-debug.toml`'s `focused_tests`).
4. Load on real hardware and confirm the game boots and screen_rotate
   (rotated titles especially) still work correctly — the DDR3 port is now
   shared during load, and that sharing has no test coverage yet.
5. Only then request an explicit RBF build to validate end-to-end.
