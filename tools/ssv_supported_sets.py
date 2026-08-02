#!/usr/bin/env python3
"""Authoritative game list for the single universal SSV core profile.

Every entry uses the same ``SSV.rbf``.  Per-game board differences are carried
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
    "survartsu",
    "ultraxg",
)

SUPPORTED_SET_IDS = {
    setname: game_id for game_id, setname in enumerate(SUPPORTED_SETS)
}

# Execution scope for the current source-exhaustion/real-game proof pass.
# This remains separate from SUPPORTED_SETS so future diagnostic subsets cannot
# silently change the release profile.
PARENT_RUN_ORDER = (
    "dynagear",
    "vasara",
    "vasara2",
    "cairblad",
    "drifto94",
    "stmblade",
    "twineag2",
    "ultrax",
)

# Lockstep startup surfaces are a protocol property, not a license to skip a
# later mismatch. Dyna Gear's first two completed surfaces straddle its
# accepted video-enable transition; all other qualified sets compare at token
# one after the common token-zero startup surface.
LOCKSTEP_FIRST_COMPARABLE_TOKEN = {
    setname: (2 if setname == "dynagear" else 1)
    for setname in SUPPORTED_SETS
}
