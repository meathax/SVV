#!/usr/bin/env bash
# ES5506 register + voice unit tests, then realrom attract audio gate.
set -euo pipefail
cd "$(dirname "$0")/.."

# Realrom TB holds ~5 MiB of ROM/sample images; Verilator can place large
# unpacked arrays on the C stack. Default 8 MiB ulimit segfaults mid-run.
ulimit -s unlimited 2>/dev/null || ulimit -s 65536

OUT="${TMPDIR:-/tmp}/ssv-audio"
mkdir -p "$OUT" sim_output/diff
CYCLES="${TRACE_CYCLES:-120000000}"
IRQ_SCHED="${IRQ_SCHED:-sim_output/diff/mame_irq_schedule_8s.txt}"
if [[ ! -f "$IRQ_SCHED" ]]; then
  IRQ_SCHED="sim_output/diff/mame_irq_schedule_long.txt"
fi

VFLAGS=(--binary --timing -j 0 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
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
  rtl/audio/ssv_mlab32_sdp.sv
  rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  rtl/ssv_core.sv
  verif/ssv_tb_ce_cpu.sv
)

echo "=== BUILD/RUN tb_ssv_es5506_regs ==="
rm -rf "$OUT/regs"; mkdir -p "$OUT/regs"
verilator "${VFLAGS[@]}" --top-module tb_ssv_es5506_regs \
  --Mdir "$OUT/regs" -o tb_ssv_es5506_regs \
  rtl/ssv_pkg.sv rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv \
  verif/tb_ssv_es5506_regs.sv \
  >"$OUT/regs/build.log" 2>&1
"$OUT/regs/tb_ssv_es5506_regs" | tee "$OUT/regs/run.log"

echo "=== BUILD/RUN tb_ssv_es5506_voice ==="
rm -rf "$OUT/voice"; mkdir -p "$OUT/voice"
verilator "${VFLAGS[@]}" --top-module tb_ssv_es5506_voice \
  --Mdir "$OUT/voice" -o tb_ssv_es5506_voice \
  rtl/ssv_pkg.sv rtl/audio/ssv_es5506_voice.sv verif/tb_ssv_es5506_voice.sv \
  >"$OUT/voice/build.log" 2>&1
"$OUT/voice/tb_ssv_es5506_voice" | tee "$OUT/voice/run.log"

echo "=== BUILD tb_ssv_realrom_boot (audio gate) ==="
rm -rf "$OUT/boot"; mkdir -p "$OUT/boot"
if ! verilator "${VFLAGS[@]}" --top-module tb_ssv_realrom_boot \
  --Mdir "$OUT/boot" -o tb_ssv_realrom_boot \
  "${CORE[@]}" verif/tb_ssv_realrom_boot.sv \
  >"$OUT/boot/build.log" 2>&1; then
  echo "BUILD FAIL tb_ssv_realrom_boot"; tail -80 "$OUT/boot/build.log"; exit 1
fi

echo "=== RUN TRACE_CYCLES=$CYCLES REQUIRE_VE REQUIRE_AUDIO + IRQ schedule ==="
"$OUT/boot/tb_ssv_realrom_boot" \
  "+TRACE_CYCLES=$CYCLES" \
  +REQUIRE_VE \
  +REQUIRE_AUDIO \
  "+DIFF_IRQ_SCHEDULE=$IRQ_SCHED" \
  "+SAMPLES=sim_output/rom/samples.bin" \
  "+ROM=sim_output/rom/maincpu.bin" \
  | tee "$OUT/boot/run.log"

echo "ALL AUDIO SIMS PASS"
