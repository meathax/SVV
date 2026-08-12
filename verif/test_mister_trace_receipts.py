#!/usr/bin/env python3
"""Fail-closed tests for raw trace completeness receipts."""

import json
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from misterlib.traces import TraceError, normalize_trace  # noqa: E402


CONTRACT = {
    "rules": {"require_complete_receipt": True},
    "domains": {
        "mainbus": {
            "strict": True,
            "meaning": "completed V60 bus transaction",
            "ordering": "domain_seq",
            "global_order_proven": False,
            "canonical": {"width_bits": 16, "phase": "completed"},
            "mame": {
                "address_unit_bytes": 1, "width_bits": 16,
                "data_encoding": "lane_numeric", "lane_to_canonical": [0, 1],
                "byte_enable_polarity": "active_high", "phase": "completed",
                "evidence": "unit-test",
            },
            "rtl": {
                "address_unit_bytes": 1, "width_bits": 16,
                "data_encoding": "lane_numeric", "lane_to_canonical": [0, 1],
                "byte_enable_polarity": "active_high", "phase": "completed",
                "evidence": "unit-test",
            },
            "comparable_optional_fields": [],
        }
    },
}


def event(seq=0):
    return {"domain": "mainbus", "seq": seq, "event": "bus",
            "phase": "completed", "rw": "W", "address": 0x100000,
            "data": 0x1234, "byte_enable": 3}


class ReceiptTests(unittest.TestCase):
    def run_case(self, rows):
        with tempfile.TemporaryDirectory(dir=ROOT / "tmp") as td:
            raw = Path(td) / "raw.jsonl"
            out = Path(td) / "normalized.jsonl"
            raw.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
            return normalize_trace(raw, out, side="rtl", contract=CONTRACT,
                                   selected_domains=["mainbus"])

    def test_verified_receipt_passes(self):
        report = self.run_case([
            event(),
            {"record": "barrier", "name": "stop", "phase": "completed",
             "counts": {"mainbus": 1}},
            {"record": "receipt", "reason": "stop", "complete": True,
             "dropped": 0, "counts": {"mainbus": 1}},
        ])
        self.assertTrue(report["receipt_verified"])
        self.assertEqual(report["barrier_count"], 1)

    def test_missing_receipt_fails(self):
        with self.assertRaisesRegex(TraceError, "missing its final completeness receipt"):
            self.run_case([event()])

    def test_count_mismatch_fails(self):
        with self.assertRaisesRegex(TraceError, "receipt count"):
            self.run_case([
                event(),
                {"record": "barrier", "name": "stop", "counts": {"mainbus": 1}},
                {"record": "receipt", "complete": True, "dropped": 0,
                 "counts": {"mainbus": 0}},
            ])

    def test_event_after_receipt_fails(self):
        with self.assertRaisesRegex(TraceError, "event appears after final receipt"):
            self.run_case([
                event(),
                {"record": "barrier", "name": "stop", "counts": {"mainbus": 1}},
                {"record": "receipt", "complete": True, "dropped": 0,
                 "counts": {"mainbus": 1}},
                event(1),
            ])


if __name__ == "__main__":
    unittest.main()
