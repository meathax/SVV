#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drive the MAME V60 opcode-histogram harness across a matrix of run presets
# and seeds, in parallel, then merge the results.
#
# Usage (from the repo root, inside WSL):
#   tools/run-v60-opcode-audit.sh [emulated_seconds]
#
# Requires: MAME with Lua scripting, dynagear.zip in $ROMPATH.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAME="${MAME:-/usr/games/mame}"
ROMPATH="${ROMPATH:-sim_output/mame/roms}"
SECS="${1:-1800}"
OUTDIR="${OUTDIR:-sim_output/mame/audit}"

mkdir -p "$OUTDIR/snap"

# preset:seed
RUNS=(
  "play_easy:1"
  "play_easy:7"
  "play_easy:13"
  "play_easy:29"
  "play_easy:41"
  "play_easy:53"
  "play_easy:67"
  "play_easy:89"
  "play_2p:5"
  "play_2p:23"
  "gameover:3"
  "gameover:31"
  "idle:1"
  "service:1"
)

echo "MAME: $("$MAME" -version 2>/dev/null | head -1)"
echo "runs: ${#RUNS[@]}  seconds each: $SECS"

pids=()
for spec in "${RUNS[@]}"; do
  preset="${spec%%:*}"
  seed="${spec##*:}"
  tag="${preset}_s${seed}"
  (
    V60_OUT="$OUTDIR/${tag}.txt" \
    V60_PROGRESS="$OUTDIR/${tag}.progress" \
    V60_PCLIST="$OUTDIR/${tag}.pclist" \
    V60_SNAP_PREFIX="$OUTDIR/snap/${tag}" \
    V60_SNAP_EVERY="${V60_SNAP_EVERY:-120}" \
    V60_REPORT_EVERY="${V60_REPORT_EVERY:-60}" \
    V60_SEED="$seed" \
    V60_PRESET="$preset" \
    "$MAME" dynagear -rompath "$ROMPATH" \
      -video none -sound none -nothrottle \
      -seconds_to_run "$SECS" \
      -autoboot_script tools/mame-v60-opcode-histogram.lua \
      >"$OUTDIR/${tag}.log" 2>&1
    echo "done: $tag rc=$?"
  ) &
  pids+=($!)
done

for p in "${pids[@]}"; do wait "$p"; done

echo "--- merging ---"
python3 tools/merge-v60-opcode-reports.py "$OUTDIR"/*.txt \
  > "$OUTDIR/merged.txt"
tail -40 "$OUTDIR/merged.txt"
