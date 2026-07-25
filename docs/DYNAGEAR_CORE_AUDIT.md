# Dyna Gear SSV MiSTer Core — Full Audit

Audit date: 25 July 2026  
Repository: `D:\Arcade\AI\SVV`  
Tree: `8b8312b` plus uncommitted bring-up fixes (ROM-write ack, dual video mux,
DIP OSD, diag `use_core_video`, hang-watch / post-VE gates)  
Target: Sammy/Seta/Visco SSV — **Dyna Gear** only for this release path  
Scope of this audit: RTL, verification, and sim evidence. **No Quartus/RBF
claims.** Hardware RBF deploy is out of band for the companion gameplay plan.

## Executive verdict

The core is a **credible Dyna Gear bring-up**, not a playable release.

| Question | Answer |
|---|---|
| Does Verilator boot Dyna Gear? | **Yes** — natural vblank reaches lockout / `video_enable` |
| Does early machine state match MAME? | **Yes** — ordered writes + full-state hashes through post-lockout (IRQ schedule) |
| Has attract mode been proven? | **No** — no attract-length frame CRC / RGB ladder |
| Has coin → start → play been proven? | **No** — inputs idle in core TBs; no gameplay scenario |
| Is audio present? | **No** — ES5506 register file only; PCM hardwired to zero |
| Overall toward playable Dyna Gear | **~55%** (medium confidence) |

Strongest verified results:

- ROM-region CPU writes no longer hang the bus (`tb_ssv_rom_write_ack`).
- Natural-vblank boot raises lockout/`video_enable` at ~53.7M `clk_sys`
  (`tb_ssv_hang_watch`: PC `0xF10983`, data `0x00C3`).
- Focused bring-up suite and V60 unit suite both **ALL PASS**.
- With MAME IRQ schedule: ordered writes and complete-state hashes match through
  the captured RTL horizon (including post-lockout samples).
- 60M-cycle real-ROM video: `p1=707008`, `nonblack=118457`, cache `1277`,
  `OVERRUN bg=0 obj=0`, PC `0x00f10575`
  (`sim_output/realrom_video_timing_pipeline_60m`).
- Wrapper muxes **core** CE/HS/VS/DE/RGB when diag state 8 (`use_core_video`).
- Dyna Gear DSW2 defaults map through OSD (`0xFFFD` at status=0: Demo Sounds ON).

Strongest remaining gaps for **real gameplay**:

- No attract-length palette-index / RGB frame CRC vs MAME.
- No coin/start stimulus scenario or post-credit CPU/video differential.
- Latent V60 UNHANDLED groups (`59` / `5B` / `5D` / some FP) unused in early
  boot; may appear in play.
- ES5506 voices/sample path absent; SDRAM audio ports tied off.
- Watchdog is a read/kick stub (no board timeout reset).
- FPGA RAM essentially exhausted (~552/553 blocks) — audio needs a deliberate
  memory plan, not more BRAM.

Estimated completion against a fully working Dyna Gear core:

| Area | Estimated completion | Confidence |
|---|---:|---|
| V60 / early boot / SSV bus | 90% | High for traced path; medium for gameplay |
| Video feature implementation | 75% | Medium |
| Attract / gameplay video proof (sim) | 35% | Medium |
| Controls and DIPs (wiring) | 70% | Medium (wired; not scenario-tested) |
| Coin → play transition (sim) | 10% | High that it is unproven |
| ES5506 audio | 15% | High |
| Build / release / HW validation | 40% | High (out of this plan’s critical path) |
| **Overall playable-core goal** | **~55%** | Medium |

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
| `210000–210011` | Watchdog / DSW / P1 / P2 / SYSTEM | IO mux | Partial (WD stub) |
| `230000` / `240000` / `260000` | IRQ vector / ack / enable | `ssv_irq` | Vblank only |
| `300000–30007f` | ES5506 host | Reg file | Partial |
| `400000–43ffff` | Dyna RAM | SDRAM `@0x1120000` | Strong in sim |
| `500008–500009` | Extra inputs | Tied `0xFFFF` | OK for Dyna Gear |
| `f00000–ffffff` | Program ROM | SDRAM read; writes nop-acked | Fixed hang |

SDRAM layout: program `0–0xfffff`, GFX `0x100000–0xcfffff`, samples
`0xd00000–0x10fffff`, then XRAM / Dyna RAM windows.

### CPU (V60)

- Production instance uses `FAST_IFETCH=0` (correctness over CPI).
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

- `ssv_irq`: vblank sets `requested[3]`; vectors/enable/ack at documented ports.
- `ssv_video_timing`: 454×262, active 336×240, vblank IRQ line 240.
- Sync widths are MiSTer-oriented, not PCB-measured — OK for bring-up; frame
  CRC work will expose any IRQ-line vs MAME mismatch.
- ES5506 `sound_irq_n` is produced by the reg block but **not** fed into
  `ssv_irq` (`irq_set` tied 0). Silent until voices exist; then may matter.

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
- DSW1 coinage hardwired `0xFFFF` (extended defaults / all Off).
- Pause (`status[7]`) freezes `ce_cpu` — can fake a hang on hardware if left on.
- **No Verilator TB drives coin/start after VE.**

### Audio (ES5506)

| Layer | Status |
|---|---|
| 4-byte host protocol + 32-voice reg pages | Yes (`ssv_es5506_regs`) |
| `commit` pulse | Exposed, no consumer |
| Sample fetch / interpolate / filter / mix | Missing |
| Core `audio_l` / `audio_r` | Hardwired `0` |
| Wrapper SDRAM p2–p5 | Tied off |
| Evidence | Focused reg TB; MAME 879 completed writes / 10s |

Critical for audible play; **not** on the critical path for silent attract /
silent playable proof in simulation.

### Watchdog

`$210000` returns `0` (MAME `reset16_r` value); kick is a nop. Board-level
timeout reset is not implemented. Treat as medium until soak shows reliance.

---

## Verification evidence (do not re-run for this audit)

| Gate | Result | Where |
|---|---|---|
| `verif/run_bringup_sims.sh` | ALL PASS | diag, loader, loader-core-boot, rom_write_ack, hang_watch |
| Hang watch VE | `LOCKOUT/VE @ ~53738421` pc=`00f10983` | bring-up logs |
| Post-VE write diff | ~554k ordered writes match; ~21k post-lockout | `run_post_ve_diff.sh` artifacts |
| Post-VE hash diff | ~2.0M complete-state hashes match (IRQ schedule) | same |
| Post-VE boot | `TRACE_CYCLES=120000000` ve=1 | post-ve boot log |
| Real-ROM 60M video | PASS, nonblack pixels, 0 overruns | `sim_output/realrom_video_timing_pipeline_60m` |
| V60 units | 28 passed, 0 failed | `verif/v60/run_v60_verilator.sh` |
| Full-core lint | Large warning set | `sim_output/audit/verilator-lint.log` (non-blocking) |

**Not evidenced:** attract-loop frame CRC; coin/start → gameplay; audible PCM;
current-RTL MiSTer attract (requires RBF — out of scope here).

### Subsystem status matrix

| Subsystem | Implemented | Sim evidence | Verdict for gameplay |
|---|---|---|---|
| MRA / ROM interleave | Yes | Stream hashes | Strong |
| HPS ROM loader | Yes | Focused + loader-core boot | Strong in sim |
| SDRAM CPU / GFX path | Yes | Behavioral in core TBs | Strong early |
| V60 CPU | Substantial | Unit + early MAME match | Strong early; latent gaps |
| ROM-write bus | Yes | rom_write_ack + hang_watch | Fixed |
| IRQ / vblank | Yes | VE rise; IRQ-scheduled diff | Strong early |
| BG / sprite / palette | Present | Focused + realrom pixels | Attract CRC missing |
| Dual video mux | Yes | diag TB | Fixed in tree |
| Inputs | Wired | Limited | Needs coin/start scenario |
| DIPs | OSD → DSW2 | Defaults = MAME | Improved |
| ES5506 regs | Yes | Focused | Partial |
| ES5506 voices | No | None | Missing |
| Attract / gameplay | Partial (VE) | Boot to VE only | **Next milestone** |

---

## Severity-ranked open findings

### Critical (gameplay path)

1. **Attract video not proven at pixel level** — CPU hashes ≠ palette/RGB proof
   for one attract loop.
2. **Coin → start → play not proven in sim** — no input schedule, no post-credit
   differential.
3. **ES5506 PCM absent** — blocks audible gameplay; defer until visual play works.

### High

4. **V60 latent UNHANDLED** — triage from a gameplay MAME opcode/trace before
   implementing unused FP/bitstring surface.
5. **No input-matrix regression** locking P1/P2/SYSTEM/DSW2 vs MAME.
6. **FPGA RAM headroom** — audio architecture must be time-multiplexed / MLAB;
   do not add large BRAM voice banks.

### Medium

7. Watchdog timeout not implemented.
8. ES5506 IRQ not integrated into `ssv_irq`.
9. DSW1 coinage not OSD-exposed.
10. Video sync widths approximate vs PCB.
11. Legacy `ssv_sprite_renderer` TB still failing (dead path).

### Low

12. Full-core Verilator lint debt.
13. Dirty working tree / incomplete commit freeze relative to `8b8312b`.

### Fixed in tree (preserve)

- ROM-write hang → nop ack + TB.
- Dual CE/HS/VS after VE → `use_core_video` mux + TB.
- Hardcoded DSW2 → OSD mapping with MAME defaults.
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
