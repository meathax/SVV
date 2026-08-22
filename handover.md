# Session handover — 2026-08-21/22

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

## 2. Sound debug overlay (uncommitted)

Added to chase the still-unresolved ES5506 warble (see §3):

- [rtl/debug/ssv_debug_overlay.sv](rtl/debug/ssv_debug_overlay.sv) — new
  module. Draws a column of squares over the right edge of the active
  picture. Rows 0-7 are toggle flip-flops (flip on each pulse of their
  monitored signal — green=1/red=0); row 8 is 5 squares showing the raw
  5-bit last-serviced voice index. Row order top-to-bottom: `sound_commit`,
  `irq_promote`, `voice_writeback`, `sample_req`, `sample_done`,
  `sample_tick`, `sample_underrun`, `frame_boundary`, `voice_index[4:0]`.
- [rtl/ssv_core.sv](rtl/ssv_core.sv) — added a new **unconditional** `ovl_*`
  port block mirroring the sound-path signals the overlay needs. Necessary
  because the existing `debug_*` bus is gated `` `ifdef SIMULATION `` and is
  stripped from synthesis — the overlay needs these signals in a real RBF,
  not just sim.
- [Arcade-SSV.sv](Arcade-SSV.sv) — wires `ovl_*` from `ssv_core`, instantiates
  `ssv_debug_overlay`, muxes its output into `av_r/g/b` ahead of the
  scandoubler, gated by `localparam DEBUG_OVERLAY_EN` (currently **`1`** —
  **flip to 0 before any real release build**).
- [files.qip](files.qip) — added the new source file.

Interpretation caveat baked into the module's own header comment: a square
whose monitored signal pulses faster than once per video frame (e.g.
`voice_writeback`, `irq_promote`, which fire per-voice every frame) will
show as red/green speckle rather than a flat color — that's scanout
sampling a flip-flop that changed value mid-frame, not a rendering bug.

## 3. RBF build

Built clean with the overlay enabled: `releases/Arcade-SSV_20260822.rbf`
(SHA-256 `b7bdf1f3aaa6b4323c6dd60adb6240e4c0121c9b3e028ee094bc412fff76f7fd`),
0 errors, positive setup/hold slack, 98% ALM. Full report already given
earlier in-session. **Ships with the debug overlay visible on-screen** —
intentional, for the screenshot/video capture below. Not yet committed.

First compile attempt failed (`can't find port "debug_hpos"` etc.) because
the top level wired the sim-only `debug_*` bus into synthesis — fixed by
adding the unconditional `ovl_*` ports instead (§2).

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

- Debug overlay files are **uncommitted** (`git status`: `Arcade-SSV.sv`,
  `rtl/ssv_core.sv`, `files.qip` modified; `rtl/debug/` and
  `releases/Arcade-SSV_20260822.rbf` untracked).
- `DEBUG_OVERLAY_EN` must be set back to `0` before any real release build.
- No MAME/Verilator differential run has been done yet for the warble
  itself — only the on-screen overlay read from user-supplied video.
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
