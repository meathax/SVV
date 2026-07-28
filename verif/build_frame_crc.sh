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

JOBS="$(nproc)"
export OBJCACHE="${OBJCACHE:-ccache}"

VFLAGS=(--binary --timing --assert --threads 1
        --verilate-jobs "$JOBS" --build-jobs "$JOBS"
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH
        -Wno-CASEOVERLAP -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN
        -Wno-UNUSEDSIGNAL
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
  rtl/ssv_core.sv
  verif/ssv_tb_ce_cpu.sv
)

/usr/bin/verilator "${VFLAGS[@]}" --top-module tb_ssv_frame_crc \
  --Mdir "$OUT" -o tb_ssv_frame_crc \
  -Iverif "${CORE[@]}" verif/tb_ssv_frame_crc.sv \
  >"$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }

echo "built: $OUT/tb_ssv_frame_crc"
