#!/usr/bin/env python3
"""Authoritative game list for the single universal SSV core profile.

Every entry uses the same ``SSV.rbf``.  Per-game board differences are carried
by the MRA index-1 descriptor and selected at ROM-load time; they are not
separate Quartus revisions or compile-time feature builds.

Keep this list limited to sets for which the project owner has a local ROM
archive and intends to qualify.  Clone sets are listed separately when their
archive is present, even when they share the same hardware feature family.
"""

SUPPORTED_SETS = (
    "dynagear",
    "cairblad",
    "vasara",
    "vasara2",
    "drifto94",
    "stmblade",
    "survartsu",
    "twineag2",
    "ultrax",
    "ultraxg",
)

SUPPORTED_SET_IDS = {
    setname: game_id for game_id, setname in enumerate(SUPPORTED_SETS)
}

# Execution scope for the current source-exhaustion/real-game proof pass.
# This does not replace SUPPORTED_SETS or remove locally qualified clone media;
# it only prevents clone evidence from standing in for a parent-ROM run.
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
