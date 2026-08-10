# SSV MiSTer FPGA Core

The SSV core emulates the Sammy, Seta, and Visco (SSV) arcade PCB family on
MiSTer. The FPGA target is the MiSTer DE10-Nano/Cyclone V
`5CSEBA6U23I7`; the board being emulated is the SSV arcade hardware used by
the supported games below.

This project produces one universal `Arcade-SSV.rbf`. Each MRA loads a
descriptor before the game ROM data so the shared core can select the correct
ROM geometry, memory windows, video geometry, watchdog, audio banks, and
optional ST010 hardware at runtime. There are no per-game Quartus builds.

The core is still a work in progress. The RTL has focused simulation and MAME
differential evidence, but the complete eight-game qualification matrix and
current physical MiSTer validation are not yet finished.

## OSD features

The core exposes the following MiSTer OSD features:

- Aspect ratio: Original, Full Screen
- Scaling: Normal, Integer (Horizontal), V-Integer (Vertical), HV-Integer
- Rotation: Horizontal, Vertical (CW), Vertical (CCW), Horizontal (Flipped)
- Video FX: None, Scanlines 25%, Scanlines 50%, Scanlines 75%
- Stereo Mix: None, 25%, 50%, 100%
- Service Mode
- Reset
- CRT Adjust: CRT Adjust, H-Size, H-Position, and V-Shift
- Six game buttons, Test, Service, Start, and Coin inputs
- Autosave Hiscores plumbing where the selected MRA provides a hiscore
  configuration

Game-specific DIP switches are supplied by each MRA. Depending on the game,
these include coinage, flip screen, demo sounds, difficulty, lives, free play,
service mode, rapid fire, subtitles, and other original board settings.

## PCB Accuracy

This section is intentionally limited to core behavior supported by primary
hardware evidence: legible PCB or cartridge photographs and manufacturer
documentation. Simulation results, MAME-derived behavior, and unmeasured
claims are documented elsewhere and are not presented as PCB accuracy here.

| Area | Core behavior supported by the evidence | Evidence |
| --- | --- | --- |
| Main CPU and program ROM interface | V60 clocked at 16 MHz from the board clock scheme; 16-bit program data split into low/high byte ROMs | 48.000 MHz crystal and `PRL`/`PRH` positions in the real STA-0001B/SAM-5127 photographs; NEC V60 documentation; [`docs/hardware/SSV_BOARD_HARDWARE.md`](docs/hardware/SSV_BOARD_HARDWARE.md) |
| Clock sources | 42.9545 MHz video crystal divided by six for the approximately 7.159 MHz pixel clock; 48.000 MHz crystal divided by three for the 16 MHz CPU domain | Real STA-0001B motherboard photograph and the documented clock derivation in [`docs/hardware/SSV_BOARD_HARDWARE.md`](docs/hardware/SSV_BOARD_HARDWARE.md) |
| Dyna Gear cartridge memory complement | Four-bank graphics layout, `16M-MASK` device capacity, and the 12 MiB graphics plus 4 MiB sample complement used by the core | Real SAM-5127 cartridge photographs, including bank labels, socket population, and device markings; [`docs/hardware/SSV_BOARD_HARDWARE.md`](docs/hardware/SSV_BOARD_HARDWARE.md) |
| DIP banks | Two 8-position DIP banks represented by the core's descriptor and input model | Real STA-0001B motherboard photograph; [`docs/hardware/SSV_BOARD_HARDWARE.md`](docs/hardware/SSV_BOARD_HARDWARE.md) |
| ES5506 / OTTO audio device | ES5506 host interface and 32-voice model with separate sample memory, envelopes, looping, reverse playback, and compressed samples | ES5506/OTTO specification plus the real-board photograph identifying the Ensoniq device; [`docs/hardware/SSV_SILICON.md`](docs/hardware/SSV_SILICON.md) |

## Supported games

These are the eight qualified parent sets in
[`tools/ssv_supported_sets.py`](tools/ssv_supported_sets.py). Other SSV entries
present in MAME are not currently claimed as supported by this core.

| Game | Set name | Runtime hardware notes |
| --- | --- | --- |
| Dyna Gear | `dynagear` | 1 MiB program ROM, 16 MiB graphics, extra RAM, read-kick watchdog |
| Change Air Blade (Japan) | `cairblad` | 2 MiB program ROM, 32 MiB graphics, identity tile mapping, 64 KiB NVRAM |
| Vasara | `vasara` | 4 MiB program ROM, 32 MiB graphics, two ES5506 banks, write-kick watchdog |
| Vasara 2 (set 1) | `vasara2` | 4 MiB program ROM, 32 MiB graphics, two ES5506 banks, write-kick watchdog |
| Drift Out '94 - The Hard Order (Japan) | `drifto94` | ST010, 4 MiB program ROM, 32 MiB graphics, 2 KiB NVRAM |
| Storm Blade (US) | `stmblade` | ST010, 4 MiB program ROM, 24 MiB graphics, 2 KiB NVRAM |
| Twin Eagle II - The Rescue Mission | `twineag2` | ST010, extra RAM, IRQ level 1, ES5506 bank aliases |
| Ultra X Weapons / Ultra Keibitai | `ultrax` | 12 MiB graphics, extra RAM, IRQ level 1 |

## **Hardware emulated**

| Hardware | Function |
| --- | --- |
| NEC V60/uPD70616 | Main SSV arcade CPU and 16-bit external bus |
| SSV video hardware | Background/tilemap rendering, sprite/object lists, row scroll, priority, shadows, palette, and native raster timing |
| SSV memory and control logic | Work/sprite/palette RAM, XRAM/NVRAM windows, interrupts, watchdog, coin/service/test inputs, and DIP switches |
| Ensoniq ES5506 (OTTO) | Host registers, 32-voice sample playback, interpolation, filters, envelopes, stereo mixing, and IRQ status |
| NEC uPD96050 / ST010 | Optional protection/DSP daughterboard used by Drift Out '94, Storm Blade, and Twin Eagle II |
| MiSTer platform interface | MiSTer HPS/OSD, SDRAM, HDMI/VGA video, audio output, rotation, scaling, scanlines, and CRT adjustment |

## Credits

- **meathax** — original SSV RTL, universal descriptor/profile integration,
  MRA generation, verification, and MiSTer integration.
- **Sega System 32 MiSTer core contributors** — source base for the V60,
  SDRAM controller, PLL, dual-port RAM helpers, and related verification
  infrastructure. See [`docs/PROVENANCE.md`](docs/PROVENANCE.md).
- **MiSTer-devel and MiSTer framework contributors** — MiSTer shell, HPS/OSD,
  video, audio, and platform integration from
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer).
- **MAMEdev and MAME contributors** — SSV driver/video behavior, V60 behavior,
  uPD96050/ST010 behavior, ES5506 behavior, ROM definitions, controls, DIP
  switches, and board-level reference contracts in
  [MAME](https://github.com/mamedev/mame). MAME source is used as a behavioral
  reference; it is not copied into the synthesizable core.
- **Farfetch'd and R. Belmont** — MAME V60 behavioral reference credited by the
  imported V60 source.
- **byuu and MAME contributors** — portable uPD7725/uPD96050 behavioral
  reference used for the ST010 implementation.
- **Ensoniq** — *OTTO Specification Rev. 2.3 (ES5506)*, used as the primary
  ES5506 hardware reference: [manual](https://gjcp.net/pdf/es5506.pdf).
- **tildearrow and Furnace contributors** — `vgsound_emu` ES550x behavioral
  cross-check: [Furnace source](https://github.com/tildearrow/furnace/tree/master/extern/vgsound_emu-modified/vgsound_emu/src/es550x).
- **visions85 / JTSFTM contributors** — partial ES5506 RTL inspected as an
  FPGA implementation reference: [sftm5506.v](https://github.com/visions85/sftm/blob/main/cores/sftm/hdl/sftm5506.v).
- **Umberto Parisi (rmonic79), with help from Andrea Bogazzi (@asturur)** —
  CRT Adjust module used by the OSD integration.
- **Alan Steremberg and Jim Gregory** — Hiscores_MiSTer module used for the
  hiscore plumbing: [Hiscores_MiSTer](https://github.com/JimmyStones/Hiscores_MiSTer).

## License

The original SSV RTL and integration are released under the
[GNU General Public License version 3 or later](LICENSE). Third-party files
retain their own license notices; see the source headers and
[`docs/PROVENANCE.md`](docs/PROVENANCE.md). MAME and other references are
credited above and are not a license to redistribute copyrighted game data.

No copyrighted game ROMs are included. Use only ROMs that you legally own or
are otherwise authorized to use.

## How to install

### Manual installation

1. Download the core RBF and the MRA file or files you want to use.
2. Copy the RBF to MiSTer at `/media/fat/_Arcade/cores/`.
3. Copy the matching `.mra` files to `/media/fat/_Arcade/`.
4. Put your legally obtained game ROM ZIP in the appropriate MiSTer arcade/MAME
   ROM folder, then launch the game from the MiSTer Arcade menu.

The MRA selects the universal `Arcade-SSV` core and supplies the per-game
descriptor before the ROM stream.

### Automatic installation with Downloader

Add this entry to your `downloader.ini`, then run **Update All** to download
all of the Meatcores automatically:

```ini
[meathax/meatcores]
db_url = https://raw.githubusercontent.com/meathax/meatcores/db/downloader_meathax_meatcores.zip
```

## Development and verification

- [`docs/GAME_COVERAGE.md`](docs/GAME_COVERAGE.md) — supported-set matrix and
  current qualification evidence.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — shared hardware and memory
  architecture.
- [`docs/implementation-status.md`](docs/implementation-status.md) — detailed
  implementation and verification status.
- [`docs/ES5506_RESEARCH.md`](docs/ES5506_RESEARCH.md) — ES5506 sources,
  measurements, and implementation notes.

For the local profile/media audit:

```powershell
python tools/verify_ssv_universal_profile.py --require-roms
```
