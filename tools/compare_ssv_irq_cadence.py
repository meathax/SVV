#!/usr/bin/env python3
"""Bind the first V60 IRQ-cadence divergence without resynchronising traces.

The comparison starts at one exact architectural state (PC plus R2/R16), then
checks the next MAME debugger instruction against the next RTL retire.  It also
records the raster-side RTL IRQ request/ack around that boundary and proves
whether MAME entered the configured handler after the aligned state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


SSVREG_RE = re.compile(
    r"^SSVREG cursor=(?P<cursor>\d+) pc=(?P<pc>[0-9A-Fa-f]+) "
    r"opcode=(?P<opcode>[0-9A-Fa-f]+) psw=(?P<psw>[0-9A-Fa-f]+)"
    r"(?: beamx=(?P<beamx>\d+) beamy=(?P<beamy>\d+))?.*"
    r"r2=(?P<r2>[0-9A-Fa-f]+).*r16=(?P<r16>[0-9A-Fa-f]+)"
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_hex(value: str) -> int:
    return int(value, 16)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mame_debugger", type=Path)
    parser.add_argument("mame_irq", type=Path)
    parser.add_argument("rtl", type=Path)
    parser.add_argument("--mame-cursor", type=int, required=True)
    parser.add_argument("--rtl-post-epoch-frame", type=int, required=True)
    parser.add_argument("--start-pc", type=parse_hex, required=True)
    parser.add_argument("--start-r2", type=parse_hex, required=True)
    parser.add_argument("--start-r16", type=parse_hex, required=True)
    parser.add_argument("--handler-pc", type=parse_hex, required=True)
    parser.add_argument(
        "--mame-occurrence", type=int, default=0,
        help="zero-based exact-state occurrence to align (default: 0)",
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    mame_lines = args.mame_debugger.read_text(encoding="ascii", errors="replace").splitlines()
    target_matches = []
    for index, line in enumerate(mame_lines):
        match = SSVREG_RE.match(line)
        if not match:
            continue
        values = {}
        for name, value in match.groupdict().items():
            if name == "cursor" or value is None:
                continue
            values[name] = int(value, 16) if name not in {"beamx", "beamy"} else int(value)
        if (int(match.group("cursor")) == args.mame_cursor and
                values["pc"] == args.start_pc and
                values["r2"] == args.start_r2 and
                values["r16"] == args.start_r16):
            target_matches.append((index, {
                "input_cursor": args.mame_cursor,
                **values,
            }))
    if not target_matches:
        raise ValueError("MAME exact start state not found")
    if args.mame_occurrence < 0 or args.mame_occurrence >= len(target_matches):
        raise ValueError(
            f"MAME exact start state occurrence {args.mame_occurrence} is unavailable "
            f"(matches={len(target_matches)})"
        )
    target_index, target = target_matches[args.mame_occurrence]

    mame_next = None
    handler_before = 0
    handler_after = 0
    for line in mame_lines[:target_index]:
        match = SSVREG_RE.match(line)
        if match and int(match.group("pc"), 16) == args.handler_pc:
            handler_before += 1
    for line in mame_lines[target_index + 1 :]:
        match = SSVREG_RE.match(line)
        if not match:
            continue
        pc = int(match.group("pc"), 16)
        if mame_next is None:
            mame_next = {
                "input_cursor": int(match.group("cursor")),
                "pc": pc,
                "opcode": int(match.group("opcode"), 16),
                "psw": int(match.group("psw"), 16),
            }
            if match.group("beamx") is not None:
                mame_next["beamx"] = int(match.group("beamx"))
                mame_next["beamy"] = int(match.group("beamy"))
        if pc == args.handler_pc:
            handler_after += 1

    rtl_records = []
    irq_records = []
    with args.rtl.open("r", encoding="utf-8-sig") as stream:
        for line in stream:
            if not line.strip():
                continue
            record = json.loads(line)
            if (record.get("domain") == "v60_retire" and
                    record.get("post_epoch_frame") == args.rtl_post_epoch_frame):
                rtl_records.append(record)
            if record.get("domain") == "irq":
                irq_records.append(record)
    rtl_target_index = None
    for index, record in enumerate(rtl_records):
        if (record.get("pc") == args.start_pc and
                record.get("r2") == args.start_r2 and
                record.get("r16") == args.start_r16):
            rtl_target_index = index
            break
    if rtl_target_index is None:
        raise ValueError("RTL exact start state not found")
    rtl_target = rtl_records[rtl_target_index]
    if rtl_target_index + 1 >= len(rtl_records):
        raise ValueError("RTL trace has no post-start instruction")
    rtl_next = rtl_records[rtl_target_index + 1]

    irq_window = []
    target_cycle = int(rtl_target.get("cycle", 0))
    next_cycle = int(rtl_next.get("cycle", target_cycle))
    for record in irq_records:
        cycle = int(record.get("cycle", -1))
        if target_cycle - 64 <= cycle <= next_cycle + 64:
            irq_window.append(record)

    mame_irq_entries = []
    with args.mame_irq.open("r", encoding="utf-8-sig") as stream:
        for line in stream:
            if not line.strip() or line.lstrip().startswith("{") and '"domain"' not in line:
                continue
            record = json.loads(line)
            if record.get("domain") == "v60_irq_entry":
                mame_irq_entries.append(record)

    result = {
        "schema": "ssv-v60-irq-cadence-compare-v1",
        "mame_debugger": str(args.mame_debugger),
        "mame_debugger_sha256": sha256(args.mame_debugger),
        "mame_irq": str(args.mame_irq),
        "mame_irq_sha256": sha256(args.mame_irq),
        "rtl_trace": str(args.rtl),
        "rtl_sha256": sha256(args.rtl),
        "mame_cursor": args.mame_cursor,
        "mame_start_occurrence": args.mame_occurrence,
        "mame_start_matches": len(target_matches),
        "rtl_post_epoch_frame": args.rtl_post_epoch_frame,
        "start": target,
        "mame_next": mame_next,
        "rtl_next": rtl_next,
        "mame_irq_entries_total": len(mame_irq_entries),
        "mame_handler_entries_before_start": handler_before,
        "mame_handler_entries_after_start": handler_after,
        "rtl_irq_window": irq_window,
        "verdict": "divergence" if (mame_next is None or
                                      mame_next.get("pc") != rtl_next.get("pc")) else "match",
        "selected_cause": "natural_irq_cadence" if irq_window and handler_after == 0 else None,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
