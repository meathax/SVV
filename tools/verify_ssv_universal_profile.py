#!/usr/bin/env python3
"""Verify that every qualified local set selects the one universal SSV RBF."""

from __future__ import annotations

import argparse
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

from ssv_supported_sets import (
    RETIRED_LOCAL_SETS,
    SUPPORTED_SETS,
    SUPPORTED_SET_IDS,
)


def fail(message: str, errors: list[str]) -> None:
    errors.append(message)


def cfg_bytes(root: ET.Element, setname: str, errors: list[str]) -> bytes:
    nodes = [n for n in root.findall("rom") if n.get("index") == "1"]
    if len(nodes) != 1 or nodes[0].find("part") is None:
        fail(f"{setname}: expected exactly one index-1 profile descriptor", errors)
        return b""
    try:
        data = bytes.fromhex((nodes[0].findtext("part") or "").strip())
    except ValueError:
        fail(f"{setname}: profile descriptor is not hexadecimal", errors)
        return b""
    if len(data) != 16:
        fail(f"{setname}: profile descriptor is {len(data)} bytes, expected 16", errors)
        return b""
    if data[0:2] != b"\x53\x02":
        fail(f"{setname}: bad profile magic/version {data[0:2].hex()}", errors)
    if sum(data) & 0xFF:
        fail(f"{setname}: profile checksum does not sum to zero", errors)
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument(
        "--require-roms",
        action="store_true",
        help="also require the local private ROM archives and all named parts",
    )
    args = parser.parse_args()
    repo = args.repo.resolve()
    errors: list[str] = []

    qpf = (repo / "Arcade-SSV.qpf").read_text(encoding="ascii")
    if 'PROJECT_REVISION = "Arcade-SSV"' not in qpf:
        fail("Arcade-SSV.qpf does not select the sole Arcade-SSV revision", errors)

    by_set: dict[str, tuple[Path, ET.Element]] = {}
    for path in sorted((repo / "mra").glob("*.mra")):
        root = ET.parse(path).getroot()
        setname = (root.findtext("setname") or "").strip()
        if setname in by_set:
            fail(f"{setname}: duplicate MRA ({by_set[setname][0].name}, {path.name})", errors)
        by_set[setname] = (path, root)

    rows = []
    seen_ids: set[int] = set()
    # Archives named by a qualified MRA are media dependencies, not additional
    # supported sets. Retired local archives are allowed below so removing a
    # profile entry does not require deleting private ROM media.
    allowed_archive_stems: set[str] = set()
    for setname in SUPPORTED_SETS:
        if setname not in by_set:
            fail(f"{setname}: no MRA", errors)
            continue
        path, root = by_set[setname]
        if (root.findtext("rbf") or "").strip() != "SSV":
            fail(f"{setname}: MRA does not select SSV.rbf", errors)

        rotation = (root.findtext("rotation") or "").strip()
        if rotation not in ("horizontal", "vertical (ccw)"):
            fail(
                f"{setname}: missing or unsupported MRA rotation {rotation!r}",
                errors,
            )

        rom_nodes = root.findall("rom")
        order = [node.get("index") for node in rom_nodes]
        if "1" not in order or "0" not in order or order.index("1") > order.index("0"):
            fail(f"{setname}: index-1 profile must precede index-0 ROM data", errors)

        cfg = cfg_bytes(root, setname, errors)
        if not cfg:
            continue
        game_id = cfg[11] & 0x0F
        if game_id != SUPPORTED_SET_IDS[setname]:
            fail(
                f"{setname}: descriptor id {game_id}, expected "
                f"{SUPPORTED_SET_IDS[setname]}",
                errors,
            )
        if game_id in seen_ids:
            fail(f"{setname}: descriptor id {game_id} is not unique", errors)
        seen_ids.add(game_id)

        prog_mb, gfx_mb, sample_mb = cfg[2], cfg[3] & 0x7F, cfg[12]
        gfx_quarters = cfg[6] & 7
        gfx_k, gfx_factor_code = cfg[4] & 0x1F, cfg[5] & 0x03
        gfx_factor = (1, 3)[gfx_factor_code] if gfx_factor_code < 2 else None
        flags = cfg[9]
        extra_input_mode = (flags >> 6) & 0x03
        extra_ram_mode = (cfg[10] >> 3) & 0x03
        nvram_mode = (cfg[10] >> 6) & 0x03
        if flags & 0x04:
            fail(f"{setname}: reserved descriptor flag byte-9 bit 2 is set", errors)
        if prog_mb not in (1, 2, 4):
            fail(f"{setname}: unsupported program size {prog_mb} MiB", errors)
        if gfx_mb not in (12, 16, 24, 32) or gfx_quarters not in (3, 4):
            fail(
                f"{setname}: unsupported graphics geometry "
                f"{gfx_mb} MiB/{gfx_quarters} quarters",
                errors,
            )
        if gfx_factor is None:
            fail(f"{setname}: unsupported graphics factor code {gfx_factor_code}", errors)
        elif (gfx_factor << gfx_k) != (gfx_mb << 13):
            fail(f"{setname}: graphics factor/k disagrees with region size", errors)
        if extra_input_mode == 3:
            fail(f"{setname}: reserved extra-input mode 3", errors)
        if (cfg[13] * 2, cfg[14]) not in (
            (336, 238), (336, 240), (338, 240), (352, 240)
        ):
            fail(f"{setname}: unsupported visible area {cfg[13] * 2}x{cfg[14]}", errors)
        if sample_mb not in (4, 8):
            fail(f"{setname}: unsupported sample size {sample_mb} MiB", errors)
        if extra_ram_mode == 3:
            fail(f"{setname}: reserved extra CPU RAM mode 3", errors)
        if nvram_mode == 3:
            fail(f"{setname}: reserved NVRAM mode 3", errors)
        if bool(cfg[10] & 0x04) != bool(nvram_mode):
            fail(f"{setname}: NVRAM presence/size fields disagree", errors)

        index0 = next((n for n in rom_nodes if n.get("index") == "0"), None)
        zip_names = (index0.get("zip") if index0 is not None else "") or ""
        archive_names = [name.strip() for name in zip_names.split("|") if name.strip()]
        allowed_archive_stems.update(Path(name).stem for name in archive_names)
        if f"{setname}.zip" not in archive_names:
            fail(f"{setname}: index-0 zip list omits {setname}.zip", errors)

        if args.require_roms:
            set_archive = repo / "rom" / f"{setname}.zip"
            if not set_archive.is_file():
                fail(f"{setname}: local ROM archive is missing", errors)
            else:
                # MiSTer searches the MRA's clone|parent list. Mirror that
                # contract here: a required part may live in either an
                # existing split archive, while a fully merged clone archive
                # remains sufficient on its own.
                available: set[str] = set()
                for archive_name in archive_names:
                    archive = repo / "rom" / archive_name
                    if archive.is_file():
                        with zipfile.ZipFile(archive) as zf:
                            available.update(zf.namelist())
                required = {
                    part.get("name")
                    for part in index0.iter("part")
                    if part.get("name")
                }
                missing = sorted(required - available)
                if missing:
                    fail(
                        f"{setname}: archive lacks MRA parts {', '.join(missing)}",
                        errors,
                    )

        rows.append(
            (
                setname,
                game_id,
                prog_mb,
                gfx_mb,
                sample_mb,
                "ST010" if flags & 0x08 else "-",
                "IRQ1" if flags & 0x02 else "-",
                {0: "-", 1: "idle", 2: "B4-6"}[extra_input_mode],
                {0: "-", 1: "400k", 2: "010k"}[extra_ram_mode],
                {0: "-", 1: "2k", 2: "64k"}[nvram_mode],
                cfg[10] & 3,
                path.name,
            )
        )

    if args.require_roms:
        local_sets = {p.stem for p in (repo / "rom").glob("*.zip")}
        required_sets = set(SUPPORTED_SETS)
        allowed_archive_stems.update(RETIRED_LOCAL_SETS)
        missing_required = required_sets - local_sets
        unexpected = local_sets - allowed_archive_stems
        if missing_required or unexpected:
            fail(
                "local ROM media differs from qualified MRA dependencies: "
                f"unexpected={sorted(unexpected)}, "
                f"missing-qualified={sorted(missing_required)}",
                errors,
            )

    if errors:
        for message in errors:
            print(f"ERROR: {message}", file=sys.stderr)
        return 1

    print("set        id prog gfx samp dsp   irq  input ram   nvram wdog  MRA")
    for row in rows:
        print(
            f"{row[0]:10} {row[1]:2} {row[2]:4} {row[3]:3} "
            f"{row[4]:4} {row[5]:5} {row[6]:4} {row[7]:5} {row[8]:5} "
            f"{row[9]:5} {row[10]:4}  {row[11]}"
        )
    print(f"PASS: {len(rows)} sets select the single SSV.rbf profile")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
