# Stream 3 brief — V60 opcode evidence, then area gating

Worktree: `D:\Arcade\AI\SVV-v60`  Branch: `work/v60-opcode-audit`
Forked from `main` at `c80d8f8`.

**Read `docs/DYNAGEAR_CORE_AUDIT.md` (ALM distribution section) first.**

---

## Why this stream exists

`s32_v60` is **19,917 ALMs — roughly 47% of the whole device**. Every other
block combined is under 40%. It is the only meaningful area lever left, and the
core is at 82% ALMs / 96% M10K, so headroom matters.

Four instruction groups are known-partial implementations:

| Opcode | Group |
|---|---|
| `0x59` | decimal |
| `0x5B` | bit string |
| `0x5D` | bit field |
| `0x5C` / `0x5F` | floating point (validated subset only) |

If Dyna Gear never executes them, they can be parameter-gated out. **But this
must not be done on a guess.** Only ~950 frames of one stage have ever been
simulated. Gating on attract-era evidence would silently break a later stage or
boss that nobody has run, and that failure would appear as a hang on hardware
weeks later.

## Task 1 — produce the evidence (this is the real deliverable)

Get a **full-playthrough** MAME 0.288 opcode hit list for `dynagear`.

- `tools/mame-capture-ssv-frames.lua` already exists and shows the harness
  pattern for driving MAME with a Lua script; extend that approach rather than
  starting from scratch.
- The output should be a histogram of executed V60 opcodes across as much of
  the game as can be reached — ideally more than one stage, plus a boss.
- Record how far the playthrough actually got. **An honest "covered stages 1–2
  only" is far more useful than an implied claim of full coverage**, because the
  gating decision depends entirely on coverage.
- Commit the hit list to `docs/` with the MAME version and the input script
  used, so it is reproducible.

## Task 2 — only if Task 1 justifies it

Parameter-gate the unused groups behind a localparam in `rtl/cpu/v60/s32_v60.sv`,
defaulting to **enabled**, so the release build is unchanged until someone
explicitly opts in and measures.

⚠️ **Coordinate before touching `rtl/`.** Stream 1 owns `rtl/` and is actively
changing it. Do Task 1 fully first; it needs no RTL edits at all. Flag when you
reach Task 2 so the branches can be sequenced.

## Task 3 — gameplay validation past 950 frames

Independent of the above and useful on its own. The current gate stops at 950
post-video-enable frames, which reaches the first controllable jungle window and
no further. Extend `verif/scenarios/dynagear/` with a longer input script and
report how far it gets before anything diverges, hangs, or overruns.

`verif/tb_ssv_frame_crc.sv` takes `+SCENARIO=`, `+FRAMES=`, `+SOAK_FRAMES=`,
`+CYCLES=` and `+REQUIRE_GAMEPLAY`. Note the default `+CYCLES=200000000` only
reaches ~216 frames; budget roughly 805k `clk_sys` cycles per 60 Hz frame plus
~26 M of boot.

## Scope

- Task 1 and 3 touch `tools/`, `verif/scenarios/`, `docs/` — no conflict with
  stream 1.
- **Do not use Quartus or the MiSTer.** Stream 1 owns both. Quartus refuses to
  run concurrently anyway (`build-ssv.ps1` aborts if any `quartus*` process is
  live, and the QSF pins `NUM_PARALLEL_PROCESSORS 1`).

## Environment notes

- Verilator is in **WSL** at `/usr/bin/verilator`. The repo's `verif/run_*.sh`
  call a `verilator-safe.exe` Windows launcher that **stalls** under a
  non-interactive nested WSL shell — invoke `/usr/bin/verilator` and the built
  binaries directly.
- ROM images are gitignored and absent from this worktree. Copy or symlink
  `sim_output/rom/{maincpu.bin,sprites.bin,samples.bin}` from `..\SVV`.
- MAME reference material and prior traces are under `sim_output/diff/` in the
  main worktree (also gitignored).

## Definition of done

- A committed, reproducible opcode hit list with **explicitly stated coverage**.
- A clear recommendation: which groups are provably unused, which are not, and
  what the residual risk is.
- Task 3: a longer scenario committed, with an honest report of how far the core
  gets and what breaks first.
