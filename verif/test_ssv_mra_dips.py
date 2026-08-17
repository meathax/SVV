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
    "dynagear": ("Jump,Attack,-,-,-,-,Start,Coin,Service,Test", 2),
    "cairblad": ("Fire,Bomb,Special,-,-,-,Start,Coin,Service,Test", 3),
    "vasara": ("Attack,Bomb,Rapid Fire,-,-,-,Start,Coin,Service,Test", 3),
    "vasara2": ("Attack,Vasara Attack,Rapid Fire,-,-,-,Start,Coin,Service,Test", 3),
    "drifto94": ("Brake,Accelerate,-,-,-,-,Start,Coin,Service,Test", 2),
    "stmblade": ("Fire,Bomb,-,-,-,-,Start,Coin,Service,Test", 2),
    "twineag2": ("Cannon,Ground Attack,Bomb,-,-,-,Start,Coin,Service,Test", 3),
    "ultrax": ("Fire,Grenade,Bomb,-,-,-,Start,Coin,Service,Test", 3),
    "survarts": (
        "Weak Punch,Medium Punch,Strong Punch,Weak Kick,Medium Kick,"
        "Strong Kick,Start,Coin,Service,Test",
        6,
    ),
    "survartsu": (
        "Weak Punch,Medium Punch,Strong Punch,Weak Kick,Medium Kick,"
        "Strong Kick,Start,Coin,Service,Test",
        6,
    ),
    "survartsj": (
        "Weak Punch,Medium Punch,Strong Punch,Weak Kick,Medium Kick,"
        "Strong Kick,"
        "Start,Coin,Service,Test",
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

    # Dyna Gear's two switch banks are a release contract, not merely a
    # generated-MRA smoke check.  Keep the exact default and all ten fields
    # pinned to the MAME 0.289 declaration so a generator edit cannot silently
    # drop the health/free-play or four-way lives choices.
    dynagear_default, dynagear_lines, dynagear_skipped = generator.dips_to_mra(
        generator.parse_dips(text, "dynagear")
    )
    assert dynagear_default == "FF,FD", dynagear_default
    assert not dynagear_skipped, dynagear_skipped
    assert [
        re.search(r'name="([^"]+)"', line).group(1)
        for line in dynagear_lines if '<dip ' in line
    ] == [
        "Coin A", "Coin B", "Flip Screen", "Demo Sounds", "Difficulty",
        "Lives", "Free Play", "Health",
    ], dynagear_lines

    for setname, (expected_names, expected_count) in EXPECTED_BUTTONS.items():
        actual_names, _actual_default, actual_count = generator.BUTTONS[setname]
        assert actual_names == expected_names, (setname, actual_names)
        assert actual_count == expected_count, (setname, actual_count)

    wrapper = (ROOT / "Arcade-SSV.sv").read_text(encoding="utf-8")
    compact_wrapper = re.sub(r"\s+", "", wrapper)
    assert ('"J1,Fire,Jump,Button3,Button4,Button5,Button6,'
            'Start,Coin,Service,Test;"') in compact_wrapper
    assert "wiretest_button=status[6]|joy_p1[13]|joy_p2[13];" in compact_wrapper
    assert "wireservice_button=joy_p1[12]|joy_p2[12];" in compact_wrapper
    assert "wirecoin1_button=joy_p1[11];" in compact_wrapper
    assert "wirecoin2_button=joy_p2[11];" in compact_wrapper
    mame_lua = (ROOT / "tools" / "mame-ssv-headless.lua").read_text(
        encoding="utf-8"
    )
    assert '[0x10]={"Test"}' in mame_lua
    assert 'local extra = (setname == "survartsu") and ports[":ADD_BUTTONS"] or nil' in mame_lua
    assert '[0x100]={"P1 Button 4"}' in mame_lua
    assert '[0x200]={"P1 Button 5"}' in mame_lua
    assert '[0x400]={"P1 Button 6"}' in mame_lua
    assert '[0x100]={"P2 Button 4"}' in mame_lua
    assert '[0x200]={"P2 Button 5"}' in mame_lua
    assert '[0x400]={"P2 Button 6"}' in mame_lua

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
    print("PASS wrapper Start/Coin/Service/Test joystick-bit contract")
    print("PASS Dyna Gear exact DIP default/field contract")
    print("PASS MAME Test input journal mapping")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
