#!/usr/bin/env python3
"""Authoritative game list for the single universal SSV core profile.

Every entry uses the same ``Arcade-SSV.rbf``.  Per-game board differences are carried
by the MRA index-1 descriptor and selected at ROM-load time; they are not
separate Quartus revisions or compile-time feature builds.

Keep this list limited to sets for which the project owner has a local ROM
archive and intends to qualify.  Retired local archives are listed separately
below so the media audit can preserve them without treating them as support.
"""

SUPPORTED_SETS = (
    "dynagear",
    "cairblad",
    "vasara",
    "vasara2",
    "drifto94",
    "stmblade",
    "twineag2",
    "ultrax",
)

# Private archives retained locally for reference, but deliberately excluded
# from the universal profile and MRA generation.
RETIRED_LOCAL_SETS = (
    "ultraxg",
)

SUPPORTED_SET_IDS = {
    setname: game_id for game_id, setname in enumerate(SUPPORTED_SETS)
}

# MiSTer-only convenience controls selected by the profile descriptor.  This
# is deliberately metadata, never a synthesizable set-name branch.
DESCRIPTOR_FEATURE_OVERRIDES = {
    "vasara": {"rapid_fire_b3_to_b1": True},
    "vasara2": {"rapid_fire_b3_to_b1": True},
    "stmblade": {"rapid_fire_b3_to_b1": True},
    "twineag2": {"rapid_fire_b1": True, "rapid_fire_b2": True},
}

# Sets whose <rom index="0"> element carries address=DDR_FAST_LOAD_ADDR, so
# MiSTer Main places the ROM blob directly in DDR3 instead of streaming it
# over ioctl (rtl/mem/ssv_ddr_rom_loader.sv consumes it from there).
#
# Enabled for every supported set on 2026-08-20 after the adaptor gained
# functional coverage: verif/tb_ssv_ddr_rom_loader.sv models the DDRAM_*
# read handshake with randomized latency and free-running loader
# back-pressure, and caught (fixes now in the RTL) an MSB-first byte-order
# reversal, a dropped-byte wait-handshake race, and a core_cold_reset/
# video_reset port-gate deadlock. Byte order was independently confirmed
# against MiSTer-devel/Arcade-IGSPGM_MiSTer's ddr_rom_loader_adaptor
# (buffer[(offset[2:0]*8) +: 8], LSB-first) and this core's own screen_rotate
# BE mapping. Still not hardware-verified per
# ~/.claude/reference/mister-hardware-hazards.md; the first hardware boot of
# each game should confirm the load completes (LED_USER goes out) and the
# game matches the ioctl-streamed load. Reverting a set to the legacy path
# is deleting it from this tuple and regenerating MRAs -- no RTL change.
DDR_FAST_LOAD_SETS = ()
DDR_FAST_LOAD_ADDR = "0x30000000"

# Execution scope for the current source-exhaustion/real-game proof pass.
# This remains separate from SUPPORTED_SETS so future diagnostic subsets cannot
# silently change the release profile.
PARENT_RUN_ORDER = (
    "dynagear",
    "cairblad",
    "vasara",
    "vasara2",
    "ultrax",
    "stmblade",
    "drifto94",
    "twineag2",
)

# Lockstep startup surfaces are a protocol property, not a license to skip a
# later mismatch. Dyna Gear's first two completed surfaces straddle its
# accepted video-enable transition; all other qualified sets compare at token
# one after the common token-zero startup surface.
LOCKSTEP_FIRST_COMPARABLE_TOKEN = {
    setname: (2 if setname == "dynagear" else 1)
    for setname in SUPPORTED_SETS
}
