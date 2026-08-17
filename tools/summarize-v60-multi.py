#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarize multi-set V60 opcode-histogram reports into a per-set verdict table.

    tools/summarize-v60-multi.py sim_output/mame/multi/run/*.txt

Produces, per setname:
  * the run matrix actually completed (preset/seed, emulated seconds, retired
    instructions, distinct executed instruction addresses)
  * an integrity line (rom_base, mismatches) - a run with mismatches != 0 or
    zero retired instructions is INVALID and is reported as such rather than
    counted as "never executed"
  * per-group hit/no-hit for the whole 0x58..0x5F two-byte family

The distinction this script exists to preserve: "no hit in a valid run" is
evidence; "no hit in an invalid run" is nothing at all.
"""
import sys
import glob
from collections import defaultdict

GROUPS = {
    0x58: "byte string (implemented)",
    0x59: "decimal / BCD           *candidate*",
    0x5A: "half string (implemented)",
    0x5B: "bit string              *candidate*",
    0x5C: "floating point          *candidate*",
    0x5D: "bit field               *candidate*",
    0x5E: "long float (not implemented)",
    0x5F: "float convert           *candidate*",
}
CANDIDATES = [0x59, 0x5B, 0x5C, 0x5D, 0x5F]


def parse(path):
    meta, ops, subops = {}, {}, defaultdict(dict)
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("#"):
                for tok in line.lstrip("# ").split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        meta.setdefault(k, v)
                continue
            f = line.split()
            if not f:
                continue
            if f[0] == "OP":
                ops[int(f[1], 16)] = int(f[2])
            elif f[0] == "SUBOP":
                subops[int(f[1], 16)][int(f[2], 16)] = int(f[3])
    return meta, ops, subops


def main(paths):
    per_set = defaultdict(list)
    for p in sorted(paths):
        meta, ops, subops = parse(p)
        name = meta.get("setname", "?")
        per_set[name].append((p, meta, ops, subops))

    out = sys.stdout.write
    out("# V60 executed-opcode summary, multi-set\n")
    versions = {m.get("mame_version") for runs in per_set.values()
                for _, m, _, _ in runs}
    out(f"# mame_version={'/'.join(sorted(v for v in versions if v))}\n")
    out(f"# sets={len(per_set)}  reports={sum(len(v) for v in per_set.values())}\n\n")

    grand = defaultdict(int)
    grand_ops = 0
    invalid = []

    for name in sorted(per_set):
        runs = per_set[name]
        out(f"=== {name} ===\n")
        tot_ops = 0
        tot_hist = defaultdict(int)
        for path, meta, ops, subops in runs:
            frames = int(meta.get("emulated_frames", 0) or 0)
            retired = int(meta.get("retired_instructions", 0) or 0)
            dpc = int(meta.get("distinct_instruction_addresses", 0) or 0)
            mism = int(meta.get("rom_base_mismatches", -1))
            bad = (mism != 0) or retired == 0
            if bad:
                invalid.append((name, path, mism, retired))
            out("  run %-14s preset=%-8s seed=%-3s sec=%7.1f retired=%14d "
                "distinct_pc=%6d rom_base=%s mismatch=%d%s\n" % (
                    path.split("/")[-1].replace(".txt", ""),
                    meta.get("preset", "?"), meta.get("seed", "?"),
                    frames / 60.0, retired, dpc, meta.get("rom_base", "?"),
                    mism, "   <-- INVALID" if bad else ""))
            if not bad:
                tot_ops += retired
                for op, c in ops.items():
                    tot_hist[op] += c
                    grand[op] += c
        grand_ops += tot_ops
        out("  --- valid-run totals: retired=%d  distinct primary opcodes=%d\n"
            % (tot_ops, len(tot_hist)))
        for op in range(0x58, 0x60):
            c = tot_hist.get(op, 0)
            state = "EXECUTED %d" % c if c else "not executed"
            out("  GROUP %02x  %-38s %s\n" % (op, GROUPS[op], state))
            if c:
                subs = defaultdict(int)
                for _, _, _, so in runs:
                    for s, n in so.get(op, {}).items():
                        subs[s] += n
                for s in sorted(subs):
                    out("           subop %02x  x%d\n" % (s, subs[s]))
        out("\n")

    out("=== VERDICT (candidate groups, across all valid runs) ===\n")
    out("# total retired instructions across all valid runs: %d\n" % grand_ops)
    for op in CANDIDATES:
        c = grand.get(op, 0)
        sets_hit = [n for n in sorted(per_set)
                    if any(o.get(op) for _, _, o, _ in per_set[n])]
        if c:
            out("GROUP %02x  EXECUTED  count=%d  sets=%s\n"
                % (op, c, ",".join(sets_hit)))
        else:
            out("GROUP %02x  NOT-EXECUTED in any of %d sets\n" % (op, len(per_set)))

    if invalid:
        out("\n!!! INVALID RUNS (must not be counted as evidence) !!!\n")
        for name, path, mism, retired in invalid:
            out("  %s %s mismatch=%d retired=%d\n" % (name, path, mism, retired))
    else:
        out("\nAll runs passed the ROM-base integrity check.\n")


if __name__ == "__main__":
    args = sys.argv[1:]
    files = []
    for a in args:
        files.extend(glob.glob(a)) if any(c in a for c in "*?") else files.append(a)
    if not files:
        print(__doc__)
        sys.exit(2)
    main(files)
