# Plan: from emulator-derived to PCB-accurate

Created 28 July 2026, after a research pass for real Sammy/Seta/Visco SSV hardware evidence
(`SSV_BOARD_HARDWARE.md`, `SSV_SILICON.md`, `SSV_VIDEO_AND_FAMILY.md`).

Target: **Dyna Gear** first, with choices made so the wider SSV family stays reachable.

---

## The finding that shapes this plan

**The Seta custom silicon is undocumented in public.** No schematic, no datasheet, no decap,
no patent. Even the ST-00xx part numbers trace back to emulator sources rather than to a
photograph. Meanwhile the two *standard* parts — NEC V60 and Ensoniq ES5506 — have genuine
manufacturer documentation that is freely obtainable.

So accuracy work splits cleanly, and the split determines the order of work:

| Domain | Route to accuracy | Cost |
|---|---|---|
| V60 CPU | **Read NEC's manual.** Free, available now | Low |
| ES5506 audio | **Read Ensoniq's spec.** Already the project's source; deepen it | Low |
| Video timing | **Measure a board.** No document will ever tell us | Needs hardware |
| Sprite/tilemap engine | **Probe a board.** No document exists | Needs hardware |

The tempting move is to keep searching for SSV documentation. Based on this pass that has low
expected value — the searches that would have found it came back empty. **A few hours with a
board, a camera and a scope would produce more than weeks of further archaeology.** Phase 0
is deliberately built around that.

---

## Phase 0 — Board evidence (blocks the most, costs the least)

Everything here needs a physical SSV board. Nothing here needs FPGA work. In value order:

### 0.1 Photograph the crystals
Resolves the pixel clock, the V60 clock and the ES5506 clock in one go. Our core asserts
42.954545 MHz / 6 for pixels and 16.00 MHz for the CPU; **neither is confirmed**. A legible
photo of each oscillator can settles it permanently.

### 0.2 Scope HSYNC and VSYNC
Measure period, pulse width, polarity. `rtl/ssv_video_timing.sv` currently says in its own
comment that the sync widths are *"not documented by MAME's set_raw call… suitable for MiSTer
output"* — i.e. we know they are invented. Real values would be a direct accuracy win and are
a 10-minute measurement.

### 0.3 High-resolution photographs of motherboard and Dyna Gear cart, both sides
Resolves the entire custom-chip inventory, the RAM types, the DAC, and the board revision
question (STA-0001 vs STA-0001B). Also settles whether the ST-00xx numbers are even correct.

### 0.4 Measure the ES5506 master clock
Our core ties the audio enable to the CPU enable (`ce_snd = ce_cpu`) — a convenient
simplification that saved a second fractional accumulator. This measurement tells us whether
it is board-correct or an approximation we should stop relying on.

### 0.5 Logic-analyse the OTTO sample-fetch bus during play
Gives real voice-slot timing, which feeds directly into the audio accuracy work in Phase 2.

**If a board is not available:** 0.1–0.3 can be satisfied by good auction/forum photographs.
`arcade-projects.com` has several SSV threads by people with boards in hand; those pages
returned HTTP 403 to automated fetching but are readable manually and are the best remaining
lead.

---

## Phase 1 — V60 from NEC's manual (no hardware needed, do this now)

Source: µPD70616 Programmer's Reference Manual, `archive.org/details/NEC_V60pgmRef`.

### 1.1 Reserved-instruction exception behaviour — **highest value**
The opcode audit established that Dyna Gear never executes the `0x58`–`0x5F` family across
51.3 billion retired instructions and five stage environments. The blocker on reclaiming that
area (~47% of the device is the V60) is *what happens if the assumption is ever wrong*.

NEC's manual defines the reserved-instruction exception precisely. With that in hand we can:
- implement the exception correctly rather than guessing,
- then parameter-gate the unused groups **with a defined failure mode** instead of undefined
  behaviour deep in a playthrough.

That converts "unsafe to gate" into "safe to gate, and here is what happens if we are wrong".

### 1.2 Interrupt acknowledge and vector fetch
Verify `ssv_irq` + `s32_v60` against NEC's documented sequence. Our vblank IRQ path is
inferred; a mismatch here would be invisible in normal play but could bite on edge cases.

### 1.3 Bus byte-lane and width rules
Check `s32_v60_bus` against the manual's specification of the 16-bit external bus. It was
written by inference.

### 1.4 Locate a µPD70616 *hardware* datasheet
Still missing. Needed for real bus cycle timing and wait-state behaviour. Without it our CPU
timing stays approximate — which matters, because the renderer's deadline problems are
sensitive to how much SDRAM bandwidth the CPU consumes.

---

## Phase 2 — ES5506 from Ensoniq's spec (no hardware needed)

Source: Ensoniq OTTO (ES5506) Technical Specification v2.3 — already cited by
`docs/ES5506_RESEARCH.md`, so this is deepening an existing good practice.

- **Voice slot scheduling.** Confirm clocks-per-voice and the 32-voice sequence against the
  spec rather than against our derivation.
- **Filter maths as specified.** Our `lp()`/`hp()` are cross-checked against reimplementations;
  check them against Ensoniq's own description instead.
- **Host wait states.** We insert 2 cycles for MLAB read latency. Compare with the spec'd
  asynchronous host protocol.
- **Sample-fetch protocol.** Feeds Phase 0.5 and the `sdr_p4` design.

Note the spec confirms **separate host and sound-memory interfaces**, which validates our
architectural choice of an independent `sdr_p4` port.

---

## Phase 3 — Close the honesty gap in the docs (do immediately, costs nothing)

Several core constants are presented as fact but are actually derived or invented. Regardless
of when hardware appears, the documentation should say which is which:

- `ssv_video_timing.sv` sync widths — already honestly commented. Good; keep it that way.
- `ssv_pkg.sv` H/V totals — mark as unconfirmed against hardware.
- The tilemap **page** model — currently our best explanation of observed behaviour, validated
  against MAME frame-by-frame, but **not** confirmed against silicon. It fixed a real bug and
  matches the reference emulator exactly; that is strong behavioural evidence and weak
  architectural evidence. Say so.
- `ce_snd = ce_cpu` — record as a simplification pending 0.4.

This matters because the next person (or the next session) will otherwise treat these as
settled hardware facts and build on them.

---

## Phase 4 — Family readiness (design choices to make now)

Dyna Gear is the target, but a few cheap decisions keep the family reachable.

**Survival Arts is the natural second game.** It reportedly shares the **same `SAM-5127`
sub-board and the same memory map** as Dyna Gear `[SECONDARY]`. That makes it the lowest-cost
validation that the core is a *platform* and not a single-game special case — and it would
exercise different sprite/tilemap content through the same paths.

Design implications to keep in view:

- **Do not hard-code Dyna Gear specifics** into the memory map or the loader beyond what is
  already parameterised. The `ssv_pkg.sv` layout constants are the place this would creep in.
- **The tilemap page model must generalise.** Dyna Gear puts layers in pages 3/5/6; another
  game will use different pages, and possibly a different `size_shift`. The fix already
  derives page from the scanline origin rather than hard-coding, so this should hold — but it
  is worth testing against a second game's data before claiming it.
- **Later SSV titles add cartridge silicon** (ST-0020 zooming sprites and similar). Those are
  out of scope for Dyna Gear but should not be architecturally excluded — keep the sprite path
  extensible rather than assuming Dyna Gear's feature set is the whole hardware.
- **Watch resolution assumptions.** SSV titles do not all run 336×240. Constants in
  `ssv_pkg.sv` should stay parameters, not literals sprinkled through the RTL.

---

## What this plan deliberately does not do

- **No further broad web archaeology on the Seta customs.** This pass searched the obvious and
  the non-obvious sources and came back empty. Spending more time there has low expected value
  compared with Phase 0.
- **No RBF builds or fitting.** Explicitly out of scope for this work.
- **No "accuracy" changes to the renderer without evidence.** The renderer is now CRC-locked
  to MAME across 950 frames and verified pixel-exact at eight sampled character-select frames.
  Changing it to match a *guess* about hardware would destroy a real reference in exchange for
  a hypothesis.

---

## Recommended order

1. **Phase 3** — documentation honesty. Free, immediate, prevents compounding errors.
2. **Phase 1.1** — V60 reserved-instruction exception from NEC's manual. Unblocks the largest
   area saving available (the V60 is ~47% of the device).
3. **Phase 0** — board photographs and scope measurements, whenever a board is to hand. This
   is the only route to real video-timing accuracy.
4. **Phase 2** — ES5506 spec deep-read, in parallel with anything else.
5. **Phase 4** — Survival Arts as the platform-generality test.
