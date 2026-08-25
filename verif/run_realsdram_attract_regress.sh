#!/usr/bin/env bash
# Real-SDRAM attract regression across sets.
#
# Guards the sound-priority arbitration change in rtl/mem/sdram.sv: the sample
# port now wins ahead of the round-robin, so this checks that video still
# renders and the renderer never overruns for every set, on the memory model
# that actually arbitrates. Also reports the realised ES5506 stream rate, which
# is what the change exists to protect.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN:-/mnt/r/Verilator/SVV/keyon/tb_ssv_frame_crc}"
[[ -f "$BIN.exe" ]] && BIN="$BIN.exe"
FRAMES="${FRAMES:-150}"
OUTDIR="${OUTDIR:-sim_output/realsdram_regress}"
mkdir -p "$OUTDIR"

# setname:id. Sets without an ST010 image simply omit the plusarg.
SETS="${SETS:-dynagear:0 vasara:2 drifto94:4 twineag2:6}"

status=0
for entry in $SETS; do
  name="${entry%%:*}"
  id="${entry##*:}"
  image="sim_output/rom/$name"
  args=(+GAME_ID="$id" +DSW1=FFFF +DSW2=FFFF
        +MAINROM="$image/maincpu.bin" +SPRROM="$image/sprites.bin"
        +SMPROM="$image/samples.bin"
        +SCENARIO=attract_idle +FRAMES="$FRAMES" +SOAK_FRAMES=0
        +CYCLES=2000000000 +REAL_SDRAM)
  [[ -f "$image/st010.bin" ]] && args+=(+ST010ROM="$image/st010.bin")

  log="$OUTDIR/$name.log"
  "$BIN" "${args[@]}" >"$log" 2>&1
  line="$(grep -aE '^PASS tb_ssv_frame_crc' "$log" | tail -1)"
  rate="$(grep -aE '^AUDIO_RATE' "$log" | tail -1)"
  if [[ -n "$line" ]]; then
    ovr="$(sed -n 's/.*\(overruns bg=[0-9]* obj=[0-9]*\).*/\1/p' <<<"$line")"
    echo "OK   $name  $ovr  $rate"
  else
    echo "FAIL $name  $(grep -aE 'Fatal|Assertion' "$log" | tail -1)"
    status=1
  fi
done
exit $status
