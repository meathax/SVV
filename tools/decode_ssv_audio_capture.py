#!/usr/bin/env python3
import csv
import json
import sys
from pathlib import Path


CORE = "emu:emu|ssv_core:core|stp_core_trace"
OUT = "emu:emu|stp_output_audio_trace"


def bit_name(prefix: str, bit: int) -> str:
    return f"{prefix}[{bit}]"


def bit(row: dict[str, str], prefix: str, index: int):
    value = row.get(bit_name(prefix, index), "X").strip()
    return int(value) if value in {"0", "1"} else None


def uint(row: dict[str, str], prefix: str, low: int, high: int):
    value = 0
    for index in range(low, high + 1):
        item = bit(row, prefix, index)
        if item is None:
            return None
        value |= item << (index - low)
    return value


def sint16(value):
    if value is None:
        return None
    return value - 0x10000 if value & 0x8000 else value


def load_capture(path: Path):
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    header_index = next(i for i, line in enumerate(lines) if line.startswith("time unit:"))
    header = next(csv.reader([lines[header_index]], skipinitialspace=True))
    names = [item.strip() for item in header[1:] if item.strip()]
    records = []
    for raw in lines[header_index + 1 :]:
        if not raw.strip():
            continue
        values = next(csv.reader([raw], skipinitialspace=True))
        if not values or not values[0].strip().lstrip("-").isdigit():
            continue
        samples = [item.strip() for item in values[1 : 1 + len(names)]]
        row = dict(zip(names, samples))
        if all(value not in {"0", "1"} for value in samples):
            continue
        records.append((int(values[0].strip()), row))
    return names, records


def decode(time_value: int, row: dict[str, str]):
    result = {
        "time": time_value,
        "commit_pc": uint(row, CORE, 0, 31),
        "commit_addr": uint(row, CORE, 32, 55),
        "commit_byte": uint(row, CORE, 56, 63),
        "commit_data": uint(row, CORE, 64, 95),
        "commit_page": uint(row, CORE, 96, 102),
        "commit_reg": uint(row, CORE, 103, 106),
        "current_page": uint(row, CORE, 107, 113),
        "ce_cpu": bit(row, CORE, 114),
        "rst": bit(row, CORE, 115),
        "host_commit": bit(row, CORE, 116),
        "commit_valid": bit(row, CORE, 117),
        "sound_irq_n": bit(row, CORE, 118),
        "engine_irq_set": bit(row, CORE, 119),
        "engine_irq_voice": uint(row, CORE, 120, 124),
        "cpu_irq_ack": bit(row, CORE, 125),
        "irq_vector": uint(row, CORE, 126, 133),
        "sample_tick": bit(row, CORE, 134),
        "underrun": bit(row, CORE, 135),
        "sdr_req": bit(row, CORE, 136),
        "sdr_ack": bit(row, CORE, 137),
        "sdr_addr": uint(row, CORE, 138, 163),
        "sdr_data": uint(row, CORE, 164, 179),
        "core_audio_l": sint16(uint(row, OUT, 0, 15)),
        "core_audio_r": sint16(uint(row, OUT, 16, 31)),
        "cdc_audio_l": sint16(uint(row, OUT, 32, 47)),
        "cdc_audio_r": sint16(uint(row, OUT, 48, 63)),
        "core_audio_tick": bit(row, OUT, 64),
        "cdc_valid": bit(row, OUT, 65),
        "cdc_ready": bit(row, OUT, 66),
        "reset": bit(row, OUT, 67),
        "core_reset": bit(row, OUT, 68),
    }
    return result


def main():
    if len(sys.argv) not in {2, 3}:
        raise SystemExit("usage: decode_ssv_audio_capture.py CAPTURE.csv [DECODED.csv]")

    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else source.with_name("decoded.csv")
    names, raw_records = load_capture(source)
    records = [decode(time_value, row) for time_value, row in raw_records]
    if not records:
        raise SystemExit("capture has no fully named binary samples")

    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)

    pulse_fields = [
        "host_commit",
        "engine_irq_set",
        "cpu_irq_ack",
        "sample_tick",
        "underrun",
        "sdr_req",
        "sdr_ack",
        "core_audio_tick",
        "cdc_valid",
        "cdc_ready",
    ]
    summary = {
        "source": str(source),
        "decoded": str(output),
        "named_probes": len(names),
        "samples": len(records),
        "time_first": records[0]["time"],
        "time_last": records[-1]["time"],
        "pulses": {field: sum(record[field] == 1 for record in records) for field in pulse_fields},
        "host_commits": [
            {
                key: record[key]
                for key in (
                    "time",
                    "commit_pc",
                    "commit_addr",
                    "commit_byte",
                    "commit_data",
                    "commit_page",
                    "commit_reg",
                )
            }
            for record in records
            if record["host_commit"] == 1
        ],
        "underrun_times": [record["time"] for record in records if record["underrun"] == 1],
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
