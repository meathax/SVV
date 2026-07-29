# Phase 9 — ST010 (NEC uPD96050): interface specification

**Status: specification only. No RTL written.**

This is the bounded first deliverable the plan asks for. It pins down the
interface precisely, so the implementation (or the decision not to implement)
rests on facts rather than on a re-reading of MAME later.

All references are `D:\Arcade\AI\MAMESOURCE\mame\src\mame\seta\ssv.cpp`.

## Which titles need it

Three of the nine targets, all in the derived `drifto94_state` class (which is
why the earlier config parsers, hardcoded to `ssv_state::`, silently reported
"no watchdog" for them):

| set | machine config | `UPD96050` |
|---|---|---|
| Drift Out '94 | `drifto94` | `ssv.cpp:2468` |
| Storm Blade | `stmblade` | `ssv.cpp:2642` |
| Twin Eagle II | `twineag2` | `ssv.cpp:2755` |

Instantiated as `UPD96050(config, m_dsp, 10000000);` — 10 MHz, and MAME's own
comment is `// TODO: correct?`, so the clock is **not** authoritative.

## CPU-side interface — two windows only

From `drifto94_map` (`ssv.cpp:410-411`) and `twineag2_map` (`:769-770`):

```
map(0x480000, 0x480000).rw(m_dsp, upd96050_device::data_r, data_w);
map(0x482000, 0x482fff).rw(drifto94_state::dsp_r, dsp_w).umask16(0x00ff);
```

**`$480000` — the DSP data port.** A single byte-wide register pair; the host
reads/writes the uPD96050's `data_r`/`data_w`, which is the DSP's SR/DR
handshake port.

**`$482000-$482fff` — the DSP data RAM window**, 4 KB of CPU address space
mapped `umask16(0x00ff)`, i.e. **byte lanes only, 2048 usable bytes**. The
translation (`ssv.cpp:350-362`) is exact and worth reproducing verbatim,
because the halving is easy to get wrong:

```c
uint8_t dsp_r(offs_t offset) {
    uint16_t temp  = m_dsp->dataram_r(offset / 2);
    uint8_t  shift = BIT(offset, 0) << 3;
    return (temp >> shift) & 0xff;
}
void dsp_w(offs_t offset, uint8_t data) {
    uint8_t shift = BIT(offset, 0) << 3;
    m_dsp->dataram_w(offset / 2, (uint16_t(data) << 8) | data,
                     uint16_t(0xff) << shift);
}
```

So CPU byte offset *n* addresses DSP data-RAM **word** `n/2`, selecting the
high byte when `n` is odd and the low byte when even. The write duplicates the
byte into both halves and relies on the mask — a detail that matters if the RTL
implements `dataram_w` with a plain byte enable.

`ssv.cpp:157` notes `0x482000 - 0x482007 - values taken from obj table`, i.e.
the game stages sprite-table values through the DSP's RAM.

## ROM layout

```
ROM_REGION  (0x11000, "st010")   st010.bin, CRC(aa11ee2d)
ROM_REGION32_BE(0x10000, "dspprg")  ROM_COPY "st010" 0x00000 -> 0x10000 bytes
ROM_REGION16_BE(0x01000, "dspdata") ROM_COPY "st010" 0x10000 -> 0x01000 bytes
```

One 69,632-byte image split into a **64 KB 32-bit-BE program** and a **4 KB
16-bit-BE data** region. Both are `ROM_COPY` from the single `st010.bin`, so
the MRA needs one part and the loader does the split — the same aliasing
pattern already handled for the ES5506 banks.

DSP-side maps (`ssv.cpp:341-348`) confirm the addressing:

```
dsp_prg_map   map(0x0000, 0x3fff).rom().region("dspprg", 0)    16K words x 24/32-bit
dsp_data_map  map(0x0000, 0x07ff).rom().region("dspdata", 0)    2K words x 16-bit
```

Note `dspdata` is 4 KB of bytes = **2048 16-bit words**, matching the 2048
usable bytes of the `$482000` window exactly.

## SDRAM cost

Program 64 KB + data 4 KB = **68 KB**, trivial against the 28 MB free in the
current bank map. It does **not** motivate any layout change.

## Implementation cost — and why this is its own project

The uPD96050 is a Harvard-architecture 16-bit DSP with a 24-bit instruction
word, hardware multiplier, accumulator pair, ring-buffer data pointers and a
stack. Estimated ~2000 ALM and 4-8 M10K (program ROM 16K x 24 bits is ~5 M10K
on its own, before the 2K x 16 data ROM and the register file).

M10K is the binding resource at **510/553**, so this cannot simply be added:
either the program ROM goes to SDRAM behind a cache, or something else moves.
That trade has not been designed.

## Recommended first step — measure, do not build

The plan's own guidance, and it still stands: **run Storm Blade and Twin Eagle
II with the DSP absent and find the first divergence** using the method in
`docs/CORE_ISSUE_DIFFTEST_METHOD.md`.

- The DSP is a *maths coprocessor*. Drift Out '94 is a driving game whose ST010
  does the perspective transform, so it will diverge immediately and visibly.
- Storm Blade and Twin Eagle II are shooters. It is entirely possible the DSP is
  used for a subset of effects and that both are substantially playable with a
  stub that returns plausible values, which would move two of the three titles
  out of Phase 9 entirely.

Deciding that costs one boot-and-diff per title. Writing the DSP first costs a
CPU core. **Do the measurement first.**

## Blocked on

Neither title can be booted yet: the loader has no `st010` stream region and
the config record has no `has_st010` consumer. Both are small, but they are
Phase 8 work, not Phase 9 — so the measurement above is gated on finishing the
per-game loader, not on any DSP work.
