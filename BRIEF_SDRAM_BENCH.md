# Stream 2 brief — put the real SDRAM controller in front of the renderer

Worktree: `D:\Arcade\AI\SVV-bench`  Branch: `work/sdram-bench`
Forked from `main` at `c80d8f8`.

**Read `docs/DYNAGEAR_HW_RENDER_FIX_PLAN.md` first.** This brief is Phase 3.1 of
that plan.

---

## Why this stream exists

Two real defects shipped to hardware in one day, and **simulation could not see
either of them**, for the same reason both times:

1. The vblank descriptor build could overrun and latch the display dead
   permanently (fixed in `bc4b6ab`).
2. The background renderer latched the object renderer's tile data whenever a
   line missed its deadline (fixed in `c80d8f8`) — this is what painted large
   parts of the level as white cross-hatch boxes on the board.

Both need **a scanline to miss its rendering deadline** before they can happen.
No bench can produce that, because every full-core testbench drives the core
through a hand-written per-port SDRAM stub in `verif/tb_ssv_frame_crc.sv` that
acks each port independently after one cycle. The real `rtl/mem/sdram.sv`
serialises all six ports through one chip, with tRCD, CAS latency, a two-cycle
ack stretch, and refresh stalls.

Result: `overruns bg=0 obj=0` across all 950 frames in sim, while the board
visibly misses deadlines constantly.

Until this gap closes, this whole class of defect can only be found by
deploying to hardware and looking at the screen. That is the single biggest
verification weakness in the project.

## Goal

Make `tb_ssv_frame_crc` (and ideally the other full-core benches) able to run
against the **real** `rtl/mem/sdram.sv` plus a behavioural SDR SDRAM chip model,
so that renderer deadline misses happen naturally and are regressible.

## Scope — stay inside `verif/`

**Do not modify `rtl/`.** Stream 1 owns it and is actively changing it. If you
believe you have found an RTL bug, write it up in `docs/` and say so; do not fix
it here. That keeps merges to `main` clean, because this branch should only ever
touch `verif/` (plus a new doc).

## Suggested approach

1. **Write a behavioural SDR SDRAM chip model** (`verif/sdram_chip_model.sv`).
   16-bit, CL2, four banks, auto-precharge on A10. It must decode
   `{nCS,nRAS,nCAS,nWE}` into NOP/ACT/READ/WRITE/PRE/REF and drive `SDRAM_DQ`
   with a CAS-2 pipeline. `rtl/mem/sdram.sv` is the spec — read its header
   comment and state machine carefully, especially the **request contract**:
   *one transaction per req RISING EDGE*, ack stretched to two `clk_ram` cycles.

2. **Populate it with the same data the current stub returns.** This is the
   fiddly part and the most likely source of false failures. The stub in
   `tb_ssv_frame_crc.sv` computes the Q0/Q1 sprite interleave on the fly
   (`packed_code`/`packed_row`/`raw_q0_index`); the chip model needs that
   layout materialised in memory instead, exactly as `rtl/mem/ssv_rom_loader.sv`
   would write it. Consider driving the real loader to fill the model, which
   also gets the loader covered.

3. **Make it selectable**, e.g. `+SDRAM_REAL`. Default must stay on the existing
   stub so that `sim_output/diff/rtl_final96_gameplay_frames.crc` remains a
   valid golden — do not invalidate it.

4. **Expect the CRC to differ under `+SDRAM_REAL`** and that is fine: the CPU
   runs at a different rate relative to the raster, so game state legitimately
   diverges. The golden is only meaningful for the default model. Judge the
   real-SDRAM mode on assertions (no ownership violations, no hangs, non-black
   pixels, sane overrun counts), not on CRC equality.

5. **Report the numbers that matter:** how many `bg`/`obj` line-deadline
   overruns occur per frame with realistic SDRAM, and the p1 service latency
   distribution. Stream 1 needs those to decide whether SDRAM arbitration
   priority or the bucket-loop halving is the right next fix.

## Interim tool you can lean on

`+P1_LATENCY=N` already exists on `main` (added in `c80d8f8`). It injects N
cycles of delay before each GFX-fetch ack — a crude way to starve p1 and induce
overruns. Useful for sanity-checking your chip model produces comparable
pressure, and as a fallback if the full model proves too slow to run 950 frames.

## Environment notes

- Verilator lives in **WSL** at `/usr/bin/verilator` (5.032). The repo's
  `verif/run_*.sh` scripts call a `verilator-safe.exe` Windows launcher that
  **stalls** when invoked from a non-interactive nested WSL shell — call
  `/usr/bin/verilator` and the built binaries directly instead.
- `tb_ssv_frame_crc` defaults to `+CYCLES=200000000`, which only reaches ~216
  post-VE frames. A 950-frame soak needs about `+CYCLES=900000000`.
- ROM images are gitignored and will **not** be in this worktree. Copy or
  symlink them:
  `sim_output/rom/{maincpu.bin,sprites.bin,samples.bin}` from `..\SVV`.
- `/tmp` in WSL does not survive a WSL restart. Write CRC streams there for
  speed (writes to `/mnt/d` can truncate), but copy anything you care about out.

## Definition of done

- A full-core bench runs against `rtl/mem/sdram.sv` + the chip model.
- With it, a run **reproduces line-deadline overruns naturally**, with no
  `+P1_LATENCY` crutch.
- Reverting `c80d8f8`'s ack fix in a scratch copy makes
  `bg_ack_while_obj_owns` non-zero under the real model. That proves the bench
  would have caught the bug — which is the whole point of this stream.
- Default (stub) mode still produces the byte-identical golden CRC.
