#!/usr/bin/env python3
"""Compare per-frame SSV palette-index and RGB CRC streams from MAME and RTL."""

from __future__ import annotations

import argparse
from collections.abc import Iterator
from pathlib import Path

Frame = tuple[int, int, int]


def records(path: Path) -> Iterator[Frame]:
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line in stream:
            fields = line.split()
            if not fields or fields[0] != "FRAME":
                continue
            if len(fields) != 4:
                raise ValueError(f"bad frame CRC line: {line.rstrip()}")
            _, frame, idx_crc, rgb_crc = fields
            yield int(frame, 0), int(idx_crc, 16), int(rgb_crc, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument(
        "--max-frames",
        type=int,
        default=0,
        help="Stop after N compared frames (0 = all)",
    )
    parser.add_argument(
        "--rgb-only",
        action="store_true",
        help="Ignore palette-index CRC mismatches",
    )
    parser.add_argument(
        "--skip",
        type=int,
        default=0,
        help="Skip the first N frame records on both sides",
    )
    parser.add_argument(
        "--min-frames",
        type=int,
        default=0,
        help="Fail unless at least N frames were actually compared "
        "(0 = derive from --max-frames, or 1)",
    )
    args = parser.parse_args()

    # A stream that ends early used to print PASS and exit 0, so an empty or
    # truncated MAME capture passed the gate silently -- and the gameplay gate
    # invokes this with --max-frames 1, where "no frames at all" is exactly the
    # case that looked like success. Compare-nothing is now a failure: running
    # out of records before `required` is reached is TRUNCATED, not PASS.
    required = args.min_frames or args.max_frames or 1

    count = 0
    skipped = 0
    mame = records(args.mame)
    rtl = records(args.rtl)
    while True:
        if args.max_frames and count >= args.max_frames:
            print(f"PASS: first {count} compared frames match (skipped {skipped})")
            return 0
        try:
            m_record = next(mame)
        except StopIteration:
            if count < required:
                print(
                    f"TRUNCATED {args.mame}: compared {count} frames, "
                    f"need {required} (skipped {skipped})"
                )
                return 1
            print(f"PASS: all {count} MAME frames match RTL (skipped {skipped})")
            return 0
        try:
            r_record = next(rtl)
        except StopIteration:
            if count < required:
                print(
                    f"TRUNCATED {args.rtl}: compared {count} frames, "
                    f"need {required} (skipped {skipped})"
                )
                return 1
            print(f"PASS: {count} available RTL frames match MAME (skipped {skipped})")
            return 0

        if skipped < args.skip:
            skipped += 1
            continue

        m_frame, m_idx, m_rgb = m_record
        r_frame, r_idx, r_rgb = r_record
        if m_frame != r_frame:
            print(
                f"DIVERGE frame_index count={count} "
                f"MAME={m_frame} RTL={r_frame}"
            )
            return 1
        if (not args.rgb_only) and m_idx != r_idx:
            print(
                f"DIVERGE IDX frame={m_frame} "
                f"MAME={m_idx:08x} RTL={r_idx:08x}"
            )
            return 1
        if m_rgb != r_rgb:
            print(
                f"DIVERGE RGB frame={m_frame} "
                f"MAME={m_rgb:08x} RTL={r_rgb:08x}"
            )
            return 1
        count += 1


if __name__ == "__main__":
    raise SystemExit(main())
