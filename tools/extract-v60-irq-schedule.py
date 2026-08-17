#!/usr/bin/env python3
"""Extract zero-based interrupt-handler entry indices from a V60 state trace."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--handler-pc",
        type=lambda value: int(value, 16),
        default=0x00F11124,
    )
    args = parser.parse_args()

    state_index = 0
    entries: list[int] = []
    with args.trace.open("r", encoding="ascii", errors="replace") as stream:
        for line in stream:
            pc: int | None = None
            if line.startswith("STATE "):
                fields = line.split()
                if len(fields) >= 2:
                    pc = int(fields[1], 16)
            elif line.startswith("pc="):
                pc = int(line.split()[0].split("=", 1)[1], 16)
            elif line.startswith("HASH "):
                fields = line.split()
                if len(fields) >= 2:
                    pc = int(fields[1], 16)
            else:
                continue
            if pc == args.handler_pc:
                entries.append(state_index)
            state_index += 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as stream:
        for entry in entries:
            stream.write(f"{entry}\n")
    print(f"wrote {len(entries)} IRQ entries from {state_index} states")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
