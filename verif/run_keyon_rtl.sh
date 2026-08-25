#!/usr/bin/env bash
# RTL side of the ES5506 key-on content comparison.
#
# Drives drifto94 through its coin+start gameplay scenario and records every
# voice key-on (bank, START, END, FC) reconstructed from the core's own host
# commit stream. The MAME side records the same thing from a write tap, so the
# two logs answer one question: does the RTL ever key a sample region the
# reference never keys?
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN:-/mnt/r/Verilator/SVV/keyon/tb_ssv_frame_crc}"
[[ -f "$BIN.exe" ]] && BIN="$BIN.exe"
OUT="${OUT:-sim_output/keyon}"
mkdir -p "$OUT"

IMAGE=sim_output/rom/drifto94
FRAMES="${FRAMES:-1400}"
SOAK="${SOAK:-0}"
CYCLES="${CYCLES:-2000000000}"
SCENARIO="${SCENARIO:-drifto94_gameplay}"

"$BIN" \
  +GAME_ID=4 +DSW1=FFFF +DSW2=FFFF \
  +MAINROM="$IMAGE/maincpu.bin" \
  +SPRROM="$IMAGE/sprites.bin" \
  +SMPROM="$IMAGE/samples.bin" \
  +ST010ROM="$IMAGE/st010.bin" \
  +SCENARIO="$SCENARIO" \
  +FRAMES="$FRAMES" +SOAK_FRAMES="$SOAK" +CYCLES="$CYCLES" \
  +KEYON_OUT="$OUT/rtl_keyon.txt" \
  ${EXTRA_ARGS:-} \
  2>&1 | tail -20
