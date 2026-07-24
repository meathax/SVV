#!/usr/bin/env python3
"""Compare corresponding SSV vblank-handler PC sequences, ignoring IRQ timing."""

from __future__ import annotations

import argparse
from pathlib import Path

from compare_v60_pc_traces import load_mame_pcs, load_rtl_pcs


def segments(pcs: list[int], start: int, end: int) -> list[list[int]]:
    result: list[list[int]] = []
    current: list[int] | None = None
    for pc in pcs:
        if current is None:
            if pc == start:
                current = [pc]
        else:
            current.append(pc)
            if pc == end:
                result.append(current)
                current = None
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--start", type=lambda value: int(value, 16), default=0x00F11124)
    parser.add_argument("--end", type=lambda value: int(value, 16), default=0x00F11335)
    args = parser.parse_args()

    mame_segments = segments(load_mame_pcs(args.mame), args.start, args.end)
    rtl_segments = segments(load_rtl_pcs(args.rtl), args.start, args.end)
    count = min(len(mame_segments), len(rtl_segments))
    for index in range(count):
        mame = mame_segments[index]
        rtl = rtl_segments[index]
        limit = min(len(mame), len(rtl))
        for offset in range(limit):
            if mame[offset] != rtl[offset]:
                print(
                    f"DIVERGE handler={index} offset={offset} "
                    f"M={mame[offset]:08x} R={rtl[offset]:08x}"
                )
                return 1
        if len(mame) != len(rtl):
            print(
                f"DIVERGE handler={index} length "
                f"M={len(mame)} R={len(rtl)}"
            )
            return 1
        print(f"PASS handler={index} instructions={len(mame)}")
    print(
        f"PASS: {count} corresponding handlers match "
        f"(MAME={len(mame_segments)} RTL={len(rtl_segments)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
