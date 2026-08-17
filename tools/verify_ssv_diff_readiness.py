#!/usr/bin/env python3
"""Static gate for the universal supported-set headless differential configuration."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from ssv_supported_sets import PARENT_RUN_ORDER, SUPPORTED_SETS  # noqa: E402
from ssv_gameplay_scenario import read_scenario  # noqa: E402

EXPECTED_ORDER = tuple(PARENT_RUN_ORDER)


def _schema_errors(value, schema, root_schema, path="$") -> list[str]:
    """Small dependency-free subset of JSON Schema used by project-v4.

    The repository's runtime validator intentionally has no third-party
    dependency.  This mirror checks the schema features used by the checked-in
    project contract, including additionalProperties and $defs/$ref, so an
    executor cannot silently ignore a newly invented configuration key.
    """
    if "$ref" in schema:
        schema = root_schema["$defs"][schema["$ref"].rsplit("/", 1)[-1]]
    errors: list[str] = []
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: value is outside enum")
    typ = schema.get("type")
    if typ == "object":
        if not isinstance(value, dict):
            return [f"{path}: expected object"]
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}.{key}: required")
        if schema.get("additionalProperties") is False:
            allowed = set(schema.get("properties", {}))
            errors.extend(f"{path}.{key}: additional property" for key in value if key not in allowed)
        for key, child_schema in schema.get("properties", {}).items():
            if key in value:
                errors.extend(_schema_errors(value[key], child_schema, root_schema, f"{path}.{key}"))
    elif typ == "array":
        if not isinstance(value, list):
            return [f"{path}: expected array"]
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: too few items")
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            errors.append(f"{path}: duplicate items")
        for index, item in enumerate(value):
            errors.extend(_schema_errors(item, schema.get("items", {}), root_schema, f"{path}[{index}]"))
    elif typ == "string":
        if not isinstance(value, str):
            errors.append(f"{path}: expected string")
        elif len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: string is empty")
    elif typ == "integer":
        if isinstance(value, bool) or not isinstance(value, int):
            errors.append(f"{path}: expected integer")
        elif value < schema.get("minimum", value):
            errors.append(f"{path}: below minimum")
    elif typ == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append(f"{path}: expected number")
    elif typ == "boolean" and not isinstance(value, bool):
        errors.append(f"{path}: expected boolean")
    if "oneOf" in schema:
        matches = sum(not _schema_errors(value, child, root_schema, path) for child in schema["oneOf"])
        if matches != 1:
            errors.append(f"{path}: oneOf did not match exactly once")
    return errors


def main() -> int:
    errors: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    require(tuple(PARENT_RUN_ORDER) == EXPECTED_ORDER,
            f"PARENT_RUN_ORDER is {PARENT_RUN_ORDER}, expected {EXPECTED_ORDER}")
    require(set(SUPPORTED_SETS) == set(EXPECTED_ORDER),
            "supported set membership does not match the authoritative readiness matrix")

    project_path = ROOT / ".mister" / "project.json"
    project_text = project_path.read_text(encoding="utf-8")
    project = json.loads(project_text)
    active_text = "\n".join([
        project_text,
        (ROOT / "core-debug.toml").read_text(encoding="utf-8"),
        (ROOT / "tools" / "build_ssv_headless.ps1").read_text(encoding="utf-8"),
        (ROOT / "tools" / "run_ssv_headless.ps1").read_text(encoding="utf-8"),
        (ROOT / "tools" / "run_ssv_mame_headless.ps1").read_text(encoding="utf-8"),
        (ROOT / "verif" / "ssv_headless_main.cpp").read_text(encoding="utf-8"),
    ])
    for forbidden in ("keithlcy", "wsl.exe", "SDL", "-window", '"AUTO"'):
        require(forbidden.lower() not in active_text.lower(),
                f"active differential configuration contains forbidden token {forbidden!r}")
    require("${SSV_" not in active_text,
            "active differential configuration contains an unbound SSV_* placeholder")

    require(project["mame"]["supported_setnames"] == list(EXPECTED_ORDER),
            ".mister supported_setnames does not follow PARENT_RUN_ORDER")
    require(project["mame"]["version_expected"] == "0.289 (mame0289)",
            "MAME executable contract is not pinned to 0.289/mame0289")
    for setname in EXPECTED_ORDER:
        scenario_path = ROOT / "verif" / "scenarios" / setname / "gameplay_neutral.json"
        try:
            scenario, _ = read_scenario(scenario_path)
            require(scenario["set"] == setname,
                    f"gameplay scenario set mismatch for {setname}")
            require(scenario["stop"]["through_frame"] ==
                    scenario["gameplay_entry"]["neutral_after_frame"] + 120,
                    f"gameplay scenario stop is not entry+120 for {setname}")
        except Exception as error:  # noqa: BLE001 - report all static failures together
            errors.append(f"invalid gameplay scenario {setname}: {error}")
    require(project["mister"]["rbf_name"] == "Arcade-SSV" and
            project["mister"]["require_mra_for_release"] is True and
            project["mister"]["require_rom_mapping"] is True,
            "MiSTer release profile is not the universal Arcade-SSV/MRA profile")
    require(project["capture"]["raw_schema"] == "mister-raw-trace-v4" and
            project["capture"]["canonical_schema"] == "mister-canonical-trace-v4" and
            project["capture"]["diagnostic_resync_window"] == 0,
            "capture contract is not raw/canonical v4 with resynchronization disabled")
    for task in ("verilator_build", "rtl_capture", "mame_capture"):
        require(project["tasks"][task]["enabled"] is True and
                bool(project["tasks"][task]["argv"]),
                f"active task {task} is disabled or empty")
    require(all(isinstance(task.get("argv"), list) and task["argv"]
                for task in project["tasks"].values()),
            "project contains an empty disabled placeholder task")

    observability_text = (ROOT / "docs" / "OBSERVABILITY.json").read_text(
        encoding="utf-8"
    )
    observability = json.loads(observability_text)
    require("AUTO" not in observability_text, "OBSERVABILITY.json contains AUTO")
    cpu_data = observability["domains"].get("cpu_data")
    require(isinstance(cpu_data, dict) and cpu_data.get("candidate_strict") is True,
            "cpu_data is not declared as the candidate strict domain")
    require(isinstance(cpu_data, dict) and cpu_data.get("strict") is False,
            "cpu_data was promoted strict without same-side determinism evidence")
    mainbus = observability["domains"]["mainbus"]
    require(mainbus.get("candidate_strict") is False and mainbus.get("strict") is False,
            "mainbus must remain diagnostic while ROM fetch granularity is unresolved")
    require(observability["rules"].get("strict_no_resync") is True,
            "acceptance contract permits resynchronization")

    preflight = (ROOT / "tools" / "ssv_lockstep_preflight.py").read_text(
        encoding="utf-8"
    )
    require("descriptor_v3" in preflight and "--allow-legacy-v2" in preflight,
            "preflight lacks v3 release enforcement/explicit v2 legacy mode")

    core = (ROOT / "rtl" / "ssv_core.sv").read_text(encoding="utf-8")
    duplicate = re.search(
        r"st010_ce_acc\s*<=\s*st010_acc_next\[15:0\];\s*"
        r"st010_ce_acc\s*<=\s*st010_acc_next\[15:0\];", core,
    )
    require(duplicate is None, "duplicated st010_ce_acc assignment remains")
    sim_block = core[core.find("`ifdef SIMULATION"):]
    for signal in ("debug_mainbus_complete", "debug_v60_retire",
                   "debug_st010_retire", "debug_sound_commit",
                   "debug_frame_boundary"):
        require(signal in sim_block, f"missing simulation debug signal {signal}")

    closure = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in (ROOT / "Arcade-SSV.qsf", ROOT / "files.qip")
        if path.is_file()
    )
    require("ssv_diff_probe" not in closure and "ssv_headless_main" not in closure,
            "simulation-only probe/host leaked into Quartus source closure")

    mame_lua = (ROOT / "tools" / "mame-ssv-headless.lua").read_text(
        encoding="utf-8"
    )
    require("0x000000, 0xffffff" in mame_lua,
            "MAME adapter does not install full program-space taps")
    require(all(token in mame_lua for token in
                ('"record":"barrier"', '"record":"receipt"', '"dropped":0')),
            "MAME adapter lacks barrier/zero-drop receipt records")
    require("SSV_HEADLESS_ROM_BASE" in mame_lua and
            "SSV_HEADLESS_ROM_BASE" in
            (ROOT / "tools" / "run_ssv_mame_headless.ps1").read_text(encoding="utf-8"),
            "MAME adapter does not receive the descriptor-derived ROM base")
    require("video_enable_epoch" in mame_lua and "post_epoch_frames" in mame_lua,
            "MAME adapter stop barrier is not aligned to the shared video-enable epoch")

    # The repository ships a dependency-free runtime validator, but this gate
    # also enforces the schema's additionalProperties contract for the project
    # file.  Extra ad-hoc keys are dangerous here because the executor silently
    # ignores them and a stale contract can look configured while doing nothing.
    schema = json.loads((ROOT / ".mister" / "project.schema.json").read_text(encoding="utf-8"))
    schema_failures = _schema_errors(project, schema, schema)
    require(not schema_failures,
            "project.json fails schema-v4 validation: " + "; ".join(schema_failures[:4]))

    probe = (ROOT / "verif" / "ssv_diff_probe.sv").read_text(encoding="utf-8")
    require("." not in "".join(
        line.split("//", 1)[0] for line in probe.splitlines()
        if "dut." in line
    ), "canonical probe uses a hierarchical DUT path")
    require(all(token in probe for token in
                ('record\\\":\\\"barrier', 'record\\\":\\\"receipt',
                 'dropped\\\":0')),
            "RTL probe lacks barrier/zero-drop receipt records")

    with (ROOT / "core-debug.toml").open("rb") as stream:
        tomllib.load(stream)

    if errors:
        print("SSV differential readiness: FAIL")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("SSV differential readiness: PASS")
    print("  supported-set order: " + ", ".join(EXPECTED_ORDER))
    print("  active path: MAME 0.289 -video none / native UCRT64 headless RTL")
    print("  candidate strict domain: cpu_data (promotion pending determinism proof)")
    print("  Quartus/Verilator execution: not performed by this audit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
