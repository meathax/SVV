#!/usr/bin/env python3
"""Compare the SSV ES5506 host/control stream without loading giant traces."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, deque
from pathlib import Path
from typing import Any, Iterable, Iterator


SOUND_BASE = 0x300000
SOUND_DEVICE = 9
SENTINEL = object()


def iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    with path.open("rb") as handle:
        for line_number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"invalid JSON at {path}:{line_number}: {exc}") from exc
            if isinstance(record, dict):
                yield record


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def receipt(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise RuntimeError(f"receipt is not an object: {path}")
    return value


def require_complete(value: dict[str, Any] | None, label: str) -> None:
    if value is None:
        return
    if value.get("complete") is not True or int(value.get("dropped", 0)) != 0:
        raise RuntimeError(f"{label} receipt is incomplete or dropped events")


def sound_bus(
    path: Path,
    start_frame: int | None = None,
    stop_frame: int | None = None,
) -> Iterator[dict[str, Any]]:
    for record in iter_jsonl(path):
        if record.get("domain") != "mainbus" or int(record.get("device", -1)) != SOUND_DEVICE:
            continue
        if start_frame is not None:
            if "frame" not in record:
                continue
            frame = int(record["frame"])
            if frame < start_frame or (stop_frame is not None and frame > stop_frame):
                continue
        yield {
            "seq": record.get("seq"),
            "rw": record.get("rw"),
            "address": int(record.get("address", 0)),
            "data": int(record.get("data", 0)),
            "byte_enable": int(record.get("byte_enable", 0)),
            **{
                key: record[key]
                for key in ("pc", "cycle", "frame", "scanline")
                if key in record
            },
        }


def mame_host_commits(
    path: Path,
    state: dict[str, int],
    start_frame: int | None = None,
    stop_frame: int | None = None,
) -> Iterator[dict[str, Any]]:
    page = 0
    write_latch = 0

    # MAME's es5506_device::write() accepts each byte independently.  It
    # updates m_write_latch at the byte selected by (offset & 3), commits on
    # byte slot 3, and then clears the latch.  A legal transaction can start
    # at slot 1 or 2; grouping only slot-0..3 runs silently changes such
    # writes into low-byte commits and invents malformed groups.
    for event in sound_bus(path):
        if event["rw"] != "W":
            continue
        offset = event["address"] - SOUND_BASE
        if offset < 0 or offset > 0x7F or (offset & 1):
            state["malformed"] += 1
            continue

        word_offset = offset >> 1
        slot = word_offset & 0x3
        shift = 8 * slot
        write_latch = (write_latch & ~(0xFF000000 >> shift)) | (
            (event["data"] & 0xFF) << (24 - shift)
        )
        if shift != 24:
            continue

        data = write_latch
        register = (word_offset >> 2) & 0xF
        current_page = page
        write_latch = 0
        if register == 0xF:
            page = data & 0x7F

        frame = event.get("frame")
        if start_frame is not None and (
            frame is None
            or int(frame) < start_frame
            or (stop_frame is not None and int(frame) > stop_frame)
        ):
            continue
        state["groups"] += 1
        yield {
            "seq": state["groups"] - 1,
            "page": current_page,
            "register": register,
            "data": data,
            "bus_seq_first": event["seq"],
            "bus_seq_last": event["seq"],
            "address": event["address"],
            "addresses": [event["address"]],
            **({"frame": frame} if frame is not None else {}),
        }


def rtl_host_commits(
    path: Path,
    start_frame: int | None = None,
    stop_frame: int | None = None,
) -> Iterator[dict[str, Any]]:
    for record in iter_jsonl(path):
        if record.get("domain") != "es5506" or record.get("event") != "host_commit":
            continue
        if start_frame is not None:
            frame = int(record.get("frame", -1))
            if frame < start_frame or (stop_frame is not None and frame > stop_frame):
                continue
        yield {
            "seq": record.get("seq"),
            "page": int(record.get("page", 0)),
            "register": int(record.get("register", 0)),
            "data": int(record.get("data", 0)),
            **{
                key: record[key]
                for key in ("cycle", "frame", "scanline")
                if key in record
            },
        }


def event_key(event: dict[str, Any], fields: tuple[str, ...]) -> tuple[Any, ...]:
    return tuple(event.get(field) for field in fields)


def compare_streams(
    reference: Iterable[dict[str, Any]],
    candidate: Iterable[dict[str, Any]],
    fields: tuple[str, ...],
    context_size: int,
) -> dict[str, Any]:
    reference_iter = iter(reference)
    candidate_iter = iter(candidate)
    reference_before: deque[dict[str, Any]] = deque(maxlen=context_size)
    candidate_before: deque[dict[str, Any]] = deque(maxlen=context_size)
    first: dict[str, Any] | None = None
    reference_after: list[dict[str, Any]] = []
    candidate_after: list[dict[str, Any]] = []
    index = 0
    reference_count = 0
    candidate_count = 0
    after_remaining = 0

    while True:
        reference_event = next(reference_iter, SENTINEL)
        candidate_event = next(candidate_iter, SENTINEL)
        if reference_event is SENTINEL and candidate_event is SENTINEL:
            break

        if reference_event is not SENTINEL:
            reference_count += 1
        if candidate_event is not SENTINEL:
            candidate_count += 1

        mismatch = (
            reference_event is SENTINEL
            or candidate_event is SENTINEL
            or event_key(reference_event, fields) != event_key(candidate_event, fields)
        )
        if mismatch and first is None:
            first = {
                "index": index,
                "fields": list(fields),
                "reference": None if reference_event is SENTINEL else reference_event,
                "candidate": None if candidate_event is SENTINEL else candidate_event,
                "reference_before": list(reference_before),
                "candidate_before": list(candidate_before),
            }
            after_remaining = context_size
        elif first is not None and after_remaining > 0:
            if reference_event is not SENTINEL:
                reference_after.append(reference_event)
            if candidate_event is not SENTINEL:
                candidate_after.append(candidate_event)
            after_remaining -= 1

        if reference_event is not SENTINEL:
            reference_before.append(reference_event)
        if candidate_event is not SENTINEL:
            candidate_before.append(candidate_event)
        index += 1

    if first is not None:
        first["reference_after"] = reference_after
        first["candidate_after"] = candidate_after

    return {
        "reference_count": reference_count,
        "candidate_count": candidate_count,
        "first_mismatch": first,
        "status": "match" if first is None else "mismatch",
    }


def rtl_irq_summary(
    path: Path,
    start_frame: int | None = None,
    stop_frame: int | None = None,
) -> dict[str, Any]:
    events = []
    kinds: Counter[str] = Counter()
    for record in iter_jsonl(path):
        if record.get("domain") != "irq":
            continue
        if start_frame is not None:
            frame = int(record.get("frame", -1))
            if frame < start_frame or (stop_frame is not None and frame > stop_frame):
                continue
        event = str(record.get("event", ""))
        kinds[event] += 1
        if len(events) < 8:
            events.append(record)
    return {"count": sum(kinds.values()), "by_event": dict(kinds), "first_events": events}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mame-trace", type=Path, required=True)
    parser.add_argument("--rtl-trace", type=Path, required=True)
    parser.add_argument("--mame-receipt", type=Path)
    parser.add_argument("--rtl-receipt", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--context", type=int, default=4)
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--stop-frame", type=int)
    parser.add_argument("--reference-start-frame", type=int)
    parser.add_argument("--reference-stop-frame", type=int)
    parser.add_argument("--candidate-start-frame", type=int)
    parser.add_argument("--candidate-stop-frame", type=int)
    args = parser.parse_args()
    if args.context < 0:
        parser.error("--context must be non-negative")
    if (args.start_frame is None) != (args.stop_frame is None):
        parser.error("--start-frame and --stop-frame must be supplied together")
    if args.start_frame is not None and args.stop_frame < args.start_frame:
        parser.error("--stop-frame must be >= --start-frame")
    for label, start, stop in (
        ("reference", args.reference_start_frame, args.reference_stop_frame),
        ("candidate", args.candidate_start_frame, args.candidate_stop_frame),
    ):
        if (start is None) != (stop is None):
            parser.error(f"--{label}-start-frame and --{label}-stop-frame must be supplied together")
        if start is not None and stop < start:
            parser.error(f"--{label}-stop-frame must be >= --{label}-start-frame")

    reference_start = args.reference_start_frame
    reference_stop = args.reference_stop_frame
    candidate_start = args.candidate_start_frame
    candidate_stop = args.candidate_stop_frame
    if args.start_frame is not None:
        if reference_start is None:
            reference_start, reference_stop = args.start_frame, args.stop_frame
        if candidate_start is None:
            candidate_start, candidate_stop = args.start_frame, args.stop_frame

    mame_receipt = receipt(args.mame_receipt)
    rtl_receipt = receipt(args.rtl_receipt)
    require_complete(mame_receipt, "MAME")
    require_complete(rtl_receipt, "RTL")

    bus = compare_streams(
        sound_bus(args.mame_trace, reference_start, reference_stop),
        sound_bus(args.rtl_trace, candidate_start, candidate_stop),
        ("rw", "address", "data", "byte_enable"),
        args.context,
    )
    mame_commit_state = {"groups": 0, "malformed": 0}
    commits = compare_streams(
        mame_host_commits(args.mame_trace, mame_commit_state, reference_start, reference_stop),
        rtl_host_commits(args.rtl_trace, candidate_start, candidate_stop),
        ("page", "register", "data"),
        args.context,
    )

    result = {
        "schema": "ssv-es5506-stream-comparison-v1",
        "status": "match" if bus["status"] == "match" and commits["status"] == "match" else "mismatch",
        "contract": {
            "reference": "MAME device-9 sound bus and reconstructed four-byte ES5506 commits",
            "candidate": "RTL device-9 sound bus and es5506 host_commit events",
            "sound_base": SOUND_BASE,
            "sound_device": SOUND_DEVICE,
            "commit_byte_order": "big_endian_byte0_to_byte3",
            "commit_page_register": 0xF,
            "page_update": "data[6:0] after PAGE commit",
            "frame_window": None if reference_start is None and candidate_start is None else {
                "reference": {"start": reference_start, "stop": reference_stop},
                "candidate": {"start": candidate_start, "stop": candidate_stop},
            },
        },
        "reference": {
            "trace": str(args.mame_trace.resolve()),
            "trace_sha256": file_sha256(args.mame_trace),
            "receipt": None if args.mame_receipt is None else str(args.mame_receipt.resolve()),
            "receipt_sha256": None if args.mame_receipt is None else file_sha256(args.mame_receipt),
        },
        "candidate": {
            "trace": str(args.rtl_trace.resolve()),
            "trace_sha256": file_sha256(args.rtl_trace),
            "receipt": None if args.rtl_receipt is None else str(args.rtl_receipt.resolve()),
            "receipt_sha256": None if args.rtl_receipt is None else file_sha256(args.rtl_receipt),
        },
        "sound_bus": bus,
        "host_commits": {
            **commits,
            "mame_reconstruction": mame_commit_state,
        },
        "rtl_irq": rtl_irq_summary(args.rtl_trace, candidate_start, candidate_stop),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(json.dumps({
        "status": result["status"],
        "sound_bus": {
            "reference_count": bus["reference_count"],
            "candidate_count": bus["candidate_count"],
            "first_mismatch_index": None if bus["first_mismatch"] is None else bus["first_mismatch"]["index"],
        },
        "host_commits": {
            "reference_count": commits["reference_count"],
            "candidate_count": commits["candidate_count"],
            "first_mismatch_index": None if commits["first_mismatch"] is None else commits["first_mismatch"]["index"],
            "mame_malformed_groups": mame_commit_state["malformed"],
        },
        "output": str(args.output.resolve()),
    }, sort_keys=True))
    return 0 if result["status"] == "match" else 2


if __name__ == "__main__":
    raise SystemExit(main())
