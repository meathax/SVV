# Dyna Gear SSV MiSTer Core Audit

Audit date: 24 July 2026  
Repository: `D:\Arcade\AI\SVV`  
Audited branch/commit: `main` at `b0fa575` (`Cache SSV sprite lists by scanline`) plus an extensive uncommitted working tree  
Target: Sammy/Seta/Visco SSV, Dyna Gear, MiSTer Cyclone V

## Executive verdict

The project is a substantial, synthesizable SSV bring-up, but it is **not yet a
working Dyna Gear core**.

The strongest verified result is that the V60 reaches the same early program
states and writes as MAME in Verilator, and the current video pipeline produces
non-black pixels in a direct `ssv_core` simulation. The current Quartus build
fits the MiSTer FPGA and meets the reported timing constraints.

The strongest contrary result is physical hardware: MiSTer loads
`SSV_20260724` and `Dyna Gear.mra`, but the captured output is completely black.
No attract mode or gameplay has been observed. The current wrapper resets the
video timing together with the rest of the core, so its intended startup colors
cannot diagnose a ROM-loader, SDRAM-ready, reset-release, or downstream-video
failure. The first failing physical-hardware boundary is therefore still
unknown.

Audio is not implemented beyond the ES5506 host-register file. Both PCM outputs
are hardwired to zero. Controls exist, but the DIPs are hardcoded and the full
input set has not been validated on hardware.

Estimated completion against the goal of a fully working, release-quality Dyna
Gear core:

| Area | Estimated completion | Confidence |
|---|---:|---|
| V60/early boot and SSV bus behavior | 85% | High for the traced early path; low for unexecuted gameplay paths |
| Video feature implementation | 70% | Medium |
| Video validation on real hardware | 25% | High that current output is black |
| ROM packaging and MRA mapping | 90% | High |
| Controls and DIPs | 40% | Medium |
| ES5506 audio | 15% | High |
| Build, release, and reproducibility | 35% | High |
| **Overall fully working-core goal** | **about 40%** | Medium |

The percentage is deliberately based on the final playable goal, not on lines
of RTL written. A silent simulation scaffold would score higher, but it is not
the requested deliverable.

## Severity-ranked findings

### Critical: physical MiSTer output is black

On the final audit check, MiSTerClaw reported:

```text
Core: SSV_20260724
Game: /media/fat/_Arcade/Dyna Gear.mra
```

The screenshot was uniformly black. This confirms the intended core and MRA
were selected, but does not prove that the ROM stream completed or that the core
left reset.

The deployed ROM exists at:

```text
/media/fat/games/mame/dynagear.zip
```

The deployed MRA correctly uses:

```xml
<rom index="0" zip="dynagear.zip">
```

MiSTer searches the configured MAME ROM paths for this archive. The previous
`games/mame/dynagear.zip` path and invalid `md5="none"` form are no longer
present.

### Critical: startup diagnostics are held in reset

The top-level wrapper defines:

```systemverilog
wire video_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire core_reset = video_reset | ioctl_download | ~rom_loaded | ~sdram_ready_sys;
```

The entire `ssv_core`, including its timing generator and pixel clock-enable
generation, receives `core_reset`. The wrapper then selects startup colors for
download, ROM-not-loaded, and reset states. Because timing and pixel activity
are also stopped in those states, these colors are not a reliable visible
diagnostic.

Consequences:

- Black cannot distinguish a missing ROM from a stuck SDRAM-ready signal.
- Black cannot distinguish a reset failure from a running core whose video is
  disabled.
- The existing color-state logic creates the appearance of observability
  without ensuring a valid output raster.
- Remote testing cannot read `LED_USER`, which is the only other direct
  `rom_loaded` indication.

This is the first issue to correct. Hardware debugging should not continue as a
sequence of blind RBF builds.

### Critical: game audio is absent

In `rtl/ssv_core.sv`, the final output logic contains:

```systemverilog
audio_l = 16'sd0;
audio_r = 16'sd0;
```

The project has a synthesizable ES5506 register interface, but not the voice
scheduler, sample-ROM fetch, accumulators, looping, envelopes, filters, channel
routing, mixer, or PCM output path needed by Dyna Gear.

The JTSFTM `sftm5506` RTL is a useful architecture/reference source but is not a
drop-in solution: it implements only four voices in its present form and its
own repository describes it as incomplete. MAME's `es5506.cpp` and
`vgsound_emu` should remain the behavioral oracles.

The current fit uses 552 of 553 RAM blocks. Audio cannot safely be added by
replicating large per-voice structures in block RAM. The implementation needs a
time-multiplexed arithmetic pipeline and a deliberate memory/resource plan,
preceded by reduction or repacking of existing RAM use.

### High: the successful real-ROM simulation bypasses the failing integration

The 60-million-`clk_sys` regression passed:

```text
PASS tb_ssv_realrom_video p1=707008 active=6032207 nonblack=118457 pc=00f10575
```

This is meaningful evidence that the direct core can execute and draw. It is
not an end-to-end MiSTer boot test. The testbench instantiates `ssv_core`
directly and supplies behavioral memory ports. It bypasses:

- the MiSTer `emu` wrapper;
- HPS `ioctl` ROM download;
- `ssv_rom_loader` integration at the top level;
- the physical SDRAM controller and arbitration;
- PLL lock and reset synchronization;
- the MiSTer video output path;
- the MRA parser and real archive loading.

At approximately 48.3 MHz, 60 million system clocks are about 1.24 seconds.
This is not long enough to claim attract-mode operation.

### High: differential traces validate only the available early trace

The current comparison tools report:

```text
PASS: 1072678 available RTL complete-state hashes match MAME
PASS: 549383 available RTL writes match MAME
```

This is excellent evidence for the V60 and bus behavior represented in those
traces. It does not prove:

- execution after the captured RTL trace ends;
- attract mode;
- full interrupt timing;
- complete sprite/background frame equivalence;
- input-dependent/gameplay code paths;
- ES5506 behavior;
- MiSTer wrapper and SDRAM integration.

The method is correct and should continue, but the trace horizon and compared
signals must expand until at least one complete attract loop is matched.

### High: V60 opcode groups remain explicitly unimplemented

`rtl/cpu/v60/s32_v60.sv` still reports unimplemented `59`, `5B`, `5D`, and
floating-point subgroups. The current trace has not required all of them. These
are latent failures until a complete attract and gameplay trace demonstrates
that Dyna Gear never executes them, or the needed operations are implemented
and tested.

### High: release readiness is not enforced by deployment

`tools/report-quartus.ps1` defaults to the copied System 32 revision:

```powershell
[string]$Revision = "Arcade-SegaSystem32"
```

Running it without an explicit revision therefore fails to audit the SSV build.
With `-Revision Arcade-SSV`, it reports the current build as ready. This default
is a release-tooling defect and risks checking the wrong product.

`tools/deploy-ssv.ps1` hashes and uploads artifacts but does not require a
successful current fit/timing report before deployment. A manually copied or
stale RBF can therefore be deployed without a release gate.

Required behavior:

1. SSV must be the default/only revision for SSV scripts.
2. Deployment must call the readiness checker with `-RequireReady`.
3. The promoted RBF must be produced by the exact audited source commit.
4. The manifest must record source commit, dirty-state policy, tool version,
   report hashes, RBF hash, and MRA hash.

### High: the audited source is not reproducible

The repository is on `main` at `b0fa575`, but the working tree contains many
modified and untracked source, verification, documentation, and tool files.
The deployed RBF therefore cannot be reconstructed from the named commit
without capturing all uncommitted state.

ROMs, generated RBFs, simulator output, and scratch traces are correctly ignored
and no ROM is tracked. That legal/repository hygiene is good. The source state,
however, needs to be frozen into reviewable commits before further release
claims.

### Medium: DIPs are hardcoded

The top-level connects:

```systemverilog
.in_dsw1(16'hffff), .in_dsw2(16'hfffd)
```

There is no complete MiSTer menu mapping for Dyna Gear's DIP switches. Controls
are wired, but coin/start/player buttons, service/test behavior, DIP defaults,
and reset-on-setting-change still require MAME-referenced simulation and
physical-controller validation.

### Medium: timing constraints contain stale top-level names

`SSV.sdc` attempts to constrain `CLK_50M`, `RESET`, and `HPS_BUS` as top-level
ports. The compiled entity is `sys_top`, whose board clock is
`FPGA_CLK2_50`; the wrapper-level port patterns do not all match at that
hierarchy. Quartus warns that the `CLK_50M` clock target is ignored.

The framework SDC creates the actual top clocks, and the timing report is
positive, so this is not proof of an unconstrained design. It is still unsafe
constraint hygiene. Every exception and multicycle path must be checked with
Quartus reports showing:

- the intended objects matched;
- no critical clocks are unconstrained;
- the V60 multicycle exception applies only to legitimate clock-enabled
  register-to-register paths;
- there are no broad false paths hiding functional timing.

### Medium: FPGA memory is effectively exhausted

Current fit summary:

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| ALMs | 28,409 | 41,910 | 68% |
| Registers | 18,142 | — | — |
| Block memory bits | 4,392,722 | 5,662,720 | 78% |
| RAM blocks | 552 | 553 | 100% rounded |
| DSP blocks | 39 | 112 | 35% |
| PLLs | 3 | 6 | 50% |

Only one RAM block remains. The design has useful ALM and DSP headroom, but the
audio implementation and any additional frame/trace buffers need a new memory
allocation strategy.

### Medium: video timing is not hardware-verified

`rtl/ssv_video_timing.sv` documents that exact board sync widths were not
available from MAME's `set_raw` definition and describes the chosen pulses as
suitable for MiSTer. This may be acceptable for output compatibility, but it is
not yet validated against SSV hardware or a known-good reference capture.

Visible geometry, blanking, IRQ positions, field behavior, and pixel clock need
to be treated separately from the arbitrary placement of MiSTer-compatible sync
pulses.

### Medium: one legacy renderer regression fails

A clean focused Verilator rebuild from the current sources produced:

```text
PASS bg_renderer
PASS cached_sprite_renderer
PASS es5506_regs
PASS gfx_row_decode
PASS gfx_row_fetch
PASS irq
PASS line_buffer
PASS line_buffer4
PASS palette_ram
PASS rom_loader
PASS sprite_decode
FAIL sprite_renderer: plot metadata mismatch
PASS video_timing
```

The failing `ssv_sprite_renderer.sv` is not included by `files.qip`; the release
uses `ssv_cached_sprite_renderer.sv`, whose test passes. This is not evidence
that the synthesized renderer fails. It is evidence that a dead/legacy module
and test remain in the tree. They should either be removed with provenance
preserved, or clearly marked and excluded from the release regression.

### Low/medium: lint debt obscures future defects

Full-core Verilator lint succeeds but emits 191 warnings:

| Warning class | Count |
|---|---:|
| WIDTHEXPAND | 80 |
| UNUSEDSIGNAL | 59 |
| WIDTHTRUNC | 16 |
| PINCONNECTEMPTY | 9 |
| UNUSEDPARAM | 9 |
| BLKSEQ | 8 |
| MULTIDRIVEN | 5 |
| VARHIDDEN | 4 |
| CASEOVERLAP | 1 |

The `MULTIDRIVEN` warnings are primarily caused by a shared loop variable in
the four-bank line buffer, not multiple functional drivers. The V60 case
overlap appears to be intentional ordering of explicit branches before a broad
group. These should still be rewritten or locally waived with explanations.

The ROM loader's 27-bit-to-24-bit sprite-offset truncation is safe for the
current stream range, but it should be explicit and asserted so a future layout
change cannot silently wrap an address.

The complete log is:

```text
sim_output/audit/verilator-lint.log
```

### Low/medium: documentation and provenance lag the implementation

The README and architecture documents still say that physical testing has not
occurred, while a real MiSTer black-screen result now exists. The frozen-video
issue contains older artifact hashes. The provenance record identifies System
32 and MAME sources conceptually but does not pin every imported source to an
exact upstream commit.

All copied/adapted RTL must record:

- upstream URL;
- exact commit;
- original path;
- license;
- local changes;
- whether code or only behavior was used.

## ROM and MRA audit

MAME's Dyna Gear definitions in
`D:\Arcade\AI\MAMESOURCE\mame\src\mame\seta\ssv.cpp` were used as the
authoritative region/interleave definition.

The MRA stream was independently assembled and verified:

| Stream section | Bytes | MD5 | SHA-256 |
|---|---:|---|---|
| Main program | 1,048,576 | `c5aaace0c7acaab5558616cd44407110` | `c29d3bf...c66289` |
| Sprites/graphics | 12,582,912 | `4873cfbb98e06b74a47dff0c664463ec` | `5738ad3a...eab4f` |
| Samples | 4,194,304 | `566311a64570e1fdf13601d059d6c2eb` | `2f187215...d31aa` |
| **Complete stream** | **17,825,792** | `1b3c7ce30ece381d16a5a4fb8bbc90e4` | `d86207cf...55d684` |

Only shortened SHA-256 values are shown above for the component streams because
the full verification output remains in the audit logs. The deployed artifact
hashes are:

```text
RBF SHA-256:
B187887A89D832F8BE75D8448CD92DF3FB0C9DD50426280E473B36B3B4CB2318

MRA SHA-256:
C6472457E98EB0C524E82BC1138B1DF5B983A6F27E7AA58E8E1FB872725372BB

ROM ZIP SHA-256:
E0088D91679FEAFF026DE267919700C86243C3823F5A1FB55894E1DBC4F7109D
```

The MRA mapping is no longer the leading suspect. The loader/top-level
handshake on hardware remains unproven.

## Quartus result

With the correct `Arcade-SSV` revision specified, the audit script reports:

- map successful and current;
- fit successful and current;
- reported worst timing is positive, including a 0.086 ns worst hold slack;
- `ReadyToDeploy = true`.

This proves that the current artifact fits and that Quartus reports timing
closure under the applied constraints. It does not prove functional operation,
correct constraint coverage, or source/artifact reproducibility.

The flow previously experienced a Quartus STA process failure after printing
positive slacks. Release automation must distinguish a complete successful STA
process from useful partial report output and must never promote an RBF after a
failed required stage.

## Tooling observations

### Verilator

Verilator simulation and lint are operational. Two Windows/MSYS2 integration
issues were found:

- FST-enabled builds fail because `lz4.h` is not available.
- Native linking with the installed Verilator library requires
  `_GLIBCXX_USE_CXX11_ABI=0` to match the library ABI.

These environment requirements should be encoded in one checked-in regression
script so clean rebuilds do not depend on shell history.

### GTKWave MCP

The GTKWave connection is working, but its current signal extraction does not
provide useful name-based inspection of the generated traces:

- FST extraction reports that non-VCD input is unsupported.
- VCD extraction returned identifiers rather than usable hierarchical signal
  references.

This is a tooling/parser limitation, not a pass result. Waveform-based
differential debugging should use a generated VCD subset with stable signal
names, or a scripted trace-to-CSV path, until interactive extraction is
reliable.

### MiSTerClaw

MiSTerClaw is working for status and screenshot capture. It confirms the core
and MRA selection and the black output. It does not currently expose the FPGA
LED, loader state, SDRAM-ready state, CPU PC, or internal video enable.

## Subsystem status matrix

| Subsystem | Implemented | Simulation evidence | Physical MiSTer evidence | Verdict |
|---|---|---|---|---|
| MRA/ROM interleave | Yes | Independent byte/hash assembly | Archive present and MRA selected | Strong |
| HPS ROM loader | RTL present | Focused loader test passes | Completion unknown | Needs observability |
| SDRAM integration | RTL/framework present | Behavioral ports used in core test | Ready/traffic unknown | Unproven |
| V60 CPU | Substantial, some groups missing | Early trace/hash/write match | Execution unknown | Strong early, incomplete overall |
| SSV memory map/IRQ | Substantial | Focused and trace tests pass | Unknown | Strong in simulation |
| Background renderer | Present | Focused test and real-ROM pixels | Black output | Integration unproven |
| Sprite renderer | Cached renderer present | Cached test passes | Black output | Integration unproven |
| Palette/compositor | Present | Focused tests pass | Black output | Integration unproven |
| Raster timing | Present | Focused test passes | No visible raster | Hardware unproven |
| Inputs | Basic wiring present | Limited | Not validated | Incomplete |
| DIPs | Hardcoded | N/A | Not configurable | Incomplete |
| ES5506 registers | Present | Focused MAME-derived test passes | Unknown | Partial |
| ES5506 voices/mixer | Absent | None | Silent by construction | Missing |
| Build/fit | Present | N/A | RBF loads | Fits, process needs gates |
| Attract/gameplay | Not demonstrated | Trace too short | Not seen | Failing final goal |

## Required implementation order

### 1. Make the first hardware boundary observable

Build a diagnostic wrapper that keeps a valid raster alive whenever the PLL is
locked, independently of game-core reset. Display a small status overlay or
unambiguous full-screen state code containing at least:

- PLL locked;
- `ioctl_download`;
- ROM byte count and expected terminal address;
- `rom_loaded`;
- SDRAM initialization/ready;
- `core_reset`;
- V60 reset release;
- low bits of V60 PC or a heartbeat counter;
- `video_enable`;
- frame counter;
- main/program and graphics read activity;
- loader/controller error or timeout.

The normal game core can remain reset while this diagnostic timing generator
runs. This single build should distinguish loader, SDRAM, CPU, and video
failures without guessing.

### 2. Exercise the real integration in simulation

Add a top-level simulation that drives the same `ioctl` byte stream generated
from the MRA, instantiates the actual ROM loader and SDRAM arbitration logic,
waits for the same reset sequence, and checks:

1. exact downloaded byte count;
2. every region's first/last address and checksum;
3. `rom_loaded` assertion;
4. SDRAM-ready behavior;
5. core reset release;
6. first V60 fetch and expected early PCs;
7. first video-enable write;
8. first non-black visible pixel.

The behavioral SDRAM storage can remain a model, but the controller-facing
request/acknowledge behavior and all wrapper state must be exercised.

### 3. Extend MAME/RTL differential testing to attract mode

Use one deterministic input and DIP configuration. Compare in increasing cost:

1. V60 PC/opcode and complete-state hashes;
2. memory and I/O reads/writes;
3. interrupt request, acknowledge, vector, and scanline;
4. palette writes;
5. background/tile/sprite descriptors;
6. per-scanline object lists;
7. palette-index frame CRCs;
8. final RGB frame CRCs and PNG differences.

Run until MAME and RTL complete at least one matching attract loop. On the first
divergence, reduce to the earliest causal bus/IRQ/render event, fix it, add a
regression, and repeat. Do not debug from a late screenshot if an earlier
machine-state divergence exists.

### 4. Close video on real hardware

Once the diagnostic build shows CPU and frame progress:

- verify actual pixel clock and sync geometry;
- verify `video_enable` is written;
- compare frame/scanline signatures with Verilator;
- validate graphics SDRAM addresses and data;
- validate output color width/order;
- test rotation/aspect behavior through the MiSTer video chain.

An attract-mode screenshot is a milestone, not the final video sign-off.

### 5. Complete controls and DIPs

Add MRA/menu entries from MAME's Dyna Gear input definition. Validate default
DIPs, coin, start, both players, all action buttons, service/test, pause, reset,
and controller remapping. Include a simulation test that checks exact SSV port
bits for each MiSTer input.

### 6. Implement ES5506 audio under a resource budget

Before adding voices, recover RAM blocks or redesign the current line/sprite
storage. Then:

- use MAME and `vgsound_emu` as golden behavior;
- adapt ideas from JTSFTM with license/provenance recorded;
- store 32-voice state compactly;
- time-multiplex shared interpolation/envelope/filter arithmetic;
- implement sample-ROM SDRAM reads and buffering;
- implement looping, bidirectional mode, IRQs, envelopes, filters, volume,
  channel routing, clamp/saturation, and any sample modes Dyna Gear uses;
- compare register transactions and PCM sample streams;
- validate audio clock/rate, stereo routing, gain, and clipping on MiSTer.

Dyna Gear may not exercise every theoretical ES5506 mode, but every used mode
must match, and unsupported modes must be documented rather than silently
misimplemented.

### 7. Make releases reproducible

- Commit the current source in logical, reviewable changes.
- Pin all upstream source revisions and licenses.
- Provide one command for a clean full regression.
- Make all focused tests pass or explicitly remove dead tests.
- Reduce lint to an explained waiver list.
- Require clean Quartus map/fit/STA and correct revision.
- Require MRA stream reconstruction and hash checks.
- Require a clean or explicitly captured source tree.
- Generate a manifest tying source, reports, RBF, MRA, and test results
  together.
- Deploy only the artifact named in that manifest.

## Release gates

The core should not be called fully working until all of these are true:

- [ ] Real MiSTer shows a stable attract mode from a cold load.
- [ ] At least one full MAME/RTL attract loop matches at machine-state and
      frame-signature levels.
- [ ] Coin/start and complete gameplay controls work for both players.
- [ ] Service/test mode and configurable DIPs behave correctly.
- [ ] Backgrounds, normal sprites, tilemap sprites, priorities, shadows,
      scrolling, flips, and transitions have been visually/frame-diff checked.
- [ ] ES5506 output is audible and PCM-differential-tested for the modes used.
- [ ] A representative gameplay session completes without CPU, bus, video,
      SDRAM, or audio errors.
- [ ] Full clean Verilator regression passes from source.
- [ ] Quartus map, fit, and STA complete successfully with reviewed constraint
      coverage and acceptable margins.
- [ ] Resource use leaves a documented safety margin.
- [ ] Source tree and all upstream provenance are committed and reproducible.
- [ ] Generated RBF and MRA hashes match the release manifest.
- [ ] The release is tested again on the exact deployed artifacts.

## Immediate next milestone

The next milestone is **not** audio and is **not** another blind MRA edit. It is
a diagnostic RBF that keeps video timing active and visibly reports loader,
SDRAM, reset, CPU, and video state. That build will identify the first failing
physical boundary. The MAME/Verilator differential method can then be applied
to the correct subsystem until a real attract-mode frame appears.

