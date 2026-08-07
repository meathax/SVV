# CLAUDE.md — MiSTer core project conventions

The repository-level `AGENTS.md` and `core-debug.toml` are the authoritative
current contract. This SSV project has one universal `Arcade-SSV` revision and
one `SSV.rbf`; game-specific behavior is selected by the MRA descriptor at
runtime. Any older placeholder or Dyna Gear-only note below is historical and
must not override that contract.

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

## Resource optimization techniques

### DSP block reduction: narrow multiply operands to natural width

Quartus synthesizes each `*` operator to a DSP block matching the declared width of both operands, even when the operands' actual value ranges are far narrower. **Redundant sign- or zero-extension before multiply silently causes Quartus to split one logical multiply across two physical DSP blocks** (e.g., "18x18 plus 36" + companion "Two Independent 18x18"), with no warning at all.

**Fix:** narrow each operand to its analytically-derived natural bit width, nothing else. This is a pure width change with zero value change when the analysis is right — verify algebraically before committing.

**Example:** ES5506 voice engine filter (`rtl/audio/ssv_es5506_voice.sv`, 2026-08-06):
- `lp()`: two 18-bit signed values subtracted fit in 19 bits (range ±262142 < signed 19-bit's ±262144); narrowed from re-sign-extended 32-bit, freeing one DSP block per multiply.
- `hp()` and `lerp()`: similar width-only narrowing, each recovered one DSP block.
- **Measured result:** module DSP usage dropped from 63 to 57 blocks (synthesis stage estimate), zero RTL restructuring, zero added pipeline stages, exact numeric value preserved.

**Process:**
1. Identify a multiply where worst-case setup/hold fails by < 2 ns or DSP usage is critical.
2. Measure the declared operand widths in the Fitter report (`grep -n "DSP Block Details" output_files/*.fit.rpt`); a logical multiply appearing twice means Quartus cascaded two physical blocks.
3. Compute the minimum required bit width for each operand algebraically (e.g., for two N-bit signed values subtracted, result needs exactly N+1 bits to never overflow).
4. Replace the operand with one narrowed to that natural width **without adding or removing `$signed()` / `$unsigned()` casts** — preserve the original arithmetic-mode structure exactly.
5. Verify via `quartus_map`-only compile (seconds, not minutes): `Implemented N DSP elements` should drop in seconds vs. the full ~30-minute flow.

**Caveat:** do not change operand signedness or accidentally alter behavior while narrowing. Confirm the narrowed operand still carries the identical numeric value.

### M10K RAM inference: use Altera's literal true-dual-port write-first template

Quartus 17 has a narrow "sweet spot" for M10K inference on dual-port RAM with write-first behavior. **Arrays that don't match Altera's exact documented template silently remain in logic** (costing thousands of ALMs per KiB) with no warning or diagnostic until a real Fitter run. Even seemingly-correct restructurings still fail if intermediate signals (delayed copies, multiplexed outputs) break the inference pattern.

**Correct pattern:** one `always @(posedge clk)` block per port, containing **only** the array write, the same-cycle write-first bypass, and the unconditional registered read, driving output `q_*` directly.

**Example:** hiscore RAM (`rtl/hiscore.v`, 2026-08-06):
- **Wrong:** unconditional read + delayed write-first bypass (`we_a_d` / `d_a_d`) in one or even split blocks, feeding `q_a` through a downstream `always @(*)` mux. Fitter diagnosis: "uninferred due to asynchronous read logic" despite `(* ramstyle = "M10K" *)`.
- **Right:** port A's block contains only write-first (`if (we_a) ... else ...`) + direct `q_a` assignment; port B identically structured. **This is what Altera's M10K NEW_DATA mode implements in hardware**, so it's the best-supported shape.
- **Result:** array now infers directly into M10K blocks instead of spilling into 3,800+ register ALMs.

**Process:**
1. If synthesis `grep "uninferred due to" <build>/quartus.log` or Fitter report shows a `ramstyle` array refusing to infer, suspect the pattern.
2. Read Altera's true-dual-port write-first template from vendor docs or existing working cores (e.g., jotego/jtcores reference).
3. Restructure to match: **one always block per port, one unconditional read in `else`, write-first in `if`, q assigned directly — nothing else in that block**.
4. Verify via a real Fitter run; check the per-entity register count in `output_files/*.map.rpt` — if the module's own register count was close to the array's bit count, it was in logic; after the fix, it should match only the non-array logic.
5. Document the pattern and which arrays use it, so future readers don't accidentally "restructure" it into logic again.
