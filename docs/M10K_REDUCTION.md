# Block RAM reduction pass

Block RAM is the binding resource on this part: **530 of 553 M10K (96%)** against
83% ALM occupancy. This pass worked from the Fitter RAM Summary in
`output_files/Arcade-SSV.fit.rpt`, not from guesses.

## Where the blocks actually go

| M10K | bits | instance | verdict |
|---:|---:|---|---|
| 256 | 2,097,152 | `sprite_ram` 131072 x 16 | correct size, fully used |
| 64 | 524,288 | palette `even_words` 32768 x 16 | correct, all bits live |
| 64 | 524,288 | palette `odd_words` 32768 x 16 | **half wasted — fixed** |
| 64 | 524,288 | `work_ram` 32768 x 16 | correct size |
| 21 | 161,280 | `line_entries` 23040 x 7 | 20 is the floor; near-optimal |
| 16 + 14 | 162,816 | `descriptor_cache_hi/lo` | **split backfired — reverted** |

Everything else is `sys/` framework (ascal, osd, shadowmask), ~30 blocks.

## Sizes checked against MAME first

Before optimising anything, the three big RAMs were checked against
`src/mame/seta/ssv.cpp`:

```
map(0x000000, 0x00ffff)  mainram    64 KB   -> work_ram   32768 x 16  correct
map(0x100000, 0x13ffff)  spriteram 256 KB   -> sprite_ram 131072 x 16 correct
map(0x140000, 0x15ffff)  palette   128 KB   -> 2 x 32768 x 16         correct
```

None is oversized, so no saving was available from simply shrinking them.

## Change 1 — palette odd bank 16 bits -> 8 (saves 32 blocks)

An SSV palette entry is `00RRGGBB`: the even word holds GG BB, the odd word
holds `00 RR`. Only the red byte reaches the screen — `video_rgb` uses
`odd_video_q[7:0]` and always did. The other eight bits are SSV's undefined
field and were costing 32 M10K to store.

Storing 8 bits instead of 16 gives exactly `32768 x 8 = 262,144` bits,
`262144 / 8192 = 32` blocks, down from 64.

**The trade, stated honestly:** a CPU read of an odd palette word now returns
zero in the undefined byte instead of the value last written. Measured over 250
gameplay frames:

```
PALETTE_ACCESS cpu_reads=0 cpu_writes=94008
```

Dyna Gear writes the palette 94,008 times and never reads it once, so nothing
observes the difference. If a future title reads palette RAM back, widen the
bank again — the cost is exactly those 32 blocks.

`s32_big_dpram` gained `DATA_WIDTH`/`BE_WIDTH` parameters defaulting to 16, so
every other instance is untouched, and its behavioural byte-enable logic is now
width-generic rather than assuming two lanes.

## Change 2 — revert the descriptor-cache split (saves 8 blocks)

Commit `6800e5f` split `descriptor_cache` from one 1536 x 128 array into 53-bit
and 75-bit halves to steer M10K packing, predicting 9 blocks apiece for 18
total against the 22 the single array measured.

The Fitter RAM Summary from the build that contains that change reports
**16 + 14 = 30** — eight blocks *worse* than the array it replaced. The
prediction did not survive contact with the fitter, so it is reverted with the
measurement recorded in the code so it is not retried blindly.

## Rejected, with the reason

- **Shrink `sprite_ram`.** The game walks the entire 256 KB:
  `SPRITERAM_USE cpu_writes=1199055 highest_word=0x1ffff of 0x1ffff`.
- **Shrink `CACHE_ENTRIES`.** Peak occupancy is 1519 of 1536 — no headroom.
- **Shrink `LINE_SLOTS`.** `line_entries` at 161,280 bits already sits one block
  above the 20-block floor, and observed peak line occupancy is 90 of 96.
- **Move a RAM to SDRAM.** Every candidate is latency-critical on the render
  path that was just optimised; trading M10K for fetch latency would undo it.

## Expected result

530 -> **~490 of 553 (89%)**, freeing ~40 blocks.

**Not confirmed by a fit** — this pass was run under an explicit no-Quartus
constraint. Both changes are verified pixel-identical (`coin_start_p1_gameplay`,
250 frames, frame CRCs byte-identical), and change 1's saving is exact
arithmetic, but the block counts want a fit report to confirm.
