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
AUDIO_ISOLATION_ARGS=()
if [[ "${AUDIO_ISOLATION_DIAGNOSTIC:-0}" == 1 ]]; then
  # This deliberately allows the simulation-only renderer deadline guard to
  # report and continue. It isolates ES5506 host/sample traffic; it is not a
  # full-core acceptance result and must never be enabled for release gates.
  AUDIO_ISOLATION_ARGS+=(+ALLOW_RENDERER_OVERRUN_DIAGNOSTIC)
  echo "AUDIO ISOLATION DIAGNOSTIC: renderer deadline fatal is non-blocking"
fi

VFLAGS=(--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -CFLAGS -D_GLIBCXX_USE_CXX11_ABI=0
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH -Wno-CASEOVERLAP
        -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-UNUSEDSIGNAL
        +define+SIMULATION)

CORE=(
  rtl/ssv_pkg.sv rtl/ssv_irq.sv rtl/ssv_video_timing.sv
  rtl/io/ssv_mahjong_matrix.sv
  rtl/io/ssv_upd4701.sv rtl/io/ssv_upd7001.sv
  rtl/io/ssv_adc0809.sv rtl/io/ssv_93c46_16.sv
  rtl/common/s32_big_dpram.sv
  rtl/video/ssv_palette_ram.sv rtl/video/ssv_line_buffer4.sv
  rtl/video/ssv_gfx_row_fetch.sv rtl/video/ssv_gfx_row_decode.sv
  rtl/video/ssv_st0020_ctrl.sv
  rtl/video/ssv_bg_renderer.sv rtl/video/ssv_mlab240_sdp.sv
  rtl/video/ssv_cached_sprite_renderer.sv
  rtl/audio/ssv_mlab32_sdp.sv
  rtl/audio/ssv_es5506_regs.sv
  rtl/audio/ssv_srmp7_bank.sv
  rtl/audio/ssv_es5506_voice.sv
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv
  # ST010 (uPD96050) DSP: ssv_core instantiates the wrapper unconditionally
  # and gates it on cfg.has_st010, so these are needed by every core build.
  rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv
  rtl/cpu/upd96050/ssv_st010_prg_fetch.sv
  rtl/ssv_core.sv
  verif/ssv_tb_ce_cpu.sv
)

echo "=== BUILD/RUN tb_ssv_es5506_regs ==="
mkdir -p "$OUT/regs"
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_es5506_regs \
  --Mdir "$OUT/regs" -o tb_ssv_es5506_regs \
  rtl/ssv_pkg.sv rtl/audio/ssv_mlab32_sdp.sv rtl/audio/ssv_es5506_regs.sv \
  verif/tb_ssv_es5506_regs.sv \
  >"$OUT/regs/build.log" 2>&1
verilator-safe status
regs_bin="$OUT/regs/tb_ssv_es5506_regs"; [[ -f "$regs_bin.exe" ]] && regs_bin="$regs_bin.exe"
verilator-sim-safe -- "$regs_bin" | tee "$OUT/regs/run.log"

echo "=== BUILD/RUN tb_ssv_es5506_ulaw ==="
mkdir -p "$OUT/ulaw"
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_es5506_ulaw \
  --Mdir "$OUT/ulaw" -o tb_ssv_es5506_ulaw \
  rtl/ssv_pkg.sv verif/tb_ssv_es5506_ulaw.sv \
  >"$OUT/ulaw/build.log" 2>&1
verilator-safe status
ulaw_bin="$OUT/ulaw/tb_ssv_es5506_ulaw"; [[ -f "$ulaw_bin.exe" ]] && ulaw_bin="$ulaw_bin.exe"
verilator-sim-safe -- "$ulaw_bin" | tee "$OUT/ulaw/run.log"

echo "=== BUILD/RUN tb_ssv_es5506_voice ==="
mkdir -p "$OUT/voice"
verilator-safe status
verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_es5506_voice \
  --Mdir "$OUT/voice" -o tb_ssv_es5506_voice \
  rtl/ssv_pkg.sv rtl/audio/ssv_es5506_voice.sv verif/tb_ssv_es5506_voice.sv \
  >"$OUT/voice/build.log" 2>&1
verilator-safe status
voice_bin="$OUT/voice/tb_ssv_es5506_voice"; [[ -f "$voice_bin.exe" ]] && voice_bin="$voice_bin.exe"
verilator-sim-safe -- "$voice_bin" | tee "$OUT/voice/run.log"

if [[ "${UNIT_ONLY:-0}" == 1 ]]; then
  echo "ALL AUDIO CHIP UNIT SIMS PASS"
  exit 0
fi

echo "=== BUILD tb_ssv_realrom_boot (audio gate) ==="
mkdir -p "$OUT/boot"
verilator-safe status
if ! verilator-safe "${VFLAGS[@]}" --top-module tb_ssv_realrom_boot \
  --Mdir "$OUT/boot" -o tb_ssv_realrom_boot \
  "${CORE[@]}" verif/tb_ssv_realrom_boot.sv \
  >"$OUT/boot/build.log" 2>&1; then
  echo "BUILD FAIL tb_ssv_realrom_boot"; tail -80 "$OUT/boot/build.log"; exit 1
fi

echo "=== RUN TRACE_CYCLES=$CYCLES REQUIRE_VE REQUIRE_AUDIO + IRQ schedule ==="
verilator-safe status
boot_bin="$OUT/boot/tb_ssv_realrom_boot"; [[ -f "$boot_bin.exe" ]] && boot_bin="$boot_bin.exe"
verilator-sim-safe -- "$boot_bin" \
  "+TRACE_CYCLES=$CYCLES" \
  +REQUIRE_VE \
  +REQUIRE_AUDIO \
  "+DIFF_IRQ_SCHEDULE=$IRQ_SCHED" \
  "+SAMPLES=sim_output/rom/samples.bin" \
  "+ROM=sim_output/rom/maincpu.bin" \
  "${AUDIO_ISOLATION_ARGS[@]}" \
  | tee "$OUT/boot/run.log"

if [[ "${AUDIO_ISOLATION_DIAGNOSTIC:-0}" == 1 ]]; then
  echo "AUDIO ISOLATION DIAGNOSTIC PASS (not full-core acceptance)"
else
  echo "ALL AUDIO SIMS PASS"
fi
