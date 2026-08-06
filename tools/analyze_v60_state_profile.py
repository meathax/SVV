#!/usr/bin/env python3
"""Report per-FSM-state cycle cost for one V60 opcode from a
+V60_STATE_PROFILE_OP run (verif/tb_ssv_frame_crc.sv).

Input CSV schema: state_id,cycles,entries
"entries" = number of times the FSM transitioned INTO that state while the
target opcode was in flight (distinguishes "visited once, took a while" from
"visited N times per instruction" -- the latter is exactly what would confirm
or refute the "doubled EA resolution" hypothesis in
docs/hardware/V60_CYCLE_PROFILE_FINDINGS.md).

State names are transcribed directly from the st_t enum declaration order in
rtl/cpu/v60/s32_v60.sv (typedef enum logic [6:0] { S_RESET, S_FILL, ... }),
which auto-numbers from 0 -- NOT from memory of any datasheet.
"""
import argparse
import csv
import sys

# rtl/cpu/v60/s32_v60.sv: typedef enum logic [6:0] { ... } st_t; (declaration order)
STATE_NAMES = [
    "S_RESET", "S_FILL", "S_FILLW", "S_DECODE", "S_IF2",
    "S_EA_MODE", "S_EA_IND", "S_EA_IND2", "S_EA_VAL", "S_EA_DONE",
    "S_EXEC", "S_OP2_LD", "S_MULDIV", "S_DIVX", "S_WB_MEM", "S_NEXT",
    "S_RMW_RD", "S_RMW_EX", "S_XCH1", "S_XCH2", "S_ROTC",
    "S_MOVD_RL", "S_MOVD_RH", "S_MOVD_WL", "S_MOVD_WH", "S_DIVXM_RH",
    "S_BR_TAKE", "S_PUSH", "S_POP", "S_PUSHM", "S_POPM",
    "S_JSR1", "S_RET1", "S_RET2", "S_RETI1", "S_RETI2", "S_RETI3",
    "S_CALL1", "S_CALL1b", "S_RSR",
    "S_STR_OP1", "S_STR_OP2", "S_STR_RD", "S_STR_WR", "S_STR_NEXT", "S_STR_FILL",
    "S_DEC_OP1", "S_DEC_OP2", "S_DEC_RD", "S_DEC_EX", "S_DEC_WR",
    "S_BAM_MODE", "S_BAM_IND", "S_BAM_VAL",
    "S_BF_EXT1", "S_BF_EXTW",
    "S_BF_INS1", "S_BF_INS2", "S_BF_INSRD", "S_BF_INSWR",
    "S_BS_SCH1", "S_BS_SCHRD", "S_BS_SCHB", "S_BS_SCHW",
    "S_BS_MOV1", "S_BS_MOV2", "S_BS_MOVS", "S_BS_MOVD", "S_BS_MOVB", "S_BS_MOVF",
    "S_FP_OP2", "S_FP_LD", "S_FP_EXEC", "S_FP_DIV", "S_FP_WB",
    "S_EXC_PUSH1", "S_EXC_EXTRA", "S_EXC_CODE", "S_EXC_PUSH2", "S_EXC_VEC", "S_EXC_JMP",
    "S_TASK_LD_NEXT", "S_TASK_LD_ACK", "S_TASK_ST_NEXT", "S_TASK_ST_ACK",
    "S_TASI1", "S_TASI2",
    "S_PREP1", "S_DISP1",
    "S_HALT",
]


def state_name(idx):
    return STATE_NAMES[idx] if 0 <= idx < len(STATE_NAMES) else f"(unknown state {idx})"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv_path", help="CSV written by +V60_STATE_PROFILE_OUT=")
    ap.add_argument("--op", help="opcode hex this run targeted, for the header only")
    args = ap.parse_args()

    rows = []
    with open(args.csv_path, newline="") as f:
        for row in csv.DictReader(f):
            rows.append({
                "state": int(row["state_id"]),
                "cycles": int(row["cycles"]),
                "entries": int(row["entries"]),
            })

    if not rows:
        print("no state buckets in CSV -- did the target opcode ever execute in this window?",
              file=sys.stderr)
        return 1

    total_cycles = sum(r["cycles"] for r in rows)
    rows.sort(key=lambda r: r["cycles"], reverse=True)

    op_label = f" (op=0x{args.op})" if args.op else ""
    print(f"# V60 per-state profile{op_label}: {total_cycles} total clk_sys ticks across {len(rows)} states")
    print(f"# 'entries' = count of transitions INTO that state; entries > count of retired")
    print(f"# instructions in the same window means this state is visited MORE THAN ONCE")
    print(f"# per instruction on average -- direct evidence for/against a doubled-pass hypothesis.")
    print()
    header = f"{'state':<16} {'cycles':>10} {'pct':>6} {'entries':>8} {'cyc/entry':>10}"
    print(header)
    print("-" * len(header))
    for r in rows:
        pct = 100.0 * r["cycles"] / total_cycles
        cyc_per_entry = r["cycles"] / r["entries"] if r["entries"] else 0.0
        print(f"{state_name(r['state']):<16} {r['cycles']:>10} {pct:>5.1f}% "
              f"{r['entries']:>8} {cyc_per_entry:>10.2f}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
