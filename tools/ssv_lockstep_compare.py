#!/usr/bin/env python3
"""Protocol-v2 coordinator for live SSV RTL-versus-MAME sessions.

Both producers publish a native P6 frame and a monotonically increasing frame
token, then wait for ``release_frame.txt``.  This coordinator is deliberately
independent of either process so a failed producer cannot silently advance the
other side or turn an alignment failure into an RTL bug report.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import struct
import time
import zlib


VOLATILE_READY_KEYS = {"pid", "window_handle", "window_flags", "timestamp"}
TRACE_COMPARE_KEYS = ("cpu", "event", "rw", "address", "data", "lanes", "device")
STATE_CONTEXT_KEYS = {"frame", "pc", "cycle", "sequence", "producer"}
SESSION_DEADLINE: float | None = None


def atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    for attempt in range(20):
        try:
            if path.exists():
                path.unlink()
            temporary.replace(path)
            return
        except (PermissionError, FileNotFoundError):
            if attempt == 19:
                raise
            time.sleep(0.025)


def atomic_text(path: Path, value: str) -> None:
    atomic_bytes(path, value.encode("utf-8"))


def atomic_json(path: Path, value: object) -> None:
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def read_json_retry(path: Path) -> dict:
    for attempt in range(20):
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, PermissionError, json.JSONDecodeError):
            if attempt == 19:
                raise
            time.sleep(0.025)
    raise AssertionError("unreachable")


def read_token(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="ascii").strip())
    except (FileNotFoundError, PermissionError, ValueError):
        return None


def read_owner_packet(path: Path, expected_frame: int) -> dict | None:
    if not path.exists():
        return None
    packet = read_json_retry(path)
    if packet.get("frame") != expected_frame or packet.get("source") != "rtl-owner":
        raise RuntimeError(
            f"invalid RTL-owner input packet for frame {expected_frame}: {packet}"
        )
    for key in ("p1_pressed", "p2_pressed", "system_pressed"):
        if not isinstance(packet.get(key), int):
            raise RuntimeError(f"input packet {path} has invalid {key}: {packet}")
    return packet


def wait_for(predicate, description: str, timeout: float, stop: Path):
    deadline = time.monotonic() + timeout
    if SESSION_DEADLINE is not None:
        deadline = min(deadline, SESSION_DEADLINE)
    while time.monotonic() < deadline:
        if stop.exists():
            raise RuntimeError(f"session stopped while waiting for {description}")
        value = predicate()
        if value is not None and value is not False:
            return value
        time.sleep(0.02)
    if SESSION_DEADLINE is not None and time.monotonic() >= SESSION_DEADLINE:
        raise TimeoutError(
            f"session wall-clock deadline expired while waiting for {description}"
        )
    raise TimeoutError(f"timed out after {timeout:.1f}s waiting for {description}")


def ppm(path: Path) -> tuple[int, int, bytes]:
    raw = path.read_bytes()
    if not raw.startswith(b"P6"):
        raise ValueError(f"not a P6 image: {path}")
    position = 2

    def token() -> bytes:
        nonlocal position
        while position < len(raw):
            if raw[position:position + 1] == b"#":
                position = raw.find(b"\n", position) + 1
            elif raw[position] in b" \t\r\n":
                position += 1
            else:
                break
        end = position
        while end < len(raw) and raw[end] not in b" \t\r\n":
            end += 1
        value = raw[position:end]
        position = end
        return value

    width, height, maximum = (int(token()), int(token()), int(token()))
    if maximum != 255:
        raise ValueError(f"unsupported PPM maximum {maximum}: {path}")
    if position >= len(raw) or raw[position] not in b" \t\r\n":
        raise ValueError(f"PPM header has no payload delimiter: {path}")
    first = raw[position]
    position += 1
    if first == 13 and position < len(raw) and raw[position] == 10:
        position += 1
    pixels = raw[position:]
    expected = width * height * 3
    if len(pixels) != expected:
        raise ValueError(f"PPM payload {len(pixels)} != {expected}: {path}")
    return width, height, pixels


def png_chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def write_rgb_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    rows = b"".join(
        b"\0" + pixels[y * width * 3:(y + 1) * width * 3]
        for y in range(height)
    )
    data = (b"\x89PNG\r\n\x1a\n" +
            png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            png_chunk(b"IDAT", zlib.compress(rows, 6)) + png_chunk(b"IEND", b""))
    atomic_bytes(path, data)


def compare_pixels(rtl: bytes, reference: bytes, width: int, height: int) -> tuple[dict, bytes]:
    if len(rtl) != len(reference):
        raise ValueError("native frame payload sizes differ")
    diff = bytearray(len(rtl))
    differing = 0
    exact_channels = 0
    error_sum = 0
    min_x, min_y, max_x, max_y = width, height, -1, -1
    for pixel in range(width * height):
        base = pixel * 3
        different = False
        for channel in range(3):
            delta = abs(rtl[base + channel] - reference[base + channel])
            error_sum += delta
            exact_channels += delta == 0
            diff[base + channel] = min(255, delta * 4)
            different |= delta != 0
        if different:
            differing += 1
            x, y = pixel % width, pixel // width
            min_x, min_y = min(min_x, x), min(min_y, y)
            max_x, max_y = max(max_x, x), max(max_y, y)
    count = width * height
    metrics = {
        "compared_pixels": count,
        "exact_pixels": count - differing,
        "exact_ratio": (count - differing) / count if count else 1.0,
        "differing_pixels": differing,
        "rgb_mae": error_sum / (count * 3) if count else 0.0,
        "exact_channel_ratio": exact_channels / (count * 3) if count else 1.0,
        "difference_bbox": None if not differing else [min_x, min_y, max_x, max_y],
    }
    return metrics, bytes(diff)


def jsonl_frame(path: Path, frame: int) -> list[dict]:
    if not path.exists():
        return []
    # Producers append complete JSON records, but Windows can briefly deny a
    # read and a concurrent append can expose a partial final line. Retry
    # instead of silently turning malformed or unavailable evidence into an
    # empty trace that could be mistaken for equality.
    for attempt in range(20):
        result = []
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
            for line_number, line in enumerate(lines, 1):
                if not line.strip():
                    continue
                item = json.loads(line)
                if item.get("frame") == frame:
                    result.append(item)
            return result
        except (PermissionError, UnicodeDecodeError, json.JSONDecodeError) as error:
            if attempt == 19:
                raise RuntimeError(f"invalid JSONL evidence {path}: {error}") from error
            time.sleep(0.025)
    raise AssertionError("unreachable")


def first_trace_difference(rtl: list[dict], reference: list[dict]) -> dict | None:
    count = min(len(rtl), len(reference))
    for index in range(count):
        left = {key: rtl[index].get(key) for key in TRACE_COMPARE_KEYS}
        right = {key: reference[index].get(key) for key in TRACE_COMPARE_KEYS}
        if left != right:
            return {"index": index, "rtl": rtl[index], "reference": reference[index],
                    "matching_predecessors": rtl[max(0, index - 4):index]}
    if len(rtl) != len(reference):
        return {"index": count, "rtl": rtl[count] if len(rtl) > count else None,
                "reference": reference[count] if len(reference) > count else None,
                "matching_predecessors": rtl[max(0, count - 4):count]}
    return None


def first_state_difference(rtl: list[dict], reference: list[dict]) -> dict | None:
    if not rtl and not reference:
        return None
    if not rtl or not reference:
        return {"missing_side": "rtl" if not rtl else "reference",
                "rtl": rtl[-1] if rtl else None,
                "reference": reference[-1] if reference else None}
    left, right = rtl[-1], reference[-1]
    keys = sorted((set(left) & set(right)) - STATE_CONTEXT_KEYS)
    differing = {key: {"rtl": left[key], "reference": right[key]}
                 for key in keys if left[key] != right[key]}
    return None if not differing else {"keys_compared": keys, "differing": differing,
                                        "rtl": left, "reference": right}


def validate_ready(manifest: dict, rtl: dict, reference: dict,
                   start_frame: int) -> tuple[dict, bool]:
    expected_geometry = manifest["alignment"]["geometry"]["rtl"]
    expected_dips = manifest["alignment"]["mra_dips"]
    first_complete = manifest["alignment"].get("first_complete_token")
    first_comparable = manifest["alignment"].get("first_comparable_token")
    warmup_excluded = manifest["alignment"].get("warmup_excluded_tokens")
    valid_policy = (
        first_complete == 1
        and isinstance(first_comparable, int)
        and first_comparable >= first_complete
        and warmup_excluded == list(range(first_comparable))
    )
    rtl_startup = manifest.get("rtl_startup", {"mode": "cold-lockstep"})
    checkpoint_restore = rtl_startup.get("mode") == "checkpoint-restore"
    checks = {
        "schema_rtl": rtl.get("schema") == "ssv-lockstep-ready-v2",
        "schema_reference": reference.get("schema") == "ssv-lockstep-ready-v2",
        "set_rtl": rtl.get("set") == manifest["set"],
        "set_reference": reference.get("set") == manifest["set"],
        "geometry_rtl": rtl.get("geometry") == expected_geometry,
        "geometry_reference": reference.get("geometry") == expected_geometry,
        "geometry_pair": rtl.get("geometry") == reference.get("geometry"),
        "dips_rtl": rtl.get("dips") == expected_dips,
        "dips_reference": reference.get("dips") == expected_dips,
        "sound_pair": rtl.get("sound_enabled") is True and reference.get("sound_enabled") is True,
        "input_owner": rtl.get("input_role") == "owner" and reference.get("input_role") == "consumer",
        "raw_surface_pair": rtl.get("raw_frame_format") == "P6-RGB24" and
                            reference.get("raw_frame_format") == "P6-RGB24",
        "boundary_declared": bool(rtl.get("frame_boundary")) and bool(reference.get("frame_boundary")),
        "epoch_pair": rtl.get("epoch") == reference.get("epoch") ==
                      "accepted-write:21000e:low-byte:data-bit7",
        "manifest_startup_policy": valid_policy,
        "first_complete_token_pair": rtl.get("first_complete_token") ==
                                     reference.get("first_complete_token") ==
                                     first_complete,
        "first_comparable_token_pair": rtl.get("first_comparable_token") ==
                                        reference.get("first_comparable_token") ==
                                        first_comparable,
        "warmup_excluded_tokens_pair": rtl.get("warmup_excluded_tokens") ==
                                       reference.get("warmup_excluded_tokens") ==
                                       warmup_excluded,
        "capture_start_token_pair": rtl.get("capture_start_token") ==
                                    reference.get("capture_start_token") ==
                                    start_frame,
        "start_frame_comparable": (
            valid_policy and start_frame >= first_comparable
        ),
        "rtl_startup_mode": rtl.get("startup_mode", "cold-lockstep") ==
                            ("checkpoint-restore" if checkpoint_restore else "cold-lockstep"),
        "reference_startup_mode": reference.get("startup_mode", "cold-lockstep") ==
                                  ("cold-reference-replay" if checkpoint_restore else "cold-lockstep"),
        "restore_boundary": (
            rtl.get("restore_committed_frame") == start_frame - 1 and
            reference.get("catchup_target") == start_frame
        ) if checkpoint_restore else True,
    }
    return checks, all(checks.values())


def main() -> int:
    global SESSION_DEADLINE
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--start-frame", type=int, default=0)
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument(
        "--total-timeout", type=float, default=0.0,
        help="optional wall-clock ceiling for the complete coordinator run",
    )
    parser.add_argument("--freeze-on", choices=("pixel", "trace", "state", "never"), default="pixel")
    parser.add_argument(
        "--reference-catchup", action="store_true",
        help="RTL starts from a verified start_frame-1 checkpoint; drain only the cold reference",
    )
    args = parser.parse_args()
    if args.start_frame < 0 or args.frames < 1 or args.total_timeout < 0:
        parser.error("start frame must be nonnegative and frames must be positive")
    if args.total_timeout:
        SESSION_DEADLINE = time.monotonic() + args.total_timeout

    session = args.session.resolve()
    manifest = read_json_retry(session / "manifest.json")
    if manifest.get("status") != "pending_live_adapters":
        raise RuntimeError("manifest is not a static-preflight pending manifest")
    checkpoint_restore = manifest.get("rtl_startup", {}).get("mode") == "checkpoint-restore"
    if args.reference_catchup != checkpoint_restore:
        raise RuntimeError(
            "--reference-catchup must exactly match manifest rtl_startup mode"
        )
    stop = session / "STOP.txt"
    # Nobody advances until readiness and every skipped startup token has
    # crossed the same two-producer/owner-input barrier.
    atomic_text(session / "release_frame.txt", "-1\n")

    rtl_ready = wait_for(lambda: read_json_retry(session / "rtl_ready.json")
                         if (session / "rtl_ready.json").exists() else None,
                         "RTL readiness", args.timeout, stop)
    ref_ready = wait_for(lambda: read_json_retry(session / "reference_ready.json")
                         if (session / "reference_ready.json").exists() else None,
                         "reference readiness", args.timeout, stop)
    checks, passed = validate_ready(manifest, rtl_ready, ref_ready,
                                    args.start_frame)
    preflight = {"schema": "ssv-lockstep-preflight-v2", "set": manifest["set"],
                 "status": "pass" if passed else "failure", "checks": checks,
                 "static_manifest": str(session / "manifest.json"),
                 "rtl_ready": rtl_ready, "reference_ready": ref_ready}
    marker = "PREFLIGHT_PASS.json" if passed else "PREFLIGHT_FAILURE.json"
    atomic_json(session / marker, preflight)
    if not passed:
        atomic_text(stop, "alignment failure\n")
        return 2

    advanced_tokens = []
    for frame in range(args.start_frame):
        if not checkpoint_restore:
            wait_for(lambda: frame if read_token(session / "rtl_frame.txt") == frame else None,
                     f"RTL startup token {frame}", args.timeout, stop)
        wait_for(lambda: frame if read_token(session / "reference_frame.txt") == frame else None,
                 f"reference startup token {frame}", args.timeout, stop)
        packet_frame = frame + 1
        packet_path = session / "inputs" / f"frame_{packet_frame:06d}.json"
        packet = wait_for(
            lambda path=packet_path, number=packet_frame:
                read_owner_packet(path, number),
            f"RTL-owner input packet {packet_frame}", args.timeout, stop,
        )
        advanced_tokens.append({"frame": frame, "next_input": packet})
        atomic_text(session / "release_frame.txt", f"{frame}\n")
    atomic_json(
        session / "STARTUP_ADVANCE.json",
        {"schema": "ssv-lockstep-startup-v1", "set": manifest["set"],
         "requested_start_frame": args.start_frame,
         "mode": "cold-reference-replay" if checkpoint_restore else "two-producer-lockstep",
         "rtl_restore_committed_frame": (
             manifest.get("rtl_startup", {}).get("restore_committed_frame")
             if checkpoint_restore else None
         ),
         "policy_warmup_tokens": manifest["alignment"]["warmup_excluded_tokens"],
         "advanced_tokens": advanced_tokens},
    )

    metrics_path = session / "metrics.jsonl"
    if metrics_path.exists():
        metrics_path.unlink()
    compared = 0
    frozen = False
    first_token = args.start_frame
    last_token = args.start_frame - 1
    coverage = {
        "video": "compared", "inputs": "compared",
        "cpu_bus": "missing_evidence", "video_state": "missing_evidence",
        "audio": "captured_only" if rtl_ready.get("audio_capture") else "missing_evidence",
        "st010": "missing_evidence",
    }
    all_pixels_equal = True
    all_traces_equal = True
    all_states_equal = True
    trace_frames_compared = 0
    state_frames_compared = 0

    for frame in range(args.start_frame, args.start_frame + args.frames):
        wait_for(lambda: frame if read_token(session / "rtl_frame.txt") == frame else None,
                 f"RTL frame token {frame}", args.timeout, stop)
        wait_for(lambda: frame if read_token(session / "reference_frame.txt") == frame else None,
                 f"reference frame token {frame}", args.timeout, stop)
        rtl_path = session / "rtl" / f"frame_{frame:06d}.ppm"
        ref_path = session / "reference" / f"frame_{frame:06d}.ppm"
        wait_for(lambda: rtl_path if rtl_path.exists() else None,
                 f"RTL frame {frame}", args.timeout, stop)
        wait_for(lambda: ref_path if ref_path.exists() else None,
                 f"reference frame {frame}", args.timeout, stop)
        rw, rh, rp = ppm(rtl_path)
        mw, mh, mp = ppm(ref_path)
        if (rw, rh) != (mw, mh):
            raise RuntimeError(f"frame {frame} geometry differs RTL={rw}x{rh} MAME={mw}x{mh}")
        pixel_metrics, diff = compare_pixels(rp, mp, rw, rh)
        write_rgb_png(session / "diff" / f"frame_{frame:06d}.png", rw, rh, diff)

        rtl_trace = jsonl_frame(session / "rtl_trace.jsonl", frame)
        ref_trace = jsonl_frame(session / "reference_trace.jsonl", frame)
        trace_diff = first_trace_difference(rtl_trace, ref_trace)
        if rtl_trace and ref_trace:
            coverage["cpu_bus"] = "compared"
            trace_frames_compared += 1
        rtl_state = jsonl_frame(session / "rtl_state.jsonl", frame)
        ref_state = jsonl_frame(session / "reference_state.jsonl", frame)
        state_diff = first_state_difference(rtl_state, ref_state)
        if rtl_state and ref_state:
            coverage["video_state"] = "compared"
            state_frames_compared += 1
        rtl_st010 = any(
            any(str(key).startswith("st010_") for key in record)
            for record in rtl_state)
        ref_st010 = any(
            any(str(key).startswith("st010_") for key in record)
            for record in ref_state)
        rtl_st010_bus = any(event.get("device") == 9 for event in rtl_trace)
        ref_st010_bus = any(event.get("device") == 9 for event in ref_trace)
        if rtl_st010 and ref_st010:
            coverage["st010"] = "compared"
        elif rtl_st010 or ref_st010 or rtl_st010_bus or ref_st010_bus:
            coverage["st010"] = "captured_only"

        trace_equal = (None if not rtl_trace and not ref_trace
                       else trace_diff is None)
        state_equal = (None if not rtl_state and not ref_state
                       else state_diff is None)
        all_pixels_equal &= pixel_metrics["differing_pixels"] == 0
        all_traces_equal &= trace_equal is True
        all_states_equal &= state_equal is True

        row = {"frame": frame, **pixel_metrics,
               "rtl_trace_events": len(rtl_trace), "reference_trace_events": len(ref_trace),
               "trace_equal": trace_equal,
               "state_equal": state_equal}
        with metrics_path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
            stream.flush()
        atomic_text(session / "status.txt",
                    f"frame={frame} exact_ratio={pixel_metrics['exact_ratio']:.9f} "
                    f"differing={pixel_metrics['differing_pixels']}\n")

        if trace_diff is not None and not (session / "FIRST_TRACE_DIVERGENCE.json").exists():
            trace_diff["frame"] = frame
            atomic_json(session / "FIRST_TRACE_DIVERGENCE.json", trace_diff)
            atomic_json(session / "FIRST_CAUSAL_DIVERGENCE.json", trace_diff)
            # Preserve the first causal event bundle, then stop expensive bus
            # collection regardless of which surface controls the session's
            # freeze policy.  Compact frame/state evidence continues and can
            # still freeze later on a first visible or architectural split.
            atomic_text(session / "TRACE_STOP.txt",
                        f"first trace divergence frame {frame}\n")
        if state_diff is not None and not (session / "FIRST_STATE_DIVERGENCE.json").exists():
            state_diff["frame"] = frame
            atomic_json(session / "FIRST_STATE_DIVERGENCE.json", state_diff)
        if pixel_metrics["differing_pixels"] and not (session / "FIRST_PIXEL_DIVERGENCE.json").exists():
            atomic_json(session / "FIRST_PIXEL_DIVERGENCE.json",
                        {"frame": frame, **pixel_metrics, "rtl": str(rtl_path),
                         "reference": str(ref_path),
                         "diff": str(session / "diff" / f"frame_{frame:06d}.png")})

        compared += 1
        last_token = frame
        freeze = ((args.freeze_on == "pixel" and pixel_metrics["differing_pixels"] > 0) or
                  (args.freeze_on == "trace" and trace_diff is not None) or
                  (args.freeze_on == "state" and state_diff is not None))
        if freeze:
            frozen = True
            atomic_text(session / "TRACE_STOP.txt", f"first divergence frame {frame}\n")
            break
        atomic_text(session / "release_frame.txt", f"{frame}\n")

    exact = compared == args.frames
    matched = (exact and not frozen and all_pixels_equal and all_traces_equal
               and all_states_equal and trace_frames_compared == compared
               and state_frames_compared == compared)
    completion = {
        "schema": "ssv-lockstep-completion-v2", "set": manifest["set"],
        "requested_count": args.frames, "compared_count": compared,
        "start_frame": first_token, "end_frame": last_token,
        "requested_end_frame": args.start_frame + args.frames - 1,
        "exact_completion": exact, "matched_completion": matched,
        "all_pixels_equal": all_pixels_equal,
        "all_traces_equal": all_traces_equal,
        "all_states_equal": all_states_equal,
        "trace_frames_compared": trace_frames_compared,
        "state_frames_compared": state_frames_compared,
        "frozen": frozen, "coverage": coverage,
    }
    atomic_json(session / "completion.json", completion)
    atomic_json(session / "diagnostic_summary.json",
                {**completion, "preflight": "pass",
                 "first_pixel_divergence": (session / "FIRST_PIXEL_DIVERGENCE.json").exists(),
                 "first_trace_divergence": (session / "FIRST_TRACE_DIVERGENCE.json").exists(),
                 "first_state_divergence": (session / "FIRST_STATE_DIVERGENCE.json").exists()})
    if exact and not frozen:
        atomic_text(session / "release_frame.txt", f"{last_token}\n")
    outcome = "FROZEN" if frozen else ("MATCHED" if matched else "COMPLETE_MISMATCH")
    print(f"LOCKSTEP_{outcome} set={manifest['set']} "
          f"compared={compared}/{args.frames} tokens={first_token}..{last_token}")
    return 3 if frozen else (0 if matched else (5 if exact else 4))


if __name__ == "__main__":
    raise SystemExit(main())
