#!/usr/bin/env python3
"""Finalize one SSV MAME JSONL trace without materializing the whole stream."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def integer(value: object, label: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{label} is not an integer: {value!r}") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--journal-sha256", required=True)
    parser.add_argument("--strict-only", action="store_true")
    parser.add_argument("--irq-handler-pc", type=int, default=-1)
    parser.add_argument("--expected-frames", type=int, default=-1)
    parser.add_argument("--neutral-after-frame", type=int, default=-1)
    args = parser.parse_args()

    receipt_records: list[dict] = []
    contract_records: list[dict] = []
    stop_count = 0
    mainbus_count = 0
    cpu_data_count = 0
    frame_count = 0
    gameplay_entries: list[dict] = []

    try:
        with args.trace.open("r", encoding="utf-8-sig") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ValueError(
                        f"invalid JSON in MAME trace at line {line_number}: {exc}"
                    ) from exc
                if not isinstance(record, dict):
                    raise ValueError(f"MAME trace line {line_number} is not an object")

                if record.get("record") == "receipt":
                    receipt_records.append(record)
                if record.get("record") == "contract":
                    contract_records.append(record)
                if record.get("record") == "barrier":
                    if record.get("name") == "stop":
                        stop_count += 1
                    if record.get("name") == "gameplay_entry":
                        gameplay_entries.append(record)
                    if record.get("name") == "frame_complete":
                        post_epoch_frame = integer(
                            record.get("post_epoch_frame"),
                            "frame_complete.post_epoch_frame",
                        )
                        input_cursor = integer(
                            record.get("input_cursor"),
                            "frame_complete.input_cursor",
                        )
                        if post_epoch_frame != frame_count or input_cursor != frame_count:
                            raise ValueError(
                                "MAME frame cursor is not contiguous at ordinal "
                                f"{frame_count}"
                            )
                        if "frame_crc32" not in record:
                            raise ValueError(
                                f"MAME frame metadata lacks frame_crc32 at frame {frame_count}"
                            )
                        if (
                            args.neutral_after_frame >= 0
                            and input_cursor >= args.neutral_after_frame
                            and any(
                                integer(record.get(field, 0), field) != 0
                                for field in (
                                    "p1_pressed",
                                    "p2_pressed",
                                    "system_pressed",
                                )
                            )
                        ):
                            raise ValueError(
                                "MAME frame metadata reports non-neutral input after "
                                f"gameplay entry frame {args.neutral_after_frame}"
                            )
                        frame_count += 1

                if record.get("domain") == "mainbus":
                    sequence = integer(record.get("seq"), "mainbus.seq")
                    if sequence != mainbus_count:
                        raise ValueError(
                            f"MAME mainbus sequence is not contiguous at ordinal {mainbus_count}"
                        )
                    mainbus_count += 1
                    if integer(record.get("device"), "mainbus.device") != 1:
                        cpu_data_count += 1

        if len(receipt_records) != 1:
            raise ValueError("MAME trace must contain exactly one final receipt")
        receipt = receipt_records[0]
        if (
            receipt.get("complete") is not True
            or integer(receipt.get("dropped"), "receipt.dropped") != 0
            or receipt.get("reason") != "stop_barrier"
        ):
            raise ValueError("MAME receipt is incomplete, aborted, or reports drops")
        if integer(receipt.get("coin_impulse"), "receipt.coin_impulse") != -1:
            raise ValueError("MAME receipt does not attest disabled frontend coin impulse")

        if len(contract_records) != 1:
            raise ValueError("MAME trace must contain exactly one contract record")
        contract = contract_records[0]
        if integer(contract.get("coin_impulse"), "contract.coin_impulse") != -1:
            raise ValueError("MAME trace contract does not pin coin_impulse=-1")
        if str(contract.get("journal_sha256", "")) != args.journal_sha256:
            raise ValueError("MAME trace contract journal digest does not match the input journal")
        if args.strict_only and contract.get("strict_only") is not True:
            raise ValueError("MAME trace contract does not attest strict-only output")
        if args.irq_handler_pc >= 0:
            if (
                integer(contract.get("irq_handler_pc"), "contract.irq_handler_pc")
                != args.irq_handler_pc
                or contract.get("irq_entry_trace") is not True
            ):
                raise ValueError("MAME trace contract does not attest the requested IRQ probe")

        if stop_count != 1:
            raise ValueError("MAME trace must contain exactly one completed stop barrier")
        counts = receipt.get("counts")
        if not isinstance(counts, dict):
            raise ValueError("MAME receipt lacks counts")
        if integer(counts.get("mainbus"), "receipt.counts.mainbus") != mainbus_count:
            raise ValueError(
                f"MAME receipt mainbus count does not match trace: {mainbus_count}"
            )
        if integer(counts.get("cpu_data"), "receipt.counts.cpu_data") != cpu_data_count:
            raise ValueError("MAME receipt cpu_data count does not match trace")
        if integer(receipt.get("frames"), "receipt.frames") != frame_count or integer(
            receipt.get("expected_frames"), "receipt.expected_frames"
        ) != frame_count:
            raise ValueError("MAME receipt frame count does not match frame metadata")

        if args.expected_frames >= 0 and frame_count != args.expected_frames:
            raise ValueError(
                f"MAME capture frame count {frame_count} does not equal declared "
                f"{args.expected_frames}"
            )
        if args.expected_frames >= 0:
            if len(gameplay_entries) != 1:
                raise ValueError("MAME capture must contain exactly one gameplay_entry barrier")
            entry = gameplay_entries[0]
            if (
                integer(entry.get("input_cursor"), "gameplay_entry.input_cursor")
                != args.neutral_after_frame
                or integer(
                    entry.get("neutral_after_frame"),
                    "gameplay_entry.neutral_after_frame",
                )
                != args.neutral_after_frame
                or receipt.get("gameplay_entry_seen") is not True
            ):
                raise ValueError("MAME gameplay_entry barrier does not match the scenario")

        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(
            "MAME_TRACE_FINALIZED "
            f"frames={frame_count} mainbus={mainbus_count} cpu_data={cpu_data_count}"
        )
        return 0
    except (OSError, ValueError) as exc:
        print(f"MAME_TRACE_FINALIZE_ERROR {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
