#!/usr/bin/env python3
"""Streaming strict comparator for very large SSV canonical traces.

This is the bounded-memory counterpart to ``compare_ssv_strict.py``.  It
keeps the same ordinal and ``cpu_data_lane_mask_v1`` contract, but consumes
both traces incrementally so a full MAME capture does not have to be loaded
into RAM.  It still reads to both receipts before reporting a verdict; a
first mismatch alone is never accepted as a complete comparison.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import deque
from pathlib import Path
from typing import Iterator


FIELDS = ("event", "phase", "rw", "address", "data", "byte_enable", "device")


def normalize_event(event: dict, domain: str) -> dict:
    projected = dict(event)
    if domain == "cpu_data":
        byte_enable = event.get("byte_enable")
        data = event.get("data")
        if isinstance(byte_enable, int) and isinstance(data, int):
            lane_mask = (0x00FF if byte_enable & 1 else 0) | \
                (0xFF00 if byte_enable & 2 else 0)
            projected["data"] = data & lane_mask
    return projected


def projected_digest_update(digest: "hashlib._Hash", event: dict) -> None:
    digest.update((json.dumps(
        {key: event.get(key) for key in FIELDS},
        sort_keys=True,
        separators=(",", ":"),
    ) + "\n").encode("utf-8"))


class TraceStream:
    def __init__(self, path: Path, domain: str, context: int) -> None:
        self.path = path
        self.domain = domain
        self.context = context
        self.file_digest = hashlib.sha256()
        self.projected_digest = hashlib.sha256()
        self.events = 0
        self.last_seq: int | None = None
        self.receipt: dict | None = None
        self.stop = False
        self.line_number = 0
        self.before: deque[dict] = deque(maxlen=context)
        self.current: dict | None = None
        self._stream = path.open("rb")

    def __iter__(self) -> Iterator[dict]:
        try:
            for raw in self._stream:
                self.line_number += 1
                self.file_digest.update(raw)
                try:
                    line = raw.decode("utf-8").strip()
                except UnicodeDecodeError as error:
                    raise ValueError(
                        f"{self.path}:{self.line_number}: invalid UTF-8: {error}"
                    ) from error
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError as error:
                    raise ValueError(
                        f"{self.path}:{self.line_number}: invalid JSON: {error}"
                    ) from error
                if item.get("record") == "barrier" and item.get("name") == "stop":
                    self.stop = True
                elif item.get("record") == "receipt":
                    if self.receipt is not None:
                        raise ValueError(f"{self.path}: duplicate receipt")
                    self.receipt = item
                elif item.get("domain") == "mainbus" and self.domain in {"mainbus", "cpu_data"}:
                    if self.domain == "cpu_data" and item.get("device") == 1:
                        continue
                    sequence = item.get("seq")
                    if not isinstance(sequence, int):
                        raise ValueError(
                            f"{self.path}:{self.line_number}: {self.domain} event has no integer seq"
                        )
                    if self.last_seq is not None and sequence <= self.last_seq:
                        raise ValueError(
                            f"{self.path}:{self.line_number}: {self.domain} sequence is not increasing"
                        )
                    if self.domain == "mainbus" and sequence != self.events:
                        raise ValueError(
                            f"{self.path}:{self.line_number}: mainbus seq {sequence} != {self.events}"
                        )
                    event = normalize_event(item, self.domain)
                    projected_digest_update(self.projected_digest, event)
                    self.last_seq = sequence
                    self.events += 1
                    self.current = event
                    yield event
                    self.before.append(event)
        finally:
            self._stream.close()

    def finish(self) -> None:
        if self.receipt is None or self.receipt.get("complete") is not True:
            raise ValueError(f"{self.path}: missing complete receipt")
        if self.receipt.get("dropped") != 0:
            raise ValueError(
                f"{self.path}: receipt reports dropped={self.receipt.get('dropped')}"
            )
        if not self.stop:
            raise ValueError(f"{self.path}: missing stop barrier")
        reported = self.receipt.get("counts", {}).get(self.domain)
        if reported is not None and reported != self.events:
            raise ValueError(
                f"{self.path}: receipt {self.domain} count {reported} != trace {self.events}"
            )
        if self.domain == "cpu_data":
            reported_mainbus = self.receipt.get("counts", {}).get("mainbus")
            if not isinstance(reported_mainbus, int) or reported_mainbus < self.events:
                raise ValueError(
                    f"{self.path}: receipt mainbus count cannot cover cpu_data projection"
                )

    def metadata(self) -> dict:
        return {
            "path": str(self.path.resolve()),
            "file_sha256": self.file_digest.hexdigest(),
            "projected_sha256": self.projected_digest.hexdigest(),
            "events": self.events,
            "receipt": self.receipt,
        }


def compare(reference: Path, candidate: Path, domain: str, context: int) -> dict:
    left = TraceStream(reference, domain, context)
    right = TraceStream(candidate, domain, context)
    left_iter = iter(left)
    right_iter = iter(right)
    first_bad: int | None = None
    first_reference: dict | None = None
    first_candidate: dict | None = None
    reference_context: list[dict] = []
    candidate_context: list[dict] = []
    ordinal = 0
    while True:
        ref = next(left_iter, None)
        cand = next(right_iter, None)
        if ref is None or cand is None:
            if ref is not None or cand is not None:
                if first_bad is None:
                    first_bad = ordinal
                    first_reference = ref
                    first_candidate = cand
                    reference_context = list(left.before)
                    candidate_context = list(right.before)
            break
        if first_bad is None and any(ref.get(key) != cand.get(key) for key in FIELDS):
            first_bad = ordinal
            first_reference = ref
            first_candidate = cand
            reference_context = list(left.before)
            candidate_context = list(right.before)
        ordinal += 1
    # Continue consuming each side after a length mismatch so both full
    # receipts/counts and source digests are still verified.
    if ref is not None:
        for _ in left_iter:
            pass
    if cand is not None:
        for _ in right_iter:
            pass
    left.finish()
    right.finish()
    result = {
        "schema": "ssv-strict-stream-comparator-v1",
        "status": "match" if first_bad is None and left.events == right.events else "mismatch",
        "domain": domain,
        "normalization": "cpu_data_lane_mask_v1" if domain == "cpu_data" else "raw_event_fields_v1",
        "matching_prefix": left.events if first_bad is None else first_bad,
        "first_bad_ordinal": first_bad,
        "reference": first_reference,
        "candidate": first_candidate,
        "reference_context": reference_context,
        "candidate_context": candidate_context,
        "reference_trace": left.metadata(),
        "candidate_trace": right.metadata(),
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--domain", default="mainbus")
    parser.add_argument("--context", type=int, default=3)
    parser.add_argument("--receipt-out", type=Path)
    args = parser.parse_args()
    if args.context < 0:
        parser.error("--context must be non-negative")
    try:
        result = compare(args.reference, args.candidate, args.domain, args.context)
    except ValueError as error:
        parser.exit(2, f"compare error: {error}\n")
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.receipt_out:
        args.receipt_out.parent.mkdir(parents=True, exist_ok=True)
        args.receipt_out.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0 if result["status"] == "match" else 1


if __name__ == "__main__":
    raise SystemExit(main())
