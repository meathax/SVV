#!/usr/bin/env python3
"""Compare genuine MAME V60 debugger hooks with RTL retire boundaries."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterator


MAME_RECORD = re.compile(r"^SSVREG cursor=(\d+) ")
MAME_FIELD = re.compile(r"([a-z0-9]+)=([0-9A-Fa-f]+)")


@dataclass(frozen=True)
class Boundary:
    pc: int
    opcode: int
    psw: int
    registers: tuple[int, ...]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def mame_boundaries(path: Path, cursor: int) -> Iterator[Boundary]:
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            match = MAME_RECORD.match(line)
            if not match or int(match.group(1)) != cursor:
                continue
            fields = {name: int(value, 16) for name, value in MAME_FIELD.findall(line)}
            required = {"pc", "opcode", "psw", "ap", "fp", "sp"}
            required.update(f"r{index}" for index in range(29))
            missing = sorted(required.difference(fields))
            if missing:
                raise ValueError(f"{path}:{line_number}: missing fields {missing}")
            registers = tuple(fields[f"r{index}"] for index in range(29)) + (
                fields["ap"], fields["fp"], fields["sp"]
            )
            yield Boundary(fields["pc"], fields["opcode"], fields["psw"], registers)


def rtl_boundaries(
    path: Path, *, frame: int | None, post_epoch_frame: int | None
) -> Iterator[Boundary]:
    if (frame is None) == (post_epoch_frame is None):
        raise ValueError("select exactly one RTL frame domain")
    with path.open("r", encoding="ascii", errors="strict") as stream:
        for line_number, line in enumerate(stream, 1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if record.get("domain") != "v60_retire":
                continue
            if frame is not None and record.get("frame") != frame:
                continue
            if post_epoch_frame is not None:
                if "post_epoch_frame" not in record:
                    raise ValueError(
                        f"{path}:{line_number}: trace lacks post_epoch_frame; use --rtl-frame"
                    )
                if record["post_epoch_frame"] != post_epoch_frame:
                    continue
            try:
                registers = tuple(int(record[f"r{index}"]) for index in range(32))
                yield Boundary(
                    int(record["pc"]), int(record["opcode"]),
                    int(record["psw"]), registers
                )
            except KeyError as exc:
                raise ValueError(f"{path}:{line_number}: missing {exc.args[0]}") from exc


def aligned(
    states: Iterator[Boundary], start_pc: int, source: str,
    *, start_r2: int | None = None, start_r16: int | None = None,
) -> Iterator[Boundary]:
    for state in states:
        if state.pc != start_pc:
            continue
        if start_r2 is not None and state.registers[2] != start_r2:
            continue
        if start_r16 is not None and state.registers[16] != start_r16:
            continue
        yield state
        yield from states
        return
    predicates = [f"PC={start_pc:08X}"]
    if start_r2 is not None:
        predicates.append(f"R2={start_r2:08X}")
    if start_r16 is not None:
        predicates.append(f"R16={start_r16:08X}")
    raise ValueError(f"{source}: start state ({', '.join(predicates)}) not found")


def state_json(state: Boundary | None) -> dict[str, object] | None:
    if state is None:
        return None
    result = asdict(state)
    result["registers"] = list(state.registers)
    return result


def differing_fields(mame: Boundary, rtl: Boundary) -> list[str]:
    fields: list[str] = []
    for name in ("pc", "opcode", "psw"):
        if getattr(mame, name) != getattr(rtl, name):
            fields.append(name)
    for index, (left, right) in enumerate(zip(mame.registers, rtl.registers)):
        if left != right:
            fields.append(f"r{index}")
    return fields


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--mame-cursor", required=True, type=int)
    rtl_group = parser.add_mutually_exclusive_group(required=True)
    rtl_group.add_argument("--rtl-frame", type=int)
    rtl_group.add_argument("--rtl-post-epoch-frame", type=int)
    parser.add_argument("--start-pc", default="F11124", type=lambda text: int(text, 16))
    parser.add_argument("--start-r2", type=lambda text: int(text, 16))
    parser.add_argument("--start-r16", type=lambda text: int(text, 16))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    mame = aligned(
        mame_boundaries(args.mame, args.mame_cursor), args.start_pc, "MAME",
        start_r2=args.start_r2, start_r16=args.start_r16,
    )
    rtl = aligned(
        rtl_boundaries(
            args.rtl, frame=args.rtl_frame,
            post_epoch_frame=args.rtl_post_epoch_frame
        ),
        args.start_pc,
        "RTL", start_r2=args.start_r2, start_r16=args.start_r16,
    )
    matched = 0
    last_good: Boundary | None = None
    mame_bad: Boundary | None = None
    rtl_bad: Boundary | None = None
    while True:
        try:
            mame_state = next(mame)
        except StopIteration:
            try:
                rtl_bad = next(rtl)
            except StopIteration:
                pass
            break
        try:
            rtl_state = next(rtl)
        except StopIteration:
            mame_bad = mame_state
            break
        if mame_state != rtl_state:
            mame_bad = mame_state
            rtl_bad = rtl_state
            break
        last_good = mame_state
        matched += 1

    differences = (
        differing_fields(mame_bad, rtl_bad)
        if mame_bad is not None and rtl_bad is not None else ["trace_length"]
    )
    verdict = "match" if mame_bad is None and rtl_bad is None else "divergence"
    result = {
        "schema": "ssv-v60-instruction-compare-v1",
        "verdict": verdict,
        "matching_prefix": matched,
        "start_pc": args.start_pc,
        "start_r2": args.start_r2,
        "start_r16": args.start_r16,
        "mame_cursor": args.mame_cursor,
        "rtl_frame": args.rtl_frame,
        "rtl_post_epoch_frame": args.rtl_post_epoch_frame,
        "differing_fields": differences,
        "last_good": state_json(last_good),
        "mame_first_bad": state_json(mame_bad),
        "rtl_first_bad": state_json(rtl_bad),
        "mame_trace": str(args.mame.resolve()),
        "mame_sha256": sha256(args.mame),
        "rtl_trace": str(args.rtl.resolve()),
        "rtl_sha256": sha256(args.rtl),
    }
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if verdict == "match" else 1


if __name__ == "__main__":
    raise SystemExit(main())
