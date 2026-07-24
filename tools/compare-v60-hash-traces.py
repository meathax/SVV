#!/usr/bin/env python3
"""Compare compact complete-state hashes from MAME and RTL."""

from __future__ import annotations

import argparse
from collections.abc import Iterator
from pathlib import Path


def records(path: Path) -> Iterator[tuple[int, int]]:
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line in stream:
            if not line.startswith("HASH "):
                continue
            _, pc, state_hash = line.split()
            yield int(pc, 16), int(state_hash, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    args = parser.parse_args()

    mame = records(args.mame)
    rtl = records(args.rtl)
    try:
        m_record = next(mame)
        r_record = next(rtl)
    except StopIteration:
        print("ERROR: one or both traces contain no hash records")
        return 2

    skipped = 0
    while r_record[0] != m_record[0] and skipped < 16:
        r_record = next(rtl)
        skipped += 1
    if r_record[0] != m_record[0]:
        print(
            f"ERROR: could not align RTL to first MAME PC {m_record[0]:08x} "
            f"within 16 records"
        )
        return 2
    if skipped:
        print(f"aligned traces after skipping {skipped} RTL startup record(s)")

    count = 0
    while True:
        if m_record != r_record:
            print(
                f"DIVERGE state={count} "
                f"MAME=({m_record[0]:08x},{m_record[1]:016x}) "
                f"RTL=({r_record[0]:08x},{r_record[1]:016x})"
            )
            return 1
        count += 1
        try:
            m_record = next(mame)
        except StopIteration:
            print(f"PASS: all {count} MAME complete-state hashes match RTL")
            return 0
        try:
            r_record = next(rtl)
        except StopIteration:
            print(f"PASS: {count} available RTL complete-state hashes match MAME")
            return 0


if __name__ == "__main__":
    raise SystemExit(main())
