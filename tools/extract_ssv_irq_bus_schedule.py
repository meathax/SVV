#!/usr/bin/env python3
"""Extract MAME IRQ-handler bus-event indices from an SSV JSONL trace."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pc", type=lambda value: int(value, 0), default=0x00F010D4)
    parser.add_argument("--address", type=lambda value: int(value, 0), default=0x240030)
    parser.add_argument("--start-index", type=int, default=0)
    args = parser.parse_args()

    targets: list[int] = []
    with args.trace.open("r", encoding="utf-8") as stream:
        for index, line in enumerate(stream):
            event = json.loads(line)
            if (index >= args.start_index and
                    event.get("pc") == args.pc and
                    event.get("address") == args.address):
                targets.append(index)

    if not targets:
        raise SystemExit("no matching IRQ handler events found")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as stream:
        for target in targets:
            stream.write(f"{target}\n")
    print(f"wrote {len(targets)} IRQ bus-event targets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
