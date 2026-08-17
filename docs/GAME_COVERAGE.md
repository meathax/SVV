# Universal SSV profile

The project has one Quartus revision (`Arcade-SSV`) and produces one runtime
core, `Arcade-SSV.rbf`. There are no per-game RBF variants. Every qualified MRA loads
a 24-byte version-3 index-1 descriptor before index-0 ROM data; that descriptor selects
the ROM geometry and optional board paths at runtime.

`tools/ssv_supported_sets.py` is the authoritative release list. It currently
matches the nine supported ROM archives. One retired local archive is kept
for reference but are not profile entries or generated support descriptors:

| Set | Hardware family selected at runtime |
|---|---|
| `dynagear` | 1 MiB program, 16 MiB graphics, `$400000-$43ffff` RAM, read-kick watchdog |
| `cairblad` | 2 MiB program, 32 MiB graphics, identity tile scrambling, 64 KiB NVRAM |
| `vasara`, `vasara2` | 4 MiB program, 32 MiB graphics, two ES5506 banks, write-kick watchdog |
| `drifto94` | ST010, 4 MiB program, 32 MiB graphics, 2 KiB NVRAM, no watchdog |
| `stmblade` | ST010, 4 MiB program, 24 MiB graphics, 2 KiB NVRAM, no watchdog |
| `twineag2` | ST010, `$010000-$03ffff` RAM, IRQ level-1 line 0, four ES5506 bank aliases |
| `ultrax` | 12 MiB graphics, `$010000-$03ffff` RAM, IRQ level-1 line 0 |
| `survartsu` | 1 MiB program, 24 MiB graphics, `$400000-$43ffff` RAM, read-kick watchdog, live six-button `$500008` window |

The current source-exhaustion and gameplay-proof pass runs the nine supported
sets in `PARENT_RUN_ORDER`, in the owner-selected order Dyna Gear, Vasara,
Vasara 2, then Cair Blade, Drift Out '94, Storm Blade, Twin Eagle II, and Ultra
X, followed by Survival Arts (USA). The release profile contains that one USA
clone entry and no review-only entries.

The descriptor also carries the exact graphics modulo geometry, populated
graphics quarters, ES5506 bank-valid/map fields, sample-stream size, and
watchdog mode. The same sprite/background/audio/input/DSP implementation is
always synthesized, so fixes and enhancements are shared by every set.
The ST010 is likewise always synthesized and selected only by
`cfg.has_st010`; the pre-RBF audit rejects any compile-time ST010 gate so an
RBF cannot silently omit Drift Out '94, Storm Blade, or Twin Eagle II support.
The shared ES5506 voice path also handles `CR_CMPD`: its OTTO compressed-sample
decoder is source-backed by MAME and focused-tested both at the table level and
after the filter/mixer pipeline. This is implementation evidence only; it does
not promote any set past the real-ROM attract and screenshot gates below.

Run the structural and local-media audit with:

```powershell
python tools/verify_ssv_universal_profile.py --require-roms
python tools/verify_ssv_hardware_shapes.py
python tools/verify_ssv_diff_readiness.py
```

This verifies that every qualified archive has one MRA, every MRA selects
`SSV`, descriptors are ordered/checksummed/unique, supported memory geometries
fit the universal SDRAM map, and every named ROM part exists locally.
Presentation rotation is generated from MAME (`ROT0` -> `horizontal`,
`ROT270` -> `vertical (ccw)`) and checked for all nine manifest entries; raw
Verilator/MAME comparison remains on the same native unrotated raster.

Qualification status is not the same as full gameplay accuracy. All visible,
SDL and protocol-v2 results below are historical evidence from pre-readiness
models. The active differential configuration is now windowless and non-SDL;
the gameplay lane uses the versioned scenarios in
[`GAMEPLAY_CONVERGENCE.md`](GAMEPLAY_CONVERGENCE.md), the shared immutable
journals compiled by `tools/ssv_gameplay_scenario.py`, and `cpu_data` as the
candidate strict domain. No set is qualified until two cold same-side
reproductions and the 120-frame neutral-soak gate pass.

Historical
strict Verilator attract runs passed for Dyna Gear and Cairblad in saved
360-frame runs with no renderer overruns, but those runs are not current
release evidence until they are rerun through the screenshot gate below.
One older Vasara 2 model reached a visible attract logo in a bounded universal
model: a 120-frame MAME/Verilator session was exact through frame 54 and first
diverged at frame 55 in the logo bounding box (98.2949% exact pixels, 1,375
pixels different). Video state first diverged at frame 8, with no renderer
overrun. This is close-attract evidence, not the required gameplay proof or
the 360-frame screenshot gate. A later 360-frame strict run remained black
through frame 359. These records conflict, so frozen-source Vasara 2 behavior
is unverified until the new cold headless captures resolve it. A shared
exact-consecutive ordinary-descriptor
cache suppression is source-integrated. The shared behavioral visual model now
also serves the ST010 program-fetch burst and loads the 2,048-word ST010 data
ROM before releasing the core: Storm Blade reaches completed frames (30-frame
replay, exact pixels through frame 5), and Drift Out reaches a completed first
frame with exact pixels and state. Those are bounded bring-up results only; all
strict passes must still be rerun after the current shared renderer and map
changes before release evidence is considered current.

A pinned MAME reference sweep has 20-frame CRC/state streams for the previous
eight authoritative sets. Survival Arts is now a supported target, but its
current attract/gameplay capture is still pending; reference streams for the
retired local archive are historical only and none count as Verilator attract
or screenshot evidence.

The 10 Aug pre-RBF resource pass is shared across the previous eight descriptors
and the new Survival Arts descriptor selects the same universal paths; it
does not change this qualification matrix: V60 `MULX/MULUX` reuse the existing
serial multiplier, and the renderer removes a duplicate line-base read/table.
Arithmetic and static checks pass, but no set receives new attract/gameplay
credit until the affected visible universal-model regressions are rerun.

The retired native SDL Verilator harness independently proved the historical live-window path
on Dyna Gear: the pre-audio harness model opened a responsive native window, reached
its first changing/nonblack framebuffer at frame 214 (checksum `d512913d`,
76,852 nonblack pixels), and continued beyond frame 1,000 with keyboard and
controller polling live. The current audio/watchdog/protocol-v2 harness builds
with Verilator 5.050. Its first bounded current-source Dyna token matched all 30
accepted bus events plus PC, sprite/list and palette CRCs, but the RTL frame was
black while MAME displayed the 8,830-pixel Sammy logo. Scroll-state comparison
now excludes MAME's word-0 status overlay, and focused simulation repaired a
missing pooled-line descriptor prefetch that made every slot after zero reuse
descriptor zero. Clock-corrected bounded session `dynagear-20260801-205514` then
matched three consecutive aligned post-transition tokens (2 through 4)
exactly: 241,920/241,920 pixels, 90/90 bus events, and all state digests, with
zero cache overflow or blocked swaps. Both processes closed normally after
37.8 seconds. A separate checkpointable visual profile has also completed a
real fresh-process round trip: frame 2 saved a 47,486,254-byte binary archive,
frames 3 and 4 resumed in new visible processes, and their frame/state CRC
lines match the uninterrupted timing model exactly. This allows Dyna gameplay
progress to be accumulated in short slot-friendly runs, but is useful
simulator infrastructure evidence rather than gameplay proof. The new v2 proof
chain has cold-run visibly through frame 50 and then restored in a fresh visible
process through frames 100 and 150, producing a 47,486,366-byte archive whose
SHA-256 matches its sidecar and an immutable RTL-owned packet prefix through
frame 151.
The earlier frame-100 v1 archive is intentionally ineligible
for final lockstep because it predates that input journal. It
is not the scripted 360-frame `REQUIRE_ATTRACT` assertion plus same-run P6
screenshot, so Dyna Gear deliberately remains 0% below.

## Attract progress

The per-game percentage below is deliberately binary: 100% means the same
current universal-model Verilator run completed the 360-frame `attract_idle`
gate with `attract=1`, zero renderer overruns, and emitted a non-empty P6
PPM/PNG screenshot from an attract frame. MAME runs or MAME screenshots are
behavioral-reference evidence only and never count toward this gate. A
missing, empty, or MAME-only capture leaves the game at 0% until the
Verilator run is repeated with its screenshot.

For the nine supported entries in this audit (`dynagear`, `vasara`, `vasara2`,
`cairblad`, `drifto94`, `stmblade`, `twineag2`, `ultrax`, and `survartsu`), none
currently meets the complete goal standard: 0/9 have a current 360-frame Verilator
attract screenshot gate plus matched gameplay proof.

| Set | Boots to attract | Attract progress | Current evidence boundary |
|---|---|---:|---|
| `dynagear` | Three post-transition tokens matched; gameplay not proven | 0% | Current-source attract lockstep is pixel/trace/state exact through frame 179; frame 180 first differs only in sprite-RAM CRC and the bottom credit strip because MAME's approximate V60 completes one sprite-list pass earlier. Owner-required same-run Verilator gameplay plus screenshot/soak gate remains pending |
| `cairblad` | Current boot replay exact through frame 13 | 0% | Current 338x240 lockstep is pixel-exact through frame 13; sprite-RAM state first shifts at frame 12 and the Sammy logo first appears one frame earlier in MAME at frame 14. This is a CPU-phase boundary, not a graphics-layout proof; the 360-frame Verilator screenshot/attract gate remains pending |
| `vasara` | Not proven | 0% | Shared MAME-equivalent IRQ-line refresh repair passes its focused test and preserves Dyna tokens 2-4 exactly. Current-source visible lockstep is exact in pixels through frame 115; frame 116 first differs only in the VISCO-logo box (1,252 pixels, 98.4474% exact). The first causal trace difference is a frame-edge watchdog write at `$210000`, the correct MAME `ryorioh_map` write-kick; the remaining state/PC shift is a measured CPU-phase boundary, not an IRQ storm. Gameplay and the strict 360-frame Verilator screenshot gate remain pending. |
| `vasara2` | Not proven | 0% | Historical evidence conflicts: `vasara2-attract120-20260802` reached a logo and was exact through frame 54, while a later strict 360-frame gate remained black through frame 359. Frozen-source behavior is unverified; the new cold headless determinism captures must resolve this before any cross-side claim. |
| `drifto94` | Name/flag/car flow reaches the Monte Carlo map; live driving not yet reached | 0% | Native geometry is 336x238. A visible fixed-core replay restored at frame 270 and compared all 430 frames through frame 700, then wrote a verified full-state checkpoint. The first cabinet-port data mismatch at `$21000c` is fixed (`00ff` on both sides). Pixels were exact on 267/430 frames, including frame 700; the first visible difference was a 240-pixel selection animation at frame 341 and later map animation differences reconverged repeatedly. The earliest remaining trace difference is an extra side-effect-free RTL byte read, while sampled ST010 PC phase also differs. This is map-intro evidence, not controllable-gameplay qualification. |
| `stmblade` | Completed frames; short replay diverges | 0% | Native geometry is 352x240. The current ST010-backed replay completed 30/30 frames with no renderer overrun; frames 1-5 were pixel-exact, then the first visible divergence was frame 6 (94.51% exact by frame 30). ST010-specific trace evidence and the strict attract/gameplay gate remain pending |
| `twineag2` | Reaches frames; short replay diverges | 0% | Native 336x240 visual lockstep with ST010 evidence now runs 20/20 frames without renderer overrun. RTL matches MAME on frames 2-9, 11-12, and 14-21; frame 10 is a 54,162-pixel raster-line-78 split and frame 13 a 43,344-pixel partial split caused by RTL's live palette-0 update during MAME's frame-level indexed-bitmap snapshot. The shared blank path now uses MAME pen 0 instead of hard RGB black. State/trace alignment differs at the boot boundary; IRQ1 gameplay, strict attract, and sustained-play proof remain pending |
| `ultrax` | Reaches frames; short replay diverges | 0% | Native 336x240 visual lockstep compared frames 2-18: pixels were exact through frame 17, then frame 18 differed in a 2,014-pixel box (97.5025% exact). State/trace alignment was already different at frame 2; ST010/IRQ1 gameplay and the strict attract gate remain pending |
| `survartsu` | Not yet run | 0% | Descriptor, ROM mapping, and six-button control path are integrated; current attract/gameplay and screenshot evidence remain pending |

Historical strict attract progress remains 2/9 supported entries (22.2%), while
current screenshot-qualified release progress is 0/9 until Dyna Gear,
Cairblad, Vasara 2, and every remaining set are rerun under the updated gate.

The same descriptor-driven runner selects each title and does not create a
second core or RBF. The current matrix gate uses 360 post-video-enable frames,
requires the attract milestone, stops on renderer overrun, and requires a
non-empty Verilator screenshot from that run; evidence remains set-specific.
MAME validation and MAME screenshots remain reference-only and cannot satisfy
the Verilator attract gate.
