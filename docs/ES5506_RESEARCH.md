# ES5506 / SSV audio research

This document records the sources and measurements used to implement the
Ensoniq ES5506 (OTTO) in the SSV MiSTer core.  Generated downloads and game
ROMs remain outside version control.

## Sources

### Primary specification

- Ensoniq, *OTTO Specification Rev. 2.3* (ES5506), 51-page scanned manual:
  <https://gjcp.net/pdf/es5506.pdf>
  - Local research copy: `scratch/upstream/es5506/es5506.pdf`
  - SHA-256:
    `406D32C937227ABA9069BAB39482007DD434F72E2389085A3B32003F16A8127F`
  - OCR text used for implementation review:
    `scratch/upstream/es5506/es5506_ocr.txt`
- Ensoniq ES5505 manual: <https://gjcp.net/pdf/es5505.pdf>
  - SHA-256:
    `8B28A8109238DE9D84B89B590B4EF975D0D7668EFC01BFF532B45511F602B6C0`
- Ensoniq ES5510 manual: <https://gjcp.net/pdf/es5510.pdf>
  - SHA-256:
    `FF7B74EF97E7C56A9D5FC7D2CC92D7B6EF0222A1D483734BD5676008B5C7A9F3`

The scanned manuals are research references and are not redistributed in this
repository.

### Open-source behavioral references

- MAME ES5505/ES5506 device:
  <https://github.com/mamedev/mame/blob/master/src/devices/sound/es5506.cpp>
  - Local source:
    `D:/Arcade/AI/MAMESOURCE/mame/src/devices/sound/es5506.cpp`
  - Per-file license: BSD-3-Clause.
  - Used to cross-check host-register masking, IRQ acknowledgement, looping,
    sample addressing, volume, filter state, and reset behavior.
- vgsound_emu ES550x implementation, as pinned by Furnace:
  <https://github.com/tildearrow/furnace/tree/master/extern/vgsound_emu-modified/vgsound_emu/src/es550x>
  - Furnace commit:
    `2325f63ca625451a6944a303338714bca8f9aa41`
  - License: zlib.
  - Used as a second implementation check, particularly the manual's
    nine-bit interpolation equation.
- FinalBurn Neo:
  <https://github.com/finalburnneo/FBNeo>
  - Inspected commit:
    `ea47777f10c25af4ca1d543c314141b0a49a5568`
  - Useful only as an independent behavioral comparison.  Its non-commercial
    license is incompatible with reuse here; no FBNeo source is copied.
- libvgm:
  <https://github.com/ValleyBell/libvgm>
  - Inspected commit:
    `867223e7c33d63de115d1ab955f784c44f19040a`
  - Its current `emu/cores/es5506.c` is a stub, not an implementation.
- MiSTer Apple IIgs:
  <https://github.com/MiSTer-devel/Apple-IIgs_MiSTer>
  - Inspected commit:
    `9adbba8622f378253765b7d438b6cbcc4d03fc57`
  - Contains an earlier ES5503 HDL implementation.  It is useful for general
    Ensoniq/MiSTer integration patterns but is not register- or
    datapath-compatible with the ES5506.
- JTSFTM partial ES5506 RTL:
  <https://github.com/visions85/sftm/blob/main/cores/sftm/hdl/sftm5506.v>
  - Repository license: GPLv3 for its authored RTL.
  - MiSTer/JTFRAME-targeted voice datapath with sample-ROM handshake,
    accumulator/loop logic, filter arithmetic, volume mixing, envelopes, and
    IRQ stacking.
  - It is an unvalidated early scaffold restricted to four voices.  Its host
    protocol/register map, scheduler, interpolation, widths, filter modes,
    and saturation must not be adopted without correction against the OTTO
    manual, MAME, and the Dyna Gear trace.
  - Reuse selectively with attribution; retain this project's existing
    32-voice, four-byte-latched host/register frontend.

No completed, validated, drop-in ES5506 HDL core has been identified.
JTSFTM is the strongest FPGA-specific starting point, but it is partial.
The primary manual remains authoritative, with MAME and vgsound used as

## Confirmed chip behavior

- 32 voices, with each enabled voice consuming 16 master clocks.
- Output sample rate is `master_clock / (16 * (ACTV + 1))`.  Reset ACTV is
  31, so a 16 MHz clock produces 31.25 kHz.
- Four sample banks are selected by CR bits BS1:BS0.  Each bank is up to
  2 Mwords of 16-bit sample data.
- The 21-bit integer accumulator address selects sample S1; the next word is
  S2.  The interpolator uses nine fractional bits:
  `S1 + fraction * (S2 - S1) / 512`.
- Four one-pole filters operate at 18-bit precision.  Poles 1 and 2 are
  always low-pass using K1.  Poles 3 and 4 use K2 and are individually
  selectable as low-pass or high-pass.
- The host sees 32-bit registers through four 8-bit accesses.  Bytes 0-2
  only update the write latch; byte 3 commits the register and clears the
  latch.  Reading byte 0 snapshots a whole register into the read latch;
  bytes 1-3 return the remaining snapshot bytes.
- Voice state is selected by PAGE.  Pages `00-1f` expose low registers,
  pages `20-3f` expose high registers, and pages `40-7f` expose test
  registers.
- IRQV resets to `0x80`.  Reading IRQV acknowledges the presented voice
  interrupt and returns the vector to the inactive value.

The ES5506 manual specifies nine interpolation fraction bits.  MAME's older
ES5506 path retains eleven accumulator fraction bits in its interpolation
formula, while current vgsound uses the manual's bits 10:2.  RTL follows the
manual and vgsound: the two least-significant accumulator fraction bits are
retained for phase accumulation but discarded for interpolation.

## Dyna Gear measurements

The official MAME 0.288 binary was run for ten emulated seconds with
`tools/mame-capture-es5506.lua`.  The ROM set passed MAME's `-verifyroms`
check.  The ignored raw trace is:

`scratch/upstream/es5506/dynagear_mame_es5506_10s.log`

It contains 3,516 byte writes, eight byte reads, and 879 completed 32-bit
register writes.  `tools/decode-mame-es5506.py` reconstructs and names the
transactions.

Observed initialization:

- MODE is written `0x0b`, then `0x08`.
- W_ST=`0x30`, W_END=`0x40`, LR_END=`0x40`.
- ACTV=`0x1f` (32 voices).
- All 64 low/high voice pages are initialized.
- The game polls IRQV; the observed inactive value is `0x00000080`.

The first audible demo activity uses voices 16-18.  These voices use:

- CR=`0x8000`: sample bank 2, uncompressed 16-bit PCM, forward direction,
  no loop, no voice IRQ, channel 0, and filter mode 0.
- Voice 16: START/ACCUM=`0x38943000`, END=`0x3bb6f000`,
  FC=`0x0800`, LVOL/RVOL=`0xf550`, K1=`0xff80`, K2=`0xf030`.
- Voices 17 and 18: START/ACCUM=`0x03836000`, END=`0x05a1c000`,
  LVOL/RVOL=`0xfd10`, K1=`0xff80`, K2=`0xf030`, with FC swept by the
  game.

Dyna Gear's sample ROM is loaded into ES5506 bank 2.  Its traced voices do
not require compressed samples, reverse/bidirectional loops, alternate
output channels, or high-pass modes during the captured interval.  Those
features remain part of the full-core target, but linear PCM bank-2 playback
is the shortest path to the first authentic sound.

## Implementation order

1. Exact 8-bit host protocol and complete readable/writable register file.
2. Time-multiplexed voice scheduler and SDRAM sample fetches.
3. Linear PCM interpolation, accumulator boundary handling, and channel
   accumulation.
4. Four-pole filter, exponential volume, saturation, and stereo output.
5. Hardware envelopes, loop modes, IRQ stacking, and compressed samples.
6. MAME trace-vector comparison, Verilator/GTKWave checks, Quartus fit and
   timing, then MiSTer hardware testing.

Implementation code is original GPL-3.0-or-later RTL.  MAME BSD-3-Clause and
vgsound zlib sources are behavioral references and are attributed here; no
incompatible source is incorporated.
