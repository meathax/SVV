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

import ast
import operator
import re

# ---------------------------------------------------------------------------
# PARSER STATUS -- all four verified against a direct reading of ssv.cpp.
#
# The has_st010 flag is NOT in this table because it is not parsed from the
# machine config at all: it is the presence of a ROM_REGION named "st010", which
# holds for drifto94, stmblade, stmbladej and twineag2. Keying on the region
# rather than on UPD96050(config, ...) keeps the flag and the MRA's st010.bin
# part derived from the same fact, so they cannot disagree.
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


# The universal release profile is deliberately limited to the graphics
# geometries used by tools/ssv_supported_sets.py.  Keep these constraints here
# so both descriptor generation and its focused tests reject an accidental
# expansion to an unqualified MAME set.
SUPPORTED_GFX_MB = (12, 16, 24, 32)
ODD_TILE_FACTORS = (1, 3)


def decompose_tiles(tiles):
    """tiles -> (k, factor_code), where tiles == ODD_TILE_FACTORS[code] << k.

    MAME wraps sprite codes with `code % gfxelement->elements()` -- a true
    modulo -- and elements() = sprites_region / 128.  The supported-set manifest
    needs only power-of-two and 3*power-of-two tile counts.  Encoding the odd
    factor selects the shared small constant-modulo path in RTL.
    """
    k, n = 0, tiles
    while n % 2 == 0:
        n //= 2
        k += 1
    if n not in ODD_TILE_FACTORS:
        raise ValueError("tile count 0x%x is not a qualified factor(1/3)*2^k" % tiles)
    return k, ODD_TILE_FACTORS.index(n)


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


def _addrmap_bodies(src, map_name, seen=None):
    """Return a map and the base maps it calls, most-derived first."""
    seen = set() if seen is None else seen
    if not map_name or map_name in seen:
        return []
    seen.add(map_name)
    body = _fn_body(src, map_name, "(address_map &map)")
    if not body:
        return []
    out = [body]
    for call in re.finditer(r"^\s*(\w+)\(map(?:\s*,[^;]*)?\);", body, re.M):
        out.extend(_addrmap_bodies(src, call.group(1), seen))
    return out


def watchdog_mode(src, map_name):
    """0 = no watchdog, 1 = read-kick, 2 = write-kick -- from the ADDRESS MAP.

    reset16_r / reset16_w appear in `map(0x210000, 0x210001)` inside the
    address map, NOT in the machine config, which is where the first version of
    this looked. Some maps carry `.nopr()` with the watchdog commented out
    (drifto94/stmblade), which reads as no device.
    """
    for body in _addrmap_bodies(src, map_name):
        for line in body.splitlines():
            if "0x210000" not in line:
                continue
            code = line.split("//")[0]
            if "reset16_w" in code:
                return 2
            if "reset16_r" in code:
                return 1
            return 0        # nopr() in a derived map overrides its base
    return 0


def _input_bodies(src, ports_name, seen=None):
    seen = set() if seen is None else seen
    if not ports_name or ports_name in seen:
        return []
    seen.add(ports_name)
    m = re.search(r"INPUT_PORTS_START\(\s*%s\s*\)(.*?)INPUT_PORTS_END" %
                  re.escape(ports_name), src, re.S)
    if not m:
        return []
    body = m.group(1)
    out = [body]
    for inc in re.finditer(r"PORT_INCLUDE\(\s*(\w+)\s*\)", body):
        out.extend(_input_bodies(src, inc.group(1), seen))
    return out


def extra_input_mode(src, map_name, ports_name):
    """0 none, 1 decoded/idle, 2 decoded six-button input window."""
    decoded = any("0x500008" in body for body in _addrmap_bodies(src, map_name))
    if not decoded:
        return 0
    for body in _input_bodies(src, ports_name):
        for section in re.split(r"(?=PORT_(?:START|MODIFY)\s*\()", body):
            if '"ADD_BUTTONS"' in section and re.search(r"IPT_BUTTON[456]", section):
                return 2
    return 1


def system_input_mode(src, ports_name):
    """0 normal; 1 MAME fixes SYSTEM Test/Tilt bits high as unknown."""
    for body in _input_bodies(src, ports_name):
        for section in re.split(r"(?=PORT_(?:START|MODIFY)\s*\()", body):
            if '"SYSTEM"' not in section:
                continue
            fixed_unknown = set()
            for line in section.splitlines():
                m = re.search(r"PORT_BIT\(\s*(0x[0-9a-fA-F]+).*IPT_UNKNOWN", line)
                if m:
                    fixed_unknown.add(int(m.group(1), 16))
            if 0x0008 in fixed_unknown and 0x0010 in fixed_unknown:
                return 1
    return 0


def has_add_buttons(src, map_name):
    """Legacy compatibility helper: whether $500008 is decoded at all."""
    return any("0x500008" in body for body in _addrmap_bodies(src, map_name))


def has_nvram(src, map_name):
    """True when the address map decodes Cairblad's $580000 NVRAM window."""
    return any("0x580000" in body for body in _addrmap_bodies(src, map_name))


def nvram_mode(src, map_name):
    """Return the exact MAME NVRAM window size: 0, 2 KiB, or 64 KiB."""
    for body in _addrmap_bodies(src, map_name):
        if re.search(r"0x580000\s*,\s*0x5807ff\)\.ram", body):
            return 1
        if re.search(r"0x580000\s*,\s*0x58ffff\)\.ram", body):
            return 2
    return 0


def extra_ram_mode(src, map_name):
    """Return the descriptor-selected extra CPU RAM map.

    MAME's ``.ram()`` and ``.nopw()`` are intentionally distinguished.  The
    latter is a write sink in Drift Out/STM Blade, not backing RAM that the
    universal core should expose to the CPU.
    """
    for body in _addrmap_bodies(src, map_name):
        if re.search(r"0x400000\s*,\s*0x43ffff\)\.ram\s*\(", body):
            return 1
        if re.search(r"0x010000\s*,\s*0x03ffff\)\.ram\s*\(", body):
            return 2
    return 0


def has_st010(regions):
    """True when the set declares a ROM_REGION named "st010".

    Deliberately keyed on the ROM REGION and not on the machine config or the
    state class. UPD96050(config, ...) appears in drifto94, stmblade and
    twineag2, all of which live in the derived drifto94_state -- and a parser
    that went looking for `ssv_state::` is exactly how these three previously
    ended up reporting the wrong watchdog. The region is class-agnostic and is
    also the thing the MRA has to emit, so keying on it keeps the flag and the
    ROM part from ever disagreeing.
    """
    return any(r['name'] == 'st010' for r in regions)


def has_drifto_unknown(src, map_name):
    """True for drifto94_map's MAME random-read test windows."""
    return any("0x510000" in body and "drifto94_unknown_r" in body and
               "0x520000" in body for body in _addrmap_bodies(src, map_name))


def lockout_inverted(src, map_name):
    """Descriptor fact only; the core does not yet gate coin inputs."""
    return any("lockout_inv_w" in body for body in _addrmap_bodies(src, map_name))


_BINOPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
           ast.Div: operator.floordiv, ast.FloorDiv: operator.floordiv}


def _const_expr(text):
    """Evaluate the integer-only arithmetic MAME uses in set_visarea()."""
    def visit(node):
        if isinstance(node, ast.Expression):
            return visit(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = visit(node.operand)
            return value if isinstance(node.op, ast.UAdd) else -value
        if isinstance(node, ast.BinOp) and type(node.op) in _BINOPS:
            return _BINOPS[type(node.op)](visit(node.left), visit(node.right))
        raise ValueError("non-constant geometry expression %r" % text)
    return visit(ast.parse(text.strip(), mode="eval"))


def visible_geometry(src, config_name, depth=0):
    """Return MAME's configured visible width/height, following config calls."""
    if depth > 8:
        raise ValueError("machine-config inheritance too deep at %s" % config_name)
    body = _fn_body(src, config_name, "(machine_config &config)")
    if not body:
        raise ValueError("no machine config body for %s" % config_name)
    start = body.find("set_visarea(")
    if start >= 0:
        begin = start + len("set_visarea(")
        depth_paren, end = 1, begin
        while end < len(body) and depth_paren:
            if body[end] == "(":
                depth_paren += 1
            elif body[end] == ")":
                depth_paren -= 1
            end += 1
        args, part, nested = [], [], 0
        for char in body[begin:end - 1]:
            if char == "(":
                nested += 1
            elif char == ")":
                nested -= 1
            if char == "," and nested == 0:
                args.append("".join(part))
                part = []
            else:
                part.append(char)
        args.append("".join(part))
        if len(args) != 4:
            raise ValueError("set_visarea in %s has %d arguments" %
                             (config_name, len(args)))
        x0, x1, y0, y1 = (_const_expr(v) for v in args)
        return x1 - x0 + 1, y1 - y0 + 1
    for inc in re.finditer(r"^\s*(\w+)\(config\);", body, re.M):
        try:
            return visible_geometry(src, inc.group(1), depth + 1)
        except ValueError:
            pass
    raise ValueError("no set_visarea reachable from %s" % config_name)


def graphics_quarters(gfx_region, gfx_load_end):
    """Whether ROM data reaches the fourth logical graphics quarter."""
    return 4 if gfx_load_end > (gfx_region * 3) // 4 else 3


def build_cfg_bytes(game_id, prog_size, gfx_region, gfx_load_end,
                    sample_mb, ens_valid, ens_map, flags, wdog,
                    visible_width, visible_height):
    """Assemble the 16-byte block. Raises if a field will not fit."""
    k, factor_code = decompose_tiles(gfx_region // 128)
    quarters = graphics_quarters(gfx_region, gfx_load_end)
    prog_mb = prog_size >> 20
    gfx_mb = gfx_region >> 20
    if not 1 <= prog_mb <= 7:
        raise ValueError("program size %d MB does not fit prog_mb" % prog_mb)
    if gfx_mb not in SUPPORTED_GFX_MB:
        raise ValueError("graphics region %d MB is outside the supported profile" %
                         gfx_mb)
    if visible_width & 1 or not 2 <= visible_width <= 510:
        raise ValueError("visible width %d is not an encodable even width" % visible_width)
    if not 1 <= visible_height <= 255:
        raise ValueError("visible height %d does not fit" % visible_height)

    b = [0] * 16
    b[0] = 0x53                 # magic 'S'
    b[1] = 2                    # version
    b[2] = prog_mb
    b[3] = gfx_mb
    b[4] = k
    b[5] = factor_code
    b[6] = quarters
    b[7] = ens_map & 0xFF       # 2 bits per ES5506 CR bank -> stream slot
    b[8] = ens_valid & 0x0F
    b[9] = ((1 if flags.get("tile_code_identity") else 0) |
            (2 if flags.get("irq_level1_line0") else 0) |
            # Bit 2 is reserved zero in the supported descriptor ABI.
            (8 if flags.get("has_st010") else 0) |
            (16 if flags.get("has_drifto_unknown") else 0) |
            (32 if flags.get("lockout_inverted") else 0) |
            ((flags.get("extra_input_mode", 0) & 0x03) << 6))
    extra_mode = flags.get("extra_ram_mode", 0)
    if extra_mode not in (0, 1, 2):
        raise ValueError("unsupported extra RAM mode %r" % (extra_mode,))
    nvram_size_mode = flags.get("nvram_mode", 0)
    if nvram_size_mode not in (0, 1, 2):
        raise ValueError("unsupported NVRAM mode %r" % (nvram_size_mode,))
    b[10] = ((wdog & 0x03) |
             (4 if flags.get("has_nvram") else 0) |
             ((extra_mode & 0x03) << 3) |
             (32 if flags.get("system_input_mode") else 0) |
             ((nvram_size_mode & 0x03) << 6))
    b[11] = game_id & 0x0F
    b[12] = sample_mb & 0x3F
    b[13] = visible_width // 2
    b[14] = visible_height
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
