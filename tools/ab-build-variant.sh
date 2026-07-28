#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build verif/tb_ssv_frame_crc.sv with either the current (`new`) renderers or
# the pre-fix (`old`) ones, so the two can be compared frame by frame.
#
# `old` reads sim_output/ab/oldrtl/{ssv_bg_renderer,ssv_cached_sprite_renderer}.sv,
# which you populate with e.g.
#   git show <commit>^:rtl/video/ssv_bg_renderer.sv > sim_output/ab/oldrtl/...
# rtl/ itself is never modified.
#
# See docs/DYNAGEAR_TILEMAP_PAGE_FIX_MAME_VERIFICATION.md.
#
# Usage: tools/ab-build-variant.sh new|old <outdir>
set -euo pipefail
VARIANT="$1"
OUT="$2"
cd "$(dirname "$0")/.."
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

if [ "$VARIANT" = "old" ]; then
  BG=sim_output/ab/oldrtl/ssv_bg_renderer.sv
  OBJ=sim_output/ab/oldrtl/ssv_cached_sprite_renderer.sv
else
  BG=rtl/video/ssv_bg_renderer.sv
  OBJ=rtl/video/ssv_cached_sprite_renderer.sv
fi

CORE=(
  rtl/ssv_pkg.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  "$BG" "$OBJ"
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

echo "built[$VARIANT]: $OUT/tb_ssv_frame_crc"
