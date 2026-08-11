#!/usr/bin/env python3
"""Create the immutable, machine-readable half of an SSV lockstep preflight.

This tool deliberately writes ``PREFLIGHT_PENDING.json``.  A live coordinator
may promote it to ``PREFLIGHT_PASS.json`` only after the MAME and RTL adapters
report their *effective* dimensions, DIPs, inputs, sound/reset state and frame
boundary.  Static provenance alone is never treated as a passing comparison.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from ssv_supported_sets import (  # noqa: E402
    LOCKSTEP_FIRST_COMPARABLE_TOKEN,
    PARENT_RUN_ORDER,
    SUPPORTED_SET_IDS,
    SUPPORTED_SETS,
)
from ssv_input_journal import inspect_journal  # noqa: E402

MB = 1 << 20


def source_git(source_root: Path, *arguments: str) -> list[str]:
    """Run read-only Git provenance checks on an external checkout safely.

    The shared MAME checkout is intentionally owned by the host user rather
    than the sandbox identity.  Pass a repository-local safe.directory for
    each read instead of mutating global Git configuration.
    """
    return ["git", "-C", str(source_root),
            "-c", f"safe.directory={source_root}", *arguments]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def find_mra(setname: str, mra_dir: Path) -> tuple[Path, ET.Element]:
    for path in sorted(mra_dir.glob("*.mra")):
        root = ET.parse(path).getroot()
        if root.findtext("setname") == setname:
            return path, root
    raise FileNotFoundError(f"no MRA found for {setname}")


def mame_xml(mame: Path, setname: str) -> ET.Element:
    result = subprocess.run(
        [str(mame), setname, "-listxml"], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    root = ET.fromstring(result.stdout)
    for machine in root.findall("machine"):
        if machine.get("name") == setname:
            return machine
    raise ValueError(f"MAME listxml has no machine {setname}")


def mame_version(mame: Path) -> str:
    result = subprocess.run(
        [str(mame), "-version"], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    return result.stdout.strip()


def source_revision(source_root: Path, revision: str = "HEAD") -> str:
    result = subprocess.run(
        source_git(source_root, "rev-parse", revision),
        text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    return result.stdout.strip() if result.returncode == 0 else "unversioned"


def executable_source_tag(version: str) -> str | None:
    """Map MAME's declared version to the release tag in the source checkout."""
    parenthesized = re.search(r"\((mame\d+)\)", version)
    if parenthesized:
        return parenthesized.group(1)
    numeric = re.search(r"\b(\d+)\.(\d{1,3})\b", version)
    if not numeric:
        return None
    return f"mame{int(numeric.group(1))}{int(numeric.group(2)):03d}"


def tagged_source_file(source_root: Path, revision: str, relative: str,
                       allow_unversioned_source: bool = False) -> dict[str, object]:
    spec = f"{revision}:{relative}"
    blob = subprocess.run(
        source_git(source_root, "show", spec),
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    if blob.returncode != 0:
        if not allow_unversioned_source:
            raise FileNotFoundError(f"MAME source checkout has no {spec}")
        path = source_root / relative
        if not path.is_file():
            raise FileNotFoundError(f"MAME source tree has no {relative}")
        return {
            "git_spec": None,
            "git_object": None,
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
            "provenance": "unversioned source-tree file hash",
        }
    object_id = subprocess.run(
        source_git(source_root, "rev-parse", spec),
        check=True, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.strip()
    return {
        "git_spec": spec,
        "git_object": object_id,
        "bytes": len(blob.stdout),
        "sha256": hashlib.sha256(blob.stdout).hexdigest(),
    }


def mame_dip_defaults(machine: ET.Element) -> dict[str, int]:
    defaults: dict[str, int] = {}
    for switch in machine.findall("dipswitch"):
        tag = switch.get("tag", "")
        mask = int(switch.get("mask", "0"), 0)
        selected = next(
            (value for value in switch.findall("dipvalue")
             if value.get("default") == "yes"),
            None,
        )
        if selected is None:
            continue
        value = int(selected.get("value", "0"), 0)
        defaults[tag] = (defaults.get(tag, 0) & ~mask) | (value & mask)
    return defaults


def archive_provenance(rom_node: ET.Element, rom_dir: Path) -> dict[str, object]:
    alternatives = [item for item in rom_node.get("zip", "").split("|") if item]
    archives = [rom_dir / item for item in alternatives if (rom_dir / item).is_file()]
    if not archives:
        raise FileNotFoundError(f"none of the MRA archives exist: {alternatives}")

    opened = [(path, zipfile.ZipFile(path)) for path in archives]
    try:
        parts: list[dict[str, object]] = []
        for part in rom_node.iter("part"):
            name = part.get("name")
            if not name:
                continue
            found = None
            for archive_path, archive in opened:
                matches = [entry for entry in archive.infolist()
                           if entry.filename.lower() == name.lower()]
                if matches:
                    found = (archive_path, archive, matches[0])
                    break
            if found is None:
                raise FileNotFoundError(f"MRA part {name} missing from {alternatives}")
            archive_path, archive, entry = found
            data = archive.read(entry)
            expected_crc = part.get("crc")
            actual_crc = f"{entry.CRC:08x}"
            if expected_crc and actual_crc.lower() != expected_crc.lower():
                raise ValueError(
                    f"{name}: ZIP CRC {actual_crc} != MRA {expected_crc}"
                )
            parts.append({
                "name": name,
                "archive": archive_path.name,
                "bytes": len(data),
                "crc32": actual_crc,
                "sha256": hashlib.sha256(data).hexdigest(),
                "map": part.get("map"),
            })
        return {
            "alternatives": alternatives,
            "present": [
                {"path": str(path.resolve()), "bytes": path.stat().st_size,
                 "sha256": sha256_file(path)}
                for path in archives
            ],
            "parts": parts,
        }
    finally:
        for _, archive in opened:
            archive.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", required=True, choices=SUPPORTED_SETS)
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--mame", type=Path, default=Path(r"D:\Arcade\AI\mame\mame.exe"))
    parser.add_argument("--mame-source", type=Path,
                        default=Path(r"D:\Arcade\AI\mame289"))
    parser.add_argument("--rom-dir", type=Path, default=ROOT / "rom")
    parser.add_argument("--image-root", type=Path, default=ROOT / "sim_output" / "rom")
    parser.add_argument("--mra-dir", type=Path, default=ROOT / "releases")
    parser.add_argument(
        "--allow-unversioned-source", action="store_true",
        help="accept hashes from a source tree without the executable's Git tag",
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--scenario", default="coin_start_p1_gameplay")
    parser.add_argument("--start-frame", type=int)
    parser.add_argument("--rtl-restore", type=Path)
    parser.add_argument("--input-journal", type=Path)
    args = parser.parse_args()

    if args.set not in PARENT_RUN_ORDER:
        raise SystemExit(
            f"{args.set} is a clone and is excluded from the parent-only audit"
        )
    if args.session.exists() and any(args.session.iterdir()):
        if not args.force:
            raise SystemExit(f"session is not empty: {args.session}")
        shutil.rmtree(args.session)
    args.session.mkdir(parents=True, exist_ok=True)

    mra_path, mra = find_mra(args.set, args.mra_dir)
    descriptor_hex = (mra.find("rom[@index='1']/part").text or "").strip()
    descriptor = bytes.fromhex(descriptor_hex)
    if len(descriptor) != 16 or descriptor[:2] != b"S\x02" or sum(descriptor) & 0xff:
        raise ValueError(f"invalid schema-v2 descriptor: {mra_path}")

    switches = mra.find("switches")
    mra_dips = [int(value, 16) for value in switches.get("default", "FF,FD").split(",")]
    machine = mame_xml(args.mame, args.set)
    cloneof = machine.get("cloneof")
    if cloneof:
        raise ValueError(f"parent-only target {args.set} is cloneof={cloneof}")
    display = machine.find("display")
    if display is None:
        raise ValueError(f"MAME {args.set} has no display")

    width = descriptor[13] * 2
    height = descriptor[14]
    mame_width = int(display.get("width", "0"))
    mame_height = int(display.get("height", "0"))
    mame_rotation = int(display.get("rotate", "0"))
    expected_mra_rotation = {
        0: "horizontal",
        270: "vertical (ccw)",
    }.get(mame_rotation)
    mra_rotation = (mra.findtext("rotation") or "").strip()
    mame_dips = mame_dip_defaults(machine)
    checks = {
        "supported_manifest": args.set in SUPPORTED_SET_IDS,
        "mame_parent": cloneof is None,
        "geometry_matches": [width, height] == [mame_width, mame_height],
        "mra_rotation_matches": (
            expected_mra_rotation is not None
            and mra_rotation == expected_mra_rotation
        ),
        "dip_defaults_match": (
            mame_dips.get("DSW1") == mra_dips[0]
            and mame_dips.get("DSW2") == mra_dips[1]
        ),
    }

    scenario_path = ROOT / "verif" / "scenarios" / args.set / f"{args.scenario}.json"
    scenario_identity = {
        "id": args.scenario,
        "path": str(scenario_path.resolve()) if scenario_path.is_file() else None,
        "sha256": sha256_file(scenario_path) if scenario_path.is_file() else None,
    }
    rtl_startup: dict[str, object] = {"mode": "cold-lockstep"}
    if args.rtl_restore:
        if args.start_frame is None or args.start_frame < 1 or not args.input_journal:
            raise ValueError(
                "checkpoint preflight requires --start-frame and --input-journal"
            )
        restore = args.rtl_restore.resolve()
        metadata_path = Path(str(restore) + ".json")
        if not restore.is_file() or restore.stat().st_size == 0:
            raise FileNotFoundError(f"missing or empty RTL checkpoint: {restore}")
        if not metadata_path.is_file():
            raise FileNotFoundError(f"missing RTL checkpoint metadata: {metadata_path}")
        checkpoint = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
        journal_identity = inspect_journal(
            args.input_journal.resolve(), args.start_frame
        )
        checkpoint_journal = checkpoint.get("input_journal", {})
        checkpoint_scenario = checkpoint.get("input_identity", {})
        checkpoint_schema = checkpoint.get("schema")
        checkpoint_frame_coordinate = (
            checkpoint_schema != "ssv-verilator-checkpoint-v3"
            or (
                checkpoint.get("coordinate", {}).get("kind") == "frame"
                and checkpoint.get("coordinate", {}).get("value")
                == checkpoint.get("frame")
            )
        )
        checks.update({
            "checkpoint_schema": checkpoint_schema in {
                "ssv-verilator-checkpoint-v2",
                "ssv-verilator-checkpoint-v3",
            },
            "checkpoint_frame_coordinate": checkpoint_frame_coordinate,
            "checkpoint_set": checkpoint.get("set") == args.set,
            "checkpoint_scenario": checkpoint.get("scenario") == args.scenario,
            "checkpoint_frame_precedes_start": checkpoint.get("frame") == args.start_frame - 1,
            "checkpoint_archive_bytes": checkpoint.get("archive_bytes") == restore.stat().st_size,
            "checkpoint_archive_sha256": str(checkpoint.get("archive_sha256", "")).lower() == sha256_file(restore),
            "checkpoint_input_prefix": (
                checkpoint_journal.get("through_frame") == args.start_frame
                and checkpoint_journal.get("semantic_sha256") ==
                    journal_identity["semantic_sha256"]
            ),
            "checkpoint_scenario_identity": (
                scenario_identity["sha256"] is not None
                and str(checkpoint_scenario.get("scenario_sha256", "")).lower() ==
                    str(scenario_identity["sha256"]).lower()
            ),
        })
        rtl_startup = {
            "mode": "checkpoint-restore",
            "restore_committed_frame": args.start_frame - 1,
            "first_rtl_token": args.start_frame,
            "archive": str(restore),
            "archive_bytes": restore.stat().st_size,
            "archive_sha256": sha256_file(restore),
            "metadata": str(metadata_path.resolve()),
            "input_journal": journal_identity,
        }

    image_dir = args.image_root / args.set
    image_sizes = {
        "maincpu.bin": descriptor[2] * MB,
        "sprites.bin": (descriptor[3] * MB if descriptor[6] == 4
                        else descriptor[3] * MB * 3 // 4),
        "samples.bin": descriptor[12] * MB,
    }
    if descriptor[9] & 0x08:
        image_sizes["st010.bin"] = 0x11000
    images: dict[str, object] = {}
    for name, expected_size in image_sizes.items():
        path = image_dir / name
        if not path.is_file():
            raise FileNotFoundError(f"missing simulation image: {path}")
        images[name] = {
            "path": str(path.resolve()), "bytes": path.stat().st_size,
            "expected_bytes": expected_size, "sha256": sha256_file(path),
        }
        checks[f"image_size_{name}"] = path.stat().st_size == expected_size

    rom_node = mra.find("rom[@index='0']")
    if rom_node is None:
        raise ValueError(f"MRA has no index-0 media: {mra_path}")
    provenance = archive_provenance(rom_node, args.rom_dir)

    verify = subprocess.run(
        [str(args.mame), args.set, "-verifyroms", "-rompath", str(args.rom_dir)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    checks["mame_verifyroms"] = verify.returncode == 0

    neutral_packet = {"frame": 0, "p1_pressed": 0, "p2_pressed": 0,
                      "system_pressed": 0, "source": "neutral-seed"}
    packet_bytes = json.dumps(neutral_packet, sort_keys=True,
                              separators=(",", ":")).encode()
    first_comparable_token = LOCKSTEP_FIRST_COMPARABLE_TOKEN[args.set]

    isolated = {}
    for name in ("cfg", "nvram", "state", "snapshot"):
        path = args.session / "mame" / name
        path.mkdir(parents=True, exist_ok=True)
        isolated[name] = str(path.resolve())

    version = mame_version(args.mame)
    runtime_source_tag = executable_source_tag(version)
    runtime_source_revision = (
        source_revision(args.mame_source, runtime_source_tag)
        if runtime_source_tag else "unversioned"
    )
    checks["mame_executable_source_tag"] = (
        runtime_source_revision != "unversioned"
        or args.allow_unversioned_source
    )

    pertinent_source_files = (
        "src/mame/seta/ssv.cpp",
        "src/mame/seta/ssv_v.cpp",
        "src/mame/seta/ssv.h",
        "src/devices/cpu/v60/v60.cpp",
        "src/devices/cpu/v60/op5.hxx",
        "src/devices/cpu/v60/am.hxx",
        "src/devices/sound/es5506.cpp",
    )
    source_files = {}
    audit_source_files = {}
    for relative in pertinent_source_files:
        if runtime_source_tag:
            source_files[relative] = tagged_source_file(
                args.mame_source, runtime_source_tag, relative,
                args.allow_unversioned_source,
            )
        path = args.mame_source / relative
        audit_source_files[relative] = {
            "path": str(path.resolve()), "sha256": sha256_file(path),
        }

    payload = {
        "schema": "ssv-lockstep-preflight-v1",
        "status": "pending_live_adapters",
        "set": args.set,
        "game_id": SUPPORTED_SET_IDS[args.set],
        "parent_run_order": list(PARENT_RUN_ORDER),
        "mra": {"path": str(mra_path.resolve()), "sha256": sha256_file(mra_path),
                "descriptor_hex": descriptor_hex},
        "media": {"archives": provenance, "simulation_images": images},
        "reference": {
            "mame_path": str(args.mame.resolve()),
            "mame_sha256": sha256_file(args.mame),
            "mame_version": version,
            "mame_source_root": str(args.mame_source.resolve()),
            # Runtime traces are interpreted against the release tag declared
            # by this exact executable. HEAD remains the newer source-audit
            # target and may intentionally differ.
            "mame_source_tag": runtime_source_tag,
            "mame_source_revision": runtime_source_revision,
            "mame_source_binding": (
                "executable-declared release tag; binary identity pinned by SHA-256"
            ),
            "mame_source_provenance": (
                "Git release tag"
                if runtime_source_revision != "unversioned"
                else "unversioned source-tree file hashes; executable SHA-256 pinned"
            ),
            "source_files": source_files,
            "audit_source_revision": source_revision(args.mame_source),
            "audit_source_files": audit_source_files,
            "verifyroms_exit": verify.returncode,
            "verifyroms_output": verify.stdout.strip(),
            "isolated_paths": isolated,
            "expected_boundary": "MAME register_frame_done raw :screen pixels after draw",
        },
        "alignment": {
            "geometry": {"rtl": [width, height], "mame_listxml": [mame_width, mame_height]},
            "rotation": {
                "mame_degrees": mame_rotation,
                "mra": mra_rotation,
                "raw_comparison": "native unrotated",
            },
            "fixed_crop": [0, 0, width, height],
            "mra_dips": {"DSW1": mra_dips[0], "DSW2": mra_dips[1]},
            "mame_listxml_dips": mame_dips,
            "cabinet": "upright",
            "sound_enabled": True,
            "reset_state": (
                "RTL verified full-state checkpoint; MAME cold power-on with RTL-owned input replay"
                if args.rtl_restore else "cold power-on; no inherited state"
            ),
            "neutral_input_packet": neutral_packet,
            "neutral_input_sha256": hashlib.sha256(packet_bytes).hexdigest(),
            "first_complete_token": 1,
            "first_comparable_token": first_comparable_token,
            "warmup_excluded_tokens": list(range(first_comparable_token)),
            "rtl_expected_boundary": "completed post-video-enable native surface before presentation scaling",
        },
        "checks": checks,
        "scenario_identity": scenario_identity,
        "rtl_startup": rtl_startup,
        "required_live_ready": ["rtl_ready.json", "reference_ready.json"],
    }
    if not all(checks.values()):
        payload["status"] = "static_failure"
        atomic_json(args.session / "PREFLIGHT_FAILURE.json", payload)
        print(json.dumps(checks, sort_keys=True))
        return 1

    atomic_json(args.session / "manifest.json", payload)
    atomic_json(args.session / "PREFLIGHT_PENDING.json", payload)
    print(f"PREFLIGHT_PENDING set={args.set} session={args.session.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
