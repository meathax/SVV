#!/usr/bin/env python3
"""Rank V60 opcode overspend from a +V60_CYCLE_PROFILE CSV against hardware
targets from docs/hardware/V60_CYCLE_TIMING_REFERENCE.md.

Input CSV schema (written by verif/tb_ssv_frame_crc.sv):
    opcode_hex,count,total_clk_sys,min_clk_sys,max_clk_sys,avg_clk_sys

CLK_SYS_PER_V60_CLOCK converts clk_sys ticks to V60-clock-equivalent using
the project's fixed 704/315 clock ratio (48.317307 MHz / 16 MHz).

Opcode-to-mnemonic labels below are limited to bytes this project can cite
directly from rtl/cpu/v60/s32_v60.sv's own literal opcode comparisons
(grep-verified, cited by file:line) -- NOT reconstructed from memory of a
scanned datasheet page. Everything else is reported unlabeled so a wrong
guess is never presented as fact; cross-reference
docs/hardware/refs/NEC_V60pgmRef.pdf Appendix A to name them precisely
before drawing conclusions from an unlabeled row.
"""
import argparse
import csv
import sys

CLK_SYS_PER_V60_CLOCK = 704.0 / 315.0  # 48.317307 MHz / 16 MHz, per core-debug.toml ratio

# Generic hardware floors from docs/hardware/V60_CYCLE_TIMING_REFERENCE.md S1
# Table 5 (V60 clocks). Used as an "at least this cheap on real silicon"
# baseline per class, converted to clk_sys ticks for the excess-cycle ranking.
FLOOR_SIMPLE_V60_CLOCKS = 2.0     # ADD reg,reg / branch not-taken lower bound
FLOOR_BRANCH_TAKEN_V60_CLOCKS = 11.0
FLOOR_MUL_V60_CLOCKS = 23.0
FLOOR_DIV_V60_CLOCKS = 43.0
MAME_FLAT_V60_CLOCKS = 8.0        # src/devices/cpu/v60/v60.cpp:626 -- reference only, not a target

# RTL-literal-sourced labels only (grep rtl/cpu/v60/s32_v60.sv for the cited line).
KNOWN_OPCODES = {
    0x86: ("MULX", FLOOR_MUL_V60_CLOCKS, "s32_v60.sv: mul_signed = (cur_op == 8'h86)"),
    0xA6: ("DIVX", FLOOR_DIV_V60_CLOCKS, "s32_v60.sv: cur_op == 8'ha6 // DIVX (signed)"),
    0x97: ("SET1", FLOOR_SIMPLE_V60_CLOCKS, "s32_v60.sv: (cur_op == 8'h97) ? ... // SET1"),
    0xA7: ("CLR1", FLOOR_SIMPLE_V60_CLOCKS, "s32_v60.sv: (cur_op == 8'ha7) ? ... // CLR1"),
    0xB7: ("NOT1", FLOOR_SIMPLE_V60_CLOCKS, "s32_v60.sv: (cur_op == 8'hb7) ? ... // NOT1"),
    0x58: ("STRING.B", FLOOR_SIMPLE_V60_CLOCKS, "s32_v60.sv: cur_op[1] selects byte/half // 0x58=byte"),
    0x5A: ("STRING.H", FLOOR_SIMPLE_V60_CLOCKS, "s32_v60.sv: cur_op[1] selects byte/half // 0x5a=half"),
    0x5B: ("BAM-related (0x5b)", FLOOR_SIMPLE_V60_CLOCKS, "s32_v60.sv: cur_op == 8'h5b (bam_base / +1/+4 step)"),
    0x5F: ("reserved/fallthrough (0x5f)", None, "s32_v60.sv: if (cur_op == 8'h5f) ... latent per DYNAGEAR_CORE_AUDIT.md"),
}


def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            rows.append({
                "opcode": int(row["opcode_hex"], 16),
                "count": int(row["count"]),
                "total": int(row["total_clk_sys"]),
                "min": int(row["min_clk_sys"]),
                "max": int(row["max_clk_sys"]),
                "avg": float(row["avg_clk_sys"]),
            })
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv_path", help="CSV written by +V60_CYCLE_PROFILE_OUT=")
    ap.add_argument("--top", type=int, default=32, help="rows to print (default 32)")
    args = ap.parse_args()

    rows = load_csv(args.csv_path)
    if not rows:
        print("no opcode buckets in CSV -- did the profiled window ever retire an instruction?",
              file=sys.stderr)
        return 1

    total_instrs = sum(r["count"] for r in rows)
    total_cycles = sum(r["total"] for r in rows)

    for r in rows:
        label, floor_v60, cite = KNOWN_OPCODES.get(r["opcode"], (None, None, None))
        floor_v60 = floor_v60 if floor_v60 is not None else FLOOR_SIMPLE_V60_CLOCKS
        floor_clk_sys = floor_v60 * CLK_SYS_PER_V60_CLOCK
        r["label"] = label
        r["cite"] = cite
        r["avg_v60_clocks"] = r["avg"] / CLK_SYS_PER_V60_CLOCK
        r["excess_per_instr"] = max(0.0, r["avg"] - floor_clk_sys)
        r["excess_total"] = r["excess_per_instr"] * r["count"]

    rows.sort(key=lambda r: r["excess_total"], reverse=True)

    print(f"# V60 cycle profile: {total_instrs} instructions, "
          f"{total_cycles} clk_sys ticks total, "
          f"{len(rows)} distinct opcode bytes seen")
    print(f"# clk_sys/V60-clock ratio = {CLK_SYS_PER_V60_CLOCK:.6f} "
          f"(704/315, 48.317307 MHz / 16 MHz)")
    print(f"# MAME's flat model (v60.cpp:626) = {MAME_FLAT_V60_CLOCKS:.0f} V60 clocks/instr "
          f"= {MAME_FLAT_V60_CLOCKS * CLK_SYS_PER_V60_CLOCK:.1f} clk_sys -- reference only, not a target")
    print()
    header = (f"{'op':>4} {'label':<24} {'count':>8} {'avg_clk_sys':>12} "
              f"{'avg_v60clk':>11} {'excess_tot':>12} {'cite'}")
    print(header)
    print("-" * len(header))
    for r in rows[: args.top]:
        label = r["label"] or "(unclassified)"
        cite = r["cite"] or "-- cross-ref NEC_V60pgmRef.pdf Appendix A before naming"
        print(f"0x{r['opcode']:02x} {label:<24} {r['count']:>8} {r['avg']:>12.2f} "
              f"{r['avg_v60_clocks']:>11.2f} {r['excess_total']:>12.0f} {cite}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
