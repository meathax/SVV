#!/usr/bin/env python3
"""Compare MAME debugger and RTL retired-PC traces at the first divergence."""

from __future__ import annotations

import argparse
import re
from collections import deque
from pathlib import Path
from typing import Iterator


MAME_PC = re.compile(r"^([0-9a-fA-F]+):")


def mame_records(path: Path) -> Iterator[tuple[int, str]]:
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            match = MAME_PC.match(line)
            if match:
                yield int(match.group(1), 16), line.rstrip()


def rtl_records(path: Path) -> Iterator[int]:
    with path.open("r", encoding="ascii") as stream:
        for line in stream:
            line = line.strip()
            if line:
                yield int(line, 16)


def seek(records: Iterator[tuple[int, str]], pc: int) -> Iterator[tuple[int, str]]:
    for record in records:
        if record[0] == pc:
            yield record
            break
    yield from records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--align", type=lambda value: int(value, 16), default=0x00F10120)
    args = parser.parse_args()

    mame = seek(mame_records(args.mame), args.align)
    rtl = iter(rtl_records(args.rtl))
    for pc in rtl:
        if pc == args.align:
            rtl = iter((pc, *rtl))
            break
    else:
        raise SystemExit(f"RTL alignment PC {args.align:08x} was not found")

    previous: deque[tuple[int, int, int, str]] = deque(maxlen=12)
    compared = 0
    for compared, (mame_record, rtl_pc) in enumerate(zip(mame, rtl), start=1):
        mame_pc, disassembly = mame_record
        if mame_pc != rtl_pc:
            print(f"DIVERGE at aligned instruction {compared - 1}")
            for index, old_mame, old_rtl, old_text in previous:
                print(f"{index:9d} M={old_mame:08x} R={old_rtl:08x}  {old_text}")
            print(f"{compared - 1:9d} M={mame_pc:08x} R={rtl_pc:08x}  {disassembly}  <==")
            return 1
        previous.append((compared - 1, mame_pc, rtl_pc, disassembly))

    print(f"PASS: {compared} aligned retired PCs match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
