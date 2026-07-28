project_open Arcade-SSV
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -npaths 20 -nworst 5 -detail full_path -show_routing -file output_files/worst_setup.txt

# The global worst list is dominated by whichever domain is currently failing,
# which hides how much margin the core itself has. Report each domain that the
# core actually lives in so a regression there is visible before it fails.
set core_clocks {
    {clk_sys  {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}}
    {clk_ram  {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}}
    {hdmi_pix {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}}
}
foreach entry $core_clocks {
    set label [lindex $entry 0]
    set clk   [lindex $entry 1]
    report_timing -setup -npaths 10 -nworst 3 -detail path_only \
        -to_clock [get_clocks $clk] \
        -file output_files/worst_setup_$label.txt
}

report_clocks -file output_files/clocks.txt
project_close
