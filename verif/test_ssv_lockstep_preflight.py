#!/usr/bin/env python3
"""Focused static checks for lockstep reference-source provenance."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from ssv_lockstep_preflight import executable_source_tag  # noqa: E402


def main() -> int:
    assert executable_source_tag("0.288 (mame0288)") == "mame0288"
    assert executable_source_tag("0.289 (unknown)") == "mame0289"
    assert executable_source_tag("MAME 1.7") == "mame1007"
    assert executable_source_tag("unversioned") is None
    print("PASS MAME executable version to exact source-tag binding")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
