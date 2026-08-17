#!/usr/bin/env python3
"""Assemble private SSV simulation images from the generated MRA and ZIP.

The MRA is already generated from the pinned MAME ``ssv.cpp`` driver.  This
tool deliberately consumes that description instead of maintaining a second
ROM-name/offset table, then splits the resulting index-0 stream at the
descriptor-selected region boundaries used by ``ssv_pkg``.

Outputs are local simulation artifacts under ``sim_output/rom/<set>`` and are
ignored by Git.  No ROM data belongs in the repository.
"""

from __future__ import annotations

import argparse
import binascii
import pathlib
import zipfile
import xml.etree.ElementTree as ET

from ssv_supported_sets import SUPPORTED_SETS


MB = 1 << 20


def _zip_for(root: pathlib.Path, value: str) -> pathlib.Path:
    for candidate in value.split("|"):
        path = root / candidate
        if path.is_file():
            return path
    raise FileNotFoundError(f"none of the MRA ZIP alternatives exist: {value}")


def _zip_entry(zf: zipfile.ZipFile, name: str) -> bytes:
    try:
        info = zf.getinfo(name)
    except KeyError:
        lowered = name.lower()
        matches = [i for i in zf.infolist() if i.filename.lower() == lowered]
        if not matches:
            raise FileNotFoundError(f"{name} is missing from {zf.filename}")
        info = matches[0]
    data = zf.read(info)
    got = binascii.crc32(data) & 0xFFFFFFFF
    if got != info.CRC:
        raise ValueError(f"ZIP CRC failure for {name} in {zf.filename}")
    return data


def _part_data(part: ET.Element, zf: zipfile.ZipFile) -> bytes:
    repeat = part.get("repeat")
    if repeat is not None:
        count = int(repeat, 0)
        fill = (part.text or "00").strip()
        if fill != "00":
            raise ValueError(f"unsupported MRA repeat fill {fill!r}")
        return bytes(count)

    name = part.get("name")
    if not name:
        raise ValueError("MRA part has neither name nor repeat")
    data = _zip_entry(zf, name)
    expected = part.get("crc")
    if expected is not None and (binascii.crc32(data) & 0xFFFFFFFF) != int(expected, 16):
        raise ValueError(f"MRA CRC mismatch for {name} in {zf.filename}")
    return data


def _interleave(node: ET.Element, zf: zipfile.ZipFile) -> bytes:
    parts = list(node.findall("part"))
    if not parts:
        raise ValueError("empty MRA interleave")

    lane_parts: list[tuple[int, bytes]] = []
    for part in parts:
        mapping = part.get("map")
        data = _part_data(part, zf)
        if mapping == "21":
            if len(data) & 1:
                raise ValueError(f"word-swapped part has odd length: {part.get('name')}")
            swapped = bytearray(len(data))
            for i in range(0, len(data), 2):
                swapped[i] = data[i + 1]
                swapped[i + 1] = data[i]
            lane_parts.append((0, bytes(swapped)))
        elif mapping in ("01", "10"):
            # MRA map 01 is the even-address byte lane and 10 is odd.
            lane_parts.append((0 if mapping == "01" else 1, data))
        else:
            raise ValueError(f"unsupported MRA interleave map {mapping!r}")

    if any(mapping == "21" for mapping in (p.get("map") for p in parts)):
        if len(lane_parts) != 1:
            raise ValueError("word swap cannot be combined with another lane")
        return lane_parts[0][1]

    output = bytearray(max(len(data) for _, data in lane_parts) * 2)
    for lane, data in lane_parts:
        for i, value in enumerate(data):
            output[2 * i + lane] = value
    return bytes(output)


def _assemble_stream(rom: ET.Element, zf: zipfile.ZipFile) -> bytes:
    stream = bytearray()
    for child in list(rom):
        if child.tag == "part":
            stream.extend(_part_data(child, zf))
        elif child.tag == "interleave":
            stream.extend(_interleave(child, zf))
        else:
            raise ValueError(f"unsupported MRA element <{child.tag}>")
    return bytes(stream)


def assemble(setname: str, mra_dir: pathlib.Path, rom_dir: pathlib.Path,
             output_root: pathlib.Path) -> None:
    mra_paths = sorted(mra_dir.glob("*.mra"))
    mra_path = None
    for candidate in mra_paths:
        root = ET.parse(candidate).getroot()
        if root.findtext("setname") == setname:
            mra_path = candidate
            break
    if mra_path is None:
        raise FileNotFoundError(f"no MRA for supported set {setname}")

    root = ET.parse(mra_path).getroot()
    cfg_hex = (root.find("rom[@index='1']/part").text or "").strip()
    cfg = bytes.fromhex(cfg_hex)
    if len(cfg) != 24 or cfg[0:2] != b"S\x03" or sum(cfg) & 0xFF:
        raise ValueError(f"invalid release descriptor v3 in {mra_path}")

    prog_size = cfg[2] * MB
    gfx_region = cfg[3] * MB
    quarters = cfg[6]
    gfx_size = gfx_region if quarters == 4 else (gfx_region * 3) // 4
    sample_size = cfg[12] * MB
    st010_size = 0x11000 if (cfg[9] & 0x08) else 0
    expected_size = prog_size + gfx_size + sample_size + st010_size

    rom = root.find("rom[@index='0']")
    if rom is None:
        raise ValueError(f"MRA has no index-0 ROM block: {mra_path}")
    zip_path = _zip_for(rom_dir, rom.get("zip", ""))
    with zipfile.ZipFile(zip_path) as zf:
        stream = _assemble_stream(rom, zf)

    if len(stream) != expected_size:
        raise ValueError(
            f"{setname}: stream length {len(stream):#x}, expected {expected_size:#x}"
        )

    out = output_root / setname
    out.mkdir(parents=True, exist_ok=True)
    regions = {
        "maincpu.bin": stream[:prog_size],
        "sprites.bin": stream[prog_size:prog_size + gfx_size],
        "samples.bin": stream[prog_size + gfx_size:prog_size + gfx_size + sample_size],
    }
    if st010_size:
        regions["st010.bin"] = stream[-st010_size:]
    for name, data in regions.items():
        (out / name).write_bytes(data)

    print(
        f"{setname}: {mra_path.name} + {zip_path.name} -> "
        f"main={prog_size:#x} gfx_stream={gfx_size:#x} "
        f"samples={sample_size:#x} st010={st010_size:#x}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", dest="sets", action="append", choices=SUPPORTED_SETS)
    parser.add_argument("--mra-dir", type=pathlib.Path, default=pathlib.Path("mra"))
    parser.add_argument("--rom-dir", type=pathlib.Path, default=pathlib.Path("rom"))
    parser.add_argument("--output-root", type=pathlib.Path,
                        default=pathlib.Path("sim_output/rom"))
    args = parser.parse_args()
    for setname in args.sets or SUPPORTED_SETS:
        assemble(setname, args.mra_dir, args.rom_dir, args.output_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
