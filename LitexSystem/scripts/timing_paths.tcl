# timing_paths.tcl : more of the worst paths than the build's own report
#
# The build writes only the ten worst paths of each clock
# (digilent_arty_timing.rpt), which says little about how many paths sit
# just above them. This opens the routed design the build left behind and
# lists the worst 300 endpoints of the CPU clock (one path each), then the
# 40 worst in detail. Nothing is rebuilt; it takes a minute or two.
#
#   vivado -mode batch -source timing_paths.tcl     (in build\gateware)
#
# Output: digilent_arty_paths.rpt next to the design.

open_checkpoint digilent_arty_route.dcp
set clk [get_clocks main_clkout0]
report_timing -setup -group $clk -max_paths 300 -nworst 1 -sort_by slack \
    -path_type summary -file digilent_arty_paths.rpt
report_timing -setup -group $clk -max_paths 40 -nworst 1 -sort_by slack \
    -input_pins -file digilent_arty_paths.rpt -append
