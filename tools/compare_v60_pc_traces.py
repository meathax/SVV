"""Shared parsers for MAME debugger and RTL retired-PC traces."""

from __future__ import annotations

import re
from pathlib import Path


MAME_PC = re.compile(r"^([0-9a-fA-F]+):")


def load_mame_pcs(path: Path) -> list[int]:
    result: list[int] = []
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            match = MAME_PC.match(line)
            if match:
                result.append(int(match.group(1), 16))
    return result


def load_rtl_pcs(path: Path) -> list[int]:
    with path.open("r", encoding="ascii") as stream:
        return [int(line, 16) for line in stream if line.strip()]
