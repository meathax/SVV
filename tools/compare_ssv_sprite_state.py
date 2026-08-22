#!/usr/bin/env python3
"""Compare ordered SSV sprite-list and sprite-RAM state fingerprints."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


STATE = re.compile(
    r"^STATE (?P<frame>\d+) list512=(?P<list>[0-9a-fA-F]{8}) "
    r"spr8k=(?P<sprite>[0-9a-fA-F]{8})"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def states(path: Path) -> list[str]:
    result = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        match = STATE.match(line)
        if not match:
            continue
        if int(match.group("frame")) != len(result):
            raise ValueError(f"non-contiguous state frames in {path}")
        result.append(match.group("list").lower() + match.group("sprite").lower())
    if not result:
        raise ValueError(f"no SSV sprite state records in {path}")
    return result


def runs(values: list[str]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for frame, value in enumerate(values):
        if result and result[-1]["value"] == value:
            result[-1]["last_frame"] = frame
            result[-1]["length"] = int(result[-1]["length"]) + 1
        else:
            result.append({
                "value": value,
                "list512": value[:8],
                "spr8k": value[8:],
                "first_frame": frame,
                "last_frame": frame,
                "length": 1,
            })
    return result


def lcs(left: list[dict[str, object]], right: list[dict[str, object]]) -> list[tuple[int, int]]:
    rows, columns = len(left), len(right)
    table = [[0] * (columns + 1) for _ in range(rows + 1)]
    for i in range(rows - 1, -1, -1):
        for j in range(columns - 1, -1, -1):
            if left[i]["value"] == right[j]["value"]:
                table[i][j] = table[i + 1][j + 1] + 1
            else:
                table[i][j] = max(table[i + 1][j], table[i][j + 1])
    pairs = []
    i = j = 0
    while i < rows and j < columns:
        if left[i]["value"] == right[j]["value"]:
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
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    reference = runs(states(args.reference))
    candidate = runs(states(args.candidate))
    pairs = lcs(reference, candidate)
    matched_reference = {i for i, _ in pairs}
    matched_candidate = {j for _, j in pairs}
    unmatched_reference = [run for i, run in enumerate(reference)
                           if i not in matched_reference]
    unmatched_candidate = [run for j, run in enumerate(candidate)
                           if j not in matched_candidate]
    receipt = {
        "schema": "ssv-sprite-state-comparator-v1",
        "match": not unmatched_reference and not unmatched_candidate,
        "comparison": "ordered exact list512+spr8k state runs; cadence retained",
        "reference": {
            "path": str(args.reference.resolve()),
            "sha256": sha256(args.reference),
            "frames": sum(int(run["length"]) for run in reference),
            "runs": len(reference),
        },
        "candidate": {
            "path": str(args.candidate.resolve()),
            "sha256": sha256(args.candidate),
            "frames": sum(int(run["length"]) for run in candidate),
            "runs": len(candidate),
        },
        "matched_runs": len(pairs),
        "last_matched_reference_frame": max(
            (int(reference[i]["last_frame"]) for i, _ in pairs), default=-1),
        "last_matched_candidate_frame": max(
            (int(candidate[j]["last_frame"]) for _, j in pairs), default=-1),
        "unmatched_reference": unmatched_reference,
        "unmatched_candidate": unmatched_candidate,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt["match"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
