#!/usr/bin/env python3
"""Audit every shipped SSV MRA against the core's video/rotation contract.

This is a release metadata and integration check.  It does not claim that a
Direct Video output can rotate a landscape display: Direct Video is the raw
native raster, while MiSTer framebuffer rotation is the non-Direct-Video
presentation path.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from ssv_supported_sets import SUPPORTED_SETS


ROOT = Path(__file__).resolve().parents[1]
RELEASES = ROOT / "releases"
TOP = ROOT / "Arcade-SSV.sv"

EXPECTED_ROTATION = {
    "dynagear": "horizontal",
    "cairblad": "vertical (ccw)",
    "vasara": "vertical (ccw)",
    "vasara2": "vertical (ccw)",
    "drifto94": "horizontal",
    "stmblade": "vertical (ccw)",
    "twineag2": "vertical (ccw)",
    "ultrax": "vertical (ccw)",
}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def main() -> int:
    mras = sorted(RELEASES.glob("*.mra"))
    if len(mras) != len(SUPPORTED_SETS):
        fail(f"release MRA count {len(mras)} differs from supported count {len(SUPPORTED_SETS)}")

    source = TOP.read_text(encoding="utf-8")
    required_source = {
        '"H0O[50:49],Rotation,': "Direct Video hides framebuffer rotation",
        ".direct_video(direct_video)": "hps_io Direct Video connection",
        "wire rotation_active = !direct_video": "Direct Video-native aspect policy",
        ".no_rotate(direct_video ||": "Direct Video disables DDRAM rotation",
    }
    for needle, description in required_source.items():
        if needle not in source:
            fail(f"missing {description}: {needle}")

    seen_sets = set()
    for path in mras:
        root = ET.parse(path).getroot()
        setname = root.findtext("setname")
        if setname not in SUPPORTED_SETS:
            fail(f"{path.name}: unexpected setname {setname!r}")
        if setname in seen_sets:
            fail(f"duplicate MRA setname {setname!r}")
        seen_sets.add(setname)
        if root.findtext("rbf") != "Arcade-SSV":
            fail(f"{path.name}: stale or incorrect RBF name")
        if root.findtext("resolution") != "15kHz":
            fail(f"{path.name}: resolution must be 15kHz")
        rotation = root.findtext("rotation")
        if rotation != EXPECTED_ROTATION[setname]:
            fail(
                f"{path.name}: rotation {rotation!r}, "
                f"expected {EXPECTED_ROTATION[setname]!r}"
            )
        rom0 = next((rom for rom in root.findall("rom") if rom.get("index") == "0"), None)
        if rom0 is None or rom0.get("address") != "0x30000000":
            fail(f"{path.name}: ROM index 0 is missing DDR fast-load address")
        descriptor = next((rom for rom in root.findall("rom") if rom.get("index") == "1"), None)
        if descriptor is None:
            fail(f"{path.name}: missing index-1 descriptor")
        part = descriptor.findtext("part") or ""
        if len(part) != 48 or any(character not in "0123456789abcdefABCDEF" for character in part):
            fail(f"{path.name}: index-1 descriptor is not exactly 24 bytes")

        direct_result = (
            "raw native raster; physical CRT rotation required"
            if rotation.startswith("vertical")
            else "raw native horizontal raster"
        )
        framebuffer_result = "DDRAM framebuffer rotation available when direct_video=0"
        print(f"PASS {setname:8} {rotation:15} Direct Video: {direct_result}; {framebuffer_result}")

    if seen_sets != set(SUPPORTED_SETS):
        fail(f"MRA setnames differ from SUPPORTED_SETS: {sorted(seen_sets)}")

    print(f"PASS video integration contract and {len(mras)} shipped game profiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
