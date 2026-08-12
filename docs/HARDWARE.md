# Hardware truth model

> Populate from evidence. Do not turn unknowns into implementation assumptions.

The project has no access to an original PCB and does not expect future board
measurements.  Remaining unresolved behavior follows the explicit
[MAME 0.289 behavioral-reference profile](REFERENCE_PROFILE.md); this is an
emulator-equivalence target, not a claim of measured PCB-cycle accuracy.

## Identity

| Field | Value | Confidence | Source |
|---|---|---:|---|
| Game / set | UNRESOLVED |  |  |
| PCB name/revision | UNRESOLVED |  |  |
| Region/clone differences | UNRESOLVED |  |  |
| MAME short name/driver | UNRESOLVED |  |  |

Confidence values: `KNOWN`, `INFERRED`, `HYPOTHESIS`.

## Evidence inventory

| ID | Evidence | Revision/location | Supports | Limitations |
|---|---|---|---|---|
| E001 |  |  |  |  |

## Clock tree

| Source | Frequency | Derivation | Consumers | Enable/phase | Confidence/source |
|---|---:|---|---|---|---|
| OSC0 |  |  |  |  |  |

Document actual clocks separately from synchronous clock enables. Record reset release relation and any asynchronous boundaries.

## Processing devices

| Device | Type/revision | Clock | Bus | Reset | Interrupts | Confidence/source |
|---|---|---:|---|---|---|---|
| MAIN |  |  |  |  |  |  |

## Memory and address map

| Owner | Address range | Width | Device | Read/write behavior | Wait/arbitration | Confidence/source |
|---|---|---:|---|---|---|---|
|  |  |  |  |  |  |  |

Record mirroring, banking, byte lanes, endian behavior, open-bus behavior, read side effects and read-during-write semantics.

## Interrupts, DMA and timers

| Source | Target/level | Trigger | Latch/ack/clear | Timing domain | Confidence/source |
|---|---|---|---|---|---|
|  |  |  |  |  |  |

For DMA record source, destination, width, trigger, ordering, busy/ack, bus stealing and completion behavior.

## Video

| Property | Value | Confidence/source |
|---|---|---|
| Master/pixel clock |  |  |
| Total/active dimensions |  |  |
| H/V blank and sync |  |  |
| Tilemap layers |  |  |
| Sprites/buffering |  |  |
| Palette format |  |  |
| Priority/mixer |  |  |
| Special effects |  |  |

Describe where registers latch: immediate, pixel, line, vblank, frame or DMA boundary.

## Audio

| Path/device | Clock/rate | Registers/bus | IRQ/timer | ROM/banking | Confidence/source |
|---|---:|---|---|---|---|
|  |  |  |  |  |  |

## Inputs, outputs and persistent state

Document controls, analog/trackball/wheel semantics, DIP switches, coin/service, lamps, watchdog, EEPROM/NVRAM and power-on defaults.

## Board/game variants

| Feature | Variant A | Variant B | RTL strategy | Verification |
|---|---|---|---|---|
|  |  |  |  |  |

## Unknowns and experiments

| ID | Unknown | Why it matters | Smallest experiment | Status |
|---|---|---|---|---|
| U001 |  |  |  | OPEN |

## Implementation mapping

| Hardware function | RTL module/path | Donor/source | Verification status |
|---|---|---|---|
|  |  |  |  |
