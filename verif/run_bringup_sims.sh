#!/usr/bin/env bash
# Build+run focused SSV bring-up sims under WSL Verilator.
# Native Verilator MCP can lint/compile, but MSYS link hits the CXX11 ABI issue.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/ssv-bringup"
mkdir -p "$OUT"
pwd
ls rtl/ssv_pkg.sv >/dev/null
VFLAGS=(--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -CFLAGS -D_GLIBCXX_USE_CXX11_ABI=0
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION +define+SSV_ST010_ENABLED)

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

run_one() {
  local top="$1"; shift
  local bdir="$OUT/$top"
  mkdir -p "$bdir"
  echo "=== BUILD $top ==="
  verilator-safe status
  if ! verilator-safe "${VFLAGS[@]}" --top-module "$top" --Mdir "$bdir" -o "$top" "$@" >"$bdir/build.log" 2>&1; then
    echo "BUILD FAIL $top"; tail -40 "$bdir/build.log"; exit 1
  fi
  echo "=== RUN $top ==="
  verilator-safe status
  verilator-sim-safe -- "$bdir/$top.exe" | tee "$bdir/run.log"
}

run_one tb_ssv_rom_loader \
  rtl/ssv_pkg.sv rtl/mem/ssv_rom_loader.sv verif/tb_ssv_rom_loader.sv

run_one tb_ssv_cfg \
  rtl/ssv_pkg.sv verif/tb_ssv_cfg.sv

run_one tb_ssv_irq \
  rtl/ssv_irq.sv verif/tb_ssv_irq.sv

run_one tb_ssv_video_timing \
  rtl/ssv_pkg.sv rtl/ssv_video_timing.sv verif/tb_ssv_video_timing.sv

run_one tb_ssv_palette_ram \
  rtl/common/s32_big_dpram.sv rtl/video/ssv_palette_ram.sv \
  verif/tb_ssv_palette_ram.sv

run_one tb_ssv_clock_ratio \
  rtl/ssv_pkg.sv rtl/ssv_video_timing.sv verif/ssv_tb_ce_cpu.sv \
  verif/tb_ssv_clock_ratio.sv

run_one tb_ssv_input_matrix \
  verif/tb_ssv_input_matrix.sv

run_one tb_ssv_nvram_bridge \
  rtl/mem/ssv_nvram_bridge.sv verif/tb_ssv_nvram_bridge.sv

run_one tb_ssv_gfx_row_fetch \
  rtl/ssv_pkg.sv rtl/video/ssv_gfx_row_fetch.sv \
  verif/tb_ssv_gfx_row_fetch.sv

run_one tb_ssv_bg_renderer \
  rtl/ssv_pkg.sv rtl/video/ssv_gfx_row_fetch.sv \
  rtl/video/ssv_gfx_row_decode.sv rtl/video/ssv_bg_renderer.sv \
  verif/tb_ssv_bg_renderer.sv

run_one tb_ssv_tilemap_page \
  rtl/ssv_pkg.sv rtl/video/ssv_gfx_row_fetch.sv \
  rtl/video/ssv_gfx_row_decode.sv rtl/video/ssv_bg_renderer.sv \
  verif/tb_ssv_tilemap_page.sv

run_one tb_ssv_cached_sprite_renderer \
  rtl/ssv_pkg.sv rtl/video/ssv_gfx_row_fetch.sv \
  rtl/video/ssv_gfx_row_decode.sv \
  rtl/video/ssv_cached_sprite_renderer.sv \
  verif/tb_ssv_cached_sprite_renderer.sv

run_one tb_ssv_line_buffer4 \
  rtl/common/s32_big_dpram.sv rtl/video/ssv_line_buffer4.sv \
  verif/tb_ssv_line_buffer4.sv

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

run_one tb_ssv_watchdog \
  "${SSV_CORE_FILES[@]}" verif/tb_ssv_watchdog.sv
run_one tb_ssv_watchdog_mode0 \
  "${SSV_CORE_FILES[@]}" verif/tb_ssv_watchdog.sv
run_one tb_ssv_watchdog_mode2 \
  "${SSV_CORE_FILES[@]}" verif/tb_ssv_watchdog.sv

# Natural-vblank boot must raise video_enable (long RAM clear ~35s wall).
run_one tb_ssv_hang_watch \
  "${SSV_CORE_FILES[@]}" verif/ssv_tb_ce_cpu.sv verif/tb_ssv_hang_watch.sv

echo "ALL FOCUSED BRING-UP SIMS PASS"
echo "For full MAME write/hash post-VE diff: verif/run_post_ve_diff.sh"
