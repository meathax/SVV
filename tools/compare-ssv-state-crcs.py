#!/usr/bin/env python3
"""Compare MAME/RTL SSV per-frame memory-state CRC summaries."""

import argparse
import re
from pathlib import Path

LINE = re.compile(
    r"^STATE\s+(\d+)\s+list512=([0-9a-fA-F]{8})\s+"
    r"spr8k=([0-9a-fA-F]{8})\s+scroll64=([0-9a-fA-F]{8})\s+"
    r"pal512=([0-9a-fA-F]{8})$"
)
FIELDS = ("list512", "spr8k", "scroll64", "pal512")


def load(path: Path):
    states = {}
    for lineno, text in enumerate(path.read_text().splitlines(), 1):
        if not text.strip():
            continue
        match = LINE.match(text.strip())
        if not match:
            raise SystemExit(f"{path}:{lineno}: malformed state line: {text}")
        frame = int(match.group(1))
        states[frame] = tuple(int(value, 16) for value in match.groups()[1:])
    return states


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-frames", type=int)
    parser.add_argument(
        "--ignore-field",
        action="append",
        choices=FIELDS,
        default=[],
        help="exclude a known non-comparable field (repeatable)",
    )
    args = parser.parse_args()
    reference = load(args.reference)
    candidate = load(args.candidate)
    frames = sorted(set(reference) & set(candidate))
    if args.max_frames is not None:
        frames = [frame for frame in frames if frame < args.max_frames]
    if not frames:
        raise SystemExit("no common frames")
    for frame in frames:
        diffs = [
                f"{name}:ref={reference[frame][index]:08x},rtl={candidate[frame][index]:08x}"
                for index, name in enumerate(FIELDS)
                if name not in args.ignore_field and
                reference[frame][index] != candidate[frame][index]
            ]
        if diffs:
            raise SystemExit(f"STATE_DIVERGENCE frame={frame} " + " ".join(diffs))
    print(f"STATE_MATCH frames={len(frames)} first={frames[0]} last={frames[-1]}")


if __name__ == "__main__":
    main()
