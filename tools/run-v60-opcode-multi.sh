#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drive tools/mame-v60-opcode-histogram-multi.lua across every SSV set the
# universal core supports, in parallel.
#
#   tools/run-v60-opcode-multi.sh [emulated_seconds] [outdir]
#
# Run from the repo root inside WSL.  Requires MAME with Lua and the set ZIPs
# in $ROMPATH (default rom/).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAME="${MAME:-/usr/games/mame}"
ROMPATH="${ROMPATH:-rom}"
SECS="${1:-900}"
OUTDIR="${2:-sim_output/mame/multi/run}"

SETS="${SETS:-dynagear cairblad vasara vasara2 drifto94 stmblade twineag2 ultrax}"
# preset:seed pairs run for every set
RUNS="${RUNS:-play:1 play:7 play_2p:5 idle:1}"

# Stage all run output on a native Linux filesystem, not the Windows DrvFs
# mount.  With 32 MAME instances writing reports every 30 emulated seconds,
# io.open() on /mnt/d intermittently fails; the Lua side now survives that
# (pcall + report_write_failures), but staging on ext4 avoids it entirely.
# Results are copied back to OUTDIR when every run has finished.
STAGE="${STAGE:-/tmp/v60-multi-$$}"

mkdir -p "$OUTDIR/snap" "$STAGE/snap"
echo "MAME: $("$MAME" -version 2>/dev/null | head -1)"
echo "stage: $STAGE -> $OUTDIR"
echo "sets: $SETS"
echo "runs per set: $RUNS   seconds each: $SECS"

# SPECS lets a rerun name individual set:preset:seed triples instead of the
# full SETS x RUNS cross product - used to re-run only the runs a previous
# sweep lost, without disturbing the ones that completed.
SPECS="${SPECS:-}"
if [ -z "$SPECS" ]; then
  for g in $SETS; do
    for spec in $RUNS; do
      SPECS="$SPECS $g:${spec%%:*}:${spec##*:}"
    done
  done
fi
echo "specs: $SPECS"

pids=()
for triple in $SPECS; do
    g="${triple%%:*}"
    rest="${triple#*:}"
    preset="${rest%%:*}"
    seed="${rest##*:}"
    tag="${g}_${preset}_s${seed}"
    (
      V60_OUT="$STAGE/${tag}.txt" \
      V60_PROGRESS="$STAGE/${tag}.progress" \
      V60_PCLIST="$STAGE/${tag}.pclist" \
      V60_SNAP_PREFIX="$STAGE/snap/${tag}" \
      V60_SNAP_EVERY="${V60_SNAP_EVERY:-60}" \
      V60_REPORT_EVERY="${V60_REPORT_EVERY:-30}" \
      V60_SEED="$seed" \
      V60_PRESET="$preset" \
      "$MAME" "$g" -rompath "$ROMPATH" \
        -video none -sound none -nothrottle \
        -seconds_to_run "$SECS" \
        -autoboot_script tools/mame-v60-opcode-histogram-multi.lua \
        >"$STAGE/${tag}.log" 2>&1
      echo "done: $tag rc=$?"
    ) &
    pids+=($!)
done

for p in "${pids[@]}"; do wait "$p"; done

cp -f "$STAGE"/*.txt "$STAGE"/*.progress "$STAGE"/*.pclist "$STAGE"/*.log "$OUTDIR"/ 2>/dev/null
cp -f "$STAGE"/*.hit "$OUTDIR"/ 2>/dev/null
cp -f "$STAGE"/snap/*.ppm "$OUTDIR/snap/" 2>/dev/null
rm -rf "$STAGE"
echo "--- all runs complete: $OUTDIR ---"
