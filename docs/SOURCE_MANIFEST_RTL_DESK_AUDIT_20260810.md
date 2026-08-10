# Source, manifest, and RTL desk audit — 2026-08-10

## Scope and evidence boundary

This audit is a source-only review of commit
`8f83e7da730e834914b2c9c7348d2b19d064040d`. The worktree was clean when the
review began. No Verilator model, simulator, MAME session, Quartus stage, RBF,
or hardware test was run.

Reviewed surfaces:

- `Arcade-SSV.qpf`, `Arcade-SSV.qsf`, `files.qip`, and nested QIP entry points;
- the single-profile and compressed-bitstream policy;
- descriptor generation, validation, decoding, and RTL consumption;
- compile-time game/profile selection;
- `sys/` provenance and committed deviations;
- synthesizable RTL widths/signs, address decodes, reset retention, CDCs,
  memory shapes, and Quartus 17-era language compatibility.

Severity means:

- **P1** — release-blocking source risk with a direct failure mechanism;
- **P2** — concrete robustness/policy defect that should be fixed before the
  next release candidate;
- **P3** — cleanup or audit-coverage debt with no demonstrated functional
  failure.

## Executive result

The single Quartus project and its direct source manifest are coherent: one
QPF/QSF exists, `Arcade-SSV.qsf` sources `files.qip` exactly once, all 32 direct
manifest entries exist, and no direct source path is duplicated. Compression
is correctly set to `COMPRESSION_MODE ON`. No synthesizable set-name branch or
compile-time per-game device fork was found in the release RTL.

The audit found three release-significant issues:

1. the rotation writer drives DDRAM controls in `CLK_VIDEO`/`clk_sys` while
   advertising `clk_ram` as `DDRAM_CLK`;
2. descriptor reload/validation can retain and use a previous valid
   configuration, and the accepted descriptor domain is much wider than the
   generator/profile contract;
3. committed functional and constraint changes exist under the vendored
   `sys/` framework, contrary to the repository's current framework policy.

No multidimensional unpacked inferred memory was found in the compiled RTL.
No new definite arithmetic-value error or Quartus-17 language incompatibility
was established by source inspection alone.

## Findings

### P1-1 — DDRAM clock does not own the rotation writer signals

`screen_rotate` is clocked by `CLK_VIDEO`, which is assigned to `clk_sys`. Its
`DDRAM_BURSTCNT`, `DDRAM_ADDR`, `DDRAM_DIN`, `DDRAM_BE`, `DDRAM_WE`, and
`DDRAM_RD` outputs are therefore generated in the `clk_sys` domain. The module
also emits `DDRAM_CLK = CLK_VIDEO` as the clock that owns those signals.

The top level captures that clock as `rotate_ddram_clk` but discards it and
instead drives the MiSTer port with:

```systemverilog
assign DDRAM_CLK = clk_ram;
```

`clk_ram` is a separate PLL output at twice the system-clock rate. There is no
handshake, toggle synchronizer, async FIFO, or registered bridge transferring
the writer controls and data into that domain. This can make the HPS DDRAM
interface observe a request or payload on an unintended `clk_ram` edge,
producing duplicated, missed, or incoherent framebuffer writes. The problem is
specific to rotation/framebuffer output; native unrotated video can appear
healthy while this path is broken.

Action:

- restore clock ownership (`DDRAM_CLK = rotate_ddram_clk`) if the standard
  MiSTer contract permits it, or add a real request/data CDC bridge whose
  source and destination clocks are explicit;
- do not solve this with a combinational clock mux;
- require hardware verification because this touches a top-level clocked HPS
  interface and framebuffer rotation.

Focused regression specification:

1. Add a structural release check that fails if the clock emitted by
   `screen_rotate` is not the clock exported with its control/data bundle.
2. Add a focused bench with deliberately non-coincident source/destination
   edges. Issue uniquely numbered framebuffer writes and assert exactly one
   accepted destination write per source request, with address/data/BE from
   the same packet.
3. On MiSTer, test CW and CCW rotation through several frame swaps while
   checking stable HDMI, correct buffer order, and no torn/stale bands.

### P1-2 — descriptor reload can operate with stale configuration

`ssv_rom_loader` clears `cfg_valid` only on `loader_reset` (PLL loss). Beginning
a new index-1 descriptor does not invalidate the previous descriptor. Byte 15
sets `cfg_seen_last`; validation and `cfg <= cfg_decode()` occur one cycle
later. During that cycle, an immediately following index-0 byte is gated by the
*old* `cfg_valid` and uses the *old* `cfg` because the new assignments have not
committed yet.

Consequences:

- on the first load, a truly back-to-back index-1/index-0 transition can drop
  index-0 byte zero because the old `cfg_valid` is false;
- on a later game load without PLL loss, the same transition can accept ROM
  data under the previous game's layout;
- receiving byte 15 proves neither that bytes 0 through 14 were received nor
  that they belonged to one ordered descriptor transaction.

Current hps_io/MRA cadence may insert enough idle time to hide the issue, but
the loader itself does not encode or assert that dependency.

Action:

- invalidate `cfg_valid` and clear a byte-received mask at the start of every
  index-1 transfer;
- accept a descriptor only after all 16 byte addresses have been received for
  the current transaction and its checksum/domain checks pass;
- prevent index-0 acceptance until the newly decoded `cfg` is committed;
- retain the existing fail-closed behavior—do not add a Dyna Gear fallback.

Focused regression specification:

1. Load two descriptors with different program, graphics, NVRAM, and ST010
   geometries without asserting PLL reset.
2. Transition directly from descriptor byte 15 to ROM byte 0 with no idle
   cycle.
3. Assert byte 0 is neither dropped nor mapped using the old descriptor.
4. Send byte 15 first, omit one middle byte, duplicate a byte, and reorder the
   block; every case must leave `cfg_valid=0` and reject index 0.

### P2-1 — descriptor validators ignore reserved/high bits and unsupported RTL modes

The generator emits a narrow version-2 domain, but both the Python profile
audit and RTL decoder mask many fields instead of rejecting non-zero reserved
bits. Examples include the high bits of bytes 2, 3, 4, 5, 6, 8, 11, and 12.
The RTL validity predicate checks only magic, version, and checksum; it does not
reject unsupported program sizes, graphics sizes/factors/quarters, watchdog
mode 3, extra-RAM mode 3, NVRAM mode 3, inconsistent `has_nvram`, zero/odd
geometry, invalid ES5506 bank mappings, or reserved flag bits.

This matters beyond packaging hygiene: unchecked values feed variable shifts,
stream boundary arithmetic, array/bank indexes, and address decodes. A
checksum-valid malformed descriptor is currently treated as valid hardware
configuration.

Action:

- define one explicit version-2 descriptor-domain predicate;
- mirror it in the Python generator/auditor and synthesizable loader;
- make `cfg_valid` depend on that predicate;
- check that every `bank_map` entry selected by `bank_valid` names a populated
  sample slot.

Focused regression specification:

- start from every generated descriptor and flip each reserved/high bit one at
  a time while repairing the checksum; both Python and RTL must reject it;
- enumerate every legal field value and every reserved mode;
- compare the decoded packed `ssv_cfg_t` against the Python field record for
  all eight supported sets.

### P2-2 — vendored `sys/` is not pristine

The worktree has no uncommitted `sys/` change, but repository history contains
committed edits after the initial import:

- `sys/ascal.vhd` — functional pipeline, divider, counter, and RAM-style
  changes;
- `sys/sys_top.v` — SSV-specific scaler parameters and palette selection;
- `sys/sys_top.sdc` — clock and false-path edits.

Comparing against the provenance-declared adjacent source
`D:\Arcade\AI\s32\sys` also reports differences in those files plus
`pll_audio.13.qip`, `pll_audio.qip`, `pll_hdmi.13.qip`, `pll_hdmi.qip`, and
`sys.tcl`. The QIP differences add `MISC_FILE` entries, and `sys.tcl` adds a
fast output-register assignment for `HDMI_TX_CLK`; those may be generator or
upstream-version differences, but they are not pinned or justified in the
provenance ledger.

This conflicts with the current rule that `sys/`, scaler framework, PLL QIPs,
and generated IP are read-only unless a defect is proven there. In particular,
the `ascal.vhd` changes are behaviorally substantial, not a harmless local
parameter override.

Action:

- pin the exact upstream framework commit/hash set;
- classify every differing file as upstream-identical, generated metadata, or
  intentional local patch;
- restore pristine framework files where possible and express core-specific
  sizing/configuration outside `sys/`;
- isolate any indispensable framework fix as a separately reviewable patch
  with framework regression and real-hardware evidence.

Do not blindly copy the adjacent S32 files over this tree: the current changes
include timing/pipeline edits and require a controlled revert or upstream
refresh.

### P2-3 — the repository contract disagrees with the enforced release identity

The actual project, MRAs, build scripts, deployment scripts, README, and
profile auditor consistently use `Arcade-SSV.rbf`, and the QSF correctly uses
compressed bitstreams. `AGENTS.md` instead states `runtime bitstream: SSV.rbf`
and later instructs the build flow to keep “compression-off.” Both statements
conflict with the enforced profile and with MiSTer's HPS configuration
requirement.

Action: change the contract to `Arcade-SSV.rbf` and compression **on** before
the next build is authorized. Keep the build-script guard that rejects
compression being disabled.

### P2-4 — asynchronous top-level reset is used without a destination synchronizer

`RESET` is ORed with clk_sys-domain `status[0]` and `buttons[1]` and passed as
`reset_request`. `ssv_host_guard` samples that composite in a `clk_sys`
counter, but also feeds it combinationally into `host_reset`/`video_reset`.
There is no synchronizer for the external `RESET` input. This creates an
unconstrained/asynchronous reset-data path into multiple synchronous blocks and
can release near a destination edge even though the hold counter itself is
clocked.

Action: synchronize the external term into `clk_sys`, then stretch it there.
Register only the asynchronous/global term so status/button timing and the
established reset-release phase are not shifted accidentally.

Focused regression specification:

- pulse the external reset for sub-cycle and edge-adjacent intervals;
- require immediate-or-bounded assertion as chosen by the contract, a fixed
  minimum synchronous hold, and exactly one clean release edge;
- confirm descriptor/ROM downloads and watchdog resets retain their existing
  cold/soft distinction.

### P3-1 — direct manifest is sound, but orphan RTL and nested-QIP coverage are implicit

Direct manifest result:

- 32 QIP/QSF entries parsed;
- zero duplicate paths;
- zero missing paths;
- `Arcade-SSV.qsf` contains no direct user RTL/QIP/SDC assignment and sources
  `files.qip` exactly once.

Unlisted RTL under `rtl/` consists of the generated PLL implementation reached
through `rtl/pll/pll.qip`, the simulation-only PLL placeholder, and three
legacy renderer files: `ssv_line_buffer.sv`, `ssv_sprite_decode.sv`, and
`ssv_sprite_renderer.sv`. No compiled module instantiates the three legacy
files. The manifest explains two of them but not `ssv_line_buffer.sv`.

Action:

- mark all three legacy files explicitly as non-release sources or remove them
  in a separate cleanup after confirming no verification-only consumer needs
  them;
- extend the static audit to resolve nested QIPs rather than checking only the
  first-level QIP files.

### P3-2 — hardwired configuration helpers are verification-only but stale

`cfg_dynagear()` through `cfg_ultrax()` and `cfg_for_game()` are compiled into
`ssv_pkg.sv`, but release RTL does not call them. Consumers are testbenches;
the runtime core uses `ssv_rom_loader.cfg`. Therefore no synthesizable
game-name/game-ID selection was found in the active release path.

The helpers duplicate the descriptor matrix and already contain stale comments
claiming nine/ten profiles. They can drift from the Python authority and make a
bench validate the wrong expected record.

Action: generate verification records from the same descriptor bytes used by
the MRA generator, or add a static cross-language equality test. Keep
`game_id` out of functional RTL decisions.

## Desk-review results by requested category

| Category | Result |
|---|---|
| QSF/QIP membership | Direct release manifest is coherent; nested-QIP and orphan-file documentation can improve |
| Compile-time game forks | No active release fork found; ST010 is always instantiated and runtime-gated |
| Descriptor fields | Python packing and RTL bit extraction agree for generated fields, but reload atomicity and accepted-domain validation are defective |
| Vendored `sys/` | Committed functional/constraint deviations found; provenance is insufficient |
| Compression/profile | Actual QPF/QSF/tools are one-profile and compression-on; `AGENTS.md` contradicts both RBF name and compression policy |
| Width/sign | No new definite arithmetic-value bug found; malformed descriptor widths can reach unsafe variable arithmetic |
| Incomplete decodes | Descriptor validity/domain checks are incomplete; ordinary CPU read muxes have explicit unmapped defaults |
| Reset retention | Core cold/soft intent is generally explicit; unsynchronized external reset and descriptor reload state are actionable gaps |
| CDC | Rotation DDRAM bundle has a definite clock-owner mismatch; PLL lock and SDRAM-ready synchronizers otherwise follow async-assert/sync-release or two-flop patterns |
| Memory inference | No multidimensional unpacked inferred memory found in compiled RTL; large release memories are flat arrays or explicit `altsyncram` wrappers |
| Quartus 17 compatibility | No unambiguous unsupported construct found in compiled RTL; final confirmation still requires the later authorized Quartus flow |

## Required verification ladder after fixes are authorized

1. Static descriptor-domain and manifest checks.
2. Focused descriptor reload/malformed-block regression.
3. Focused host-reset edge/retention regression.
4. Focused DDRAM request/data CDC regression.
5. Existing video-mode, loader, NVRAM, ST010, watchdog, and universal-profile
   regressions.
6. Current eight-set visual/game gates.
7. Quartus map/fit/timing only when explicitly authorized.
8. Real MiSTer rotation, HDMI, reset, persistence, audio, and input test.

No final RBF was built by this audit.

## Source-integration follow-up

The runtime findings P1-1, P1-2, P2-1, P2-3, and P2-4 were subsequently
addressed in source without running a simulator or Quartus:

- the rotation bundle exports `rotate_ddram_clk`;
- descriptor receipt is transaction-masked, stale validity is cleared, commit
  is held atomic against index 0, and one shared constant-domain predicate is
  mirrored by the Python generator/auditor;
- the external shell reset has async assertion and two-edge synchronized
  release, while clk_sys-native reset terms retain their phase;
- the contract now names compressed `Arcade-SSV.rbf`;
- synchronizer chains carry Quartus recognition attributes, and no new memory
  or compile-time per-game path was added.

P2-2 is deliberately not “fixed” by copying framework files or removing the
existing scaler optimizations blindly. Those committed changes affect timing,
resources, and video behavior. They remain an isolated provenance/revalidation
item: restoring or relocating them requires the focused regressions, Quartus
evidence, and real-hardware checks that this no-simulation/no-Quartus task does
not authorize.
