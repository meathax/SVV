#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the `new` and `old` builds from tools/ab-build-variant.sh over
# coin_start_p1_gameplay, writing frame CRCs and PPM captures to sim_output/ab/.
# Expects the binaries in /tmp/ab/{new,old}.  Needs `ulimit -s unlimited`.
#
# See docs/DYNAGEAR_TILEMAP_PAGE_FIX_MAME_VERIFICATION.md.
set -u
cd "$(dirname "$0")/.."
R="$PWD"
ulimit -s unlimited
OUT="$R/sim_output/ab"
mkdir -p "$OUT/ppm" "$OUT/log"

ROMS="+MAINROM=$R/sim_output/rom/maincpu.bin +SPRROM=$R/sim_output/rom/sprites.bin"
DET="+verilator+seed+1 +verilator+rand+reset+2"

run() {  # run <variant> <tag> <frames> <cycles> <ppm_start> <ppm_step> <ppm_count>
  local v="$1" tag="$2" frames="$3" cyc="$4" ps="$5" pst="$6" pc="$7"
  /tmp/ab/$v/tb_ssv_frame_crc $ROMS $DET \
    +SCENARIO=coin_start_p1_gameplay \
    +FRAMES=$frames +SOAK_FRAMES=30 +CYCLES=$cyc \
    +IGNORE_OVERRUN \
    +FRAME_CRC=$OUT/${tag}.crc \
    +DUMP_PPM_PREFIX=$OUT/ppm/${tag} \
    +DUMP_PPM_START=$ps +DUMP_PPM_STEP=$pst +DUMP_PPM_COUNT=$pc \
    > "$OUT/log/${tag}.log" 2>&1
  echo "done ${tag} rc=$? $(tail -1 "$OUT/log/${tag}.log" | cut -c1-80)"
}

run new new950 950 900000000 200 50 15 &
run old old950 950 900000000 200 50 15 &
run new new_early 200 250000000 170 1 20 &
run old old_early 200 250000000 170 1 20 &
wait
echo ALL_DONE
