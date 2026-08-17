#!/usr/bin/env python3
"""Compare per-frame SSV memory-state CRC summaries.

The optional JSON receipt is deliberately strict: an explicit frame window
must exist on both sides and is compared by the declared frame number, with
no resynchronisation or missing-as-zero behavior.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

LINE = re.compile(
    r"^STATE\s+(\d+)\s+list512=([0-9a-fA-F]{8})\s+"
    r"spr8k=([0-9a-fA-F]{8})\s+scroll63=([0-9a-fA-F]{8})\s+"
    r"pal512=([0-9a-fA-F]{8})$"
)
FIELDS = ("list512", "spr8k", "scroll63", "pal512")


def load(path: Path):
    states = {}
    for lineno, text in enumerate(path.read_text().splitlines(), 1):
        if not text.strip():
            continue
        match = LINE.match(text.strip())
        if not match:
            raise ValueError(f"{path}:{lineno}: malformed state line: {text}")
        frame = int(match.group(1))
        if frame in states:
            raise ValueError(f"{path}:{lineno}: duplicate state frame {frame}")
        states[frame] = tuple(int(value, 16) for value in match.groups()[1:])
    return states


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def state_json(values):
    return None if values is None else {
        name: f"{values[index]:08x}" for index, name in enumerate(FIELDS)
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-frames", type=int)
    parser.add_argument("--start-frame", type=int, default=None)
    parser.add_argument("--stop-frame", type=int, default=None)
    parser.add_argument("--output", type=Path, help="write a machine-readable receipt")
    parser.add_argument(
        "--ignore-field", action="append", choices=FIELDS, default=[],
        help="exclude a known non-comparable field (repeatable)",
    )
    args = parser.parse_args()
    if args.start_frame is not None and args.start_frame < 0:
        parser.error("--start-frame must be nonnegative")
    if args.stop_frame is not None and args.stop_frame < 0:
        parser.error("--stop-frame must be nonnegative")
    if args.start_frame is not None and args.stop_frame is not None and args.stop_frame < args.start_frame:
        parser.error("--stop-frame must be >= --start-frame")

    try:
        reference = load(args.reference)
        candidate = load(args.candidate)
    except (OSError, ValueError) as exc:
        if args.output:
            args.output.write_text(json.dumps({
                "schema": "ssv-state-crc-compare-v1",
                "status": "error",
                "error": str(exc),
            }, indent=2) + "\n")
        print(str(exc), file=sys.stderr)
        return 2

    explicit_window = args.start_frame is not None or args.stop_frame is not None
    if explicit_window:
        start = 0 if args.start_frame is None else args.start_frame
        if args.stop_frame is not None:
            stop = args.stop_frame
        elif args.max_frames is not None:
            stop = args.max_frames - 1
        else:
            stop = max(set(reference) | set(candidate), default=start)
        frames = list(range(start, stop + 1))
    else:
        frames = sorted(set(reference) & set(candidate))
        if args.max_frames is not None:
            frames = [frame for frame in frames if frame < args.max_frames]

    first_bad = None
    missing = None
    matching_prefix = 0
    for frame in frames:
        ref = reference.get(frame)
        cand = candidate.get(frame)
        if ref is None or cand is None:
            missing = {"frame": frame, "reference_present": ref is not None,
                       "candidate_present": cand is not None}
            break
        diffs = {
            name: {"reference": f"{ref[index]:08x}", "candidate": f"{cand[index]:08x}"}
            for index, name in enumerate(FIELDS)
            if name not in args.ignore_field and ref[index] != cand[index]
        }
        if diffs:
            first_bad = {"frame": frame, "fields": diffs}
            break
        matching_prefix += 1

    status = "match" if first_bad is None and missing is None and frames else "mismatch"
    if not frames:
        status = "error"
    receipt = {
        "schema": "ssv-state-crc-compare-v1",
        "status": status,
        "normalization": "state_crc32_v1",
        "fields": [field for field in FIELDS if field not in args.ignore_field],
        "reference_path": str(args.reference.resolve()),
        "candidate_path": str(args.candidate.resolve()),
        "reference_sha256": sha256(args.reference),
        "candidate_sha256": sha256(args.candidate),
        "start_frame": frames[0] if frames else None,
        "stop_frame": frames[-1] if frames else None,
        "required_frames": len(frames),
        "reference_frames": len(reference),
        "candidate_frames": len(candidate),
        "matching_prefix": matching_prefix,
        "first_bad": first_bad,
        "missing": missing,
        "resynchronized": False,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")

    if status == "match":
        print(f"STATE_MATCH frames={len(frames)} first={frames[0]} last={frames[-1]}")
        return 0
    if first_bad:
        details = " ".join(
            f"{name}:ref={values['reference']},rtl={values['candidate']}"
            for name, values in first_bad["fields"].items()
        )
        print(f"STATE_DIVERGENCE frame={first_bad['frame']} {details}", file=sys.stderr)
    elif missing:
        print(f"STATE_MISSING frame={missing['frame']} "
              f"reference={missing['reference_present']} candidate={missing['candidate_present']}", file=sys.stderr)
    else:
        print("no common frames", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
