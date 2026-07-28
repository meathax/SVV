#!/usr/bin/env python3
"""Convert binary P6 PPM captures to dependency-free RGB PNG files."""

from __future__ import annotations

import argparse
import pathlib
import struct
import zlib


def read_token(data: bytes, position: int) -> tuple[bytes, int]:
    while True:
        while position < len(data) and data[position] in b" \t\r\n":
            position += 1
        if position >= len(data) or data[position] != ord("#"):
            break
        while position < len(data) and data[position] not in b"\r\n":
            position += 1
    start = position
    while position < len(data) and data[position] not in b" \t\r\n":
        position += 1
    return data[start:position], position


def chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def convert(source: pathlib.Path, scale: int) -> pathlib.Path:
    data = source.read_bytes()
    position = 0
    tokens = []
    for _ in range(4):
        token, position = read_token(data, position)
        tokens.append(token)
    magic, width_raw, height_raw, max_raw = tokens
    if magic != b"P6" or int(max_raw) != 255:
        raise ValueError(f"unsupported PPM header in {source}")
    width, height = int(width_raw), int(height_raw)
    while position < len(data) and data[position] in b" \t\r\n":
        position += 1
    pixels = data[position : position + width * height * 3]
    if len(pixels) != width * height * 3:
        raise ValueError(f"short pixel payload in {source}")

    out_width, out_height = width * scale, height * scale
    rows = []
    for y in range(height):
        row = pixels[y * width * 3 : (y + 1) * width * 3]
        expanded = b"".join(
            row[x * 3 : x * 3 + 3] * scale for x in range(width)
        )
        rows.extend(b"\x00" + expanded for _ in range(scale))

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(
            b"IHDR",
            struct.pack(">IIBBBBB", out_width, out_height, 8, 2, 0, 0, 0),
        )
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        + chunk(b"IEND", b"")
    )
    target = source.with_suffix(".png")
    target.write_bytes(png)
    return target


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+", type=pathlib.Path)
    parser.add_argument("--scale", type=int, default=4)
    args = parser.parse_args()
    if args.scale < 1:
        parser.error("--scale must be positive")
    for source in args.sources:
        print(convert(source, args.scale))


if __name__ == "__main__":
    main()
