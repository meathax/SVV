#!/usr/bin/env python3
"""Focused parser checks for MAME DIP declarations used by the SSV MRAs."""

from pathlib import Path
import re
import sys
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import gen_ssv_mras as generator  # noqa: E402
from ssv_supported_sets import SUPPORTED_SETS  # noqa: E402


MAME_TO_MRA_ROTATION = {
    "ROT0": "horizontal",
    "ROT270": "vertical (ccw)",
}


def mame_rotations(text: str) -> dict[str, str]:
    game_re = (
        r"^GAME\(\s*\d+\??\s*,\s*(\w+)\s*,\s*\w+\s*,"
        r".*?(ROT\d+)\s*,\s*\""
    )
    return {
        match.group(1): match.group(2)
        for match in re.finditer(game_re, text, re.M | re.S)
    }


def main() -> int:
    source = Path(r"D:\Arcade\AI\MAMESOURCE\mame\src\mame\seta\ssv.cpp")
    text = source.read_text(encoding="utf-8")
    default, lines, skipped = generator.dips_to_mra(
        generator.parse_dips(text, "cairblad")
    )
    assert default == "FF,FF", (default, lines, skipped)
    assert sum('name="Unused"' in line for line in lines) == 2, lines

    default, lines, skipped = generator.dips_to_mra(
        generator.parse_dips(text, "drifto94")
    )
    assert default == "FF,FF", (default, lines, skipped)
    assert sum('name="Unknown"' in line for line in lines) == 2, lines
    assert sum('name="Unused"' in line for line in lines) == 1, lines

    source_rotations = mame_rotations(text)
    checked = []
    for setname in SUPPORTED_SETS:
        mame_rotation = source_rotations[setname]
        expected = MAME_TO_MRA_ROTATION[mame_rotation]
        matches = []
        for path in sorted((ROOT / "mra").glob("*.mra")):
            root = ET.parse(path).getroot()
            if (root.findtext("setname") or "").strip() == setname:
                matches.append(path)
                actual = (root.findtext("rotation") or "").strip()
                assert actual == expected, (setname, mame_rotation, actual, expected)
        assert len(matches) == 1, (setname, matches)
        checked.append(setname)

    print("PASS cairblad/drifto94 implicit DIP defaults FF,FF")
    print(f"PASS {len(checked)} MRA rotations match MAME GAME declarations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
