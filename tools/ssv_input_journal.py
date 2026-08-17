#!/usr/bin/env python3
"""Validate and stage immutable protocol-v2 input journals.

Checkpoint lockstep cannot ask a restored RTL model to reproduce frames that
are already inside the archive.  The checkpoint accumulation run therefore
records the exact active-high input packet committed by RTL for every following
native frame.  Gameplay scenarios use the same packet shape, but are authored
before either producer runs and carry ``source=scenario``.  This module gives
both forms one canonical semantic digest and refuses gaps or renumbering.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile


PACKET_KEYS = ("frame", "p1_pressed", "p2_pressed", "system_pressed", "source")
SCENARIO_SOURCE = "scenario"


def packet_path(journal: Path, frame: int) -> Path:
    return journal / f"frame_{frame:06d}.json"


def canonical_packet(
    packet: object, expected_frame: int, *, allow_scenario: bool = True
) -> dict[str, object]:
    if not isinstance(packet, dict):
        raise ValueError(f"input packet {expected_frame} is not an object")
    frame = packet.get("frame")
    expected_source = "neutral-seed" if expected_frame == 0 else "rtl-owner"
    actual_source = packet.get("source")
    if allow_scenario and actual_source == SCENARIO_SOURCE:
        expected_source = SCENARIO_SOURCE
    if frame != expected_frame:
        raise ValueError(
            f"input packet frame mismatch: expected {expected_frame}, got {frame!r}"
        )
    if actual_source != expected_source:
        raise ValueError(
            f"input packet {expected_frame} source must be {expected_source!r}, "
            f"got {packet.get('source')!r}"
        )
    result: dict[str, object] = {"frame": expected_frame}
    for key in ("p1_pressed", "p2_pressed", "system_pressed"):
        value = packet.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 0xffff:
            raise ValueError(
                f"input packet {expected_frame} has invalid {key}: {value!r}"
            )
        result[key] = value
    result["source"] = expected_source
    return result


def canonical_bytes(packet: dict[str, object]) -> bytes:
    return (json.dumps(packet, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def read_packet(journal: Path, frame: int) -> dict[str, object]:
    path = packet_path(journal, frame)
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as error:
        raise ValueError(f"missing input packet {frame}: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid input packet JSON {path}: {error}") from error
    return canonical_packet(value, frame)


def inspect_journal(journal: Path, through_frame: int) -> dict[str, object]:
    if through_frame < 0:
        raise ValueError("through_frame must be nonnegative")
    digest = hashlib.sha256()
    for frame in range(through_frame + 1):
        data = canonical_bytes(read_packet(journal, frame))
        digest.update(len(data).to_bytes(4, "big"))
        digest.update(data)
    return {
        "schema": "ssv-input-journal-v2",
        "path": str(journal.resolve()),
        "through_frame": through_frame,
        "packet_count": through_frame + 1,
        "semantic_sha256": digest.hexdigest(),
        "ownership": (
            "scenario-authored immutable packets"
            if any(read_packet(journal, frame)["source"] == SCENARIO_SOURCE
                   for frame in range(through_frame + 1))
            else "neutral frame 0; RTL owner frames 1..through_frame"
        ),
    }


def atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def stage_journal(journal: Path, destination: Path, through_frame: int) -> dict[str, object]:
    identity = inspect_journal(journal, through_frame)
    destination.mkdir(parents=True, exist_ok=True)
    for frame in range(through_frame + 1):
        packet = read_packet(journal, frame)
        atomic_bytes(packet_path(destination, frame), canonical_bytes(packet))
    staged = inspect_journal(destination, through_frame)
    if staged["semantic_sha256"] != identity["semantic_sha256"]:
        raise RuntimeError("staged input journal identity changed")
    return identity


def seed_neutral(journal: Path) -> None:
    packet = canonical_packet(
        {
            "frame": 0,
            "p1_pressed": 0,
            "p2_pressed": 0,
            "system_pressed": 0,
            "source": "neutral-seed",
        },
        0,
    )
    target = packet_path(journal, 0)
    if target.exists():
        if read_packet(journal, 0) != packet:
            raise ValueError(f"existing neutral seed differs: {target}")
        return
    atomic_bytes(target, canonical_bytes(packet))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--journal", type=Path, required=True)
    parser.add_argument("--through", type=int)
    parser.add_argument("--stage-to", type=Path)
    parser.add_argument("--seed-neutral", action="store_true")
    args = parser.parse_args()
    if args.seed_neutral:
        seed_neutral(args.journal)
    if args.through is None:
        if not args.seed_neutral:
            parser.error("--through or --seed-neutral is required")
        return 0
    identity = (
        stage_journal(args.journal, args.stage_to, args.through)
        if args.stage_to
        else inspect_journal(args.journal, args.through)
    )
    print(json.dumps(identity, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
