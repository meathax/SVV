#!/usr/bin/env bash
# Full-core frame bench against the REAL SDRAM controller.
#
#   rtl/mem/sdram.sv  +  verif/sdram_chip_model.sv  +  rtl/mem/ssv_rom_loader.sv
#
# Builds one binary that can run either SDRAM model:
#   default            per-port stub (golden-CRC compatible, unchanged)
#   +SDRAM_REAL        real controller + chip model
#
# Use the project safe launchers. They enforce the headless, single-thread
# contract and select the matching UCRT64 compiler/runtime on Windows.
#
# Usage:
#   bash verif/run_sdram_bench.sh build
#   bash verif/run_sdram_bench.sh stub   [extra plusargs...]
#   bash verif/run_sdram_bench.sh real   [extra plusargs...]
set -euo pipefail
cd "$(dirname "$0")/.."

ulimit -s unlimited 2>/dev/null || ulimit -s 65536

VERILATOR="${VERILATOR:-verilator-safe}"
SIMULATOR="${SIMULATOR:-verilator-sim-safe}"
OUT="${OUT:-/tmp/ssv-sdram-bench}"
JOBS="${JOBS:-$(nproc)}"
# Do not assume ccache is installed. Callers may opt in by exporting OBJCACHE.
export OBJCACHE="${OBJCACHE:-}"

VFLAGS=(--binary --timing --assert --threads 1
        --verilate-jobs "$JOBS" --build-jobs "$JOBS"
        -CFLAGS -D_GLIBCXX_USE_CXX11_ABI=0
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION)

CORE=(
  rtl/ssv_pkg.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/io/ssv_mahjong_matrix.sv
  rtl/io/ssv_upd4701.sv rtl/io/ssv_upd7001.sv
  rtl/io/ssv_adc0809.sv rtl/io/ssv_93c46_16.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_st0020_ctrl.sv
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_mlab240_sdp.sv
  rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_srmp7_bank.sv rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv
  rtl/mem/sdram.sv rtl/mem/ssv_rom_loader.sv
  verif/sdram_chip_model.sv
  verif/ssv_tb_ce_cpu.sv
)

# RTL_DIR lets the DoD#3 experiment point the build at a scratch copy of rtl/
# without touching the tree Stream 1 owns.
RTL_DIR="${RTL_DIR:-}"
if [[ -n "$RTL_DIR" ]]; then
  for i in "${!CORE[@]}"; do
    CORE[$i]="${CORE[$i]/#rtl\//$RTL_DIR/}"
  done
fi

do_build() {
  mkdir -p "$OUT"
  echo "=== build -> $OUT/tb_ssv_frame_crc ==="
  "$VERILATOR" "${VFLAGS[@]}" --top-module tb_ssv_frame_crc \
    --Mdir "$OUT" -o tb_ssv_frame_crc \
    -Iverif "${CORE[@]}" verif/tb_ssv_frame_crc.sv \
    2>&1 | tee "$OUT/build.log" | tail -40
  test -f "$OUT/tb_ssv_frame_crc" -o -f "$OUT/tb_ssv_frame_crc.exe"
}

model_bin() {
  if [[ -f "$OUT/tb_ssv_frame_crc.exe" ]]; then
    printf '%s' "$OUT/tb_ssv_frame_crc.exe"
  else
    printf '%s' "$OUT/tb_ssv_frame_crc"
  fi
}

case "${1:-build}" in
  build) do_build ;;
  stub)  shift; "$SIMULATOR" -- "$(model_bin)" "$@" ;;
  real)  shift; "$SIMULATOR" -- "$(model_bin)" +SDRAM_REAL "$@" ;;
  *) echo "usage: $0 {build|stub|real} [plusargs]" >&2; exit 2 ;;
esac
