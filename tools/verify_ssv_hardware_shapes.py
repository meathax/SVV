#!/usr/bin/env python3
"""Fail-closed static checks for the universal SSV hardware source shape.

This checks source/manifest structure only.  It does not run Quartus and does
not prove RAM inference, resource usage, timing, or behavior on hardware.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


SOURCE_RE = re.compile(
    r"^\s*set_global_assignment\s+-name\s+(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+(\S+)",
    re.MULTILINE,
)
COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)
MULTIDIM_UNPACKED_RE = re.compile(
    r"\b(?:logic|reg)\s*(?:\[[^;\n]+?\])?\s+\w+\s*"
    r"\[[^;\n]+?\]\s*\[[^;\n]+?\]\s*;"
)
GAME_NAMES = ("dynagear", "cairblad", "vasara", "vasara2", "drifto94",
              "stmblade", "twineag2", "ultrax")
REQUIRED_SOURCES = {
    "Arcade-SSV.sv",
    "rtl/ssv_core.sv",
    "rtl/ssv_pkg.sv",
    "rtl/cpu/v60/s32_v60.sv",
    "rtl/cpu/v60/s32_v60_bus.sv",
    "rtl/audio/ssv_es5506_regs.sv",
    "rtl/audio/ssv_es5506_voice.sv",
    "rtl/cpu/upd96050/upd96050.sv",
    "rtl/cpu/upd96050/upd96050_st010.sv",
    "rtl/cpu/upd96050/ssv_st010_prg_fetch.sv",
    "rtl/mem/sdram.sv",
    "rtl/mem/ssv_rom_loader.sv",
    "rtl/mem/ssv_nvram_bridge.sv",
    "rtl/video/ssv_cached_sprite_renderer.sv",
}
EXPECTED_MEMORIES = {
    "rtl/ssv_core.sv": (
        r'ramstyle\s*=\s*"MLAB, no_rw_check"[^;]*\bicache_data\s*\[0:127\]',
        r'ramstyle\s*=\s*"MLAB, no_rw_check"[^;]*\bicache_tag\s*\[0:127\]',
    ),
    "rtl/video/ssv_cached_sprite_renderer.sv": (
        r'ramstyle\s*=\s*"M10K, no_rw_check"[^;]*\bdescriptor_cache\s*\[0:CACHE_ENTRIES-1\]',
        r'ramstyle\s*=\s*"M10K, no_rw_check"[^;]*\bline_meta\s*\[0:239\]',
        r'ramstyle\s*=\s*"M10K, no_rw_check"[^;]*\bline_entries\s*\[0:LINE_POOL_ENTRIES-1\]',
    ),
}


def audit(root: Path) -> dict:
    errors: list[str] = []
    qip = root / "files.qip"
    if not qip.is_file():
        return {"status": "fail", "errors": ["files.qip is missing"]}
    manifest_text = qip.read_text(encoding="utf-8")
    sources = [item.replace("\\", "/") for item in SOURCE_RE.findall(manifest_text)]
    if not sources:
        errors.append("files.qip contains no HDL source assignments")
    duplicates = sorted({item for item in sources if sources.count(item) > 1})
    if duplicates:
        errors.append("duplicate HDL manifest entries: " + ", ".join(duplicates))
    for item in sources:
        if not (root / item).is_file():
            errors.append(f"manifest source is missing: {item}")
        if item.startswith("sys/") or any(part in item.split("/") for part in
                                           ("db", "incremental_db", "output_files")):
            errors.append(f"manifest directly compiles forbidden framework/generated source: {item}")
    missing_required = sorted(REQUIRED_SOURCES - set(sources))
    if missing_required:
        errors.append("required universal device sources absent: " + ", ".join(missing_required))

    compiled_rtl = [item for item in sources if item.startswith("rtl/")]
    for item in compiled_rtl:
        path = root / item
        if not path.is_file():
            continue
        clean = COMMENT_RE.sub("", path.read_text(encoding="utf-8", errors="replace"))
        if MULTIDIM_UNPACKED_RE.search(clean):
            errors.append(f"compiled RTL contains multidimensional unpacked inferred-memory shape: {item}")
        if item != "rtl/ssv_pkg.sv":
            for line_no, line in enumerate(clean.splitlines(), 1):
                lower = line.lower()
                if any(re.search(rf"\b{re.escape(name)}\b", lower) for name in GAME_NAMES):
                    errors.append(f"game-name identifier in synthesizable RTL: {item}:{line_no}")

    for item, patterns in EXPECTED_MEMORIES.items():
        path = root / item
        text = COMMENT_RE.sub("", path.read_text(encoding="utf-8", errors="replace")) if path.is_file() else ""
        for pattern in patterns:
            if not re.search(pattern, text, re.DOTALL):
                errors.append(f"expected flat memory/ramstyle intent missing in {item}: {pattern}")

    git = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain", "--", "sys"],
        text=True, capture_output=True, check=False,
    )
    if git.returncode != 0:
        errors.append("unable to audit sys/ worktree status")
    elif git.stdout.strip():
        errors.append("vendored sys/ has tracked or untracked edits")

    return {
        "schema": "ssv-hardware-shape-audit-v1",
        "status": "fail" if errors else "pass",
        "quartus_rbf": False,
        "inference_proven": False,
        "scope": "static source and resource-shape intent only",
        "manifest_source_count": len(sources),
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    result = audit(args.repo.resolve())
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
