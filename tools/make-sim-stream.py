#!/usr/bin/env python3
"""Build per-game simulation ROM images for any SSV set, from MAME + a ROM zip.

Replaces tools/make-dynagear-images-fast.ps1, which hardcodes Dyna Gear's MAME
entry names and so cannot serve any other title. Every fact here is DERIVED from
MAME's ssv.cpp via tools/gen_ssv_mras.py's parser -- the same authority the MRA
generator uses -- so the sim images and the MRA cannot describe different ROMs.

WHY THIS READS MAME AND NOT THE MRA
-----------------------------------
The obvious design is to parse the .mra and honour its <interleave>/map=
attributes, since that is what the HPS feeds the core on hardware. It was
deliberately not done, because the semantics of `map` could not be established:

  * mra-tools-c's parse_pattern() treats the digits as 0-BASED input byte
    offsets and rejects any digit >= the pattern length, so it would reject the
    map="21" that MAME's ROM_LOAD16_WORD_SWAP regions carry, and its width check
    rejects a two-part interleave whose parts each have a 2-character pattern.
    That code therefore does not implement this attribute.
  * The MiSTer documentation says map="21" byteswaps, which requires 1-BASED
    digits with 0 meaning "skip" -- a different convention.
  * Under the 1-based reading, map="01"/"10" place the ROM_LOAD16_BYTE lanes the
    opposite way round from the byte order this core's RTL demonstrably needs.

Rather than guess a convention and risk manufacturing a fake bug, this tool
reconstructs each MAME ROM_REGION image directly from ROM_START -- offsets,
sizes and load kinds -- which is unambiguous. The MRA's map strings remain
UNVERIFIED for hardware; whether the HPS produces these same bytes is a real
open question that only a hardware boot answers. See docs/issues/.

Usage:
  python tools/make-sim-stream.py <ssv.cpp> <setname> <romdir> <outdir>

Writes, into <outdir>:
  maincpu.bin   V60 program, MAME "maincpu" region image
  sprites.bin   graphics, MAME "sprites"/"gfxdata" region image
  samples.bin   ES5506 samples, all "ensoniq.*" regions concatenated
  st010.bin     uPD96050 image, when the set has one
  cfg.bin       the 16-byte per-game config block (MRA <rom index="1">)
  stream.bin    program + graphics + samples + st010, i.e. the MRA index-0
                stream, for a bench that drives ssv_rom_loader
"""

import importlib.util
import os
import sys
import zipfile
import zlib


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


HERE = os.path.dirname(os.path.abspath(__file__))
gen = _load('gen_ssv_mras', os.path.join(HERE, 'gen_ssv_mras.py'))
cfgblk = _load('ssv_cfg_block', os.path.join(HERE, 'ssv_cfg_block.py'))


class RomSource:
    """The set's zip plus its parent's, searched in that order."""

    def __init__(self, romdir, setname, parent):
        self.zips = []
        for cand in ([setname] + ([parent] if parent and parent != '0' else [])):
            p = os.path.join(romdir, cand + '.zip')
            if os.path.exists(p):
                self.zips.append(zipfile.ZipFile(p))
        if not self.zips:
            raise SystemExit('no zip for %s in %s' % (setname, romdir))

    def read(self, name, want_crc):
        for z in self.zips:
            try:
                data = z.read(name)
            except KeyError:
                continue
            got = '%08x' % (zlib.crc32(data) & 0xFFFFFFFF)
            if want_crc and got != want_crc:
                raise SystemExit('CRC mismatch for %s: zip %s, MAME %s'
                                 % (name, got, want_crc))
            return data
        raise SystemExit('%s not found in %s'
                         % (name, [os.path.basename(z.filename)
                                   for z in self.zips]))


def build_region(region, src):
    """Reconstruct one MAME ROM_REGION image.

    Placement follows the load KIND, which is what makes this unambiguous:

      ROM_LOAD16_BYTE       one lane of a 16-bit region: byte i of the file goes
                            to region offset + 2*i, so a pair of loads at
                            offsets 0 and 1 interleaves into whole words.
      ROM_LOAD16_WORD_SWAP  the file is a 16-bit image with the two bytes of
                            every word the other way round, so swap each pair.
      anything else         placed linearly.

    Gaps stay zero, which is what MAME's ERASE00 default and the MRA's
    <part repeat="0x..">00</part> padding both mean.
    """
    image = bytearray()
    extent = 0

    def put(index, value):
        if index >= len(image):
            image.extend(b'\x00' * (index + 1 - len(image)))
        image[index] = value

    def cover(end):
        # Region extent is tracked from each load's DECLARED span, not from the
        # highest byte actually stored. An unpaired ROM_LOAD16_BYTE fills only
        # one lane, so its last stored byte sits one short of the final 16-bit
        # word and a high-water mark would end the region mid-word -- which is
        # how the sample images first came out 0x7FFFFE and 0x3FFFFF long. The
        # lane this load does not supply is legitimately zero (gen_ssv_mras.py
        # emits a single-part interleave for exactly this case).
        nonlocal extent
        if end > extent:
            extent = end

    for ld in sorted(region['loads'], key=lambda x: (x['offset'], x['size'])):
        data = src.read(ld['name'], ld.get('crc'))
        if len(data) != ld['size']:
            # A ROM_RELOAD may re-place only part of the preceding file.
            if ld.get('reload') and len(data) >= ld['size']:
                data = data[:ld['size']]
            else:
                raise SystemExit('%s is %d bytes, MAME declares %d'
                                 % (ld['name'], len(data), ld['size']))
        base = ld['offset']
        kind = ld['kind']
        if kind == 'ROM_LOAD16_BYTE':
            for i, b in enumerate(data):
                put(base + 2 * i, b)
            # Both lanes of every word this load touches belong to the region.
            cover(base - (base % 2) + 2 * len(data))
        elif kind == 'ROM_LOAD16_WORD_SWAP':
            for i in range(0, len(data) - 1, 2):
                put(base + i, data[i + 1])
                put(base + i + 1, data[i])
            if len(data) % 2:
                put(base + len(data) - 1, data[-1])
            cover(base + len(data))
        else:
            for i, b in enumerate(data):
                put(base + i, b)
            cover(base + len(data))

    if len(image) < extent:
        image.extend(b'\x00' * (extent - len(image)))
    return bytes(image[:extent])


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    src_path, setname, romdir, outdir = sys.argv[1:5]
    text = open(src_path, encoding='utf-8', errors='replace').read()

    game = None
    for m in gen.re.finditer(
            r'^GAME\(\s*(\d+\??)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,'
            r'\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,', text, gen.re.M):
        if m.group(2) == setname:
            game = {'parent': m.group(3), 'machine': m.group(4),
                    'init': m.group(7)}
            break
    if not game:
        raise SystemExit('no GAME() line for %s' % setname)

    regions = gen.parse_rom_start(text, setname)
    if not regions:
        raise SystemExit('no ROM_START for %s' % setname)

    src = RomSource(romdir, setname, game['parent'])
    os.makedirs(outdir, exist_ok=True)

    def region_group(names):
        return [r for r in regions if r['name'] in names]

    prog = region_group(('maincpu',))
    gfx = [r for r in regions if r['name'] in ('sprites', 'gfxdata')]
    samp = [r for r in regions if r['name'].startswith('ensoniq')]
    st010 = [r for r in regions if r['name'] == 'st010']

    written = {}

    def emit(fname, blob):
        with open(os.path.join(outdir, fname), 'wb') as fh:
            fh.write(blob)
        written[fname] = len(blob)

    prog_img = build_region(prog[0], src) if prog else b''
    gfx_img = b''.join(build_region(r, src) for r in gfx)
    samp_img = b''.join(build_region(r, src) for r in samp if r['loads'])
    st010_img = build_region(st010[0], src) if st010 and st010[0]['loads'] else b''

    emit('maincpu.bin', prog_img)
    emit('sprites.bin', gfx_img)
    emit('samples.bin', samp_img)
    if st010_img:
        emit('st010.bin', st010_img)

    # 16-byte config block, byte-identical to what gen_ssv_mras.py puts in the
    # MRA -- same inputs, same function.
    gfx_region = gfx[0]['size'] if gfx else 0
    gfx_loaded = sum(l['size'] for r in gfx for l in r['loads'])
    ens_valid, ens_map = gen.ensoniq_banks(regions)
    flags = cfgblk.resolve_init(text, game['init'])
    flags.update(gen.DESCRIPTOR_FEATURE_OVERRIDES.get(setname, {}))
    amap = cfgblk.resolve_addrmap(text, game['machine'])
    flags['has_add_buttons'] = cfgblk.has_add_buttons(text, amap) if amap else False
    flags['has_st010'] = cfgblk.has_st010(regions)
    wdog = cfgblk.watchdog_mode(text, amap) if amap else 0
    samples_size = sum(cfgblk.region_extent(r) for r in samp if r['loads'])
    if samples_size != len(samp_img):
        raise SystemExit('samples_mb helper says %d bytes, image is %d -- the '
                         'config block and the image would disagree'
                         % (samples_size, len(samp_img)))
    cfg_bytes = cfgblk.build_cfg_bytes(
        gen.SUPPORTED.index(setname) if setname in gen.SUPPORTED else 15,
        prog[0]['size'] if prog else 0, gfx_region, gfx_loaded,
        ens_valid, ens_map, flags, wdog, samples_size)
    emit('cfg.bin', bytes(cfg_bytes))

    emit('stream.bin', prog_img + gfx_img + samp_img + st010_img)

    print('set %s -> %s' % (setname, outdir))
    for k in ('maincpu.bin', 'sprites.bin', 'samples.bin', 'st010.bin',
              'cfg.bin', 'stream.bin'):
        if k in written:
            print('  %-12s %10d bytes (0x%X)' % (k, written[k], written[k]))
    print('  cfg block   %s' % ''.join('%02X' % b for b in cfg_bytes))


if __name__ == '__main__':
    main()
