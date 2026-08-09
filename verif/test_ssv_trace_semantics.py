#!/usr/bin/env python3
"""Focused regressions for cumulative SSV bus-trace classification."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ssv_trace_semantics", ROOT / "tools" / "ssv_trace_semantics.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def event(sequence: int, *, data: int | None = None, frame: int = 1) -> dict:
    return {
        "frame": frame, "cycle": sequence, "pc": 0x1000 + sequence,
        "psw": 0x10000000, "cpu": 0, "event": "bus", "rw": "w",
        "address": 0x100000 + sequence * 2,
        "data": sequence if data is None else data, "lanes": 3, "device": 2,
    }


def main() -> int:
    mainline = [event(i) for i in range(20)]
    irq = [event(100 + i) for i in range(8)]
    reference = mainline[:8] + irq + mainline[8:]
    rtl = mainline + irq
    result = MODULE.compare_streams(reference, rtl, lookahead=64, anchor_length=4)
    assert result["verdict"] == "timing_interleavings", result
    assert result["trace_semantics_equal"] and not result["trace_order_equal"]

    # A faster trace can enter one extra instance of an already-paired IRQ
    # block before capture ends.  With explicit trailing-incomplete policy it
    # is inconclusive phase evidence, not a novel semantic insertion.
    result = MODULE.compare_streams(
        reference, rtl + irq + [event(300)], lookahead=64, anchor_length=4,
        allow_trailing_incomplete=True)
    assert not result["semantic_divergence_detected"], result
    assert result["trailing_evidence_incomplete"], result

    changed_irq = [dict(item) for item in irq]
    changed_irq[3]["data"] ^= 1
    result = MODULE.compare_streams(reference, mainline + changed_irq,
                                    lookahead=64, anchor_length=4)
    assert result["verdict"] == "semantic_divergence", result

    rebucketed = [dict(item, frame=2) for item in reference]
    result = MODULE.compare_streams(reference, rebucketed,
                                    lookahead=64, anchor_length=4)
    assert result["verdict"] == "exact_order", result

    one_sided = reference + [event(200)]
    result = MODULE.compare_streams(reference, one_sided,
                                    lookahead=64, anchor_length=4)
    assert result["verdict"] == "semantic_divergence", result

    print("PASS cumulative trace rebucketing, interleaving, and semantic divergence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
