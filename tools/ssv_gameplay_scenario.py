#!/usr/bin/env python3
"""Validate and compile one immutable SSV gameplay input journal.

The scenario is the source-of-truth input contract.  It is intentionally
small, JSON-only, and independent of either MAME or Verilator.  ``events``
are frame edges and masks are active-high pressed bits using the same logical
mapping as the MAME adapter.  Low player bits retain MAME's P1/P2 ports; for
Survival Arts, ``0x100/0x200/0x400`` carry ADD_BUTTONS B4/B5/B6. The compiler
expands those edges into the directory journal consumed by both headless lanes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET

from ssv_supported_sets import SUPPORTED_SETS


SCHEMA = "ssv-gameplay-scenario-v1"
JOURNAL_SCHEMA = "ssv-input-journal-v2"
SETS = set(SUPPORTED_SETS)
MASK_KEYS = ("p1_pressed", "p2_pressed", "system_pressed")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def read_scenario(path: Path) -> tuple[dict, bytes]:
    raw = path.read_bytes()
    value = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("scenario must be a JSON object")
    if value.get("schema") != SCHEMA:
        raise ValueError(f"scenario schema must be {SCHEMA}")
    setname = value.get("set")
    if setname not in SETS:
        raise ValueError(f"unsupported authoritative set: {setname!r}")
    if not isinstance(value.get("id"), str) or not value["id"]:
        raise ValueError("scenario id is required")
    stop = value.get("stop")
    entry = value.get("gameplay_entry")
    if not isinstance(stop, dict) or not isinstance(entry, dict):
        raise ValueError("gameplay_entry and stop objects are required")
    neutral_after = entry.get("neutral_after_frame")
    soak = stop.get("neutral_soak_frames", 120)
    if not isinstance(neutral_after, int) or neutral_after < 0:
        raise ValueError("gameplay_entry.neutral_after_frame must be nonnegative")
    if not isinstance(soak, int) or soak != 120:
        raise ValueError("the gameplay gate requires exactly 120 neutral frames")
    through = neutral_after + soak
    if stop.get("through_frame", through) != through:
        raise ValueError("stop.through_frame must equal neutral entry plus 120 frames")
    expected_watchdog = value.get("expected_watchdog", {})
    if not isinstance(expected_watchdog, dict):
        raise ValueError("expected_watchdog must be an object")
    watchdog_resets = expected_watchdog.get("resets", 0)
    watchdog_min = expected_watchdog.get("min_post_video_frame", 0)
    watchdog_max = expected_watchdog.get("max_post_video_frame", 0)
    for name, field in (("resets", watchdog_resets),
                        ("min_post_video_frame", watchdog_min),
                        ("max_post_video_frame", watchdog_max)):
        if not isinstance(field, int) or isinstance(field, bool) or field < 0:
            raise ValueError(f"expected_watchdog.{name} must be a nonnegative integer")
    if watchdog_resets == 0 and (watchdog_min or watchdog_max):
        raise ValueError("expected_watchdog frame bounds require a nonzero reset count")
    if watchdog_resets and watchdog_min > watchdog_max:
        raise ValueError("expected_watchdog frame bounds are reversed")
    defaults = value.get("defaults", {})
    if not isinstance(defaults, dict):
        raise ValueError("defaults must be an object")
    current = {key: _mask(defaults.get(key, 0), key, 0) for key in MASK_KEYS}
    events = value.get("events", [])
    if not isinstance(events, list):
        raise ValueError("events must be an array")
    previous = -1
    normalized: list[dict] = []
    for event in events:
        if not isinstance(event, dict) or not isinstance(event.get("frame"), int):
            raise ValueError("each event requires an integer frame")
        frame = event["frame"]
        if frame < 0 or frame <= previous:
            raise ValueError("event frames must be strictly increasing")
        previous = frame
        if frame > through:
            raise ValueError(f"event frame {frame} exceeds stop.through_frame {through}")
        packet = {"frame": frame}
        for key in MASK_KEYS:
            if key in event:
                current[key] = _mask(event[key], key, frame)
            packet[key] = current[key]
        if frame >= neutral_after and any(packet[key] for key in MASK_KEYS):
            raise ValueError(f"non-neutral event at or after gameplay entry: frame {frame}")
        normalized.append(packet)
    return {**value, "events": normalized,
            "stop": {**stop, "through_frame": through},
            "expected_watchdog": {
                "resets": watchdog_resets,
                "min_post_video_frame": watchdog_min,
                "max_post_video_frame": watchdog_max,
            }}, raw


def _mask(value: object, key: str, frame: int) -> int:
    if isinstance(value, str):
        value = int(value, 0)
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 0xffff:
        raise ValueError(f"{key} at frame {frame} must be a 16-bit mask")
    return value


def descriptor_identity(scenario: dict, mra_dir: Path) -> dict[str, object] | None:
    mra_name = scenario.get("mra")
    if not mra_name:
        return None
    path = mra_dir / mra_name
    if not path.is_file():
        raise FileNotFoundError(f"scenario MRA does not exist: {path}")
    root = ET.parse(path).getroot()
    descriptor = (root.find("rom[@index='1']/part").text or "").strip()
    data = bytes.fromhex(descriptor)
    if len(data) != 24 or data[:2] != b"S\x03" or sum(data) & 0xff:
        raise ValueError(f"scenario MRA descriptor is not checksum-valid v3: {path}")
    return {
        "path": str(path.resolve()),
        "sha256": sha256_bytes(path.read_bytes()),
        "descriptor_v3_sha256": sha256_bytes(data),
        "descriptor_hex": descriptor,
    }


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
        Path(temporary).replace(path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def compile_journal(scenario_path: Path, output: Path, mra_dir: Path) -> dict[str, object]:
    scenario, raw = read_scenario(scenario_path)
    through = scenario["stop"]["through_frame"]
    neutral_after = scenario["gameplay_entry"]["neutral_after_frame"]
    current = {key: _mask(scenario.get("defaults", {}).get(key, 0), key, 0)
               for key in MASK_KEYS}
    by_frame = {event["frame"]: event for event in scenario["events"]}
    digest = hashlib.sha256()
    output.mkdir(parents=True, exist_ok=True)
    for frame in range(through + 1):
        if frame in by_frame:
            current.update({key: by_frame[frame][key] for key in MASK_KEYS})
        if frame >= neutral_after:
            current = {key: 0 for key in MASK_KEYS}
        packet = {"frame": frame, **current, "source": "scenario"}
        encoded = canonical_json(packet)
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        atomic_write(output / f"frame_{frame:06d}.json", encoded)
    identity = descriptor_identity(scenario, mra_dir)
    manifest = {
        "schema": JOURNAL_SCHEMA,
        "scenario_schema": SCHEMA,
        "scenario_id": scenario["id"],
        "set": scenario["set"],
        "scenario_sha256": sha256_bytes(raw),
        "through_frame": through,
        "neutral_after_frame": neutral_after,
        "neutral_soak_frames": 120,
        "expected_watchdog": scenario["expected_watchdog"],
        "packet_count": through + 1,
        "semantic_sha256": digest.hexdigest(),
        "ownership": "scenario-authored immutable packets",
        "descriptor": identity,
    }
    atomic_write(output / "manifest.json", canonical_json(manifest))
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate")
    validate.add_argument("scenario", type=Path)
    compile_parser = sub.add_parser("compile")
    compile_parser.add_argument("scenario", type=Path)
    compile_parser.add_argument("--output", type=Path, required=True)
    compile_parser.add_argument("--mra-dir", type=Path,
                                default=Path(__file__).resolve().parents[1] / "releases")
    args = parser.parse_args()
    if args.command == "validate":
        scenario, raw = read_scenario(args.scenario)
        print(json.dumps({"status": "valid", "scenario_sha256": sha256_bytes(raw),
                          "set": scenario["set"], "through_frame": scenario["stop"]["through_frame"]},
                         sort_keys=True))
        return 0
    print(json.dumps(compile_journal(args.scenario, args.output, args.mra_dir), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
