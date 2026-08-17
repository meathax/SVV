#!/usr/bin/env python3
"""Compare MAME and RTL V60 architectural-state traces.

The initial comparison is lockstep from a requested start PC.  Vblank IRQs are
asynchronous, so corresponding IRQ handlers are also compared independently
from their entry through RETIS.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class State:
    pc: int
    psw: int
    r0: int
    r1: int
    r2: int
    sp: int


def states(path: Path) -> Iterator[State]:
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line in stream:
            if not line.startswith("STATE "):
                continue
            if "\0" in line:
                return
            fields = line.split()
            if len(fields) != 7:
                raise ValueError(f"{path}: malformed STATE line: {line.rstrip()}")
            yield State(*(int(value, 16) for value in fields[1:]))


def aligned_states(path: Path, start: int) -> Iterator[State]:
    found = False
    for state in states(path):
        if not found:
            found = state.pc == start
            if not found:
                continue
        yield state
    if not found:
        raise ValueError(f"{path}: start PC {start:08x} not found")


def compare_lockstep(mame_path: Path, rtl_path: Path, start: int) -> bool:
    mame = aligned_states(mame_path, start)
    rtl = aligned_states(rtl_path, start)
    count = 0
    while True:
        try:
            m = next(mame)
            r = next(rtl)
        except StopIteration:
            print(f"LOCKSTEP END after {count} matching states")
            return True
        if m == r:
            count += 1
            continue
        if m.pc != r.pc:
            print(
                f"LOCKSTEP PC EVENT after {count} matching states: "
                f"MAME={m.pc:08x} RTL={r.pc:08x}"
            )
            return True
        labels = ("pc", "psw", "r0", "r1", "r2", "sp")
        differences = [
            f"{label}:M={getattr(m, label):08x}/R={getattr(r, label):08x}"
            for label in labels
            if getattr(m, label) != getattr(r, label)
        ]
        print(
            f"STATE DIVERGENCE instruction={count} pc={m.pc:08x} "
            + " ".join(differences)
        )
        return False


def handler_segments(
    path: Path, start: int, end: int
) -> Iterator[list[State]]:
    current: list[State] | None = None
    for state in states(path):
        if current is None:
            if state.pc == start:
                current = [state]
        else:
            current.append(state)
            if state.pc == end:
                yield current
                current = None


def compare_handlers(
    mame_path: Path, rtl_path: Path, start: int, end: int
) -> bool:
    mame = handler_segments(mame_path, start, end)
    rtl = handler_segments(rtl_path, start, end)
    count = 0
    while True:
        try:
            m_handler = next(mame)
        except StopIteration:
            print(f"HANDLERS PASS: {count} MAME handlers match RTL exactly")
            return True
        try:
            r_handler = next(rtl)
        except StopIteration:
            print(f"HANDLER DIVERGENCE: RTL ended before MAME handler {count}")
            return False
        if len(m_handler) != len(r_handler):
            print(
                f"HANDLER DIVERGENCE handler={count} length "
                f"MAME={len(m_handler)} RTL={len(r_handler)}"
            )
            return False
        for offset, (m_state, r_state) in enumerate(zip(m_handler, r_handler)):
            if m_state != r_state:
                labels = ("pc", "psw", "r0", "r1", "r2", "sp")
                differences = [
                    f"{label}:M={getattr(m_state, label):08x}"
                    f"/R={getattr(r_state, label):08x}"
                    for label in labels
                    if getattr(m_state, label) != getattr(r_state, label)
                ]
                print(
                    f"HANDLER STATE DIVERGENCE handler={count} "
                    f"offset={offset} " + " ".join(differences)
                )
                return False
        print(f"HANDLER PASS index={count} states={len(m_handler)}")
        count += 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument(
        "--start", type=lambda value: int(value, 16), default=0x00F10120
    )
    parser.add_argument(
        "--handler-start",
        type=lambda value: int(value, 16),
        default=0x00F11124,
    )
    parser.add_argument(
        "--handler-end",
        type=lambda value: int(value, 16),
        default=0x00F11335,
    )
    args = parser.parse_args()

    lockstep_ok = compare_lockstep(args.mame, args.rtl, args.start)
    handlers_ok = compare_handlers(
        args.mame, args.rtl, args.handler_start, args.handler_end
    )
    return 0 if lockstep_ok and handlers_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
