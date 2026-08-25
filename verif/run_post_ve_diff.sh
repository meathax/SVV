#!/usr/bin/env bash
# Post-video_enable MAME/RTL differential gate (WSL Verilator).
# Extends ordered write + complete-state hash compares past the first lockout.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/ssv-post-ve"
mkdir -p "$OUT" sim_output/diff
CYCLES="${TRACE_CYCLES:-500000000}"
MAME_HASH="${MAME_HASH:-sim_output/diff/mame_v60_hash.trace}"
# The MAME retire-indexed IRQ3 schedule is deliberately NOT injected.
# Measured 2026-08-25 (dynagear, tb_ssv_realrom_boot, 300M cycles): driving
# irq3_pulse from mame_irq_schedule_8s.txt deadlocks the game. IRQ3 is
# dynagear's only interrupt source (cfg sets neither irq_level1_line0 nor
# irq_level2_line120), the schedule's first entry is retire 731058, and the
# retire indices do not track this RTL's retire stream, so boot stalls and
# the watchdog trips (SSV_WDOG_TRIP at cycle 144951920, host_writes frozen
# at 2092, audio_peak=0). The free-running raster IRQ3 is the hardware
# source and is what these gates have actually run on since ssv_core split
# irq3_pulse away from vblank_pulse; the bench force was a no-op for the IRQ
# path from that split until it was corrected.
MAME_WRITES="${MAME_WRITES:-sim_output/diff/mame_ssv_writes_long.trace}"
if [[ ! -f "$MAME_WRITES" ]]; then
  MAME_WRITES="sim_output/diff/mame_ssv_writes.trace"
fi
RTL_WRITES="${RTL_WRITES:-sim_output/diff/rtl_ssv_writes_postve.trace}"
RTL_HASH="${RTL_HASH:-sim_output/diff/rtl_v60_hash_postve.trace}"

VFLAGS=(--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION)

# Kept in step with verif/run_audio_sims.sh: this list had fallen behind
# ssv_core and the bench (missing ssv_srmp7_bank, ssv_tb_ce_cpu, the io/
# modules and ssv_st0020_ctrl), so the lane failed to verilate.
CORE=(
  rtl/ssv_pkg.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/io/ssv_mahjong_matrix.sv
  rtl/io/ssv_upd4701.sv rtl/io/ssv_upd7001.sv
  rtl/io/ssv_adc0809.sv rtl/io/ssv_93c46_16.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_st0020_ctrl.sv
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_mlab240_sdp.sv rtl/video/ssv_mlab88_sdp.sv
  rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_srmp7_bank.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/audio/ssv_audio_cdc.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  # ST010 (uPD96050) DSP: ssv_core instantiates the wrapper unconditionally
  # and gates it on cfg.has_st010, so these are needed by every core build.
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv
  verif/ssv_tb_ce_cpu.sv
)

echo "=== BUILD tb_ssv_realrom_boot ==="
mkdir -p "$OUT/boot"
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_realrom_boot \
  --Mdir "$OUT/boot" -o tb_ssv_realrom_boot \
  "${CORE[@]}" verif/tb_ssv_realrom_boot.sv \
  >"$OUT/boot/build.log" 2>&1

echo "=== RUN TRACE_CYCLES=$CYCLES REQUIRE_VE (raster IRQ3) ==="
verilator-safe status
verilator-sim-safe -- "$OUT/boot/tb_ssv_realrom_boot" \
  "+TRACE_CYCLES=$CYCLES" \
  +REQUIRE_VE \
  "+WRITE_TRACE=$RTL_WRITES" \
  "+TRACE=$RTL_HASH" \
  +TRACE_HASH_ONLY \
  | tee "$OUT/boot/run.log"

echo "=== COMPARE WRITES ==="
python3 tools/compare-ssv-write-traces.py "$MAME_WRITES" "$RTL_WRITES" \
  | tee "$OUT/writes_compare.log"

echo "=== COMPARE HASHES ==="
python3 tools/compare-v60-hash-traces.py "$MAME_HASH" "$RTL_HASH" \
  | tee "$OUT/hash_compare.log"

echo "=== BUILD/RUN tb_ssv_hang_watch (natural vblank VE gate) ==="
mkdir -p "$OUT/hang"
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_hang_watch \
  --Mdir "$OUT/hang" -o tb_ssv_hang_watch \
  "${CORE[@]}" verif/tb_ssv_hang_watch.sv \
  >"$OUT/hang/build.log" 2>&1
verilator-safe status
verilator-sim-safe -- "$OUT/hang/tb_ssv_hang_watch" | tee "$OUT/hang/run.log"

echo "ALL POST-VE DIFF GATES PASS"
