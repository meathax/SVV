#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Positive control for the multi-set V60 opcode harness.
#
# A detector that reports "never executed" is worthless until it has been
# shown to fire when the opcode IS executed.  For each set, patch the loaded
# program ROM at an address the game demonstrably executes during boot so the
# instruction there becomes each candidate group opcode, and require exactly
# one recorded hit.  The game usually crashes right afterwards; that is fine.
#
#   tools/run-v60-opcode-multi-control.sh
#
# The per-set injection address is a PC observed in that set's own evidence
# run (first_pc of a common early opcode).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MAME="${MAME:-/usr/games/mame}"
ROMPATH="${ROMPATH:-rom}"
OUTDIR="${OUTDIR:-sim_output/mame/multi/control}"
mkdir -p "$OUTDIR"

# set:inject_address (an address executed during that set's boot)
TARGETS="${TARGETS:-}"
if [ -z "$TARGETS" ]; then
  echo "usage: TARGETS='set:addr set:addr ...' $0" >&2
  echo "  e.g. TARGETS='vasara2:f00168 ultrax:e0012a'" >&2
  exit 2
fi

pids=()
for t in $TARGETS; do
  g="${t%%:*}"
  addr="${t##*:}"
  for op in 59 5b 5c 5d 5f; do
   (
    out="$OUTDIR/inj_${g}_${op}.txt"
    V60_INJECT="${addr}:${op}:00" \
    V60_OUT="$out" \
    V60_PROGRESS="$OUTDIR/inj_${g}_${op}.progress" \
    V60_PRESET="${CTRL_PRESET:-play}" \
    "$MAME" "$g" -rompath "$ROMPATH" -video none -sound none -nothrottle \
      -seconds_to_run "${CTRL_SECS:-30}" \
      -autoboot_script tools/mame-v60-opcode-histogram-multi.lua \
      >"$OUTDIR/inj_${g}_${op}.log" 2>&1
    line="$(grep -E "^OP ${op} " "$out" 2>/dev/null || true)"
    if [ -n "$line" ]; then
      echo "CONTROL $g $op PASS  $line"
    else
      echo "CONTROL $g $op FAIL  (no hit recorded - detector is blind)"
    fi
   ) &
   pids+=($!)
  done
done
for p in "${pids[@]}"; do wait "$p"; done
