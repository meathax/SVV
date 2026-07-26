project_open Arcade-SSV
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 5 -detail full_path -file output_files/worst_setup.txt
report_clocks -file output_files/clocks.txt
project_close
