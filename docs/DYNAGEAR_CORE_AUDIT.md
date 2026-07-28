# Dyna Gear SSV MiSTer Core — Full Audit

Audit date: 28 July 2026 (supersedes the 27 July sim-only pass)
Repository: `D:\Arcade\AI\SVV`  
Branch tip: `5eb1f5b` + this pass's timing/area work.  
Target: Sammy/Seta/Visco SSV — **Dyna Gear** only for this release path  
Scope: RTL + Verilator evidence **plus** the Quartus 17.0.2 fit/STA that the
previous pass deferred. Physical MiSTer validation is still open.

## Executive verdict

The core is a **credible sim-playable Dyna Gear bring-up that now also fits and
very nearly closes timing**, but it has not run on hardware.

| Question | Answer |
|---|---|
| Does Verilator boot Dyna Gear? | **Yes** — natural vblank reaches lockout / `video_enable` (~26M with FAST_IFETCH) |
| Does early machine state match MAME? | **Yes** — ordered writes through **8s attract** + hashes (IRQ schedule) |
| Has attract mode been proven? | **Yes (stable early window)** — frames 2–3 RGB/IDX and all 80,640 pixels match MAME |
| Has coin → start → play been proven? | **Yes (sim)** — assertion-clean 950-frame replay reaches controllable jungle gameplay |
| Is audio present? | **Yes (sim)** — voice PCM + REQUIRE_AUDIO peak gate; HW deferred |
| Does it fit the 5CSEBA6U23I7? | **Yes** — 82% ALM, 96% M10K, 53% DSP |
| Does it close timing? | **Yes** — all clocks positive at all four corners; worst is +0.392 ns |
| Is there an RBF? | **Yes** — `releases/SSV.rbf`, built 28 Jul 12:25 |
| Does it work on hardware? | **No** — boots and enables video, but the renderer emits almost nothing. See [`DYNAGEAR_FROZEN_VIDEO.md`](issues/DYNAGEAR_FROZEN_VIDEO.md) |
| Overall toward playable Dyna Gear (sim) | **~90%** (high confidence for the tested window) |

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
| BG / sprite / GFX / linebuf / palette | ~90% | exact stable pixels; 950f zero-overrun gameplay |
| Diag video mux | ~90% | Dual-raster tear fixed |
| Inputs (P1/P2/SYSTEM) | ~90% | Matrix TB + fixed P1 order |
| DIP switches | ~90% | DSW1+DSW2 OSD |
| Watchdog | ~90% | 180-frame `wdog_rst` + TB |
| ES5506 host / registers | ~90% | Protocol + pages tested |
| ES5506 voice PCM / mix | ~70% | Bank-2 + peak gate; no full PCM match / HW |
| Sample SDRAM port (p4) | ~75% | Wired; basic underrun |
| Attract / gameplay (tested window) | ~90% | coin/start/select/story/jungle play proven |
| Quartus fit | ~90% | Fits: 89% ALM / 98% M10K; M10K is the binding resource |
| Quartus timing | ~85% | Only `ascal` fails, by −0.121 ns; core clocks +1.35/+2.26 ns |
| Physical MiSTer validation | — | **Still open** — no RBF has been run on a board |

Strongest remaining gaps: post-coin MAME/RTL presentation phase skew; play
beyond the first jungle window; latent V60 UNHANDLED; the residual `ascal`
setup violation; sample-accurate ES5506 PCM and physical hardware validation.

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

## FPGA implementation (Quartus 17.0.2, 5CSEBA6U23I7)

Compiled 28 Jul 12:05–12:28 (`quartus_sh --flow compile`, Fast Fit profile,
`NUM_PARALLEL_PROCESSORS 1`). This supersedes the 09:45 fit, which predated the
`ascal` `o_vlastcpt` fix and reported a −0.121 ns violation.

### Fit summary — 28 Jul 12:25

| Resource | Used | Available | % | vs. previous fit |
|---|---:|---:|---:|---:|
| ALMs | **34,366** | 41,910 | **82** | −2,966 |
| Registers | 20,456 | — | — | −1,582 |
| M10K blocks | **532** | 553 | **96** | −10 |
| Block memory bits | 4,326,704 | 5,662,720 | 76 | −10,689 |
| DSP blocks | 59 | 112 | 53 | — |
| PLLs | 3 | 6 | 50 | — |

The −10,689 block-memory bits are exactly `pal1_mem` (6,144) + both
`altshift_taps` (449) + `i_dpram` (4,096), and the register count fell rather
than rising by ~4,096 — which is how we know `i_dpram` reached LUTRAM instead
of falling back to logic. Analysis & Synthesis reports **no warning 10999**, so
`icache_data` now infers as memory.

M10K remains the binding resource, but headroom nearly doubled: 21 free blocks,
up from 11.

### Where the block RAM goes

| Owner | M10K | Note |
|---|---:|---|
| `sprite_ram` (0x100000–0x13ffff) | 256 | 2,097,152 bits — board-exact, at the device floor |
| `palette_ram` (0x140000–0x15ffff) | 128 | 1,048,576 bits — 0x8000 xRGB888 entries, at the floor |
| `work_ram` (0x000000–0x00ffff) | 64 | 524,288 bits — at the floor |
| `ssv_cached_sprite_renderer` | 45 | descriptor cache 22, line entries 21, page starts 2 |
| `ascal` | 38 | output line buffers 20, DDR FIFOs 8, poly/pal/misc 10 |
| OSD (HDMI + VGA) | 8 | MiSTer framework |
| shadowmask / `vga_out` taps | 3 | |

448 of the 542 blocks are the three board RAMs, and those are already at the
information-theoretic minimum for their bit counts — there is nothing to
recover there without changing the memory map. All discretionary block RAM
lives in the sprite renderer and `ascal`.

### Timing

Multicorner analysis is on. **Every setup, hold, recovery, removal and
minimum-pulse-width check passes at all four corners.** Setup:

| Clock | Freq | Slow 100C | Slow −40C | was (pre-fix) |
|---|---:|---:|---:|---:|
| `pll_hdmi` scaler pixel clock | 148.54 MHz | +0.413 | **+0.392** | −0.121 |
| `clk_ram` / SDRAM | 96.63 MHz | +1.110 | +1.304 | +1.415 |
| `clk_sys` (core) | 48.32 MHz | +2.418 | +2.511 | +2.175 |
| `h2f_user0_clk` | 100 MHz | +3.705 | +3.492 | +3.142 |

Worst hold is +0.100 ns (`pll_hdmi`, Fast −40C); every other hold is larger.

The `ascal` `o_vlastcpt` change closed the HDMI domain on its own, under the
codified Fast Fit profile — no fitter-effort escalation was needed. That was
the point of not spending it: the +0.513 ns swing is attributable to the RTL
fix, not to placement luck. `STANDARD FIT` + `ROUTER_TIMING_OPTIMIZATION_LEVEL
MAXIMUM` remain unspent in reserve.

Note the tightest domain is now `pll_hdmi` at +0.392 ns (~6% of a 6.732 ns
period). That is a MiSTer-framework domain, not SSV logic; `clk_sys` has ~12%
and `clk_ram` ~13%.

The V60 and ES5506 voice multicycle exceptions in `SSV.sdc` were re-checked
against the RTL this pass and hold up:

- `ce_cpu` is a 21702/65536 accumulator at 48.32 MHz → 16.00 MHz, and because
  21702×2 < 65536 the gap between enables is never smaller than 3 `clk_sys`.
  `-setup 3 -hold 2` is therefore the correct pairing (hold 2 pulls the hold
  check back to the launch edge, i.e. the normal same-edge check).
- Every register in `s32_v60` and `s32_v60_bus` sits inside a single
  `else if (ce)` branch, so the whole collection is genuinely CE-paced.
- The voice collection is *mostly* CE-paced. The exception is the `|eng_*`
  group: `eng_wr_accum`/`eng_wr_cr`/`eng_wr_filt`/`eng_wr_env`/`eng_irq_set`
  are cleared unconditionally every `clk_sys`, so those flops do toggle every
  cycle. The exception is still sound, because their only in-collection
  sources (`state`, `proc_*`, `cr`, …) change one CE edge earlier and the
  intermediate captures are forced to 0 by the single-cycle-constrained `ce`
  term. Worth remembering before anyone widens the `|eng_*` pattern.
- The SDRAM handshake registers (`s1`, `s2`, `got_ack`, `wait_cnt`, `sdr_*`)
  are correctly excluded — they are acked on `clk_sys`, not on `ce`.

### ALM distribution

| Entity | ALMs | Share of device |
|---|---:|---:|
| `s32_v60` | 19,917 | 47.5% |
| `ssv_core` own logic | 4,778 | 11.4% |
| `ssv_cached_sprite_renderer` | 1,999 | 4.8% |
| `ascal` | 1,944 | 4.6% |
| `ssv_es5506_voice` | 1,132 | 2.7% |
| `ssv_es5506_regs` | 954 | 2.3% |
| `audio_out` | 916 | 2.2% |
| `ssv_line_buffer4` | 706 | 1.7% |
| OSD ×2 | 1,079 | 2.6% |
| `hps_io` | 459 | 1.1% |
| `ssv_bg_renderer` | 429 | 1.0% |
| `sdram` | 227 | 0.5% |

**The V60 is nearly half the device on its own.** Any serious ALM reduction has
to come from there; every other block combined is under 40%. A large share of
the 4,778 ALMs charged to `ssv_core`'s own logic came from the ROM icache,
which failed memory inference and was therefore built from 2,048 flops plus
three 64-bit 32:1 read muxes (see findings). That is fixed in the tree now, but
the exact ALM recovery is an estimate until the next fit lands.

---

## Verification evidence (do not re-run for this audit)

| Gate | Result | Where |
|---|---|---|
| `verif/run_bringup_sims.sh` | ALL PASS | diag, loader, loader-core-boot, rom_write_ack, hang_watch |
| Hang watch VE | LOCKOUT/VE ~26M (FAST_IFETCH); was ~53.7M | bring-up logs |
| Attract frame 0 CRC | IDX=`d3b2fac2` RGB=`7fdb4700` | `tb_ssv_frame_crc` / Wave C |
| Stable attract frames 2–3 | Exact IDX/RGB + 80,640 pixels | MAME/RTL probe |
| Coin/start gameplay | 950f PASS; frame-850 gameplay gate | `coin_start_p1_gameplay` |
| Audio suite | ALL PASS + peak gate | `run_audio_sims.sh` |
| Watchdog | Trip @180f + kicked clear | `tb_ssv_watchdog` |
| V60 units | 28 passed, 0 failed | `verif/v60/run_v60_verilator.sh` |
| Post-VE write/hash | 8s attract match (IRQ schedule) | prior artifacts |

### Re-run for the 28 Jul RTL changes

The icache and IRQ edits are meant to be behaviour-neutral, so they were
gated on exact CRC equality against the committed golden stream rather than on
a pass/fail assertion:

| Gate | Result |
|---|---|
| `tb_ssv_diag_video` | PASS `ce=1403 nonblack=1001 use_core_video=1` |
| `tb_ssv_rom_loader` | PASS |
| `tb_ssv_loader_core_boot` | PASS `rom_loaded=1 first_pc=fffffff0` |
| `tb_ssv_rom_write_ack` | PASS `acked in 0 cycles busy=0` |
| `tb_ssv_watchdog` | PASS (trip @180f, kicked path clear) |
| `tb_ssv_irq` | PASS |
| `tb_ssv_hang_watch` | PASS `pc=00f104c6 cyc=49728838 frames=30 lockouts=30` |
| `tb_ssv_input_matrix` | PASS, including the new MAME-scenario anchor block |
| 950-frame `coin_start_p1_gameplay` | PASS `frames=950 overruns bg=0 obj=0 max_line_entries=86` |

The 950-frame frame-CRC stream is **byte-identical** to the committed golden
`sim_output/diff/rtl_final96_gameplay_frames.crc` —
SHA-256 `11213dd7bc0c46a698c988a5e8b48c748933bb752b6e7c117eb77ddc3ae0a26d` on
both, 950/950 records. Boot, attract, coin, start, character select, both story
transitions and the controllable jungle window all render bit-for-bit the same
as before the icache and IRQ changes, which is what "behaviour-neutral" has to
mean for edits like these.

`tb_ssv_hang_watch` is the one that matters for the icache change: it boots
from cold through ~49.7 M `clk_sys` cycles of real ROM execution, so every
instruction fetch in the boot path went through the restructured fill.

**Note on running the gates:** `verif/run_*.sh` call the `verilator-safe.exe`
Windows launcher, which stalls when the script is started from a
non-interactive nested WSL shell. Running `/usr/bin/verilator` and the built
binaries directly (same flags) works. Also note `tb_ssv_frame_crc` defaults to
`+CYCLES=200000000`, which only reaches ~216 post-VE frames — a 950-frame soak
needs roughly `+CYCLES=900000000` (≈805k `clk_sys` per 60 Hz frame plus ~26 M
of boot) or it aborts with `soak frames=216 need=950`.

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
| Attract / gameplay | Partial | 950-frame CRC stream | Strong for the tested window; beyond it unproven |

---

## Severity-ranked open findings

### Critical (gameplay path)

1. **Post-coin presentation phase** — first same-frame visual split is frame
   36; comparable memory hashes remain matched through frame 49.
2. **Full-game duration open** — 950 frames reach controllable play, not game
   completion or every stage/boss path.

### High

3. **V60 latent UNHANDLED** — triage from a gameplay MAME opcode/trace before
   implementing unused FP/bitstring surface.
4. ~~`ascal` setup violation blocks a timing-clean RBF.~~ **Closed:** the
   `o_vlastcpt` fix was compiled on 28 Jul and the HDMI domain went from
   −0.121 ns to +0.392 ns at the worst corner. All clocks now pass at all four
   corners.
5. **ES5506 full PCM match / HW** — sim peak only; waveform + board soak open.
   This is now the largest untested area.
6. **M10K headroom** — improved from 11 to 21 free blocks (542 → 532), but the
   three board RAMs (448 blocks) still cannot be shrunk, so it remains the
   binding resource. See "M10K levers" below for what is left.
7. **The core does not render on hardware.** *(New — this is now the top
   blocker.)* The timing-clean RBF was deployed to MiSTer `192.168.0.69` on
   28 Jul. It boots: ROM loads, the V60 runs, and the game reaches and executes
   the `$21000E` video-enable write. But the active area is a uniform teal
   index-0 field with a few coloured blocks upper-left, static across captures
   20 s apart — the renderer is not writing pixels into the line buffer.
   Verilator renders the same 950 frames perfectly, so this is a
   simulation-versus-silicon divergence, not a logic error the benches can see.
   This deployment also **refuted** the long-standing hypothesis that the
   frozen image was caused by the timing failure. See
   [`DYNAGEAR_FROZEN_VIDEO.md`](issues/DYNAGEAR_FROZEN_VIDEO.md) and the fix
   plan in [`DYNAGEAR_HW_RENDER_FIX_PLAN.md`](DYNAGEAR_HW_RENDER_FIX_PLAN.md).

### Medium

7. ~~Watchdog timeout not implemented.~~ **Fixed:** 180-frame post-VE timeout → `wdog_rst` (`tb_ssv_watchdog`).
8. ~~ES5506 IRQ not integrated into `ssv_irq`.~~ **Waived for Dyna Gear:** MAME does not bind ES5506 IRQ; keep unwired.
9. ~~DSW1 coinage not OSD-exposed.~~ **Fixed:** OSD Coin A/B → `SSV_COINAGE_EXTENDED` nibbles.
10. Video sync widths approximate vs PCB.
11. Legacy `ssv_sprite_renderer` is dead source: not in `files.qip`, and its TB
    still fails. Its only consumer of `ssv_sprite_decode` is gone, so that file
    has been dropped from the build too. The `.sv` files are still on disk —
    deleting them needs a decision, not a guess.
12. ~~`renderer_overrun` is write-only.~~ **Fixed:** the sticky flag
    (`debug_status[16]`) now drives `LED_DISK = {1'b1, renderer_overrun}`, so a
    line-deadline miss or a truncated descriptor/line-slot list lights the I/O
    board HDD LED. Previously, with `ENABLE_DIAG_VIDEO=0`, nothing read
    `debug_status` at all and the failure was completely silent on hardware.
13. ~~`cache_overflow` also sets on an exactly-full cache.~~ **Withdrawn on
    closer reading — not a bug.** The flag means "descriptor list truncated",
    and when the scan aborts at the ceiling anything still in the list *is*
    dropped, so raising it is correct. Two things were genuinely wrong and are
    now fixed: the comment claimed the entry was merely "not orphaned", and the
    `else if (build_screen_visible_q)` arm in `BUILD_STORE` is unreachable —
    `cache_stop_after_bucket` fires exactly as the count reaches
    `CACHE_COUNT_VALUE`, so the "already full" case can never be entered. It is
    kept as a guard and now labelled as one.
14. ~~`tb_ssv_input_matrix` cannot catch an input-mapping regression.~~
    **Fixed:** the bench now also asserts `player_port()`/`system_port()`
    against the literal `in_p1`/`in_system` words from
    `verif/scenarios/dynagear/coin_start_p1.json` — values captured from a MAME
    0.288 replay in which the game actually coins up, starts, confirms a
    character and moves. Those constants are not derived from `Arcade-SSV.sv`,
    so editing the mirror can no longer make the bench pass. A scope warning at
    the top of the file explains the distinction.

### Low

15. Full-core Verilator lint debt.
16. `sys/sys_top.v` still carried a "System 32 is at most 416 pixels wide"
    comment on `IHRES(512)`. Corrected to SSV/336.

### Fixed in tree (preserve)

- ROM-write hang → nop ack + TB.
- Dual CE/HS/VS after VE → `use_core_video` mux + TB.
- DSW1/DSW2 OSD mapping with MAME defaults.
- 180-frame watchdog → `wdog_rst`.
- FAST_IFETCH + 32×8B ROM icache.
- ES5506 voice PCM + p4 (sim).
- Stale top-level SDC names cleaned.
- **Vblank IRQ vs. same-cycle ack race** (this pass) — `ssv_irq` wrote
  `requested[3] <= 1` before `requested[ack_level] <= 0`, so a `$240000` ack
  landing on the same `clk_sys` edge as `vblank_pulse` silently ate a frame
  interrupt. Rare (vblank_pulse is one `clk_sys` wide) but real over a long
  session, and it would present as an unexplained hang or stutter on hardware.
  The clear now happens first so the raster always wins.
- **ROM icache lost to failed memory inference** (this pass) — Quartus warning
  10999 `can't infer memory for variable 'icache_data'`. The per-word
  bit-select write `icache_data[line][{word,4'b0} +: 16] <= dout` blocked
  inference, so a 32×64 array became 2,048 flops plus 64-bit 32:1 read muxes
  inside `ssv_core`'s 4,778-ALM block. Fill words now land in a `fill_buf`
  register and the whole 8-byte line is written once, which is the same shape
  as `icache_tag` (which *did* infer, into two MLABs).
- **Descriptor build could latch the display dead** (this pass) — the vblank
  cache build had no deadline, and `line_buffer_start` gates on
  `!obj_cache_busy`. A build that overran into active display stopped every
  line swap, and because the next vblank re-arms the build via `cache_pending`
  it could never recover — one overrun froze the picture permanently. The build
  now aborts at `vcnt >= SSV_VTOTAL-2`, publishes a partial cache and raises
  `cache_overflow` (which drives the overrun LED). Regression test in
  `tb_ssv_cached_sprite_renderer`, observed to fail with the abort removed.
- **Renderer overrun surfaced on hardware** (this pass) — `LED_DISK`.
- **Input-matrix bench anchored to the MAME replay constants** (this pass).
- **Dead `ssv_sprite_decode.sv` dropped from `files.qip`** (this pass) — nothing
  in the build instantiated it; the file remains on disk.
- **`ascal i_dpram` moved to LUTRAM** (this pass) — a 32×128 DDR staging FIFO
  was costing 4 M10Ks for 4,096 bits. Its read port is on the 100 MHz `avl_clk`
  (+3.1 ns), so LUTRAM is comfortable.

---

## Deliberately not done, and why

These were identified and left alone on purpose. Each needs evidence or a
decision that this pass could not supply.

| Item | Why not |
|---|---|
| **V60 area gating** (up to several thousand ALMs) | The decimal/bit-string/bit-field/FP groups are the only meaningful ALM lever left, but parameter-gating them requires a MAME opcode hit list over a *full* playthrough. Only ~950 frames of one stage have ever been simulated. Gating on attract-era traces would silently break a later stage or boss that nobody has run. Get the trace first. |
| **`ascal o_dpram` → LUTRAM** (−4 M10K) | Same shape as `i_dpram`, but its read port is on the 148.5 MHz `o_clk` — the one domain that is currently missing setup. Moving it there while that violation is unresolved is the wrong order of operations. Revisit after the next STA shows the domain clean. |
| **Video sync widths** | MAME's `set_raw` does not document the board's real HSYNC/VSYNC widths. The current pulses lie wholly inside blanking and are correct for MiSTer output; making them PCB-exact needs a measurement, not a guess. |
| **ES5506 sample-accurate PCM match** | Needs a MAME PCM capture and a comparison harness. That is a project, not a fix, and the sim peak gate already passes. |
| **Post-coin phase skew / full-game duration** | Research tasks against MAME, not code defects. Frame 36 is the first same-frame visual split; memory hashes still match through frame 49. |
| **Verilator lint debt** | The gates run with a long `-Wno-*` list. Clearing it is a mechanical sweep across the whole tree with real regression risk and no functional payoff; it deserves its own pass with its own CRC gate. |
| **Deleting the legacy renderer sources** | `rtl/video/ssv_sprite_renderer.sv`, `rtl/video/ssv_sprite_decode.sv` and their benches are now fully out of the build but still on disk. Removing files is a call for the maintainer to make. |

---

## M10K levers, with measured cost

Only the sprite renderer and `ascal` hold discretionary block RAM. Recorded
here so nobody re-derives the packing arithmetic:

| Lever | ΔM10K | Cost / risk |
|---|---:|---|
| Disable auto shift-register recognition | **−4** | 449 bits were being promoted into two `altshift_taps` (ascal `o_v_poly_phase_a2` 4×80, `vga_out` `din1` 3×43). ~450 flops back. **Taken this pass.** |
| `ascal .PALETTE("false")` | **−2** | `MISTER_FB` is undefined, so `pal1_mem` (128×48) was dead. Upstream MiSTer already drops it. **Taken this pass.** |
| `ascal` `i_dpram`/`o_dpram` → MLAB | −8 | Two 32×128 DDR burst FIFOs cost 4 blocks each. ~140 ALMs to move. Dual-clock LUTRAM on the DDR path — needs a fit + a real HDMI soak. |
| `CACHE_ENTRIES` 1536 → 1024 | −11 | **Not safe.** Attract already uses ~1277 descriptors. |
| Force a better descriptor-cache geometry | up to −4 | Quartus packed 1536×106 as 2 slices of 1024×10 = **22** blocks. 3 slices of 512×20 would have been 18. Splitting the array into two ~53-bit halves is the usual way to steer this. Cheap to test on the next fit; verify against the report rather than assuming. |
| Precompute descriptor coordinates at build time | ~−8 | Storing resolved `sx`/`sy`/`code`/`color` instead of raw local+global words gets the descriptor under ~60 bits and also deletes the duplicated render-side coordinate maths (~400+ ALMs) and shortens the render path. Requires a full frame-CRC re-validation and freezes `flip_control`/`local_control` at vblank. |
| Narrow the descriptor losslessly | ~0 | Checked: the genuinely-used bits total 102 (`l2` needs [15:12] for depth when `local_control[14]` selects the local size fields), which is unlikely to cross a packing boundary. Not worth the churn on its own. |
| `LINE_ENTRY_LOW_WIDTH` 7 → 10 | **+9** | Checked and rejected. `line_entries` (23040×7) landed on 21 blocks, which is uniquely `3 depth slices × 7 bit-planes` — i.e. ×1 packing, where every extra bit of width costs 3 more blocks. Widening the entry to drop the page table is a net loss. |
| `LINE_SLOTS` 96 → ≤68 | −7 | **Not safe.** Measured peak is 86 descriptors on one scanline.

`sprite_ram` (256), `palette_ram` (128) and `work_ram` (64) are all exactly
`bits / 8192` — the Cyclone V floor for true-dual-port 16-bit memories. They
are board-accurate sizes and cannot be reduced without changing the memory map.

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
