# SSV MiSTer timing constraints.
create_clock -name CLK_50M -period 20.000 [get_ports {CLK_50M}]
derive_pll_clocks
derive_clock_uncertainty

# HPS and front-panel controls are asynchronous to the FPGA core clocks and
# are synchronised by the MiSTer framework / local reset synchronisers.
set_false_path -from [get_ports {RESET}]
set_false_path -from [get_ports {HPS_BUS[*]}]

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
