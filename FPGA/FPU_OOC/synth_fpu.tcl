#---------------------------------------------------------------------------
# synth_fpu.tcl : an FPU alone in Vivado, out of context
#                 (Artix-7 xc7a100tcsg324-1, the part of the Arty A7-100T)
#
#   cd FPGA/FPU_OOC
#   vivado -mode batch -source synth_fpu.tcl -tclargs [top [period [impl]]]
#
#     top     FPU_PIPE (the pipelined unit, ROADMAP C2) or CORE_FPU (the
#             unit the core has now)                     FPU_PIPE
#     period  clock period in ns                         20.0 (50 MHz)
#     impl    1 = also place and route                   1
#
# Outputs in ./output/<top>/ : utilization_synth.rpt / utilization.rpt,
# timing_summary.rpt, timing_reg2reg.rpt, summary.txt (the numbers in one
# place). Run it for both tops to see what the pipelining costs.
#
# The ports have no I/O pins out of context; each side is given 30 % of
# the period as input and output delay. In the core the operands come
# through the forwarding multiplexers of EX, so the input side is the one
# to watch (CORE_FPU copies them in its first cycle for that reason, and
# FPU_PIPE does the same in P0).
#---------------------------------------------------------------------------

set part   xc7a100tcsg324-1
set rtl    ../../RTL

set top    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "FPU_PIPE"}]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20.0}]
set impl   [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]

set outdir ./output/$top
file mkdir $outdir
puts "INFO: $top, clock period $period ns, place and route: $impl"

set_part $part
set srcs [list $rtl/CPU/CPU_FPU/FPU_ROUND/FPU_ROUND.sv]
if {$top eq "CORE_FPU"} {
    lappend srcs $rtl/CPU/CPU_FPU/CORE_FPU/CORE_FPU.sv
} else {
    lappend srcs $rtl/CPU/CPU_FPU/FPU_PIPE/FPU_PIPE.sv
}
read_verilog -sv $srcs

synth_design -top $top -part $part -mode out_of_context

create_clock -name clk -period $period [get_ports clk]
set io_dly [expr {0.3 * $period}]
set_input_delay  -clock clk $io_dly [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk $io_dly [get_ports -filter {DIRECTION == OUT}]

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -hierarchical -file $outdir/utilization_synth.rpt

proc count {filter} { return [llength [get_cells -quiet -hier -filter $filter]] }
set n_lut  [count {PRIMITIVE_GROUP == LUT}]
set n_ff   [count {PRIMITIVE_GROUP == FLOP_LATCH}]
set n_dsp  [count {REF_NAME =~ DSP48*}]
set n_lram [count {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ SRL*}]
set synth_msg [format "after synthesis: %d LUT, %d FF, %d DSP, %d LUT RAM / SRL cells" \
                   $n_lut $n_ff $n_dsp $n_lram]
puts "INFO: $synth_msg"

set fh [open $outdir/summary.txt w]
puts $fh "$top  (period $period ns, I/O delay $io_dly ns each side)"
puts $fh $synth_msg

if {$impl} {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force $outdir/post_route.dcp
    report_utilization -hierarchical -file $outdir/utilization.rpt
    report_timing_summary -file $outdir/timing_summary.rpt
    report_timing -max_paths 10 -nworst 1 -path_type full -from [all_registers] -to [all_registers] \
        -file $outdir/timing_reg2reg.rpt
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    set r2r [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup \
                                     -from [all_registers] -to [all_registers]]]
    if {[catch {
        set n_slc [llength [get_sites -quiet -filter {SITE_TYPE =~ SLICE*} \
                                -of_objects [get_cells -hier -filter {IS_PRIMITIVE}]]]
    }]} { set n_slc -1 }
    set msg [format "after routing: WNS %s ns (register to register %s ns), WHS %s ns, %d slices" \
                 $wns $r2r $whs $n_slc]
    puts "INFO: $msg"
    puts $fh $msg
}
close $fh
puts "INFO: done, see $outdir/summary.txt"
