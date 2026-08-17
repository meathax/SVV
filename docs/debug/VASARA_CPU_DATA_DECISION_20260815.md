# Vasara CPU-data decision record — 2026-08-15

## Observation

The first strict `cpu_data` mismatch in the post-entry frame-259–261
projection is ordinal 68. The address and PC match, but the byte value and
captured raster phase do not:

| field | MAME 0.289 | RTL |
|---|---:|---:|
| address | `0x00330E` | `0x00330E` |
| read data | `0x0001` | `0x0000` |
| byte enable | `0b001` | `0b001` |
| device | work RAM (2) | work RAM (2) |
| PC | `0x00F021A2` | `0x00F021A2` |
| post-entry frame | 259 | 259 |
| scanline | 0 | 240 |

The first 68 projected transactions match exactly. The candidate projection is
derived from the raw fix5 trace by selecting mainbus events whose RTL frame is
259–261 and re-indexing only that diagnostic copy; the raw receipt and trace
remain untouched.

## Evidence

* Two cold Vasara RTL captures are byte-identical for receipt, frame stream,
  state hashes, PCM and native PPM; both complete 381 frames with 120 neutral
  frames after the gameplay marker.
* Two cold MAME Vasara barrier captures and two cold strict `cpu_data` windows
  are byte-identical under the pinned MAME 0.289 executable and journal.
* Native frame CRCs show an initial one-frame capture offset: RTL frame 1
  equals MAME frame 0, and the same offset persists through the gameplay
  marker. This is diagnostic evidence of capture/epoch alignment, not an
  acceptance resynchronization.

## Hypotheses and falsification

1. **Input or RAM initialization mismatch.** Not selected: the prefix through
   ordinal 67 matches and both sides use the same immutable journal.
2. **Frame/scanline sampling phase.** Plausible: the first bad value is at the
   same PC/address while MAME samples at scanline 0 and RTL at scanline 240,
   and the native frame stream has a one-frame initial offset.
3. **Incorrect Vasara work-RAM behavior.** Unproven: the value difference may
   be causal, but no equivalent instruction-to-memory association has been
   captured yet.

## Selected explanation

None. Keep this as Vasara's sole active diagnostic target; do not change shared
V60, input, RAM or video timing RTL while the Dyna Gear divergence remains the
earliest unresolved shared-CPU target.

## Smallest change

None. Only the strict projection and durable decision record were added.

## Next observation

Capture a narrow Vasara instruction/IRQ and work-RAM context around ordinal 68
with equivalent event anchors. If the same address/value mismatch survives
frame-phase alignment, promote it to a causal RTL investigation.
