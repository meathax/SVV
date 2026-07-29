#!/usr/bin/env python3
"""Coin+start Verilator run; dump 5 play frames to PNG."""
from __future__ import annotations

import os
import pathlib
import struct
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / "ssv-play-shots"
PREFIX = ROOT / "sim_output" / "frames" / "play" / "shot"
START = int(os.environ.get("DUMP_START", "280"))
COUNT = int(os.environ.get("DUMP_COUNT", "5"))
STEP = int(os.environ.get("DUMP_STEP", "25"))
LAST = START + (COUNT - 1) * STEP + 10

VFLAGS = [
    "--binary", "--timing", "--assert", "--threads", "1",
    "--verilate-jobs", "4", "--build-jobs", "4", "-Wno-fatal",
    "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND", "-Wno-UNOPTFLAT",
    "-Wno-CASEINCOMPLETE", "-Wno-BLKANDNBLK", "-Wno-MULTIDRIVEN",
    "-Wno-INITIALDLY", "-Wno-DECLFILENAME", "-Wno-PINMISSING",
    "-Wno-UNSIGNED", "-Wno-WIDTH", "-Wno-CASEOVERLAP", "-Wno-UNUSED",
    "-Wno-PINCONNECTEMPTY", "-Wno-VARHIDDEN", "-Wno-UNUSEDSIGNAL",
    "+define+SIMULATION",
]
CORE = [
    "rtl/ssv_pkg.sv", "rtl/ssv_irq.sv", "rtl/ssv_video_timing.sv",
    "rtl/common/s32_big_dpram.sv",
    "rtl/video/ssv_palette_ram.sv", "rtl/video/ssv_line_buffer4.sv",
    "rtl/video/ssv_gfx_row_fetch.sv", "rtl/video/ssv_gfx_row_decode.sv",
    "rtl/video/ssv_bg_renderer.sv", "rtl/video/ssv_cached_sprite_renderer.sv",
    "rtl/audio/ssv_mlab32_sdp.sv", "rtl/audio/ssv_es5506_regs.sv",
    "rtl/audio/ssv_es5506_voice.sv",
    "rtl/cpu/v60/s32_v60.sv", "rtl/cpu/v60/s32_v60_bus.sv",
    "rtl/ssv_core.sv", "verif/ssv_tb_ce_cpu.sv",
]


def chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def ppm_to_png4x(ppm_path: pathlib.Path, png_path: pathlib.Path) -> None:
    data = ppm_path.read_bytes()
    assert data.startswith(b"P6")
    p = 2
    parts: list[str] = []
    while len(parts) < 3:
        while data[p : p + 1] in (b" ", b"\n", b"\r", b"\t"):
            p += 1
        if data[p : p + 1] == b"#":
            while data[p : p + 1] not in (b"\n", b""):
                p += 1
            continue
        s = p
        while data[p : p + 1] not in (b" ", b"\n", b"\r", b"\t"):
            p += 1
        parts.append(data[s:p].decode())
    w, h, maxv = map(int, parts)
    raw = data[p + 1 :]
    need = w * h * 3
    raw = (raw + b"\x00" * need)[:need]
    scale = 4
    W, H = w * scale, h * scale
    out = bytearray(W * H * 3)
    for y in range(h):
        for x in range(w):
            i = (y * w + x) * 3
            c = raw[i : i + 3]
            for dy in range(scale):
                for dx in range(scale):
                    j = ((y * scale + dy) * W + (x * scale + dx)) * 3
                    out[j : j + 3] = c
    rows = b"".join(b"\x00" + bytes(out[y * W * 3 : (y + 1) * W * 3]) for y in range(H))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )
    png_path.write_bytes(png)
    print(f"wrote {png_path} bytes={len(png)}")


def main() -> int:
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    (ROOT / "sim_output" / "frames" / "play").mkdir(parents=True, exist_ok=True)
    (ROOT / "sim_output" / "diff").mkdir(parents=True, exist_ok=True)

    try:
        import resource

        resource.setrlimit(resource.RLIMIT_STACK, (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
    except Exception:
        pass

    print("=== BUILD ===")
    subprocess.run(["verilator-safe", "status"], cwd=ROOT, check=True)
    build = subprocess.run(
        [
            "verilator-safe",
            *VFLAGS,
            "--top-module",
            "tb_ssv_frame_crc",
            "--Mdir",
            str(OUT),
            "-o",
            "tb_ssv_frame_crc",
            "-Iverif",
            *CORE,
            "verif/tb_ssv_frame_crc.sv",
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    (OUT / "build.log").write_text(build.stdout + build.stderr)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        return 1
    print("BUILD OK")

    bin_path = OUT / "tb_ssv_frame_crc"
    cmd = [
        "verilator-sim-safe",
        "--",
        str(bin_path),
        "+SCENARIO=coin_start_p1",
        f"+FRAMES={LAST}",
        f"+SOAK_FRAMES={LAST}",
        "+CYCLES=700000000",
        "+IGNORE_OVERRUN",
        "+FRAME_CRC=sim_output/diff/rtl_play_shots.crc",
        f"+DUMP_PPM_PREFIX={PREFIX.as_posix()}",
        f"+DUMP_PPM_START={START}",
        f"+DUMP_PPM_COUNT={COUNT}",
        f"+DUMP_PPM_STEP={STEP}",
    ]
    print("=== RUN", " ".join(cmd[3:]), "===")
    subprocess.run(["verilator-safe", "status"], cwd=ROOT, check=True)
    run = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    (OUT / "run.log").write_text(run.stdout + run.stderr)
    sys.stdout.write(run.stdout)
    if run.returncode != 0:
        sys.stderr.write(run.stderr[-2000:])
        # Still convert any PPMs that landed.
    for k in range(COUNT):
        f = START + k * STEP
        ppm = pathlib.Path(f"{PREFIX}_f{f}.ppm")
        if not ppm.exists():
            print(f"missing {ppm}")
            continue
        png = pathlib.Path(f"{PREFIX}_f{f}_4x.png")
        root = ROOT / f"play_shot_{k + 1}_4x.png"
        ppm_to_png4x(ppm, png)
        root.write_bytes(png.read_bytes())
        print(f"copied {root.name}")
    return 0 if run.returncode == 0 else run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
