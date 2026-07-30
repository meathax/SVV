#!/usr/bin/env bash
# Build+run focused SSV bring-up sims under WSL Verilator.
# Native Verilator MCP can lint/compile, but MSYS link hits the CXX11 ABI issue.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/ssv-bringup"
mkdir -p "$OUT"
pwd
ls rtl/ssv_pkg.sv >/dev/null
# verilator-safe is a Windows launcher, and the MSYS toolchain it drives cannot
# link a Verilated binary here (verilated.o wants the CXX11 ABI std::string
# symbols that ucrt64 libstdc++ does not export) -- so this suite only builds
# under WSL Verilator, as the header above says. The wrapper additionally stalls
# when invoked from a non-interactive nested WSL shell, which is why
# verif/build_frame_crc.sh already bypasses it.
#
# Keep the wrapper as the default so an interactive run still gets its build /
# simulation slot limiting, but allow an override so the suite is runnable from
# a non-interactive shell:
#
#   SSV_VERILATOR=verilator SSV_VERILATOR_RUN= bash verif/run_bringup_sims.sh
#
# The names are SSV_-prefixed on purpose: VERILATOR_BIN is reserved by
# Verilator's own wrapper script to locate the real binary, so setting that name
# makes the wrapper re-enter itself ("re-entered 17 levels deep via
# $VERILATOR_RUNNING") instead of overriding anything here.
#
# SSV_VERILATOR_RUN uses ${VAR-default}, so an explicitly empty value means "run
# the binary with no wrapper" rather than falling back to the default.
read -r -a SSV_VERILATOR_ARR <<< "${SSV_VERILATOR:-verilator-safe}"
read -r -a SSV_VERILATOR_RUN_ARR <<< "${SSV_VERILATOR_RUN-verilator-sim-safe --}"

# Only the real wrapper understands `status`.
vstatus() {
  if [[ "${SSV_VERILATOR_ARR[0]}" == "verilator-safe" ]]; then
    verilator-safe status
  fi
}

VFLAGS=(--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION)

CORE_FILES=(
  rtl/ssv_pkg.sv
  rtl/mem/ssv_rom_loader.sv
  rtl/ssv_irq.sv
  rtl/ssv_video_timing.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv
  rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv
  rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_bg_renderer.sv
  rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv
  rtl/cpu/v60/s32_v60_bus.sv
  # ST010 (uPD96050) DSP: ssv_core instantiates the wrapper unconditionally
  # and gates it on cfg.has_st010, so these are needed by every core build.
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv
)

# Core without the ioctl loader (pure ssv_core benches).
SSV_CORE_FILES=(
  rtl/ssv_pkg.sv
  rtl/ssv_irq.sv
  rtl/ssv_video_timing.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv
  rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv
  rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_bg_renderer.sv
  rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv
  rtl/cpu/v60/s32_v60_bus.sv
  # ST010 (uPD96050) DSP: ssv_core instantiates the wrapper unconditionally
  # and gates it on cfg.has_st010, so these are needed by every core build.
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv
)

# run_labelled separates the build directory / binary name from the top module,
# so the same top can be built more than once with different -G parameters
# without the variants overwriting each other's obj dir.
run_labelled() {
  local label="$1"; local top="$2"; shift 2
  local bdir="$OUT/$label"
  mkdir -p "$bdir"
  echo "=== BUILD $label ==="
  vstatus
  if ! "${SSV_VERILATOR_ARR[@]}" "${VFLAGS[@]}" --top-module "$top" --Mdir "$bdir" -o "$label" "$@" >"$bdir/build.log" 2>&1; then
    echo "BUILD FAIL $label"; tail -40 "$bdir/build.log"; exit 1
  fi
  echo "=== RUN $label ==="
  vstatus
  "${SSV_VERILATOR_RUN_ARR[@]}" "$bdir/$label" | tee "$bdir/run.log"
}

run_one() {
  local top="$1"; shift
  run_labelled "$top" "$top" "$@"
}

run_one tb_ssv_rom_loader \
  rtl/ssv_pkg.sv rtl/mem/ssv_rom_loader.sv verif/tb_ssv_rom_loader.sv

# ST010 program fetch. Checks the instruction-address -> SDRAM-byte arithmetic
# and the big/little-endian handoff between the loader's packing and MAME's
# 32-bit-BE dspprg region, which nothing else covers.
run_one tb_ssv_st010_prg_fetch \
  rtl/ssv_pkg.sv rtl/cpu/upd96050/ssv_st010_prg_fetch.sv \
  verif/tb_ssv_st010_prg_fetch.sv

# Line doubler. Shipped in 095d3b2 with "never produced a pixel"; this bench
# found three real defects (907-vs-908 tick ratio, a one-pixel line shift, and
# vsync emitted three times per frame) and is the regression for their fixes.
run_one tb_ssv_scandoubler \
  rtl/ssv_pkg.sv rtl/ssv_video_timing.sv rtl/ssv_scandoubler.sv \
  verif/tb_ssv_scandoubler.sv

run_one tb_ssv_loader_core_boot \
  "${CORE_FILES[@]}" verif/tb_ssv_loader_core_boot.sv

run_one tb_ssv_rom_write_ack \
  "${SSV_CORE_FILES[@]}" verif/tb_ssv_rom_write_ack.sv

# Per-game tile-code modulus. 12,418 checks of ssv_pkg::wrap_code_cfg against a
# reference modulo across all nine target titles, plus a discrimination section
# proving the sweep can tell the titles apart. It existed unrun: no script
# invoked it, so the one test that covers six of the nine titles' graphics
# addressing was never a gate.
run_one tb_ssv_cfg \
  rtl/ssv_pkg.sv verif/tb_ssv_cfg.sv

# SDRAM controller against the chip model, including the bank/column coverage
# added 2026-07-30. This was ALSO unrun by any script, which mattered: until
# then every check in it addressed bank 0 only (the bench used 24-bit literals
# while bank is a[25:24] at COL_BITS=11), p1_addr/p5_addr were declared [24:3]
# against a [26:3] port so bursts could not physically leave bank 0, and p2 --
# the 8-lane assembly in deliver() -- was never driven at all.
#
# Read this bench's PASS narrowly. It proves the controller and
# verif/ssv_sdram_chip.sv agree with each other; both take their geometry and
# timing from the same constants, so it cannot prove either matches the physical
# part. The DQ capture margin is separately measured as zero (+/-1 clk_ram of
# read skew breaks the first single-word read), which is why SSV.sdc now
# constrains the bus.
run_one tb_ssv_sdram_loopback \
  rtl/ssv_pkg.sv rtl/mem/sdram.sv verif/ssv_sdram_chip.sv \
  verif/tb_ssv_sdram_loopback.sv

# Watchdog, all three board variants. The bench is parameterised for 0/1/2 and
# adapts its kick direction and expectations per mode, but only the default
# (mode 1) was ever run -- so the modes vasara/vasara2 (2, write-kick) and
# drifto94/stmblade (0, no device) depend on were untested. Mode 0 is the
# dangerous one: an unconditional counter resets those boards forever.
for wdog_mode in 0 1 2; do
  run_labelled "tb_ssv_watchdog_mode${wdog_mode}" tb_ssv_watchdog \
    -GWDOG_MODE="${wdog_mode}" \
    "${SSV_CORE_FILES[@]}" verif/tb_ssv_watchdog.sv
done

# Natural-vblank boot must raise video_enable (long RAM clear ~35s wall).
run_one tb_ssv_hang_watch \
  "${SSV_CORE_FILES[@]}" verif/ssv_tb_ce_cpu.sv verif/tb_ssv_hang_watch.sv

echo "ALL FOCUSED BRING-UP SIMS PASS"
echo "For full MAME write/hash post-VE diff: verif/run_post_ve_diff.sh"
