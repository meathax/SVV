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

These sources are GPLv3 and the repository retains the upstream `LICENSE`.
New SSV-specific RTL is also distributed under GPL-3.0-or-later.

MAME source is used as behavioral documentation. No MAME source is copied into
the synthesizable core.
