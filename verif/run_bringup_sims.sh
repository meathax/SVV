#!/usr/bin/env bash
# Build+run focused SSV bring-up sims under WSL Verilator.
# Native Verilator MCP can lint/compile, but MSYS link hits the CXX11 ABI issue.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/ssv-bringup"
mkdir -p "$OUT"
pwd
ls rtl/ssv_pkg.sv >/dev/null
VFLAGS=(--binary --timing -j 0 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
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
  rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv
  rtl/cpu/v60/s32_v60_bus.sv
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
  rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv
  rtl/cpu/v60/s32_v60_bus.sv
  rtl/ssv_core.sv
)

run_one() {
  local top="$1"; shift
  local bdir="$OUT/$top"
  rm -rf "$bdir"; mkdir -p "$bdir"
  echo "=== BUILD $top ==="
  if ! verilator "${VFLAGS[@]}" --top-module "$top" --Mdir "$bdir" -o "$top" "$@" >"$bdir/build.log" 2>&1; then
    echo "BUILD FAIL $top"; tail -40 "$bdir/build.log"; exit 1
  fi
  echo "=== RUN $top ==="
  "$bdir/$top" | tee "$bdir/run.log"
}

run_one tb_ssv_diag_video \
  rtl/ssv_pkg.sv rtl/ssv_video_timing.sv rtl/ssv_diag_video.sv verif/tb_ssv_diag_video.sv

run_one tb_ssv_rom_loader \
  rtl/ssv_pkg.sv rtl/mem/ssv_rom_loader.sv verif/tb_ssv_rom_loader.sv

run_one tb_ssv_loader_core_boot \
  "${CORE_FILES[@]}" verif/tb_ssv_loader_core_boot.sv

run_one tb_ssv_rom_write_ack \
  "${SSV_CORE_FILES[@]}" verif/tb_ssv_rom_write_ack.sv

# Natural-vblank boot must raise video_enable (long RAM clear ~35s wall).
run_one tb_ssv_hang_watch \
  "${SSV_CORE_FILES[@]}" verif/tb_ssv_hang_watch.sv

echo "ALL FOCUSED BRING-UP SIMS PASS"
echo "For full MAME write/hash post-VE diff: verif/run_post_ve_diff.sh"
