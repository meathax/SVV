# Issue contract: black screen on hardware, correct raster, corrupt SDRAM reads

## Issue

**Symptom (real MiSTer hardware, 2026-07-30).** The core loads and runs —
`/tmp/CORENAME` reads `dynagear`, `/tmp/RBFNAME` reads `SSV`, the MiSTer process
is running the SSV `.rbf` against `Dyna Gear.mra` — and emits a correctly timed
**336x240** raster. The picture is **pure black**: no title screen, no attract,
no partial or corrupted graphics.

**What makes it interesting.** Simulation of the same tree is green.
`tb_ssv_frame_crc` on `attract_idle` matches MAME 0.288 on **119 of 120**
frames with **1,425,025 non-black pixels** across the run
([`DYNAGEAR_ATTRACT_FRAME_CRC.md`](DYNAGEAR_ATTRACT_FRAME_CRC.md), 2026-07-30
re-measure). The single residual is frame 1, a one-frame phase difference on an
otherwise identical image. So the defect is in something simulation does not
model, and the first job was to find out what.

**Objective pass/fail.** See "Exit gate" at the end. In short: the painted probe
must read exactly `20 7A 0C`, and the attract frame CRC must still match.

**Status:** `suspect`. **Evidence tier:** `OBSERVED` (hardware capture) for the
symptom and the probe readback; the *cause* is a hypothesis and is **not
confirmed**. No fix has been proven on hardware at the time of writing.

**Affected platform:** DE10-Nano + single 64Mx16 128 MB SDR module on GPIO0.
Simulation is unaffected.

---

## Deterministic reproduction

Hardware, over SSH key auth (no password handling — `tools/deploy-mister.ps1:5`).

### 1. Build and gate

```powershell
pwsh tools\build-ssv.ps1
pwsh tools\report-quartus.ps1 -Revision "Arcade-SSV" -RequireReady
```

Never deploy a `Deployable: False` RBF — see the bisect row for `fad1c58`, which
is exactly what happens if you try.

### 2. Deploy, hash-verified, and boot the core

```powershell
pwsh tools\deploy-mister.ps1 -MisterHost 192.168.0.69 `
    -Rbf releases\SSV.rbf -CoreName SSV `
    -Mra "/media/fat/_Arcade/Dyna Gear.mra" -Boot
```

`deploy-mister.ps1` backs up the installed core, stages the upload as
`SSV.rbf.new`, compares MD5 both ends and only then swaps it in
(`tools/deploy-mister.ps1:31-55`), so a truncated transfer cannot masquerade as
a core bug. `-Boot` issues `load_core` and prints `/tmp/CORENAME` after 12 s
(`tools/deploy-mister.ps1:58-62`).

**Pair the RBF with the right MRA. See "Incidental finding 2" — a mismatched
pair produces a black screen for reasons that have nothing to do with this bug,
and it nearly corrupted this bisect.**

### 3. Confirm it is actually running, then screenshot

```bash
ssh root@192.168.0.69 'cat /tmp/CORENAME; cat /tmp/RBFNAME; \
                       ps w | grep -i mister | head'
ssh root@192.168.0.69 'echo screenshot > /dev/MiSTer_cmd'
ssh root@192.168.0.69 'ls -la /media/fat/screenshots/dynagear/ | tail -3'
```

MiSTer writes the capture to `/media/fat/screenshots/<CORENAME>/`, i.e.
`/media/fat/screenshots/dynagear/`, named by timestamp. Pull it back:

```bash
scp root@192.168.0.69:'/media/fat/screenshots/dynagear/<file>.png' .
```

### 4. Read the PNG properly

```python
from PIL import Image
im = Image.open("shot.png").convert("RGB")
print(im.size, im.getcolors(maxcolors=1 << 24))
```

**Do not hand-decode the PNG.** An earlier pass stripped the per-scanline filter
bytes without *applying* the filters and read the frame as all-zero, which is
the wrong answer and would have sent the investigation to the video chain. Use
PIL (or any real decoder).

### Screenshot size as a cheap oracle

A solid black 336x240 frame compresses to about **1,151 bytes**. Anything near
that number is a black screen without opening it; a rendered Dyna Gear title
screen is **~42 KB**. Every row in the bisect below is a real PNG pulled off the
device, and the byte count is quoted so the table can be re-derived rather than
believed.

### OSD state

Default: undoubled path (`sd_on` low — no forced scandoubler, `status[5:3]` = 0,
`Arcade-SSV.sv:755`). Video Fx off. See "Incidental finding 1" for what happens
with the doubler on.

---

## Hardware bisect

| commit | result | PNG | notes |
|---|---|---:|---|
| Jul 29 RBF (predates `4556e29`) | **WORKS** — Dyna Gear title screen, 336x240 | 42,752 B | renders using the **current v2** MRA |
| `0997ad8` | **WORKS** — title screen, 336x240 | 42,317 B | last known-good commit |
| `c429ba4` .. `8038c60` | **UNBUILDABLE** | — | see below |
| `2b44914` pure (clean tree, RBF SHA256 `ae92aa98…`) | **BLACK** | 1,151 B | paired with its **own v1** config block |
| HEAD + uncommitted work | **BLACK** | 1,151 B | |

**`c429ba4`..`8038c60` is not "untested", it is unbuildable.** `fad1c58` — whose
RTL is identical to `c429ba4`, being the docs-only commit immediately after it
(`git log --oneline 0997ad8..2b44914`) — fits but fails timing at worst
**-15.968 ns**, TNS **-643.426 ns**, `Deployable: False`. No valid RBF has ever
existed for that range. This is the `wrap_code_cfg` divider that `2b44914` later
fixed; `rtl/mem/ssv_rom_loader.sv:122-125` records the same -12.7 ns variable
shifter on the SDRAM address path.

**Conclusion.** The regression is inside the committed range
**`c429ba4`..`2b44914`**, and it is **not** in the uncommitted work — pure
`2b44914` is already black.

Commits in range, in order:

```
8a20468 verif: make the frame-CRC build usable, and able to build +REAL_SDRAM at all
c429ba4 Retarget to the 128 MB SDRAM module and generalise for nine SSV titles
fad1c58 docs: per-phase journals, including what the measurements refuted
7c26c49 sdram: close the tRFC / refresh question by deduction, not datasheet
fbeee8e Gate the bg renderer on renderer_busy, raise LINE_SLOTS, ...
a0fff45 Add the ST010 (NEC uPD96050) DSP core, ...
837c143 Restore CRT Adjust, upstream of the doubler, and fix its shrink-end overrun
8038c60 Integrate the ST010 into the core, gated per game
2b44914 Fix the timing disaster in wrap_code_cfg: a divider in the SDRAM address path
```

---

## Eliminated, and why

Each of these was ruled out by a measurement or by reading the gate, not by
assumption.

**`837c143` CRT Adjust — removed from the build entirely, still black.**
`rtl/crt_adjust.sv` is dropped from `files.qip` (the assignment is commented out
at `files.qip:34`) and the wrapper's video path is bypassed
(`Arcade-SSV.sv:685-701`). The screen stayed black. Worth recording that its Off
path was already a genuine bypass — `wire crt_rd_ce = crt_on ? crt_rd_tick :
av_ce` at `837c143:Arcade-SSV.sv:769` — so it was never a strong suspect; it was
removed because it was the cheapest untested thing to eliminate, and the comment
in the tree says exactly that rather than implying guilt.

**`7c26c49` tRFC / refresh — moved in the SAFE direction.** tRFC went from a
hardcoded 7 cycles (72 ns) to 12 cycles (124.2 ns at 96.648 MHz), and `refw_cnt`
was widened 3 → 4 bits because it could not express the larger value
(`rtl/mem/sdram.sv:40-49`, `rtl/mem/sdram.sv:203`). Over-waiting on tRFC costs a
fraction of a percent of the bus; it cannot corrupt a read.

**`a0fff45` / `8038c60` ST010 — inert for Dyna Gear.** The DSP is held in reset
by `rst || !cfg.has_st010`, and `ssv_st010_prg_fetch` forces `sdr_req <= 1'b0`
when `!enable`, so the p5 port never issues a transaction for a non-ST010 title
(`Arcade-SSV.sv:345-348`).

**SDRAM module size / aliasing — the geometry is right.** The user confirmed a
single 64Mx16 128 MB module, so `c429ba4`'s `BANK_BITS 2 / ROW_BITS 13 /
COL_BITS 11` at `Arcade-SSV.sv:441-442` is correct for the fitted part.

The arithmetic is worth recording anyway, because it says what a *wrong* module
would look like and it is worse than the docs claimed. On a 32 MB part the word
address is 24 bits, i.e. a 25-bit byte address wrapping at `0x2000000`. The four
region bases are `SDR_MAINCPU_BASE 0x0000000`, `SDR_GFX_BASE 0x2000000`,
`SDR_ST010_BASE 0x4000000` and `SDR_SAMPLES_BASE 0x6000000`
(`rtl/ssv_pkg.sv:66-95`) — all four are exact multiples of `0x2000000`, so **all
four alias onto address 0**. That does not "look like corrupt graphics": the
graphics stream lands on top of the V60 program and the program is destroyed.
`docs/PHASE3_128MB.md` has been corrected accordingly.

**Hardware, MiSTer setup, MRA index-0 stream, ROM zip — all exonerated by one
observation.** The Jul 29 RBF renders a correct title screen using the **current
v2 MRA** and the same `dynagear.zip`. The ROM data, the MRA's index-0 stream,
the SD card, the module and the display are therefore all fine.

**Default video chain — the raster is correct, only the content is black.** The
undoubled path emits correct 336x240 geometry (`Arcade-SSV.sv:780-789` with
`sd_on` low). The monitor locks. Timing is not the problem.

**`rom_sig_ok` is not holding the core in reset.** It feeds `debug_status` only
and is otherwise sunk in `unused_debug` (`Arcade-SSV.sv:820-821`). The reset
term is:

```systemverilog
wire core_reset = video_reset | ioctl_download | ~rom_loaded |
                  ~sdram_ready_sys | ~probe_done | wdog_rst;   // Arcade-SSV.sv:302-303
```

`probe_done` is in there, `rom_sig_ok` is not — the probe releases the CPU
whatever it read.

---

## The decisive measurement

An instrumented build (`+define+DBG_SDRAM_PAINT`, `Arcade-SSV.sv:703-746`)
paints the wrapper's **existing** ROM-signature probe onto the screen as RGB
instead of the core's raster:

```
R = probe_sig0[15:8]   G = probe_sig0[7:0]   B = probe_sig1[15:8]
```

`probe_sig0` is the word read back from SDRAM byte address `0x00000`,
`probe_sig1` from `0x1F3D0` (`Arcade-SSV.sv:363-365`, `:377-397`). This is not
new instrumentation of the memory system — the probe has always run before the
CPU is released; its result was simply wired to `debug_status`, which nothing on
hardware can see.

### Expectations, validated against the real ROM

Read off `sim_output/rom/maincpu.bin` (0x100000 bytes):

```
@0x00000:  7A 20 00 00 7A 52 00 00 7A D3
@0x1F3D0:  7A 0C 00 31 32 33 34 35 36 37
```

Little-endian words: `0x207A` at `0x00000`, `0x0C7A` at `0x1F3D0` — matching
`rom_sig_ok`'s constants at `Arcade-SSV.sv:387`. Expected paint: **RGB
(20, 7A, 0C)**.

### What hardware returned

**RGB (00, 7A, 35), on 100 % of 80,640 pixels** (336 x 240), confirmed by
decoding the PNG with PIL.

| probe | requested | expected word | returned word | verdict |
|---|---|---|---|---|
| `probe_sig0` | byte `0x00000` | `0x207A` | `0x007A` | low byte `0x7A` **correct**, high byte `0x00` **wrong** |
| `probe_sig1` | byte `0x1F3D0` | `0x0C7A` | high byte `0x35` | `0x35` is ASCII `'5'`, which lives at byte `0x1F3D7` |

`0x35` at `0x1F3D7` is the high byte of the word at `0x1F3D6` — **+3 words (+6
bytes) past the requested word address.**

### What that rules out

Two reads, corrupted in **different** ways, each partly resembling correct data:

- **Not a consistent address-mapping offset.** A wrong bank/row/column slice
  applies the same displacement to every access. One read off by zero words in
  its low byte and another off by three words is not one mapping.
- **Not DQM byte masking.** `dqm <= ~be_r` (`rtl/mem/sdram.sv:790`) is correct
  for the loader's `be = 2'b11`, and reads drive `dqm <= 2'b00`
  (`rtl/mem/sdram.sv:680`). A stuck DQM would zero the *same* byte lane on every
  read; `probe_sig0` lost its high byte while `probe_sig1` did not.
- **Not "the ROM never arrived".** `0x7A` came back correct from `0x00000`, and
  `0x35` is genuine ROM content from 6 bytes away. The data is in the part.

The picture is of a controller that gets the **right neighbourhood** and the
**wrong bytes** — a data-capture problem, not an addressing one.

---

## Leading hypothesis

> The controller captures the DQ bus on the wrong cycle: a CAS-latency /
> read-pipeline error in the `c429ba4` rewrite of `rtl/mem/sdram.sv` (345 lines
> changed — `git show --stat c429ba4 -- rtl/mem/sdram.sv`).

Relevant signals and code: `cl_pipe`, `rd_captured`, `rd_total`, `rd_issued`,
`cap_buf`, `ack_stretch`, the `deliver()` task, and
`always @(posedge clk) dq_in <= SDRAM_DQ` (`rtl/mem/sdram.sv:617-636`,
`:685-694`). `CL = 3'd2` (`rtl/mem/sdram.sv:144`), programmed by
`MRS = 13'b000_0_00_010_0_000` — CL2, sequential, burst 1
(`rtl/mem/sdram.sv:670-674`).

**Refutation condition, stated before the test.** If a build that changes only
the capture alignment (or a chip-model run with `+sdram_read_skew` — see below)
cannot produce both observed corruptions, and the painted probe still reads
anything other than `20 7A 0C`, the read-alignment hypothesis is wrong and the
next rung down is the *physical* interface: DQ input timing, `SDRAM_CLK` phase,
or the MRS being mis-received.

### Two things the code says that the hypothesis must account for

These are recorded because they matter and because leaving them out would make
the hypothesis look better than the evidence supports.

**1. The read-capture logic is unchanged since the last known-good RBF.**
`git diff 0997ad8 HEAD -- rtl/mem/sdram.sv` shows `cl_pipe`, `dq_in`, `cap_buf`,
`deliver()`, `ack_stretch`, `CL = 3'd2` and the ACT-skip fast path all
**byte-identical**. The only functional deltas are (a) address-field slicing via
the derived `BANK_HI/ROW_HI/COL_HI` localparams plus `cas_addr()` now driving
`A[11]`, (b) tRFC/refresh parameterisation, (c) simulation-only instrumentation.
The fast path in particular predates the working RBF: `grant_row_hit` and
`state <= ST_RD; // row already open: straight to CAS` are present verbatim in
`git show 0997ad8:rtl/mem/sdram.sv:455-456`.

Nor does that fast path change *when* data returns relative to the READ command:
`cl_pipe[0] <= 1'b1` is set in `ST_RD` (`rtl/mem/sdram.sv:808`) on both the
ACT path (`ST_ACT`→`ST_RCD1`→`ST_RCD2`→`ST_RD`) and the row-hit path
(`ST_IDLE`→`ST_RD`), so the capture offset from CAS is identical either way.
**The "skipping ACT changes when data returns" form of the hypothesis is not
supported by the code**, and should not be carried forward without evidence.

**2. A uniform "N cycles late" does not fit `probe_sig1` either.** The probe
uses port p0, which is a **single-word** read — `rd_total <= 4'd1`
(`rtl/mem/sdram.sv:714`) — with the mode register set to burst 1. A capture N
cycles late on a single-word read returns *nothing* or a neighbouring
transaction's data, not the word 3 columns further along. Getting `0x1F3D6`'s
content out of a burst-1 read at `0x1F3D0` additionally requires either the MRS
not taking effect (leaving a longer default burst on the real part) or the part
streaming past its burst.

**Where that points.** The stronger reading of the same evidence — and it is
still a hypothesis — is that the DQ capture is **marginal rather than off by a
fixed count**: per-byte, per-transaction corruption that sometimes returns the
right byte is what a setup/hold violation on an unconstrained input path looks
like, and it is consistent with identical RTL working in one fit and failing in
another. The SDRAM interface is completely unconstrained (next section), so its
capture margin is a placement lottery and nothing in the flow reports on it.
`rtl/mem/sdram.sv:602-607` claims the read return is covered "under the SDC
input-delay and multicycle constraints" — **`SSV.sdc` contains no such
constraints**, so that comment describes an intention, not the build.

Both forms live in `rtl/mem/sdram.sv`'s read path; they differ in whether the
fix is logical (alignment) or physical (constraints + IOE placement). The
distinguishing experiment is listed under "Recommended next evidence".

---

## Why simulation and STA both missed it

This is the durable lesson, independent of the eventual fix. **Two independent
blind spots, either of which alone would have let this through.**

### 1. STA never analysed the broken path

`SSV.sdc` (62 lines) contains `derive_pll_clocks`,
`derive_clock_uncertainty`, and multicycle exceptions for the V60 and ES5506 CE
domains. **There is not one constraint on the SDRAM interface** — no
`set_input_delay` on `SDRAM_DQ`, no output delay, no false path, nothing. The
fitted report proves it:

```
output_files/Arcade-SSV.sta.rpt:1448   Unconstrained Clocks            0   0
output_files/Arcade-SSV.sta.rpt:1454   Unconstrained Input Ports      21  21
output_files/Arcade-SSV.sta.rpt:1456   Unconstrained Output Ports     89  89
```

Of those 21 unconstrained input ports, **16 are `SDRAM_DQ[0..15]`**, each
reported as "No input delay, min/max delays, false-path exceptions, or max skew
assignments found". The output side is worse: `SDRAM_DQ[0..15]`, `SDRAM_A[0..12]`,
`SDRAM_BA[0..1]`, `SDRAM_CLK`, `SDRAM_DQMH/DQML`, `SDRAM_nCAS/nRAS/nWE` — 53
SDRAM pin entries in the unconstrained lists. The same report says plainly:

```
output_files/build-ssv.out.log:10256   Info (332102): Design is not fully constrained for setup requirements
output_files/build-ssv.out.log:10257   Info (332102): Design is not fully constrained for hold requirements
```

So `report-quartus.ps1` truthfully reports `worst 0.096 ns; TNS 0 ns; met=True;
unconstrained clocks 0` while the read-capture path that is broken was **never
analysed**. `unconstrained clocks 0` is the gate the build checks, and it is
satisfied by a design with 110 unconstrained *ports*. The green light was real
and meaningless.

(Measured worst slacks, minimum across the multicorner models
(`Arcade-SSV.qsf:29`): pure `2b44914` **+0.104 ns** hold
(`output_files/phase0-baseline.log`), CRT-removed **+0.096 ns** hold
(`output_files/nocrt-rbf.log`), painted-probe build **+0.095 ns** hold
(`output_files/dbg-sdram-paint.log`). These are hold slacks on the `pll_hdmi` /
`emu|pll` domains — nothing to do with SDRAM, because SDRAM is not in the
analysis.)

### 2. The chip model is parameterised from the controller's own constants

`verif/ssv_sdram_chip.sv` takes `BANK_BITS` / `ROW_BITS` / `COL_BITS` as
parameters (`verif/ssv_sdram_chip.sv:98-100`) — the *same* values passed to the
controller at `Arcade-SSV.sv:441-442` — and derives its read-return alignment
from `CL` the same way the controller derives its capture
(`verif/ssv_sdram_chip.sv:26-69`). **Model and controller therefore agree by
construction, even when both are wrong about the physical part.**
`verif/tb_ssv_sdram_loopback.sv` passes for that reason, and its pass is a
statement about internal consistency, not about the module on the board. This is
the same class of mistake already recorded in
[`DYNAGEAR_SDRAM_BANDWIDTH.md`](DYNAGEAR_SDRAM_BANDWIDTH.md) — "`overruns bg=0
obj=0` was a statement about that model, not about the memory system" — one
level further down.

**Partial mitigation, stated fairly.** The model does carry a fault injector,
`+sdram_read_skew=N`, which shifts read data N clocks on DQ and exists
specifically "to let `tb_ssv_sdram_loopback` demonstrate that it FAILS when the
read alignment is wrong, so a pass means something"
(`verif/ssv_sdram_chip.sv:194-209`). So the *alignment* dimension is testable
and the loopback's pass is not vacuous along it. What no bench can do is check
the model's latency against the real part's, or check the *physical* capture
margin that has no constraint.

### 3. And nothing in the wrapper is simulated at all

`verif/tb_ssv_frame_crc.sv:193` instantiates `ssv_core` directly. **No bench
elaborates `Arcade-SSV.sv`.** The video chain, the reset gating, the loader
integration and this very probe are outside every gate the project runs — which
is also how the ST010's unconnected ports shipped (`Arcade-SSV.sv:337-343`) and
why `crt_adjust` could be restored with no coverage. A wrapper-level bench is
the structural fix for a whole class of these.

---

## Incidental findings

Recorded here because they were found during this investigation and are real,
but they are **not** this bug.

### 1. Video Fx is unusable — 52x481 instead of ~672x480

With the doubler enabled (`sd_on`, `Arcade-SSV.sv:755`), hardware captures
**52 x 481**. The **481** is correct: vertical doubling of 240 active lines.
The horizontal figure is the collapse — 672 is expected (336 x 2).

52 is `ssv_scandoubler`'s measured `hmax` (`rtl/ssv_scandoubler.sv:95-117`: the
read side wraps at `hmax`, which is latched from the previous line's write
count). It is also exactly the number `docs/PHASE6_LINE_DOUBLER.md:99` records
for a **vblank boundary line**, where one active region legitimately splits
across two lines (measured 52 + 620 = 672). A boundary line's short measurement
becoming the whole frame's line length is a coherent mechanism and the obvious
first hypothesis, but it has **not** been proven. `hmax` is also `'1` until a
full line has been measured (`rtl/ssv_scandoubler.sv:103`), which
`docs/PHASE6_LINE_DOUBLER.md:104-106` lists under "Not addressed", and the same
document's last line says the doubler has still never run on a real 31 kHz
monitor. That check is now done and it failed.

Note: the claim that the module's own comments document a "509 → 19" line-length
collapse could not be substantiated — that string does not appear in
`rtl/ssv_scandoubler.sv`, in `verif/tb_ssv_scandoubler.sv`, in
`docs/PHASE6_LINE_DOUBLER.md`, or anywhere in the file's git history
(`git log --all -S "509" -- rtl/ssv_scandoubler.sv` returns nothing). The 52
figure above is what is actually documented.

### 2. Config-block version trap — pair the RBF with its MRA

The MRA's `<rom index="1">` block carries a version byte
(`rtl/mem/ssv_rom_loader.sv:56-70`). Three behaviours exist in the history:

| RBF | `<rom index="1">` |
|---|---|
| before `c429ba4` | ignored entirely |
| `2b44914` | **requires version 1** |
| current tree | **requires version 2** (byte 12, `samples_mb`) |

Version 1 blocks are *rejected*, not defaulted, on purpose: a v1 block carries 0
in `samples_mb`, and a zero sample size would put the ST010 block on top of the
samples (`rtl/mem/ssv_rom_loader.sv:67-70`). `mra/Dyna Gear.mra:10-12` ships
`53020110110003000404010004000079` — magic `0x53` `'S'`, version `0x02`.

**Deploying a mismatched RBF/MRA pair leaves `cfg_valid` low, index 0 is
discarded, `rom_loaded` never asserts and the screen is black** — with
`LED_USER` lit (`rtl/mem/ssv_rom_loader.sv:72-79`, `Arcade-SSV.sv:304`), which
is the tell that distinguishes it. **This nearly corrupted the bisect**: an old
RBF tested against the current v2 MRA, or `2b44914` against it, is black for
packaging reasons and says nothing about the memory system. Every bisect row
above was run against a config block of the version that RBF requires, and the
table states which.

**Rule: an RBF is only a valid bisect point when paired with a config block of
the version that RBF requires, and `LED_USER` must be OFF before a black screen
counts as evidence.**

---

## Process notes

**Quartus crashed once and a bare retry succeeded.** `quartus_sta` reported
success (`0 errors, 1 warning`) and then the module ended unexpectedly:

```
output_files/build-ssv.out.log:10261   Error (293007): Current module quartus_sta ended unexpectedly.
output_files/build-ssv.out.log:10267   Error: Peak virtual memory: 4680 megabytes
```

That is the same failure mode `Arcade-SSV.qsf:33-44` already records for
`quartus_fit` at **4,649 MB** with 35 GB of host RAM free — a Quartus 17.0.2
Lite per-process ceiling, not system memory. A retry with no changes succeeded.
Successful builds in this investigation peaked at 4,609 MB
(`output_files/phase0-baseline.log`, `nocrt-rbf.log`, `dbg-sdram-paint.log`), so
the margin is a few tens of MB. Do not "fix" this by raising
`NUM_PARALLEL_PROCESSORS` — `Arcade-SSV.qsf:74-79` records that taking it to 4
drove `quartus_fit` to 9,072 MB and killed it.

(Note: the crash text recoverable from the logs is `quartus_sta` at 4,680 MB.
"`quartus_fit` / `Access Violation` at 4,609 MB" could not be corroborated —
`Access Violation` appears nowhere in `output_files/`, only as prior-incident
prose in `Arcade-SSV.qsf:74`. The mechanism is the same either way; the exact
module and figure above are what the log supports.)

**`tools/report-quartus.ps1` never exited 0 on success, and both callers were
wrong because of it.** PowerShell only sets `$LASTEXITCODE` for *native*
executables, so a script that falls off the end leaves whatever value was
already there. `tools/deploy-ssv.ps1:15-16` saw `$null` in a fresh session and
**refused to deploy a perfectly good RBF**. `tools/build-ssv.ps1:110-113` was
the dangerous half: its readiness gate only "passed" because `quartus_sh` had
set 0 earlier in the same session — **that gate would equally have passed a
failing check.** Fixed with an explicit `exit 0` and the reasoning recorded in
place (`tools/report-quartus.ps1:206-215`).

---

## Recommended next evidence

In order of information per unit of build time.

1. **Distinguish logical misalignment from marginal capture, in simulation
   first.** Run `tb_ssv_sdram_loopback` at `COL_BITS=11` with
   `+sdram_read_skew=+1`, `-1` and `+2` (`verif/ssv_sdram_chip.sv:194-209`) and
   record, for each, *which* bytes of a p0 single-word read come back wrong. If
   no skew value reproduces "low byte right, high byte zero", a deterministic
   alignment error is refuted and the cause is physical. This costs one sim run
   and no build.
2. **Constrain the SDRAM interface, then re-read the STA report.** Add
   `set_input_delay` / `set_output_delay` for `SDRAM_DQ`, `SDRAM_A`, `SDRAM_BA`,
   `SDRAM_DQM*` and the command pins against the forwarded `SDRAM_CLK`, and see
   whether the read capture path closes. **If it does not close, that is the
   answer** — and it converts an invisible failure into a build-time one for
   every future fit. `SSV.sdc` is owned elsewhere; this issue only recommends
   it. (`sys/` remains off-limits — `CLAUDE.md`.)
3. **Widen the painted probe.** It currently shows 3 of the 4 available bytes.
   Paint `probe_sig1[7:0]` too (a second region of the screen, or a second build)
   so both words are fully visible; the low byte of `probe_sig1` is currently
   unknown and would immediately show whether `probe_sig1` is displaced as a
   whole word or corrupted per byte.
4. **Probe more addresses, including a p1/p2 burst.** Two samples cannot
   distinguish "every read is wrong" from "reads are wrong depending on row
   state". Add probes in the same row, in a different row of the same bank, and
   in a different bank; and add one multi-word burst, since every graphics fetch
   is one and the probe currently only exercises single-word p0.
5. **Sweep `SEED`.** If identical RTL renders on some seeds and not others, the
   cause is a placement-dependent margin and item 2 is mandatory rather than
   advisable. `Arcade-SSV.qsf:31-37` already documents ±0.4 ns of placement
   lottery on this design.
6. **Build a wrapper-level testbench that elaborates `Arcade-SSV.sv`.** The
   structural fix for blind spot 3. It would have caught the ST010's unconnected
   ports and would cover the probe, the reset gating and the video chain.

---

## Report block

Per `docs/CORE_ISSUE_DIFFTEST_METHOD.md` §8:

```text
Issue:                    Black screen on real hardware; correctly timed 336x240 raster,
                          zero picture content. Dyna Gear, SSV core.
Deterministic scenario:   deploy-mister.ps1 -Boot with Dyna Gear.mra (v2 config block);
                          `echo screenshot > /dev/MiSTer_cmd`; read
                          /media/fat/screenshots/dynagear/*.png with PIL.
Last matching event:      Commit 0997ad8 renders the title screen on hardware (42,317 B PNG).
First divergence:         Somewhere in c429ba4..2b44914; pure 2b44914 is black (1,151 B PNG).
                          Not in the uncommitted work.
Root-cause hypothesis:    The SDRAM controller captures DQ on the wrong cycle. Suspect
                          rtl/mem/sdram.sv read path (cl_pipe / dq_in / cap_buf / deliver),
                          in either a logical-alignment or a marginal-timing form.
                          NOT PROVEN.
Evidence tier:            OBSERVED for symptom and probe readback; UNKNOWN for cause.
RTL change:               None. crt_adjust removal (files.qip:34, Arcade-SSV.sv:685-701) and
                          DBG_SDRAM_PAINT (Arcade-SSV.sv:703-746) are bisect instrumentation
                          and must be reverted when this closes.
Focused regression:       Not yet written. See "Recommended next evidence" item 1.
Subsystem/full regression: tb_ssv_frame_crc attract_idle 119/120 vs MAME 0.288, unaffected.
Fresh MAME-to-RTL result: Unchanged; simulation never reproduced this.
Quartus timing/result:    Builds pass the project's own gate (worst +0.095..+0.104 ns hold,
                          TNS 0, met=True, unconstrained clocks 0) -- and that gate does not
                          analyse the SDRAM interface at all.
MiSTer result:            BLACK. Painted probe reads RGB (00,7A,35) on 100% of 80,640 pixels;
                          expected (20,7A,0C).
What this explains:       Why the screen is black with a correct raster (the V60 executes
                          corrupt program words) and why no bench or STA run caught it.
What this does not explain: Which of the two hypothesis forms is right; why probe_sig0 and
                          probe_sig1 are corrupted differently; how a burst-1 p0 read
                          returned data from +3 words.
Artifacts:                output_files/{phase0-baseline,nocrt-rbf,dbg-sdram-paint}.log;
                          output_files/Arcade-SSV.sta.rpt:1448-1600;
                          hardware PNGs (not committed -- see CLAUDE.md git hygiene).
```

---

## Exit gate

This issue closes only when **all** of the following hold:

1. **The painted probe reads exactly `20 7A 0C`** — i.e. RGB (0x20, 0x7A, 0x0C)
   across the full 80,640-pixel frame, from a `+define+DBG_SDRAM_PAINT` build on
   real hardware, decoded with a real PNG decoder. Equivalently, `rom_sig_ok`
   asserts (`Arcade-SSV.sv:387`). Anything else is still a corrupt read.
2. **The attract frame CRC still matches** — `tb_ssv_frame_crc` on
   `attract_idle` at ≥120 frames, still 119/120 against
   `sim_output/diff/mame_attract_idle_frames.crc`, with frame 1 as the only
   residual and its own issue still tracking it
   ([`DYNAGEAR_ATTRACT_FRAME_CRC.md`](DYNAGEAR_ATTRACT_FRAME_CRC.md)). A fix
   that repairs hardware and moves a simulation CRC has changed something else
   as well.
3. **Dyna Gear renders on hardware without the paint define** — a title-screen
   screenshot in the ~42 KB range, matching the `0997ad8` baseline, plus attract
   running.
4. **A regression exists that was observed to fail before the fix**, per
   `docs/CORE_ISSUE_DIFFTEST_METHOD.md` §5. If the cause turns out to be
   physical, the SDC constraints are that regression and it must be demonstrated
   that STA reports negative slack on the unfixed design.
5. **The bisect instrumentation is gone** — `DBG_SDRAM_PAINT`
   (`Arcade-SSV.sv:703-746`) removed, and `rtl/crt_adjust.sv` either restored to
   `files.qip` **with a wrapper-level bench** or deliberately dropped and
   recorded as such. Per `CLAUDE.md`, a rejected hypothesis is reverted, not left
   behind a disabled flag.

Until item 1 passes, **no claim that this is fixed is admissible.** The read
returns wrong data today; that is the only fact the fix has to change.
