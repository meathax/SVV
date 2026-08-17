# Imported source provenance

The following files were copied from the adjacent Sega System 32 MiSTer core
at `D:\Arcade\AI\s32` on 2026-07-23:

- `sys/`: MiSTer framework integration files.
- `rtl/cpu/v60/`: NEC V60 CPU and 16-bit external-bus adapter.
- `rtl/mem/sdram.sv`: six-port MiSTer SDRAM controller.
- `rtl/pll/`: the 96.6/48.3 MHz PLL used by that core.
- `rtl/common/s32_big_dpram.sv`: generic dual-port RAM helper.
- `verif/v60/` and `verif/cosim/`: V60 regressions and MAME differential tools.
- selected build, timing-report, and MiSTer deployment scripts in `tools/`.

## V60 refresh (2026-07-24)

`rtl/cpu/v60/s32_v60.sv` and the matching Verilator unit tests were refreshed
from s32 commit `ef8e1017d7a0857ced16da181ce0c97d6274eb65` to pick up the
authentic instruction-prefetch unit (PFU), data/prefetch bus arbiter, optional
`FAST_IFETCH` wide instruction port, and SMC/fetch regressions.

SSV instantiates the CPU with `FAST_IFETCH=1` by default (`FAST_IFETCH_EN`) and
serves the wide `if_*` port from a 32×8B direct-mapped program ROM icache in
`rtl/ssv_core.sv` (ported from `s32_core.sv`). SDRAM `p0` is shared between
icache line fills and XRAM/Dyna RAM; fills take priority. Override with
`+define+FAST_IFETCH_EN=1'b0` to A/B-test the legacy ce-gated adapter fetch.

On 2026-08-17, the V60 bus adapter handshake was adapted from s32 commit
`93776de9d6afce036ce71d277005bcad15ed16c7`. The SVV copy retains its existing
lane assembly and physical-cycle datapath, while adopting the donor's
raw-clock request re-arm and request-held completion acknowledgement. The
simulation-only reset assertion is guarded with `SIMULATION` because Quartus
17.0.2 does not define `SYNTHESIS` in this flow.

On 2026-08-17, the V60 execute-retire overlap was adapted from s32 commit
`8012041d2e2a8d75fc6df64334c86482db92f45d`. Only the evidence-backed
register-only opcode allowlists, fetch-window handoff, and stale-prefetch
guard were ported; s32's different runtime fast-ifetch map and loop-hint
implementation were not copied.

On 2026-08-18, the V60 RSR control-transfer flush was adapted from s32 commit
`f18618b64eac079a3a79690aabf94d91e0ec3fcd`. The SVV copy now invalidates the
live and retained prefetch windows when RSR loads a new PC, advances the
prefetch epoch, clears loop suppression, and rejects a coincident old-stream
acknowledgement. The existing SVV RSR data-pop and fetch-window interfaces are
otherwise unchanged.

These sources are GPLv3 and the repository retains the upstream `LICENSE`.
New SSV-specific RTL is also distributed under GPL-3.0-or-later.

MAME source is used as behavioral documentation. No MAME source is copied into
the synthesizable core.

## MiSTer framework deviation ledger

`sys/` began as the adjacent S32 framework import. It is not currently
byte-identical to that source. The following committed deviations must be
treated as an isolated patch stack—not as permission for further framework
edits:

- `5eb1f5b`: `sys/ascal.vhd` pipeline/counter/resource changes and
  `sys/sys_top.sdc` constraint corrections made for the 148.5 MHz scaler path;
- `c75139e`: `sys/ascal.vhd` input FIFO MLAB steering and `sys/sys_top.v`
  SSV-specific scaler/palette parameters;
- imported/generated metadata differences in `pll_audio*.qip`,
  `pll_hdmi*.qip`, and the `HDMI_TX_CLK` fast-output assignment in `sys.tcl`.

The ascal changes were previously accompanied by focused video regressions and
timing reports recorded in the named commits and `docs/OPTIMIZATION_PRE_RBF.md`.
They are retained because blindly restoring the adjacent copy would undo known
resource/timing work and change the video pipeline. Any future upstream refresh
must first reproduce those behavioral checks, then obtain fresh Quartus and
real-MiSTer evidence. Generated PLL submodules and their reconfiguration wiring
remain read-only.
