#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Static bound on where the partially-implemented V60 groups *could* live.

The dynamic MAME histogram (tools/mame-v60-opcode-histogram.lua) can only prove
that an opcode *was* executed.  It can never prove absence beyond the code it
covered.  This script provides the complementary static bound: every offset in
the Dyna Gear program ROM that could possibly be the first byte of one of the
partially-implemented two-byte groups.

A site is a candidate only if:
  * ROM[o]   == the group's primary opcode byte, and
  * ROM[o+1] has low five bits inside that group's implemented sub-opcode set
    (taken verbatim from rtl/cpu/v60/s32_v60.sv - anything outside those sets
    already takes the reserved-instruction exception in the current RTL, so
    gating cannot make it worse).

This is an upper bound, not a disassembly: most candidates will be operand or
table bytes.  It is useful in exactly one direction - a group with zero
candidates cannot be executed by any path, reached or not.

Usage: scan-v60-opcode-sites.py <maincpu.bin> [covered_pc_list]

The program-ROM base defaults to Dyna Gear's 0xF00000.  ssv_map() maps the
maincpu region as `map(rom, 0xffffff)`, so for any other SSV set the base is
`0x1000000 - len(rom)`; pass --base=auto to derive it that way, or
--base=<hex> to set it explicitly.  The base only shifts the printed site
addresses -- the candidate *counts* are base-independent.
"""
import sys
from collections import Counter

ROM_BASE = 0xF00000

# Sub-opcode sets are the *implemented* low-5-bit values in
# rtl/cpu/v60/s32_v60.sv (lines ~1046-1145) and fp_valid() (line ~4029).
GROUPS = {
    0x59: ("decimal (BCD)  ADDDC/SUBDC/SUBRDC/CVTDPZ/CVTDZP",
           {0x00, 0x01, 0x02, 0x10, 0x18}),
    0x5B: ("bit string     SCH0BSU/SCH1BSU/MOVBSU/MOVBSD",
           {0x00, 0x02, 0x08, 0x09}),
    0x5D: ("bit field      EXTBFS/EXTBFZ/EXTBFL/INSBFR/INSBFL",
           {0x08, 0x09, 0x0A, 0x18, 0x19}),
    0x5C: ("float          CMPF/MOVFS/NEGFS/ABSFS/SCLFS/ADDFS/SUBFS/MULFS/DIVFS",
           {0x00, 0x08, 0x09, 0x0A, 0x10, 0x18, 0x19, 0x1A, 0x1B}),
    0x5F: ("float convert  CVTWS/CVTSW",
           {0x00, 0x01}),
}
# Reference groups that are fully implemented, printed for scale comparison.
REFERENCE = {
    0x58: ("byte string (implemented)",
           {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x18, 0x19, 0x1A, 0x1B}),
    0x5A: ("half string (implemented)",
           {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x18, 0x19, 0x1A, 0x1B}),
}


def scan(rom, table):
    out = {}
    for op, (label, subs) in sorted(table.items()):
        raw = 0
        cand = []
        for o in range(len(rom) - 1):
            if rom[o] != op:
                continue
            raw += 1
            if (rom[o + 1] & 0x1F) in subs:
                cand.append(o)
        out[op] = (label, raw, cand)
    return out


def main(argv):
    global ROM_BASE
    argv = list(argv)
    base_arg = None
    for a in list(argv[1:]):
        if a.startswith("--base="):
            base_arg = a.split("=", 1)[1]
            argv.remove(a)

    rom_path = argv[1]
    with open(rom_path, "rb") as fh:
        rom = fh.read()

    if base_arg == "auto":
        ROM_BASE = 0x1000000 - len(rom)
    elif base_arg is not None:
        ROM_BASE = int(base_arg, 16)

    covered = set()
    if len(argv) > 2:
        with open(argv[2]) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    covered.add(int(line, 16))

    print("# Static candidate-site bound for the partial V60 groups")
    print("# rom=%s size=%d base=%06x" % (rom_path, len(rom), ROM_BASE))
    print("# 'raw' = byte occurrences anywhere; 'cand' = raw occurrences whose")
    print("# following byte is an implemented sub-opcode for that group.")
    print("#")

    for table, title in ((GROUPS, "PARTIAL GROUPS"), (REFERENCE, "REFERENCE")):
        print("# ---- %s ----" % title)
        res = scan(rom, table)
        for op, (label, raw, cand) in sorted(res.items()):
            print("SCAN %02x raw=%-6d cand=%-6d  %s" % (op, raw, len(cand), label))
            if cand and len(cand) <= 64:
                for o in cand:
                    mark = ""
                    if covered and (ROM_BASE + o) in covered:
                        mark = "  <-- EXECUTED"
                    print("SCAN %02x   site %06x sub=%02x%s"
                          % (op, ROM_BASE + o, rom[o + 1], mark))
            elif cand:
                dist = Counter(rom[o + 1] & 0x1F for o in cand)
                print("SCAN %02x   (too many to list; sub histogram: %s)"
                      % (op, " ".join("%02x:%d" % kv for kv in sorted(dist.items()))))
        print("#")

    if covered:
        print("# covered instruction addresses supplied: %d" % len(covered))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv))
