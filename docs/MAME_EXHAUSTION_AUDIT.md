# MAME Exhaustion Audit

## Purpose and claim boundary

This ledger records the August 2026 audit of the local MAME source against the
single universal `Arcade-SSV` profile.  It answers a narrow question: which
behavioural contracts can be extracted from MAME, which are already represented
in this repository, and which portable changes or tests still remain.

This document is not a support claim.  A set is qualified only when it is listed
by `tools/ssv_supported_sets.py` and passes the repository's current universal
Verilator attract, soak, renderer-overrun, screenshot, and media audit
requirements.  MAME execution and screenshots are behavioural-reference
evidence only.

The authoritative universal-profile manifest contains the eight supported sets
in `PARENT_RUN_ORDER` in `tools/ssv_supported_sets.py`. `dynagear` is first,
followed by `vasara`, `vasara2`, and the remaining parents. The retired local
archives `survartsu` and `ultraxg` are preserved for reference only and are not
profile entries or proof targets. The other 25 MAME entries remain an
inventory of what was inspected, but their maps, devices, inputs, descriptors,
and MRAs are deliberately out of scope and must not be implemented or generated
by this pass.

The repository still contains legacy MRAs for those 23 entries. They are not
support claims: fifteen carry the superseded schema-v1 descriptor and eight
carry no descriptor, so the schema-v2-only universal loader rejects their ROM
streams. They remain untouched as historical inventory until a set is added to
the authoritative manifest and completes the full qualification path.

Status terms used below are deliberately strict:

- **Qualified baseline**: already present in the universal source and covered by
  existing repository evidence for at least one qualified set.
- **Source-integrated, test pending**: present in the current shared worktree,
  with focused tests added where stated, but not promoted to verified evidence
  by this audit.
- **Compile-checked**: the focused Verilator top builds from final source; this
  is an integration gate, not an executable test pass.
- **Confirmed defect**: MAME establishes a contract and the universal core does
  not yet implement it correctly.
- **Portable future work**: a shared descriptor/device enhancement that can be
  implemented without a set-name conditional, but does not qualify any set by
  itself.
- **Uncertainty / MAME artifact**: MAME is incomplete, contradictory, explicitly
  approximate, or not primary enough to justify an RTL change on its own.

## Audited source provenance

The primary checkout was:

- path: `D:/Arcade/AI/MAMESOURCE/mame`
- tag/description: `mame0289`
- commit: `f34f02505e32c1993c6a782b6814232cbfc74e36`
- worktree state during audit: clean

The authoritative SSV driver surfaces are:

- `src/mame/seta/ssv.cpp`
- `src/mame/seta/ssv_v.cpp`
- `src/mame/seta/ssv.h`

Related MAME implementation surfaces inspected were:

- `src/devices/cpu/v60/` for V60 decode and instruction semantics
- `src/devices/cpu/upd7725/` for the uPD96050/ST010 execution and host ports
- `src/devices/sound/es5506.cpp` and `.h` for ES5506 host/voice semantics
- `src/devices/machine/watchdog.cpp` for watchdog timing and kick behaviour
- MAME address-space, input-port, and bookkeeping code for unmapped reads, coin
  lockout, and counter semantics
- `src/devices/bus/snes/upd.cpp` as another uPD96050 host integration example
- `src/devices/video/x1_020_dx_101.cpp` as a related, non-authoritative video
  implementation
- the SSV, V60, uPD96050, and ES5506 git histories relevant to current behaviour

No second SSV driver or independent SSV implementation exists in the audited
`MAMESOURCE` tree.  A workspace-wide source-name inventory found one other
local MAME tree, `D:/Arcade/AI/mame289`. SHA-256 comparison covered 27 pertinent
files: `ssv.cpp`/`ssv_v.cpp`/`ssv.h`, the complete V60 and uPD7725/uPD96050
device directories, ES5506 implementation/header, and watchdog
implementation/header. All 27 are byte-identical to the audited checkout, so
that tree provides no additional or independent behaviour to port.

The current public [Jotego core tree](https://github.com/jotego/jtcores/tree/master/cores)
was also checked as an independent FPGA source. It contains no SSV core, and
targeted public searches found no Jotego V60 or ES5506 implementation to port.
Unrelated Jotego video/sound cores are therefore not treated as SSV evidence;
future public additions can be audited when they expose an actual shared
device or board contract.

The SSV video source is byte-identical between MAME 0.288 and 0.289.  The main
driver/device delta is not wholly empty: MAME commit `58415acf5c9` changed V60
IRQ-cycle callback integration, while the zero ST0020 clock-argument change has
no behavioural content here.  V60 commit `f0244b9f63d` corrected ADDC/SUBC carry
semantics.  Recent uPD96050 changes relevant to this core include
`f530835c8f4`, `4565368984a`, and `43e8643d27c`; the current ST010 source already
contains those host/range corrections.

The installed comparison executable declares `0.288 (mame0288)`, while the
source-audit checkout remains at `mame0289`. Live preflight now binds the exact
executable SHA-256 to the checkout's `mame0288` tag and records tagged blob
hashes for the SSV driver/video/header, V60 addressing/operations, and ES5506.
It records the 0.289 HEAD and working-file hashes separately as the newer audit
target. Runtime traces therefore no longer claim provenance from the wrong
minor-version source; the byte-identical 0.288/0.289 video blob is also explicit.

This is therefore an exhaustive audit of the locally available MAME 0.289 SSV
driver, its directly used devices, its relevant framework contracts, and the
pertinent local git history.  It is not a promise that future MAME commits,
board measurements, manuals, or new traces will reveal nothing else.

## Complete MAME set inventory

MAME 0.289 has 33 SSV `GAME` entries.  They are grouped below by implementation
cost and shared hardware family, not by a new support promise.

| Group | Count | Sets | Meaning for the universal core |
| --- | ---: | --- | --- |
| Parent proof scope | 8 | `dynagear`, `cairblad`, `vasara`, `vasara2`, `drifto94`, `stmblade`, `twineag2`, `ultrax` | Current source-port and Verilator gameplay-proof targets, ordered by `PARENT_RUN_ORDER`. |
| Retired local archives excluded from this pass | 2 | `survartsu`, `ultraxg` | Private media remains intact, but neither archive has a supported MRA or profile entry. |
| Clone-easy candidates | 4 | `survarts`, `survartsj`, `stmbladej`, `vasara2a` | Mostly media/region/input variants, but each still requires a manifest entry, generated descriptor, legal local media, and full universal-model qualification. |
| Near-base candidates | 5 | `keithlcy`, `pastelis`, `mslider`, `ryorioh`, `meosism` | Reuse the base board with specific IRQ, mirror, quiz-input, medal-input, or NVRAM additions. |
| Mahjong/key-matrix family | 8 | `srmp4`, `srmp4o`, `hypreact`, `hypreac2`, `janjans1`, `janjans2`, `koikois2`, `srmp7` | Needs descriptor-driven key matrices/selectors; some sets also need inverted lockout and SRMP7 sound behaviour. |
| Major-device family | 6 | `gdfs`, `jsk`, `eaglshot`, `eaglshotj`, `sxyreact`, `sxyreac2` | Requires substantial shared devices: ST0020/ADC/EEPROM, V810+latches, uPD4701/golf RAM, or uPD7001/paddle/motor paths. |
| **Total** | **33** |  | No entry outside the first row is claimed supported. |

The group names are planning labels only.  `SUPPORTED_SETS` remains the universal
profile authority; `PARENT_RUN_ORDER` is only the owner-selected execution scope
and priority for this pass.

## Contracts already represented in the universal design

The following areas were compared directly rather than inferred from game
screenshots.

### Shared video path

| Contract | MAME reference | Universal implementation | Audit status |
| --- | --- | --- | --- |
| 4/6/8-bit graphics row decode | `ssv_v.cpp`, `get_tile`/tile decode paths | `rtl/video/ssv_gfx_row_decode.sv` | Qualified baseline for the modes exercised by qualified sets. |
| Shadow colour transform | `ssv_v.cpp` shadow palette formula and draw path | `rtl/video/ssv_line_buffer4.sv` | Qualified baseline. |
| True tile-code modulo | `ssv_v.cpp` tile-count wrap | `rtl/ssv_pkg.sv`, `wrap_code_cfg` | Qualified baseline. |
| Per-set tile-code scramble | `ssv.cpp`, `init_ssv` variants | shared background/cached renderer `expand_code` paths selected by descriptor | Qualified baseline; no set-name branch in synthesizable RTL. |
| Row scroll and page origin | `ssv_v.cpp` tilemap draw setup | `rtl/video/ssv_bg_renderer.sv` and cached renderer | Qualified baseline. |
| Object-list parsing, flips, coordinate modes, and 2x4 code alignment | `ssv_v.cpp` sprite/object loop | cached object renderer | Qualified baseline for current descriptor modes. |
| IRQ vector/status/ack map and video-enable register location | `ssv.cpp` and `ssv_v.cpp` shared register maps | `rtl/ssv_irq.sv` and `rtl/ssv_core.sv` | Qualified baseline, subject to the exact reset/enable caveat below. |

### CPU, DSP, memory, and input path

| Contract | Audit result | Status |
| --- | --- | --- |
| V60 opcode table coverage | Every MAME-implemented primary opcode and implemented `58/59/5A/5B/5C/5D/5F` subgroup entry has a decode path in `rtl/cpu/v60/s32_v60.sv`.  Entries absent from the core are also `opUNHANDLED` in MAME. | Source-complete for decode coverage; semantics and addressing-mode coverage still require trace evidence. |
| V60 ADDC/SUBC | The source contains the current MAME carry correction from `f0244b9f63d`. | Source-integrated; this audit reran 342,536 arithmetic comparisons plus 12 static/effective-address checks successfully, and the directed top compile-checks. |
| V60 qword effective addresses | MAME's doubleword operand handlers advance/index qword lvalues by 8 bytes. MOVD and MULX/MULUX/DIVX/DIVUX incorrectly selected the 4-byte RTL dimension for auto-increment, auto-decrement, and scaled-index destinations. | Corrected in the shared V60 core; directed qword-EA top compile-checked. |
| ST010 host windows | MAME's 16-bit data port at `$480000` and byte RAM at `$482000-$482fff` match the shared descriptor-selected core mapping. | Qualified baseline for Twin Eagle II. |
| ST010 instruction/host changes | The local RTL incorporates the relevant recent MAME uPD96050 host/range changes, native DROM loading, and split cold/soft reset semantics while retaining one optional ST010 instance. | Source-integrated and compile-checked; do not create a Twin Eagle-specific build. |
| Random-register presence | Descriptor-selected Drift Out/Storm Blade random-read locations exist and share one LFSR stream. | Baseline presence; transaction cadence was defective and is addressed separately below. |
| NVRAM address windows | The descriptor expresses the 2 KiB Drift/Storm Blade and 64 KiB Cair Blade-style windows. | A shared index-8 bridge now provides exact-sized zero-initialized upload/download persistence and CPU-write dirty tracking; source-integrated and compile-checked. |

### Audio path

The universal ES5506 path already contains the shared host register interface,
voice register file, fixed voice pacing, filter/envelope datapath, volume path,
and SDRAM sample fetch.  Qualified sample-bank selections otherwise agree with
the MAME maps, including Dyna Gear's bank-2 alias and Vasara's bank-0/bank-1
layout. MAME's `compute_tables()` voice defaults and its device-reset scope are
also represented: cold reset writes stopped `CR=0x0003`, half-scale L/R volume,
and zeroes to all 32 voice banks; watchdog reset restores only the device-level
`ACTV`/`MODE` defaults. The focused register/core tests now cover both paths.

## Qualified-set findings and current disposition

These findings affect one or more of the eight qualified targets or a universal
path used by them.  “Source-integrated” only describes the current worktree; it
does not mean the qualification matrix passed.

### Sample-region byte order

MAME declares the SSV sample regions as `ROM_REGION16_BE`; MAME's region bytes
are the canonical logical byte order after any `ROM_LOAD16_WORD_SWAP` handling.
The MRA/generator emits those logical bytes.  The universal loader previously
packed every upload stream little-endian while the ES5506 consumed the SDRAM
word directly, reversing each sample word.

- disposition: **source-integrated, test pending**
- implementation: sample uploads alone now store `{first_byte, second_byte}`;
  non-sample upload streams keep their existing packing
- focused coverage added: `CD AB`, `80 01`, and `80 00` word cases
- remaining proof: run the focused loader/voice tests, then compare attract
  audio/checksums for every qualified sample layout

### ES5506 voice semantics

The following shared device semantics were absent or incomplete:

- trans-wave looping is controlled by BLE; it must wrap rather than stop
- `START == END` stops before a sample fetch or output is produced
- envelopes continue while a voice is stopped
- a host ECOUNT write resets filter-envelope cadence; for a slow negative K
  ramp the old count is sampled at cadence positions 0, 8, and so on
- an IRQV acknowledgement must promote or retry a stacked pending interrupt
- compressed samples require the ES5506 equation-based mu-law expansion from
  the high sample byte
- cold reset must provide MAME's stopped/half-volume voice defaults, while a
  watchdog device reset must retain programmed voice banks and PAGE

These seven are **source-integrated and focused-tested** in
`rtl/audio/ssv_es5506_voice.sv`, the shared core hookups, and focused tests.
The implementation deliberately retains nine interpolation fractional bits
(accumulator bits 10:2), matching the OTTO manual and vgsound.  MAME's
conflicting eleven-bit interpolation path is not copied.  The ES5506 interrupt
is deliberately not wired to the V60: the standard SSV MAME configuration
leaves that callback unbound.

### Live CRTC clipping

MAME clips drawing from scroll/register words `$62`, `$64`, `$6a`, and `$6c`.
History commit `b753df9e455` records PCB confirmation from Twin Eagle II.  The
original universal scanout used fixed bounds and ignored those live limits.

- disposition: **source-integrated, test pending** in the current shared
  scanout/core path
- required proof: both background and object pixels immediately inside and
  outside every programmed boundary, including reset/default bounds and byte
  lanes
- integration caveat: live clip limits and per-set visible geometry must be
  composed once, not as competing crop mechanisms

### Per-descriptor visible geometry and blank status

MAME uses multiple visible areas among qualified sets:

- Drift Out '94: 336 x 238
- Cair Blade: 338 x 240
- Storm Blade: 352 x 240
- the other qualified entries: 336 x 240

The universal path now carries descriptor-selected visible geometry through
timing, blank status, scanout, and the shared maximum-width render buffers.

- disposition: **source-integrated and compile-checked**
- focused coverage added: 336x240, 338x240, 352x240, and 336x238 with exact
  horizontal and vertical blank boundaries
- remaining proof: execute the focused geometry top and obtain current same-run
  real-game captures at each native geometry

### NVRAM cold state and persistence

MAME maps 2 KiB NVRAM at `$580000-$5807ff` for Drift Out/Storm Blade and 64 KiB
at `$580000-$58ffff` for Cair Blade-style boards, using
`NVRAM(..., DEFAULT_ALL_0)`.  The universal top now uses a distinct shared
index-8 NVRAM bridge rather than conflating persistence with the hiscore path.
It zero-initializes on cold start, serializes exactly 2 KiB or 64 KiB, gives
loader restoration priority, pauses the core during transfer, and asserts dirty
only after completed CPU NVRAM writes.

- disposition: **source-integrated and compile-checked**
- focused coverage added: cold zero, both sizes, upload/download serialization,
  write priority, disabled isolation, pause, and dirty semantics
- remaining proof: execute the focused top and perform a process-level
  save/reload exercise through the MiSTer interface

### Watchdog timing

MAME's watchdog default is exactly three seconds from device reset and may be
kicked by the descriptor-selected read or write address.

- disposition: **source-integrated and compile-checked**
- implementation: an exact `3 * 48,317,307` master-clock interval from reset,
  preserving descriptor modes `none`, read-kick, and write-kick
- focused coverage added: timeout before/after video enable, correct and wrong
  access directions, exact boundary, and all modes
- soft-reset contract: MAME `machine_reset()` clears pending IRQ causes but
  retains video enable, scroll/CRTC RAM, IRQ masks/vectors, and bookkeeping
  latches; the shared cold/soft split now preserves those fields across a
  watchdog reset while cold/download reset still initializes them
- verification: the final focused
  test now drives an actual timeout, starts with a pending IRQ and non-default
  bookkeeping edge state, and the real-game top feeds `wdog_rst` back as a soft
  reset like the hardware wrapper; the Dyna mode-1 executable passes all
  assertions in 3 ms, while real Dyna Gear continuity proof remains pending

### Coin lockout and counters

The normal output register uses active-low lockouts on bits 0/1 and counters on
bits 2/3; Cair Blade uses the inverted lockout polarity.  MAME's bookkeeping
option gates coin inputs when locked.  The core previously consumed only bit 7
for video enable and always passed coin inputs.

- disposition: **source-integrated and compile-checked**
- implementation/coverage: descriptor polarity, reset-unlocked latches,
  active-low coin-input gating, both counter rising edges, and byte-lane writes

### Vasara SYSTEM input mask

The common SSV input map assigns Tilt and Test to SYSTEM bits 3/4, but MAME
overrides both bits to fixed-high/unknown for Vasara and Vasara 2.

- disposition: **source-integrated and compile-checked**
- implementation/coverage: a descriptor input mode forces bits 3/4 high for
  Vasara/Vasara 2 while normal profiles retain live Tilt/Test controls

### Dyna Gear extra-input window

Dyna Gear inherits the Survival Arts map containing `$500008`, but MAME defines
the extra button bits as active-low unknown/fixed high.  Survival Arts uses the
same window for buttons 4-6.  A boolean `has_add_buttons` cannot distinguish
these board contracts and makes Dyna Gear expose live buttons incorrectly.

- disposition: **source-integrated and compile-checked**
- implementation/coverage: descriptor modes `none`, `decoded_fixed_high`, and
  `survival_six_button`, including byte-lane behaviour

### Random-read transaction cadence

MAME calls `machine().rand()` once per read-handler transaction.  The original
core advanced its LFSR more than once while a bus request was held through the
wait/ack sequence.

- disposition: **source-integrated, test pending**; advance now occurs on the
  completed read acknowledgement edge
- required proof: held requests advance once, repeated transactions advance
  once each, both addresses share one stream, and the disabled descriptor path
  returns the universal unmapped value

### Unmapped/open-bus reads

MAME's V60 address-space default is low/zero, and watchdog reset reads use the
same unmapped value.  The original core returned `$ffff` from truly unmapped or
no-read registers, conflating them with valid active-low idle input ports.

- disposition: **source-integrated, test pending**; read-mux defaults are now
  zero while mapped idle inputs remain `$ffff`
- required proof: `$210006`, `$21000e`, IRQ write-only registers, disabled
  optional windows, watchdog read modes, and mapped idle input registers

### Power-on video enable

MAME's common initialization calls `enable_video(1)`.  The original universal
reset state held video disabled until a game write.

- disposition: **source-integrated and compile-checked**; cold reset enables
  video while soft/watchdog reset retains the output-register bit-7 latch
- focused coverage added: cold/soft reset, bit-7 writes, retained CRTC/IRQ and
  interaction with coin-lockout/counter state; executable rerun remains pending

### ST010 soft-reset retention

MAME's uPD96050 `device_start` zeroes complete state/RAM, but `device_reset`
only resets PC, status/flags, serial acknowledgements, and IRQ-related state;
general registers and RAM persist.

- disposition: **source-integrated and compile-checked**
- implementation: cold/download reset clears the complete DSP and RAM;
  board/watchdog soft reset clears MAME-equivalent execution/IRQ state while
  retaining general registers, stack, and RAM
- remaining proof: execute the directed retention top, then continue Twin
  Eagle II through a real watchdog event

## Exact IRQ contract and remaining caveats

MAME stores requested levels separately from enable bits.  Its interrupt line is
the intersection of requested and enabled; vector callback priority scans
requested levels 0 through 7; acknowledge clears the requested level.  Scanline
0 may request level 1, scanline 120 may request level 2, and scanline 240 requests
level 3.  MAME's enable write combines data but does not immediately call the
line-update helper, and machine reset clears requested state without explicitly
clearing every enable/vector register.

The universal core covers the qualified level-1/level-3 path.  Descriptor byte
9 bit 2 is deliberately reserved and rejected rather than carrying Pastel
Island's scanline-120 level-2 path into this eight-set profile.  The enable-line
timing difference is now a demonstrated qualified-game defect: Vasara reached
its IRQ setup with level 3 already pending, wrote mask `0x000c`, and the old
combinational RTL asserted before the following `UPDPSW` disabled interrupts.
It therefore used uninitialized vector slot 0 and acknowledged level 0 forever.
The shared controller now refreshes the CPU line only on cause/ack events, as
MAME does; the focused masked-pending regression passes, Dyna tokens 2-4 remain
exact, and Vasara escapes the IRQ storm. Reset still clears the line directly.

## Inspected but out-of-scope expansion work

These findings document that the source was inspected; they are not active
implementation work because the corresponding parent ROMs are not locally in
scope.  No item below authorizes a descriptor, MRA, RTL device, per-game RBF,
compile-time macro, set-name conditional, or duplicated optional device.

### Clone-easy group

The four clone candidates should reuse existing device profiles.  Remaining
work is descriptor/media generation, input/region comparison, and complete
qualification.  Similarity to a parent is not attract evidence.

### Near-base group

- `pastelis`: optional IRQ level 2 at scanline 120 plus mid-frame partial-scroll
  behaviour; mode-3 graphics/shadow remains uncertain in MAME
- `keithlcy` and `ryorioh`: quiz layout uses the upper nibble and omits the
  common Test input
- `mslider`: work RAM mirror at `$010000-$01ffff`
- `meosism`: 64 KiB NVRAM plus medal/analyzer/custom input and output behaviour

These should become descriptor-selected map/input/IRQ features with focused
tests covering both enabled and disabled profiles.

### Mahjong/key-matrix group

Implement a shared matrix/select device and selector registers for the eight
mahjong entries, with descriptor rows/width/polarity rather than individual set
logic.  Cover inverted lockout variants through the same output-polarity field
used by Cair Blade.  SRMP7 additionally needs its dynamic sample-half banking
and fake IRQV/read behaviour; that behaviour remains future/incomplete even in
MAME and must not be generalized from guesses.

### Major-device group

- `gdfs`: one shared ST0020 secondary video/tilemap path, ADC0809, 93C46 EEPROM,
  and level-6 interrupt source
- `jsk`: one optional V810 subsystem with its shared RAM/latches and host map
- `eaglshot`/`eaglshotj`: uPD4701 coordinate device, graphics banking/RAM, and
  NVRAM at `$c00000`
- `sxyreact`/`sxyreac2`: uPD7001 paddle conversion, ball/motor outputs, and the
  Cair Blade-style NVRAM family

Each device requires a media-independent unit or bus test before any real-game
qualification run.  The device instance remains present once in the universal
profile and is activated only by descriptor fields.

## Audio-specific evidence and limits

### Canonical sample storage contract

The persistent contract is: MRA generation emits MAME's logical
`ROM_REGION16_BE` byte stream, and SDRAM stores each successive pair so the
ES5506 sees the first logical region byte as the high PCM byte.  Raw ROM-file
endianness is not a valid shortcut because `ROM_LOAD16_WORD_SWAP` and byte-lane
loads have already defined the logical region.  Byte-loaded regions must retain
their zero/unpopulated lane exactly.

### ES5506 evidence hierarchy

For interpolation fraction width, the Ensoniq OTTO manual and the independent
vgsound model outweigh MAME's contradictory eleven-bit implementation.  The
core therefore keeps nine fractional bits.  MAME remains valuable for SSV host
maps, bank selection, register-access effects, looping, IRQ stacking, and ROM
region construction.

Repository research records that a ten-second Dyna Gear trace used uncompressed
bank 2.  It did not exercise compressed playback, reverse/bidirectional looping,
alternate channels, or the high-pass cases.  Focused device tests are mandatory
for those features; a clean Dyna attract run cannot validate them.

The exact physical ES5506 clock divider remains a board-level inference.  Do not
change it from a MAME constant alone without audio rate/PCB evidence.

## Video-specific evidence and limits

### Palette RAM caveat

MAME maps the palette aperture as full shared 16-bit RAM.  The universal palette
RAM intentionally retains only the odd/low RR byte and reads the high byte as
zero.  An existing palette test expects high-byte readback but is excluded from
the normal bring-up script.

This is a MAME-parity gap, not yet a confirmed hardware defect: the PCB uses
three 8-bit colour RAMs for a 24-bit palette, so the extra byte may be physically
unimplemented.  Do not consume roughly 32 additional M10Ks solely to mirror
MAME.  First obtain V60 traces showing meaningful high-byte palette reads or
direct board evidence, then either implement storage or correct the stale test
and document the hardware aperture.

### Remaining renderer uncertainties

- MAME explicitly marks BPP modes 1, 2, and 3 unverified; Pastel Island mode 3
  and its shadow interaction are unresolved.
- Priority word bit `4.h` is unknown in the driver.
- Eagle Shot offsets contain driver kludges.
- The video-status vblank bit may actually be derived from a scanline counter.
- MAME's live sprite-RAM consumption versus a vblank-cached list is not enough
  to establish physical hardware timing.
- MAME flags qualified Dyna Gear, Ultra X, and Storm Blade as imperfect
  graphics.  MAME output is therefore not pixel truth for every case.
- `x1_020_dx_101.cpp` uses related concepts but labels its own BPP handling
  buggy and differs from the SSV device.  It is a hypothesis source, not an
  implementation oracle.

## CPU and ST010 evidence limits

### V60

The decoder comparison found no MAME-implemented opcode missing from the RTL.
The risk has moved to exact semantics, flags, effective-address side effects,
alignment, and bus sequencing.  The repository has 29 directed V60 benches and
recorded Python-reference cosim baselines, but not an exhaustive MAME
opcode-by-addressing-mode comparison.

The next useful evidence is trace-driven coverage from all eight qualified sets:
compare instruction PC/opcode, registers, flags, effective address, width,
read/write data, and exception/IRQ boundaries.  Do not invent implementations
for suboperations MAME also marks unhandled.

MAME's C++ `SCLFS` behaviour for absolute shift counts greater than 30 relies on
host-language undefined behaviour.  The core's deterministic NEC-manual
interpretation is intentional and must not be replaced by that artifact.

### ST010/uPD96050

The execution core and SSV host map are substantially exhausted against current
MAME.  The serial port and external DSP interrupt facilities are unused by the
SSV integration and need not be added merely because the generic MAME device
supports them.

MAME's DP-modify mask behaviour preserves what is likely a long-standing device
model error in some high DP bits; the current core matches it.  Do not “correct”
either model without silicon, manual, or game-trace divergence.  Soft-reset
retention is the concrete remaining issue.

## MAME artifacts and uncertainty register

The following must remain visible in reviews so “matching MAME” is not mistaken
for “matching the board”:

| Area | MAME limitation or conflict | Required authority before changing RTL |
| --- | --- | --- |
| ES5506 interpolation | MAME uses 11 fractional bits; OTTO manual/vgsound use 9. | Keep 9 unless primary hardware evidence contradicts it. |
| Palette upper byte | MAME stores it; physical 3x8-bit palette hardware may not. | V60 read trace or PCB measurement. |
| BPP modes 1-3 | Driver comments call them unverified. | Captures, ROM-layout proof, or board tests. |
| Priority `4.h` | Unknown in `ssv_v.cpp`. | Targeted overlapping-layer captures/traces. |
| Eagle Shot offsets | Explicit kludges. | Board/video capture and device timing evidence. |
| Vblank status | Driver notes it may be scanline-counter derived. | Poll-loop trace aligned to raster position. |
| Imperfect graphics flags | Dyna Gear, Ultra X, and Storm Blade are not MAME pixel truth. | PCB capture or independent layout analysis. |
| Pastel Island | Mid-frame partial update and mode-3/shadow uncertain. | Trace plus line-accurate capture. |
| Sprite timing | MAME reads live RAM; hardware caching moment is not proven. | Mid-frame sprite-write experiment. |
| V60 SCLFS | Host C++ undefined shift behaviour for large counts. | NEC documentation/hardware, not MAME output. |
| ST010 DP modify | Likely inherited model quirk. | DSP manual/silicon/game divergence. |
| SRMP7 sound IRQ/read | MAME contains incomplete/faked behaviour. | Program trace and board/device evidence. |
| Related X1 video device | Similar but explicitly buggy/different. | Use only to form tests, never direct porting. |

## Licensing and source-boundary rules

- The audited MAME SSV driver, ES5506 device, and uPD96050 implementation carry
  BSD-3-Clause headers.  Their behavioural contracts may be independently
  reimplemented in this GPL-3.0-or-later repository, but code or substantial
  tables must not be copied without retaining compatible copyright and licence
  notices.
- Prefer original RTL derived from observable register, timing, map, and state
  behaviour, with file/commit references in comments and tests.  BSD-3-Clause
  compatibility with GPL does not erase attribution obligations.
- Preserve any existing vgsound zlib attribution when its model or equations
  inform a source file.
- The Ensoniq OTTO manual is a copyrighted specification/reference.  Record
  conclusions and page/section evidence; do not commit scans or bulk OCR.
- Never commit commercial ROMs, private NVRAM, generated MAME/Verilator models,
  full traces, or captures that are not redistributable.
- MAME screenshots and runs remain reference evidence and never satisfy the
  repository's Verilator-only attract milestone.

## Prioritized remaining implementation and test matrix

Priorities describe correctness/evidence value, not permission to bypass the
required shared descriptor path.

| Priority | Shared work item | Current status | Minimum focused proof | Matrix proof before claim |
| --- | --- | --- | --- | --- |
| P0 | Correct sample-region big-endian word storage | Source-integrated; compile-checked | Loader word tests `CDAB`, `8001`, `8000`; byte-loaded zero lane | Qualified attract/audio checks across every sample-bank layout |
| P0 | Complete ES5506 BLE/zero-length/envelope/ECOUNT/IRQV/compressed semantics | Source-integrated; compile-checked | Dedicated voice/register tests for both sides of every condition | Qualified attract/soak with no audio fetch/protocol failures; targeted audible/capture checks |
| P0 | Live CRTC clip limits | Source-integrated; compile-checked | All four edges for BG and objects, reset/default and writes | Qualified frame captures, especially Twin Eagle II |
| P0 | Descriptor-visible geometry and matching blank status | Source-integrated; compile-checked | Four geometry profiles and exact edge points | Same-run non-empty screenshots at native geometry for all eight qualified sets |
| P0 | Transaction-correct random reads | Source-integrated; compile-checked | Held request, repeated transactions, shared stream, disabled path | Drift Out/Storm Blade attract soak |
| P0 | Zero-valued unmapped reads | Source-integrated; compile-checked | Optional/no-read/write-only apertures plus mapped idle inputs | All-eight CPU progress/attract regression |
| P0 | Power-on video and watchdog-retained board latches | Source-integrated; compile-checked | Cold/soft reset, output bit 7, CRTC RAM, IRQ mask/vector, bookkeeping | Parent-set boot plus watchdog interaction |
| P1 | NVRAM zero-init and 2 KiB/64 KiB persistence | Source-integrated; compile-checked | Byte lanes, both sizes, cold zero, bridge upload/download, disabled isolation | Drift Out, Storm Blade, Cair Blade save/restart evidence |
| P1 | Exact three-second watchdog from reset | Source-integrated; compile-checked | Pre/post-video timeout, exact boundary, all kick modes/directions | Representative qualified profile per watchdog mode |
| P1 | Coin lockout polarity/gating and counters | Source-integrated; compile-checked | Normal/inverted, two slots, edges, lanes, reset | Cair Blade plus normal-polarity qualified set |
| P1 | Vasara SYSTEM mask | Source-integrated; compile-checked | Masked and live descriptor profiles | Vasara and Vasara 2 input/attract checks |
| P1 | Extra-input mode replacing boolean | Source-integrated; compile-checked | `none`, Dyna fixed-high, retired Survival six-button diagnostic | Dyna Gear; Survival Arts is outside the supported matrix |
| P1 | Split cold versus soft ST010 reset | Source-integrated; compile-checked | Register/RAM retention and reset-only fields | Twin Eagle II watchdog/continued-execution run |
| P1 | V60 trace-driven semantic coverage | Decode exhausted; semantic coverage incomplete | Differential traces by opcode/address mode and IRQ boundary | Coverage from all eight qualified sets |
| P2 | Palette upper-byte decision | Hardware uncertainty | Trace/readback experiment before allocation | Representative palette-intensive game plus resource report |
| P3 | Resolve BPP/priority/vblank/sprite-timing uncertainties | Research work | Synthetic ordered-pixel and raster-timed write/poll tests | PCB or independent primary evidence before behavioural changes |

After any implementation batch, update the feature matrix and evidence ledger,
run focused simulations, then run:

```text
python tools/verify_ssv_universal_profile.py --require-roms
```

Do not promote “source-integrated” to “tested” merely because compilation
succeeds.  For displayable Verilator work, the native visual simulator must
launch, generate changing frames, remain responsive, and produce the required
same-run evidence under the repository policy.

## Final audit verification snapshot

- `python tools/verify_ssv_universal_profile.py --require-roms`: **PASS 8/8**
  using the single `SSV.rbf` profile; qualified clone/parent media dependencies
  are derived from their MRAs without adding another supported set.
- V60 directed suite: **31 passed, 0 failed** under Verilator 5.032.  The static
  MAME semantic checker also passed 342,536 arithmetic comparisons and 12
  static/effective-address checks.
- Prior focused compile campaign: **17/17 tops built**, followed by clean
  rebuilds of the corrected uPD window and geometry/configuration tops. The
  final Dyna watchdog mode-1 top now also passes its exact-timeout, kick,
  open-bus/input-window, CRTC, random-read, bookkeeping, and real soft-reset
  retention assertions in 3 ms.
- uPD96050 last completed runtime: **4 suites passed, 1 window suite failed**.
  The failure was traced to the bench issuing a cold/device-start reset before
  reading RAM; the corrected helper now uses the MAME-style soft reset and
  compile-checks, but its executable rerun remains pending because unrelated
  safe-slot sessions are active.
- Native visual proof: the pre-audio harness opened a responsive Dyna Gear SDL
  window and first changed/nonblanked at frame 214 (checksum `d512913d`, 76,852
  nonblack pixels), then advanced beyond frame 1,000.  The subsequent
  current source with hardware-equivalent watchdog feedback and protocol-v2 raw
  frame barriers generated and built with Verilator 5.050 at
  `C:\tmp\ssv_obj_visual_lockstep\Vtb_ssv_frame_crc.exe`. Bounded visible
  session `dynagear-20260801-192349` then completed one aligned token in 49
  seconds and closed both processes normally. Its 30 accepted bus events, PC,
  sprite/list and palette state match MAME, but RTL is black against MAME's
  8,830-pixel Sammy logo; it is diagnostic mismatch evidence, not gameplay
  proof. The scroll digest now excludes MAME's word-0 status overlay. A focused
  renderer run subsequently exposed and repaired the pooled-index steady-state
  descriptor-prefetch omission: the 52-descriptor/133-fetch dense-line case
  now completes in 1,552 cycles, and deadline aborts pass in every long build
  phase. Bounded visible session `dynagear-20260801-195759` then matched stable
  token 2 exactly: 80,640/80,640 pixels, 30/30 bus events, and every compared
  state digest, with zero cache overflow/blocked swaps. Both processes exited
  0 and closed normally after 46.6 seconds. Token 1 was proven to be a
  mid-epoch age transition by byte-identical archived MAME frame hashes, not a
  remaining renderer semantic error. This is still not Verilator gameplay proof.
- The repaired startup/input barrier was then exercised live in bounded session
  `dynagear-20260801-202510`: tokens 2 through 4 matched exactly across all
  241,920 pixels, 90/90 bus events, and every compared state digest. Both
  visible processes exited 0 without force. The current frame-850 gameplay
  assertion plus same-run Verilator screenshot remains the next Dyna gate.
- A final Dyna-only source cross-check found no major unported MAME device
  behaviour. It did expose the shared CPU/audio-to-pixel NCO ratio as +42.4 ppm
  high. `SSV_CPU_INC=21701` now reduces that to about -3.7 ppm with no added
  state; the two-million-cycle focused ratio test passes, and bounded visible
  session `dynagear-20260801-205514` retains exact token-2-through-4 video,
  trace, and state matching in 37.8 seconds. Gameplay proof remains pending.
- Release-profile instrumentation gating was measured independently of the
  reference side: in bounded session `dynagear-20260801-211356`, RTL owner
  packets advanced from token 1 through 42 in 37 seconds after boot, versus
  51 seconds for the same interval in `dynagear-20260801-204408`. The run is
  not match evidence because MAME remained paused at token 40 despite
  `release_frame.txt=40`; both windows were then closed normally. The Lua
  adapter now retries `emu.unpause()` while an already released token remains
  paused, and the coordinator enforces a whole-session wall-clock ceiling.
- The repaired adapter and release hot-path simplifications then passed bounded
  session `dynagear-20260801-212547`: token 2 matched all 80,640 pixels, 30/30
  normalized bus events, and every compared state digest. RTL completed in
  33.96 wall seconds at about 97% CPU utilization; RTL and MAME both exited 0
  and neither required forced cleanup. This is a short regression, not the
  required frame-850 gameplay proof.
- Python compilation and `git diff --check`: **PASS**.  No Quartus build or new
  hardware test was run.

## Exhaustion conclusion

The local MAME 0.289 source and relevant history have been exhausted as an
available behavioural reference for SSV in this pass.  The audit found no
hidden second SSV implementation and no missing MAME-implemented V60 opcode
decode family.  It did find concrete shared improvements in sample storage,
ES5506 semantics, CRTC clipping, geometry, reset/watchdog/NVRAM/input behaviour,
open-bus/random transactions, and ST010 soft-reset state, plus a clear expansion
map for the other 23 entries.

What is not exhausted is evidence.  The identified qualified-set contracts are
represented in the shared worktree; most passed the prior compile campaign,
while the current Dyna renderer/full-core video mismatch still needs repair.
Compile success is not a focused execution pass, a real-game matrix pass,
timing closure, or hardware proof.  MAME's own graphics/audio uncertainties
also require manuals, PCB observations, traces, or independent tests rather
than more literal source porting.
