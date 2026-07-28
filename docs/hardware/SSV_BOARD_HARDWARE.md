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
| A1 | Pixel clock 42.954545 MHz / 6 = 7.159 MHz | **UNCONFIRMED** | No PCB photo found with legible crystal markings. 42.954545 MHz is 3× NTSC colourburst (3.579545), a very common arcade crystal, so it is *plausible* — but plausible is not measured. |
| A2 | H total 454, H active 336 | **UNCONFIRMED** | 454 × 7.159 MHz = 15.77 kHz, consistent with a standard 15 kHz arcade monitor. Self-consistent, not independently sourced. |
| A3 | V total 262, V active 240 | **UNCONFIRMED** | 15.77 kHz / 262 = 60.2 Hz. Self-consistent with standard NTSC-rate arcade video. |
| A4 | HSYNC pixels 368–400 (32 wide) | **UNCONFIRMED — flagged in our own source as not PCB-measured** | Highest-value cheap measurement. |
| A5 | VSYNC lines 244–247 (3 lines) | **UNCONFIRMED — same** | |
| A6 | V60 at 16.00 MHz | **PLAUSIBLE** | ES5506 spec states "up to 16 MHz operation" `[PRIMARY]`, and V60 parts were commonly 16 MHz. Not confirmed for this board. |
| A7 | ES5506 clocked from the same enable as V60 | **UNCONFIRMED** | Needs a board measurement of the OTTO clock pin. |
| A8 | 0x8000 palette entries, 32-bit xRGB888 | **UNCONFIRMED** | |
| A9 | Sprite/list RAM 0x40000 bytes at CPU 0x100000 | **UNCONFIRMED** | |

**None of the video timing constants has independent hardware confirmation.** They are
internally self-consistent and produce a standard 15 kHz / ~60 Hz signal, which is reassuring
but is not evidence.

---

## 1. Motherboard / cartridge topology

| Claim | Provenance | Source | Implication |
|---|---|---|---|
| SSV is a two-part system: a common motherboard plus a per-game ROM/cartridge board | `[SECONDARY]` | Multiple collector/auction listings | Matches the core's structure (fixed core + per-game ROM set) |
| Motherboard revisions **STA-0001** and **STA-0001B** exist | `[SECONDARY]` | Search summary of collector sources | Unknown whether the revisions differ functionally. Worth establishing before claiming "SSV accurate" generally |
| **Dyna Gear and Survival Arts share the same `SAM-5127` sub-board and the same memory map** | `[SECONDARY]` | arcade-projects.com discussion | **Directly actionable:** Survival Arts is the cheapest second game to support — same board, same map. Good first target after Dyna Gear |
| 4-in-1 multi ROM boards exist (Change Air Blade, Vasara 1, Vasara 2, Ultra X Weapons) | `[SECONDARY]` | Auction listings, repair logs | These are aftermarket/multi conversions, not original topology |

## 2. Crystals and oscillators

**Not established.** `[NEGATIVE]` No photograph found with legible crystal silkscreen. This is
the single highest-value item obtainable from a board photograph and remains open.

## 3. Custom chip inventory

**Not established from primary sources.** `[NEGATIVE]` The ST-00xx part numbers in common
circulation trace to emulator sources rather than to photographs or documentation in
everything found so far. A clear photograph of an SSV motherboard would settle the actual
markings immediately.

## 4. Connectors, JAMMA edge, controls, DIP switches

Not established. `[NEGATIVE]`

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
