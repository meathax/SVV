# SSV game-expansion gap analysis

Read-only analysis, 13 Aug 2026. **No RTL was changed, no Quartus or Verilator
stage was run, and no RBF was built.**

Scope: the 21 setnames that already have an MRA under `mra/` but are *not* in
`tools/ssv_supported_sets.py`:

`eaglshot eaglshotj gdfs hypreac2 hypreact janjans1 janjans2 jsk keithlcy
koikois2 meosism mslider pastelis ryorioh srmp4 srmp4o srmp7 stmbladej
sxyreac2 sxyreact vasara2a`

Behavioural authority is MAME 0.289 at `D:\Arcade\AI\mame289`, files
`src/mame/seta/ssv.cpp` and `src/mame/seta/ssv_v.cpp` (per `core-debug.toml`
`[reference]`). Every hardware claim below cites an `ssv.cpp` line number.
Repository claims cite `file:line`.

---

## 0. What the core is working with today

| Budget | Latest recorded fit | Source |
|---|---|---|
| ALMs | 39,628 / 41,910 (**95%**) | `docs/OPTIMIZATION_PRE_RBF.md` |
| M10K | 517 / 553 (**93%**), 416 of them board-accurate floor | same |
| DSP | 44 | same |
| Worst setup | **+0.04 ns** across all corners, and only with `ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM` + `SEED 3` | same |

The doc's own words for that timing number: *"a passing lottery ticket rather
than margin"*. Any change that adds logic must be assumed to reopen timing and
require a fresh seed sweep.

Reference cost datum for optional devices: pruning **all five** optional I/O
devices in `f0622c5` recovered only **−238 ALMs / −1,152 registers**, and the
GDFS serial EEPROM alone was **663 combinational ALUTs** of that
(`docs/OPTIMIZATION_PRE_RBF.md`, "Qualified-profile optional-device pruning").
So the whole mahjong + uPD4701 + uPD7001 + ADC0809 group together is well under
**~100 ALMs**. This is the single most important number in this document: the
Tier 2 devices are nearly free, and the expensive items are memory geometry and
new CPUs/renderers, not the pruned I/O.

### What already exists and is instantiated

- `ssv_pkg::ssv_cfg_t` (`rtl/ssv_pkg.sv:208-264`) already carries
  `mahjong_mode`, `input_layout`, `custom_output_mode`, `optional_io_mode`
  (documented as *1 Eagle/uPD4701, 2 Sexy/uPD7001, 3 GDFS/ST0020+ADC+EEPROM*),
  `adc_conversion_cycles`, `srmp7_sample_half_bank`, `srmp7_irqv_mame`,
  `mainram_mirror_010000`, `irq_level2_line120`, `extra_ram_mode`, `nvram_mode`.
- `tools/ssv_cfg_block.py:146-180` already derives all of those from `ssv.cpp`.
- `rtl/mem/ssv_rom_loader.sv:117-163` already decodes them from the v3
  descriptor, and `:363` already has the Eagle Shot linear-graphics copy path.
- `Arcade-SSV.sv:571-581,662-664` already plumbs `mahjong_rows`,
  `optional_coord_x/y`, `optional_paddle` and `in_ball_switch` into `ssv_core`.
- `ssv_irq.sv:19,68,106` already implements the `irq_level2_line120` raster IRQ.
- `rtl/audio/ssv_srmp7_bank.sv` **is** instantiated (`rtl/ssv_core.sv:1114`).
- `ssv_pkg.sv:81,129` already reserves `SDR_EAGL_RAM_BASE` / `_SIZE` (4 MiB).

### What exists as source but is NOT instantiated (pruned in `f0622c5`)

`rtl/io/ssv_93c46_16.sv`, `rtl/io/ssv_adc0809.sv`, `rtl/io/ssv_upd4701.sv`,
`rtl/io/ssv_upd7001.sv`, `rtl/io/ssv_mahjong_matrix.sv`,
`rtl/video/ssv_st0020_ctrl.sv`. All six are still listed in `files.qip:12-22`,
so re-enabling them is an `ssv_core.sv` instantiation + read/write-mux change,
not a new file. `rtl/ssv_core.sv:75-83,222-227` documents the removal.

`ssv_mahjong_matrix.sv:30-34` implements **all five** MAME matrix modes
(hypreact / hypreac2 / janjans1 / srmp4 / srmp7) with the correct per-mode
addresses and bit permutations — matching `ssv.cpp:493-503` (hypreact),
`:510-521` (hypreac2), `:530-538` (janjans1), `:623-635` (srmp4), `:669-681`
(srmp7).

### Hard evidence: which sets the existing tooling can already describe

`tools/gen_ssv_mras.py` was re-run against all 21 setnames with only the
manifest tuple substituted (read-only probe, output to scratchpad). **13 of 21
produced a valid 24-byte v3 descriptor with zero code changes.** The 8 failures
and their exact messages:

```
gdfs      : graphics region 8 MB is outside the supported profile
keithlcy  : graphics region 8 MB is outside the supported profile
meosism   : graphics region 8 MB is outside the supported profile
mslider   : graphics region 10 MB is outside the supported profile
pastelis  : graphics region 10 MB is outside the supported profile
hypreac2  : graphics region 40 MB is outside the supported profile
janjans1  : graphics region 40 MB is outside the supported profile
sxyreact  : graphics region 40 MB is outside the supported profile
```

(`SUPPORTED_GFX_MB = (12, 14, 16, 24, 32, 64)`, `tools/ssv_cfg_block.py:66`.)

A generated descriptor is necessary but **not** sufficient: it does not prove
the SDRAM slot is large enough, nor that the selected device exists in RTL.
Both are checked separately below.

---

## a) Per-set requirement table

Sizes are MAME `ROM_REGION` sizes and load extents, extracted mechanically from
`ssv.cpp` `ROM_START` blocks. "Stream" is the MRA index-0 byte count the
generator actually emits (populated quarters only; ES5506 `ROM_COPY` aliases
are address aliases and are not duplicated).

| Set | Game | Prog | Gfx region (stream) | Samples (real) | Extra hardware beyond a plain SSV board | Core has it? | New RTL needed |
|---|---|---|---|---|---|---|---|
| `ryorioh` | Gourmet Battle Quiz Ryohrioh CooKing | 4 MiB | 32 MiB (32) | 4 MiB | none — `ryorioh_map` is the *same map Vasara already uses* (`ssv.cpp:2585`, `:599-604`); write-kick watchdog; quiz input layout | **yes** | **none** |
| `vasara2a` | Vasara 2 (set 2) | 4 MiB | 32 MiB (32) | 8 MiB | none — identical machine/map/geometry to `vasara2` | **yes** | **none** |
| `stmbladej` | Storm Blade (Japan) | 4 MiB | 24 MiB (18) | 4 MiB | ST010 (`st010` region present) — identical to `stmblade` | **yes** (`cfg.has_st010`, `ssv_core.sv:249-257`) | **none** |
| `keithlcy` | Keith & Lucy | 2 MiB | 8 MiB (8) | 4 MiB | none (`keithlcy_map`, `ssv.cpp:545-552`); `$400000-$47ffff` is `.nopw()` write-sink, not RAM | **partial** | none in RTL; **whitelist 8 MiB** in `SUPPORTED_GFX_MB` |
| `meosism` | Meosis Magic | 1 MiB | 8 MiB (8) | 4 MiB (bank 2) | 64 KiB NVRAM `$580000-$58ffff` (`ssv.cpp:565`), read-kick watchdog (`:564`) | **partial** — `nvram_mode 2` already supported (cairblad) | none in RTL; **whitelist 8 MiB** |
| `hypreact` | Mahjong Hyper Reaction | 1 MiB | 24 MiB (18) | 4 MiB (bank 2) | mahjong matrix mode 1 @ `$c00000/$c00006` (`ssv.cpp:493-503`); inverted lockout; read-kick watchdog | **partial** — module exists, **not instantiated** | re-instantiate `ssv_mahjong_matrix` |
| `srmp4` | Super Real Mahjong PIV | 1 MiB | 24 MiB (18) | 4 MiB | mahjong matrix mode 4 @ `$c0000a/$c0000e` (`ssv.cpp:623-635`) | **partial** | same instantiation |
| `srmp4o` | Super Real Mahjong PIV (older) | 1 MiB | 24 MiB (18) | 4 MiB | identical to `srmp4` | **partial** | same |
| `janjans2` | JangJang Shimasho 2 | 4 MiB | 32 MiB (32) | 8 MiB | mahjong matrix mode 3 @ `$800002/$800000` (`ssv.cpp:530-538`) | **partial** | same |
| `koikois2` | Koi Koi Shimasho 2 | 4 MiB | 32 MiB (32) | 8 MiB | mahjong mode 3 (runs `janjans1` machine cfg, `ssv.cpp:4693`) | **partial** | same |
| `sxyreac2` | Pachinko Sexy Reaction 2 | 2 MiB | 32 MiB (24) | 8 MiB | **uPD7001 serial ADC** for the paddle (`ssv.cpp:2725-2727`), `dial_r`/`dial_w` @ `$500004`/`$520000` (`:748-763`), 64 KiB NVRAM, read-kick watchdog, ball-switch @ `$500002` | **partial** — `ssv_upd7001.sv` exists, **not instantiated**; analog plumbed at `Arcade-SSV.sv:581` | re-instantiate uPD7001 + `$500002/$500004/$520000` decode |
| `mslider` | Monster Slider | 1 MiB | 10 MiB (7.5) | 4 MiB | main-RAM mirror at `$010000-$01ffff` (`ssv.cpp:585-593`) | **partial** — `mainram_mirror_010000` is *decoded* (`ssv_rom_loader.sv:154`) but **read by nothing** in `ssv_core.sv` | mirror decode; **factor-5 tile modulus**; whitelist 10 MiB |
| `pastelis` | Pastel Island (proto) | 4 MiB region / **2 MiB window** | 10 MiB (10) | 4 MiB | raster IRQ at line 120 (`init_pastelis`, `ssv.cpp:2398-2402`; fired at `:249`); runs `keithlcy_map` with `ssv_map(map, 0xe00000)` | **partial** — raster IRQ **already implemented** (`ssv_irq.sv:68`) | **factor-5 modulus**; whitelist 10 MiB; **ROM-window base fix** (see §d) |
| `janjans1` | JangJang Shimasho | 4 MiB | **40 MiB** (40) | 8 MiB | mahjong mode 3 | **no** | mahjong instantiation + **factor-5 modulus** + **19-bit tile code** + **gfx slot > 32 MiB** |
| `sxyreact` | Pachinko Sexy Reaction | 2 MiB | **40 MiB** (30) | 8 MiB | uPD7001 (as `sxyreac2`) | **no** | uPD7001 + factor-5 + 19-bit code + gfx slot > 32 MiB |
| `hypreac2` | Mahjong Hyper Reaction 2 | 2 MiB | **40 MiB** (30) | **14 MiB** (`ensoniq.1` is **6 MiB**) | mahjong mode 2 @ `$500000/$500002/$520000` (`ssv.cpp:510-521`) | **no** | as `janjans1`, **plus** a sample-bank model that is not 4 MiB-per-slot |
| `srmp7` | Super Real Mahjong P7 | 4 MiB | **64 MiB** (64) | **24 MiB**, banks 2/3 are 8 MiB **switched** | mahjong mode 5; ES5506 bank switching @ `$580000` (`ssv.cpp:657-665`, `:683-693`); fake IRQ vector @ `$300076` (`:648-651`); extra RAM `$010000-$050faf` (`:672`) | **partial** — `ssv_srmp7_bank.sv` **is** instantiated; `srmp7_sample_half_bank`/`srmp7_irqv_mame`/`extra_ram_mode 3` exist in the descriptor | mahjong instantiation; **19-bit tile code**; **gfx slot 64 MiB**; **sample slot 24 MiB**; `extra_ram_mode 3` decode; `$300076` read |
| `eaglshot` | Eagle Shot Golf (US) | 1 MiB | **14 MiB `gfxdata`**, banked into CPU space (12 loaded) | 4 MiB | **uPD4701A trackball** @ `$900000`/`$d00000` (`ssv.cpp:2683-2685`, `:875-882`, `:897`); **sprite tiles come from 4 MiB of CPU-writable RAM**, not ROM (`ssv_v.cpp:212-221`, `gfx_eaglshot`/`layout_16x8x8_ram` `ssv.cpp:2318-2331`); gfx ROM banked 7×2 MiB into `$a00000-$bfffff` (`:869-873`, `:896`); 2 KiB NVRAM @ `$c00000`; **no** watchdog (`:889` `nopr()`) | **no** | uPD4701 instantiation (cheap) + **RAM-tile fetch path in the sprite renderer** + **CPU-visible banked gfx-ROM window** |
| `eaglshotj` | Eagle Shot Golf (JP bootleg) | 1 MiB | as `eaglshot` | 4 MiB | identical | **no** | identical to `eaglshot` |
| `jsk` | Joryuu Syougi Kyoushitsu | 1 MiB | 16 MiB (16) | 4 MiB | **second CPU: NEC V810 @ 25 MHz** with its own 512 KiB ROM and 3×128 KiB RAM (`ssv.cpp:2786`, `jsk_v810_mem` `:838-845`); 4-word bidirectional latch `$900000` ↔ `$40000000` (`:805-835`); 512 KiB RAM `$400000-$47ffff`; main-RAM mirror `$050000-$05ffff` (`:830-836`) | **no** | **an entire V810 CPU core** + latch + two new RAM windows |
| `gdfs` | Mobile Suit Gundam Final Shooting | 4 MiB | 8 MiB sprites (6) **+ 16 MiB `st0020_spr` + 0.5 MiB `tiles`** | 8 MiB | **ST0020 zooming-sprite chip + blitter** (`ssv.cpp:2504-2505`, regs/sprram/gfxram @ `$800000/$8c0000/$900000`, `:485-489`); **its own 16×16×8 tilemap layer**, 128 KiB `tmapram` + scroll (`:456-459`, `ssv_v.cpp:223-242`, `:927-940`); **93C46 serial EEPROM** (`:2485`); **ADC0809 + two light guns** (`:2487-2492`, ports `:1344-1354`) | **no** | ST0020 sprite engine, tilemap layer, EEPROM, ADC, dual-gun input |

Note on `sxyreac2`'s tile modulus: its region is 32 MiB (2^18 tiles), so it
needs **no** modulus change; only `sxyreact` (40 MiB) does. That is the only
place the two Sexy Reaction sets differ materially.

---

## b) Tiering

### Tier 1 — descriptor + MRA only, zero new RTL (6 sets)

| Set | Why it is free |
|---|---|
| `ryorioh` | Uses `ryorioh_map`, which is literally the map `vasara`/`vasara2` already run (`ssv.cpp:2585`). Descriptor generates clean today. |
| `vasara2a` | Byte-for-byte same geometry, map and machine config as the supported `vasara2`. |
| `stmbladej` | Same as supported `stmblade`, including the `st010` region. |
| `srmp4o` | Same geometry as `srmp4` — but inherits `srmp4`'s Tier 2 mahjong dependency, so it ships with it, not before it. |
| `keithlcy` | Only blocker is the 8 MiB entry missing from `SUPPORTED_GFX_MB`. Tiles = 2^16, fits every existing path. |
| `meosism` | Same 8 MiB whitelist issue. `nvram_mode 2` and read-kick watchdog are already supported by `cairblad`. |

Cost: **0 ALMs, 0 M10K, no timing risk.** `keithlcy`/`meosism` need one tuple
entry in `tools/ssv_cfg_block.py:66`.

Strictly, `srmp4o` belongs in Tier 2 because of the matrix; it is listed here
only to record that it needs nothing of its own beyond `srmp4`.

### Tier 2 — re-enable an already-written, currently-pruned device (7 sets)

| Set | Pruned module to re-instantiate |
|---|---|
| `hypreact` (mode 1) | `rtl/io/ssv_mahjong_matrix.sv` |
| `srmp4`, `srmp4o` (mode 4) | same |
| `janjans2`, `koikois2` (mode 3) | same |
| `sxyreac2` | `rtl/io/ssv_upd7001.sv` + `$500002/$500004/$520000` decode |

Work: instantiate the module in `ssv_core.sv`, add its `selected`/`rdata` into
the existing read mux, and delete the "UNUSED" note at `rtl/ssv_core.sv:75-83`.
The top level already supplies `in_mahjong_rows` (`Arcade-SSV.sv:571-575`) and
`optional_paddle` (`:581`), so nothing changes above `ssv_core`.

Cost: the whole five-device family was **238 ALMs**, and the EEPROM (not needed
here) was 663 ALUTs of it. Expect the matrix + uPD7001 to land in the **low tens
of ALMs**, no M10K, no DSP. This is the best value-per-ALM in the entire plan.

### Tier 2b — existing device, but the *memory map* has to grow (4 sets)

These need no new device model, only geometry work in `ssv_pkg.sv` /
`ssv_rom_loader.sv` / the row fetcher:

| Set | What has to grow |
|---|---|
| `mslider`, `pastelis` | tile modulus factor **5** (10 MiB → 0x14000 = 5·2^12 tiles); `SUPPORTED_GFX_MB` += 10; `mainram_mirror_010000` decode (mslider); ROM-window base fix (pastelis) |
| `janjans1`, `sxyreact` | factor 5 **and** 19-bit tile code **and** a graphics slot larger than `SDR_GFX_SIZE = 32 MiB` (`ssv_pkg.sv:125`) |
| `srmp7` | 19-bit tile code; **64 MiB** graphics slot; **24 MiB** sample slot (`SDR_SAMPLES_SIZE` is 8 MiB, `ssv_pkg.sv:130`); `extra_ram_mode 3` decode; `$300076` fake IRQ-vector read |
| `hypreac2` | everything `janjans1` needs **plus** a 6 MiB ES5506 bank, which the 4-MiB-per-slot model in `sample_word_addr_cfg` (`ssv_pkg.sv:457-485`) cannot express |

**The 128 MB module does have room.** A legal revised map that keeps every
region bank-separated (the property `ssv_pkg.sv:41-59` says is worth ~470k row
conflicts per 215 frames):

```
bank 0  0x0000000  program, XRAM, CPU RAM, NVRAM, Eagle tile RAM   (<= 32 MiB)
bank 1+2 0x2000000  graphics, up to 64 MiB
bank 3  0x6000000  ES5506 samples, up to 24 MiB
        0x7800000  ST010 image (relocated from 0x6800000)
```

`0x2000000 + 64 MiB = 0x6000000` exactly, and `0x6000000 + 24 MiB = 0x7800000`,
leaving 8 MiB of bank 3 for the 68 KiB ST010 image. So the whole family fits
without evicting anything — but `layout_fault()` (`ssv_pkg.sv:605-693`),
`gfx_record_addr`, `wrap_code_cfg`'s 18-bit return (`:502-518`) and the
`SDR_ST010_BASE` constant all have to move together. Graphics spanning two
banks needs the row-conflict claim re-measured, not assumed.

Cost: small in ALMs (a mod-5 LUT alongside the existing mod-3 one, and one more
bit of tile code). **The risk is timing, not area** — `ssv_pkg.sv:214-218`
records that recomputing this mask as a variable shift cost **−12.7 ns**, so the
19th bit must be added as stored/precomputed fields, never as a wider shifter.

### Tier 3 — genuinely new hardware (4 sets)

**`eaglshot` / `eaglshotj` — moderate.** The uPD4701 itself is trivial
(`rtl/io/ssv_upd4701.sv`, 30 lines) and the trackball coordinates are already
plumbed (`Arcade-SSV.sv:579-580`). The real work is that **Eagle Shot does not
render sprites from ROM at all**: `video_start()` allocates 16 × 0x40000 bytes
of tile RAM and points gfx element 0 at it (`ssv_v.cpp:212-221`), the CPU writes
it through `$180000-$1bffff` with a bank in `m_scroll[0x76/2]` (`ssv.cpp:866-873`),
and the layout is linear 8bpp (`layout_16x8x8_ram`, `ssv.cpp:2318-2327`) rather
than the four-quarter planar record the row fetcher packs
(`ssv_pkg.sv:20-33`). Separately, `$a00000-$bfffff` is a 2 MiB CPU-readable
window banked over 7 entries of the 14 MiB `gfxdata` ROM (`ssv.cpp:869-873`).
The 4 MiB tile RAM slot is **already reserved** (`ssv_pkg.sv:81,129`) and the
loader **already** has the linear copy path (`ssv_rom_loader.sv:363`), so the
groundwork was clearly done before pruning. Estimate: **~200-400 ALMs** for a
second tile-source mode in the row fetcher plus a CPU-side SDRAM read port for
the bank window; no new M10K if the tile RAM stays in SDRAM.

**`gdfs` — the user's suspicion is CONFIRMED, and it is the expensive one.**
`ssv.cpp:2504-2505` instantiates `ST0020_SPRITES`, and `gdfs_map`
(`ssv.cpp:485-488`) maps 512 KiB of ST0020 sprite RAM, 256 bytes of registers
and **1 MiB of ST0020 gfx RAM** into the CPU space. `st0020.cpp`'s own header
describes it as *"Seta Zooming Sprites + 4 Tilemaps + Blitter"* (746 lines of
C++). On top of that, GDFS adds a **second, independent 16×16×8 tilemap layer**
of its own (256×256 tiles, 128 KiB `tmapram` at `$400000-$41ffff`, scroll at
`$440000`; `ssv_v.cpp:223-242`, drawn over the SSV sprites at `:927-940`), a
93C46 EEPROM (`:2485`) and an ADC0809 driving two light guns (`:2487-2492`).
Honest estimate:

- EEPROM: **663 combinational ALUTs** — a *measured* number from the pruning report.
- ADC0809 + gun plumbing: ~50 ALMs, plus a second analog port at the top level
  (only `joystick_l_analog_0` is currently wired, `Arcade-SSV.sv:180`).
- Tilemap layer: a new fetch/scroll/priority path over the existing renderer,
  plus M10K for its line buffer — **~300-600 ALMs, several M10K**.
- ST0020 zooming/rotating sprite engine + blitter: `rtl/video/ssv_st0020_ctrl.sv`
  is **46 lines of register/bank/blitter *control plane* only** — it explicitly
  says *"Rendering and RAM storage remain outside this module"*. The renderer
  does not exist. A second sprite engine with independent zoom, its own 512 KiB
  sprite RAM and a 1 MiB writable gfx RAM (both necessarily in SDRAM, competing
  for the same ports as the existing renderer) is realistically **1,500-3,000
  ALMs plus new M10K line buffers plus new SDRAM arbitration**.

Total: comfortably **>2,000 ALMs and multiple M10K** on a device at 95% ALM /
93% M10K with +0.04 ns of slack. **Defer.** It is also the only set whose
deferral costs nothing to the other 20.

**`jsk` — larger than gdfs, and easy to miss.** `ssv.cpp:2786` adds
`V810(config, "sub", 25000000)` — a full NEC V810 32-bit RISC CPU with a
512 KiB ROM region and three 128 KiB RAM windows (`jsk_v810_mem`,
`ssv.cpp:838-845`), talking to the V60 through a 4-word latch pair
(`:805-835`). For scale, this project's V60 is **20,015 ALMs, 58% of the entire
design** (`docs/OPTIMIZATION_PRE_RBF.md`). A V810 is simpler than a V60 but is
still plausibly **3,000-6,000 ALMs**. There is a MiSTer-ecosystem V810 (Virtual
Boy) that could be evaluated under evidence tier 4, subject to the licence/
provenance rules in `AGENTS.md`. **Defer — and note it is not cheaper than
gdfs.**

---

## c) Recommended order, and what is affordable at 95% ALM

**Affordable today, at the current occupancy:**

1. **`keithlcy`, `meosism`** — add `8` to `SUPPORTED_GFX_MB`
   (`tools/ssv_cfg_block.py:66`). Zero RTL, zero ALMs. Do this first because it
   also proves the whitelist is the only thing standing in the way, cheaply.
2. **`ryorioh`, `vasara2a`, `stmbladej`** — manifest + regenerate MRAs. Zero
   RTL, zero ALMs. Three sets for one commit.
3. **`hypreact`, `srmp4`, `srmp4o`, `janjans2`, `koikois2`** — re-instantiate
   `ssv_mahjong_matrix`. Five sets for one small instantiation; expected cost
   tens of ALMs.
4. **`sxyreac2`** — re-instantiate `ssv_upd7001` and decode `$500002/$500004/
   $520000`. One set, tens of ALMs.

That is **11 of 21 sets** for essentially no area. Even at 95%, this is the part
that should not wait.

**Affordable but requires a timing re-close (fresh seed sweep after each):**

5. **`mslider`, `pastelis`** — factor-5 modulus, 10 MiB whitelist, main-RAM
   mirror decode, ROM-window base fix. Small ALM cost; touches
   `wrap_code_cfg`, which `ssv_pkg.sv:214-218` records as timing-critical, so
   budget a re-fit.
6. **`srmp7`** — 19-bit tile code, 64 MiB graphics slot, 24 MiB sample slot with
   ST010 relocated, `extra_ram_mode 3`, `$300076`. Small in ALMs, large in map
   surgery; the mahjong matrix from step 3 is a prerequisite.
7. **`janjans1`, `sxyreact`** — ride on steps 5+6 (factor 5 + 19-bit code +
   larger graphics slot). No new devices beyond steps 3/4.
8. **`hypreac2`** — same as step 7, plus a decision on the 6 MiB `ensoniq.1`
   bank (see §d).

Steps 5-8 take the total to **19 of 21**.

**Requires freeing area first — do not attempt at 95%:**

9. **`eaglshot`, `eaglshotj`** (~200-400 ALMs). Borderline; try only after a
   real area win lands.
10. **`gdfs`** (>2,000 ALMs + M10K). **Defer.**
11. **`jsk`** (3,000-6,000 ALMs). **Defer**, and re-scope only if a donor V810
    with clean provenance is adopted.

The area lever the optimization notes already identify is `s32_v60` at 20,015
ALMs / 58% of the design (`docs/OPTIMIZATION_PRE_RBF.md`, "ALMs: one honest
answer"). Nothing in this plan changes that: **steps 9-11 are gated on V60 area
work, not on anything in this document.**

---

## d) What I could not determine

These are open questions, not estimates. Each needs its own investigation before
the affected set is scheduled.

1. **`hypreac2`'s 6 MiB `ensoniq.1` region.** The descriptor's sample model is
   strictly 4 MiB per slot (`ssv_pkg.sv:457-485`, `build_cfg_bytes` accepts only
   `sample_mb ∈ {4,8,24}`). MAME declares a 6 MiB region fully loaded. What the
   ES5506 reads above 6 MiB on the real board — wrap, mirror, or open bus — is
   not answerable from `ssv.cpp` alone. Do not pick a padding scheme by guess.

2. **Whether a graphics region spanning SDRAM banks 1 and 2 preserves the
   measured row-hit rate.** `ssv_pkg.sv:41-59` documents a real measurement
   (564,030 → 1,033,032 row conflicts over 215 frames) for the *opposite*
   change. A 64 MiB graphics region necessarily crosses a bank boundary; the
   effect is a measurement, not an inference.

3. **`pastelis`' program-ROM window.** MAME runs `keithlcy_map`, i.e.
   `ssv_map(map, 0xe00000)` (`ssv.cpp:547`) — a 2 MiB window — while its
   `maincpu` region is 4 MiB with only 2 MiB loaded. The core derives the window
   from the region size (`rom_window_base = -(prog_mb << 20)`,
   `ssv_core.sv:238`) and `gen_ssv_mras.py:520` passes the region size, so
   `pastelis` would place the window at `$c00000` instead of `$e00000`. Whether
   the correct fix is to derive `prog_mb` from the map's `rom` argument or to
   carry the window base as its own descriptor field is a design decision I did
   not make. **This is the one latent correctness bug this analysis found in the
   existing tooling.**

4. **`jsk`'s memory map is under-described by the current parser.**
   `extra_ram_mode` (`ssv_cfg_block.py:293-307`) matches only
   `$400000-$43ffff`, `$010000-$03ffff` and `$010000-$050faf`. `jsk_map`
   declares `$400000-$47ffff` RAM and a `$050000-$05ffff` main-RAM mirror
   (`ssv.cpp:830-836`), so the probe emitted `extra_ram_mode 0` for it — a
   silently wrong descriptor, not an error. Two new modes are needed. Same class
   of omission may exist for `gdfs` (`$420000-$43ffff`, `$600000-$600fff`).

5. **Whether `custom_output_mode` is needed by any of these sets.**
   `family_map_features` hardcodes it to `0` (`ssv_cfg_block.py:167`) and
   `build_cfg_bytes` rejects anything else (`:451`). I did not audit MAME's
   per-set output/lamp/motor writes (e.g. `sxyreact`'s `motor_w`,
   `ssv.cpp:731-734`) to see whether any game *reads back* state that depends on
   them.

6. **`game_id` capacity.** The field is 4 bits (`ssv_pkg.sv:210`) and
   `build_cfg_bytes` rejects `game_id > 7` (`ssv_cfg_block.py:413`). 8 supported
   + 21 new = 29 sets. `game_id` is decoded (`ssv_rom_loader.sv:117`) but read by
   no synthesizable logic, so widening or removing the check looks safe — I did
   not verify that no *testbench* or tool depends on the 0-7 range.

7. **Real ALM/M10K cost of every estimate in §b.** The only measured numbers
   here are the 238-ALM pruning delta and the 663-ALUT EEPROM. Everything else
   is an engineering estimate. A `quartus_map`-only run (seconds, per
   `CLAUDE.md`) would convert each into a fact before any of it is committed to —
   **but that requires explicit user authorization and was not run.**

8. **Verilator attract/screenshot qualification for any of the 21 sets.** Per
   `AGENTS.md`, a set is not supported until it clears the 360-frame attract gate
   with a non-empty PPM from the same run. None of these sets has been run.
   Local ROM availability for them was also not checked.

---

## Status

Analysis only. No RTL, MRA, manifest or build setting was modified. No Quartus
stage, no Verilator run, and **no RBF** — authorization for a build was neither
requested nor given.
