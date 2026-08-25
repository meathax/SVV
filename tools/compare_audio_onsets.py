#!/usr/bin/env python3
"""Note-onset comparison between the RTL ES5506 PCM dump and a MAME WAV.

The question this answers is categorical, not statistical: does one lane
contain NOTE ONSETS (energy attacks) at times where the other lane has none?
Extra onsets in RTL = the reported random-notes symptom reproduced in sim.

RTL input: raw s16le stereo at ~31250 Hz (+PCM_OUT dump, frame-locked).
MAME input: WAV (typically 48 kHz) recorded around the same input scenario.

Alignment: both lanes are reduced to mono energy envelopes at a common
analysis rate; cross-correlation of the envelopes finds the global offset.
Onsets are peaks in the half-wave-rectified log-energy derivative. Each
onset in one lane is matched to the nearest onset in the other within a
tolerance; unmatched onsets are reported with timestamps.
"""
import sys, wave, struct
import numpy as np

AN_RATE = 200          # envelope analysis rate (Hz)
TOL = 0.08             # onset match tolerance (s)

def load_wav(path):
    w = wave.open(path, 'rb')
    n, ch, sw, sr = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
    raw = w.readframes(n)
    w.close()
    a = np.frombuffer(raw, dtype='<i2').astype(np.float32)
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return a, sr

def load_pcm(path, sr):
    a = np.fromfile(path, dtype='<i2').astype(np.float32)
    a = a.reshape(-1, 2).mean(axis=1)
    return a, sr

def envelope(x, sr):
    hop = int(round(sr / AN_RATE))
    n = len(x) // hop
    e = np.sqrt(np.mean(np.square(x[:n*hop].reshape(n, hop)), axis=1) + 1.0)
    return np.log(e)

def onsets(env):
    d = np.diff(env)
    d[d < 0] = 0
    # adaptive threshold: mean + 2*std over a sliding second
    th = np.convolve(d, np.ones(AN_RATE)/AN_RATE, mode='same')
    sd = np.sqrt(np.convolve((d-th)**2, np.ones(AN_RATE)/AN_RATE, mode='same'))
    cand = np.where(d > th + 2.0*sd + 0.05)[0]
    out = []
    for i in cand:
        if not out or i - out[-1] > int(0.06*AN_RATE):
            out.append(i)
    return np.array(out) / AN_RATE, d

def main():
    rtl_path, mame_path, rtl_sr = sys.argv[1], sys.argv[2], float(sys.argv[3])
    forced = float(sys.argv[4]) if len(sys.argv) > 4 else None
    rtl, _ = load_pcm(rtl_path, rtl_sr)
    mame, msr = load_wav(mame_path)
    er = envelope(rtl, rtl_sr)
    em = envelope(mame, msr)
    if forced is not None:
        # caller knows the scenario offset; refine only within +-0.5 s
        max_lag = int(0.5*AN_RATE)
        base = int(round(forced*AN_RATE))
        em = em[max(0, base-max_lag):]
        # fall through: search the small window against the trimmed envelope
    else:
        max_lag = 20*AN_RATE
    a = er - er.mean(); b = em - em.mean()
    best, blag = -1e18, 0
    for lag in range(-max_lag, max_lag+1, 2):
        if lag >= 0:
            x, y = a[:len(a)-lag] if lag else a, b[lag:lag+len(a)]
        else:
            x, y = a[-lag:], b[:len(a)+lag]
        m = min(len(x), len(y))
        if m < 5*AN_RATE: continue
        c = float(np.dot(x[:m], y[:m])) / m
        if c > best: best, blag = c, lag
    off = blag / AN_RATE   # mame time = rtl time + off
    print(f"# alignment offset: mame = rtl + {off:.3f}s (corr {best:.1f})")
    o_r, _ = onsets(er)
    o_m, _ = onsets(em)
    # clip mame onsets to the aligned rtl window
    lo, hi = off, off + len(er)/AN_RATE
    o_m_w = o_m[(o_m >= lo) & (o_m <= hi)] - off
    print(f"# onsets: rtl={len(o_r)} mame(in window)={len(o_m_w)}")
    def unmatched(src, ref):
        out = []
        for t in src:
            if len(ref) == 0 or np.min(np.abs(ref - t)) > TOL:
                out.append(t)
        return out
    extra_rtl = unmatched(o_r, o_m_w)
    extra_mame = unmatched(o_m_w, o_r)
    print(f"# RTL-only onsets: {len(extra_rtl)}")
    for t in extra_rtl:
        print(f"RTL_ONLY t={t:8.3f}s frame={t*60:7.1f}")
    print(f"# MAME-only onsets: {len(extra_mame)}")
    for t in extra_mame:
        print(f"MAME_ONLY t={t:8.3f}s frame={t*60:7.1f}")

if __name__ == '__main__':
    main()
