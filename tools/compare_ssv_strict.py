#!/usr/bin/env python3
"""Strict, ordinal SSV canonical trace comparator.

Acceptance comparison never searches, skips or resynchronizes. Diagnostic
alignment remains in ssv_trace_semantics.py and its output is never accepted by
this tool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

FIELDS = ("event", "phase", "rw", "address", "data", "byte_enable", "device")


def normalization_contract(domain: str) -> str:
    """Name the immutable projection applied before ordinal comparison."""
    if domain == "cpu_data":
        return "cpu_data_lane_mask_v1"
    return "raw_event_fields_v1"


def normalize_event(event: dict, domain: str) -> dict:
    """Return the comparison projection without rewriting source artifacts.

    The SSV 16-bit bus reports a byte-enable alongside a 16-bit data sample.
    For cpu_data, bits on an unselected lane are not part of the transaction:
    MAME's address-space tap already clears them while the RTL probe exposes
    the complete read word.  Keep mainbus raw for diagnostics and apply this
    explicit lane contract only to the strict acceptance projection.
    """
    projected = dict(event)
    if domain == "cpu_data":
        byte_enable = event.get("byte_enable")
        data = event.get("data")
        if isinstance(byte_enable, int) and isinstance(data, int):
            lane_mask = (0x00FF if byte_enable & 1 else 0) | \
                        (0xFF00 if byte_enable & 2 else 0)
            projected["data"] = data & lane_mask
    return projected


def load(path: Path, domain: str) -> tuple[list[dict], dict, bool]:
    events: list[dict] = []
    receipt: dict | None = None
    stop = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{number}: invalid JSON: {error}") from error
        if item.get("record") == "barrier" and item.get("name") == "stop":
            stop = True
        elif item.get("record") == "receipt":
            receipt = item
        elif item.get("domain") == "mainbus" and domain in {"mainbus", "cpu_data"}:
            # MAME observes program-space reads at a different granularity from
            # the RTL V60's 64-bit instruction fills.  cpu_data is therefore the
            # strict acceptance projection of the shared 16-bit bus: exclude
            # device 1 (program ROM) but retain every completed device/data
            # transaction from reset onward.  mainbus remains the diagnostic
            # full-space domain.
            if domain == "cpu_data" and item.get("device") == 1:
                continue
            expected = len(events)
            sequence = item.get("seq")
            if not isinstance(sequence, int):
                raise ValueError(f"{path}:{number}: {domain} event has no integer seq")
            if events and sequence <= events[-1].get("seq", -1):
                raise ValueError(f"{path}:{number}: {domain} sequence is not increasing")
            if domain == "mainbus" and sequence != expected:
                raise ValueError(
                    f"{path}:{number}: {domain} seq {sequence} != {expected}"
                )
            events.append(normalize_event(item, domain))
    if receipt is None or receipt.get("complete") is not True:
        raise ValueError(f"{path}: missing complete receipt")
    if receipt.get("dropped") != 0:
        raise ValueError(f"{path}: receipt reports dropped={receipt.get('dropped')}")
    if not stop:
        raise ValueError(f"{path}: missing stop barrier")
    reported = receipt.get("counts", {}).get(domain)
    if reported is not None and reported != len(events):
        raise ValueError(f"{path}: receipt {domain} count does not match trace")
    if domain == "cpu_data":
        reported_mainbus = receipt.get("counts", {}).get("mainbus")
        if not isinstance(reported_mainbus, int) or reported_mainbus < len(events):
            raise ValueError(f"{path}: receipt mainbus count cannot cover cpu_data projection")
    return events, receipt, stop


def digest(events: list[dict]) -> str:
    normalized = "".join(
        json.dumps({key: event.get(key) for key in FIELDS}, sort_keys=True,
                   separators=(",", ":")) + "\n"
        for event in events
    )
    return hashlib.sha256(normalized.encode()).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--domain", default="mainbus")
    parser.add_argument("--context", type=int, default=3)
    args = parser.parse_args()
    left, _, _ = load(args.reference, args.domain)
    right, _, _ = load(args.candidate, args.domain)
    provenance = {
        "reference_path": str(args.reference.resolve()),
        "reference_sha256": sha256_file(args.reference),
        "candidate_path": str(args.candidate.resolve()),
        "candidate_sha256": sha256_file(args.candidate),
    }
    common = min(len(left), len(right))
    mismatch = next(
        (index for index in range(common)
         if any(left[index].get(key) != right[index].get(key) for key in FIELDS)),
        None,
    )
    if mismatch is None and len(left) == len(right):
        print(json.dumps({
            "status": "match", "domain": args.domain, "events": len(left),
            "digest": digest(left), "resynchronized": False,
            "normalization": normalization_contract(args.domain),
            **provenance,
        }, sort_keys=True))
        return 0
    index = mismatch if mismatch is not None else common
    lo = max(0, index - args.context)
    hi = min(max(len(left), len(right)), index + args.context + 1)
    report = {
        "status": "mismatch",
        "domain": args.domain,
        "first_bad_ordinal": index,
        "matching_prefix": index,
        "reference_events": len(left),
        "candidate_events": len(right),
        "fields": list(FIELDS),
        "normalization": normalization_contract(args.domain),
        "reference": left[index] if index < len(left) else None,
        "candidate": right[index] if index < len(right) else None,
        "reference_context": left[lo:min(hi, len(left))],
        "candidate_context": right[lo:min(hi, len(right))],
        "resynchronized": False,
        **provenance,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
