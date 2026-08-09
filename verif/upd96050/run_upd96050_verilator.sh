#!/usr/bin/env bash
# Verilator unit-test runner for the uPD96050 (ST010) core.
#
# Runs ONE build and ONE simulation at a time on purpose: the machine-wide cap
# is two Verilator processes and another agent may be building. Do not add
# background jobs here, and do not raise -j past 4.
#
# Usage (from repo root, under WSL):  bash verif/upd96050/run_upd96050_verilator.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RTL="rtl/common/s32_big_dpram.sv rtl/cpu/upd96050/upd96050.sv rtl/cpu/upd96050/upd96050_st010.sv"

VFLAGS="--binary --timing --assert --threads 1 --verilate-jobs 4 --build-jobs 4
        -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
        -Wno-CASEINCOMPLETE -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED
        -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-BLKANDNBLK
        --x-assign unique --x-initial unique
        +define+SIMULATION -Iverif/upd96050"

SIMARGS="+verilator+seed+1 +verilator+rand+reset+2"

declare -A TB=(
  [tb_upd96050_isa]="UPD96050 ISA PASS"
  [tb_upd96050_window]="UPD96050 WINDOW PASS"
  [tb_upd96050_dataport]="UPD96050 DATAPORT PASS"
)
ORDER="tb_upd96050_isa tb_upd96050_window tb_upd96050_dataport"

# The ISA bench is re-run with a stalling program fetch, which is what an
# SDRAM-backed program ROM behaves like. Same expected output.
EXTRA_ISA_LAT=8

OUTDIR="${TMPDIR:-/tmp}/upd96050ut-ssv"
mkdir -p "$OUTDIR"
pass=0; fail=0; failed=""
for tb in $ORDER; do
  src="verif/upd96050/${tb}.sv"
  [ -f "$src" ] || { echo "SKIP  $tb (no file)"; continue; }
  bdir="$OUTDIR/$tb"; mkdir -p "$bdir"
  if ! nice -n 19 verilator $VFLAGS --top-module "$tb" --Mdir "$bdir" \
        -o "$tb" $RTL "$src" > "$bdir.log" 2>&1; then
    echo "BUILDFAIL $tb  (see $bdir.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
  fi
  out="$(nice -n 19 "$bdir/$tb" $SIMARGS 2>&1)"
  if echo "$out" | grep -qF "${TB[$tb]}"; then
    echo "PASS  $tb   $(echo "$out" | grep -E '[0-9]+ passed' | head -1)"
    pass=$((pass+1))
  else
    echo "FAIL  $tb   (expected '${TB[$tb]}')"
    echo "$out" | grep -E 'FAIL|passed' | head -20 | sed 's/^/        /'
    fail=$((fail+1)); failed="$failed $tb"
  fi
done

# Re-run the ISA suite with a stalled fetch port, reusing the built binary.
if [ -x "$OUTDIR/tb_upd96050_isa/tb_upd96050_isa" ]; then
  out="$(nice -n 19 "$OUTDIR/tb_upd96050_isa/tb_upd96050_isa" $SIMARGS \
         +PRGLAT=$EXTRA_ISA_LAT 2>&1)"
  if echo "$out" | grep -qF "UPD96050 ISA PASS"; then
    echo "PASS  tb_upd96050_isa(PRGLAT=$EXTRA_ISA_LAT)   $(echo "$out" | grep -E '[0-9]+ passed' | head -1)"
    pass=$((pass+1))
  else
    echo "FAIL  tb_upd96050_isa(PRGLAT=$EXTRA_ISA_LAT)"
    echo "$out" | grep -E 'FAIL|passed' | head -20 | sed 's/^/        /'
    fail=$((fail+1)); failed="$failed tb_upd96050_isa(stalled)"
  fi
fi

echo "======================================================"
echo "UPD96050 VERILATOR UNIT: $pass passed, $fail failed${failed:+ -> FAILED:$failed}"
[ "$fail" -eq 0 ] && echo "UPD96050 VERILATOR UNIT: ALL PASS"
exit $fail
