#!/usr/bin/env python3
"""Deterministically normalize a WAV stream to stereo signed 16-bit 48 kHz."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import wave


def normalize(source: Path, destination: Path) -> dict[str, int]:
    with wave.open(str(source), "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())
    if channels not in (1, 2) or width not in (1, 2, 3, 4):
        raise ValueError(f"unsupported WAV layout channels={channels} width={width}")
    if channels not in (1, 2):
        raise ValueError("WAV channel count is not mono or stereo")
    source_frame_width = width * channels
    source_count = len(frames) // source_frame_width
    decoded: list[tuple[int, int]] = []
    for index in range(source_count):
        values = []
        for channel in range(channels):
            offset = index * source_frame_width + channel * width
            raw = frames[offset:offset + width]
            if width == 1:
                sample = (raw[0] - 128) << 8
            else:
                sample = int.from_bytes(raw, "little", signed=False)
                if sample & (1 << (width * 8 - 1)):
                    sample -= 1 << (width * 8)
                if width == 3:
                    sample >>= 8
                elif width == 4:
                    sample >>= 16
            values.append(max(-32768, min(32767, sample)))
        decoded.append((values[0], values[0] if channels == 1 else values[1]))
    target_count = (source_count * 48000 + rate // 2) // rate if rate else 0
    output = bytearray()
    for index in range(target_count):
        if not decoded:
            left = right = 0
        else:
            numerator = index * rate
            base = numerator // 48000
            remainder = numerator % 48000
            first = decoded[min(base, len(decoded) - 1)]
            second = decoded[min(base + 1, len(decoded) - 1)]
            left = (first[0] * (48000 - remainder) + second[0] * remainder) // 48000
            right = (first[1] * (48000 - remainder) + second[1] * remainder) // 48000
        output.extend(struct.pack("<hh", left, right))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(bytes(output))
    return {"source_rate_hz": rate, "source_channels": channels,
            "source_width_bytes": width, "output_rate_hz": 48000,
            "output_channels": 2, "output_width_bytes": 2,
            "output_samples": len(output) // 4}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    import json
    print(json.dumps(normalize(args.source, args.destination), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
