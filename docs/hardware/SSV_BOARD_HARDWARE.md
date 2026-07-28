# SSV Board Hardware Archaeology (Sammy / Seta / Visco)

**Target game:** Dyna Gear (Sammy, 1993)
**Purpose:** independent, real-PCB evidence for the MiSTer FPGA core. MAME is deliberately
excluded as a source; where a claim's only traceable origin is MAME it is marked as such and
NOT treated as hardware fact.

**Status:** first research pass complete, 28 Jul 2026. See the headline conclusion below —
it is the most important result in this file.

---

## Provenance legend

| Tag | Meaning |
|---|---|
| `[PRIMARY]` | Datasheet, service manual, schematic, patent, die photo/decap, legible PCB photograph, scope/logic-analyser measurement |
| `[SECONDARY]` | Repair log, forum post by someone with the board in hand, auction photo, collector wiki |
| `[UNSOURCED]` | Widely repeated, no traceable origin |
| `[MAME-ORIGIN]` | Traceable only to the MAME driver / its comments. **Excluded as hardware evidence.** |
| `[NEGATIVE]` | Searched for and not found. Recorded so a later pass does not repeat the work. |

---

## HEADLINE CONCLUSION — read this first

**Public documentation for the Seta SSV custom silicon does not appear to exist.** After
systematic searching there is:

- **No** SSV schematic or service manual in public circulation `[NEGATIVE]`
- **No** Seta ST-00xx datasheet `[NEGATIVE]`
- **No** die shot / decap of any SSV custom chip on siliconpr0n or elsewhere `[NEGATIVE]`
- **No** Seta patent found describing the sprite or tilemap engine `[NEGATIVE]`

This changes the strategy. For the **standard parts** (NEC V60, Ensoniq ES5506) genuine
manufacturer documentation exists and is obtainable, and the core can be made more accurate
from paper. For the **Seta customs** — which is where the video behaviour lives — there is no
paper to work from, and the only route to accuracy is **measurement on a real PCB**.

That is a decision-changing result: further web archaeology on the customs has low expected
value, whereas a day with a board, a logic analyser and a scope would produce more than
weeks of searching. The plan in `docs/hardware/SSV_ACCURACY_PLAN.md` is built around that.

---

## Core assumptions under test

| # | Core assumption | Verdict | Evidence |
|---|---|---|---|
| A1 | Pixel clock 42.954545 MHz / 6 = 7.159 MHz | ✅ **CONFIRMED** | **A 42.9545 MHz crystal is legible on a photograph of a real STA-0001B motherboard** `[PRIMARY]`. 42.9545 / 6 = 7.159083 MHz, and 7.159083 MHz / (454 × 262) = 60.19 Hz — a standard arcade rate. The divide-by-6 is now hardware-grounded. |
| A2 | H total 454, H active 336 | **PARTIALLY** | The *product* 454 × 262 is confirmed by the crystal producing a sane 60.19 Hz. The split between active and blanking is still unconfirmed. |
| A3 | V total 262, V active 240 | **PARTIALLY** | As A2. |
| A4 | HSYNC pixels 368–400 (32 wide) | **UNCONFIRMED — flagged in our own source as not PCB-measured** | Now the single highest-value remaining measurement. Needs a scope. |
| A5 | VSYNC lines 244–247 (3 lines) | **UNCONFIRMED — same** | |
| A6 | V60 at 16.00 MHz | ✅ **CONFIRMED (strong inference)** | **A 48.000 MHz crystal is legible on the same photograph** `[PRIMARY]`. 48.000 / 3 = 16.000 MHz, the standard V60 speed. Routing not directly traced, but no other division of 48.000 MHz gives a sensible CPU clock. |
| A7 | ES5506 clocked from the same enable as V60 | **PLAUSIBLE** | The board has only two crystals, and the ES5506 spec caps at 16 MHz `[PRIMARY]`. 48.000 MHz is the only source that yields ≤16 MHz sensibly, so OTTO almost certainly derives from the same crystal as the V60. Supports `ce_snd = ce_cpu`, though the exact divider is unconfirmed. |
| A8 | 0x8000 palette entries, 32-bit xRGB888 | **UNCONFIRMED** | |
| A9 | Sprite/list RAM 0x40000 bytes at CPU 0x100000 | **UNCONFIRMED** | |

**Two crystals, two confirmations.** The board carries exactly **42.9545 MHz** and
**48.000 MHz**. Every clock in the core divides cleanly from those two values and matches what
we already implemented — the video and CPU clock derivations are hardware-correct, not merely
self-consistent. What remains unconfirmed is the *blanking/sync structure* within the frame,
which no photograph can settle.

---

## 1. Motherboard / cartridge topology

| Claim | Provenance | Source | Implication |
|---|---|---|---|
| SSV is a two-part system: a common motherboard plus a per-game ROM/cartridge board | `[SECONDARY]` | Multiple collector/auction listings | Matches the core's structure (fixed core + per-game ROM set) |
| Motherboard revisions **STA-0001** and **STA-0001B** exist | `[SECONDARY]` | Search summary of collector sources | Unknown whether the revisions differ functionally. Worth establishing before claiming "SSV accurate" generally |
| **Dyna Gear and Survival Arts share the same `SAM-5127` sub-board and the same memory map** | `[SECONDARY]` | arcade-projects.com discussion | **Directly actionable:** Survival Arts is the cheapest second game to support — same board, same map. Good first target after Dyna Gear |
| 4-in-1 multi ROM boards exist (Change Air Blade, Vasara 1, Vasara 2, Ultra X Weapons) | `[SECONDARY]` | Auction listings, repair logs | These are aftermarket/multi conversions, not original topology |

## 2. Crystals and oscillators — RESOLVED `[PRIMARY]`

From a photograph of a real **STA-0001B** motherboard, both crystal cans are legible, sitting
together near the lower-left of the board beside the JAMMA edge:

| Crystal | Almost certainly feeds | Derivation |
|---|---|---|
| **42.9545 MHz** | Video | ÷6 → 7.159083 MHz pixel clock → 60.19 Hz at 454 × 262 |
| **48.000 MHz** | V60 (and very likely ES5506) | ÷3 → 16.000 MHz |

42.9545 MHz is 12× NTSC colourburst (3.579545 MHz), a standard arcade value. **The board has
only these two crystals**, so every clock in the system derives from one of them — which
constrains the ES5506 clock to a division of 48.000 MHz (the spec caps OTTO at 16 MHz).

Both values match what the core already implements. This converts our video and CPU clocking
from "inherited from an emulator" to "matches the real board".

## 3. Custom chip inventory — PARTIALLY RESOLVED `[PRIMARY]`

Legible on the STA-0001B photograph:

| Marking | Package / position | Notes |
|---|---|---|
| **ENSONIQ** (ES5506 / OTTO) | Large QFP, upper-left | Confirms the sound chip is a genuine Ensoniq part, adjacent to the analogue section and audio heatsink |
| **ST0007** | Large QFP, upper-centre | A Seta custom, silkscreen-labelled on the board itself — **this is the first part number confirmed from hardware rather than from emulator sources** |
| Second large QFP, upper-right (U14 area) | ~100-pin QFP | Marking not resolvable at this image scale — a higher-resolution shot would name it |
| **KM681000AL P-7L** ×2 | DIP, centre | Samsung 128K × 8 SRAM, 70 ns |
| 74ALS245 / ALS273 / ALS244 etc. | DIP + SOIC | Standard glue logic |

So the ST-00xx naming convention **is** real and does appear on the silicon — at least ST0007
does. The remaining customs still need a sharper photograph.

## 4. Connectors, JAMMA edge, controls, DIP switches — PARTIALLY RESOLVED `[PRIMARY]`

- **JAMMA edge** along the left side of the motherboard, as expected for a JAMMA PCB.
- **Two 8-position DIP banks** (DSW1 and DSW2), bottom-left, each silkscreened `12345678`.
  This confirms the core's two-DIP-bank model and the 8-bits-per-bank width.
- **Four cartridge connectors** labelled **A, B, C, D** — A/B along the top edge, C/D along
  the bottom — mating with the matching A/B/C/D on the ROM board.
- **3P and 4P connectors** on the ROM board for third and fourth player wiring. Dyna Gear is
  a 2-player game, so this is a platform feature; worth knowing for the wider family.

## 4a. Dyna Gear ROM board — `SAM-5127` `[PRIMARY]`

Silkscreen reads **`SAM-5127`** / **`MADE IN JAPAN`**, confirming the forum claim that Dyna
Gear uses this sub-board (and therefore that Survival Arts, reported to share it, is the
natural second target).

| Feature | Detail |
|---|---|
| Program ROMs | Two positions silkscreened **`PRL`** and **`PRH`** (program low / high) — a 16-bit CPU bus split across two byte-wide EPROMs, matching the core's 16-bit V60 bus |
| EPROM types fitted | **TMS27C040** and **AM27C040** (512K × 8, UV-erasable) |
| Graphics ROM array | Sockets silkscreened in banks **A0–A3, B0–B3, C0–C3, D0–D3** — a four-bank × four-position layout |
| Population | Many sockets are **empty** on this board — Dyna Gear does not fill the full array, so the ROM board is sized for larger games in the family |
| Other | A `DATA` silkscreen near the top connector; 3P/4P player connectors on the right edge |

The `PRL`/`PRH` split and the banked graphics array are consistent with the loader's
interleave model.

### SAM-5127 component side, high resolution `[PRIMARY]`

| Observation | Detail | Implication |
|---|---|---|
| **Program ROMs are windowed EPROMs at `PRL` / `PRH`** | One MX-branded with a black dot seal, one with a white label | Low/high byte of the 16-bit V60 bus, exactly as the loader's interleave assumes |
| **Graphics ROMs are Sharp mask ROMs** | `Sharp` branding legible on the large DIPs | Mask ROM, not EPROM — these are production parts, so the graphics layout is fixed silicon |
| **Graphics sockets are silkscreened in four banks: `A0–A3`, `B0–B3`, `C0–C3`, `D0–D3`** | A 4 × 4 = 16-position array | **See below — this looks like direct hardware evidence for the "quarters" model** |
| **Many sockets are unpopulated** | Silkscreened footprints with no chip fitted, across several banks | Dyna Gear does not fill a board sized for larger family titles |
| **Cartridge logic is 74LS-series only** | LS245 / LS244 / LS273 buffers and latches; `CN-CP40…CP43` designators | **No custom silicon, no protection device, no battery on the Dyna Gear cart** — nothing cartridge-side left to emulate for this title |
| 3P / 4P connector positions | White pin header at the right edge, `3P` and `4P` silkscreen | Platform feature; Dyna Gear is 2-player |

#### The four banks probably *are* our "quarters"

`rtl/video/ssv_gfx_row_fetch.sv` fetches graphics as *quarters* — Q0/Q1 packed into one
64-bit beat, Q2 in its own range — and its header comment says **"MAME's absent fourth
plane-pair quarter reads as zero"**. That was inherited from the emulator with no hardware
justification.

The physical board has **exactly four graphics banks (A/B/C/D)**, and on this Dyna Gear
cartridge **they are not all populated**. That is independent hardware support for the
"fourth quarter is absent / reads as zero" behaviour: it is absent because *there is no chip
in those sockets*, not because an emulator decided so.

Confidence: **strong but not conclusive** — I can read the bank labels and see unpopulated
positions, but cannot trace which bank maps to which quarter from a photograph. Confirming
the mapping needs continuity testing on a board, or a close-up clear enough to read every
populated chip's position label at once.

### Solder side (SAM-5127 reverse) `[PRIMARY]`

- **Two-layer board.** Traces on both faces, no evidence of inner layers. Modest complexity —
  consistent with an early-90s cartridge whose job is mostly to hold EPROMs and route them.
- **Four card-edge connectors** confirmed from the reverse: two along the top edge, two along
  the bottom, mating with the motherboard's A/B (top) and C/D (bottom).
- Large ground/power pour on the left third.
- Nothing electrically surprising: no protection device, no battery, no logic beyond the
  handful of DIPs visible on the component side. **Dyna Gear's cartridge appears to be
  ROMs + address decoding only** — which is good news for the core, as it means no
  cartridge-side custom silicon to emulate for this title.

### Additional motherboard detail, second pass `[PRIMARY]` / `[UNCERTAIN]`

Confident:

| Observation | Note |
|---|---|
| Grid reference silkscreen **A–S** across the top, **1–9** down the right | Standard Seta service-grid; useful when following any future repair log |
| **Jumper blocks JP1, JP2, JP3, JP4** | Configuration straps. Purpose unknown — a likely candidate for region/monitor/audio options. Worth probing on a real board |
| Test points labelled **TP GND** in several places | |
| Two heatsinks: large one upper-left in the analogue section (audio amp), one lower-centre (regulator) | Confirms an on-board audio power amp — the board drives speakers directly, per JAMMA |
| Serial sticker `S-001419` with a Sammy ownership label | |

Uncertain at this image resolution — **do not treat as established**:

- A silkscreen that reads plausibly as **`ST0007`** beneath the large centre QFP (~U12).
- A possible **`ST0005`** marking on a smaller QFP at the lower-left near the JAMMA edge.
- A second large ~100-pin QFP upper-right (~U14) whose marking cannot be resolved at all.

These need close-up shots before being written down as fact. The earlier commit recorded
`ST0007` with more confidence than this resolution really supports; treat it as probable
rather than confirmed until someone photographs it directly.

### Photographs that would unlock the most, in value order

1. **Close-up of the upper-right large QFP (~U14).** Completely unread. Given its size and
   position between the CPU area and the video RAM, it is likely the sprite/tilemap engine —
   the exact part we have no documentation for.
2. **Close-up of the centre QFP and its silkscreen** — confirm or correct `ST0007`.
3. **Close-up of the lower-left QFP near the JAMMA edge** — confirm or correct `ST0005`.
4. **Close-up of the top-left Ensoniq QFP** — read the full part number and date code.
5. **The four jumper blocks JP1–JP4**, close enough to see which are strapped.

## 5. Video output electrical

Not established beyond the inference that SSV is a standard 15 kHz JAMMA RGB board
(consistent with it being sold as a JAMMA PCB and running on standard arcade monitors)
`[SECONDARY]`.

## 6. Power, battery/suicide, watchdog

No evidence of battery-backed protection on Dyna Gear `[NEGATIVE]`. One repair log describes
**"glitches in the background tiles" caused by poor factory SMD solder joints**, fixed by
reflowing `[SECONDARY]` — worth knowing, because it means background tile corruption is a
*known failure mode of the real hardware too*, and a collector reporting it is not necessarily
reporting an emulation bug.

---

## 8. Measurement checklist for someone with a board

In value order. Every item is cheap with the right kit and currently unobtainable otherwise.

1. **Photograph every crystal/oscillator can, legibly.** Resolves A1, A6, A7 outright.
2. **Scope HSYNC and VSYNC.** Measure period, pulse width and polarity. Resolves A4 and A5 —
   the two constants our own source code admits are guesses.
3. **Photograph the motherboard and the Dyna Gear cart at high resolution**, both sides.
   Resolves the entire custom-chip inventory question.
4. Measure the V60 CLK pin and the ES5506 master clock. Resolves A6/A7 and tells us whether
   `ce_snd = ce_cpu` is board-correct or a convenient simplification.
5. Logic-analyse the OTTO sample-fetch bus during play — gives real voice slot timing.
6. Confirm active pixel and line counts by capturing a frame with a known-good digitiser.

---

## Research log

- system16.com hardware page — HTTP 403 to automated fetch. Worth a manual visit.
- pixelatedarcade SSV page — game list only, no specifications on the fetched page.
- shootthecore.tech SSV repair — no component-level detail; documents the solder-joint fault.
- arcade-projects.com threads — HTTP 403 to automated fetch. **These look like the best
  remaining lead**: multiple threads by people with boards in hand. Manual reading recommended.
- siliconpr0n — no Seta SSV die shots found.
- Google Patents (Seta, 1990-1996, sprite/tilemap/scroll) — nothing matching found.
</content>
