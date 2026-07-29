#!/usr/bin/env bash
# Dump one Verilator attract-mode frame as PPM/PNG.
set -euo pipefail
cd "$(dirname "$0")/.."

ulimit -s unlimited 2>/dev/null || ulimit -s 65536

OUT="${TMPDIR:-/tmp}/ssv-attract-shot"
mkdir -p "$OUT" sim_output/frames sim_output/diff

VFLAGS=(--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION)
CORE=(
  rtl/ssv_pkg.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  rtl/ssv_debug_overlay.sv rtl/ssv_core.sv
  verif/ssv_tb_ce_cpu.sv
)

PPM_FRAME="${PPM_FRAME:-2}"
PPM_PATH="sim_output/frames/verilator_attract_f${PPM_FRAME}.ppm"
PNG_PATH="sim_output/frames/verilator_attract_f${PPM_FRAME}.png"
export PPM_PATH_ENV="$PPM_PATH"
export PNG_PATH_ENV="$PNG_PATH"

echo "=== BUILD tb_ssv_frame_crc ==="
verilator-safe status
if ! verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_frame_crc \
  --Mdir "$OUT" -o tb_ssv_frame_crc -Iverif "${CORE[@]}" verif/tb_ssv_frame_crc.sv \
  >"$OUT/build.log" 2>&1; then
  echo "BUILD FAIL"; tail -50 "$OUT/build.log"; exit 1
fi
echo "BUILD OK"

echo "=== RUN attract_idle DUMP_PPM_FRAME=$PPM_FRAME ==="
verilator-safe status
verilator-sim-safe -- "$OUT/tb_ssv_frame_crc" \
  +SCENARIO=attract_idle \
  +FRAMES=8 +SOAK_FRAMES=5 \
  +FRAME_CRC=sim_output/diff/rtl_attract_shot.crc \
  "+DUMP_PPM=$PPM_PATH" \
  "+DUMP_PPM_FRAME=$PPM_FRAME" \
  | tee "$OUT/run.log"

echo "=== CONVERT PPM -> PNG ==="
python3 - <<'PY'
import struct, zlib, pathlib, os
ppm_path = os.environ.get("PPM_PATH_ENV")
png_path = os.environ.get("PNG_PATH_ENV")
data = pathlib.Path(ppm_path).read_bytes()
assert data.startswith(b"P6")
p = 2
parts = []
while len(parts) < 3:
    while data[p:p+1] in (b" ", b"\n", b"\r", b"\t"):
        p += 1
    if data[p:p+1] == b"#":
        while data[p:p+1] not in (b"\n", b""):
            p += 1
        continue
    s = p
    while data[p:p+1] not in (b" ", b"\n", b"\r", b"\t"):
        p += 1
    parts.append(data[s:p].decode())
w, h, maxv = map(int, parts)
assert maxv == 255
raw = data[p+1:]
need = w * h * 3
if len(raw) < need:
    raw = raw + b"\x00" * (need - len(raw))
else:
    raw = raw[:need]

def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload +
            struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff))

rows = b"".join(b"\x00" + raw[y*w*3:(y+1)*w*3] for y in range(h))
png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
       chunk(b"IDAT", zlib.compress(rows, 9)) +
       chunk(b"IEND", b""))
pathlib.Path(png_path).write_bytes(png)
print("wrote", png_path, (w, h), "bytes", len(png), "raw", len(raw))
PY
ls -la "$PPM_PATH" "$PNG_PATH"
grep -E 'FRAME0|DUMP_PPM|PASS tb_ssv' "$OUT/run.log" || true
