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

`rtl/cpu/v60/s32_v60_bus.sv` was already identical to s32 and was not changed.

These sources are GPLv3 and the repository retains the upstream `LICENSE`.
New SSV-specific RTL is also distributed under GPL-3.0-or-later.

MAME source is used as behavioral documentation. No MAME source is copied into
the synthesizable core.
