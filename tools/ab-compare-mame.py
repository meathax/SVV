#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Final A/B verdict: is new-RTL closer to MAME than old-RTL?

MAME's captured output depends on which frames the Lua driver captures (see
the report), so every frame is compared against TWO independent MAME runs with
different capture lists.  A frame only counts as evidence if both runs give
the same verdict.

The credit-indicator box (x 8..48, y 68..92) is masked out: the two MAME runs
differ there by a constant 233 pixels from frame 199 onward, and the RTL uses
a different DIP setting anyway.  The bottom-right FREE PLAY / CREDIT text
(x 240..335, y 228..240) is masked for the same reason.

Usage: tools/ab-compare-mame.py <rtl_frame> [...]

See docs/DYNAGEAR_TILEMAP_PAGE_FIX_MAME_VERIFICATION.md for the method and the
results it produced.
"""
from __future__ import annotations
import sys, os

W, H = 336, 240
OFFSET = -1
MASK = [(8, 48, 68, 92), (240, 336, 228, 240)]


def load(path):
    d = open(path, "rb").read()
    pos, toks = 0, []
    while len(toks) < 4:
        while pos < len(d) and d[pos] in b" \t\r\n":
            pos += 1
        s = pos
        while pos < len(d) and d[pos] not in b" \t\r\n":
            pos += 1
        toks.append(d[s:pos])
    pos += 1
    px = d[pos:pos + W * H * 3]
    return [int.from_bytes(px[i * 3:i * 3 + 3], "big") for i in range(W * H)]


MASKED = set()
for x0, x1, y0, y1 in MASK:
    for y in range(y0, y1):
        for x in range(x0, x1):
            MASKED.add(y * W + x)


def diff(a, b):
    return sum(1 for i in range(W * H) if i not in MASKED and a[i] != b[i])


def find(d, stems, f):
    for s in stems:
        for n in (f"{s}_f{f}.ppm", f"{s}_f{f:04d}.ppm"):
            p = os.path.join(d, n)
            if os.path.exists(p):
                return p
    return None


def main():
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        os.pardir, "sim_output", "ab")
    ppm = os.path.join(base, "ppm")
    print(f"masked {len(MASKED)} px (credit indicator + FREE PLAY/CREDIT text); "
          f"MAME index = RTL frame {OFFSET:+d}\n")
    print(f"{'RTLf':>5} {'MAMEf':>5} {'run':<5} | {'old!=MAME':>9} {'new!=MAME':>9} "
          f"| {'old!=new':>8} | verdict")
    for f in sorted(int(a) for a in sys.argv[1:]):
        o = find(ppm, ["old950", "old_mid", "old_late", "old_sweep", "old_early"], f)
        n = find(ppm, ["new950", "new_mid", "new_late", "new_sweep", "new_early"], f)
        if not (o and n):
            print(f"{f:>5} MISSING RTL")
            continue
        po, pn = load(o), load(n)
        don = diff(po, pn)
        for run in ("single", "runP", "runQ"):
            m = find(os.path.join(base, run), ["m"], f + OFFSET)
            if not m:
                print(f"{f:>5} {f+OFFSET:>5} {run:<5} | MAME frame missing")
                continue
            pm = load(m)
            dom, dnm = diff(po, pm), diff(pn, pm)
            v = ("identical (fix inactive)" if don == 0 else
                 f"NEW closer by {dom - dnm}" if dnm < dom else
                 f"OLD closer by {dnm - dom}" if dnm > dom else "tie")
            print(f"{f:>5} {f+OFFSET:>5} {run:<5} | {dom:>9} {dnm:>9} "
                  f"| {don:>8} | {v}")
        print()


if __name__ == "__main__":
    main()
