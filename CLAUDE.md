# CLAUDE.md — MiSTer core project conventions

Persistent rules for this repo. These apply to every session, so they do not belong in a
per-bug prompt. Fill the `<FILL>` placeholders once; after that, per-bug prompts stay short.

---

## Repo layout

| Path | Contents |
|---|---|
| `<FILL>.sv` | Top-level `emu` module (MiSTer port contract) |
| `rtl/` | Core RTL — **this is where fixes normally belong** |
| `sys/` | Shared MiSTer framework — **do not modify** (see below) |
| `sim/` | Verilator harness, testbenches, replay inputs, golden frames |
| `docs/debug/` | Per-bug journals and artifacts |
| `<FILL>` | ROM location (not in repo) |

## Build and simulation commands

```bash
# Fast simulation build (default during debugging)
<FILL>

# Run, no waveform
<FILL>

# Run with focused FST trace
<FILL>

# Test suite
<FILL>

# Lint only (fast, no build)
verilator --lint-only -Wall --top-module emu <FILL sources>
```

**Never build the Quartus/RBF target during a debugging loop.** It is minutes-to-hours and
proves nothing about a logic bug. Synthesis is a separate, explicit step at the end.

## Verilator policy

- Preserve `obj_dir/`, generated files, and compiler caches. **Never run `clean`** unless
  there is concrete evidence of staleness or corruption — say what the evidence was.
- Always parallel and cached: `verilator -j $(nproc) --build-jobs $(nproc)`,
  `OBJCACHE=ccache`, `MAKEFLAGS=-j$(nproc)`.
- Default MCP flags for a normal run: `autoGenerateTestbench: false`,
  `enableWaveform: false`, coverage off.
- Use the existing full-core testbench. Only auto-generate a testbench if no usable one
  exists — say so explicitly if you do.
- Determinism flags on every run: `--x-assign unique --x-initial unique`, fixed
  `+verilator+seed+<N>`, fixed `+verilator+rand+reset+2`.
- Assertions on: `--assert`.

## MiSTer-specific rules

- **`sys/` is upstream** (MiSTer-devel `Template_MiSTer`). It is shared across every core and
  overwritten on framework updates. A fix that lives in `sys/` is almost always a
  misdiagnosis. If the evidence genuinely points there, stop and escalate rather than
  editing — that is a hard stop.
- Do not touch `.qsf`, `.sdc`, `files.qip`, or pin assignments during the simulation loop.
- Video output contract: `CLK_VIDEO`, `CE_PIXEL`, `VGA_R/G/B`, `VGA_HS/VS`, `VGA_DE`. A
  symptom that looks like a core bug may be a `CE_PIXEL`/`VGA_DE` alignment issue at the
  boundary — check the contract before diving into the pixel pipeline.
- ROM loading arrives via `ioctl_download` / `ioctl_addr` / `ioctl_dout` / `ioctl_wr` /
  `ioctl_index`. Wrong load offsets are a common source of fake bugs.
- OSD options come from `CONF_STR` into `status[]`. Record which bits were set for any
  reproduction — they change behaviour.
- Light gun / analog inputs come from the HPS via `sys/`; the core converts them to whatever
  the original hardware expected. Symptoms here are often an offset or scaling problem at
  that conversion, not in the game logic.

## Git hygiene

- One branch per bug: `fix/<short-bug-name>`.
- Instrumentation commits and functional-fix commits stay **separate**.
- Rejected hypotheses are reverted with `git checkout -- <file>`, never left commented out
  or behind a disabled flag.
- Never commit ROMs or large traces. Traces go in `docs/debug/<bug>/` and are gitignored.
- `git bisect run <detector script>` is the preferred first tool for any regression with a
  known-good commit.

## Evidence standards

- Every claim about behaviour cites a cycle number, frame number, file:line, or command
  output. "It looks like" is not evidence.
- A hypothesis is written down *before* the test that evaluates it, with its refutation
  condition stated up front.
- A regression test is not accepted until it has been **observed** to fail without the fix.
- No speculative functional RTL changes to "see if they help".

## Never

- Modify expected output or golden data to make a test pass.
- Suppress a warning or assertion instead of fixing its cause.
- Add arbitrary delays to fix a timing symptom.
- Stack multiple unproven fixes.
- Claim a fix without recorded, reproducible verification output.
