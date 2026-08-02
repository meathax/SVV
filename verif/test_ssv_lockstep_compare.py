#!/usr/bin/env python3
"""Focused protocol-v2 barrier/image regression with synthetic producers."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    for attempt in range(20):
        try:
            if path.exists():
                path.unlink()
            temporary.replace(path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.025)


def producer(session: Path, side: str, frames: list[bytes],
             emit_trace: bool = True) -> None:
    token_name = "rtl_frame.txt" if side == "rtl" else "reference_frame.txt"
    trace_name = "rtl_trace.jsonl" if side == "rtl" else "reference_trace.jsonl"
    state_name = "rtl_state.jsonl" if side == "rtl" else "reference_state.jsonl"
    for frame, pixels in enumerate(frames):
        if side == "rtl" and frame + 1 < len(frames):
            packet = {"frame": frame + 1, "p1_pressed": 0,
                      "p2_pressed": 0, "system_pressed": 0,
                      "source": "rtl-owner"}
            atomic(session / "inputs" / f"frame_{frame + 1:06d}.json",
                   json.dumps(packet).encode())
        atomic(session / side / f"frame_{frame:06d}.ppm", b"P6\n2 1\n255\n" + pixels)
        with (session / state_name).open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"frame": frame, "producer": side,
                                     "pc": 0x1000, "list512_crc": frame}) + "\n")
        if emit_trace:
            with (session / trace_name).open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"frame": frame, "cpu": 0,
                                         "event": "bus", "rw": "r",
                                         "address": 0x210008, "data": 0xffff,
                                         "lanes": 3, "device": 6}) + "\n")
        atomic(session / token_name, f"{frame}\n".encode())
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                if int((session / "release_frame.txt").read_text()) >= frame:
                    break
            # Windows can briefly deny a read while the coordinator replaces
            # the release token atomically.  Treat that exactly like a token
            # that has not been published yet and retry.
            except (FileNotFoundError, PermissionError, ValueError):
                pass
            if (session / "TRACE_STOP.txt").exists():
                return
            time.sleep(0.01)


def make_session(session: Path, setname: str = "cairblad",
                 capture_start: int = 1, checkpoint_restore: bool = False) -> None:
    first_comparable = 2 if setname == "dynagear" else 1
    manifest = {
        "status": "pending_live_adapters", "set": setname,
        "alignment": {"geometry": {"rtl": [2, 1]},
                      "mra_dips": {"DSW1": 255, "DSW2": 253},
                      "first_complete_token": 1,
                      "first_comparable_token": first_comparable,
                      "warmup_excluded_tokens": list(range(first_comparable))},
    }
    if checkpoint_restore:
        manifest["rtl_startup"] = {
            "mode": "checkpoint-restore",
            "restore_committed_frame": capture_start - 1,
        }
    atomic(session / "manifest.json", json.dumps(manifest).encode())
    common = {
        "schema": "ssv-lockstep-ready-v2", "set": setname,
        "geometry": [2, 1], "dips": {"DSW1": 255, "DSW2": 253},
        "sound_enabled": True, "raw_frame_format": "P6-RGB24",
        "epoch": "accepted-write:21000e:low-byte:data-bit7",
        "first_complete_token": 1,
        "first_comparable_token": first_comparable,
        "warmup_excluded_tokens": list(range(first_comparable)),
        "capture_start_token": capture_start,
        "frame_boundary": "synthetic completed frame",
    }
    rtl_startup = ({"startup_mode": "checkpoint-restore",
                    "restore_committed_frame": capture_start - 1}
                   if checkpoint_restore else {"startup_mode": "cold-lockstep"})
    reference_startup = ({"startup_mode": "cold-reference-replay",
                          "catchup_target": capture_start}
                         if checkpoint_restore else {"startup_mode": "cold-lockstep",
                                                     "catchup_target": -1})
    atomic(session / "rtl_ready.json",
           json.dumps({**common, **rtl_startup, "input_role": "owner"}).encode())
    atomic(session / "reference_ready.json",
           json.dumps({**common, **reference_startup, "input_role": "consumer"}).encode())


def compare_command(session: Path, freeze_on: str, start_frame: int = 1,
                    frames: int = 1, reference_catchup: bool = False) -> list[str]:
    command = [sys.executable, str(ROOT / "tools" / "ssv_lockstep_compare.py"),
            "--session", str(session), "--start-frame", str(start_frame),
            "--frames", str(frames), "--timeout", "10",
            "--freeze-on", freeze_on]
    if reference_catchup:
        command.append("--reference-catchup")
    return command


def run_compare(session: Path, freeze_on: str, start_frame: int = 1,
                frames: int = 1) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        compare_command(session, freeze_on, start_frame, frames),
        text=True, capture_output=True)


def wait_value(path: Path, expected: int, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if int(path.read_text()) == expected:
                return
        except (FileNotFoundError, PermissionError, ValueError):
            pass
        time.sleep(0.01)
    actual = path.read_text() if path.exists() else "<missing>"
    raise AssertionError(f"{path.name} did not become {expected}: {actual!r}")


def dyna_warmup_producer(session: Path, side: str, frames: list[bytes],
                         observed_inputs: list[dict] | None = None,
                         delay_frame_one: float = 0.0) -> None:
    """Model the real owner-packet-before-token and consumer-after-release order."""
    token_name = "rtl_frame.txt" if side == "rtl" else "reference_frame.txt"
    trace_name = "rtl_trace.jsonl" if side == "rtl" else "reference_trace.jsonl"
    state_name = "rtl_state.jsonl" if side == "rtl" else "reference_state.jsonl"
    for frame, pixels in enumerate(frames):
        if side == "rtl" and frame == 1 and delay_frame_one:
            time.sleep(delay_frame_one)
        if side == "rtl" and frame + 1 < len(frames):
            packet = {"frame": frame + 1, "p1_pressed": 0x1200 + frame + 1,
                      "p2_pressed": 0, "system_pressed": 0,
                      "source": "rtl-owner"}
            atomic(session / "inputs" / f"frame_{frame + 1:06d}.json",
                   json.dumps(packet).encode())
        # The real adapters omit full PPMs before capture_start_token; startup
        # still crosses the token/state/owner-input barrier in order.
        if frame >= 2:
            atomic(session / side / f"frame_{frame:06d}.ppm",
                   b"P6\n2 1\n255\n" + pixels)
        if frame >= 2:
            with (session / state_name).open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"frame": frame, "producer": side,
                                         "pc": 0x1000,
                                         "list512_crc": frame}) + "\n")
            with (session / trace_name).open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"frame": frame, "cpu": 0,
                                         "event": "bus", "rw": "r",
                                         "address": 0x210008, "data": 0xffff,
                                         "lanes": 3, "device": 6}) + "\n")
        atomic(session / token_name, f"{frame}\n".encode())
        wait_value(session / "release_frame.txt", frame, timeout=10)
        if side == "reference" and frame + 1 < len(frames):
            packet_path = session / "inputs" / f"frame_{frame + 1:06d}.json"
            assert packet_path.exists(), packet_path
            assert observed_inputs is not None
            observed_inputs.append(json.loads(packet_path.read_text()))


def restored_rtl_producer(session: Path, frame: int, pixels: bytes) -> None:
    atomic(session / "rtl" / f"frame_{frame:06d}.ppm",
           b"P6\n2 1\n255\n" + pixels)
    with (session / "rtl_state.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"frame": frame, "producer": "rtl",
                                 "pc": 0x1000, "list512_crc": frame}) + "\n")
    with (session / "rtl_trace.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"frame": frame, "cpu": 0,
                                 "event": "bus", "rw": "r",
                                 "address": 0x210008, "data": 0xffff,
                                 "lanes": 3, "device": 6}) + "\n")
    atomic(session / "rtl_frame.txt", f"{frame}\n".encode())
    wait_value(session / "release_frame.txt", frame, timeout=10)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ssv-lockstep-test-") as temporary:
        root = Path(temporary)
        session = root / "pixel"
        make_session(session)
        # Frame zero starts with a whitespace-valued red byte to prove the PPM
        # reader consumes exactly one delimiter and never strips pixel bytes.
        matching = bytes((10, 20, 30, 40, 50, 60))
        changed = bytes((10, 20, 30, 41, 50, 60))
        rtl = threading.Thread(target=producer, args=(session, "rtl", [matching, changed]))
        reference = threading.Thread(target=producer, args=(session, "reference", [matching, matching]))
        rtl.start()
        reference.start()
        result = run_compare(session, "pixel")
        rtl.join(2)
        reference.join(2)
        assert result.returncode == 3, (result.returncode, result.stdout, result.stderr)
        completion = json.loads((session / "completion.json").read_text())
        assert completion["compared_count"] == 1 and completion["frozen"]
        divergence = json.loads((session / "FIRST_PIXEL_DIVERGENCE.json").read_text())
        assert divergence["frame"] == 1 and divergence["differing_pixels"] == 1
        assert (session / "diff" / "frame_000001.png").read_bytes().startswith(b"\x89PNG")
        assert (session / "PREFLIGHT_PASS.json").exists()
        print("PASS lockstep exact barrier, PPM bytes, diff PNG, first divergence")

        # A complete frame count with one-sided bus evidence is diagnostic
        # completion, never a match and never exit zero.
        session = root / "one-sided-trace"
        make_session(session)
        rtl = threading.Thread(target=producer,
                               args=(session, "rtl", [matching, matching], True))
        reference = threading.Thread(target=producer,
                                     args=(session, "reference", [matching, matching], False))
        rtl.start()
        reference.start()
        result = run_compare(session, "never")
        rtl.join(2)
        reference.join(2)
        assert result.returncode == 5, (result.returncode, result.stdout, result.stderr)
        completion = json.loads((session / "completion.json").read_text())
        assert completion["exact_completion"] and not completion["matched_completion"]
        assert completion["all_pixels_equal"] and not completion["all_traces_equal"]
        trace = json.loads((session / "FIRST_TRACE_DIVERGENCE.json").read_text())
        assert trace["frame"] == 1 and trace["reference"] is None
        assert (session / "TRACE_STOP.txt").read_text().strip() == \
            "first trace divergence frame 1"
        print("PASS one-sided trace is explicit mismatch, not exact-match success")

        # Dyna token one is physically complete but presentation-age
        # transitional. Strict evidence must start at the proven common token
        # two; reject an accidental token-one qualification before comparing.
        session = root / "dynagear-warmup"
        make_session(session, "dynagear")
        result = run_compare(session, "never")
        assert result.returncode == 2, (result.returncode,
                                       result.stdout, result.stderr)
        preflight = json.loads((session / "PREFLIGHT_FAILURE.json").read_text())
        assert preflight["checks"]["start_frame_comparable"] is False
        print("PASS Dyna transitional token one is excluded from strict comparison")

        # A positive Dyna comparison must drain excluded tokens through the
        # same two-producer barrier. In particular, token one cannot be
        # pre-released: its release is what makes the reference consume the
        # authoritative RTL-owner packet for the first compared token two.
        session = root / "dynagear-positive-warmup"
        make_session(session, "dynagear", capture_start=2)
        for frame in range(3):
            atomic(session / "inputs" / f"frame_{frame:06d}.json",
                   json.dumps({"frame": frame, "p1_pressed": 0,
                               "p2_pressed": 0, "system_pressed": 0,
                               "source": "neutral-seed"}).encode())
        process = subprocess.Popen(
            compare_command(session, "never", start_frame=2),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        wait_value(session / "release_frame.txt", -1)

        observed_inputs: list[dict] = []
        reference = threading.Thread(
            target=dyna_warmup_producer,
            args=(session, "reference", [matching, changed, matching],
                  observed_inputs))
        reference.start()
        wait_value(session / "reference_frame.txt", 0)
        # A one-sided warmup token must not advance the barrier.
        assert int((session / "release_frame.txt").read_text()) == -1

        rtl = threading.Thread(
            target=dyna_warmup_producer,
            args=(session, "rtl", [matching, matching, matching], None, 0.3))
        rtl.start()
        wait_value(session / "reference_frame.txt", 1)
        # RTL deliberately has not published token one or owner packet two.
        # The coordinator must hold release at zero until it does.
        assert int((session / "release_frame.txt").read_text()) == 0

        stdout, stderr = process.communicate(timeout=10)
        rtl.join(2)
        reference.join(2)
        assert process.returncode == 0, (process.returncode, stdout, stderr)
        assert not rtl.is_alive() and not reference.is_alive()
        completion = json.loads((session / "completion.json").read_text())
        assert completion["matched_completion"]
        assert completion["requested_count"] == 1
        assert completion["compared_count"] == 1
        assert completion["start_frame"] == completion["end_frame"] == 2
        assert observed_inputs[-1]["frame"] == 2
        assert observed_inputs[-1]["source"] == "rtl-owner"
        assert observed_inputs[-1]["p1_pressed"] == 0x1202
        print("PASS Dyna start-two drains warmups and exposes owner input two")

        # A restored RTL model has no authority to republish tokens already
        # serialized in its checkpoint.  MAME alone must replay the immutable
        # RTL-owned packet prefix, then meet RTL at the first post-restore
        # token without pre-releasing that comparison boundary.
        session = root / "checkpoint-reference-catchup"
        make_session(session, "dynagear", capture_start=2,
                     checkpoint_restore=True)
        packets = (
            {"frame": 0, "p1_pressed": 0, "p2_pressed": 0,
             "system_pressed": 0, "source": "neutral-seed"},
            {"frame": 1, "p1_pressed": 1, "p2_pressed": 0,
             "system_pressed": 0, "source": "rtl-owner"},
            {"frame": 2, "p1_pressed": 2, "p2_pressed": 0,
             "system_pressed": 0, "source": "rtl-owner"},
        )
        for packet in packets:
            atomic(session / "inputs" / f"frame_{packet['frame']:06d}.json",
                   json.dumps(packet).encode())
        process = subprocess.Popen(
            compare_command(session, "never", start_frame=2,
                            reference_catchup=True),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        reference = threading.Thread(
            target=dyna_warmup_producer,
            args=(session, "reference", [matching, changed, matching], []))
        rtl = threading.Thread(
            target=restored_rtl_producer, args=(session, 2, matching))
        reference.start()
        rtl.start()
        stdout, stderr = process.communicate(timeout=10)
        reference.join(2)
        rtl.join(2)
        assert process.returncode == 0, (process.returncode, stdout, stderr)
        startup = json.loads((session / "STARTUP_ADVANCE.json").read_text())
        assert startup["mode"] == "cold-reference-replay"
        assert startup["rtl_restore_committed_frame"] == 1
        assert [item["frame"] for item in startup["advanced_tokens"]] == [0, 1]
        completion = json.loads((session / "completion.json").read_text())
        assert completion["matched_completion"] and completion["start_frame"] == 2
        print("PASS checkpoint RTL waits while cold reference replays owner packets")

        # Each side's readiness metadata is contractual. A malformed value on
        # either producer must fail preflight rather than silently weakening
        # the warmup boundary.
        for case, field, bad_value, failed_check in (
            ("bad-first-comparable", "first_comparable_token", 1,
             "first_comparable_token_pair"),
            ("bad-warmup-list", "warmup_excluded_tokens", [0],
             "warmup_excluded_tokens_pair"),
        ):
            session = root / case
            make_session(session, "dynagear", capture_start=2)
            ready_path = session / "reference_ready.json"
            ready = json.loads(ready_path.read_text())
            ready[field] = bad_value
            atomic(ready_path, json.dumps(ready).encode())
            result = run_compare(session, "never", start_frame=2)
            assert result.returncode == 2, (case, result.returncode,
                                            result.stdout, result.stderr)
            preflight = json.loads(
                (session / "PREFLIGHT_FAILURE.json").read_text())
            assert preflight["checks"][failed_check] is False
        print("PASS malformed first-comparable and warmup metadata are rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
