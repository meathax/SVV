# Dyna Gear — drifting corruption bands and distorted audio

Reported from hardware play, 28-29 Jul 2026: horizontal corruption bands that
move up and down, worse in gameplay than in menus, present even on near-static
screens, with music distorting **in step with** the banding.

## Resolved: the benches could not see it

Every full-core testbench answered the core's SDRAM ports from plain arrays with
a fixed two-cycle sticky ack. `overruns bg=0 obj=0` was therefore a statement
about that model, not about the memory system. `verif/ssv_sdram_harness.sv` now
puts the real `rtl/mem/sdram.sv` and a chip model
(`verif/ssv_sdram_chip.sv`) behind `+REAL_SDRAM`, clocked at the true
clk_ram = 2 x clk_sys ratio.

The fault reproduced on the first run, on the *attract screen*:

| 20 frames, attract | overruns | non-black px |
|---|---|---|
| behavioural model | bg 0, obj 0 | 227,525 |
| real controller | bg 436, obj 3,735 | 198,582 |

13% of the picture missing, from the lightest load in the game.

## Fix applied: open-row tracking in the SDRAM controller

Every transaction used to be ACT -> tRCD -> READ -> auto-precharge. A row holds
512 words and consecutive graphics fetches along a scanline are 32 words apart,
so the same row was being re-opened constantly.

Reads now leave their row open and a later read into the same row skips
ACT + tRCD. Writes deliberately still auto-precharge: write recovery is where a
mistake corrupts memory rather than merely costing time, and writes are rare
outside ROM download.

Measured by `verif/tb_ssv_sdram_loopback.sv`:

| | before | after |
|---|---:|---:|
| p1 (4-word graphics) | 12 cycles | **9** |
| p0 / p4 (single word) | 9 cycles | **6** |

Result at attract: overruns bg 436 -> **0**, obj 3,735 -> **465**, and frame
CRCs become **byte-identical to the ideal-memory model**. The behavioural-model
CRCs are unchanged by the edit, so no existing gate moved.

## NOT fixed, and the important finding: the renderer is compute-bound

Gameplay still misses deadlines (obj 22,847 over 250 frames). `+DUMP_RENDERER_BUDGET`
on a missed line says why:

```
line_cycles=2488  plotcycles=1720 (69%)  rom_wait=127 (5%)  fetch=85  desc=46
```

**Only 5% of the scanline is spent waiting for memory.** The bulk is the object
renderer's own per-tile pipeline. Memory still decides the margin — the same
scene fits with ideal memory and does not with real memory — but no further
SDRAM work can recover more than a few percent.

Two things were measured and rejected rather than assumed:

- **Strict priority for the graphics port.** Cut gameplay misses by only 10%
  (22,847 -> 20,437). The renderer is not waiting on arbitration. Reverted
  rather than left in as an unproven change; the reasoning is recorded in the
  arbiter comment so it is not retried blindly.
- **Refresh contention.** ~1.6% of bandwidth. This also refutes the earlier
  working theory that refresh beating against the line rate explained the
  *drifting* bands; the drift comes from load and arbitration phase.

## Where the remaining work is

The object renderer spends ~20 clk_sys cycles per tile of which only 4 are the
actual four-pixels-per-cycle plotting. The rest is per-tile state-machine
overhead (TILE_CODE_ADDR -> WAIT -> ATTR_ADDR -> WAIT -> PREP -> FETCH_START ->
FETCH_WAIT). That pipeline, not SDRAM, is the next target.

`docs/SDRAM_GFX_REPACK_DESIGN.md` specifies a graphics repack (one 128-bit p2
fetch per tile row instead of two 64-bit p1 fetches). It is still worth doing —
it removes transactions, which removes both memory cycles and per-tile state
overhead — but on the evidence above it should be scoped as a renderer
optimisation, not as a bandwidth fix, and it is no longer the highest-value
change.

## How to reproduce

```bash
bash tmp/build_chk.sh /tmp/ssv-real          # builds with the harness
/tmp/ssv-real/tb_ssv_frame_crc \
  +MAINROM=sim_output/rom/maincpu.bin +SPRROM=sim_output/rom/sprites.bin \
  +verilator+seed+1 +verilator+rand+reset+2 \
  +REAL_SDRAM +SCENARIO=attract_idle +FRAMES=20 +IGNORE_OVERRUN \
  +FRAME_CRC=/tmp/real.crc
```

Drop `+REAL_SDRAM` for the ideal-memory reference. The two CRC files should now
be identical; before the fix they diverged at frame 1.
