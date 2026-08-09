# V60 executed-opcode hit list — Dyna Gear

Branch: `work/v60-opcode-audit`  ·  Worktree: `SVV-v60`  ·  Forked from `main` at `c80d8f8`

## Why this exists

`s32_v60` is **19,917 ALMs — 47.5% of the device** (see
[`DYNAGEAR_CORE_AUDIT.md`](DYNAGEAR_CORE_AUDIT.md), *ALM distribution*). It is
the only meaningful area lever left. Four instruction groups in
`rtl/cpu/v60/s32_v60.sv` are partial implementations and are the obvious
candidates to parameter-gate away:

| Opcode | Group | Implemented sub-opcodes (`s32_v60.sv`) |
|---|---|---|
| `0x59` | decimal / BCD | `00` ADDDC, `01` SUBDC, `02` SUBRDC, `10` CVTDPZ, `18` CVTDZP |
| `0x5B` | bit string | `00` SCH0BSU, `02` SCH1BSU, `08` MOVBSU, `09` MOVBSD |
| `0x5D` | bit field | `08` EXTBFS, `09` EXTBFZ, `0A` EXTBFL, `18` INSBFR, `19` INSBFL |
| `0x5C` | floating point | `00` CMPF, `08` MOVFS, `09` NEGFS, `0A` ABSFS, `10` SCLFS, `18` ADDFS, `19` SUBFS, `1A` MULFS, `1B` DIVFS |
| `0x5F` | floating point convert | `00` CVTWS, `01` CVTSW |

Any sub-opcode outside those sets already takes the reserved-instruction
exception (vector 8) in the current RTL, so gating cannot make those worse.

**The whole point of this document is the coverage statement, not the
histogram.** Read [Coverage](#coverage--what-was-actually-reached) before
acting on anything else here.

---

## Verdict

Ordered by confidence, most confident first. "Live sites" is the number of
places in the whole 1 MiB program ROM that could be an instruction of that
group *and* sit in a 4 KB block where the audit actually executed something —
i.e. the only places a gated group could plausibly still be reached from.

| Group | Executed in any run? | ROM candidates | Survive boundary vote | **Live sites** |
|---|---|---:|---:|---:|
| `0x5B` bit string | **No** | 22 | 4 | **0** |
| `0x5D` bit field | **No** | 2 | 1 | **1** |
| `0x5F` float convert | **No** | 47 | 16 | **2** |
| `0x5C` floating point | **No** | 349 | 51 | **5** |
| `0x59` decimal / BCD | **No** | 88 | 15 | **7** |

Also never executed: `0x58` and `0x5A`, the byte/half string groups that *are*
fully implemented. **The entire two-byte `0x58..0x5F` family is unused by
everything that was reached.** That is a useful calibration — it says the
compiler that built this game emitted none of the F7a/F7b/F7c formats, not
just none of the exotic ones.

**None of these is *proven* unused.** The evidence is "not observed in 51.3
billion executed instructions across ~7.2 hours of emulated play spanning
several stages" — which is a lot, but the game was never finished. See
[Residual risk](#residual-risk).

---

## Method

MAME 0.285 exposes no `set_instruction_hook` in its Lua API (`cpu.debug` has
only `bpset`/`wpset`/`step`/`go`), and single-stepping ~2 M instructions/s from
Lua is not viable. Instead
[`tools/mame-v60-opcode-histogram.lua`](../tools/mame-v60-opcode-histogram.lua)
installs a read tap over the program-ROM window `0xf00000-0xffffff` and keeps
only the taps whose address equals the CPU's current `PC`.

In MAME's V60 core `PC` is updated to the instruction start *before* the
opcode fetch, so `tap_address == PC` is true for exactly the opcode byte and
false for every operand byte and every data read. The program space is 16-bit
little-endian, so the tap offset is the word address and the byte lane comes
from the mask. This was confirmed empirically against the reset stub:

```
TAP off=00f10120 data=00008009 mask=000000ff PC=00f10120   <- opcode byte
TAP off=00f10122 data=0000f3e4 mask=000000ff PC=00f10120   <- operand, rejected
```

Cost: ~4× slowdown (1237% → ~320% of real time headless).

### Two things that would have silently produced a false "never executed"

1. **A collected tap.** `install_read_tap` returns a passthrough handler that
   is removed when its Lua wrapper is garbage-collected. Held in a local, it
   died a few seconds in and the run then looked exactly like "the game stopped
   executing new code" — op counts frozen, emulation *faster*. The handle is
   now a deliberate global. Any future run whose `ops=` column stops advancing
   in the `.progress` file has hit this and must be discarded.

2. **A detector that cannot detect.** Verified positively rather than assumed.
   `V60_INJECT=addr:op:sub` patches the loaded program ROM so the instruction
   at `addr` becomes the given group opcode. Injecting each group at `f10130`
   (an address executed during boot) produces exactly one recorded hit:

   ```
   inj_59: OP 59 1 f10130 1        inj_5c: OP 5c 1 f10130 1
   inj_5b: OP 5b 1 f10130 1        inj_5d: OP 5d 1 f10130 1
   inj_5f: OP 5f 1 f10130 1
   ```

   Artefacts: `sim_output/mame/control/inj_*.txt`. So a zero count in an
   evidence run is a real absence, not a blind spot.

### A counting artefact worth knowing

Retired-instruction counts come out at a suspiciously constant
1,993,795/emulated second regardless of what is on screen. That is not a bug
in the tap: MAME's V60 core charges a flat ~8 cycles per instruction
("this is just an average"), so 16 MHz / 8 ≈ 2.0 M instr/s always. Use the
counts as a scale indicator, not as a profile. Consecutive taps at the same PC
are also collapsed, so a one-instruction self-loop counts once per entry rather
than once per iteration. Neither affects the presence/absence answer.

---

## Coverage — what was actually reached

**This is the load-bearing section.**

The bot is a deterministic PRNG-driven input generator, not a player. It is
not good at the game, but with Free Play, Easy, four lives and four hearts it
does make progress. Verified from end-of-run screenshots
(`sim_output/mame/wave1_contact.png`, `sim_output/mame/last_*.png`), the runs
reached:

* boot, title, attract loop and demo, character select;
* **both playable characters** — Roger and Wolf both appear in the HUD;
* **at least five visually distinct stage environments**: the stage-1 jungle,
  a dark vine swamp, a brown cave/rock interior, a grey stone-ruins/temple
  stage, and a sunset forest; plus the stage-1 boss arena (stone idol +
  pterodactyl);
* scores of at least **61,560** (highest seen in a sampled screenshot;
  the screenshots are every 120 s, so this is a lower bound) against a
  default table top of 80,000;
* death, respawn, continue and game over;
* two-player simultaneous play (two HUDs, Roger + Wolf);
* the service/test menu.

So the game was **not** confined to stage 1. It was also not finished — no run
was observed reaching an ending, and the high-score name-entry screen was never
confirmed.

### The number that actually matters

Distinct executed instruction addresses per run, sampled from the `.progress`
files:

| run | 60 s | 300 s | 600 s | 900 s | 1200 s | 1500 s |
|---|---:|---:|---:|---:|---:|---:|
| `play_easy_s41` | 7,501 | 9,546 | 10,040 | 10,551 | 10,554 | 10,591 |
| `play_easy_s7` | 7,741 | 9,840 | 10,090 | 10,281 | 10,492 | 10,510 |
| `play_easy_s89` | 7,592 | 9,746 | 10,069 | 10,184 | 10,187 | 10,209 |
| `play_easy_s13` | 7,289 | 9,828 | 10,040 | 10,111 | 10,118 | 10,585 |
| `play_2p_s23` | 8,056 | 10,248 | 10,370 | 10,571 | 10,571 | 10,571 |
| `gameover_s31` | 7,724 | 10,915 | 11,402 | 11,402 | 11,402 | 11,402 |
| `idle_s1` (attract only) | 5,981 | 8,075 | 8,078 | 8,078 | 8,078 | 8,078 |
| `service_s1` | 1,558 | 1,558 | 1,558 | 1,558 | 1,558 | 1,558 |

**Every run is within a few per cent of its final coverage by 600 s and barely
moves after that — while still advancing through new stages.**
`play_easy_s41` is in the stage-1 jungle at 480 s and in a sunset-forest stage
at 1320 s; across that whole span it gains 551 new instruction addresses
(10,040 → 10,591, +5.5%), and only 37 of those come after 900 s. `gameover_s31`
is completely flat from 600 s onward. Attract mode alone (`idle_s1`) reaches
8,078 — i.e. **roughly 78% of all the code the playing runs ever execute is
already covered by attract mode**.

That is the strongest single piece of evidence in this audit, and it is an
argument about the *shape* of the game rather than about how far the bot got:
**Dyna Gear's stages are data, not code.** New stages bring new tile, sprite
and layout data through the same engine, so the marginal code coverage of
reaching stage 6 rather than stage 3 is close to zero. It does not follow that
it is exactly zero — a boss with a unique mechanic, an ending sequence or a
name-entry routine can still be code nobody has run.

From the executed-PC list of a representative run
(`sim_output/mame/pc/pc_s2.pclist`, `play_rush` seed 2, 420 s): **10,133
distinct instruction addresses in 42 of the ROM's 256 4 KB blocks**, all below
`f4c000` apart from the reset stub. Whether the other 214 blocks are unrun code
or simply data is not resolved here — the linear-disassembly density suggests
mostly data, but that is a heuristic, not a measurement.

---

## Results

### Run matrix

`tools/run-v60-opcode-audit.sh` (wave 1) and `tools/run-v60-opcode-wave2.sh`
(wave 2). MAME **0.285** (Debian `0.285+dfsg1-1`), `dynagear`, headless
`-video none -sound none -nothrottle`.

| wave | preset | seeds | emulated per run |
|---|---|---|---|
| 1 | `play_easy` | 1, 7, 13, 29, 41, 53, 67, 89 | 1500–1560 s |
| 1 | `play_2p` | 5, 23 | 1500 s |
| 1 | `gameover` | 3, 31 | 1380–1560 s |
| 1 | `idle` (attract only) | 1 | 1560 s |
| 1 | `service` (test menu) | 1 | 1620 s |
| 2 | `play_rush` | 2, 11, 17, 19, 37, 43, 59, 71, 97, 101, 113, 127 | 360–420 s |

**26 runs, ≈7.2 hours of emulated gameplay, 51,320,291,061 retired
instructions.**

Two honesty notes on the matrix:

* Wave 1 was launched for 1800 s per run but its driver process was stopped at
  ~1500 s, so every wave-1 report is the last incremental dump rather than a
  clean final one (`# final=false`). The reports are complete and consistent up
  to that point; only the nominal duration is short.
* Wave 2 was launched for 2400 s per run and deliberately cut to ~400 s to
  free CPU for the RTL simulations. Its results are therefore a subset in time
  of what wave 1 covers, and it contributes seed diversity rather than depth.

### The hit list

Committed as [`V60_OPCODE_HITLIST.txt`](V60_OPCODE_HITLIST.txt) — merged
per-opcode counts, first PC, the list of primary opcodes never executed, and
the `0x58..0x5F` verdicts.

Headline numbers:

```
# total_retired_instructions=51320291061
# distinct_primary_opcodes_executed=106 of 256

GROUP 58  NOT-EXECUTED  (byte string, fully implemented)
GROUP 59  NOT-EXECUTED  (decimal / BCD)
GROUP 5a  NOT-EXECUTED  (half string, fully implemented)
GROUP 5b  NOT-EXECUTED  (bit string)
GROUP 5c  NOT-EXECUTED  (floating point)
GROUP 5d  NOT-EXECUTED  (bit field)
GROUP 5e  NOT-EXECUTED  (long float - not implemented, not claimed)
GROUP 5f  NOT-EXECUTED  (floating point convert)
```

106 of 256 primary opcode values were executed. The 150 never seen include the
whole `0x58..0x5F` block.

---

## Static bound

Dynamic evidence can only prove presence. The complementary static bound comes
from [`tools/scan-v60-opcode-sites.py`](../tools/scan-v60-opcode-sites.py) and
[`tools/analyse-v60-candidates.py`](../tools/analyse-v60-candidates.py).

**Step 1 — candidate sites.** Every offset in the 1 MiB program ROM where the
byte is a group opcode *and* the next byte's low five bits are an implemented
sub-opcode. A group with zero candidates could never execute on any path,
reached or not. None of the five has zero, so nothing is excluded here:

```
SCAN 59 raw=159  cand=88    decimal (BCD)
SCAN 5b raw=119  cand=22    bit string
SCAN 5c raw=662  cand=349   floating point
SCAN 5d raw=645  cand=2     bit field
SCAN 5f raw=153  cand=47    floating point convert
```

**Step 2 — instruction-boundary vote.** MAME's own V60 disassembler was run
over the whole ROM from four different byte alignments (`dasm` via the
debugger). A variable-length decoder self-synchronises, so an operand byte is
an instruction start under *no* alignment while a byte on the converged stream
is a start under all four:

```
CAND 59  decimal (BCD)            total=88    zero_votes=73   full_votes=15
CAND 5b  bit string               total=22    zero_votes=18   full_votes=4
CAND 5c  floating point           total=349   zero_votes=298  full_votes=51
CAND 5d  bit field                total=2     zero_votes=1    full_votes=1
CAND 5f  float convert            total=47    zero_votes=31   full_votes=16
```

**What this does and does not establish.** Zero votes is real evidence the byte
is an operand or table byte. Full votes is **not** evidence it is code — linear
decoding of a pure data region converges just as happily onto nonsense. The
align-0 stream produces 499,135 "instructions" across 1 MiB, i.e. ~2.1 bytes
each, which is far denser than real V60 code and shows most of the ROM is being
decoded as garbage. So the surviving counts are an **upper bound on the number
of real sites**, not a count of them.

**Step 3 — is the site anywhere near real code?** The executed-PC list
(`sim_output/mame/pc/pc_s2.pclist`, 10,133 distinct addresses) says which 4 KB
blocks of the ROM the audit ever executed anything in:

```
executed distinct addresses: 10133
4KB blocks touched: 42 of 256
touched ranges: f00000-f01fff  f10000-f11fff  f1d000-f1efff
                f22000-f26fff  f2c000-f47fff  f4a000-f4bfff  fff000-ffffff
```

All executed code lives below `f4c000` (plus the reset stub at the very top).
Crossing that against the surviving candidates gives the **live sites** column
in the verdict:

| group | survives vote | in a block we executed | in a block never executed |
|---|---:|---:|---:|
| `0x59` decimal | 15 | **7** | 8 |
| `0x5B` bit string | 4 | **0** | 4 |
| `0x5C` float | 51 | **5** | 46 |
| `0x5D` bit field | 1 | **1** | 0 |
| `0x5F` float convert | 16 | **2** | 14 |

The 15 sites, in full:

```
59  f1e038 subrdc   59  f1e268 subrdc   59  f2243c adddc   59  f30c1c adddc
59  f346e6 adddc    59  f3e449 adddc    59  f3f57b adddc
5c  f013bc cmpf.s   5c  f014fe cmpf.s   5c  f10ba6 cmpf.s  5c  f3f2cc mulf.s
5c  f477fa cmpf.s
5d  f44a49 extbfl
5f  f3b2ae cvt.ws   5f  f3e634 cvt.sw
```

Supporting observation, offered as an observation and not as proof: the 46
excluded `0x5C` sites include a run at `f81d2c`, `f82520`, `f82530`, `f82b20`,
`f82b30`, `f83524`, `f83534` … — regular strides in a region 3.5 MB above any
executed instruction. That is table structure, not code.

**`0x5B` (bit string) is the strongest case in the audit**: not one of its 22
ROM candidates both survives the boundary vote *and* sits in a block where the
audit executed anything. `0x59` (decimal) is the weakest, with seven live sites
scattered across blocks in which hundreds of instructions were executed —
those are plausible cold branches in live code.

---

## Recommendation

1. **Task 2 (parameter-gating) is justified as a mechanism, with the default
   left at enabled.** Adding `localparam` gates that default to *enabled*
   changes nothing about the release build, costs nothing to carry, and makes
   the area experiment cheap for whoever runs the next fit. That is worth
   doing.

2. **Do not ship a build with any of these groups gated off on the strength of
   this audit.** Nothing here rules out a later stage or boss using them. The
   failure mode is bad: an unimplemented sub-opcode takes the
   reserved-instruction exception, which on hardware would appear as a hang or
   a crash, arbitrarily deep into a playthrough, long after the build shipped.

3. **Priority order if area is needed**, most to least defensible, by live
   sites: `0x5B` bit string (0) → `0x5D` bit field (1) → `0x5F` float convert
   (2) → `0x5C` float (5) → `0x59` decimal (7). Measure each gate's ALM saving
   separately before choosing — the ranking above is about *risk*, and the
   cheapest-risk group is not necessarily the biggest area win.

4. **`0x59` decimal deserves the most caution despite its ranking.** BCD
   arithmetic is exactly what score and timer formatting would use. The audit
   watched scores climb from `8510` past `61560` and the stage timer count down
   repeatedly without a single `0x59`, so this game formats those some other
   way. The audit watched scores climb past 60,000 with no `0x59`, but score
   handling *at a high-score table entry* is the one score path never
   exercised, and that is the group whose absence would be most surprising in
   general.

5. **What would actually settle it:** finishing the game. The cheapest paths
   are a recorded human input file (`mame -record`) replayed under this
   harness, or freezing player health via a RAM poke so the bot can grind to
   the ending and into name entry. Neither was done here.

---

## Residual risk

* **Coverage is still the risk, but it is a narrower risk than it looks.**
  Several stages, both characters, 2P, game over and the service menu were all
  reached, and code coverage stopped growing long before the run ended. What
  remains unrun is whatever is unique to the stages, bosses, ending and
  name-entry screen that were never seen — and per the plateau above, most
  stage content is data rather than code. The residual exposure is
  *event-specific* code, not stage content.
* **Static analysis cannot close the gap.** Every group still has surviving
  candidate sites, so none can be excluded on static grounds alone.
* **The harness measures MAME, not the RTL.** It proves what the *game* does,
  which is the right question for gating, but it says nothing about whether
  `s32_v60`'s implementation of any executed opcode is correct.
* **MAME version is 0.285, not the 0.288 the brief asked for.** 0.288 is not
  packaged for this machine and was not built. The `ssv.cpp` V60 driver and the
  V60 core are long-stable, and the opcode *stream* comes from the game ROM
  rather than from MAME, so the version difference is very unlikely to matter —
  but it is a difference, and the existing scenario JSONs record `0.288`.

---

## Reproduction

```bash
# ROM staged at sim_output/mame/roms/dynagear.zip
tools/run-v60-opcode-audit.sh 1800      # wave 1: 14 runs, mixed presets
tools/run-v60-opcode-wave2.sh 2400 12   # wave 2: 12 forward-biased seeds
python3 tools/merge-v60-opcode-reports.py sim_output/mame/audit*/*.txt \
    > docs/V60_OPCODE_HITLIST.txt

# static bound
python3 tools/scan-v60-opcode-sites.py sim_output/rom/maincpu.bin
python3 tools/analyse-v60-candidates.py --rom sim_output/rom/maincpu.bin \
    --dasm '/tmp/dasm/align*.txt' --pclist 'sim_output/mame/pc/*.pclist'

# positive control - must report one hit per group
V60_INJECT=f10130:59:00 V60_PRESET=idle V60_OUT=/tmp/c.txt \
  mame dynagear -rompath sim_output/mame/roms -video none -sound none \
    -nothrottle -seconds_to_run 5 \
    -autoboot_script tools/mame-v60-opcode-histogram.lua
```

The input bot is fully determined by `V60_PRESET` and `V60_SEED`; the schedule
is a pure function of the emulated frame index and a seeded LCG, so a rerun
with the same pair reproduces the same inputs.

Version pinning: MAME `0.285+dfsg1-1`; program ROM
`maincpu.bin` sha256 `c29d3bf37b761aad1f13b01be7da9904c0a975826744b820fdc664c098c66289`.
