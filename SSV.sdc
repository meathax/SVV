# SSV MiSTer timing constraints.
create_clock -name CLK_50M -period 20.000 [get_ports {CLK_50M}]
derive_pll_clocks
derive_clock_uncertainty

# HPS and front-panel controls are asynchronous to the FPGA core clocks and
# are synchronised by the MiSTer framework / local reset synchronisers.
set_false_path -from [get_ports {RESET}]
set_false_path -from [get_ports {HPS_BUS[*]}]
