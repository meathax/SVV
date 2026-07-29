# Phase 8 — nine-game support

Target: Change Air Blade, Drift Out '94, Dyna Gear, Storm Blade, Survival Arts,
Twin Eagle II, Ultra X Weapons, Vasara, Vasara 2.

All per-game facts below were read out of
`D:\Arcade\AI\MAMESOURCE\mame\src\mame\seta\ssv.cpp`, not inferred.

## Done

### Per-game configuration record

`ssv_pkg::ssv_cfg_t` carries what cannot be derived from the ROM stream:
program size, graphics region size, tile-code modulus (`gfx_code_k`,
`gfx_code_mul3`), populated quarter count, ES5506 `bank_map`/`bank_valid`,
`tile_code_identity` (`init_ssv` vs `init_ssv_tilescram`), `irq_level1_line0`
(`init_ssv_irq1`), `has_add_buttons` (`$500008`), and `wdog_mode`.

`cfg_dynagear()` is the reference record and reproduces the previously
hardwired behaviour exactly. It is plumbed through `ssv_core`, both renderers,
`ssv_gfx_row_fetch`, the top level and every bench; nothing reads a hardwired
per-game constant on that path any more.

**Cost: ~0 logic today** — the record is a compile-time constant, so the
generalisation is free until a second game supplies a different one.

### Tile-code wrapping — a real bug for six of the nine titles

MAME wraps sprite codes with `code % gfxelement->elements()`, a **true modulo**,
and `elements()` = sprites region / 128:

| set | region | elements | decomposition |
|---|---:|---:|---|
| ultrax | 0x0C00000 | 0x18000 | **3 × 2^15** |
| dynagear | 0x1000000 | 0x20000 | 2^17 |
| survarts / twineag2 / stmblade | 0x1800000 | 0x30000 | **3 × 2^16** |
| cairblad / drifto94 / vasara / vasara2 | 0x2000000 | 0x40000 | 2^18 |

The core's `wrap_code = code[16:0]` mask was correct **only** for Dyna Gear.
`ssv_pkg::wrap_code_cfg` implements the general case; for `3 << k`,

```
code % (3<<k) == ((code >> k) % 3) << k | code[k-1:0]
```

and `code >> k` is at most 5 bits, so the modulo is a small LUT, not a divider.

**Verified** by `verif/tb_ssv_cfg.sv`: 12,418 checks against a reference modulo
across all nine titles, sweeping the full 20-bit code space and deliberately
including codes above `elements()` — the only region where masking and modulo
differ.

The bench also proves it **discriminates**, which is the part that matters:

```
dynagear  elements=20000 old-mask disagreements=0
survarts  elements=30000 old-mask disagreements=643
cairblad  elements=40000 old-mask disagreements=514
```

Dyna Gear's zero is the regression proof — for a 2^17 modulus the new function
is exactly the old mask, so the change cannot have moved it. Every other title
shows hundreds of disagreements per sweep, so had the mask still been in place
the bench would have failed.

Confirmed end to end: 215-frame gameplay frame CRC **identical** before and
after the generalisation.

### Quarter 3 is per game

`plane67` was a hardwired `32'd0`, load-bearing because a three-quarter title
never writes those bytes and reading them returns X against a chip model. It is
now `cfg.gfx_quarters == 4 ? rom_data[127:96] : 32'd0`, so the four-quarter
titles (cairblad, drifto94, vasara, vasara2) can use it while Dyna Gear keeps
the guard. Opening it unconditionally would be the same bug in reverse.

### ES5506 bank population is per game

The voice engine gated on `cr[15:14] != 2'b10` ("only bank 2 is populated for
Dyna Gear"). It now gates on `cfg.bank_valid[cr[15:14]]`. `bank_map` is in the
record to honour MAME's `ROM_COPY` aliases (twineag2, ultrax alias banks 2/3
onto 0/1) by address rather than by duplicating sample data.

### Program window and watchdog are per game

`sel_rom` derived from `cfg.prog_mb`: in 24-bit arithmetic the base is exactly
`-prog_size`, giving **$f00000 / $e00000 / $c00000** for 1 / 2 / 4 MB — MAME's
values for all nine sets, with no extra config field.

The watchdog now has three modes, and this is not cosmetic:

| mode | kick | games |
|---:|---|---|
| 1 | read `$210000` | dynagear, survarts, twineag2, ultrax |
| 2 | write `$210000` | vasara, vasara2 |
| 0 | none | drifto94, stmblade |

MAME's `WATCHDOG_TIMER` first appears at `ssv.cpp:2513`, *after* the drifto94
and stmblade machine configs — those boards have no watchdog. Left as it was,
the unconditional 180-frame counter would have reset them forever and would
never have been kicked by vasara.

`verif/tb_ssv_watchdog.sv` is parameterised by mode and all three pass,
including a **wrong-direction** phase: a read must not kick a write-kick board
and vice versa. That is the half that matters — a core that read-kicks
regardless would pass a naive kick test on vasara and then reset in play.

### Per-game region sizes

The SDRAM slots carried Dyna Gear's sizes, so the larger titles would not have
fit. They are now sized for the worst case across the nine (program 4 MB,
graphics 32 MB, samples 8 MB), with graphics occupying exactly bank 1.
High-water 104 MB of 128 MB, no overlaps, graphics base still 16-byte aligned.

Two things had to be separated to make that legal:

- **Stream sizes vs slot sizes.** `SDR_MAINCPU_SIZE` and `SDR_SAMPLES_SIZE`
  were doing double duty as both the shipped game's byte counts (for the MRA
  stream contiguity rules) and the SDRAM slot sizes. That only worked while one
  game filled its slots exactly. `STREAM_MAINCPU_SIZE` / `STREAM_SAMPLES_SIZE`
  now carry the former.
- **`layout_fault` rule 10 was an equality**, asserting the graphics slot
  matched the 4/3 repack ratio of the stream -- which silently required the
  region to be sized for one specific title. It is now a bound: the packed data
  must FIT. One 32 MB slot serves Ultra X Weapons' 12 MB through Vasara's 32 MB.

Bases did not move, so no byte of data relocated: frame CRC identical.

### Six-button matrix and $500008

MAME's `ADD_BUTTONS` at `$500008` carries P1 buttons 4-6 on bits 0-2 and P2 on
bits 4-6, active low, and **only `survarts_map` decodes it** -- Survival Arts is
a fighting game. The core exposed two game buttons, tied B3 released, and
hardwired `in_extra` to `16'hffff`.

`J1` is now ten entries (`B1..B6, Test, Service, Start, Coin`), which renumbers
every joystick bit, so `CONF_STR`, `player_port`, `db15_to_joy`, the
test/service/coin taps, `in_extra`, the input-matrix bench's *mirror* of all of
that, and the `<buttons>` list in all 33 MRAs moved together. B3 is a real
button now; SSV's port always carried it and Dyna Gear simply never presses it.

`in_extra` is gated on `cfg.has_add_buttons`, so every other title still reads
the idle `16'hffff` it read before -- an ungated port would change what those
games see at an address their program may still probe.

`verif/tb_ssv_input_matrix.sv` passes, including the inverted assertion: it used
to prove B3 was unreachable, and now proves the full low byte goes active.

## Phase 8 is complete.

## Not done

| item | note |
|---|---|
| MRA `<rom index="1">` config path in the loader | The record exists and is plumbed everywhere; nothing parses it from the download yet, so `cfg` is still the compile-time `cfg_dynagear()`. This is the remaining gate on actually selecting a game. |
| Compressed ES5506 samples | `CR_CMPD` voices still output silence. Measured 0 running compressed voices on Dyna Gear, so this is a pure multi-game item. |
| IRQ level 1 at scanline 0 | Needed by twineag2 and ultrax (`init_ssv_irq1`); breaks cairblad, hence the config bit — which exists but is not yet consumed by `ssv_irq`. |
| Tile-code expansion table | `init_ssv` bitswap vs cairblad's identity `init_ssv_tilescram`; `tile_code_identity` is in the record but not yet consumed. |
| `tools/gen_ssv_mras.py` | Still gates `supported = setname == 'dynagear'`. Needs the machine-config/address-map/init parsers, the config blob, graphics tail padding and the hiscore entry. |
| V60 opcode gaps | `0x59`, `0x5B`, `0x5D` partial. Dyna Gear's boot does not need them; eight other programs might. Mitigate with a sticky "unimplemented opcode" status bit rather than prediction. |

## Not reachable without new silicon

**Drift Out '94, Twin Eagle II and Storm Blade require an ST010 (NEC
uPD96050)** — `UPD96050(config, m_dsp, 10000000)` at `ssv.cpp:2468/2642/2755`,
with `ROM_REGION(0x11000, "st010")` mapped at `$480000` and its data RAM at
`$482000-$482fff`. That is Phase 9 and is a CPU core in its own right
(~2000 ALM, 4–8 M10K estimated). Six of the nine titles are reachable without
it; Storm Blade may be substantially playable without the DSP, and the first
deliverable there should be a measurement of how far it gets, not a fix.
