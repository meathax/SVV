# Universal SSV profile

The project has one Quartus revision (`Arcade-SSV`) and produces one runtime
core, `SSV.rbf`. There are no per-game RBF variants. Every qualified MRA loads
a 16-byte index-1 descriptor before index-0 ROM data; that descriptor selects
the ROM geometry and optional board paths at runtime.

`tools/ssv_supported_sets.py` is the authoritative release list. It currently
matches the eight supported ROM archives. Two retired local archives are kept
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

The current source-exhaustion and gameplay-proof pass runs the eight supported
sets in `PARENT_RUN_ORDER`, in the owner-selected order Dyna Gear, Vasara,
Vasara 2, then Cair Blade, Drift Out '94, Storm Blade, Twin Eagle II, and Ultra
X. There are no clone/review entries in the release profile.

The descriptor also carries the exact graphics modulo geometry, populated
graphics quarters, ES5506 bank-valid/map fields, sample-stream size, and
watchdog mode. The same sprite/background/audio/input/DSP implementation is
always synthesized, so fixes and enhancements are shared by every set.
The shared ES5506 voice path also handles `CR_CMPD`: its OTTO compressed-sample
decoder is source-backed by MAME and focused-tested both at the table level and
after the filter/mixer pipeline. This is implementation evidence only; it does
not promote any set past the real-ROM attract and screenshot gates below.

Run the structural and local-media audit with:

```powershell
python tools/verify_ssv_universal_profile.py --require-roms
```

This verifies that every qualified archive has one MRA, every MRA selects
`SSV`, descriptors are ordered/checksummed/unique, supported memory geometries
fit the universal SDRAM map, and every named ROM part exists locally.
Presentation rotation is generated from MAME (`ROT0` -> `horizontal`,
`ROT270` -> `vertical (ccw)`) and checked for all eight manifest entries; raw
Verilator/MAME comparison remains on the same native unrotated raster.

Qualification status is not the same as full gameplay accuracy. Historical
strict Verilator attract runs passed for Dyna Gear and Cairblad in saved
360-frame runs with no renderer overruns, but those runs are not current
release evidence until they are rerun through the screenshot gate below.
Vasara 2 now reaches a visible attract logo in the bounded current universal
model: a 120-frame MAME/Verilator session was exact through frame 54 and first
diverged at frame 55 in the logo bounding box (98.2949% exact pixels, 1,375
pixels different). Video state first diverged at frame 8, with no renderer
overrun. This is close-attract evidence, not the required gameplay proof or
the 360-frame screenshot gate. A shared exact-consecutive ordinary-descriptor
cache suppression is source-integrated. The shared behavioral visual model now
also serves the ST010 program-fetch burst and loads the 2,048-word ST010 data
ROM before releasing the core: Storm Blade reaches completed frames (30-frame
replay, exact pixels through frame 5), and Drift Out reaches a completed first
frame with exact pixels and state. Those are bounded bring-up results only; all
strict passes must still be rerun after the current shared renderer and map
changes before release evidence is considered current.

A pinned MAME reference sweep now has 20-frame CRC/state streams for all eight
current authoritative sets. Reference streams for retired local archives are
historical only; none count as Verilator attract or screenshot evidence.

The native SDL Verilator harness has independently proved the live-window path
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

For the eight parent-ROM games in this audit (`dynagear`, `vasara`, `vasara2`,
`cairblad`, `drifto94`, `stmblade`, `twineag2`, and `ultrax`), none currently
meets the complete goal standard: 0/8 have a current 360-frame Verilator
attract screenshot gate plus matched gameplay proof.

| Set | Boots to attract | Attract progress | Current evidence boundary |
|---|---|---:|---|
| `dynagear` | Three post-transition tokens matched; gameplay not proven | 0% | Current tokens 2 through 4 match MAME exactly in pixels, trace, and state with healthy renderer counters. Token 1 is a mid-epoch presentation transition, not a renderer mismatch. Owner-required same-run Verilator gameplay plus screenshot/soak gate remains pending |
| `cairblad` | Three-frame boot replay exact | 0% | Current geometry-corrected visible replay matched 3/3 frames pixel-for-pixel at 338x240. State matched after the first boot frame; the 360-frame Verilator screenshot/attract gate remains pending |
| `vasara` | Not proven | 0% | Shared MAME-equivalent IRQ-line refresh repair passes its focused test and preserves Dyna tokens 2-4 exactly. Current visible lockstep is exact in pixels through frame 118; the first visible VISCO-logo mismatch is frame 119 (1,252 pixels, 98.4474% exact). The trace shows MAME's approximate 8-cycle V60 model completing the palette/list workload earlier than RTL; this is a measured CPU-phase limitation, not an IRQ storm. Gameplay and the strict 360-frame Verilator screenshot gate remain pending. |
| `vasara2` | Not proven | 0% | Current visible lockstep `vasara2-attract120-20260802` is exact through frame 54 and first differs at frame 55 in the logo box (1,375 pixels, 98.2949% exact); state first differs at frame 8. No renderer overrun was reported. This is close-attract evidence only; the 360-frame Verilator screenshot and matched gameplay proof remain pending. |
| `drifto94` | Completed first frame; longer replay diverges | 0% | Native geometry is 336x238. The current ST010-backed one-frame replay is pixel/state exact; a bounded 30-frame probe reached frame 16 before the session wall-clock ceiling and had already diverged heavily after frame 11. Attract/gameplay gate remains pending |
| `stmblade` | Completed frames; short replay diverges | 0% | Native geometry is 352x240. The current ST010-backed replay completed 30/30 frames with no renderer overrun; frames 1-5 were pixel-exact, then the first visible divergence was frame 6 (94.51% exact by frame 30). ST010-specific trace evidence and the strict attract/gameplay gate remain pending |
| `twineag2` | Boot timeout before first compared frame | 0% | Native MAME preflight is valid at 336x240. The visible RTL model still did not reach a ready frame within the bounded 90-second one-frame probe; ST010/IRQ1 gameplay proof remains pending |
| `ultrax` | Boot timeout before first compared frame | 0% | Native MAME preflight is valid at 336x240. The visible RTL model opened and executed reset-vector reads, but did not reach a ready frame within the bounded 90-second one-frame probe; IRQ1 gameplay proof remains pending |

Historical strict attract progress remains 2/8 games (25%), while
current screenshot-qualified release progress is 0/8 until Dyna Gear,
Cairblad, Vasara 2, and every remaining set are rerun under the updated gate.

The same descriptor-driven runner selects each title and does not create a
second core or RBF. The current matrix gate uses 360 post-video-enable frames,
requires the attract milestone, stops on renderer overrun, and requires a
non-empty Verilator screenshot from that run; evidence remains set-specific.
MAME validation and MAME screenshots remain reference-only and cannot satisfy
the Verilator attract gate.
