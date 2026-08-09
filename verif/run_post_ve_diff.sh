#!/usr/bin/env bash
# Post-video_enable MAME/RTL differential gate (WSL Verilator).
# Extends ordered write + complete-state hash compares past the first lockout.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/ssv-post-ve"
mkdir -p "$OUT" sim_output/diff
CYCLES="${TRACE_CYCLES:-500000000}"
MAME_HASH="${MAME_HASH:-sim_output/diff/mame_v60_hash.trace}"
IRQ_SCHED="${IRQ_SCHED:-sim_output/diff/mame_irq_schedule_8s.txt}"
if [[ ! -f "$IRQ_SCHED" ]]; then
  IRQ_SCHED="sim_output/diff/mame_irq_schedule_long.txt"
fi
if [[ ! -f "$IRQ_SCHED" ]]; then
  IRQ_SCHED="sim_output/diff/mame_irq_schedule.txt"
fi
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

CORE=(
  rtl/ssv_pkg.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  # ST010 (uPD96050) DSP: ssv_core instantiates the wrapper unconditionally
  # and gates it on cfg.has_st010, so these are needed by every core build.
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv
)

echo "=== BUILD tb_ssv_realrom_boot ==="
mkdir -p "$OUT/boot"
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_realrom_boot \
  --Mdir "$OUT/boot" -o tb_ssv_realrom_boot \
  "${CORE[@]}" verif/tb_ssv_realrom_boot.sv \
  >"$OUT/boot/build.log" 2>&1

echo "=== RUN TRACE_CYCLES=$CYCLES REQUIRE_VE + MAME IRQ ==="
verilator-safe status
verilator-sim-safe -- "$OUT/boot/tb_ssv_realrom_boot" \
  "+TRACE_CYCLES=$CYCLES" \
  +REQUIRE_VE \
  "+DIFF_IRQ_SCHEDULE=$IRQ_SCHED" \
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
