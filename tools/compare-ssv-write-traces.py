#!/usr/bin/env python3
"""Compare ordered 16-bit SSV bus writes captured from MAME and RTL."""

from __future__ import annotations

import argparse
from collections.abc import Iterator
from pathlib import Path

Write = tuple[int, int, int]


def records(path: Path) -> Iterator[Write]:
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line in stream:
            fields = line.split()
            if not fields or fields[0] != "WRITE":
                continue
            if len(fields) == 5:
                _, _sequence, address, data, mask = fields
            elif len(fields) == 4:
                _, address, data, mask = fields
            else:
                raise ValueError(f"bad write trace line: {line.rstrip()}")
            yield int(address, 16), int(data, 16), int(mask, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    args = parser.parse_args()

    count = 0
    mame = records(args.mame)
    rtl = records(args.rtl)
    while True:
        try:
            m_record = next(mame)
        except StopIteration:
            print(f"PASS: all {count} MAME writes match RTL")
            return 0
        try:
            r_record = next(rtl)
        except StopIteration:
            print(f"PASS: {count} available RTL writes match MAME")
            return 0
        if m_record != r_record:
            print(
                f"DIVERGE write={count} "
                f"MAME=(addr={m_record[0]:08x},data={m_record[1]:04x},"
                f"mask={m_record[2]:04x}) "
                f"RTL=(addr={r_record[0]:08x},data={r_record[1]:04x},"
                f"mask={r_record[2]:04x})"
            )
            return 1
        count += 1


if __name__ == "__main__":
    raise SystemExit(main())
