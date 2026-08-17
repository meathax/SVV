#!/bin/sh
# V60 differential regression: reference model vs RTL over N random seeds.
set -e
cd "$(dirname "$0")/../.."
N="${1:-20}"
T=$(mktemp -d)
# -DSIMULATION is REQUIRED, not optional: dbg_pc/dbg_halted in s32_v60.sv are
# inside `ifdef SIMULATION, and tb_v60_diff.sv reads them.  Without it every
# elaboration fails.  The old `2>/dev/null` then hid the error text, and with
# `set -e` the script exited before printing anything at all -- a silent no-op
# that reads as success to a caller checking only for absence of FAIL output.
# Keep stderr visible so a broken build can never masquerade as a passing run.
if ! iverilog -g2012 -DSIMULATION -o "$T/tb_diff" \
     rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_diff.sv; then
    echo "V60 DIFF: BUILD FAILED (iverilog elaboration error above)" >&2
    rm -rf "$T"
    exit 1
fi
python3 verif/cosim/v60_ref.py >/dev/null   # self-test the model first
fail=0
for s in $(seq 1 "$N"); do
    python3 verif/cosim/gen_diff_program.py "$s" "$T/p$s" >/dev/null
    vvp "$T/tb_diff" +hex="$T/p$s.hex" 2>/dev/null | grep -E '^[RM][0-9]=' > "$T/r$s.rtl"
    if diff -q "$T/p$s.expected" "$T/r$s.rtl" >/dev/null; then
        :
    else
        echo "SEED $s DIVERGES:"
        diff "$T/p$s.expected" "$T/r$s.rtl" | head -8
        fail=$((fail+1))
    fi
done
if [ "$fail" -eq 0 ]; then echo "V60 DIFF: PASS ($N/$N seeds match reference)"; else echo "V60 DIFF: FAIL ($fail/$N)"; fi
rm -rf "$T"
[ "$fail" -eq 0 ]
