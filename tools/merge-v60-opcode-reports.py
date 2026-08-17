#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Merge V60 opcode-histogram reports produced by mame-v60-opcode-histogram.lua.

Usage: merge-v60-opcode-reports.py run1.txt run2.txt ... > merged.txt
"""
import sys
from collections import defaultdict

# Primary-opcode groups this audit cares about (see rtl/cpu/v60/s32_v60.sv).
SUSPECT = {
    0x59: "decimal (BCD)",
    0x5B: "bit string",
    0x5D: "bit field",
    0x5C: "floating point",
    0x5F: "floating point (convert)",
}


def main(paths):
    hist = defaultdict(int)
    first_pc = {}
    sites = defaultdict(lambda: defaultdict(int))
    subops = defaultdict(lambda: defaultdict(int))
    runs = []
    all_pc_counted = 0

    for path in paths:
        meta = {}
        with open(path) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.startswith("#"):
                    body = line.lstrip("# ").strip()
                    if "=" in body and " " not in body.split("=")[0]:
                        for tok in body.split():
                            if "=" in tok:
                                k, v = tok.split("=", 1)
                                meta[k] = v
                    continue
                f = line.split()
                if not f:
                    continue
                if f[0] == "OP":
                    op = int(f[1], 16)
                    hist[op] += int(f[2])
                    pc = int(f[3], 16)
                    if op not in first_pc:
                        first_pc[op] = pc
                elif f[0] == "SUBOP":
                    subops[int(f[1], 16)][int(f[2], 16)] += int(f[3])
                elif f[0] == "SITE":
                    sites[int(f[1], 16)][int(f[2], 16)] += int(f[3])
        runs.append((path, meta))
        all_pc_counted += int(meta.get("distinct_instruction_addresses", 0) or 0)

    out = sys.stdout.write
    out("# Merged V60 executed-opcode histogram - Dyna Gear\n")
    out("#\n# runs merged:\n")
    total_ops = 0
    for path, meta in runs:
        out("#   %-44s preset=%-10s seed=%-3s frames=%-8s ops=%-12s "
            "distinct_pc=%s\n" % (
                path.split("/")[-1], meta.get("preset", "?"),
                meta.get("seed", "?"), meta.get("emulated_frames", "?"),
                meta.get("retired_instructions", "?"),
                meta.get("distinct_instruction_addresses", "?")))
        try:
            total_ops += int(meta.get("retired_instructions", 0))
        except ValueError:
            pass
    out("#\n# mame_version=%s\n" % (runs[0][1].get("mame_version", "?") if runs else "?"))
    out("# total_retired_instructions=%d\n" % total_ops)
    out("# distinct_primary_opcodes_executed=%d of 256\n" % len(hist))
    out("#\n")

    out("# ---- executed primary opcodes ----\n")
    out("# opcode  count            first_pc\n")
    for op in sorted(hist):
        out("OP %02x %16d %06x\n" % (op, hist[op], first_pc.get(op, 0)))

    out("#\n# ---- never executed (primary opcode byte) ----\n")
    missing = [op for op in range(256) if op not in hist]
    for i in range(0, len(missing), 16):
        out("NOEXEC " + " ".join("%02x" % o for o in missing[i:i + 16]) + "\n")

    out("#\n# ---- 0x58..0x5F two-byte group verdict ----\n")
    for op in range(0x58, 0x60):
        label = SUSPECT.get(op, "byte/half string" if op in (0x58, 0x5A)
                            else "other")
        if op in hist:
            subs = " ".join("%02x:%d" % (s, c)
                            for s, c in sorted(subops[op].items()))
            out("GROUP %02x  EXECUTED  count=%d sites=%d  (%s)\n"
                % (op, hist[op], len(sites[op]), label))
            out("GROUP %02x  subops: %s\n" % (op, subs))
            for pc, c in sorted(sites[op].items()):
                out("GROUP %02x  site pc=%06x count=%d\n" % (op, pc, c))
        else:
            out("GROUP %02x  NOT-EXECUTED  (%s)\n" % (op, label))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
