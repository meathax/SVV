#!/usr/bin/env bash
# Wave C: attract frame-0 CRC re-prove + coin_start soak.
set -euo pipefail
cd "$(dirname "$0")/.."

ulimit -s unlimited 2>/dev/null || ulimit -s 65536

OUT="${TMPDIR:-/tmp}/ssv-frame"
mkdir -p "$OUT" sim_output/diff
VFLAGS=(--binary --timing -j 0 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
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
  rtl/audio/ssv_es5506_regs.sv rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  rtl/ssv_core.sv
  verif/ssv_tb_ce_cpu.sv
)

rm -rf "$OUT"
mkdir -p "$OUT"
echo "=== BUILD tb_ssv_frame_crc ==="
if ! verilator "${VFLAGS[@]}" --top-module tb_ssv_frame_crc \
  --Mdir "$OUT" -o tb_ssv_frame_crc -Iverif "${CORE[@]}" verif/tb_ssv_frame_crc.sv \
  >"$OUT/build.log" 2>&1; then
  echo "BUILD FAIL"; tail -40 "$OUT/build.log"; exit 1
fi

echo "=== RUN attract_idle ==="
"$OUT/tb_ssv_frame_crc" \
  +SCENARIO=attract_idle \
  +FRAMES=30 +SOAK_FRAMES=15 \
  +FRAME_CRC=/tmp/rtl_attract_idle_frames.crc \
  | tee "$OUT/attract.log"
cp /tmp/rtl_attract_idle_frames.crc sim_output/diff/rtl_attract_idle_frames.crc

echo "=== COMPARE frame 0 ==="
python3 tools/compare-ssv-frame-crcs.py \
  sim_output/diff/mame_attract_idle_frames.crc \
  /tmp/rtl_attract_idle_frames.crc \
  --max-frames 1

echo "=== COMPARE frames 0-29 (expect diverge at >=1) ==="
python3 tools/compare-ssv-frame-crcs.py \
  sim_output/diff/mame_attract_idle_frames.crc \
  /tmp/rtl_attract_idle_frames.crc \
  --max-frames 30 || true

echo "=== RUN coin_start_p1 ==="
"$OUT/tb_ssv_frame_crc" \
  +SCENARIO=coin_start_p1 \
  +FRAMES=40 +SOAK_FRAMES=35 \
  +FRAME_CRC=/tmp/rtl_coin_start_p1_frames.crc \
  | tee "$OUT/coin.log"
cp /tmp/rtl_coin_start_p1_frames.crc sim_output/diff/rtl_coin_start_p1_frames.crc

echo "WAVE_C_DONE"
