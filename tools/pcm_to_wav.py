#!/usr/bin/env python3
"""Wrap a raw s16le stereo PCM dump (+PCM_OUT) into a WAV for listening."""
import sys, wave

src, dst, rate = sys.argv[1], sys.argv[2], int(sys.argv[3])
data = open(src, 'rb').read()
w = wave.open(dst, 'wb')
w.setnchannels(2)
w.setsampwidth(2)
w.setframerate(rate)
w.writeframes(data)
w.close()
print(f"{dst}: {len(data)//4} frames at {rate} Hz")
