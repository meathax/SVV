#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Second wave of the V60 opcode audit: the forward-biased `play_rush` bot only.
# Wave 1 (tools/run-v60-opcode-audit.sh) saturated inside stage 1 because the
# 25%-left random walk kept timing out on the 99-unit stage clock.  This wave
# trades exploration for forward progress to try to reach the stage-1 boss and
# beyond.
#
# Usage: tools/run-v60-opcode-wave2.sh [emulated_seconds] [n_seeds]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAME="${MAME:-/usr/games/mame}"
ROMPATH="${ROMPATH:-sim_output/mame/roms}"
SECS="${1:-2400}"
NSEEDS="${2:-12}"
OUTDIR="${OUTDIR:-sim_output/mame/audit2}"

mkdir -p "$OUTDIR/snap"

SEEDS=(2 11 17 19 37 43 59 71 97 101 113 127 131 149 151 163)

pids=()
for ((i = 0; i < NSEEDS; i++)); do
  seed="${SEEDS[$i]}"
  tag="play_rush_s${seed}"
  (
    V60_OUT="$OUTDIR/${tag}.txt" \
    V60_PROGRESS="$OUTDIR/${tag}.progress" \
    V60_PCLIST="$OUTDIR/${tag}.pclist" \
    V60_SNAP_PREFIX="$OUTDIR/snap/${tag}" \
    V60_SNAP_EVERY="${V60_SNAP_EVERY:-120}" \
    V60_REPORT_EVERY="${V60_REPORT_EVERY:-60}" \
    V60_SEED="$seed" \
    V60_PRESET="play_rush" \
    "$MAME" dynagear -rompath "$ROMPATH" \
      -video none -sound none -nothrottle \
      -seconds_to_run "$SECS" \
      -autoboot_script tools/mame-v60-opcode-histogram.lua \
      >"$OUTDIR/${tag}.log" 2>&1
  ) &
  pids+=($!)
done

for p in "${pids[@]}"; do wait "$p"; done
echo "wave2 done"
