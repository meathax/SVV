# Dyna Gear completion plan

This is the dependency-ordered plan for taking the current SSV RTL from its
simulation bring-up state to a reliable, fully playable Dyna Gear core on a
real MiSTer FPGA.

**Sim-first gameplay (attract + coin/start, no RBF):** follow
[`DYNAGEAR_GAMEPLAY_PLAN.md`](DYNAGEAR_GAMEPLAY_PLAN.md). Use this document for
the full release path (audio depth, Quartus, physical MiSTer) after those sim
gates pass. Status snapshot: [`DYNAGEAR_CORE_AUDIT.md`](DYNAGEAR_CORE_AUDIT.md).

## Governing debug method

All behavioural fixes in this plan must follow
[`CORE_ISSUE_DIFFTEST_METHOD.md`](CORE_ISSUE_DIFFTEST_METHOD.md): create a
deterministic MAME/RTL scenario, find the first divergence, state and test one
root-cause hypothesis, apply the smallest justified correction, and pass
focused, subsystem, full-core, Quartus, and real-MiSTer gates.

Screenshots and downstream symptoms are boundary evidence, not root-cause
proof. MAME is an architectural reference for the V60 and observable device
effects, not a cycle-timing oracle. No timing-failing or stale RBF may be
deployed as a validated candidate.

The immediate release target is **Dyna Gear**, not every SSV title.  The
architecture must remain suitable for later SSV games, but features that Dyna
Gear demonstrably does not use do not block its first playable release.

## Definition of complete

Dyna Gear is complete only when all of the following are true:

- The distributed MRA loads a verified Dyna Gear ROM set without embedding or
  distributing copyrighted ROM data.
- A cold boot, menu reset, soft reset, and repeated ROM reload all reach the
  attract sequence reliably.
- Attract mode and normal gameplay render correctly on a real MiSTer through
  HDMI and analog video, with stable sync, correct orientation, no renderer
  overruns, and no visible sprite/tilemap corruption.
- Both players, start, coin, service, test, all game buttons, and documented
  DIP switches work.
- Music and effects play from the real Dyna Gear sample ROM with correct pitch,
  stereo balance, envelopes, filters, looping, and no SDRAM underruns or
  audible periodic glitches.
- The complete design passes the automated Verilator regressions and the
  selected MAME reference checkpoints.
- A full Quartus fit succeeds with zero failing timing paths at all required
  corners.  Resource usage leaves enough routing margin for repeatable builds.
- The core passes at least a one-hour gameplay/attract soak and repeated
  cold-boot/reset testing on the MiSTer at `192.168.0.69`.
- The release contains the RBF, MRA, README, controls, known limitations,
  provenance, licenses, and reproducible build/test instructions.

## Current baseline to preserve

The current project already has:

- A MiSTer shell, PLLs, SDRAM controller, and V60 CPU infrastructure ported
  from the nearby Sega System 32 project.
- A Dyna Gear ROM loader/MRA and the principal SSV CPU memory map.
- Work RAM, sprite RAM, palette RAM, external RAM, inputs, interrupt control,
  raster timing, and real-ROM CPU execution in simulation.
- Background, normal sprite, tilemap-sprite, shadow, flip, depth, ordering,
  descriptor-cache, and four-pixel scanline-compositor work.
- A 60-million-clock real-ROM Verilator run reaching PC `0x00f10575`, with
  visible pixels and no reported background/object scanline overruns.
- An exact ES5506 four-byte host protocol and 32-voice low/high/test register
  file, tested with register values captured from Dyna Gear in MAME.
- An official MAME 0.288 Dyna Gear trace containing 879 completed ES5506
  register writes over ten emulated seconds.

This baseline must be tagged or committed before large audio/video changes so
that every hardware regression can be bisected.

## Critical path

The critical path is:

1. Freeze a reproducible baseline.
2. Prove the existing video/CPU image on the physical MiSTer.
3. Complete the 32-voice ES5506 PCM engine and SDRAM sample path.
4. Correct video against deterministic MAME checkpoints.
5. Close Quartus timing/resources with audio enabled.
6. Iterate on real hardware until all completion criteria pass.

Audio is currently the largest missing functional block.  Physical MiSTer
validation should begin before audio is complete so shell, clocks, SDRAM,
controls, and video faults do not accumulate behind the audio task.

## Milestone 0 — freeze and inventory the baseline

### Tasks

- Separate source changes from generated Quartus, JTAG, temporary, and
  simulation files.
- Verify that the ROM archive and extracted ROM material remain ignored.
- Commit the current CPU/video milestone and record the exact commit ID.
- Record the versions of Quartus, MAME, Verilator, GTKWave, MiSTer framework,
  and the System 32 source revision being reused.
- Run the existing unit tests and the 60-million-clock real-ROM test from a
  clean checkout.
- Finish the pending ES5506 MLAB inference experiment:
  `MLAB, no_rw_check` must be verified by Quartus rather than assumed.
- Record a resource and timing baseline before the voice engine is added.

### Exit gate

- Clean reproducible checkout.
- All existing tests pass.
- Quartus analysis/synthesis succeeds.
- Baseline reports and simulation logs are archived under ignored build
  output and summarized in tracked documentation.

## Milestone 1 — physical MiSTer baseline

### Tasks

- Produce an RBF from the frozen baseline.
- Use MiSTerclaw to inspect the MiSTer at `192.168.0.69`, confirm the correct
  writable deployment locations, and deploy the RBF/MRA without guessing
  paths.
- Confirm ROM loading, reset behavior, SDRAM initialization, video sync, and
  core menu/status operation.
- Exercise coin, start, service, test, player controls, and DIP switches.
- Capture photographs/screenshots and the MiSTer-side logs for every failure.
- Compare boot progress and visible checkpoints with MAME.

### Exit gate

- The baseline reaches a stable visible Dyna Gear attract sequence on the real
  MiSTer, even though audio may still be silent.
- No ROM-loader, clock, SDRAM, input, or shell blocker remains.

## Milestone 2 — determine the complete Dyna Gear audio feature set

The ten-second trace is enough for initial bring-up but not enough to prove
which ES5506 features are used throughout a game.

### Tasks

- Extend the MAME Lua capture to cover:
  - cold boot and attract mode;
  - sound test, if exposed by the DIP/service menu;
  - coin/start and representative gameplay;
  - death, stage transition, boss, continue, and game-over sequences.
- Decode all completed register transactions and produce feature coverage:
  banks, voices, channels, PCM/compressed mode, loop modes, direction,
  filter modes, envelopes, IRQs, and active-voice changes.
- Capture reference PCM from MAME for deterministic sound events.
- Construct a small synthetic sample ROM and register script that exercises
  each feature Dyna Gear actually uses.

### Exit gate

- A tracked Dyna Gear ES5506 feature matrix exists.
- Every feature required for the Dyna Gear release has a deterministic test
  vector and reference output.

## Milestone 3 — 32-voice ES5506 architecture

### Source strategy

- Keep the current `ssv_es5506_regs` host/register frontend.  It already
  matches Dyna Gear's MAME bus trace more closely than the partial JTSFTM
  frontend.
- Pin and attribute the GPLv3 JTSFTM source:
  `visions85/sftm/cores/sftm/hdl/sftm5506.v`.
- Reuse or adapt only independently verified datapath ideas:
  ROM handshake, accumulator boundary handling, filter arithmetic, volume
  mixing, and IRQ stacking.
- Use the Ensoniq OTTO Rev. 2.3 manual as the primary specification and MAME
  plus vgsound as behavioral oracles.

### Required architecture

- All 32 voices must be available.
- Voice registers and filter history must live in inferred MLAB/BRAM or
  another compact indexed store, not replicated flip-flop banks.
- One shared arithmetic pipeline must be time-multiplexed across voices.
- Each active voice receives exactly 16 ES5506 master clocks.
- Sample rate must be:
  `16 MHz / (16 * (ACTV + 1))`.
- Host accesses and voice-state updates need defined collision/bypass rules.
- Debug outputs must expose voice number, pipeline state, sample address,
  accumulator, filter result, contribution, sample strobe, and underrun state
  for Verilator/GTKWave.

### Exit gate

- A 32-voice scheduler runs at the documented cadence.
- Voice state infers into the intended FPGA storage.
- Quartus shows acceptable preliminary area and no accidental multiplier
  replication per voice.

## Milestone 4 — SDRAM sample path

### Tasks

- Confirm the Dyna Gear MRA places `si002-10.u6` at the intended ES5506 bank-2
  address.
- Give the ES5506 a dedicated SDRAM read port in `Arcade-SSV.sv`.
- Start with the existing unused 16-bit sample-oriented port if its latency
  meets the voice schedule; use the 128-bit burst port plus a small line cache
  if arbitration or latency causes underruns.
- Implement the four ES5506 sample banks and 21-bit word addressing.
- Fetch S1 and S2 for interpolation.
- Define request, acknowledge, timeout, and reset behavior.
- Add counters for requests, acknowledgements, stalls, and missed sample
  deadlines.
- Stress the audio port concurrently with worst-case sprite/background ROM
  traffic.

### Exit gate

- Every active voice receives S1/S2 before its arithmetic slot.
- Zero missed audio deadlines during long real-ROM video/audio simulation.
- Bank-2 addresses match the MAME trace and Dyna Gear sample-ROM layout.

## Milestone 5 — Dyna Gear ES5506 PCM engine

Implement in independently testable stages:

1. Accumulator update and 21.11 addressing.
2. Forward linear 16-bit PCM.
3. Manual-accurate nine-bit linear interpolation using accumulator bits
   10:2.
4. START/END comparison and stop behavior.
5. Forward, reverse, unidirectional, and bidirectional loops required by the
   feature matrix.
6. Four one-pole filters with correct 18-bit intermediate behavior and
   verified LP3/LP4 mode selection.
7. Exponential LVOL/RVOL scaling and stereo accumulation.
8. 23-bit channel accumulation, saturation, and 16-bit MiSTer output.
9. Hardware volume/filter envelopes and their saturation rules.
10. Voice IRQ stacking and IRQV acknowledgement.
11. Compressed sample mode only if the extended Dyna Gear trace requires it;
    otherwise retain it as a post-Dyna Gear general-SSV task.

### Validation

- Run identical register/sample scripts through RTL and MAME/vgsound.
- Compare intermediate accumulator, interpolation, filter, envelope, and
  final PCM results, not just audible output.
- Make each mismatch reproducible with a short test vector and GTKWave
  waveform.
- Use the captured Dyna Gear sequences as a final end-to-end regression.

### Exit gate

- Dyna Gear reference sound events match the golden model to the explicitly
  documented arithmetic tolerance.
- No clicks from register commits, loop boundaries, resets, or SDRAM stalls.
- Correct pitch at ACTV=31 and after any observed ACTV changes.

## Milestone 6 — video equivalence

### Tasks

- Capture deterministic MAME frames at boot, title, attract gameplay, service
  mode, and representative stages.
- Capture corresponding Verilator framebuffers with the same ROM and input
  sequence.
- Compare palette indices and final RGB separately to distinguish renderer
  faults from palette/shadow faults.
- Resolve remaining differences in:
  - automatic background modes;
  - normal and tilemap sprites;
  - priority and descriptor ordering;
  - local/global coordinates and wrapping;
  - flips and orientation;
  - 4/6/8-bit graphics depth;
  - shadow/highlight behavior;
  - raster/blanking timing;
  - descriptor-cache overflow and scanline deadlines.
- Repeat comparisons on the real MiSTer to catch SDRAM arbitration and
  clock-domain faults absent from simulation.

### Exit gate

- Selected deterministic frames match MAME exactly, or every remaining pixel
  difference is understood and documented as a MAME/analog presentation
  difference rather than an RTL error.
- No renderer overruns or cache overflows during a long attract/gameplay run.

## Milestone 7 — controls, interrupts, and board behavior

### Tasks

- Validate all controls and DIP switches against the Dyna Gear MAME driver.
- Verify V60 interrupt priority, vectors, acknowledgement, and vblank/raster
  cadence.
- Validate watchdog behavior and all reset paths.
- Confirm service/test mode, coin impulses, and two-player operation.
- Exercise external RAM and any persistence behavior used by Dyna Gear.
- Run illegal/unmapped bus access tests to ensure the CPU cannot deadlock.

### Exit gate

- Complete service-menu input test passes on MiSTer.
- Repeated reset, coin/start, and two-player tests pass without lockups.

## Milestone 8 — Quartus closure

### Resource targets

- Fit within the Cyclone V 5CSEBA6 device.
- Preserve the 553-block M10K hard limit.
- Prefer less than roughly 85% ALM usage to retain routing/timing margin.
- Share audio multipliers and keep DSP use within the 112 available blocks.
- Eliminate unintended large flip-flop arrays and combinational mux forests.

### Timing targets

- Full fit and TimeQuest analysis, not map-only.
- Zero failing setup, hold, recovery, and removal paths at all required
  corners.
- Constrain all generated clocks and intentional clock-domain crossings.
- Resolve warnings that can affect real hardware; do not waive them solely to
  obtain a green report.

### Exit gate

- Reproducible full compile with zero timing failures.
- Resource report leaves practical headroom and does not vary dangerously
  between clean builds.

## Milestone 9 — real MiSTer validation loop

For every hardware candidate:

1. Build from a recorded commit.
2. Run the complete simulation regression first.
3. Deploy the RBF/MRA with MiSTerclaw.
4. Run a short smoke test: boot, attract, coin, start, movement, effects,
   music, reset.
5. Run targeted tests for the change.
6. Save logs, screenshots/audio recordings, Quartus reports, and the commit
   ID.
7. Reproduce hardware-only failures in a minimized Verilator test whenever
   possible.

Required final hardware tests:

- Ten cold boots and thirty menu/soft resets.
- At least one hour of attract/gameplay soak.
- Both players and all controls.
- HDMI and analog video where available.
- HDMI/I2S/analog audio paths where available.
- Multiple SDRAM-heavy scenes with simultaneous music/effects and dense
  sprites.
- Service/test mode and all DIP settings relevant to normal operation.

## Milestone 10 — release

### Tasks

- Run all unit, integration, real-ROM, framebuffer, audio, and hardware tests.
- Build the release RBF from a clean checkout.
- Validate the final MRA against MAME ROM names, sizes, order, and hashes.
- Document controls, DIP switches, video orientation, installation, build,
  tests, known limitations, and troubleshooting.
- Preserve attribution for System 32-derived infrastructure, JTSFTM,
  MAME-derived behavioral work, vgsound, and other incorporated sources.
- Confirm no ROM, manual scan, generated database, or temporary capture is
  tracked.
- Tag the first fully playable Dyna Gear release.

### Exit gate

- A new user with a legal Dyna Gear ROM set can install the RBF/MRA and play
  through normal gameplay on MiSTer without developer intervention.

## Work estimate and ordering

This is an engineering estimate, not a calendar promise:

- Baseline and first hardware proof: 1-3 focused sessions.
- Dyna Gear audio feature capture and test vectors: 1-2 sessions.
- ES5506 storage, scheduler, SDRAM, interpolation, filters, envelopes, mixer,
  and cosimulation: 6-10 sessions.
- Remaining video equivalence: 2-5 sessions, depending on hardware findings.
- Quartus closure and MiSTer iteration: 3-6 sessions.
- Release regression/documentation: 1-2 sessions.

The likely critical path is 14-28 focused engineering sessions.  Hardware-only
faults or a need to restructure the current near-full M10K allocation can
extend it.

## Immediate next actions

1. Commit/tag the current known-good video and ES5506-register baseline.
2. Run the pending final Quartus map with the ES5506
   `MLAB, no_rw_check` annotations and record whether MLAB inference succeeds.
3. Build and deploy the current silent-audio image to the MiSTer for the first
   physical video/input baseline.
4. Pin JTSFTM in ignored upstream research storage and add its exact commit,
   license, and selectively reusable sections to the provenance record.
5. Capture a longer MAME gameplay/sound-test ES5506 trace.
6. Implement the 32-voice scheduler and SDRAM S1/S2 fetch pipeline before the
   filter/mixer stages.
