# SSV — Real-Hardware Video Behaviour and Game Family

**Platform:** Sammy / Seta / Visco "SSV" (motherboard + game cartridge)
**Primary target:** *Dyna Gear* (Sammy, 1993)
**Purpose:** independent, real-PCB evidence to support a cycle-accurate MiSTer FPGA core.

> **MAME is deliberately excluded as a source of hardware fact.** Where a claim's only
> traceable origin is the MAME driver (or a page that merely restates its comments), it is
> tagged `[MAME-ORIGIN]` and recorded *only* so it is not laundered into "hardware fact".

**Status: IN PROGRESS.** This file is written incrementally and appended to as evidence
lands. A previous run of this research was lost by holding everything in memory; nothing is
held back here. `WIP` = not yet researched. `NOT FOUND` = searched, nothing credible found.

---

## Provenance legend

| Tag | Meaning |
|---|---|
| `[PRIMARY]` | Service manual, schematic, datasheet, scope / logic-analyser measurement, legible PCB photograph, capture taken off real hardware |
| `[SECONDARY]` | Repair log, forum post by someone with the board in hand, real-vs-emulator video comparison, auction/collector photo, curated collector wiki |
| `[UNSOURCED]` | Widely repeated with no traceable origin |
| `[MAME-ORIGIN]` | Traceable only to the MAME driver / its comments. **Not hardware evidence.** |

---

## Quick answers to the two high-value questions

*(filled in as evidence lands — see sections 1 and 4)*

| Question | Status |
|---|---|
| Q1. Real HSYNC / VSYNC widths (core uses 32 px / 3 lines, self-flagged as not PCB-measured) | WIP |
| Q2. Do high bits of the horizontal scroll value select the tilemap "page" in sprite RAM? | WIP |

---

## 1. Real video timing

WIP

## 2. Real-hardware video behaviour an emulator might miss

WIP

## 3. SSV game family and per-game hardware differences

WIP

## 4. Sprite / tilemap engine as described by anyone who probed real hardware

WIP

## 5. Could not be established — measurement checklist for someone with a board

WIP

## 6. Where real evidence contradicts an emulator-derived assumption

WIP

---

## Research log

Chronological, including dead ends, so a later run does not repeat them.

