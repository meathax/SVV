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
# Enabled for every supported set on 2026-08-21. History: the 2026-08-20
# enablement black-screened every game on hardware -- the top level passed
# ssv_rom_loader the raw HPS index, so the moment Main moved on to the
# trailing <nvram index="4"> element mid-replay, the rest of the ROM was
# silently dropped (rom_loaded never asserted, core never left reset). The
# adaptor now holds the loader's index at 0 and stalls Main via ioctl_wait
# for the replay's duration; verif/tb_ssv_ddr_rom_loader.sv test 4
# reproduces the failure (8 of 1035 bytes with the old RTL) and proves the
# fix (1035 of 1035). Earlier sim-caught fixes: MSB-first byte-order
# reversal, dropped-byte wait-handshake race, core_cold_reset port-gate
# deadlock, and the hps_io end-of-download +1 overshoot. Byte order and the
# length convention were confirmed against Main_MiSTer master
# (mra_loader.cpp rom_finish/shmem_put; user_io_set_download passes len)
# and the IGSPGM reference adaptor.
#
# The RTL fix is NOT yet hardware-verified; these MRAs require an RBF built
# from commit bdb8c8f or later -- on the 20260820 RBF or older they black-
# screen exactly as above. First boot of each game should confirm the load
# completes (LED_USER goes out), is visibly faster than the ioctl stream,
# rotated titles still display, and game switching without a power cycle
# works. Reverting a set to the legacy path is deleting it from this tuple
# and regenerating MRAs -- no RTL change.
DDR_FAST_LOAD_SETS = SUPPORTED_SETS
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
