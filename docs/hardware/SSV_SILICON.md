# SSV Silicon — standard parts and Seta customs

**Purpose:** primary-source documentation for the chips in the SSV system, to raise the
MiSTer core from emulator-derived behaviour to datasheet-derived behaviour.
**MAME is excluded as a source.** Claims traceable only to MAME are marked and not treated
as hardware fact.

Provenance legend as in `SSV_BOARD_HARDWARE.md`.

**Bottom line:** the two standard parts are well documented and obtainable. The Seta customs
are not documented anywhere public.

---

## 1. NEC V60 / uPD70616 — DOCUMENTATION EXISTS, OBTAINABLE

| Item | Provenance | Source |
|---|---|---|
| **NEC V60 CPU Manual / µPD70616 Programmer's Reference Manual**, Nov 1986 | `[PRIMARY]` | https://archive.org/details/NEC_V60pgmRef — plain text at https://archive.org/stream/NEC_V60pgmRef/NEC_V60pgmRef_djvu.txt |
| Mirror | `[PRIMARY]` | https://www.romhacking.net/documents/636/ |
| NEC 16-bit V Series databook, 5th ed. Jun 1997 (U11301EJ5V0UM00) | `[PRIMARY]` | https://archive.org/details/bitsavers_necdatabooBITVSeriesJun97_693718 — **instruction-set oriented**; archive metadata indexes mnemonics/operands, so do not assume it carries AC/bus timing until opened |

### Why this matters to our core

The V60 is currently behavioural, validated against traces rather than against NEC's own
specification. The Programmer's Reference is authoritative for:

- **The exception model for reserved / unimplemented opcodes.** Directly actionable: the
  opcode audit found the whole `0x58`–`0x5F` family unused by Dyna Gear, and whether it is
  safe to parameter-gate rests on what the CPU does on an unimplemented opcode. NEC's own
  wording settles it.
- Interrupt acknowledge and vector-fetch sequence — our `ssv_irq`/V60 interaction is inferred.
- Byte-lane and bus-width rules for the 16-bit external bus, which `s32_v60_bus` implements
  by inference.

**Update 2026-08-06 — timing evidence recovered.** See `V60_TIMING_EVIDENCE.md`:
Komoto/Saito/Mine (NEC), *Overview of 32-bit V-Series Microprocessor*, J. Info. Processing
13(2) 1990 `[PRIMARY]` (on file in `refs/`) gives the V60 bus cycle (**3 or 4 clocks/cycle,
16-bit bus**), the 6-unit/6-stage pipeline with max 4 concurrent instructions, 3.5 MIPS @
16 MHz, and a per-instruction clock table (V70 column; execution-bound entries transfer to
V60 — ADD reg,reg=2, MUL.W=23, DIV.W=43, branch 11/4, INT response 165, etc.).
The µPD70616 *full* datasheet with formal AC tables (T-state protocol, wait-state rules)
is still not located `[NEGATIVE]` — the 1987 Data Book Vol 2 (also in `refs/`) carries only
the same 3-page preliminary short-form as the DSAIH000102840 excerpt.

---

## 2. Ensoniq ES5506 "OTTO" — DOCUMENTATION EXISTS, ALREADY IN USE

| Item | Provenance | Source |
|---|---|---|
| **Ensoniq OTTO (ES5506) Technical Specification v2.3** | `[PRIMARY]` | https://zine.r-massive.com/ensoniq-technical-documents-and-schematics/ |
| ES5505 "OTIS" datasheet — OTTO's predecessor, useful cross-check | `[PRIMARY]` | same page |
| ES5510 "ESP" Technical Specification v2.4 | `[PRIMARY]` | same page |

**Already the project's primary source** — `docs/ES5506_RESEARCH.md` cites "Ensoniq OTTO Spec
Rev. 2.3". So the audio path is already datasheet-derived, not emulator-derived. This entry
records where to re-obtain it.

Independently confirmed specification facts `[PRIMARY]`:

- 32 independent voices
- **Up to 16 MHz operation** — weak support for our 16 MHz assumption
- 68000-compatible **asynchronous** host bus
- **Separate host and sound-memory interfaces** — architecturally significant, and matches
  our separate `sdr_p4` sample port
- At least 18-bit internal accuracy
- Hardware envelopes; per-voice loop start/stop with bidirectional and reverse looping
- Optional compressed sample format
- ~80,000 transistors, 1.5 µm double-metal CMOS

### Open items for accuracy

- Voice **slot scheduling** — exact clocks per voice, how 32 voices are sequenced.
- Sample-fetch bus protocol timing — needed to judge whether `sdr_p4` behaviour is right.
- Filter maths **as Ensoniq specifies it**, versus as commonly reimplemented.
- Host-interface wait states — our core inserts 2 wait cycles for MLAB read latency, a
  pragmatic choice rather than a spec-derived one.

---

## 3. Seta customs ST-0004 / ST-0005 / ST-0006 / ST-0007 — NO DOCUMENTATION FOUND

`[NEGATIVE]` on all of:

- Datasheets — none public
- Die shots / decaps — none found on siliconpr0n or elsewhere
- Seta patents on the sprite/tilemap engine — searched Google Patents, Seta assignee
  1990-1996, sprite/tilemap/scroll/zoom; nothing matching surfaced
- Reverse-engineering write-ups from hardware probing — none found

Note the ST-00xx numbering in common circulation traces to emulator sources rather than to any
photograph or document encountered in this pass. **Even the part numbers should be treated as
unconfirmed** until someone photographs a board.

### Consequence for the highest-value open question

The core implements SSV tilemaps such that **the horizontal scroll value's high bits select
which "page" (map) within sprite RAM is read** — each tilemap layer living in its own page.
This was derived empirically, and fixing it repaired a real corruption bug (confirmed against
MAME frame-by-frame: 15,000 differing pixels → 0).

**No primary source exists to confirm or refute the model.** It reproduces observed behaviour,
which is meaningful, but that is not the same as knowing the silicon works that way. It should
be documented as *empirically derived and behaviourally validated*, not *hardware-accurate*.

---

## 4. Video DAC and memory types

Not established `[NEGATIVE]`. Needs board photographs.
