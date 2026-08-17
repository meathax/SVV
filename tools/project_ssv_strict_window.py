#!/usr/bin/env python3
"""Project a bounded, source-preserving SSV bus window for strict comparison.

The full gameplay traces intentionally keep only bounded diagnostic bus windows
because an unbounded MAME cpu_data stream is multi-gigabyte.  This projector
does not resynchronise, rewrite or synthesize bus events: it copies source
records selected by their native frame field, excludes device 1 only for the
declared cpu_data projection, and emits a receipt that binds the selection and
source digest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--frame-start", type=int, required=True)
    parser.add_argument("--frame-stop", type=int, required=True)
    parser.add_argument("--domain", choices=("cpu_data",), default="cpu_data")
    args = parser.parse_args()
    if args.frame_start < 0 or args.frame_stop < args.frame_start:
        raise ValueError("invalid frame selection")

    source_digest = sha256(args.source)
    contract: dict | None = None
    events: list[dict] = []
    for number, line in enumerate(args.source.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{args.source}:{number}: invalid JSON: {error}") from error
        if item.get("record") == "contract":
            if contract is not None:
                raise ValueError(f"{args.source}: multiple contract records")
            contract = item
            continue
        if item.get("domain") != "mainbus":
            continue
        frame = item.get("frame")
        if not isinstance(frame, int) or not args.frame_start <= frame <= args.frame_stop:
            continue
        if args.domain == "cpu_data" and item.get("device") == 1:
            continue
        events.append(item)

    if contract is None:
        raise ValueError(f"{args.source}: missing contract record")
    if not events:
        raise ValueError(f"{args.source}: selected window contains no events")
    sequences = [event.get("seq") for event in events]
    if any(not isinstance(seq, int) for seq in sequences):
        raise ValueError(f"{args.source}: selected event lacks integer seq")
    if any(left >= right for left, right in zip(sequences, sequences[1:])):
        raise ValueError(f"{args.source}: selected event sequence is not increasing")

    projected_contract = dict(contract)
    projected_contract.update({
        "projection": "ssv-strict-window-v1",
        "projection_domain": args.domain,
        "projection_frame_start": args.frame_start,
        "projection_frame_stop": args.frame_stop,
        "projection_source_sha256": source_digest,
    })
    receipt = {
        "record": "receipt",
        "schema": "ssv-strict-window-receipt-v1",
        "reason": "stop_barrier",
        "complete": True,
        "dropped": 0,
        "domain": args.domain,
        "counts": {"mainbus": len(events), "cpu_data": len(events)},
        "source": str(args.source.resolve()),
        "source_sha256": source_digest,
        "frame_start": args.frame_start,
        "frame_stop": args.frame_stop,
        "event_count": len(events),
    }
    output = args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(projected_contract, separators=(",", ":")) + "\n")
        for event in events:
            stream.write(json.dumps(event, separators=(",", ":")) + "\n")
        stream.write(json.dumps({
            "record": "barrier", "name": "stop", "phase": "completed",
            "domain": args.domain, "frame_start": args.frame_start,
            "frame_stop": args.frame_stop, "events": len(events),
        }, separators=(",", ":")) + "\n")
        stream.write(json.dumps(receipt, separators=(",", ":")) + "\n")
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
