#!/usr/bin/env bash
# Build one descriptor-driven model, then prove every qualified set reaches
# visible attract mode with its own private MAME/MRA-derived image. The
# release evidence is Verilator-only: each successful run also writes a
# screenshot from the same attract frame that satisfied the gate.
set -euo pipefail
cd "$(dirname "$0")/.."

ulimit -s unlimited 2>/dev/null || ulimit -s 65536
OUT="${TMPDIR:-/tmp}/ssv-universal-attract"
mkdir -p "$OUT" sim_output/universal_attract
# 360 post-VE frames is a six-second no-input run at the native raster rate.
# It is long enough to pass title screens and reach the normal attract/demo
# loop for the qualified SSV sets. Dense sprite-list sets need more than the
# old 400M guard to reach all requested frames, so retain deterministic headroom
# in the default budget while allowing focused runs to override it.
MAX_FRAMES="${FRAMES:-360}"
MIN_SOAK_FRAMES="${SOAK_FRAMES:-360}"
MAX_CYCLES="${CYCLES:-500000000}"
SCREENSHOT_FRAME="${SCREENSHOT_FRAME:-359}"
if (( SCREENSHOT_FRAME < 0 || SCREENSHOT_FRAME >= MAX_FRAMES )); then
  echo "SCREENSHOT_FRAME=$SCREENSHOT_FRAME must be within 0..$((MAX_FRAMES - 1))" >&2
  exit 2
fi

VFLAGS=(--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION)

# Keep the production wide fetch path as the default, but allow a focused
# behavioural A/B run against the legacy ce-gated adapter. This is a diagnostic
# switch only; it never changes the descriptor/profile or creates a second RTL
# implementation.
if [[ "${FAST_IFETCH:-1}" == 0 ]]; then
  VFLAGS+=(+define+FAST_IFETCH_EN=0)
fi

CORE=(
  rtl/ssv_pkg.sv rtl/mem/sdram.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_mlab240_sdp.sv
  rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv verif/ssv_tb_ce_cpu.sv
)

echo "=== BUILD universal descriptor-driven frame model ==="
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_frame_crc \
  --Mdir "$OUT/model" -o tb_ssv_frame_crc -Iverif \
  "${CORE[@]}" verif/tb_ssv_frame_crc.sv >"$OUT/build.log" 2>&1

if [[ "${BUILD_ONLY:-0}" == 1 ]]; then
  echo "BUILD_ONLY complete: $OUT/model/tb_ssv_frame_crc"
  exit 0
fi

# Read the set list from the authoritative manifest and defaults from the
# generated MRA. This script intentionally contains no second game list.
mapfile -t PROFILE < <(python3 -c '
import pathlib, xml.etree.ElementTree as ET
from tools.ssv_supported_sets import SUPPORTED_SETS, SUPPORTED_SET_IDS
for setname in SUPPORTED_SETS:
    mra = next(path for path in pathlib.Path("mra").glob("*.mra")
               if ET.parse(path).getroot().findtext("setname") == setname)
    root = ET.parse(mra).getroot()
    dsw = (root.find("switches").get("default", "FF,FD")).split(",")
    print(f"{setname}|{SUPPORTED_SET_IDS[setname]}|FF{dsw[0]}|FF{dsw[1]}")
')

for row in "${PROFILE[@]}"; do
  IFS='|' read -r setname game_id dsw1 dsw2 <<<"$row"
  if [[ -n "${ONLY_SET:-}" && "$setname" != "$ONLY_SET" ]]; then
    continue
  fi
  image="sim_output/rom/$setname"
  log="$OUT/${setname}.log"
  crc="sim_output/universal_attract/${setname}.crc"
  shot_dir="sim_output/universal_attract/verilator"
  shot_ppm="$shot_dir/${setname}_attract_f${SCREENSHOT_FRAME}.ppm"
  shot_png="${shot_ppm%.ppm}.png"
  mkdir -p "$shot_dir"
  echo "=== RUN $setname (id=$game_id dsw1=$dsw1 dsw2=$dsw2) ==="
  verilator-safe status
  sim_args=(
    +GAME_ID="$game_id" +DSW1="$dsw1" +DSW2="$dsw2"
    +MAINROM="$image/maincpu.bin" +SPRROM="$image/sprites.bin"
    +SMPROM="$image/samples.bin" +FRAME_CRC="$crc"
    +SCENARIO=attract_idle +FRAMES="$MAX_FRAMES" +SOAK_FRAMES="$MIN_SOAK_FRAMES"
    +CYCLES="$MAX_CYCLES" +REQUIRE_ATTRACT +REQUIRE_VERILATOR_SCREENSHOT
    +STOP_ON_RENDERER_OVERRUN +DUMP_PPM="$shot_ppm"
    +DUMP_PPM_FRAME="$SCREENSHOT_FRAME"
  )
  if [[ "${REAL_SDRAM:-0}" == 1 ]]; then
    sim_args+=(+REAL_SDRAM)
  fi
  if [[ "${LIGHT_DIAG:-0}" == 1 ]]; then
    sim_args+=(+LIGHT_DIAG)
  fi
  verilator-sim-safe -- "$OUT/model/tb_ssv_frame_crc" "${sim_args[@]}" \
    | tee "$log"
  grep -q "PASS tb_ssv_frame_crc" "$log"
  [[ -s "$shot_ppm" ]] || { echo "missing/empty Verilator screenshot: $shot_ppm" >&2; exit 1; }
  python3 tools/ppm-to-png.py --scale 4 "$shot_ppm"
  [[ -s "$shot_png" ]] || { echo "missing/empty converted Verilator screenshot: $shot_png" >&2; exit 1; }
  echo "VERILATOR_SCREENSHOT $shot_png"
done

echo "ALL UNIVERSAL SETS REACHED ATTRACT MODE"
