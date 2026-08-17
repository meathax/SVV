#!/usr/bin/env python3
"""Compare MAME barrier RGB CRCs with the headless RTL FRAME stream.

The MAME adapter stores native RGB CRCs as decimal fields in frame-complete
barriers.  The RTL bench stores the same CRC as the fourth token of each
``FRAME`` line.  This comparator deliberately compares only the declared
native-RGB contract and never resynchronises either stream.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Iterable


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def mame_frames(path: Path) -> list[tuple[int, int]]:
    frames: list[tuple[int, int]] = []
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
            if record.get("record") != "barrier" or record.get("name") != "frame_complete":
                continue
            if "post_epoch_frame" not in record or "frame_crc32" not in record:
                raise ValueError(f"{path}:{line_number}: incomplete frame barrier")
            frames.append((int(record["post_epoch_frame"]), int(record["frame_crc32"])))
    return frames


def rtl_frames(path: Path) -> list[tuple[int, int]]:
    frames: list[tuple[int, int]] = []
    with path.open("r", encoding="ascii", errors="replace") as stream:
        for line_number, line in enumerate(stream, 1):
            fields = line.split()
            if not fields:
                continue
            if fields[0] != "FRAME":
                continue
            if len(fields) != 4:
                raise ValueError(f"{path}:{line_number}: malformed FRAME record")
            try:
                frames.append((int(fields[1], 0), int(fields[3], 16)))
            except ValueError as error:
                raise ValueError(f"{path}:{line_number}: malformed FRAME value") from error
    return frames


def window(records: Iterable[tuple[int, int]], start: int, stop: int) -> list[tuple[int, int]]:
    return [record for record in records if start <= record[0] <= stop]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame_trace", type=Path)
    parser.add_argument("rtl_frames", type=Path)
    parser.add_argument("--start-frame", type=int, required=True)
    parser.add_argument("--stop-frame", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.start_frame < 0 or args.stop_frame < args.start_frame:
        raise SystemExit("invalid frame window")

    required = args.stop_frame - args.start_frame + 1
    reference = window(mame_frames(args.mame_trace), args.start_frame, args.stop_frame)
    candidate = window(rtl_frames(args.rtl_frames), args.start_frame, args.stop_frame)
    matching_prefix = 0
    first_bad: dict[str, object] | None = None
    for index in range(min(len(reference), len(candidate))):
        left = reference[index]
        right = candidate[index]
        if left != right:
            first_bad = {
                "window_ordinal": index,
                "reference": {"frame": left[0], "rgb_crc32": f"{left[1]:08x}"},
                "candidate": {"frame": right[0], "rgb_crc32": f"{right[1]:08x}"},
            }
            break
        matching_prefix += 1
    if first_bad is None and len(reference) != len(candidate):
        first_bad = {
            "window_ordinal": matching_prefix,
            "reference": reference[matching_prefix] if matching_prefix < len(reference) else None,
            "candidate": candidate[matching_prefix] if matching_prefix < len(candidate) else None,
        }
    complete = len(reference) == required and len(candidate) == required
    status = "match" if complete and first_bad is None else ("truncated" if first_bad is None else "mismatch")
    result = {
        "schema": "ssv-frame-crc-compare-v1",
        "status": status,
        "normalization": "native_rgb_crc32_v1",
        "start_frame": args.start_frame,
        "stop_frame": args.stop_frame,
        "required_frames": required,
        "reference_frames": len(reference),
        "candidate_frames": len(candidate),
        "matching_prefix": matching_prefix,
        "first_bad": first_bad,
        "reference_trace": str(args.mame_trace.resolve()),
        "reference_sha256": sha256(args.mame_trace),
        "candidate_trace": str(args.rtl_frames.resolve()),
        "candidate_sha256": sha256(args.rtl_frames),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if status == "match" else 1


if __name__ == "__main__":
    raise SystemExit(main())
