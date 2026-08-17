#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Minimal P6 PPM -> PNG converter (stdlib only; no Pillow in this env).

    tools/ppm2png.py in.ppm out.png [scale]

Used to eyeball how far a headless MAME evidence run actually got, from the
bitmaps tools/mame-v60-opcode-histogram-multi.lua dumps under -video none.
"""
import sys
import zlib
import struct


def read_ppm(path):
    with open(path, "rb") as fh:
        data = fh.read()
    # header: P6 <ws> W <ws> H <ws> MAXVAL <single ws> pixels
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while data[i : i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1
    w, h, _ = fields
    return w, h, data[i : i + w * h * 3]


def write_png(path, w, h, rgb, scale=1):
    if scale > 1:
        rows = []
        for y in range(h):
            row = rgb[y * w * 3 : (y + 1) * w * 3]
            big = b"".join(row[x * 3 : x * 3 + 3] * scale for x in range(w))
            rows.extend([big] * scale)
        w, h = w * scale, h * scale
        raw = b"".join(b"\x00" + r for r in rows)
    else:
        raw = b"".join(b"\x00" + rgb[y * w * 3 : (y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    W, H, RGB = read_ppm(sys.argv[1])
    write_png(sys.argv[2], W, H, RGB, int(sys.argv[3]) if len(sys.argv) > 3 else 1)
