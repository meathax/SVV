#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Assemble the committed V60 opcode audit artefacts from the raw run outputs.
#
#   docs/V60_OPCODE_HITLIST.txt      merged hit list (the deliverable)
#   docs/V60_OPCODE_STATIC_SCAN.txt  static candidate sites + boundary vote
#
# Usage: tools/finalize-v60-audit.sh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

ROM=sim_output/rom/maincpu.bin
DASM=${DASM:-/tmp/dasm}

echo "== merging run reports =="
python3 tools/merge-v60-opcode-reports.py \
    sim_output/mame/audit/*.txt sim_output/mame/audit2/*.txt \
    > docs/V60_OPCODE_HITLIST.txt
grep -E '^GROUP' docs/V60_OPCODE_HITLIST.txt

echo
echo "== static candidate scan + boundary vote =="
{
  python3 tools/scan-v60-opcode-sites.py "$ROM"
  echo
  echo "########## instruction-boundary vote ##########"
  python3 tools/analyse-v60-candidates.py --rom "$ROM" \
      --dasm "$DASM/align*.txt" \
      --pclist 'sim_output/mame/pc/*.pclist'
} > docs/V60_OPCODE_STATIC_SCAN.txt
grep -E '^(SCAN [0-9a-f]{2} raw|CAND [0-9a-f]{2}  )' docs/V60_OPCODE_STATIC_SCAN.txt

echo
echo "== coverage curve =="
python3 - <<'PY'
import glob, re
rows = {}
for p in sorted(glob.glob('sim_output/mame/audit/*.progress')):
    tag = p.split('/')[-1].replace('.progress', '')
    for line in open(p):
        m = re.search(r'sec=([\d.]+) .*distinct_pc=(\d+)', line)
        if m:
            rows.setdefault(tag, {})[float(m.group(1))] = int(m.group(2))
cols = [60, 300, 600, 900, 1200, 1500, 1800]
print('%-16s' % 'run' + ''.join('%9d' % c for c in cols))
for t in sorted(rows):
    print('%-16s' % t + ''.join('%9s' % rows[t].get(c, '-') for c in cols))
PY
