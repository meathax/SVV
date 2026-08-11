#!/usr/bin/env python3
"""Preseed deterministic SSV scenario packets for event-aligned lockstep."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import tempfile


P1_BITS = {"P1 START": 0x01, "P1 B1": 0x08, "P1 RIGHT": 0x10, "P1 UP": 0x80}
SYSTEM_BITS = {"COIN1": 0x01}


def ranges(text: str) -> list[tuple[int, int]]:
    result = []
    for item in text.split(","):
        lo, hi = item.strip().split("-", 1)
        result.append((int(lo), int(hi)))
    return result


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", type=Path, required=True)
    parser.add_argument("--journal", type=Path, required=True)
    parser.add_argument("--through", type=int, required=True)
    parser.add_argument("--coin-lo", type=int, default=-1)
    parser.add_argument("--coin-hi", type=int, default=-1)
    parser.add_argument("--start-lo", type=int, default=-1)
    parser.add_argument("--start-hi", type=int, default=-1)
    args = parser.parse_args()

    scenario = json.loads(args.scenario.read_text(encoding="utf-8-sig"))
    through = max(args.through, int(scenario.get("stop", {}).get("after_video_enable_frames", 0)))
    p1 = [0] * (through + 1)
    system = [0] * (through + 1)
    initial_start_replaced = False
    for entry in scenario["schedule"]:
        name = entry["input"]
        spans = ranges(entry["frames"])
        if name == "COIN1" and args.coin_lo >= 0 and args.coin_hi >= 0:
            spans = [(args.coin_lo, args.coin_hi - 1)]
        elif (name == "P1 START" and not initial_start_replaced and
              args.start_lo >= 0 and args.start_hi >= 0):
            spans = [(args.start_lo, args.start_hi - 1)]
            initial_start_replaced = True
        for lo, hi in spans:
            for frame in range(max(0, lo), min(through, hi) + 1):
                if name in P1_BITS:
                    p1[frame] |= P1_BITS[name]
                elif name in SYSTEM_BITS:
                    system[frame] |= SYSTEM_BITS[name]
                else:
                    raise ValueError(f"unsupported scenario input {name!r}")

    for frame in range(through + 1):
        packet = {
            "frame": frame,
            "p1_pressed": p1[frame],
            "p2_pressed": 0,
            "system_pressed": system[frame],
            "source": "neutral-seed" if frame == 0 else "rtl-owner",
        }
        data = (json.dumps(packet, separators=(",", ":")) + "\n").encode("utf-8")
        target = args.journal / f"frame_{frame:06d}.json"
        if target.exists() and json.loads(target.read_text(encoding="utf-8-sig")) != packet:
            raise ValueError(f"existing packet differs: {target}")
        if not target.exists():
            atomic_write(target, data)
    print(f"preseeded {through + 1} deterministic packets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
