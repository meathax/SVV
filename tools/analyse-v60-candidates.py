#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Vote on whether each static candidate site is really an instruction boundary.

Input: several full-ROM linear disassemblies produced by MAME's debugger
`dasm` command started at different byte alignments (see
sim_output/mame/dasm_full.lua), plus the static candidate list from
tools/scan-v60-opcode-sites.py, plus optionally the union of instruction
addresses actually executed (V60_PCLIST files).

Why votes: a variable-length decoder is self-synchronising, so linear
disassemblies started at different offsets converge within a few
instructions.  An address on the converged stream is decoded as an
instruction start by every alignment; an address that is an operand byte of
some other instruction is decoded as a start by none of them.

What this can and cannot conclude:
  * 0 votes  -> no linear decoding of the surrounding bytes ever treats this
                offset as an instruction start.  Strong evidence it is an
                operand or table byte, not code.
  * N votes  -> the byte lies on the converged stream.  That is NOT evidence
                it is real code: linear decoding of a pure data region also
                produces a converged stream of nonsense.  Unresolved.

Usage:
  analyse-v60-candidates.py --rom sim_output/rom/maincpu.bin \\
      --dasm /tmp/dasm/align*.txt [--pclist f1.pclist f2.pclist ...]
"""
import argparse
import glob
import re
import sys
from collections import defaultdict

ROM_BASE = 0xF00000

GROUPS = {
    0x59: ("decimal (BCD)", {0x00, 0x01, 0x02, 0x10, 0x18}),
    0x5B: ("bit string", {0x00, 0x02, 0x08, 0x09}),
    0x5D: ("bit field", {0x08, 0x09, 0x0A, 0x18, 0x19}),
    0x5C: ("floating point", {0x00, 0x08, 0x09, 0x0A, 0x10, 0x18, 0x19, 0x1A, 0x1B}),
    0x5F: ("floating point convert", {0x00, 0x01}),
    0x58: ("byte string (implemented)",
           {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x18, 0x19, 0x1A, 0x1B}),
    0x5A: ("half string (implemented)",
           {0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x18, 0x19, 0x1A, 0x1B}),
}

LINE = re.compile(r"^([0-9A-Fa-f]{6,8}):\s+((?:[0-9A-Fa-f]{2} )+)\s+(\S+)")


def load_dasm(path):
    starts = {}
    lengths = {}
    with open(path, errors="replace") as fh:
        for line in fh:
            m = LINE.match(line)
            if m:
                a = int(m.group(1), 16)
                starts[a] = m.group(3).lower()
                lengths[a] = len(m.group(2).split())
    return starts, lengths


BLOCK = 0x1000


def block_stats(starts, lengths):
    """Per-4KB code/data heuristic.

    Real V60 code decodes to few, long instructions with recognised
    mnemonics.  A data region decodes to many short instructions and a high
    proportion of `$xx` illegal-opcode placeholders.  This is a heuristic
    label, not a proof - it is reported so a candidate site can be judged
    against the character of the region it sits in.
    """
    stats = {}
    for a, mn in starts.items():
        b = (a - ROM_BASE) // BLOCK
        s = stats.setdefault(b, [0, 0, 0])
        s[0] += 1
        s[1] += lengths.get(a, 1)
        if mn.startswith("$"):
            s[2] += 1
    out = {}
    for b, (n, tot, bad) in stats.items():
        out[b] = (n, tot / n if n else 0.0, bad / n if n else 0.0)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rom", required=True)
    ap.add_argument("--dasm", nargs="+", required=True)
    ap.add_argument("--pclist", nargs="*", default=[])
    args = ap.parse_args()

    with open(args.rom, "rb") as fh:
        rom = fh.read()

    paths = []
    for p in args.dasm:
        paths.extend(sorted(glob.glob(p)) or [p])
    streams = []
    stats = None
    for p in paths:
        st, ln = load_dasm(p)
        if stats is None:
            stats = block_stats(st, ln)
        streams.append(st)
        print("# loaded %s: %d instruction boundaries" % (p, len(st)))
    nalign = len(streams)

    executed = set()
    for p in args.pclist:
        for q in sorted(glob.glob(p)) or [p]:
            with open(q) as fh:
                for line in fh:
                    line = line.strip()
                    if line:
                        executed.add(int(line, 16))
    if executed:
        print("# executed instruction addresses (union): %d  span %06x..%06x"
              % (len(executed), min(executed), max(executed)))
    print("#")

    for op in sorted(GROUPS):
        label, subs = GROUPS[op]
        cands = [o for o in range(len(rom) - 1)
                 if rom[o] == op and (rom[o + 1] & 0x1F) in subs]
        votes = defaultdict(list)
        for o in cands:
            addr = ROM_BASE + o
            v = sum(1 for s in streams if addr in s)
            votes[v].append(addr)
        zero = votes.get(0, [])
        full = votes.get(nalign, [])
        other = sum(len(v) for k, v in votes.items() if k not in (0, nalign))
        print("CAND %02x  %-26s total=%-5d zero_votes=%-5d full_votes=%-5d "
              "partial=%d" % (op, label, len(cands), len(zero), len(full), other))
        # Report every site that any alignment thinks is an instruction.
        live = sorted(set(full) | set(
            a for k, v in votes.items() if k not in (0,) for a in v))
        if live:
            for a in live:
                mn = ""
                for s in streams:
                    if a in s:
                        mn = s[a]
                        break
                ex = " EXECUTED" if a in executed else ""
                b = (a - ROM_BASE) // BLOCK
                n, avglen, badfrac = stats.get(b, (0, 0.0, 0.0))
                # How much real code did we ever run in this 4 KB block?
                nexec = sum(1 for e in executed
                            if (e - ROM_BASE) // BLOCK == b) if executed else -1
                print("CAND %02x    boundary %06x sub=%02x mnem=%-10s votes=%d "
                      "blk=%03x avglen=%.1f illegal=%.0f%% exec_in_blk=%d%s"
                      % (op, a, rom[a - ROM_BASE + 1], mn,
                         sum(1 for s in streams if a in s),
                         b, avglen, badfrac * 100, nexec, ex))
        print("#")

    # Cross-check: what does MAME's own disassembler call these groups, and
    # where does the align-0 stream place them?
    print("# ---- mnemonics MAME's v60 disassembler emitted for 0x58..0x5F ----")
    seen = defaultdict(int)
    s0 = streams[0]
    for addr, mn in s0.items():
        o = addr - ROM_BASE
        if 0 <= o < len(rom) and 0x58 <= rom[o] <= 0x5F:
            seen[(rom[o], mn)] += 1
    for (op, mn), n in sorted(seen.items()):
        print("DASM_MNEM %02x %-12s %d" % (op, mn, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
