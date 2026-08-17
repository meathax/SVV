#!/usr/bin/env bash
# Thin wrapper around the Python multi-shot play capture helper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/verif/run_play_screenshots.py" "$@"
