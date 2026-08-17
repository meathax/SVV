# Issue contract: controller built for a part the board does not have

## Issue

**Symptom (real MiSTer hardware).** Dyna Gear boots to a blank screen with no
sound. The V60 never retires an instruction past its reset vector. An on-board
probe that reads two known program words back out of SDRAM returns `0x007A`
where `0x207A` was written, and `0x35..` where `0x0C7A` was written — the LOW
byte of the first word survives, the HIGH byte does not.

**Why a "green screen" was reported.** The build carried `DBG_SDRAM_PAINT`,
which paints that probe result across the whole frame. `#007a35` is
`(sig0[15:8], sig0[7:0], sig1[15:8])` = `(00,7A,35)`. The green was the
instrument, never a picture.

**Status:** `CONFIRMED` in simulation. Evidence tier: `OBSERVED` for the
hardware symptom; the mechanism is reproduced deterministically by
`verif/tb_ssv_sdram_module_contract.sv`.

## Root cause

Commit `c429ba4` rebuilt `rtl/mem/sdram.sv` for a single monolithic 64Mx16 SDRAM
with free-standing DQM pins and `nCS` folded into a 4-bit command encoding.

**That part is not what is fitted.** The MiSTer 128 MB module is:

* **TWO 32Mx16 devices**, with `SDRAM_nCS` as the **device selector**, not a
  command bit.
* **DQML/DQMH SHORTED to A11/A12** on the module. The byte mask is whatever the
  address bus carries; the pins are not independently drivable.
* **4 banks x 8192 rows x 1024 columns per device.** There is no eleventh
  column bit, and nothing addressable may sit on A11.

Sources: `rtl/mem/sdram.sv` of the Sega System 32 core
(`D:\Arcade\AI\S32MULTIONLY`), which runs on this same board and from which
SSV's controller was originally ported, citing `Arcade-IremM92_MiSTer`
`rtl/sdram.sv:69` and `jtframe_sdram_bank_core.v:140` — *"This is a limitation
in MiSTer's 128MB module"*.

Three consequences, in decreasing order of certainty:

1. **Device 1 never received MRS.** Init ran once with no device select, so the
   upper 64 MB — the ST010 region and the **ES5506 samples** — was uninitialised
   and unreachable. That is the missing audio. (Measured: `mrs1=0`.)
2. **The mode registers were programmed through a bus fight.** Throughout init
   the controller held its DQM pins at `2'b11` while `A[12:11]` carried `00` —
   two FPGA outputs driving opposite levels into one shorted net, DURING the MRS
   command whose `A[12:11]` are mode bits. What a chip latches from a fought,
   mid-rail net is undefined; stable-but-wrong data everywhere afterwards is a
   permitted outcome and matches the hardware probe. This is the surviving
   explanation for the corruption at the probe addresses — measured as
   `dqm_fights=65555`, which is the init length exactly.
3. **Writes to any cell with column bit 10 set are byte-masked** (the col bit
   rides A11 = DQML) and rows with bits 13:12 set fight the net during ACT.
   Real, measured in the module bench — but NOT the mechanism at the probe
   addresses, whose column-10 bit is 0. An earlier draft of this document
   claimed it was; that was wrong, and the correction matters because it
   changes what a fixed build must prove: the fix is removing the fight
   entirely, not just re-routing one column bit.

## Why no simulation caught it

`verif/ssv_sdram_chip.sv` models the imaginary monolithic part, and every bench
instantiated it. The whole suite — including `tb_ssv_frame_crc` matching MAME on
39/39 attract frames — was grading the controller against hardware that does not
exist.

This is the same class of blind spot already recorded in
`rtl/common/s32_big_dpram.sv:44` — *"which is exactly why every bench passed
while hardware showed corruption"*.

## Two hypotheses this supersedes, both refuted

Recorded because both looked strong and cost real time:

* **SDRAM read-capture clock phase.** The theory was that `cl_pipe[3]` was one
  cycle late for the board's 180-degree forwarded `SDRAM_CLK`. Refuted on
  hardware: `cl_pipe[2]` returned **byte-identical** wrong data. The proven S32
  controller uses tap 3. Modelling the 180-degree relationship by inverting the
  part's clock in a zero-delay simulation is also wrong — it merely shifts which
  cycle the part samples, and it makes the proven controller fail. That
  relationship is a setup/hold property belonging to STA and the SDC, not to a
  behavioural model.
* **Module size / column aliasing.** A 32 MB part under an 11-column controller
  gives a dead CPU at `pc=00000000`, not this symptom, and the board does carry
  128 MB.

## Fix

`rtl/mem/sdram.sv` is the System 32 controller, which encodes the module
contract. Geometry is **not** parameterised — making it configurable is how a
controller for the wrong part came to be built and shipped:

```
a[26]    device select -> SDRAM_nCS
a[25]    column bit 9
a[24:23] bank
a[22:10] row (13 bits)
a[9:1]   column bits 8:0

READ  CAS: A[12:11] = 00    (unmasked)
WRITE CAS: A[12:11] = ~be   (mask travels on the address bus)
PRE:       A = 13'h0400     (A10=1 all banks, A[12:11]=00)
init:      PRE / 8x REF / MRS for BOTH devices
```

## Regression

`verif/ssv_sdram_module.sv` models the module as built and is loud: it fails on
a controller that drives DQM against the A11/A12 short, or that touches a device
which never received MRS. `verif/ssv_sdram_harness.sv` now instantiates it, so
every bench grades against the real board.

Observed fail-first, which is the acceptance condition in CLAUDE.md:

| bench | before the fix | after |
|---|---|---|
| `tb_ssv_sdram_module_contract` | `errors=5`, `dqm_fights=65555`, `mrs1=0` | `errors=0`, `dqm_fights=0`, `mrs0=1 mrs1=1` |
| `tb_ssv_loader_image` (real ROM through the real loader) | — | 4098/4098 words exact |

## Known follow-up

The region map in `ssv_pkg.sv` was laid out for the previous, fictitious
decomposition. Under the real one `a[25]` is the column MSB rather than a bank
bit, so the intended bank separation between the CPU and graphics regions no
longer holds. That is a bandwidth question, not correctness, and it invalidates
the row-conflict figures in `docs/PHASE0_MEASUREMENT.md`.

## Exit gate

Fresh Quartus build with `DBG_SDRAM_PAINT` REMOVED,
`tools/report-quartus.ps1 -RequireReady`, hash-verified deploy, and a hardware
screenshot showing Dyna Gear attract mode.
