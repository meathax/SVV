# Session handover — 2026-08-21/22

## Current correction — debug overlay fully removed (2026-08-23)

The temporary ES5506 screenshot overlay was not a valid release feature. It
was removed from `Arcade-SSV.sv`, `rtl/ssv_core.sv`, and `files.qip`, and its
RTL source was deleted. The shared core now drives the native RGB path directly;
no `ovl_*` ports or overlay mux remain. This cleanup invalidates any prior
hardware visual result taken from the overlay-enabled 20260822 RBF. It does
not by itself close the independent audio or Vasara sprite failures.

## 1. RTL fixes committed (dfed31a)

- **ES5506 ECOUNT-freeze ramp abort** (`rtl/audio/ssv_es5506_regs.sv`): a host
  write that zeroes ECOUNT for a voice mid-slot now also aborts the
  LVOL/RVOL/K1/K2 ramp step for that voice, not just ECOUNT's own register.
  Per OTTO Rev 2.3 spec sec 11.5 (p35): the whole group is aborted together
  if ECOUNT is zero, checked "immediately before updating the oscillator."
- **V60 XCH memory-to-memory** (`rtl/cpu/v60/s32_v60.sv`): implemented via new
  states `S_XCH_MMRD1/2`, `S_XCH_MMWR1/2` — load op1, load op2, store op1,
  store op2.

Both pushed to `main` before this session's later work.

## 2. Diagnostic display cleanup (historical)

The temporary display was removed after confirming it contaminated the
release video path. No diagnostic pixels or release-only sound taps remain.

## 4. Sound warble investigation — user-supplied clips

Two screen recordings of the attract-mode name-entry/flag-select screen,
confirmed by the user to contain the actual "warped sound plays in and out"
bug. Overlay readout across both clips:

- **`sample_underrun`**: fires once early, then holds steady — does **not**
  keep re-firing through the clip. SDRAM sample-fetch starvation is
  therefore *not* the ongoing/repeating cause — rules out that failure
  class for the continuing warble (though the one early hit is worth
  keeping in mind).
- **`irq_promote` / `voice_writeback`**: continuous speckle throughout, as
  expected for normal per-voice servicing every frame — not informative by
  itself.
- **`sound_commit`**: sparse — few host register writes during this
  screen. The warble keeps occurring even between commits, so it is **not**
  new host writes racing the engine each time (i.e. not simply more
  instances of the §1 ECOUNT-freeze race, which needs a fresh host write to
  trigger).
- **`sample_req`/`sample_done`**: moderate steady cadence, no widening gap
  visible — fetch pipeline isn't stalling.

**Working theory**: the recurring warble is most likely an ES5506
frequency/phase-accumulator or ECOUNT-ramp arithmetic defect that doesn't
depend on host-write timing or SDRAM starvation — i.e. something in the
core interpolation/ramp math itself, not a timing race. The §1 fix
(ECOUNT-freeze ramp abort) is real and correct per spec, but evidently isn't
the whole story since the warble is still audible on this build.

**Next step (not started)**: reproduce this exact attract-mode scenario in
MAME and Verilator side by side and find the first sample-value divergence
in the ES5506 output — pins the actual arithmetic error rather than just
its timing envelope. Use the `mister-mame-diff` skill /
`mister-differential-debug.md` workflow.

## Outstanding / not done this session

- The current source cleanup is not yet deployed as a fresh hardware RBF.
- The corrected real-SDRAM Vasara 2 gameplay replay reached frame 380 with
  `deadline_aborts=0`, `bg_ack_while_obj_owns=0`, `CACHE_PEAK=328/2048`, and
  `max_line_entries=23`; its frame CRC passed. The first capture used a wrong
  native-width argument and therefore has no valid native-frame receipt.
- No MAME/Verilator differential run has yet identified the first sample-value
  divergence for the recurring warble itself.
- Not deployed to hardware.

## 5. 2026-08-22 MAME-versus-Verilator audio continuation

The differential lane is now implemented and has current paired captures.
MAME 0.289 and RTL are independently deterministic for the 156-frame
`audio_coin_prefix` scenario (journal SHA-256
`228498b4f97400c564a3feb704482b59d00bfbba0c659cefe9d7573fa52a85ef`).

The first RTL PCM captures peaked at only +/-1 because the headless testbench
compiled out its sample-ROM backend: `samples.bin` loading and p4 readback were
guarded by `SSV_VISUAL`, which the strict headless build does not define. This
was a verification-harness defect, not ES5506 RTL. The strict build now defines
`SSV_HEADLESS_SAMPLE_ROM`, enabling only sample ROM loading/readback without
enabling SDL or other visual code.

Closure evidence:

- The first fetches are the expected `c400`, `d000`, `c400`, `d000`, `d000`,
  `0400`, `d000`, `0400`; 60,588 fetches complete, 60,459 nonzero.
- RTL PCM peak advances from 1 to 2,720 (MAME prefix peak 3,222).
- Same-window RTL A/B traces match 184,186 normalized `cpu_data` events with
  no resynchronization; comparator digest
  `edebadc4cde0561370446824db2b8e7315fc40af18590a0950467161e288af8b`.
- PCM, frame, state, native-frame, and trace hashes match independently.
- The first aligned 50 ES5506 host writes match MAME. Write 51 diverges because
  the V60 observes the `FB24` main-loop/IRQ handshake at a different raster
  phase, so longer CPU-driven audio comparison is not yet trustworthy.
- The initial aligned waveform reaches correlation 0.884 over 5,000 samples
  after deterministic 31.25 kHz to 48 kHz resampling and a two-sample phase
  adjustment (fitted gain 0.929).

The corrected diagnostic replay was then repeated with the real sample backend
and a bounded ES5506 event trace. It completed 156 frames with 217,375 ES5506
events: 61 host commits, 182,763 voice writebacks, 21,630 sample requests,
7,210 sample completions, and 5,711 sample ticks. There were no dropped events,
sample underruns, renderer deadline failures, or RTL assertions. The trace
SHA-256 is
`871532950b57a878be540c8bb635c4687efbc4e92034df415a383aa2ee581c41`.

This closes the identified silent-audio defect and the ES5506 RTL semantic
boundary in simulation: the focused register/voice regressions pass, the exact
Drift Out voice prefix fetches the expected bank-2 words and produces material
PCM, and independent corrected RTL runs are byte-identical. The remaining
MAME-vs-full-core mismatch is upstream of ES5506: after the first 50 matching
sound commits, the V60 observes the FB24 main-loop/IRQ handshake at a different
raster phase. That makes later CPU-driven audio command order an invalid audio
engine comparator, not evidence of a new ES5506 arithmetic fault.

No synthesizable RTL, clock, reset, CDC, SDC, framework, or RBF changed in this
continuation. Physical MiSTer audio and the original recurring hardware warble
remain unverified because no board capture was available; claiming hardware
closure would exceed the evidence. The next experiment, if hardware or a
sound-command replay barrier becomes available, is to validate the same ES5506
event contract at the exact name-entry passage without changing V60 timing.

## 6. 2026-08-22 full gameplay audio and command-capture continuation

The corrected sample-ROM backend was carried through the complete 941-frame
`gameplay_neutral` journal. The gameplay-only lane reached its explicit entry
barrier at frame 820 and the 120-frame neutral soak, with a complete receipt:
`sim_output/diff/drifto94-audio-gameplay-fixed-b/rtl-receipt.json`. The run is
headless, one-thread, dropped=0, and contains 511,898 stereo source frames;
PCM peak is 2,720, the first non-zero source frame is 62,975, and the PCM hash
is `587dd709919874eb69c52308a66ca242c75305201e5ecd34b46684bc97bed159`.
The bounded ES5506 trace hash is
`4578c31a888cd22ff83e7dd0a708e1b2daac6ec1c491fcd53b9018ff5a8e17f5` and
contains 531,158 events (515,062 voice writebacks and 16,096 sample ticks)
with no underrun event. A first full replay also reached frame 940 but stopped
at finalization because the attract-only assertion was incompatible with this
gameplay journal; its common PCM prefix is byte-identical to the corrected
gameplay run. The dedicated attract lane remains the attract assertion gate.

MAME ES5506 bus capture is now pinned for the same journal and MAME 0.289:
`sim_output/diff/drifto94-audio-gameplay-mame-bus-80/mame-trace.jsonl`, SHA-256
`b8e5d8a72d2ec28da13a9a337029515d197d81f22f34bf00eecdfa5ac2f452c9`, with
3901066 main-bus and 461871 cpu-data events. The mapped sound writes repeat a
stable sequence at `0x300000-0x30007f`; the first 50 semantic host commits
remain the exact matching prefix already recorded above. The first later
divergence is still the V60 `FB24` main-loop/IRQ phase, not an ES5506 register
or sample fetch mismatch.

A bounded temporary diagnostic build substituted MAME's 11-bit interpolation
fraction for the production OTTO-spec 9-bit fraction. It made the aligned
prefix materially worse (correlation 0.786 over 1,000 samples and 0.590 over
3,000, versus 0.886 and 0.910 for production), so that hypothesis is rejected
and the production RTL was restored unchanged. No production sound fix beyond
the headless sample-ROM backend correction is justified by current evidence.

The sound issue is therefore closed as a verified simulation-harness defect and
as a deterministic non-silent ES5506 path. It is not closed as perfect MAME
equivalence or original-PCB warble removal: exact command replay into an
isolated ES5506 comparator and a real MiSTer/PCB audio capture remain the next
evidence threshold. No RBF was built.

## 7. 2026-08-22 native-rate sound equivalence audit

The MAME adapter now accepts `-AudioRate` and records `capture_audio_rate_hz`
in its receipt. A clean MAME capture at the ES5506 native stream rate (31,250
Hz) produced 110,626 stereo frames, peak 3,209, active onset 47,786, and WAV
SHA-256 `839c6a1253b41412c3cdf081bda83cb32f82a20184e9985c332bf6ed0d3fdacf`.
This removes the 48-kHz export resampler from the comparison. The corrected
RTL replay remains 104,314 source frames, peak 2,720, active onset 41,000.
After deterministic onset alignment, the 3,000-sample native comparison is
correlation 0.85169 and MAE 266.87; this is materially the same as the prior
resampled result, so the mismatch is in the ES5506 digital path (or its MAME
model), not WAV-rate conversion or host capture.

Three read-only diagnostic branches were falsified and removed from RTL:

- MAME's 11-bit interpolation fraction: no improvement for Drift Out because
  this title's active fractional steps are aligned to the OTTO 9-bit field.
- MAME high-pass history taps (`o2n2`/`o3n2`): correlation fell to 0.73067 and
  MAE rose to 1,247.3, so the production `o2n1`/`o3n1` recurrence is retained.
- MAME's intermediate volume lookup truncation: native correlation 0.85168,
  indistinguishable from production 0.85169, so the combined RTL shift is not
  the cause.

The higher-tier OTTO/spec audit still supports the production 9-bit
interpolator, 18-bit filter datapath, arithmetic shifts, panning narrowing,
and stopped-voice filter drain. No causal silicon-backed RTL correction has
therefore been identified. The sound lane is closed for the verified
simulation-harness defect (sample ROM was previously compiled out), but not
claimed as perfect MAME waveform equivalence or original-PCB analog
equivalence. Those claims require an isolated exact-command ES5506 replay or
a real board/MiSTer capture. No RBF was built.

## 8. 2026-08-22 Vasara 2 disappearing-sprite closure

After the audio audit, the pinned Vasara 2 journal was replayed through the
first active gameplay window. MAME 0.289 captured frames 50--80 with
`mame-trace.jsonl` SHA-256
`27d0adfafeceff83f8a55a3c6462bf1d7ba61ab24deb33ab79ec1539fbae6231`.
The clean one-thread RTL replay reached the same stop barrier with 81 native
frames, dropped=0, and `rtl-trace.jsonl` SHA-256
`26c6f10c0232f883b0067258bd5839ea7920c5fe3a28940ddb9a8e99235f941f`.

The strict bus comparator correctly rejects ordinal comparison at frame 50:
MAME's first captured event is a write at `0x00dfec` while RTL is still at a
different V60 read. This is the pre-existing CPU/raster phase divergence, not
a renderer event. The same sprite-list writes are present in both lanes; RTL
timestamps them at raster lines 247/250/261. Frame CRCs show MAME's first
moving frame at 55 and RTL's corresponding frame at 58, then unique stable
frames thereafter. This is a timing alignment issue and must not be “fixed” by
offsetting or cropping sprite output.

The actual disappearing-sprite root cause is the one fixed in commit
`54b550b`: a cache build is sequential (clear counts -> walk descriptors ->
prefix pooled bases -> reindex line entries), but the old deadline/capacity
abort path published `cache_count`/`cache_ready` from a partially built index.
That paired this frame's line counts with the previous frame's pooled bases and
line entries, so coherent groups (HUD/player) addressed the wrong descriptors
and vanished for repeated aborts. The fix routes list-walk aborts through the
bounded prefix/reindex finish and publishes an empty frame for aborts during
the torn phases; it never exposes a mixed index.

The new replay exercises that path with line-pool demand 256, maximum per-line
demand 2, cache peak 16 entries, build maximum 8,932 `clk_sys` cycles, zero
deadline aborts, zero cache overflows, zero line underruns, and no repeated
blank-frame CRCs after the initial CPU phase lag. No new RTL change is
justified: the causal renderer defect is already fixed, and the remaining
earliest MAME-vs-RTL divergence is the V60/raster schedule upstream of sprite
production. A hardware RBF load is still required to claim physical closure;
no RBF was built in this audit.

## 9. 2026-08-22 Vasara 1/2 complete sprite-pipeline audit

This audit used MAME 0.289 (`mame.exe` SHA-256
`af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3`)
and pinned `ssv_v.cpp` SHA-256
`49f3e1e06f5075627f23408652d1e651a1b9d2e6387a4a86284f61bc07370978`.
MAME is a behavioral reference here, not proof of PCB-cycle timing.

### A. Sprite RAM buffering / DMA

**KNOWN MAME behavior:** `ssv_state::draw_sprites` reads `m_spriteram`
directly (`ssv_v.cpp:756-769`); MAME 0.289 models no explicit sprite DMA,
register trigger, or private hardware latch. The physical PCB transfer scheme
therefore remains unknown. **KNOWN RTL behavior:** sprite RAM uses separate CPU
and renderer ports with registered read latency, and the renderer constructs a
private per-frame descriptor/index snapshot during VBlank. A directed test
changes live sprite RAM after publication and proves the displayed descriptor
does not change.

The real core defect was the torn cache index fixed in commit `54b550b`.
Deadline/capacity aborts previously published current per-line counts against
the previous frame's bases and pooled entries. That made coherent groups such
as player/HUD objects address unrelated descriptors and disappear. List-walk
aborts now complete prefix/reindex before publication; aborts during already
torn phases publish an empty layer. The new focused test forces that former
abort boundary and requires published line count to equal published cache
count. No guessed DMA trigger was added.

### B. Evaluation and line limits

**KNOWN MAME behavior:** the global list occupies the first 0x2000 bytes,
advances in four-word entries, terminates on global word 1 bit 15, and expands
`(global_mode[4:0] + 1)` locals (`ssv_v.cpp:758-778`). Coordinates are signed
10-bit values (`ssv_v.cpp:857-859`), not 8-bit wraparound. Width is 1/2/4/8
tiles and height is 1/2/4 tiles for ordinary sprites (`ssv_v.cpp:861-884`).
MAME models no silicon sprites-per-line limit.

**KNOWN RTL behavior:** the same terminator, local count, signed clipping,
size and list order are implemented. The focused regression covers sprites
crossing both vertical edges and fills all 2,048 descriptor slots with 64
globals x 32 distinct locals on the same eight scanlines: 16,384 pooled line
occurrences, with exact first-128 ordering. Vasara runtime maxima were 640/2048
descriptors, 9,936/24,576 occurrences and 77 entries on one scanline. Maximum
cache build was 27,600 `clk_sys` cycles with zero deadline aborts. These are
implementation bounds and observations, not claims about a physical silicon
limit.

### C. Line buffers

MAME composes objects directly into its indexed bitmap. The RTL uses a
four-slot line ring: a slot is cleared before reuse, only an opened render
epoch can write it, completed slots are consumed in order, and an underrun
repeats the prior complete line rather than exposing an in-flight bank. Pen 0
produces no write. The directed regression proves four-slot reuse clears stale
pixels, transparent/no-write pixels cannot erase an opaque object, and the
documented underrun behavior is deterministic. Both Vasara full-core runs
reported zero object and background overruns. The horizontal-band symptom was
caused by the torn per-frame index in A, not a clear or swap offset.

### D. Sprite-vs-sprite ordering

**KNOWN MAME behavior:** global and local entries are visited in ascending
list order and each later nonzero pen writes the bitmap, so later opaque
objects win (`ssv_v.cpp:756-907`, with pen-zero rejection in
`drawgfx_line`, `ssv_v.cpp:178-188`). The line-buffer regression writes two
opaque objects to the same pixels and proves the later entry wins. No reverse
index or first-write-wins hack was introduced.

### E. Priority / tilemap relationship

The proposed separate sprite-vs-tile priority mixer does not exist in the
pinned SSV model. Tilemaps are object-list entries, not independent playfields
with per-sprite priority bits. `screen_update` draws the automatic background
layer first and then the ordered object list (`ssv_v.cpp:946-981`); there is no
`priority_bitmap`/`pdrawgfx` path. Consequently the correct truth table is:
pen 0 preserves the current pixel; an opaque ordinary pen replaces it; a
shadow pen modifies it; and later list entries act after earlier entries.
Widening the line buffer for invented priority bits would be unsupported and
was rejected.

### F. Shadows

**KNOWN MAME behavior:** a shadow is not an opaque color. It replaces the high
two or four bits of the underlying 15-bit palette index with low pen bits:
`((dest & shadow_mask) | (pen << shadow_shift)) & 0x7fff`
(`ssv_v.cpp:140-188`, with mask/shift selection at `ssv_v.cpp:946-961`). The
RTL already implements that formula. Directed tests cover two-bit and four-bit
shadows, shadow after a character (modifies it), and shadow before a later
character (the later character replaces it). MAME itself labels some other
titles' shadow modes unverified, so no broader PCB-accuracy claim is made.

### G. Paired validation and remaining boundary

Vasara 2 has two deterministic 381-frame MAME captures and two deterministic
full-core one-thread Verilator captures. Its machine-readable frame comparator
matches all 141 ordered exact native RGB states; the only RTL-only state is the
declared pre-epoch partial frame. Vasara 1 likewise has two byte-identical MAME
trace/state captures and two byte-identical RTL frame/state/audio captures.
Its RTL frame SHA-256 is
`be0889c67c1e14326c48bc47b1515bed7bfa05ef70d87710f7a4787ff7eb91ad`
in both runs.

Vasara 1 does not pass exact final-pixel MAME equivalence after the fixed-frame
start sequence: the frame comparator reports a phase-diverged animated scene.
The stage comparator localizes that difference upstream of sprite attributes:
167/168 ordered `list512+spr8k` states match, every MAME sprite state through
frame 379 appears by RTL frame 380, the only candidate-only state is a
six-frame pre-start hold, and the only reference-only state is the terminal
tail. Final saved frames show the same scene, but palette/game-update phase is
different. This mismatch is retained, not masked or called a sprite pass.

Focused tests pass under Verilator 5.050 with assertions, unique-X semantics,
timing enabled, headless display-none and one runtime thread:

- 2,048 distinct on-screen descriptors on one scanline group / 16,384 pooled
  occurrences;
- signed top/bottom clipping and first/last-line inclusion;
- immutable per-frame snapshot after live sprite-RAM mutation;
- coherent publication at the former torn-index deadline abort;
- four-slot clear/reuse, transparent no-write, last-opaque-wins ordering;
- two/four-bit shadow, shadow-over-background and both shadow/character orders.

The only source edit in this audit outside tests is simulation-only: normal
watchdog-kick logging is now opt-in via `+WDOG_TRACE`; the unconditional print
made Vasara replay unusably slow. It is under `SIMULATION` and changes no
synthesized state, width, latency, reset, clock, CDC, memory, SDC or raster
contract. No new synthesizable sprite change was justified beyond `54b550b`.
No Quartus build or RBF was produced. Physical closure still requires loading
the existing timing-clean RBF containing `54b550b` on MiSTer and replaying the
reported Vasara 1/2 gameplay scenes; the physical DMA trigger and silicon line
limit remain unknown.

## 2026-08-23 — pasted two-bug plan closure audit

The pasted plan's two reported issues are closed at the currently supported
simulation boundary, with the remaining evidence gaps recorded rather than
treated as fixes.

### ES5506 warped/random audio

The causal corrections already landed in the source history are:

- `21cc47b`, `c369f84`, and `b971810`: host register writes cannot be clobbered
  by an in-flight engine writeback;
- `e39f901`: CR transition bits use sticky set/clear handling, preserving
  STOP/LEI/BLE/IRQ/DIR transitions across deferred writeback;
- `dfed31a`: ECOUNT-freeze ramp abort handling and the datasheet-backed
  accumulator, volume, filter-drain, and bank/address behavior;
- `tools/build_ssv_headless.ps1`: the strict headless harness includes the
  sample-ROM backend instead of silently compiling it out.

Fresh focused checks passed under Verilator 5.050 with assertions, timing,
unique-X semantics, headless display-none, and one runtime thread:
`tb_ssv_es5506_regs`, `tb_ssv_es5506_ulaw`, and `tb_ssv_es5506_voice`.
A fresh MAME 0.289 `drifto94` reference capture also completed 156 frames with
zero drops (`codex-audio-mame-a/mame-receipt.json`), using journal SHA-256
`228498b4f97400c564a3feb704482b59d00bfbba0c659cefe9d7573fa52a85ef` and MAME
SHA-256 `af6966108d9b52c22465c6d50f4e5d50cc371b50f2d27dc443935f287aad37a3`.

The archived complete full-core audio lane is deterministic, non-silent, and
has no sample-fetch underruns. Its earliest trustworthy MAME/RTL mismatch is
after the first 50 matching ES5506 host writes, at the V60 `FB24` main-loop/
IRQ raster phase. The current turn's fresh full-core RTL attempts were stopped
before their barriers and are not acceptance evidence. Therefore the remaining
audio claim is: the ES5506 unit-level and previously identified writeback
failures are fixed; exact long-run MAME waveform equivalence remains open until
an isolated command replay or a physical capture removes the upstream V60
phase ambiguity.

### Vasara 2 sprites invisible under load

`54b550b` is the causal fix. On a deadline/capacity abort, the renderer no
longer publishes a torn current-frame index paired with previous-frame line
bases and entries; it publishes a bounded coherent prefix or an empty frame.
The focused renderer regression reproduces the former abort and requires
`line_meta == cache_count`; it passes, as does the line-buffer suite.

The archived Vasara full-core lanes report no renderer overruns and preserve
ordered sprite states. The machine-readable Vasara 2 comparator matches all
141 ordered exact native RGB states, with only the declared pre-epoch partial
frame outside the comparison boundary. The remaining Vasara 1 phase-diverged
animated-scene result is retained as an upstream game-update/raster phase
mismatch, not masked as sprite equivalence. Physical DMA triggering and the
silicon sprite line limit remain unknown.

### Audit boundary

No new synthesizable RTL change was justified by this audit. No Quartus build
or new RBF was produced in this turn; the existing `releases/Arcade-SSV_20260823.rbf`
has not been hardware-validated. One non-fatal inferred-latch warning in
`rtl/audio/ssv_es5506_regs.sv` remains from the ECOUNT-freeze implementation;
it is a separate cleanup item and was not bundled with behavioral closure.

### 2026-08-23 — Quartus timing-closure seed experiment

The clean baseline compilation fit and assembled, but multicorner STA reported
worst setup slack `-0.152 ns` / TNS `-0.302 ns` in the reconfigurable HDMI PLL
`pll_hdmi|...|counter[0].output_counter|divclk` domain. Hold,
recovery/removal, and minimum-pulse-width checks were positive. This is the
same placement-sensitive framework domain documented in the QSF history.

As a single-variable timing experiment, the QSF seed was changed from `19` to
the documented next candidate `3`. No RTL, SDC, clock, reset, framework, or
generated file was changed. Acceptance requires a fresh full compile with all
four process/temperature corners clean, followed by compressed-RBF and release
artifact validation. The baseline unconstrained-port counts (4 input ports,
50 output ports) remain explicitly reported pending separate constraint review;
they are not waived by this seed experiment.

Seed 3 completed the clean full compile with fit and assembler success, but it
was rejected by multicorner STA. The active HDMI PLL domain measured setup
slack `-0.250 ns` / TNS `-0.478 ns` at Slow 100C and `-0.357 ns` / TNS
`-0.705 ns` at Slow -40C. Fast corners passed, as did all hold,
recovery/removal, and minimum-pulse-width checks. The generated compressed RBF
was retained only as diagnostic output and was not copied into `releases/`.

The next single-variable placement experiment is seed 23, selected from the
QSF's documented untried candidates. No RTL, SDC, clock, reset, framework, or
release file is changed by this experiment.

Seed 23 completed the clean full compile and assembled successfully, but was
rejected by multicorner STA. Slow 100C passed setup at `+0.115 ns`; Slow -40C
failed setup at `-0.207 ns` / TNS `-0.828 ns`. Hold, recovery/removal, and
minimum-pulse-width checks remained positive. Fitter utilization was
`40,968 / 41,910` ALMs (98%), `533 / 553` RAM blocks (96%), and `44 / 112`
DSP blocks (39%).

### 2026-08-23 — registered-mux resource experiment

**Observation:** The seed-23 fit remains within 942 ALMs of device capacity,
and the Quartus map report's `Multiplexer Restructuring Statistics` identifies
large registered muxes in project-owned V60 and ES5506 RTL while recording
that no restructuring was performed.

**Evidence:** `output_files/Arcade-SSV.map.rpt` attributes 30,463 own
combinational ALUTs to `s32_v60`, reports no RAM-inference failure, and lists
many registered muxes with positive estimated area savings. The matching QSF
setting is `MUX_RESTRUCTURE OFF`. This is **KNOWN** report evidence; the claim
that enabling it will improve the packed fit is **INFERRED** until measured.

**Hypotheses:** Enabling registered-mux restructuring will reduce ALM and
routing pressure; alternatively it may not survive packing or may increase
logic depth enough to worsen timing. A clean map and multicorner fit falsify
those alternatives directly.

**Selected explanation:** The measured area pressure is dominated by
high-fanin registered next-state muxes rather than failed RAM inference. A
bounded synthesis-option experiment is justified without changing modeled
hardware behavior.

**Smallest change:** Change only `Arcade-SSV.qsf` from
`MUX_RESTRUCTURE OFF` to `ON`; retain seed 23 for the first like-for-like
measurement. No RTL, SDC, clock, reset, CDC, memory, width, state, or latency
changes are permitted in this experiment.

**Verification:** Run a clean Quartus 17 map and compare total/per-entity
resources, then fit and run multicorner STA. Reject the experiment if the
resource saving is immaterial, inference changes unexpectedly, fit fails, or
timing does not close after the bounded seed step.

**Regression scope:** MiSTer `Arcade-SSV` only. This QSF-only, logically
equivalent synthesis transformation does not require a Verilator replay.

**Known unknowns:** Final packed ALM savings and the placement-sensitive HDMI
PLL response remain unknown until map/fit. The option was disabled in the
2026-07 history without a retained measured rationale.

The clean optimized seed-23 map reduced the estimate from 40,774 to 35,873
ALMs (4,901 saved), with RAM bits unchanged at 4,266,640 and DSP use unchanged
at 44. The corresponding fit packed into 35,664 / 41,910 ALMs (85%), saving
5,304 ALMs versus the unoptimized seed-23 baseline; RAM remained 533 / 553
blocks and DSP remained 44 / 112. This confirms the resource transformation.

Seed 23 is not timing-clean on the optimized netlist. Slow 100C passed setup
at `+0.017 ns`; Slow -40C failed at `-0.495 ns` / TNS `-2.075 ns`, with both
the core PLL general[1] and HDMI PLL domains contributing. Both fast corners
passed setup, and every hold, recovery/removal, and minimum-pulse-width check
was positive. The next isolated placement experiment is seed 2; no RTL, SDC,
clock, reset, framework, memory, or synthesis-option setting changes with it.

Seed 2 fit successfully at 35,693 / 41,910 ALMs (85%), 533 RAM blocks, and 44
DSP blocks, but was rejected by STA. Slow 100C setup was `-0.646 ns` / TNS
`-0.646 ns`; Slow -40C setup was `-0.655 ns` / aggregate TNS `-0.706 ns`.
The principal failure moved to the 96.63 MHz core PLL general[0] domain; the
HDMI domain additionally missed by `-0.092 ns` at Slow -40C. Both fast corners
and every hold, recovery/removal, and pulse-width check passed. Seed 19 is the
next isolated placement experiment because it was the closest documented
candidate on multiple earlier netlists. No other setting changes with it.

Seed 19 fit successfully at 35,663 / 41,910 ALMs (85%), with RAM and DSP use
unchanged, but was rejected by STA. Slow 100C setup passed at `+0.263 ns`;
Slow -40C setup failed at `-0.284 ns` / TNS `-1.268 ns` in the 48.32 MHz core
PLL general[1] domain. Both fast corners and every hold, recovery/removal, and
pulse-width check passed. Seed 31 is the next isolated placement experiment;
no other input or setting changes with it.

Seed 31 fit successfully at 35,655 / 41,910 ALMs (85%), with RAM and DSP use
unchanged, but was rejected by STA. Slow 100C setup passed at `+0.169 ns`;
Slow -40C setup failed at `-0.405 ns`. Both fast corners and every hold,
recovery/removal, and pulse-width check passed. Seed 11 is the next isolated
placement experiment; no other input or setting changes with it.

Seed 11 fit successfully at 35,622 / 41,910 ALMs (85%), with RAM and DSP use
unchanged, and passed every analyzed timing corner. Setup slack was `+0.264 ns`
at Slow 100C, `+0.011 ns` at Slow -40C, `+2.528 ns` at Fast 100C, and
`+2.587 ns` at Fast -40C. Worst hold, recovery, removal, and minimum-pulse
width slacks were all positive. Seed 11 is therefore the accepted candidate,
subject to a clean full compile under unchanged inputs and final artifact audit.

The required clean Quartus 17.0.2 full compile reproduced the seed-11 result
exactly and completed map, fit, multicorner STA, and assembler successfully.
Final resources are 35,622 / 41,910 ALMs (85%), 533 / 553 RAM blocks (96%),
4,266,640 memory bits (75%), and 44 / 112 DSPs (39%). Worst setup/hold slacks
are `+0.011 ns` / `+0.041 ns`; recovery, removal, and minimum-pulse-width
slacks are all positive. The fresh RBF is 4,443,980 bytes with SHA-256
`0934DC4662AB1A5AE6B328479BCC5ABDA1C6DE43B18106E00D3A320B71B6724B`.
There are zero unconstrained clocks. The retained unconstrained external-port
inventory is 4 optional input ports / 14 paths and 50 optional output ports /
77 paths; no active internal clock endpoint is unconstrained. No RTL, SDC,
clock, reset, CDC, width, state, latency, memory mapping, or framework file was
changed by this optimization pass.

### 2026-08-24 — Vasara 2 sprite-cache restart coalescing

**Observation:** The clean Vasara 2 gameplay replay reached a dense sprite-list
window where accepted CPU writes repeatedly restarted the vblank descriptor
cache. In the baseline replay, the cache reached `cache_cnt=0` around frame 236
and stayed empty through frame 252 while the build was being restarted during
`BUILD_REINDEX`; storage was not near capacity (`328 / 2048` descriptors and
`5248 / 24576` pooled entries at the dense peak).

**Evidence:** Baseline session
`sim_output/codex-baseline-vasara2-20260824` and candidate session
`sim_output/codex-first-write-full-vasara2-20260824` use the same descriptor
SHA-256 `e7bbf4c337384e694a43b392fabdbadbc2b60811eadf463094c1f7ccd964e475`,
MRA SHA-256
`575b327bd9da4cf5848cf3368555697ba006f2b342153378d1aac30a509e9ec2`, and
scenario semantic SHA-256
`0482cc5f52ce92ec5b6b158b2f064fbe1bbb07a68011d9723427d0967edecd5f`.
The pinned MAME 0.289 frame trace has SHA-256
`41e987635f6817419c30321d9bb4452ebc3ef4d371e1374b78047cc58365aa84`.

**Hypotheses:** (1) per-write cache restart starvation; (2) real SDRAM p2
latency/arbitration; (3) descriptor or line-pool capacity. The baseline
occupancy falsifies (3) for this scenario. A bounded real-SDRAM gameplay replay
is retained as a separate latency check; it reached frame 129 in the dense
window with no renderer overrun, but was intentionally stopped before the
scenario's frame-260 gameplay barrier.

**Selected explanation:** **INFERRED** per-write restart starvation is the first
causal producer of the observed empty publication. The restart pulse was
repeated while the CPU walked the list, so the cache spent its protected
vblank budget re-entering its clear/read phases instead of completing one
coherent index.

**Smallest change:** In `rtl/ssv_core.sv`, coalesce accepted sprite-list and
scroll writes in lines 240–248 into one restart pulse, then suppress later
writes until the window ends. In
`rtl/video/ssv_cached_sprite_renderer.sv`, allow that one pulse to rewind even
`BUILD_CLEAR_LINES`; later writes cannot restart the clear again. No CPU clock,
chip clock, SDRAM timing, memory size, address map, or framework file changed.

**Verification:** The candidate completed the 381-frame cold headless replay
with `dropped=0`, `deadline_aborts=0`, `overruns bg=0 obj=0`,
`CACHE_PEAK=328`, `SIM_LINE_DEM_MAX=23`, and `CACHE_BUILD max=14545` cycles.
The ordered MAME frame comparator returned `match=true` for all 381 frames;
the dense duration delta present in the baseline was absent. The sprite-cache
and line-buffer unit tests both passed. Final Verilator build: 5.050,
headless, `--threads 1`, 7.510 MB / 31 modules; the pre-existing
`ssv_es5506_regs.sv:338` latch warning remains non-fatal.

**Regression scope:** Vasara 2 gameplay, shared cached sprite renderer,
line-buffer scheduling, p2 graphics arbitration, and all SSV titles that use
the shared renderer. MAME/Verilator MCP capabilities were not exposed in this
environment, so the repository-owned headless lanes were used. No Quartus or
RBF build was run.

**Known unknowns:** The real board's exact SDRAM arbitration margin and final
MiSTer hardware display behavior still require a Quartus build and hardware
load. Raising `SSV_CPU_INC` or chip clocks is not justified: those are board
cadences, and the existing 16 MHz lockstep evidence warns that even a one-count
change alters dependent audio timing. The next evidence threshold is a full
real-SDRAM gameplay soak or hardware capture if the physical symptom persists.

## 9. 2026-08-25 Drift Out full-gameplay audio additional-voice audit

The exact 941-frame `gameplay_neutral` journal was replayed through the
declared gameplay-entry barrier at frame 820 and the final frame 940. The
strict headless Verilator lane used one runtime thread, timing enabled,
unique-X semantics, display backend `none`, and completed with zero dropped
events, zero audio underruns, and zero renderer deadline failures. The
slot-diagnostic receipt is
`sim_output/diff/drifto94-audio-gameplay-slotdiag-20260825/rtl-receipt.json`
(SHA-256
`ed0cc057ceaa6c0523bd55fead63a3e4cd02095c25627b7bab5759b3b3da3524`), with
PCM SHA-256
`a72315f5c6a84e9cbf90c881b03495fb4dca807021fc03842a8a6811cf7e10a2` and
trace SHA-256
`573008ba09cda7a6df4e94ed593639a7f4a1d542087589483adae59699d08666`.

Two clean MAME 0.289 native-rate captures of the same journal are byte
identical: 31,250 Hz WAV SHA-256
`d028dc4db229dfcfd5b60872b0b5266402515357bbae29a5d015e06e0bd60490` in both
runs. Their deterministic 48 kHz normalized PCM also matches in both runs
with SHA-256
`27a6190c4269c0e9f936a50ecdbb4e4aecb995cd7f6779132743c687a74d7db3b2`.
The RTL and MAME audio envelopes contain the same two broad music-active
regions after onset alignment, but the native PCM content and level are not
equivalent; this is a real remaining audio divergence, not a WAV-rate
conversion artifact.

**Observation:** The reported extra-sound symptom is not explained by an RTL
voice remaining active after its host control state has stopped. The full
replay has a waveform mismatch and command-phase drift once music is running.

**Evidence:** **KNOWN** — MAME and RTL are independently deterministic under
the pinned journal. **KNOWN** — the reconstructed MAME and RTL host streams
each contain 219 active CR writes (`STOP1|STOP0 == 0`). **KNOWN** — per-voice
RTL snapshots compared with an RTL-owned host-register model found 17 CR
mismatches, all `0x2001/0x6001` engine STOP0 transitions versus host
`0x2000/0x6000`; these transitions suppress a natural voice tail and cannot
create an additional voice. **KNOWN** — no snapshot showed a stale active
voice after its host CR had stopped. **INFERRED** — the remaining active-mask
differences are command timing/order drift: the best global frame alignment is
approximately 11 frames, and the long exact host-command blocks recur at
different frame positions. A bounded prefix also shows the RTL polling the
ST010 data port 27 times where MAME polls 5 times, identifying an upstream
CPU/DSP cadence difference that must not be repaired with an audio gain or
voice mask.

**Hypotheses:** (1) stale ES5506 voice state creates extra sound — falsified by
the slot/host-state comparison; (2) V60/raster/ST010 command cadence changes
the timing and order of otherwise valid music commands — remains **INFERRED**;
(3) ES5506 interpolation, filter, or fixed-point arithmetic creates the
remaining waveform difference — remains **HYPOTHESIS** because the current
OTTO/spec audit conflicts with some MAME implementation details and no
physical waveform or exact-command isolated replay selects it.

**Selected explanation:** No functional core explanation is proven for an
additional voice. The only demonstrated correction in this continuation was a
diagnostic-lane defect: the behavioral SDRAM harness was bypassing the P5
response used for ST010 program memory. Selecting the behavioral P5 data/ack
response restored the real ST010 fetch path and later gameplay audio. This is
not a synthesizable core correction.

**Smallest change:** Keep the P5 harness mux repair and the opt-in per-voice
snapshot trace. No ES5506 register, voice, clock, reset, CDC, gain, filter,
interpolation, or timing behavior was changed.

**Verification:** The strict model was rebuilt in
`R:\Verilator\SVV\tool-20260824T192708298Z-30724-35504921` and the complete
journal was rerun cold. The result reached attract/gameplay barriers and the
stop barrier with no underrun/drop. The diagnostic trace is retained in
`sim_output/diff/drifto94-audio-gameplay-slotdiag-20260825/rtl-trace.jsonl`.

**Regression scope:** Full Drift Out gameplay audio, the existing audio coin
prefix, ST010 program/data transport, ES5506 host/engine traces, and the
headless harness. No Quartus or RBF build was run.

**Known unknowns:** The earliest PCM sample-value producer after command
alignment is not isolated, the exact PCB audio behavior is unmeasured, and
the physical audio CDC/output path remains unverified on MiSTer. A core audio
RTL fix remains blocked until an exact-command replay, stronger board evidence,
or a causal V60/raster/DSP timing divergence is proven. No final RBF was built.
