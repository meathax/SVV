"""hiscore.dat configuration blocks for the SSV MRAs.

The core carries rtl/hiscore.v (alanswx / JimmyStones).  It reads its
configuration from ioctl index 3 and saves/restores the extracted table on
index 4, so every game whose score table lives in RAM the core can reach gets
persistent high scores even though its PCB has no battery.

Entries below are transcribed from the MAME hiscore plugin's hiscore.dat
(MAME 0.288, bin/plugins/hiscore/hiscore.dat), which encodes each line as

    @:maincpu,program,<address>,<length>,<start value>,<end value>

Addresses are V60 program-space byte addresses.  The core reaches
$000000-$00ffff (main RAM, block RAM) and, on a descriptor with
extra_ram_mode 2, $010000-$03ffff (the "More RAM" window twineag2 and ultrax
have, kept in SDRAM).  Anything outside that is not emitted.

Sets whose score table is battery-backed on the real PCB are deliberately
absent: cairblad's hiscore.dat entry is the NVRAM window itself ($580030) and
drifto94 has no entry at all.  Both persist through the index-8 board NVRAM
stream, which is what the hardware does.  stmblade keeps its table in main RAM
even though it also has NVRAM, so it gets both, and the two streams touch
disjoint memory.
"""

# setname -> [(address, length, start value, end value), ...]
HISCORE_ENTRIES = {
    'dynagear': [(0x0000af, 0x2c, 0x80, 0x50),
                 (0x0000fd, 0x01, 0x04, 0x04)],
    'stmblade': [(0x0028d3, 0x80, 0x15, 0x00)],
    'twineag2': [(0x00e208, 0x03, 0x40, 0x0f),
                 (0x015572, 0x2f, 0x40, 0x0a)],
    'ultrax':   [(0x01ac8e, 0x28, 0x40, 0x04),
                 (0x00e23c, 0x03, 0x40, 0x0f)],
    'vasara':   [(0x002a32, 0xc5, 0x01, 0x1e)],
    'vasara2':  [(0x005302, 0xeb, 0x01, 0x0a)],
}

# Highest CPU byte address the core's hiscore port can reach.  Main RAM is
# $0000-$ffff for every set; the extra window only exists on extra_ram_mode 2.
MAIN_RAM_LAST = 0x00ffff
EXTRA_RAM_LAST = 0x03ffff

# Header defaults (rtl/hiscore.v, "Parameters read from config header").  The
# stock MiSTer values assume single-cycle game RAM; twineag2 and ultrax read
# theirs out of SDRAM through rtl/mem/ssv_hs_extram.sv, so the hold windows are
# widened to cover a burst read and a byte write.  Units are clk_sys cycles.
START_WAIT = 0                # the check loop below already retries forever
CHECK_WAIT = 0xffff           # ~0.8 ms between start/end check attempts
CHECK_HOLD = 0x0040           # 64 cycles to answer a check read
WRITE_HOLD = 0x0100           # 256 cycles to retire a restore write
WRITE_REPEATCOUNT = 0x0001
WRITE_REPEATWAIT = 0x000f
ACCESS_PAUSEPAD = 0x04
CHANGEMASK = 0x00             # no mask: compare the whole dump


def _reachable(setname, entries, extra_ram_mode):
    last = EXTRA_RAM_LAST if extra_ram_mode == 2 else MAIN_RAM_LAST
    for addr, length, _start, _end in entries:
        if addr < 0 or (addr + length - 1) > last:
            raise ValueError(
                "%s hiscore entry $%06x+%d is outside the reachable "
                "window (max $%06x)" % (setname, addr, length, last))


def config_bytes(setname, extra_ram_mode):
    """Return the ioctl index-3 blob for a set, or None if it has no entry."""
    entries = HISCORE_ENTRIES.get(setname)
    if not entries:
        return None
    _reachable(setname, entries, extra_ram_mode)

    blob = bytearray()
    blob += START_WAIT.to_bytes(4, 'big')
    blob += CHECK_WAIT.to_bytes(2, 'big')
    blob += CHECK_HOLD.to_bytes(2, 'big')
    blob += WRITE_HOLD.to_bytes(2, 'big')
    blob += WRITE_REPEATCOUNT.to_bytes(2, 'big')
    blob += WRITE_REPEATWAIT.to_bytes(2, 'big')
    blob.append(ACCESS_PAUSEPAD)
    blob.append(CHANGEMASK)
    assert len(blob) == 16, "header must stay at HS_HEADERLENGTH bytes"

    # Eight bytes per entry.  hiscore.v latches the address from offsets 1-3,
    # the length from 4, the start value from 5 and the end value from 6;
    # offsets 0 and 7 are padding it never reads.
    for addr, length, start, end in entries:
        if length < 1 or length > 0x100:
            raise ValueError("%s entry length %d out of range" %
                             (setname, length))
        blob += bytes([0x00,
                       (addr >> 16) & 0xff, (addr >> 8) & 0xff, addr & 0xff,
                       length & 0xff, start, end, 0x00])
    return bytes(blob)


def dump_bytes(setname):
    """Size of the index-4 save file: the concatenated table contents."""
    entries = HISCORE_ENTRIES.get(setname)
    if not entries:
        return 0
    return sum(length for _addr, length, _s, _e in entries)


def rom_block(blob):
    """MRA lines carrying the config blob on ioctl index 3."""
    return ['  <rom index="3">',
            '    <part>%s</part>' % ''.join('%02X' % b for b in blob),
            '  </rom>']
