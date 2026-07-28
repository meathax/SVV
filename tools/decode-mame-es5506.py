#!/usr/bin/env python3
"""Reconstruct ES5506 32-bit register transactions from an SSV MAME tap log."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import re
from pathlib import Path


BASE = 0x300000
TRACE_RE = re.compile(
    r"ES5506_(WRITE|READ)\s+\d+\s+addr=([0-9a-fA-F]+)"
    r"\s+data=([0-9a-fA-F]+)\s+mask=([0-9a-fA-F]+)"
)

LOW_NAMES = (
    "CR", "FC", "LVOL", "LVRAMP", "RVOL", "RVRAMP", "ECOUNT", "K2",
    "K2RAMP", "K1", "K1RAMP", "ACTV", "MODE", "PAR", "IRQV", "PAGE",
)
HIGH_NAMES = (
    "CR", "START", "END", "ACCUM", "O4N1", "O3N1", "O3N2", "O2N1",
    "O2N2", "O1N1", "W_ST", "W_END", "LR_END", "PAR", "IRQV", "PAGE",
)
TEST_NAMES = (
    "CH0_L", "CH0_R", "CH1_L", "CH1_R", "CH2_L", "CH2_R", "CH3_L",
    "CH3_R", "CH4_L", "CH4_R", "CH5_L", "CH5_R", "EMPTY", "PAR",
    "IRQV", "PAGE",
)


@dataclass(frozen=True)
class Transaction:
    number: int
    page: int
    register: int
    name: str
    value: int


def register_name(page: int, register: int) -> str:
    if page < 0x20:
        return LOW_NAMES[register]
    if page < 0x40:
        return HIGH_NAMES[register]
    return TEST_NAMES[register]


def decode(path: Path) -> tuple[list[Transaction], Counter[str], int, int]:
    page = 0
    latch = 0
    completed: list[Transaction] = []
    byte_writes = 0
    byte_reads = 0

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = TRACE_RE.search(line)
        if not match:
            continue

        operation, address_text, data_text, mask_text = match.groups()
        address = int(address_text, 16)
        data = int(data_text, 16)
        mask = int(mask_text, 16)
        if not BASE <= address <= BASE + 0x7F:
            continue

        # SSV connects the ES5506's 8-bit host bus to the low byte of the
        # V60's 16-bit data bus.  Consecutive ES5506 bytes are two CPU bytes
        # apart, so strip A0 before decoding HA[5:0].
        host_address = (address - BASE) >> 1
        byte_index = host_address & 3
        register = (host_address >> 2) & 0xF

        if operation == "READ":
            byte_reads += 1
            continue

        byte_writes += 1
        if not mask & 0xFF:
            continue

        shift = 24 - 8 * byte_index
        latch = (latch & ~(0xFF << shift)) | ((data & 0xFF) << shift)
        if byte_index != 3:
            continue

        name = register_name(page, register)
        completed.append(
            Transaction(len(completed) + 1, page, register, name, latch)
        )
        if register == 15:
            page = latch & 0x7F
        latch = 0

    counts = Counter(tx.name for tx in completed)
    return completed, counts, byte_writes, byte_reads


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="MAME ES5506 tap log")
    parser.add_argument(
        "--transactions", action="store_true",
        help="print every reconstructed 32-bit write",
    )
    args = parser.parse_args()

    transactions, counts, byte_writes, byte_reads = decode(args.trace)
    print(f"byte writes: {byte_writes}")
    print(f"byte reads: {byte_reads}")
    print(f"completed writes: {len(transactions)}")
    print("register counts:")
    for name, count in sorted(counts.items()):
        print(f"  {name:8s} {count}")

    voice_transactions = [
        tx for tx in transactions if tx.name != "PAGE" and tx.page < 0x40
    ]
    voices = sorted({tx.page & 0x1F for tx in voice_transactions})
    low_control = Counter(
        tx.value for tx in transactions if tx.page < 0x20 and tx.name == "CR"
    )
    high_control = Counter(
        tx.value for tx in transactions if 0x20 <= tx.page < 0x40 and tx.name == "CR"
    )
    modes = Counter(tx.value for tx in transactions if tx.name == "MODE")
    print(
        "voices used: "
        + (", ".join(str(voice) for voice in voices) if voices else "none")
    )
    print("low-page CR values:")
    for value, count in sorted(low_control.items()):
        print(f"  {value:08x} {count}")
    print("high-page CR values:")
    for value, count in sorted(high_control.items()):
        print(f"  {value:08x} {count}")
    print("MODE values:")
    for value, count in sorted(modes.items()):
        print(f"  {value:08x} {count}")

    if args.transactions:
        print("transactions:")
        for tx in transactions:
            page_kind = "low" if tx.page < 0x20 else (
                "high" if tx.page < 0x40 else "test"
            )
            print(
                f"{tx.number:04d} page={tx.page:02x} {page_kind:4s} "
                f"voice={tx.page & 0x1f:02d} {tx.name:8s}={tx.value:08x}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
