# Dyna Gear MAME-diff execution record — 2026-08-15

This is an implementation record, not a MAME-equivalence acceptance claim.
The fixed scenario is `verif/scenarios/dynagear/gameplay_neutral.json`: 941
native frames, gameplay marker 820, neutral through 940, and the compiled
input journal with MAME `-coin_impulse -1`.

## Pinned contract

- MAME: 0.289 (`mame0289`), executable SHA-256
  `af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3`.
- Journal SHA-256:
  `8396230ffcefd1dc5d7c28bb9391b938c6293b6dd78b9a57daecaa260ab9fcc4`.
- Strict candidate: `cpu_data`; device-1 program-ROM fetches excluded because
  MAME observes individual reads and RTL observes cache-line fills.
- Verilator model signature:
  `sim_output/obj_headless/headless.signature` =
  `74CA37A740E8BD05E0A1BB99F8B1475BC49BF3B06900348A29A12F0E49002756`.
- Strict comparator SHA-256:
  `82915c89a8b3caedf45ad228b5f1f7b8e2a6de9b5aeef16fcaed437b3ff343d2`.
- Strict-only probe SHA-256:
  `d2d872bd992ab51b05519489c039286f176af212bfa5e4b5dac54f79b3d48974`.
- Headless contract: native UCRT64, Verilator 5.050, timing enabled,
  assertions enabled, unique X handling, `--threads 1`, display backend none.
  FST support fell back to compile-time VCD because `C:\msys64\ucrt64\include\lz4.h`
  is unavailable; no waveform was emitted by the acceptance lanes.

The current strict-window producer profile is `strict_only=true`: it retains
the real reset/journal/core path and complete stop receipt while suppressing
diagnostic domains to keep the canonical bus trace bounded. Comparator
receipts name the immutable `cpu_data_lane_mask_v1` projection, which masks
unselected lanes from `data` using `byte_enable` before ordinal comparison;
source JSONL remains unchanged.

## Same-side deterministic baselines

Two cold MAME barrier captures completed with identical receipts and artifacts:

| Artifact | SHA-256 |
|---|---|
| receipt | `8443ba2f743cab0bc7d7da193641a2b04c664920410db2a2e4acf19e22596211` |
| trace (`BusMode=none`) | `06baed4f7b444c9991d75bd5c86bc34cd1270e1bfe65be44e0e37b159bb80aca` |
| normalized 48 kHz stereo PCM | `b829fb7a0fd35c31b1865b20d574c9649dcd540eb2b093960ff0effd6092e0a7` |
| native PPM frame 820 | `e6a57d810bab3e1201b43c31d77e6803bf43d6acc812c0b7f137cd77308b4ef9` |
| native PPM frame 940 | `4b9c80573785c6e8f8daa4c94a2deeff43c97697aa914398b58efc79908e7b3` |

The two cold RTL receipts from the current source state are
`sim_output/diff/dynagear-gameplay-rtl-fix4-detached-1` and `...-2`; their
receipt, frame stream, state stream, audio stream, and final PPM hashes are
identical. Both are complete 941-frame, zero-drop runs and consume the same
scenario journal. Their audio receipt remains diagnostic because the source
tick to 48 kHz phase contract is not yet proven.

The source-preserving strict-window projector
`tools/project_ssv_strict_window.py` and `tools/compare_ssv_strict.py` prove
the two cold MAME windows match without resynchronization:
`sim_output/diff/dynagear-mame-sameside-strict-f841-843.json` reports 64,524
events and normalized digest
`9ef17e38670108610c2bd78111127226c12a99c9a5b9d4515b5c970804b103f9`.

## Causal window

The fresh MAME window is
`sim_output/diff/dynagear-exec-mame-irq-482-v5` and the paired RTL diagnostic
trace is `sim_output/diff/dynagear-rtl-causal-pe482-a/rtl-trace.jsonl`.
`sim_output/diff/dynagear-irq-cadence-exec-v2.json` is the machine-readable
comparator receipt. It binds the unique state
`PC=F1E8E8, R2=FFFA1A72, R16=F29D94` and records:

- MAME next retirement `F1E8EB`;
- RTL next retirement `F11124`;
- MAME handler entries before the aligned state: 3;
- MAME handler beam `(2,240)` and aligned-state beam `(220,215)`;
- RTL level-3 request at cycle `406962020`, acknowledgements
  `406962038..040`, frame 507/scanline 240.

Comparator receipt SHA-256:
`56da7c63bb7d2fe3ba4e64d21bb07c2b5a57b50274bd52bc435366b96bc4c658`.

The cursor-482 causal observation was independently repeated in MAME sessions
`sim_output/diff/dynagear-mame-irq-pe482-b` and `...-c`.  Their debugger
traces are byte-identical (SHA-256
`7e84807f929cb9e06df1a66c871b726cc60b6c1578f5a2ffe21abbf810559975`) and
each has one exact-state occurrence at beam `(220,215)`.  Same-side MAME
determinism is therefore closed for this diagnostic boundary; the cross-lane
IRQ-cadence mismatch remains open.

This is the sole active divergence. The scanline producer is common and the
MAME/RTL ROM words at the loop state match. The evidence supports an inferred
natural CPU-throughput/IRQ-phase difference; it does not justify an arbitrary
IRQ delay or a clock/CPI change. Pinned MAME’s V60 core uses an explicitly
approximate average instruction cost, and independent PCB V60 timing/phase
evidence is absent.

The pinned source anchors the shared producer: `mame289/src/mame/seta/ssv.cpp`
sets the V60 to 16 MHz, the raw raster to 454x262, and raises level 3 at
scanline 240 (`ssv.cpp:239-263,2422-2440`). The V60 device itself documents
its average instruction charge (`src/devices/cpu/v60/v60.cpp:614,626`), so a
MAME-vs-RTL retirement-rate difference cannot safely select a synthesizable
CPU-speed correction.

The earlier bounded receipt
`sim_output/diff/dynagear-cross-strict-f841-843-v2.json` is retained only as
superseded evidence from the pre-current MAME profile; it is not the active
target. The current paired receipt below replaces it and records the same
earliest transaction ordinal under the corrected lane contract.

The fresh paired receipt is
`sim_output/diff/dynagear-cross-strict-current-f841-843.json` (SHA-256
`0359693fa5f3e1a2301d110e360563940d196097f7b70aac48a39463ccf390cd`). It
reports the same sole earliest mismatch: ordinal 21 after a 21-event matching
prefix, MAME `0x5100` versus RTL `0x1100` at work RAM `0x790C`, BE2. The
strict cross-lane comparison is intentionally still a failure; no later event
is investigated and no RTL correction is claimed.

Strict-only same-side smoke runs are complete and byte-identical under this
contract: MAME 20-frame `cpu_data` traces contain 885,930 projected events and
RTL 20-frame traces contain 947,769 projected events. These are harness and
normalization checks only, not a cross-lane gameplay equivalence claim.

The first current full-scenario bounded MAME pair is also deterministic. Both
941-frame cold runs use the gameplay journal and emit frames 841–843 only:
each has 65,275 `cpu_data` events, trace SHA-256
`b96913309217357b4147f2be51c0660854ecb9b10975c52cfe27a1fa82eb6d2a`, receipt
SHA-256 `b5ef05bddb35eaa938c6ca1a9e5c95322572125c0385dca58460849a54b8b32b`,
and normalized digest `9f592ef408dcff1051de7757cfcda8754671f17b3d5a5b074920fa6dbbc4e628`.

The current cold RTL replay also completed all 941 frames, reached the
frame-820 gameplay marker, and emitted a complete zero-drop receipt. Its
bounded 841–843 trace contains 61,854 projected events and has SHA-256
`fb10d9586cbf730acb21b7b2705ff7585565f30579503ae2eeae93ffba3d6208`.
It matches the independently captured RTL window from
`dynagear-gameplay-rtl-fix4-detached-2` under the strict comparator, with
normalized digest `69f18d538b2738ac1477f7e1a180faf206bb409d88e9f1cec52ebb6aa3eb8c3c`.
The complete current RTL receipt SHA-256 is
`4afc4156ecab088939f8e9b60552995d7e0fcbadd26a94672eaf92b337d3c716`.

The native RGB frame stream is also closed for the declared gameplay/soak
window: `sim_output/diff/dynagear-frame-crc-gameplay-soak.json` reports a
strict `native_rgb_crc32_v1` match for all 121 frames 820 through 940, with
matching prefix 121.  The receipt SHA-256 is
`7b252c1dea79dc8ffb13a12eaba891a066e8bacdc2a87b36b91d9208f067bb1b` and the
comparator source SHA-256 is
`0c610d069cc982d7f05f594641bcd1ae423dd191c4b3679132f957d24efd07d3`.
This is a closed video-domain gate only; it cannot waive the earlier
CPU/IRQ divergence.

The same comparator run over frames 0–940 fails closed at frame 1 (matching
prefix 1), so the gameplay/soak result is a declared bounded gate rather than
an assertion that the pregame raster stream is already exact.

As a barrier-alignment falsification, a cold MAME cursor-483 debugger run was
also completed in `sim_output/diff/dynagear-mame-irq-pe483-a`.  Its receipt is
complete (941 frames, gameplay marker 820, zero drops; SHA-256
`8443ba2f743cab0bc7d7da193641a2b04c664920410db2a2e4acf19e22596211`) and its
debugger trace SHA-256 is
`32bd82abd5e2ea11ed450e0906df223a002e3591e48f40c44efa87a5ed216748`.
That trace contains no cursor-482 architectural state; it begins at the next
natural `F11124` handler entry and reaches the `F10575` idle loop.  The
cursor-482 alignment is therefore not a removable label-only offset, and the
natural CPU/IRQ cadence blocker remains open.

## Capability and fallback record

MAME MCP `ping`, `config_check`, `audit_romset`, `get_ioports`, persistent
launch/status/stop all succeeded. MCP was used for preflight and a persistent
headless smoke. The project-owned PowerShell/Lua runner was used for the
artifact-producing captures because it preserves the real journal, descriptor,
headless adapter, receipt schema, and opt-in debugger traces; no MCP operation
available in this environment supplied the complete paired canonical trace
and comparator receipt contract.

The canonical journaled MAME adapter also emitted an opt-in state-CRC
sidecar. Two cold MAME sidecars are byte-identical (941 records each;
SHA-256 `309e2f028a47d7356b2eda02b33fcd14e58889d563939db538360c29650d3d65`).
The strict windowed state comparator
`sim_output/diff/dynagear-state-gameplay-soak.json` first differs at frame 820
only in `scroll63` (`15c7d3d4` MAME versus `5456bd80` RTL); `list512`, `spr8k`,
and `pal512` match there. This remains diagnostic and downstream of the sole
active CPU/IRQ divergence.

## Remaining acceptance gate

The full `cpu_data` MAME stream is not a usable 941-frame artifact: an
unbounded capture exceeded 3.5 GB before the stop barrier and was correctly
rejected as incomplete. Bounded strict MAME windows and complete same-side
baselines exist, but the cross-side `cpu_data` stream comparison through the
941-frame gameplay/soak barrier is still open. No RTL correction, Quartus
build, RBF, deployment, or hardware-equivalence claim was made in this run.
## MCP preflight detail

The required MCP-first preflight was run against the pinned identities. `ping`
returned `pong=true`; `config_check` resolved the repository, MAME 0.289
executable and merged ROM path; `audit_romset` returned `romset dynagear is
good`; and `get_ioports` discovered the expected `:P1`, `:P2`, and `:SYSTEM`
fields. A persistent MCP MAME session then launched Dyna Gear, reported a
live frame/status, and stopped cleanly. The Verilator MCP preflight reported
headless display backend `none`, strict correctness defaults, and the expected
safe wrapper.

The MCP live surface does not preserve this project’s complete scenario
journal, strict-only canonical bus projection, native frame/state/audio
artifacts, or final zero-drop receipt contract. Therefore the paired
acceptance runs use the project-owned PowerShell/Lua and headless-Verilator
adapters, with the MCP capability gap recorded rather than substituting a
generic MCP trace. No MCP memory/register mutation was used.
