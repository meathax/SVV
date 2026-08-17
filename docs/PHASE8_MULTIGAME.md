# Phase 8 — universal SSV profile

This is the historical implementation record. The current cross-chat
contract is `AGENTS.md`, `core-debug.toml`, `docs/GAME_COVERAGE.md`, and
`docs/implementation-status.md`. All work stays in the single universal
profile; there are no per-game RBFs or compile-time game forks.

Target: the nine current authoritative manifest entries `dynagear`,
`cairblad`, `vasara`, `vasara2`, `drifto94`, `stmblade`, `twineag2`, and
`ultrax`, plus the USA Survival Arts clone `survartsu`. The Ultra X Gamest
review build remains a retired local archive, not a supported profile entry.

All per-game facts below were read out of
`D:\Arcade\AI\MAMESOURCE\mame\src\mame\seta\ssv.cpp`, not inferred.

## Done

### Per-game configuration record

`ssv_pkg::ssv_cfg_t` carries what cannot be derived from the ROM stream:
program size, graphics region size, tile-code modulus (`gfx_code_k`,
`gfx_code_mul3`), populated quarter count, visible geometry, ES5506
`bank_map`/`bank_valid`,
`tile_code_identity` (`init_ssv` vs `init_ssv_tilescram`), `irq_level1_line0`
(`init_ssv_irq1`), `extra_input_mode`, `system_input_mode`, lockout polarity,
and `wdog_mode`.

Descriptor byte 5 retains its ABI location, but only bit 0 is decoded: zero
selects factor 1 and one selects factor 3. The nine-set generator and verifier
reject factors 5/7 and graphics regions outside 12, 16, 24, or 32 MiB.

`cfg_dynagear()` remains the reference record for unit tests, while production
configuration is decoded from the MRA index-1 descriptor by
`rtl/mem/ssv_rom_loader.sv`. It is plumbed through `ssv_core`, both renderers,
`ssv_gfx_row_fetch`, the top level, and every bench; no supported game relies
on a hardwired per-game constant on that path.

The record is runtime descriptor state, not a compile-time game selection.
Resource cost therefore belongs to the one shared universal path and must be
measured in synthesis rather than inferred from any individual set.

### Tile-code wrapping — a real bug for three of the nine supported entries

MAME wraps sprite codes with `code % gfxelement->elements()`, a **true modulo**,
and `elements()` = sprites region / 128:

| set | region | elements | decomposition |
|---|---:|---:|---|
| ultrax | 0x0C00000 | 0x18000 | **3 × 2^15** |
| dynagear | 0x1000000 | 0x20000 | 2^17 |
| twineag2 / stmblade / survartsu | 0x1800000 | 0x30000 | **3 × 2^16** |
| cairblad / drifto94 / vasara / vasara2 | 0x2000000 | 0x40000 | 2^18 |

The core's `wrap_code = code[16:0]` mask was correct **only** for Dyna Gear.
`ssv_pkg::wrap_code_cfg` implements the general case; for `3 << k`,

```
code % (3<<k) == ((code >> k) % 3) << k | code[k-1:0]
```

and `code >> k` is at most 5 bits, so the modulo is a small LUT, not a divider.

**Covered** by `verif/tb_ssv_cfg.sv` against a reference modulo across all four
manifest graphics geometries, sweeping the full 20-bit code space and deliberately
including codes above `elements()` — the only region where masking and modulo
differ.

The bench also proves it **discriminates**, which is the part that matters:

```
dynagear  elements=20000 old-mask disagreements=0
survartsu elements=30000 old-mask disagreements=643
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
titles (drifto94, vasara, vasara2) can use it while Dyna Gear and Cairblad keep
the three-quarter guard. Opening it unconditionally would be the same bug in
reverse.

### ES5506 bank population is per game

The voice engine gated on `cr[15:14] != 2'b10` ("only bank 2 is populated for
Dyna Gear"). It now gates on `cfg.bank_valid[cr[15:14]]`. `bank_map` is in the
record to honour MAME's `ROM_COPY` aliases (twineag2, ultrax alias banks 2/3
onto 0/1) by address rather than by duplicating sample data.

`CR_CMPD` is also implemented once in the shared voice path. Its decoder is
the OTTO equation used by MAME's ES5506 device, not a generic telephony u-law
lookup. `verif/tb_ssv_es5506_ulaw.sv` checks source-derived values across the
exponent and sign boundaries, while `verif/tb_ssv_es5506_voice.sv` checks
positive and negative compressed samples after filtering and mixing. Full
real-set compressed-audio qualification remains part of the matrix gate. The
same register path now applies MAME's cold-reset voice defaults (`CR=3`,
`LVOL/RVOL=0x8000`, all other fields zero) without erasing those banks during a
watchdog device reset; `verif/tb_ssv_es5506_regs.sv` covers the retention edge.

### Program window and watchdog are per game

`sel_rom` derived from `cfg.prog_mb`: in 24-bit arithmetic the base is exactly
`-prog_size`, giving **$f00000 / $e00000 / $c00000** for 1 / 2 / 4 MB — MAME's
values for all nine supported sets, with no extra config field.

The watchdog now has three modes, and this is not cosmetic:

| mode | kick | games |
|---:|---|---|
| 1 | read `$210000` | dynagear, twineag2, ultrax, survartsu |
| 2 | write `$210000` | vasara, vasara2 |
| 0 | none | drifto94, stmblade |

MAME's `WATCHDOG_TIMER` first appears at `ssv.cpp:2513`, *after* the drifto94
and stmblade machine configs — those boards have no watchdog. Left as it was,
an unconditional watchdog would reset them forever and a read-only strobe
would never be kicked by vasara.

MAME leaves the timer interval at `watchdog_timer_device`'s exact three-second
default. The RTL therefore counts `clk_sys` master cycles from reset rather
than approximating it as 180 post-video frames. `WDOG_TIMEOUT_CYCLES` is
parameterised so `verif/tb_ssv_watchdog.sv` can cheaply cover all three modes,
the exact boundary, and the decisive **wrong-direction** phase.

### Per-game region sizes

The SDRAM slots carried Dyna Gear's sizes, so the larger titles would not have
fit. They are now sized for the worst case across the nine entries (program 4 MB,
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

Survival Arts uses MAME's `ADD_BUTTONS` at `$500008` for P1/P2 buttons 4-6.
The supported `survartsu` profile selects the live six-button mode; Dyna Gear
continues to select the decoded-but-fixed-high mode for the same address.

`J1` is now ten entries (`B1..B6, Test, Service, Start, Coin`), which renumbers
every joystick bit, so `CONF_STR`, `player_port`, the test/service/coin taps,
`in_extra`, the input-matrix bench's *mirror* of all of that, and the `<buttons>`
list in the manifest MRAs moved together. B3 is a real button now; SSV's port
always carried it and Dyna Gear simply never presses it.

`extra_input_mode` distinguishes an absent decode, Dyna Gear's decoded but
idle port, and Survival Arts' live six-button port. `system_input_mode` separately
keeps Vasara/Vasara 2 Test and Tilt fixed high while normal profiles retain
live cabinet inputs.

The shared `$21000e` handler follows MAME's `lockout_w` and `lockout_inv_w`:
reset starts unlocked, the descriptor selects polarity, locked active-low coin
inputs are forced released, and both bookkeeping diagnostics increment only
on rising counter-drive edges. No game-name branch is used.

`verif/tb_ssv_input_matrix.sv` passes, including the inverted assertion: it used
to prove B3 was unreachable, and now proves the full low byte goes active.

## Phase 8 is complete.

## Remaining qualification work

| item | note |
|---|---|
| MRA `<rom index="1">` config path in the loader | **Done.** Descriptor bytes are validated, decoded, and used for ROM placement and runtime feature selection. |
| IRQ level 1 at scanline 0 | **Done in shared RTL.** `cfg.irq_level1_line0` is consumed by `rtl/ssv_irq.sv`; per-set gameplay qualification remains open. |
| Tile-code expansion table | **Done in shared RTL.** Both renderers consume `cfg.tile_code_identity`; modulo coverage is in `verif/tb_ssv_cfg.sv`. |
| `tools/gen_ssv_mras.py` | **Done for the supported matrix.** The nine-set authoritative manifest, descriptor generation, and profile audit are in `tools/ssv_supported_sets.py`, `tools/gen_ssv_mras.py`, and `tools/verify_ssv_universal_profile.py`. |
| Compressed ES5506 samples | **Shared path implemented; focused-tested.** The MAME/OTTO decoder is centralized in `ssv_pkg`, with table-value and post-mixer polarity regressions; full real-set/matrix qualification remains open. |
| V60 opcode gaps | **Open qualification boundary.** Any implementation is shared CPU RTL and must be covered before promoting additional sets. |

## Optional hardware status

**Drift Out '94, Twin Eagle II and Storm Blade require an ST010 (NEC
uPD96050)** — `UPD96050(config, m_dsp, 10000000)` at `ssv.cpp:2468/2642/2755`,
with `ROM_REGION(0x11000, "st010")` mapped at `$480000` and its data RAM at
`$482000-$482fff`. The shared uPD96050 implementation is now present in the
universal source profile and descriptor-gated for those sets. Remaining work
is real-set boot/gameplay evidence, not a separate profile or RBF. Future DSP
fixes must stay in shared `rtl/cpu/upd96050/` RTL.
