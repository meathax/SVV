#!/usr/bin/env python3
"""Report exact spatial/color differences between two binary P6 SSV frames."""

from __future__ import annotations

import argparse
import collections
from pathlib import Path


def token(data: bytes, position: int) -> tuple[bytes, int]:
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


def load(path: Path, pad_short: bool) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    position = 0
    values = []
    for _ in range(4):
        value, position = token(data, position)
        values.append(value)
    magic, width_raw, height_raw, max_raw = values
    if magic != b"P6" or max_raw != b"255":
        raise SystemExit(f"{path}: unsupported PPM")
    width, height = int(width_raw), int(height_raw)
    while position < len(data) and data[position] in b" \t\r\n":
        position += 1
    pixels = data[position : position + width * height * 3]
    required = width * height * 3
    if pad_short and 0 < required - len(pixels) <= 3:
        pixels += b"\x00" * (required - len(pixels))
    if len(pixels) != required:
        raise SystemExit(f"{path}: short pixel payload")
    return width, height, pixels


def rgb(pixels: bytes, index: int) -> int:
    offset = index * 3
    return int.from_bytes(pixels[offset : offset + 3], "big")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--top-colors", type=int, default=12)
    parser.add_argument(
        "--pad-short",
        action="store_true",
        help="pad at most one missing legacy pixel with black",
    )
    parser.add_argument(
        "--search-offset",
        type=int,
        default=0,
        help="search +/-N whole-frame candidate pixel offsets",
    )
    parser.add_argument(
        "--list-mismatches",
        type=int,
        default=0,
        help="list the first N mismatches at the best searched offset",
    )
    parser.add_argument(
        "--metrics",
        action="store_true",
        help="print nonblack and green-dominant populations",
    )
    args = parser.parse_args()
    rw, rh, reference = load(args.reference, args.pad_short)
    cw, ch, candidate = load(args.candidate, args.pad_short)
    if (rw, rh) != (cw, ch):
        raise SystemExit(f"geometry mismatch ref={rw}x{rh} candidate={cw}x{ch}")

    if args.metrics:
        for label, pixels in (("REF", reference), ("CANDIDATE", candidate)):
            colors = [rgb(pixels, index) for index in range(rw * rh)]
            nonblack = sum(color != 0 for color in colors)
            green = sum(
                ((color >> 8) & 0xFF) > ((color >> 16) & 0xFF)
                and ((color >> 8) & 0xFF) > (color & 0xFF)
                and ((color >> 8) & 0xFF) >= 0x40
                for color in colors
            )
            print(f"{label}_METRICS nonblack={nonblack} green={green}")

    mismatches = []
    substitutions: collections.Counter[tuple[int, int]] = collections.Counter()
    row_counts = [0] * rh
    for index in range(rw * rh):
        ref = rgb(reference, index)
        got = rgb(candidate, index)
        if ref != got:
            x, y = index % rw, index // rw
            mismatches.append((x, y, ref, got))
            row_counts[y] += 1
            substitutions[(ref, got)] += 1

    if not mismatches:
        print(f"PIXEL_MATCH geometry={rw}x{rh} pixels={rw * rh}")
        return
    min_x = min(item[0] for item in mismatches)
    max_x = max(item[0] for item in mismatches)
    min_y = min(item[1] for item in mismatches)
    max_y = max(item[1] for item in mismatches)
    first = mismatches[0]
    busiest = sorted(enumerate(row_counts), key=lambda item: item[1], reverse=True)[:8]
    print(
        f"PIXEL_DIVERGENCE count={len(mismatches)}/{rw * rh} "
        f"first=({first[0]},{first[1]}) ref={first[2]:06x} got={first[3]:06x} "
        f"bbox=({min_x},{min_y})-({max_x},{max_y})"
    )
    print("BUSIEST_ROWS " + " ".join(f"y={y}:{count}" for y, count in busiest if count))
    if args.search_offset:
        scores = []
        for dy in range(-args.search_offset, args.search_offset + 1):
            for dx in range(-args.search_offset, args.search_offset + 1):
                count = 0
                for y in range(rh):
                    for x in range(rw):
                        ref = rgb(reference, y * rw + x)
                        cx, cy = x + dx, y + dy
                        got = (
                            rgb(candidate, cy * rw + cx)
                            if 0 <= cx < rw and 0 <= cy < rh
                            else 0
                        )
                        count += ref != got
                scores.append((count, dx, dy))
        ranked = sorted(scores)
        print(
            "BEST_OFFSETS "
            + " ".join(
                f"dx={dx},dy={dy}:{count}" for count, dx, dy in ranked[:5]
            )
        )
        if args.list_mismatches:
            _, best_dx, best_dy = ranked[0]
            listed = 0
            for y in range(rh):
                for x in range(rw):
                    ref = rgb(reference, y * rw + x)
                    cx, cy = x + best_dx, y + best_dy
                    got = (
                        rgb(candidate, cy * rw + cx)
                        if 0 <= cx < rw and 0 <= cy < rh
                        else 0
                    )
                    if ref != got:
                        print(
                            f"OFFSET_MISMATCH x={x} y={y} "
                            f"ref={ref:06x} got={got:06x}"
                        )
                        listed += 1
                        if listed >= args.list_mismatches:
                            break
                if listed >= args.list_mismatches:
                    break
    for (ref, got), count in substitutions.most_common(args.top_colors):
        print(f"COLOR_SUB count={count} ref={ref:06x} got={got:06x}")


if __name__ == "__main__":
    main()
