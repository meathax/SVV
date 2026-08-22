#!/usr/bin/env python3
"""Compare ordered native-frame states without hiding raster cadence drift."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def mame_frames(path: Path) -> list[int]:
    frames = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if '"name":"frame_complete"' not in line:
            continue
        record = json.loads(line)
        if record.get("post_epoch_frame") != len(frames):
            raise ValueError("MAME frame cursor is not contiguous")
        frames.append(int(record["frame_crc32"]))
    return frames


def rtl_frames(path: Path) -> list[int]:
    frames = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if not fields or fields[0] != "FRAME":
            continue
        if int(fields[1]) != len(frames):
            raise ValueError("RTL frame cursor is not contiguous")
        frames.append(int(fields[3], 16))
    return frames


def runs(frames: list[int]) -> list[dict[str, int]]:
    result: list[dict[str, int]] = []
    for frame, crc in enumerate(frames):
        if result and result[-1]["crc32"] == crc:
            result[-1]["last_frame"] = frame
            result[-1]["length"] += 1
        else:
            result.append({
                "crc32": crc,
                "first_frame": frame,
                "last_frame": frame,
                "length": 1,
            })
    return result


def lcs(left: list[dict[str, int]], right: list[dict[str, int]]) -> list[tuple[int, int]]:
    rows, columns = len(left), len(right)
    table = [[0] * (columns + 1) for _ in range(rows + 1)]
    for i in range(rows - 1, -1, -1):
        for j in range(columns - 1, -1, -1):
            if left[i]["crc32"] == right[j]["crc32"]:
                table[i][j] = table[i + 1][j + 1] + 1
            else:
                table[i][j] = max(table[i + 1][j], table[i][j + 1])
    pairs = []
    i = j = 0
    while i < rows and j < columns:
        if left[i]["crc32"] == right[j]["crc32"]:
            pairs.append((i, j))
            i += 1
            j += 1
        elif table[i + 1][j] >= table[i][j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame_trace", type=Path)
    parser.add_argument("rtl_frames", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    mame = mame_frames(args.mame_trace)
    rtl = rtl_frames(args.rtl_frames)
    mame_runs = runs(mame)
    rtl_runs = runs(rtl)
    pairs = lcs(mame_runs, rtl_runs)
    paired_mame = {i for i, _ in pairs}
    paired_rtl = {j for _, j in pairs}
    unmatched_mame = [mame_runs[i] for i in range(len(mame_runs)) if i not in paired_mame]
    unmatched_rtl = [rtl_runs[j] for j in range(len(rtl_runs)) if j not in paired_rtl]
    duration_deltas = []
    for i, j in pairs:
        if mame_runs[i]["length"] != rtl_runs[j]["length"]:
            duration_deltas.append({
                "crc32": f"{mame_runs[i]['crc32']:08x}",
                "mame": mame_runs[i],
                "rtl": rtl_runs[j],
            })

    # The RTL capture deliberately includes one pre-epoch partial frame. It
    # is admissible only as the first unmatched RTL run; every subsequent
    # ordered pixel state must occur in both lanes. A missing/extra corrupted
    # animation frame therefore remains a hard mismatch.
    allowed_rtl_prefix = (
        len(unmatched_rtl) == 1 and
        unmatched_rtl[0]["first_frame"] == 0 and
        unmatched_rtl[0]["last_frame"] == 0
    )
    match = not unmatched_mame and (not unmatched_rtl or allowed_rtl_prefix)
    receipt = {
        "schema": "ssv-sprite-frame-comparator-v1",
        "match": match,
        "comparison": "ordered exact native RGB CRC states; duration drift reported separately",
        "mame": {
            "path": str(args.mame_trace.resolve()),
            "sha256": sha256(args.mame_trace),
            "frames": len(mame),
            "runs": len(mame_runs),
        },
        "rtl": {
            "path": str(args.rtl_frames.resolve()),
            "sha256": sha256(args.rtl_frames),
            "frames": len(rtl),
            "runs": len(rtl_runs),
        },
        "matched_runs": len(pairs),
        "unmatched_mame": unmatched_mame,
        "unmatched_rtl": unmatched_rtl,
        "allowed_rtl_pre_epoch_partial_frame": allowed_rtl_prefix,
        "duration_deltas": duration_deltas,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print(json.dumps(receipt, sort_keys=True))
    return 0 if match else 1


if __name__ == "__main__":
    raise SystemExit(main())
