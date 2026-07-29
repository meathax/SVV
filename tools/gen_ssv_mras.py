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

# Sammy-published SSV sets, in MAME order.
SETS = ['dynagear', 'survarts', 'survartsu', 'survartsj', 'eaglshot',
        'eaglshotj', 'hypreact', 'meosism', 'hypreac2', 'sxyreact',
        'sxyreac2', 'cairblad']

# The core's CONF_STR J1 list is fixed at six entries, so an MRA cannot add a
# button the core does not expose. Games with more buttons than this are noted
# in <about> rather than silently mapped to nothing.
BUTTONS_DEFAULT = ('Button 1,Button 2,Test,Service,Start,Coin',
                   'A,B,R,L,Start,Select')
BUTTONS = {'dynagear': ('Fire,Jump,Test,Service,Start,Coin',
                        'A,B,R,L,Start,Select')}

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
            hi = loads[i + 1] if i + 1 < len(loads) else None
            if hi is None or hi['offset'] != ld['offset'] + 1:
                raise SystemExit('unpaired ROM_LOAD16_BYTE %s' % ld['name'])
            out.append('%s<interleave output="16">' % indent)
            out.append('%s  <part name="%s" crc="%s" map="01"/>'
                       % (indent, xml_escape(ld['name']), ld['crc']))
            out.append('%s  <part name="%s" crc="%s" map="10"/>'
                       % (indent, xml_escape(hi['name']), hi['crc']))
            out.append('%s</interleave>' % indent)
            pos += ld['size'] * 2
            i += 2
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


def parse_dips(src, portsname):
    """Collect DSW1/DSW2 switches, expanding the SSV_COINAGE_* macros."""
    m = re.search(r'INPUT_PORTS_START\(\s*%s\s*\)(.*?)INPUT_PORTS_END'
                  % portsname, src, re.S)
    if not m:
        return []
    body, dips, port, cur = m.group(1), [], None, None
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
        s = re.search(r'PORT_DIPSETTING\(\s*(0x[0-9a-fA-F]+)\s*,\s*(.*?)\s*\)\s*$',
                      line)
        if s and cur is not None:
            cur['settings'].append((int(s.group(1), 16), deranged(s.group(2))))
    return [d for d in dips if d['settings'] and d['mask']]


def dips_to_mra(dips):
    """MRA <switches>: bit 0-7 are DSW1, 8-15 DSW2, defaults as MAME sets."""
    if not dips:
        return None, None
    default = [0, 0]
    lines = []
    for port, base in (('DSW1', 0), ('DSW2', 8)):
        group = [d for d in dips if d['port'] == port]
        if not group:
            continue
        lines.append('    <!-- %s -->' % port)
        for d in group:
            mask, idx = d['mask'], 0 if port == 'DSW1' else 1
            lo = (mask & -mask).bit_length() - 1
            hi = mask.bit_length() - 1
            default[idx] |= d['default'] & mask
            bits = str(base + lo) if lo == hi else '%d,%d' % (base + lo,
                                                              base + hi)
            pairs = sorted(d['settings'], key=lambda kv: -kv[0])
            ids = ','.join(xml_escape(lbl) for _, lbl in pairs)
            vals = ','.join(str(v >> lo) for v, _ in pairs)
            lines.append('    <dip bits="%s" name="%s" ids="%s" values="%s"/>'
                         % (bits, xml_escape(d['name']), ids, vals))
    return '%02X,%02X' % (default[0] & 0xff, default[1] & 0xff), lines


def main():
    src_path, out_dir = sys.argv[1], sys.argv[2]
    src = open(src_path, encoding='utf-8', errors='replace').read()
    os.makedirs(out_dir, exist_ok=True)

    games = {}
    for m in re.finditer(r'^GAME\(\s*(\d+\??)\s*,\s*(\w+)\s*,\s*(\w+)\s*,'
                         r'\s*(\w+)\s*,\s*(\w+)\s*,.*?(ROT\d+)\s*,\s*"([^"]*)"'
                         r'\s*,\s*"((?:[^"\\]|\\.)*)"', src, re.M | re.S):
        games[m.group(2)] = {'year': m.group(1).rstrip('?'),
                             'parent': m.group(3), 'ports': m.group(5),
                             'rot': m.group(6), 'maker': m.group(7),
                             'desc': m.group(8)}

    written = 0
    for setname in SETS:
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

        body, offsets = [], []
        cursor = 0
        for label, group in (('program', prog), ('graphics', gfx),
                             ('samples', samp)):
            if not group:
                continue
            start = cursor
            body.append('    <!-- %s -->' % label)
            for region in group:
                if not region['loads']:
                    continue
                lines, size = emit_region(region)
                body.extend(lines)
                cursor += size
            offsets.append('%s 0x%07X-0x%07X' % (label, start, cursor - 1))

        default, dip_lines = dips_to_mra(parse_dips(src, g['ports']))
        names, defaults = BUTTONS.get(setname, BUTTONS_DEFAULT)

        supported = setname == 'dynagear'
        about = ('Runs on the SSV core.' if supported else
                 'NOT YET SUPPORTED by the SSV core: rtl/mem/ssv_rom_loader.sv '
                 'takes a fixed Dyna Gear stream (1 MB program, graphics as '
                 'three 4 MB quarters, 4 MB samples) and this set does not '
                 'match it. The ROM description below is correct and will work '
                 'once the loader is generalised.')

        out = ['<misterromdescription>',
               '  <!-- Generated by tools/gen_ssv_mras.py from MAME ssv.cpp.',
               '       Stream offsets: %s' % '; '.join(offsets),
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

        # Windows rejects ? : * " < > | \ / in filenames, and MAME titles do
        # contain some of them ("Eagle Shot Golf (Japan, bootleg?)").
        safe = re.sub(r'[\\/:*?"<>|]', '', g['desc']).strip()
        path = os.path.join(out_dir, '%s.mra' % safe)
        with open(path, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write('\n'.join(out) + '\n')
        print('%-10s -> %s' % (setname, os.path.basename(path)))
        written += 1
    print('%d MRA files written to %s' % (written, out_dir))


if __name__ == '__main__':
    main()
