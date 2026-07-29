#!/usr/bin/env python3
"""Generate MRA files for the Sammy-published SSV titles from MAME's ssv.cpp.

Everything in the output is derived from MAME source -- ROM names, CRCs, load
order, region sizes, DIP switch names/values/defaults and the game metadata.
Nothing is hand-transcribed, because twelve sets of forty-odd CRCs is exactly
where hand-transcription goes wrong.

  python tools/gen_ssv_mras.py path/to/ssv.cpp mra/

SCOPE WARNING, and it is not a small one: of these sets the SSV core can
currently run ONLY dynagear. rtl/mem/ssv_rom_loader.sv takes a fixed stream --
1 MB program, then graphics as three 4 MB quarters, then 4 MB of samples -- and
every other title here has a different graphics geometry, a bigger sample bank,
or hardware the core does not implement (mahjong matrix, dial, trackball, tile
descrambling). These MRAs describe the ROM sets correctly; they will not boot
until the loader is generalised. Each generated file says so in its <about>.
"""

import re
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ssv_cfg_block as cfgblk

# Every set in the driver, discovered from the GAME() lines rather than
# hardcoded, so a MAME update that adds an SSV title is picked up by re-running
# this instead of by remembering to edit a list.
SETS = None

# The core's CONF_STR J1 list is fixed at six entries, so an MRA cannot add a
# button the core does not expose. Games with more buttons than this are noted
# in <about> rather than silently mapped to nothing.
# The core's J1 list is now ten entries: six game buttons then
# Test/Service/Start/Coin. SSV's P1/P2 ports carry B1-B3 and the $500008
# window carries B4-B6 (Survival Arts uses all six). Test and Service reuse
# R and L, which is what they mapped to before the widening.
BUTTONS_DEFAULT = ('Button 1,Button 2,Button 3,Button 4,Button 5,Button 6,'
                   'Test,Service,Start,Coin',
                   'A,B,X,Y,L,R,R,L,Start,Select')
BUTTONS = {'dynagear': ('Fire,Jump,Button 3,Button 4,Button 5,Button 6,'
                        'Test,Service,Start,Coin',
                        'A,B,X,Y,L,R,R,L,Start,Select')}

# SSV_COINAGE_* expansions, from the macro definitions in ssv.cpp.
COINAGE = {
    'BASIC':    {1: '2C/1C', 3: '1C/1C', 0: '2C/3C', 2: '1C/2C'},
    'STANDARD': {5: '3C/1C', 6: '2C/1C', 7: '1C/1C', 4: '1C/2C',
                 3: '1C/3C', 2: '1C/4C', 1: '1C/5C', 0: '1C/6C'},
    'EXTENDED': {7: '4C/1C', 8: '3C/1C', 9: '2C/1C', 15: '1C/1C',
                 6: '2C/3C', 14: '1C/2C', 13: '1C/3C', 12: '1C/4C',
                 11: '1C/5C', 10: '1C/6C', 5: 'Multi A', 4: 'Multi B',
                 3: 'Multi C', 2: 'Multi D', 1: 'Multi E'},
}
COINAGE_MASK = {'BASIC': 0x3, 'STANDARD': 0x7, 'EXTENDED': 0xf}


def xml_escape(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
             .replace('"', '&quot;'))


def deranged(s):
    """DEF_STR(Foo_Bar) and friends -> readable text."""
    s = s.strip()
    m = re.fullmatch(r'DEF_STR\(\s*(\w+)\s*\)', s)
    if m:
        name = m.group(1)
        special = {'Coin_A': 'Coin A', 'Coin_B': 'Coin B',
                   'Flip_Screen': 'Flip Screen', 'Demo_Sounds': 'Demo Sounds',
                   'Free_Play': 'Free Play', 'Unknown': 'Unknown',
                   'Unused': 'Unused', 'Off': 'Off', 'On': 'On'}
        if name in special:
            return special[name]
        m2 = re.fullmatch(r'(\d)C_(\d)C', name)
        if m2:
            return '%sC/%sC' % m2.groups()
        return name.replace('_', ' ')
    return s.strip('"')


def parse_rom_start(src, setname):
    m = re.search(r'ROM_START\(\s*%s\s*\)(.*?)\nROM_END' % setname, src, re.S)
    if not m:
        return None
    body = m.group(1)
    regions, current = [], None
    for line in body.splitlines():
        line = line.split('//')[0].strip()
        if not line:
            continue
        r = re.match(r'ROM_REGION(?:16_[BL]E|32_[BL]E)?\(\s*(0x[0-9a-fA-F]+)\s*,'
                     r'\s*"([^"]+)"', line)
        if r:
            current = {'name': r.group(2), 'size': int(r.group(1), 16),
                       'loads': []}
            regions.append(current)
            continue
        l = re.match(r'(ROM_LOAD\w*)\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                     r'\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)', line)
        if l and current is not None:
            current['loads'].append({
                'kind': l.group(1), 'name': l.group(2),
                'offset': int(l.group(3), 16), 'size': int(l.group(4), 16),
                'crc': l.group(5).lower()})
            continue
        # ROM_RELOAD re-places the PRECEDING file at another offset -- a real
        # mirror in the region image, so it has to be emitted or the assembled
        # ROM is short. It carries no filename; it inherits the last load's.
        rl = re.match(r'ROM_RELOAD\(\s*(0x[0-9a-fA-F]+)\s*,'
                      r'\s*(0x[0-9a-fA-F]+)\s*\)', line)
        if rl and current is not None and current['loads']:
            prev = current['loads'][-1]
            current['loads'].append({
                'kind': prev['kind'], 'name': prev['name'],
                'offset': int(rl.group(1), 16), 'size': int(rl.group(2), 16),
                'crc': prev['crc'], 'reload': True})
            continue
        # ROM_COPY aliases another region's contents. The ES5506 banks use it to
        # point several banks at one sample set; that is an address alias, not
        # extra data, so it is recorded for the comment and not duplicated.
        cp = re.match(r'ROM_COPY\(\s*"([^"]+)"', line)
        if cp and current is not None:
            current.setdefault('copies', []).append(cp.group(1))
    return regions


def emit_region(region, indent='    '):
    """Turn one MAME region into MRA <part>/<interleave> lines, padding gaps."""
    out, pos = [], 0
    loads = sorted(region['loads'], key=lambda x: x['offset'])
    i = 0
    while i < len(loads):
        ld = loads[i]
        if ld['offset'] > pos:
            out.append('%s<part repeat="0x%x">00</part>'
                       % (indent, ld['offset'] - pos))
            pos = ld['offset']
        if ld['kind'] == 'ROM_LOAD16_BYTE':
            nxt = loads[i + 1] if i + 1 < len(loads) else None
            paired = (nxt is not None and nxt['kind'] == 'ROM_LOAD16_BYTE'
                      and nxt['offset'] == ld['offset'] + 1)
            # An UNPAIRED byte load is a real MAME idiom, not a parse failure:
            # drifto94's sample ROMs each fill one lane of a 16-bit region and
            # leave the other as ERASE00. A single-part interleave does exactly
            # that -- the lane this part does not supply comes out as zero.
            out.append('%s<interleave output="16">' % indent)
            out.append('%s  <part name="%s" crc="%s" map="%s"/>'
                       % (indent, xml_escape(ld['name']), ld['crc'],
                          '01' if ld['offset'] % 2 == 0 else '10'))
            if paired:
                out.append('%s  <part name="%s" crc="%s" map="10"/>'
                           % (indent, xml_escape(nxt['name']), nxt['crc']))
            out.append('%s</interleave>' % indent)
            # Either way the pair of lanes spans twice one part's length.
            pos += ld['size'] * 2
            i += 2 if paired else 1
            continue
        if ld['kind'] == 'ROM_LOAD16_WORD_SWAP':
            out.append('%s<interleave output="16">' % indent)
            out.append('%s  <part name="%s" crc="%s" map="21"/>'
                       % (indent, xml_escape(ld['name']), ld['crc']))
            out.append('%s</interleave>' % indent)
        else:
            out.append('%s<part name="%s" crc="%s"/>'
                       % (indent, xml_escape(ld['name']), ld['crc']))
        pos += ld['size']
        i += 1
    return out, pos


def parse_dips(src, portsname, _seen=None):
    """Collect DSW1/DSW2 switches, expanding the SSV_COINAGE_* macros.

    PORT_INCLUDE is followed: ssv_quiz defines Flip Screen, Service, Demo
    Sounds, Coin A and Difficulty that its users (ryorioh, koikois2) inherit
    and never restate, so a parser that ignores includes emits an empty
    <switches> for them. A later PORT_MODIFY of the same port and mask wins.
    """
    _seen = _seen or set()
    if portsname in _seen:                       # guard against a cycle
        return []
    _seen.add(portsname)
    m = re.search(r'INPUT_PORTS_START\(\s*%s\s*\)(.*?)INPUT_PORTS_END'
                  % portsname, src, re.S)
    if not m:
        return []
    body, dips, port, cur = m.group(1), [], None, None
    for inc in re.finditer(r'PORT_INCLUDE\(\s*(\w+)\s*\)', body):
        dips.extend(parse_dips(src, inc.group(1), _seen))
    for line in body.splitlines():
        line = line.split('//')[0].rstrip()
        if not line.strip():
            continue
        p = re.search(r'PORT_(?:MODIFY|START)\(\s*"(DSW\d)"', line)
        if p:
            port, cur = p.group(1), None
            continue
        if re.search(r'PORT_(?:MODIFY|START)\(', line):
            port, cur = None, None
            continue
        if port is None:
            continue
        c = re.search(r'SSV_COINAGE_(BASIC|STANDARD|EXTENDED)\(\s*(\d+)\s*,'
                      r'\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*(.*?)\s*,\s*"([^"]+)"',
                      line)
        if c:
            kind, shift = c.group(1), int(c.group(2))
            default = int(c.group(3), 0)
            mask = COINAGE_MASK[kind] << shift
            cur = {'port': port, 'mask': mask, 'default': default << shift,
                   'name': deranged(c.group(4)), 'settings': []}
            for val, label in COINAGE[kind].items():
                cur['settings'].append((val << shift, label))
            dips.append(cur)
            cur = None          # macro is self-contained
            continue
        d = re.search(r'PORT_DIPNAME\(\s*(0x[0-9a-fA-F]+)\s*,'
                      r'\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*'
                      r'(?:PORT_DIPLOCATION|$)', line)
        if d:
            cur = {'port': port, 'mask': int(d.group(1), 16),
                   'default': int(d.group(2), 16),
                   'name': deranged(d.group(3)), 'settings': []}
            dips.append(cur)
            continue
        sv = re.search(r'PORT_SERVICE_DIPLOC\(\s*(0x[0-9a-fA-F]+)\s*,'
                       r'\s*IP_ACTIVE_(LOW|HIGH)', line)
        if sv:
            mask = int(sv.group(1), 16)
            on = 0 if sv.group(2) == 'LOW' else mask
            dips.append({'port': port, 'mask': mask, 'default': mask - on,
                         'name': 'Service Mode',
                         'settings': [(mask - on, 'Off'), (on, 'On')]})
            cur = None
            continue
        s = re.search(r'PORT_DIPSETTING\(\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*$',
                      line)
        if s and cur is not None:
            cur['settings'].append((int(s.group(1), 16), deranged(s.group(2))))

    # A PORT_MODIFY overriding an inherited switch appears later with the same
    # port and mask; keep the last definition of each.
    merged = {}
    for d in dips:
        if d['settings'] and d['mask']:
            merged[(d['port'], d['mask'])] = d
    return list(merged.values())


def dips_to_mra(dips):
    """MRA <switches>: bit 0-7 are DSW1, 8-15 DSW2, defaults as MAME sets.

    Returns (default, lines, skipped) -- skipped names the switches that cannot
    be expressed, so the caller can say so rather than quietly dropping them.
    """
    if not dips:
        return None, None, []
    default = [0, 0]
    lines, skipped = [], []
    for port, base in (('DSW1', 0), ('DSW2', 8)):
        group = [d for d in dips if d['port'] == port]
        if not group:
            continue
        lines.append('    <!-- %s -->' % port)
        for d in sorted(group, key=lambda x: x['mask']):
            mask, idx = d['mask'], 0 if port == 'DSW1' else 1
            lo = (mask & -mask).bit_length() - 1
            hi = mask.bit_length() - 1
            # The default still applies even if the control cannot be shown.
            default[idx] |= d['default'] & mask
            # MRA bits="a,b" is the contiguous range a..b. ultrax's Region is
            # mask 0x14 -- DSW2 switches 3 and 5, with switch 4 (Free Play) in
            # between -- so it has no single-control representation and would
            # otherwise silently swallow the neighbouring switch.
            if mask != (((1 << (hi - lo + 1)) - 1) << lo):
                skipped.append('%s (%s mask 0x%02X, non-contiguous)'
                               % (d['name'], port, mask))
                continue
            bits = str(base + lo) if lo == hi else '%d,%d' % (base + lo,
                                                              base + hi)
            # MAME's declaration order, not sorted by raw value: it lists
            # settings the way a player expects to scroll them (Easy, Normal,
            # Hard, Hardest / Lives 1, 2, 3, 4), and the raw values are
            # arbitrary bit patterns whose numeric order means nothing.
            pairs = d['settings']
            # Commas separate entries in ids=, so a label containing one
            # ("70000, every 90000" in pastelis) would silently split into two
            # and desynchronise ids from values. MRA has no escape for it.
            ids = ','.join(xml_escape(lbl).replace(', ', ' / ').replace(',', ' /')
                           for _, lbl in pairs)
            vals = ','.join(str(v >> lo) for v, _ in pairs)
            lines.append('    <dip bits="%s" name="%s" ids="%s" values="%s"/>'
                         % (bits, xml_escape(d['name']), ids, vals))
    return ('%02X,%02X' % (default[0] & 0xff, default[1] & 0xff),
            lines, skipped)



def ensoniq_banks(regions):
    """(bank_valid, bank_map) for the four ES5506 CR banks.

    MAME declares ensoniq.0..3. A bank with its own ROM_LOADs reads its own
    stream slot; a bank declared with ROM_COPY is an ADDRESS ALIAS onto another
    bank, not extra data, so it is marked valid but mapped to the source slot.
    That is what lets twineag2/ultrax work without duplicating 8 MB of samples
    in SDRAM.
    """
    by_name = {}
    for r in regions:
        if r['name'].startswith('ensoniq'):
            idx = r['name'].split('.')[-1]
            by_name[int(idx) if idx.isdigit() else 0] = r
    valid = 0
    bmap = 0
    slot = {}
    nxt = 0
    for b in sorted(by_name):
        if by_name[b]['loads']:
            slot[b] = nxt
            nxt += 1
    for b in sorted(by_name):
        r = by_name[b]
        if r['loads']:
            src = slot[b]
        elif r.get('copies'):
            cn = r['copies'][0].split('.')[-1]
            src = slot.get(int(cn) if cn.isdigit() else 0, 0)
        else:
            continue
        valid |= (1 << b)
        bmap |= (src & 3) << (2 * b)
    return valid, bmap


# Sets the core can currently run. Order fixes game_id.
SUPPORTED = ['dynagear']

def main():
    src_path, out_dir = sys.argv[1], sys.argv[2]
    src = open(src_path, encoding='utf-8', errors='replace').read()
    os.makedirs(out_dir, exist_ok=True)

    games = {}
    # Groups: 1 year, 2 set, 3 parent, 4 machine config, 5 input ports,
    # 6 state class, 7 init function.
    game_re = (r'^GAME\(\s*(\d+\??)\s*,\s*(\w+)\s*,\s*(\w+)\s*,'
               r'\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,'
               r'.*?(ROT\d+)\s*,\s*"([^"]*)"'
               r'\s*,\s*"((?:[^"\\]|\\.)*)"')
    for m in re.finditer(game_re, src, re.M | re.S):
        games[m.group(2)] = {'year': m.group(1).rstrip('?'),
                             'parent': m.group(3), 'machine': m.group(4),
                             'ports': m.group(5), 'init': m.group(7),
                             'rot': m.group(8), 'maker': m.group(9),
                             'desc': m.group(10)}

    order = [m.group(1) for m in
             re.finditer(r'^GAME\(\s*\d+\??\s*,\s*(\w+)', src, re.M)]
    written = 0
    for setname in order:
        g = games.get(setname)
        if not g:
            print('SKIP %s: no GAME() line' % setname)
            continue
        regions = parse_rom_start(src, setname)
        if not regions:
            print('SKIP %s: no ROM_START' % setname)
            continue

        prog = [r for r in regions if r['name'] == 'maincpu']
        gfx = [r for r in regions if r['name'] in ('sprites', 'gfxdata')]
        samp = [r for r in regions if r['name'].startswith('ensoniq')]

        body, offsets, aliases = [], [], []
        cursor = 0
        for label, group in (('program', prog), ('graphics', gfx),
                             ('samples', samp)):
            if not group:
                continue
            start = cursor
            body.append('    <!-- %s -->' % label)
            for region in group:
                for srcname in region.get('copies', []):
                    aliases.append('%s aliases %s' % (region['name'], srcname))
                if not region['loads']:
                    continue
                lines, size = emit_region(region)
                body.extend(lines)
                cursor += size
            offsets.append('%s 0x%07X-0x%07X' % (label, start, cursor - 1))

        default, dip_lines, dip_skipped = dips_to_mra(
            parse_dips(src, g['ports']))
        names, defaults = BUTTONS.get(setname, BUTTONS_DEFAULT)

        supported = setname in SUPPORTED
        about = ('Runs on the SSV core.' if supported else
                 'NOT YET SUPPORTED by the SSV core: rtl/mem/ssv_rom_loader.sv '
                 'takes a fixed Dyna Gear stream (1 MB program, graphics as '
                 'three 4 MB quarters, 4 MB samples) and this set does not '
                 'match it. The ROM description below is correct and will work '
                 'once the loader is generalised.')

        out = ['<misterromdescription>',
               '  <!-- Generated by tools/gen_ssv_mras.py from MAME ssv.cpp.',
               '       Stream offsets: %s' % '; '.join(offsets),
               ('       ES5506 bank aliases (ROM_COPY in MAME, address aliases '
                'rather than data, so not duplicated here): %s'
                % '; '.join(sorted(set(aliases)))) if aliases else None,
               ('       Switches MAME defines that an MRA cannot express, '
                'left out and still at their default: %s'
                % '; '.join(dip_skipped)) if dip_skipped else None,
               '       %s -->' % about,
               '  <name>%s</name>' % xml_escape(g['desc']),
               '  <setname>%s</setname>' % setname,
               '  <year>%s</year>' % g['year'],
               '  <manufacturer>%s</manufacturer>' % xml_escape(g['maker']),
               '  <rbf>SSV</rbf>']
        if g['rot'] != 'ROT0':
            out.append('  <!-- MAME rotation %s; the core does not rotate. -->'
                       % g['rot'])
        zipname = (g['parent'] if g['parent'] != '0' else setname)
        zips = setname + '.zip'
        if g['parent'] != '0':
            zips = '%s.zip|%s.zip' % (setname, zipname)
        # Per-game configuration block. MUST precede <rom index="0">: the
        # loader cannot place index-0 bytes without knowing the layout, and it
        # discards them until this block validates (rtl/mem/ssv_rom_loader.sv).
        cfg_bytes = None
        try:
            gfx_region = gfx[0]['size'] if gfx else 0
            gfx_loaded = sum(l['size'] for r in gfx for l in r['loads'])
            prog_size = prog[0]['size'] if prog else 0
            ens_valid, ens_map = ensoniq_banks(regions)
            flags = cfgblk.resolve_init(src, g['init'])
            amap = cfgblk.resolve_addrmap(src, g['machine'])
            flags['has_add_buttons'] = (
                cfgblk.has_add_buttons(src, amap) if amap else False)
            wdog = cfgblk.watchdog_mode(src, amap) if amap else 0
            cfg_bytes = cfgblk.build_cfg_bytes(
                SUPPORTED.index(setname) if setname in SUPPORTED else 15,
                prog_size, gfx_region, gfx_loaded,
                ens_valid, ens_map, flags, wdog)
        except Exception as exc:
            # A set whose geometry this core cannot describe gets no config
            # block, so the loader refuses it outright rather than running on
            # silently wrong numbers.
            print('  no config for %s: %s' % (setname, exc))
        if cfg_bytes:
            out.extend(cfgblk.cfg_rom_block(cfg_bytes))
        out.append('  <rom index="0" zip="%s">' % zips)
        out.extend(body)
        out.append('  </rom>')
        if dip_lines:
            out.append('  <switches default="%s" base="16">' % default)
            out.extend(dip_lines)
            out.append('  </switches>')
        out.append('  <buttons names="%s" default="%s" count="%d"/>'
                   % (names, defaults, len(names.split(','))))
        out.append('</misterromdescription>')
        out = [line for line in out if line is not None]

        # Windows rejects ? : * " < > | \ / in filenames, and MAME titles do
        # contain some of them: "Eagle Shot Golf (Japan, bootleg?)" and
        # "Ultra X Weapons / Ultra Keibitai". Slashes separate alternate titles,
        # so they become " - " rather than vanishing and welding words together.
        safe = g['desc'].replace('/', ' - ')
        safe = re.sub(r'[\\:*?"<>|]', '', safe)
        safe = re.sub(r'\s+', ' ', safe).strip()
        path = os.path.join(out_dir, '%s.mra' % safe)
        with open(path, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write('\n'.join(out) + '\n')
        print('%-10s -> %s' % (setname, os.path.basename(path)))
        written += 1
    print('%d MRA files written to %s' % (written, out_dir))


if __name__ == '__main__':
    main()
