# Sammy Seta Visco MiSTer FPGA Core

The Sammy Seta Visco core emulates the Sammy, Seta, and Visco arcade PCB family on
MiSTer. The FPGA target is the MiSTer DE10-Nano/Cyclone V
`5CSEBA6U23I7`; the board being emulated is the Sammy Seta Visco arcade hardware used by
the supported games below.

This project produces one universal `Arcade-SSV.rbf`. Each MRA loads a
descriptor before the game ROM data so the shared core can select the correct
ROM geometry, memory windows, video geometry, watchdog, audio banks, and
optional ST010 hardware at runtime. There are no per-game Quartus builds.

The core is still a work in progress. The RTL has focused simulation and MAME
differential evidence, but the complete nine-set qualification matrix and
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
- High score saving on every supported game, enabled by default (OSD:
  Autosave Hiscores). Six of the nine sets carry a hiscore.dat configuration
  in their MRA and save the extracted table to `<MRA name>.nvm`; Change Air
  Blade and Drift Out '94 keep their scores in battery-backed board NVRAM
  instead, which is saved as its own persistence stream. The table is written
  back to game RAM at load and re-read when the OSD is opened.

Game-specific DIP switches are supplied by each MRA. Depending on the game,
these include coinage, flip screen, demo sounds, difficulty, lives, free play,
service mode, rapid fire, subtitles, and other original board settings.

## Direct Video and rotated games

Direct Video outputs each game's native raster without MiSTer framebuffer
rotation. The horizontal `dynagear`, `drifto94`, and `mslider` profiles therefore work
directly on a compatible display. The vertical `cairblad`, `vasara`, `vasara2`,
`stmblade`, `twineag2`, and `ultrax` profiles require a physically rotated CRT
or another display that accepts the native vertical signal when Direct Video is
enabled.

For a normal landscape HDMI display, leave Direct Video disabled (`direct_video=0`)
so MiSTer's DDRAM framebuffer rotation can present the six vertical profiles.
The core hides its framebuffer Rotation menu while Direct Video is enabled,
because that presentation-layer rotation cannot transform the raw Direct Video
signal. Aspect ratio and Scale are hidden for the same reason: both are HDMI
scaler settings, and MiSTer reports a zero HDMI size to the core while Direct
Video is on, so neither can act on a raw native raster.

Video Fx does still apply under Direct Video. It switches the core's own line
doubler, so `None` gives the native 15 kHz raster for a CRT through a DAC, and
any scanline level gives a 31 kHz raster for a VGA-rate analog display. The
scanline levels themselves are only emitted while the doubler is running.

The release build keeps MiSTer's analog Y/C encoder enabled. RGB/component output
uses the normal VGA DAC pins; when the MiSTer analog configuration selects it,
the same native raster can be encoded for composite or S-Video by the framework's
Y/C path. This configuration is independent of the Direct Video choice above.

## PCB Accuracy

This section is intentionally limited to core behavior supported by primary
hardware evidence: legible PCB or cartridge photographs and manufacturer
documentation. Simulation results, MAME-derived behavior, and unmeasured
claims are documented elsewhere and are not presented as PCB accuracy here.

| Area | Core behavior supported by the evidence | Evidence |
| --- | --- | --- |
| Main CPU and program ROM interface | V60 clocked at 16 MHz from the board clock scheme; 16-bit program data split into low/high byte ROMs | 48.000 MHz crystal and `PRL`/`PRH` positions in the real STA-0001B/SAM-5127 photographs; NEC V60 documentation and board photographs |
| Clock sources | 42.9545 MHz video crystal divided by six for the approximately 7.159 MHz pixel clock; 48.000 MHz crystal divided by three for the 16 MHz CPU domain | Real STA-0001B motherboard photograph and manufacturer documentation |
| Dyna Gear cartridge memory complement | Four-bank graphics layout, `16M-MASK` device capacity, and the 12 MiB graphics plus 4 MiB sample complement used by the core | Real SAM-5127 cartridge photographs, including bank labels, socket population, and device markings |
| DIP banks | Two 8-position DIP banks represented by the core's descriptor and input model | Real STA-0001B motherboard photograph |
| ES5506 / OTTO audio device | ES5506 host interface and 32-voice model with separate sample memory, envelopes, looping, reverse playback, and compressed samples | ES5506/OTTO specification plus the real-board photograph identifying the Ensoniq device |

## Supported games

The core exposes these nine supported entries. Other Sammy Seta Visco entries
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
| Monster Slider (Japan) | `mslider` | 1 MiB program ROM, 10 MiB graphics, 4 MiB samples, 352x240 horizontal raster |

## **Hardware emulated**

| Hardware | Function |
| --- | --- |
| NEC V60/uPD70616 | Main Sammy Seta Visco arcade CPU and 16-bit external bus |
| Sammy Seta Visco video hardware | Background/tilemap rendering, sprite/object lists, row scroll, priority, shadows, palette, and native raster timing |
| Sammy Seta Visco memory and control logic | Work/sprite/palette RAM, XRAM/NVRAM windows, interrupts, watchdog, coin/service/test inputs, and DIP switches |
| Ensoniq ES5506 (OTTO) | Host registers, 32-voice sample playback, interpolation, filters, envelopes, stereo mixing, and IRQ status |
| NEC uPD96050 / ST010 | Optional protection/DSP daughterboard used by Drift Out '94, Storm Blade, and Twin Eagle II |
| MiSTer platform interface | MiSTer HPS/OSD, SDRAM, HDMI/VGA video, audio output, rotation, scaling, scanlines, and CRT adjustment |

## Credits

- **meathax** — original Sammy Seta Visco RTL, universal descriptor/profile integration,
  MRA generation, verification, and MiSTer integration.
- **Sega System 32 MiSTer core contributors** — source base for the V60,
  SDRAM controller, PLL, dual-port RAM helpers, and related verification
  infrastructure. See the source headers and upstream links below.
- **MiSTer-devel and MiSTer framework contributors** — MiSTer shell, HPS/OSD,
  video, audio, and platform integration from
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer).
- **MAMEdev and MAME contributors** — Sammy Seta Visco driver/video behavior, V60 behavior,
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

The original Sammy Seta Visco RTL and integration are released under the
[GNU General Public License version 3 or later](LICENSE). Third-party files
retain their own license notices in the source tree. MAME and other references are
credited above and are not a license to redistribute copyrighted game data.

No copyrighted game ROMs are included. Use only ROMs that you legally own or
are otherwise authorized to use.

## How to install

### Manual installation

1. Download the core RBF and the MRA file or files you want to use.
2. Copy the RBF to MiSTer at `/media/fat/_Arcade/`.
3. Copy the matching `.mra` files to the same `/media/fat/_Arcade/` folder.
4. Put your legally obtained game ROM ZIP in the appropriate MiSTer arcade/MAME
   ROM folder, then launch the game from the MiSTer Arcade menu.

The MRA selects the universal `Arcade-SSV` core and supplies the per-game
descriptor before the ROM stream.

### Automatic installation with Downloader

Add this entry to your `downloader.ini`, then run **Update All** to download
all of the Meatcores automatically:

```ini
[meathax/meatcores]
db_url = https://raw.githubusercontent.com/meathax/meatcores/db/db.json.zip
```
