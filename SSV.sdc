# SSV MiSTer core timing constraints.
# Board clocks (FPGA_CLK*_50, HPS user clocks) are created in sys/sys_top.sdc.
# Do not invent a CLK_50M / RESET / HPS_BUS top-level here — the compiled
# entity is sys_top, and those emu-wrapper names do not exist as ports.

derive_pll_clocks
derive_clock_uncertainty

# The V60 is clock-enabled at approximately 16.1 MHz from clk_sys.  The
# accumulator ratio guarantees at least three clk_sys periods between enable
# pulses, and every V60 state register is updated by the same `ce` branch.
# Constrain only register-to-register paths wholly inside that instance.
set v60_registers [get_registers {*|s32_v60:cpu|*}]
set v60_registers [add_to_collection $v60_registers \
    [get_registers {*|s32_v60_bus:bus_adapter|*}]]
set_multicycle_path -setup 3 \
    -from $v60_registers -to $v60_registers
set_multicycle_path -hold 2 \
    -from $v60_registers -to $v60_registers
