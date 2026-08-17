#!/usr/bin/env python3
"""Strictly compare low-volume MAME/RTL V60 register-change streams."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path


MAME = re.compile(
    r"^SSVREGCHANGE cursor=(?P<cursor>\d+) pc=(?P<pc>[0-9A-F]+) "
    r"opcode=(?P<opcode>[0-9A-F]+) psw=(?P<psw>[0-9A-F]+) "
    r"beamx=(?P<beamx>\d+) beamy=(?P<beamy>\d+) .*"
    r"old_r2=(?P<old_r2>[0-9A-F]+) new_r2=(?P<new_r2>[0-9A-F]+) "
    r"old_r23=(?P<old_r23>[0-9A-F]+) new_r23=(?P<new_r23>[0-9A-F]+)$"
)


@dataclass(frozen=True)
class Change:
    pc: int
    opcode: int
    psw: int
    old_r2: int
    new_r2: int
    old_r23: int
    new_r23: int


@dataclass(frozen=True)
class LocatedChange:
    change: Change
    frame: int | None
    post_epoch_frame: int | None
    cycle: int | None
    scanline: int | None
    hpos: int | None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def mame_changes(path: Path) -> list[LocatedChange]:
    result: list[LocatedChange] = []
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line in stream:
            match = MAME.match(line.rstrip())
            if not match:
                continue
            values = match.groupdict()
            result.append(LocatedChange(
                Change(*(int(values[name], 16) for name in (
                    "pc", "opcode", "psw", "old_r2", "new_r2",
                    "old_r23", "new_r23"
                ))),
                None,
                int(values["cursor"]),
                None,
                int(values["beamy"]),
                int(values["beamx"]),
            ))
    return result


def rtl_changes(path: Path) -> tuple[list[LocatedChange], dict[str, object]]:
    result: list[LocatedChange] = []
    receipt: dict[str, object] | None = None
    with path.open("r", encoding="ascii", errors="strict") as stream:
        for line_number, line in enumerate(stream, 1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if record.get("record") == "receipt":
                receipt = record
                continue
            if record.get("domain") != "v60_reg_change" or record.get("first"):
                continue
            result.append(LocatedChange(
                Change(*(int(record[name]) for name in (
                    "pc", "opcode", "psw", "old_r2", "new_r2",
                    "old_r23", "new_r23"
                ))),
                int(record["frame"]),
                (int(record["post_epoch_frame"])
                 if "post_epoch_frame" in record else None),
                int(record["cycle"]),
                int(record["scanline"]),
                (int(record["hpos"]) if "hpos" in record else None),
            ))
    if receipt is None or receipt.get("complete") is not True:
        raise ValueError(f"{path}: missing complete register-trace receipt")
    if receipt.get("dropped") != 0:
        raise ValueError(f"{path}: dropped={receipt.get('dropped')}")
    reported = receipt.get("count")
    # The receipt counts the initial state record, which comparison excludes.
    if not isinstance(reported, int) or reported != len(result) + 1:
        raise ValueError(
            f"{path}: receipt count {reported!r} != records {len(result) + 1}"
        )
    return result, receipt


def located_json(item: LocatedChange | None) -> dict[str, object] | None:
    if item is None:
        return None
    return {
        "change": asdict(item.change),
        "frame": item.frame,
        "post_epoch_frame": item.post_epoch_frame,
        "cycle": item.cycle,
        "scanline": item.scanline,
        "hpos": item.hpos,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    left = mame_changes(args.mame)
    right, _ = rtl_changes(args.rtl)
    common = min(len(left), len(right))
    mismatch = next(
        (index for index in range(common) if left[index].change != right[index].change),
        None,
    )
    if mismatch is None and len(left) == len(right):
        verdict = "match"
        index = common
        left_bad = None
        right_bad = None
    else:
        verdict = "divergence"
        index = mismatch if mismatch is not None else common
        left_bad = left[index] if index < len(left) else None
        right_bad = right[index] if index < len(right) else None
    result = {
        "schema": "ssv-v60-register-change-compare-v1",
        "verdict": verdict,
        "matching_prefix": index,
        "mame_records": len(left),
        "rtl_records": len(right),
        "mame_last_good": located_json(left[index - 1] if index else None),
        "rtl_last_good": located_json(right[index - 1] if index else None),
        "mame_first_bad": located_json(left_bad),
        "rtl_first_bad": located_json(right_bad),
        "mame_trace": str(args.mame.resolve()),
        "mame_sha256": file_sha256(args.mame),
        "rtl_trace": str(args.rtl.resolve()),
        "rtl_sha256": file_sha256(args.rtl),
        "resynchronized": False,
    }
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if verdict == "match" else 1


if __name__ == "__main__":
    raise SystemExit(main())
