#!/usr/bin/env python3
"""Focused immutable RTL input-journal identity regression."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from ssv_input_journal import inspect_journal, seed_neutral, stage_journal  # noqa: E402


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ssv-input-journal-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staged = root / "staged"
        seed_neutral(source)
        # The production proof restores a checkpoint committed at token 849;
        # its already-applied masks are packet 850 for MAME's final catch-up.
        for frame in range(1, 851):
            packet = {
                "frame": frame, "p1_pressed": frame,
                "p2_pressed": 0, "system_pressed": 0,
                "source": "rtl-owner",
            }
            (source / f"frame_{frame:06d}.json").write_text(
                json.dumps(packet), encoding="utf-8"
            )
        identity = inspect_journal(source, 850)
        assert json.loads((source / "frame_000850.json").read_text())["frame"] == 850
        staged_identity = stage_journal(source, staged, 850)
        assert identity["semantic_sha256"] == staged_identity["semantic_sha256"]
        assert inspect_journal(staged, 850)["semantic_sha256"] == identity["semantic_sha256"]
        bad = json.loads((source / "frame_000850.json").read_text())
        bad["source"] = "reference"
        (source / "frame_000850.json").write_text(json.dumps(bad), encoding="utf-8")
        try:
            inspect_journal(source, 850)
        except ValueError as error:
            assert "source must be" in str(error)
        else:
            raise AssertionError("non-RTL packet ownership was accepted")
    print("PASS RTL input journal identity, staging, and ownership rejection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
