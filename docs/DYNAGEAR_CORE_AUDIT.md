# Dyna Gear SSV MiSTer Core — Full Audit

Audit date: 26 July 2026  
Repository: `D:\Arcade\AI\SVV`  
Branch tip: gameplay-gate + FAST_IFETCH icache + Wave B RTL (DSW1, watchdog,
voice pipeline for timing).  
Target: Sammy/Seta/Visco SSV — **Dyna Gear** only for this release path  
Scope: RTL + Verilator evidence. **Quartus/RBF / physical MiSTer deferred**
(explicitly out of this pass).

## Executive verdict

The core is a **credible sim-playable Dyna Gear bring-up**, not a HW release.

| Question | Answer |
|---|---|
| Does Verilator boot Dyna Gear? | **Yes** — natural vblank reaches lockout / `video_enable` (~26M with FAST_IFETCH) |
| Does early machine state match MAME? | **Yes** — ordered writes through **8s attract** + hashes (IRQ schedule) |
| Has attract mode been proven? | **Partial+** — post-VE **frame 0** RGB/IDX CRC matches MAME; frame≥1 open |
| Has coin → start → play been proven? | **Partial** — `coin_start_p1` schedule in sim; full play CRC open |
| Is audio present? | **Yes (sim)** — voice PCM + REQUIRE_AUDIO peak gate; HW deferred |
| Overall toward playable Dyna Gear (sim) | **~78%** (medium confidence) |

### Board completeness (sim-proven unless noted)

| Board component | Completeness | Notes |
|---|---:|---|
| MiSTer shell / PLL / clocks | ~85% | Sim path solid; HW timing deferred |
| SDRAM controller + layout | ~85% | Program/GFX/samples/XRAM/Dyna mapped |
| ROM loader / MRA interleave | ~90% | Stream + probe path |
| NEC V60 CPU | ~90% | PFU + FAST_IFETCH on; latent 59/5B/5D/FP |
| CPU bus / ROM-write ack | ~95% | Hang fixed + restart-while-`ack_r` guard |
| Work / sprite / palette RAM | ~90% | On-chip; boot + video |
| XRAM + Dyna RAM (SDRAM) | ~85% | Strong in sim |
| Scroll / CRT regs + blanking | ~75% | MiSTer-ish sync widths |
| IRQ controller | ~85% | Vblank L3; ES5506 IRQ N/A for DG (MAME) |
| Video timing (336×240) | ~85% | VE/IRQ; natural CE boots |
| BG / sprite / GFX / linebuf / palette | ~80–85% | Frame-0 CRC match; loop open |
| Diag video mux | ~90% | Dual-raster tear fixed |
| Inputs (P1/P2/SYSTEM) | ~90% | Matrix TB + fixed P1 order |
| DIP switches | ~90% | DSW1+DSW2 OSD |
| Watchdog | ~90% | 180-frame `wdog_rst` + TB |
| ES5506 host / registers | ~90% | Protocol + pages tested |
| ES5506 voice PCM / mix | ~70% | Bank-2 + peak gate; no full PCM match / HW |
| Sample SDRAM port (p4) | ~75% | Wired; basic underrun |
| Attract / gameplay (whole) | ~65% | VE + frame 0 + coin/start stim; loop CRC open |
| Quartus fit / timing / RBF | — | **Deferred this pass** |
| Physical MiSTer validation | — | **Deferred this pass** |

Strongest remaining gaps (sim): attract-loop CRC frame≥1 (IRQ/CPI skew);
full play CRC; latent V60 UNHANDLED; FPGA M10K headroom for future audio HW.

---

## Subsystem audit

### Memory map (`rtl/ssv_core.sv`, `rtl/ssv_pkg.sv`)

| CPU range | Function | Placement | Verdict |
|---|---|---|---|
| `000000–00ffff` | Work RAM | On-chip | Strong |
| `100000–13ffff` | Sprite / list RAM | On-chip | Strong |
| `140000–15ffff` | Palette RAM | On-chip | Strong |
| `160000–17ffff` | XRAM | SDRAM `@0x1100000` | Strong in sim |
| `1c0000–1c007f` | Scroll / CRT (+ blanking peek) | Regs | Present |
| `210000–210011` | Watchdog / DSW / P1 / P2 / SYSTEM | IO mux | Strong (WD 180f) |
| `230000` / `240000` / `260000` | IRQ vector / ack / enable | `ssv_irq` | Vblank only |
| `300000–30007f` | ES5506 host | Reg file | Partial |
| `400000–43ffff` | Dyna RAM | SDRAM `@0x1120000` | Strong in sim |
| `500008–500009` | Extra inputs | Tied `0xFFFF` | OK for Dyna Gear |
| `f00000–ffffff` | Program ROM | SDRAM read; writes nop-acked | Fixed hang |

SDRAM layout: program `0–0xfffff`, GFX `0x100000–0xcfffff`, samples
`0xd00000–0x10fffff`, then XRAM / Dyna RAM windows.

### CPU (V60)

- Production instance uses `FAST_IFETCH=1` by default (`FAST_IFETCH_EN`) with a
  32×8B ROM icache on SDRAM p0 in `ssv_core` (override `1'b0` to A/B-test).
- Unit suite: 28/28 PASS (`verif/v60/run_v60_verilator.sh`).
- Open opcode surface (reserved-inst / MAME-UNHANDLED style):
  - `0x59` decimal — partial
  - `0x5B` bit-string — partial
  - `0x5D` bit-field — partial
  - `0x5C` / `0x5F` FP — validated subset only
- Early Dyna Gear boot has not required the missing subs; **gameplay may**.

### Bus / hang history

**Fixed in tree:** writes into `sel_rom` waited on `ext_done` without starting
an SDRAM cycle → permanent stall (`ext_busy=0`), matching prior MiSTer freeze
at `PC=0x00F1F3D6`. ROM writes are now nop-acked; only ROM reads use SDRAM.
Gate: `verif/tb_ssv_rom_write_ack.sv`.

### IRQ / timing

- `ssv_irq`: vblank sets `requested[3]` (level 3 only for Dyna Gear gameplay);
  vectors/enable/ack at documented ports.
- `ssv_video_timing`: 454×262, active 336×240, vblank IRQ line 240.
- Sync widths are MiSTer-oriented, not PCB-measured — OK for bring-up; frame
  CRC work will expose any IRQ-line vs MAME mismatch.
- **ES5506 IRQ N/A for Dyna Gear (board-correct):** MAME `ssv.cpp` instantiates
  `ES5506` for survarts/dynagear with **no** `irq_handler` / CPU IRQ bind.
  Voices run without a voice IRQ into `ssv_irq`. RTL keeps `sound_irq_n` /
  `eng_irq_set` internal to the ES5506 block and does **not** invent a level-5
  (or other) wire. Completing IRQ completeness for DG = document this, not add
  speculative wiring.

### Video pipeline

Present and integrated when `video_enable=1`:

1. Timing → BG (`ssv_bg_renderer`) + cached sprites (`ssv_cached_sprite_renderer`)
2. GFX row fetch / decode (packed Q0/Q1 + native Q2)
3. Four-bank compositor (`ssv_line_buffer4`) with shadow resolve
4. Palette (`ssv_palette_ram`) → xRGB888 scanout
5. RGB forced black while `!video_enable` or blanking

**Fixed in tree:** dual-raster tear — diag CE/HS/VS/DE previously always drove
HDMI while only RGB switched in state 8. Now `use_core_video` muxes all five
from the core. Gate: `verif/tb_ssv_diag_video.sv`.

Gaps: attract-length pixel proof; legacy `ssv_sprite_renderer` TB still a
dead-path fail (release uses cached renderer).

### Inputs / DIPs (`Arcade-SSV.sv` → `ssv_core`)

```
hps_io joysticks / status
  → player_port / system_port / dsw1 / dsw2
  → in_p1 / in_p2 / in_system / in_dsw1 / in_dsw2 / in_extra
  → $21000x / $500008 read mux
```

- Joystick bit map matches MAME `ssv_joystick` (START, buttons, directions).
- SYSTEM: COIN1/2, SERVICE1, TILT=0, TEST.
- DSW2 OSD → active-low bits; status=0 yields `0xFD` (MAME dynagear default).
- DSW1 Coin A/B OSD → `SSV_COINAGE_EXTENDED` nibbles; default all Off = `0xFF`
  (1C/1C). Gate: `tb_ssv_input_matrix`.
- Pause (`status[7]`) freezes `ce_cpu` — can fake a hang on hardware if left on.
- Coin/start schedule: `verif/scenarios/dynagear/coin_start_p1.json` +
  `tb_ssv_frame_crc`.

### Audio (ES5506)

| Layer | Status |
|---|---|
| 4-byte host protocol + 32-voice reg pages | Yes (`ssv_es5506_regs`) |
| Sample fetch / interpolate / filter / mix | Yes (`ssv_es5506_voice`, pipelined) |
| Core `audio_l` / `audio_r` | Driven from voice mixer |
| Sample SDRAM | `sdr_p4` |
| Evidence | `run_audio_sims.sh` ALL PASS (`audio_peak=32768`) |

Full attract PCM waveform match vs MAME and HW soak remain open; Quartus
timing closure for the voice path is deferred with RBF work.

### Watchdog

`$210000` read kicks a 180-frame (post-VE) counter; timeout asserts sticky
`wdog_rst` (OR’d into wrapper reset). Gate: `verif/tb_ssv_watchdog.sv`.

---

## Verification evidence (do not re-run for this audit)

| Gate | Result | Where |
|---|---|---|
| `verif/run_bringup_sims.sh` | ALL PASS | diag, loader, loader-core-boot, rom_write_ack, hang_watch |
| Hang watch VE | LOCKOUT/VE ~26M (FAST_IFETCH); was ~53.7M | bring-up logs |
| Attract frame 0 CRC | IDX=`d3b2fac2` RGB=`7fdb4700` | `tb_ssv_frame_crc` / Wave C |
| Attract frame ≥1 CRC | DIVERGE (documented residual) | `DYNAGEAR_ATTRACT_FRAME_CRC.md` |
| Coin/start scenario | Schedule + nonblack continue | `coin_start_p1` |
| Audio suite | ALL PASS + peak gate | `run_audio_sims.sh` |
| Watchdog | Trip @180f + kicked clear | `tb_ssv_watchdog` |
| V60 units | 28 passed, 0 failed | `verif/v60/run_v60_verilator.sh` |
| Post-VE write/hash | 8s attract match (IRQ schedule) | prior artifacts |

**Not evidenced this pass:** 120-frame attract CRC loop; Quartus ReadyToDeploy;
physical MiSTer attract (RBF deferred).

### Subsystem status matrix

| Subsystem | Implemented | Sim evidence | Verdict for gameplay |
|---|---|---|---|
| MRA / ROM interleave | Yes | Stream hashes | Strong |
| HPS ROM loader | Yes | Focused + loader-core boot | Strong in sim |
| SDRAM CPU / GFX path | Yes | Behavioral in core TBs | Strong early |
| V60 + FAST_IFETCH icache | Yes | Unit + faster VE | Strong early; latent gaps |
| ROM-write bus | Yes | rom_write_ack + hang_watch | Fixed |
| IRQ / vblank | Yes | VE rise; ES5506 IRQ N/A | Strong early |
| BG / sprite / palette | Yes | Frame-0 CRC match | Loop CRC open |
| Dual video mux | Yes | diag TB | Fixed |
| Inputs + DSW1/2 | Yes | matrix + scenarios | Strong in sim |
| Watchdog | Yes | focused TB | Strong in sim |
| ES5506 regs + voices | Yes | audio suite | Sim peak green; HW deferred |
| Attract / gameplay | Partial | frame 0 + coin stim | **Loop CRC next** |

---

## Severity-ranked open findings

### Critical (gameplay path)

1. **Attract-loop CRC open after frame 0** — frame≥1 IDX/RGB diverge (IRQ/CPI
   skew); see `DYNAGEAR_ATTRACT_FRAME_CRC.md`.
2. **Full play CRC open** — coin/start schedule exists; long play match does not.

### High

3. **V60 latent UNHANDLED** — triage from a gameplay MAME opcode/trace before
   implementing unused FP/bitstring surface.
4. **FPGA RAM / timing headroom** — M10K at ceiling; Quartus voice-path timing
   not closed (RBF deferred this pass).
5. **ES5506 full PCM match / HW** — sim peak only; waveform + board soak open.

### Medium

7. ~~Watchdog timeout not implemented.~~ **Fixed:** 180-frame post-VE timeout → `wdog_rst` (`tb_ssv_watchdog`).
8. ~~ES5506 IRQ not integrated into `ssv_irq`.~~ **Waived for Dyna Gear:** MAME does not bind ES5506 IRQ; keep unwired.
9. ~~DSW1 coinage not OSD-exposed.~~ **Fixed:** OSD Coin A/B → `SSV_COINAGE_EXTENDED` nibbles.
10. Video sync widths approximate vs PCB.
11. Legacy `ssv_sprite_renderer` TB still failing (dead path).

### Low

12. Full-core Verilator lint debt.

### Fixed in tree (preserve)

- ROM-write hang → nop ack + TB.
- Dual CE/HS/VS after VE → `use_core_video` mux + TB.
- DSW1/DSW2 OSD mapping with MAME defaults.
- 180-frame watchdog → `wdog_rst`.
- FAST_IFETCH + 32×8B ROM icache.
- ES5506 voice PCM + p4 (sim).
- Stale top-level SDC names cleaned.

---

## What “real gameplay” means here

For the companion plan, **real gameplay** means Verilator (and later HW) can:

1. Cold-boot to a stable **attract** sequence with non-black game pixels.
2. Accept **coin** and **start** and enter a playable stage/character control
   loop without CPU/bus hang or renderer overrun.
3. Keep P1 controls and vblank IRQs coherent with MAME for a short play window.
4. (Stretch) produce audible ES5506 PCM for the same window.

Silent but controllable play **counts** as the primary gameplay gate. Audio is
the secondary gate. Quartus/RBF is explicitly **not** required to declare the
sim gameplay gates met.

## Immediate pointer

See [`DYNAGEAR_GAMEPLAY_PLAN.md`](DYNAGEAR_GAMEPLAY_PLAN.md) for the ordered
sim-first plan to attract + coin/start play. Do not start audio or Quartus work
until that plan’s visual/input gates pass.
