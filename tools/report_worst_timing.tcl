project_open Arcade-SSV
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -npaths 20 -nworst 5 -detail full_path -show_routing -file output_files/worst_setup.txt
report_clocks -file output_files/clocks.txt
project_close
