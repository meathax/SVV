#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build verif/tb_ssv_frame_crc.sv with Verilator directly.
#
# The repo's run_*.sh wrappers shell out to a `verilator-safe.exe` Windows
# launcher which stalls when it is invoked from a non-interactive nested WSL
# shell.  This script calls /usr/bin/verilator instead so the frame-CRC
# testbench can be built and run unattended.
#
# Usage: verif/build_frame_crc.sh [output_dir]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-${TMPDIR:-/tmp}/ssv-frame-crc}"
mkdir -p "$OUT"

# Bounded, NOT $(nproc). nproc is 32 on this host, so an unbounded build forks
# 32 compilers at up to ~1 GB each; two concurrent builds then exhaust the
# 64 GB. 6 matches the Quartus NUM_PARALLEL_PROCESSORS cap used elsewhere.
JOBS="${BUILD_JOBS:-6}"
# ccache keeps rebuilds cheap, but it is not installed everywhere this script
# runs (it is absent under Git Bash on this host). Fall back to no object cache
# rather than failing the build with "ccache: No such file or directory".
export OBJCACHE="${OBJCACHE:-ccache}"
command -v "$OBJCACHE" >/dev/null 2>&1 || export OBJCACHE=""

VFLAGS=(--binary --timing --assert --threads 1
        --verilate-jobs "$JOBS" --build-jobs "$JOBS"
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH
        -Wno-CASEOVERLAP -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN
        -Wno-UNUSEDSIGNAL
        +define+SIMULATION +define+SSV_ST010_ENABLED)

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
  # tb_ssv_frame_crc instantiates ssv_sdram_harness unconditionally, and that
  # harness instantiates the real `sdram` controller. Without this file the
  # build dies with MODMISSING, i.e. +REAL_SDRAM could not be built at all.
  rtl/mem/sdram.sv
  verif/ssv_tb_ce_cpu.sv
)

# Prefer WSL's /usr/bin/verilator (see header: it dodges the verilator-safe.exe
# launcher stall). Under Git Bash that path does not exist, so fall back to
# whatever verilator is on PATH there.
VERILATOR=/usr/bin/verilator
[ -x "$VERILATOR" ] || VERILATOR="$(command -v verilator)"

"$VERILATOR" "${VFLAGS[@]}" --top-module tb_ssv_frame_crc \
  --Mdir "$OUT" -o tb_ssv_frame_crc \
  -Iverif "${CORE[@]}" verif/tb_ssv_frame_crc.sv \
  >"$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }

echo "built: $OUT/tb_ssv_frame_crc"
