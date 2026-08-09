#!/usr/bin/env python3
"""Classify SSV bus-trace semantics independently of presentation-frame phase."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


SEMANTIC_KEYS = ("cpu", "event", "rw", "address", "data", "lanes", "device")
ANCHOR_KEYS = SEMANTIC_KEYS + ("pc", "psw")


def event_key(event: dict, keys: tuple[str, ...] = SEMANTIC_KEYS) -> tuple:
    return tuple(event.get(key) for key in keys)


def load_events(path: Path, start_frame: int | None = None,
                end_frame: int | None = None) -> list[dict]:
    events = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"invalid JSONL {path}:{line_number}: {error}") from error
            frame = event.get("frame")
            if start_frame is not None and frame < start_frame:
                continue
            if end_frame is not None and frame > end_frame:
                continue
            events.append(event)
    return events


def signature(events: list[dict], position: int, length: int,
              keys: tuple[str, ...]) -> tuple:
    return tuple(event_key(event, keys) for event in events[position:position + length])


def find_anchor(left: list[dict], right: list[dict], left_pos: int,
                right_pos: int, lookahead: int, anchor_length: int) -> tuple[int, int] | None:
    left_stop = min(len(left) - anchor_length + 1, left_pos + lookahead + 1)
    right_stop = min(len(right) - anchor_length + 1, right_pos + lookahead + 1)
    if left_stop <= left_pos or right_stop <= right_pos:
        return None

    for keys in (ANCHOR_KEYS, SEMANTIC_KEYS):
        left_map: dict[tuple, list[int]] = {}
        right_map: dict[tuple, list[int]] = {}
        for position in range(left_pos, left_stop):
            left_map.setdefault(signature(left, position, anchor_length, keys), []).append(position)
        for position in range(right_pos, right_stop):
            right_map.setdefault(signature(right, position, anchor_length, keys), []).append(position)
        candidates = []
        for value in left_map.keys() & right_map.keys():
            if len(left_map[value]) == 1 and len(right_map[value]) == 1:
                lp, rp = left_map[value][0], right_map[value][0]
                if lp != left_pos or rp != right_pos:
                    candidates.append((max(lp - left_pos, rp - right_pos),
                                       (lp - left_pos) + (rp - right_pos), lp, rp))
        if candidates:
            _, _, lp, rp = min(candidates)
            return lp, rp
    return None


def block_digest(events: list[dict]) -> str:
    payload = json.dumps(
        [event_key(event, SEMANTIC_KEYS) for event in events],
        separators=(",", ":"), ensure_ascii=True,
    ).encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def block_summary(side: str, events: list[dict], prefix: bool = False,
                  tail: bool = False) -> dict:
    context_keys = ("frame", "cycle", "pc", "psw") + SEMANTIC_KEYS
    compact = lambda event: {key: event.get(key) for key in context_keys}
    return {
        "side": side,
        "count": len(events),
        "sha256": block_digest(events),
        "prefix": prefix,
        "tail": tail,
        "first": compact(events[0]) if events else None,
        "last": compact(events[-1]) if events else None,
        "_keys": [event_key(event, SEMANTIC_KEYS) for event in events],
    }


def subsequence_count(haystack: list[tuple], needle: list[tuple]) -> int:
    if not needle or len(needle) > len(haystack):
        return 0
    count = 0
    position = 0
    while position <= len(haystack) - len(needle):
        if haystack[position:position + len(needle)] == needle:
            count += 1
            position += len(needle)
        else:
            position += 1
    return count


def compare_streams(reference: list[dict], rtl: list[dict], *,
                    lookahead: int = 16384, anchor_length: int = 8,
                    allow_trailing_incomplete: bool = False) -> dict:
    if anchor_length < 2 or lookahead < anchor_length:
        raise ValueError("anchor length must be >=2 and fit within lookahead")

    ri = ti = 0
    matched = 0
    runs: list[int] = []
    blocks: list[dict] = []
    first_gap = True
    while ri < len(reference) and ti < len(rtl):
        run = 0
        while (ri < len(reference) and ti < len(rtl) and
               event_key(reference[ri]) == event_key(rtl[ti])):
            ri += 1
            ti += 1
            run += 1
        if run:
            runs.append(run)
            matched += run
            first_gap = False
        if ri == len(reference) or ti == len(rtl):
            break
        anchor = find_anchor(reference, rtl, ri, ti, lookahead, anchor_length)
        if anchor is None:
            blocks.append(block_summary("reference", reference[ri:], prefix=first_gap))
            blocks.append(block_summary("rtl", rtl[ti:], prefix=first_gap))
            ri, ti = len(reference), len(rtl)
            break
        next_ri, next_ti = anchor
        if next_ri > ri:
            blocks.append(block_summary("reference", reference[ri:next_ri],
                                        prefix=first_gap))
        if next_ti > ti:
            blocks.append(block_summary("rtl", rtl[ti:next_ti], prefix=first_gap))
        ri, ti = next_ri, next_ti

    if ri < len(reference):
        blocks.append(block_summary("reference", reference[ri:], tail=True))
    if ti < len(rtl):
        blocks.append(block_summary("rtl", rtl[ti:], tail=True))

    reference_blocks = Counter(
        (block["sha256"], block["count"]) for block in blocks
        if block["side"] == "reference" and not block["prefix"] and
        (not block["tail"] or not allow_trailing_incomplete))
    rtl_blocks = Counter(
        (block["sha256"], block["count"]) for block in blocks
        if block["side"] == "rtl" and not block["prefix"] and
        (not block["tail"] or not allow_trailing_incomplete))
    paired = reference_blocks & rtl_blocks
    paired_count = sum(paired.values())
    unpaired_reference = reference_blocks - paired
    unpaired_rtl = rtl_blocks - paired
    prefix_incomplete = any(block["prefix"] for block in blocks)
    trailing_incomplete = allow_trailing_incomplete and any(
        block["tail"] for block in blocks)
    repeated_boundary_excess = 0
    if trailing_incomplete:
        # A periodic IRQ block may occur once more on the faster producer
        # before the other trace reaches the capture boundary.  Only relax a
        # block identity already observed exactly on both sides; a novel or
        # changed block remains a semantic divergence.
        for key in list(unpaired_reference):
            if key in paired:
                repeated_boundary_excess += unpaired_reference.pop(key)
        for key in list(unpaired_rtl):
            if key in paired:
                repeated_boundary_excess += unpaired_rtl.pop(key)
        # A moved block can be wholly contained inside the opposite producer's
        # unmatched tail.  Pair only an exact strong-key subsequence; do not
        # weaken or truncate a changed event to manufacture a match.
        for counter, side, opposite in (
                (unpaired_reference, "reference", "rtl"),
                (unpaired_rtl, "rtl", "reference")):
            for key in list(counter):
                sample = next(block["_keys"] for block in blocks
                              if block["side"] == side and not block["tail"] and
                              (block["sha256"], block["count"]) == key)
                available = sum(
                    subsequence_count(block["_keys"], sample) for block in blocks
                    if block["side"] == opposite and block["tail"])
                paired_at_boundary = min(counter[key], available)
                if paired_at_boundary:
                    counter[key] -= paired_at_boundary
                    repeated_boundary_excess += paired_at_boundary
                    if counter[key] == 0:
                        del counter[key]
    unpaired = bool(unpaired_reference or unpaired_rtl)

    if not blocks:
        verdict = "exact_order"
    elif not unpaired and not prefix_incomplete and not trailing_incomplete:
        verdict = "timing_interleavings"
    elif (prefix_incomplete or trailing_incomplete) and not unpaired:
        verdict = "alignment_inconclusive"
    else:
        verdict = "semantic_divergence"
    result = {
        "schema": "ssv-trace-semantics-v1",
        "verdict": verdict,
        "trace_semantics_equal": verdict in ("exact_order", "timing_interleavings"),
        "trace_order_equal": verdict == "exact_order",
        "reference_events": len(reference),
        "rtl_events": len(rtl),
        "matched_events": matched,
        "matching_runs": len(runs),
        "longest_matching_run": max(runs, default=0),
        "timing_interleavings": paired_count,
        "repeated_boundary_interleavings": repeated_boundary_excess,
        "alignment_prefix_incomplete": prefix_incomplete,
        "trailing_evidence_incomplete": trailing_incomplete,
        "semantic_divergence_detected": unpaired,
        "unpaired_reference_blocks": sum(unpaired_reference.values()),
        "unpaired_rtl_blocks": sum(unpaired_rtl.values()),
        "blocks": blocks,
    }
    for block in blocks:
        del block["_keys"]
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--rtl", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--end-frame", type=int)
    parser.add_argument("--lookahead", type=int, default=16384)
    parser.add_argument("--anchor-length", type=int, default=8)
    parser.add_argument(
        "--allow-trailing-incomplete", action="store_true",
        help="treat an unmatched capture tail as incomplete evidence, not a proven insertion",
    )
    args = parser.parse_args()
    result = compare_streams(
        load_events(args.reference, args.start_frame, args.end_frame),
        load_events(args.rtl, args.start_frame, args.end_frame),
        lookahead=args.lookahead, anchor_length=args.anchor_length,
        allow_trailing_incomplete=args.allow_trailing_incomplete,
    )
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if result["trace_semantics_equal"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
