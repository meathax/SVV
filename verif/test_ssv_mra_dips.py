#!/usr/bin/env python3
"""Focused parser checks for MAME DIP declarations used by the SSV MRAs."""

from pathlib import Path
import os
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

EXPECTED_BUTTONS = {
    "dynagear": ("Jump,Attack,-,-,-,-,Test,Service,Start,Coin", 2),
    "cairblad": ("Fire,Bomb,Special,-,-,-,Test,Service,Start,Coin", 3),
    "vasara": ("Attack,Bomb,-,-,-,-,Test,Service,Start,Coin", 2),
    "vasara2": ("Attack,Vasara Attack,-,-,-,-,Test,Service,Start,Coin", 2),
    "drifto94": ("Accelerate,Brake,-,-,-,-,Test,Service,Start,Coin", 2),
    "stmblade": ("Fire,Bomb,-,-,-,-,Test,Service,Start,Coin", 2),
    "twineag2": ("Cannon,Ground Attack,Bomb,-,-,-,Test,Service,Start,Coin", 3),
    "ultrax": ("Fire,Grenade,Bomb,-,-,-,Test,Service,Start,Coin", 3),
    "survarts": (
        "Weak Punch,Medium Punch,Strong Punch,Weak Kick,Medium Kick,"
        "Strong Kick,Test,Service,Start,Coin",
        6,
    ),
    "survartsu": (
        "Weak Punch,Medium Punch,Strong Punch,Weak Kick,Medium Kick,"
        "Strong Kick,Test,Service,Start,Coin",
        6,
    ),
    "survartsj": (
        "Weak Punch,Medium Punch,Strong Punch,Weak Kick,Medium Kick,"
        "Strong Kick,"
        "Test,Service,Start,Coin",
        6,
    ),
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
    source_root = Path(os.environ.get("SSV_MAME_SOURCE", r"D:\Arcade\AI\mame289"))
    source = source_root / "src" / "mame" / "seta" / "ssv.cpp"
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

    for setname, (expected_names, expected_count) in EXPECTED_BUTTONS.items():
        actual_names, _actual_default, actual_count = generator.BUTTONS[setname]
        assert actual_names == expected_names, (setname, actual_names)
        assert actual_count == expected_count, (setname, actual_count)

    source_rotations = mame_rotations(text)
    checked = []
    controls_checked = []
    for setname in SUPPORTED_SETS:
        mame_rotation = source_rotations[setname]
        expected = MAME_TO_MRA_ROTATION[mame_rotation]
        matches = []
        for path in sorted((ROOT / "releases").glob("*.mra")):
            root = ET.parse(path).getroot()
            if (root.findtext("setname") or "").strip() == setname:
                matches.append(path)
                actual = (root.findtext("rotation") or "").strip()
                assert actual == expected, (setname, mame_rotation, actual, expected)
                expected_names, expected_default, expected_count = generator.BUTTONS.get(
                    setname, generator.BUTTONS_DEFAULT
                )
                buttons = root.find("buttons")
                assert buttons is not None, setname
                assert buttons.get("names") == expected_names, (setname, buttons.attrib)
                assert buttons.get("default") == expected_default, (setname, buttons.attrib)
                assert buttons.get("count") == str(expected_count), (setname, buttons.attrib)
                assert len(expected_names.split(",")) == 10, expected_names
                controls_checked.append(setname)
        assert len(matches) == 1, (setname, matches)
        checked.append(setname)

    print("PASS cairblad/drifto94 implicit DIP defaults FF,FF")
    print(f"PASS {len(checked)} MRA rotations match MAME GAME declarations")
    print(f"PASS {len(controls_checked)} MRA control declarations match generator")
    print(f"PASS {len(EXPECTED_BUTTONS)} exact control mappings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
