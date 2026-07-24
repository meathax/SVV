#!/usr/bin/env python3
"""Convert MAME tracesym V60 state records to compact full-state hashes."""

from __future__ import annotations

import argparse
from pathlib import Path


FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x00000100000001B3
MASK64 = 0xFFFFFFFFFFFFFFFF
REGISTERS = [f"r{i}" for i in range(29)] + ["ap", "fp", "sp"]


def update_hash(value: int, word: int) -> int:
    return ((value ^ word) * FNV_PRIME) & MASK64


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame_trace", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    count = 0
    with (
        args.mame_trace.open("r", encoding="ascii", errors="replace") as source,
        args.output.open("w", encoding="ascii", newline="\n") as output,
    ):
        for line in source:
            if not line.startswith("pc="):
                continue
            values: dict[str, int] = {}
            for field in line.split():
                if "=" not in field:
                    break
                name, encoded = field.split("=", 1)
                values[name.lower()] = int(encoded, 16)
            required = ["pc", "psw", *REGISTERS]
            missing = [name for name in required if name not in values]
            if missing:
                raise ValueError(f"missing fields {missing} at state {count}")
            state_hash = update_hash(FNV_OFFSET, values["psw"])
            for register in REGISTERS:
                state_hash = update_hash(state_hash, values[register])
            output.write(f"HASH {values['pc']:08x} {state_hash:016x}\n")
            count += 1
    print(f"hashed {count} complete MAME V60 states")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
