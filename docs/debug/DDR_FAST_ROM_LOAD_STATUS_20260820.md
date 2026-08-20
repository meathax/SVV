# DDR3 fast ROM load — status

2026-08-20. Implements MiSTer-devel/Arcade-IGSPGM_MiSTer's DDR3-address-mode
ROM load pattern for this core: an MRA `<rom index="0" address="0x....">`
tells Main to memcpy the ROM blob straight into DDR3 instead of streaming it
over ioctl; the core reads it back at full DDR3 speed and replays it as a
synthetic ioctl byte stream in front of the unmodified `ssv_rom_loader`.

Enabled for all eight supported sets. The three defects that made the
original implementation non-functional are fixed and covered by
`verif/tb_ssv_ddr_rom_loader.sv`. Hardware verification is still outstanding.

## What changed

- `rtl/mem/ssv_ddr_rom_loader.sv` (new): DDR3 read-back adaptor. Classifies
  each index-0 download as legacy (ioctl_wr observed -> pass-through, byte-
  for-byte identical to before) or address-mode (no ioctl_wr, `ioctl_addr`
  holds the final length -> replay from DDR3). Only ever acquires the
  `DDRAM_*` port while `core_cold_reset` is asserted.
- `Arcade-SSV.sv`: instantiates the adaptor, muxes its replay output into
  `ssv_rom_loader`'s `ioctl_download`/`ioctl_wr`/`ioctl_addr`/`ioctl_dout`
  inputs, and arbitrates the `DDRAM_*` port between `screen_rotate` and the
  adaptor on `ddr_ld_acquire`. `ssv_rom_loader.sv` itself is untouched.
  `ssv_host_guard` is fed the replay-extended download view so its
  `core_cold_reset` hold spans the replay (see defect 3).
- `files.qip`: added the new source file.
- `tools/ssv_supported_sets.py`: `DDR_FAST_LOAD_SETS = SUPPORTED_SETS` and
  `DDR_FAST_LOAD_ADDR` (`0x30000000`, matching the adaptor's
  `DDR_BASE_BYTES` default).
- `tools/gen_ssv_mras.py`: emits `address=` on the index-0 `<rom>` element
  for any setname listed in `DDR_FAST_LOAD_SETS`.
- `verif/tb_ssv_ddr_rom_loader.sv` (new), wired into
  `verif/run_bringup_sims.sh`.

## Defects found and fixed

All three were found by the new testbench, and all three are individually
reproducible by reverting the fix (each was re-introduced into a scratch copy
and confirmed to fail the bench).

1. **Byte order reversed.** The drain shifted MSB-first out of the 64-bit
   word (`buffer[63:56]`, `buffer <= {buffer[55:0], 8'h00}`), so every group
   of eight bytes was delivered backwards and every ROM would have loaded
   scrambled. The DDR3 port is little-endian: stream byte N is
   `DDRAM_DOUT[8*(N%8) +: 8]`. Two independent sources agree — this core's
   own other DDRAM client, `sys/arcade_video.v`'s `screen_rotate`
   (`DDRAM_BE = ram_addr[2] ? 8'hF0 : 8'h0F`, so byte offsets 0-3 are
   `[31:0]`), and the upstream adaptor this was ported from
   (`buffer[(offset[2:0]*8) +: 8]` over an unswapped copy of the read data).

2. **Dropped bytes under back-pressure.** `replay_wr` was raised one cycle
   after `loader_wait` was sampled, so a wait rising in that gap produced a
   strobe during wait. `ssv_rom_loader` has no input buffer — it accepts on
   `(ioctl_wr && !busy)` (`ssv_rom_loader.sv:501`) and drives
   `ioctl_wait = busy | ~mem_ready | cfg_commit_pending` (`:433`) — so that
   byte was silently lost, and because the loader pairs bytes by
   `ioctl_addr[0]` a single loss mis-pairs the whole remainder of the
   stream. The byte is now held on the bus until it is actually taken.
   Measured on the bench: 52 of 1035 bytes lost before the fix.

3. **Port gate could never open.** Acquisition was gated on `video_reset`,
   but `ssv_host_guard` drives `video_reset = ~pll_ready_sys | host_reset`
   (`ssv_host_guard.sv:131`) where `host_reset` comes only from the
   OSD/front-panel reset request — it is **low** during a normal MRA load.
   The signal actually held across a load is `core_cold_reset` (`:132`).
   As written the adaptor could never acquire the port: it would park in
   `S_ISSUE`, `rom_loaded` would never assert, and the core would hang with
   LED_USER lit instead of booting. The gate is now `core_cold_reset`, which
   also keeps `screen_rotate` idle (its write traffic is driven by the
   DE/sync stream out of `ssv_core`'s video timing, which that reset holds).

   Enabling this exposed a second-order case: `core_cold_reset` folds in
   `~rom_loaded`, and on a *game switch* `rom_loaded` is still high from the
   previous game when the real `ioctl_download` falls (address mode emits no
   `ioctl_wr`, so the loader's `ioctl_addr == 0` clear never fires during the
   download). `replay_active` therefore now anticipates the
   `S_IDLE -> S_ISSUE` transition combinationally, and `ssv_host_guard` is
   fed `loader_ioctl_download` rather than the raw HPS signal, so the reset
   hold is seamless across the handover. Without that the gate would drop for
   one cycle and deadlock the load.

## Verification done

- `verif/tb_ssv_ddr_rom_loader.sv`: models the `DDRAM_*` read handshake with
  randomized 2-17 cycle latency and a `ddr_busy` accept window, plus
  free-running `loader_wait` back-pressure. Checks a 1035-byte blob
  (deliberately not a multiple of 8) replays byte-for-byte with correct
  `ioctl_addr` sequencing, that a legacy download produces zero replayed
  bytes and zero DDR reads, that an offered byte never changes while
  waiting, that `ddr_acquire` never asserts while the gate is low, that a
  pending load survives the gate being low and resumes correctly, and that
  `replay_active` has no gap at the download handover.
- Each of the three defects re-introduced individually into a scratch copy
  fails the bench (byte-order mutant shows the mirrored-within-8 signature;
  wait-race mutant loses 52 bytes and shifts every later address).
- `rtl/mem/ssv_ddr_rom_loader.sv` lints clean standalone.
- `python -m py_compile` clean on the touched generator/tools files.

## Verification NOT done

- **No hardware test.** This is a top-level-pin, DDR3-port-sharing change
  per `~/.claude/reference/mister-hardware-hazards.md` ("Hardware-visible
  changes require hardware verification"). Not yet loaded on a real MiSTer.
  The sim model is this repo's reading of the Avalon handshake, not the real
  controller.
- **No full-`emu` ioctl-protocol test.** The bench drives the adaptor's
  ioctl-facing ports directly; it does not run `sys/hps_io.sv`. The
  classification of "address mode" still rests on the documented Main
  behaviour (download handshake with zero `ioctl_wr` and `ioctl_addr` left
  holding the length) rather than on an observed trace.
- **No length sanity check.** If Main leaves an implausible `ioctl_addr`,
  the adaptor will replay that many bytes from DDR3. Worth adding a bound
  against the configured ROM size before trusting this unattended.

## First hardware boot — what to confirm

1. Each of the eight games loads: LED_USER goes out and the game reaches
   attract, matching the previous ioctl-streamed behaviour.
2. Load is visibly faster than the ioctl path.
3. Rotated titles still scan out correctly — the DDR3 port is shared during
   load, and only the sim model covers that so far.
4. Game switching without a power cycle works (the defect-3 second-order
   case above is the one to watch).

Reverting any set to the legacy path is deleting it from
`DDR_FAST_LOAD_SETS` and regenerating MRAs — no RTL change required.
