#!/usr/bin/env python3
"""Per-game configuration block for the SSV core, emitted as MRA <rom index="1">.

Every field is DERIVED from MAME's ssv.cpp, never hand-transcribed -- the same
rule gen_ssv_mras.py follows for ROM names, CRCs and DIP switches, and for the
same reason: nine sets of per-game behaviour is exactly where transcription
goes wrong.

The byte layout is documented in rtl/mem/ssv_rom_loader.sv and decoded into
ssv_pkg::ssv_cfg_t. Byte 15 is the negated sum of bytes 0..14, so a truncated
or reordered block is rejected rather than half-applied.
"""

import re

# ---------------------------------------------------------------------------
# PARSER STATUS -- all four verified against a direct reading of ssv.cpp.
#
#   set        addrmap          wdog  flags
#   dynagear   survarts_map      1    ident=0 irq1=0
#   survarts   survarts_map      1    ident=0 irq1=0
#   twineag2   twineag2_map      1    ident=0 irq1=1
#   ultrax     ultrax_map        1    ident=0 irq1=1
#   cairblad   cairblad_map      1    ident=1 irq1=0
#   vasara     ryorioh_map       2    ident=0 irq1=0
#   vasara2    ryorioh_map       2    ident=0 irq1=0
#   drifto94   drifto94_map      0    ident=0 irq1=0
#   stmblade   drifto94_map      0    ident=0 irq1=0
#
# Three bugs had to be fixed to get there, all of which produced plausible but
# WRONG values rather than errors -- which is why each was checked against the
# source by hand instead of being trusted:
#
#  1. Function bodies were matched with a non-greedy regex ending at a
#     line-initial "}". That terminates inside a for-loop, so init_ssv's body
#     was truncated and the flags were nonsense. Now brace-matched.
#
#  2. The init functions CHAIN: init_ssv_tilescram() and init_ssv_irq1() both
#     call init_ssv() first and then override one thing. Testing for the mere
#     presence of an identifier is meaningless here -- init_ssv sets
#     m_interrupt_ultrax = FALSE, so "is the name present" answered true for
#     every set. The last assignment wins, and inheritance is followed.
#
#  3. reset16_r / reset16_w live in the ADDRESS MAP, not the machine config,
#     and the map is rarely named after the set (dynagear runs survarts_map,
#     vasara2 runs vasara's ryorioh_map). Worse, the three ST010 titles live in
#     a DERIVED class, drifto94_state, so hardcoding "ssv_state::" made
#     drifto94, stmblade and twineag2 all silently report "no watchdog" -- and
#     for twineag2 that is wrong in the dangerous direction, because a board
#     that does have a watchdog would never have been kicked.
# ---------------------------------------------------------------------------


def decompose_tiles(tiles):
    """tiles -> (k, mul3), where tiles == (3 << k) or (1 << k).

    MAME wraps sprite codes with `code % gfxelement->elements()` -- a true
    modulo -- and elements() = sprites_region / 128. Across the nine SSV
    targets that is 0x18000, 0x20000, 0x30000 or 0x40000, and three of those
    are 3*2^k rather than powers of two, which a plain bit-mask gets wrong.
    """
    k, n = 0, tiles
    while n % 2 == 0:
        n //= 2
        k += 1
    if n == 1:
        return k, 0
    if n == 3:
        return k, 1
    raise ValueError("tile count 0x%x is neither 2^k nor 3*2^k" % tiles)


def _fn_body(src, name, args="()"):
    """Body of a function, brace-matched rather than regex-terminated.

    A non-greedy regex terminated by a line-initial closing brace stops inside
    a for-loop body, which is why the first version of this parser reported
    nonsense. Counting braces is the only reliable way.
    """
    # The class is NOT always ssv_state: the ST010 titles (drifto94,
    # stmblade, twineag2) live in a derived drifto94_state, and hardcoding the
    # base class made all three silently report "no watchdog".
    m = re.search(r"void\s+\w+::%s\s*%s" % (re.escape(name), re.escape(args)),
                  src)
    if not m:
        return ""
    i = src.find("{", m.end() - 1)
    if i < 0:
        return ""
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
        j += 1
    return ""


def resolve_init(src, name, depth=0):
    """Flags for an init_* function, following its init_ssv() chain.

    The chain matters and is why a flat text scan fails:
      init_ssv()           m_tile_code[i] = bitswap<4>(...); m_interrupt_ultrax = false
      init_ssv_tilescram() init_ssv(); then m_tile_code[i] = i << 16   (identity)
      init_ssv_irq1()      init_ssv(); then m_interrupt_ultrax = true
    So the value is whatever the LAST assignment sets, and merely finding the
    identifier in the body tells you nothing about which way it was set.
    """
    body = _fn_body(src, name)
    flags = {"tile_code_identity": False, "irq_level1_line0": False}
    if not body or depth > 3:
        return flags
    # Inherit first, then let this body's own assignments override.
    for call in re.finditer(r"^\s*(init_\w+)\(\);", body, re.M):
        flags.update(resolve_init(src, call.group(1), depth + 1))
    tile = re.findall(r"m_tile_code\[i\]\s*=\s*([^;]+);", body)
    if tile:
        flags["tile_code_identity"] = "bitswap" not in tile[-1]
    irq = re.findall(r"m_interrupt_ultrax\s*=\s*(true|false)", body)
    if irq:
        flags["irq_level1_line0"] = (irq[-1] == "true")
    return flags


def parse_inits(src):
    """All init_* functions, fully resolved."""
    names = set(re.findall(r"void \w+::(init_\w+)\(\)", src))
    return {n: resolve_init(src, n) for n in sorted(names)}


def watchdog_mode(src, map_name):
    """0 = no watchdog, 1 = read-kick, 2 = write-kick -- from the ADDRESS MAP.

    reset16_r / reset16_w appear in `map(0x210000, 0x210001)` inside the
    address map, NOT in the machine config, which is where the first version of
    this looked. Some maps carry `.nopr()` with the watchdog commented out
    (drifto94/stmblade), which reads as no device.
    """
    body = _fn_body(src, map_name, "(address_map &map)")
    if not body:
        return 0
    for line in body.splitlines():
        if "0x210000" not in line:
            continue
        code = line.split("//")[0]
        if "reset16_w" in code:
            return 2
        if "reset16_r" in code:
            return 1
        return 0            # nopr() or otherwise no watchdog device
    return 0


def has_add_buttons(src, map_name):
    """True when the address map decodes $500008 (the extra-input window)."""
    body = _fn_body(src, map_name, "(address_map &map)")
    return "0x500008" in body


def build_cfg_bytes(game_id, prog_size, gfx_region, gfx_loaded,
                    ens_valid, ens_map, flags, wdog):
    """Assemble the 16-byte block. Raises if a field will not fit."""
    k, mul3 = decompose_tiles(gfx_region // 128)
    quarters = 4 if gfx_loaded >= gfx_region else 3
    prog_mb = prog_size >> 20
    gfx_mb = gfx_region >> 20
    if not 1 <= prog_mb <= 7:
        raise ValueError("program size %d MB does not fit prog_mb" % prog_mb)
    if gfx_mb > 63:
        raise ValueError("graphics region %d MB does not fit gfx_mb" % gfx_mb)

    b = [0] * 16
    b[0] = 0x53                 # magic 'S'
    b[1] = 1                    # version
    b[2] = prog_mb
    b[3] = gfx_mb
    b[4] = k
    b[5] = mul3
    b[6] = quarters
    b[7] = ens_map & 0xFF       # 2 bits per ES5506 CR bank -> stream slot
    b[8] = ens_valid & 0x0F
    b[9] = ((1 if flags.get("tile_code_identity") else 0) |
            (2 if flags.get("irq_level1_line0") else 0) |
            (4 if flags.get("has_add_buttons") else 0))
    b[10] = wdog & 0x03
    b[11] = game_id & 0x0F
    b[15] = (-sum(b[:15])) & 0xFF
    return b


def cfg_rom_block(cfg_bytes, indent="  "):
    """MRA <rom index="1"> lines.

    MUST be emitted BEFORE <rom index="0">: the loader cannot place index-0
    bytes without knowing the layout, and it discards them until this block
    validates.
    """
    hexed = "".join("%02X" % v for v in cfg_bytes)
    return ['%s<rom index="1">' % indent,
            '%s  <part>%s</part>' % (indent, hexed),
            '%s</rom>' % indent]


def resolve_addrmap(src, config_name, depth=0):
    """Machine-config name -> the address map it installs.

    Needed because the map is rarely named after the set: dynagear inherits
    survarts, which does set_addrmap(..., &ssv_state::survarts_map). Looking
    for `<set>_map` finds nothing and silently reports "no watchdog", which for
    dynagear would be wrong in the dangerous direction.
    """
    body = _fn_body(src, config_name, "(machine_config &config)")
    if not body or depth > 3:
        return None
    m = re.search(r"set_addrmap\(AS_PROGRAM,\s*&\w+::(\w+)\)", body)
    if m:
        return m.group(1)
    for inc in re.finditer(r"^\s*(\w+)\(config\);", body, re.M):
        got = resolve_addrmap(src, inc.group(1), depth + 1)
        if got:
            return got
    return None


def watchdog_mode_for_set(src, config_name):
    """Watchdog mode for a machine config, resolving its address map first."""
    mp = resolve_addrmap(src, config_name)
    return watchdog_mode(src, mp) if mp else 0
