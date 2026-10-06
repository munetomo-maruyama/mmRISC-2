#---------------------------------------------------------------------------
# synth_l2.tcl : CPU_L2 alone in Vivado, out of context
#                (Artix-7 xc7a100tcsg324-1, the part of the Arty A7-100T)
#
#   cd FPGA/L2_OOC
#   vivado -mode batch -source synth_l2.tcl -tclargs [size [ways [random [period [impl]]]]]
#
#     size    L2 bytes                       262144 (256 KB)
#     ways                                   4
#     random  1 = random replacement         0 (pseudo LRU)
#     period  clock period in ns             20.0 (50 MHz, the system clock)
#     impl    1 = also place and route       1
#
# Outputs in ./output/L2_<KB>K_<ways>w[_rnd]/ :
#   utilization_synth.rpt / utilization.rpt  (hierarchical, by module)
#   ram_utilization.rpt                      the arrays: block RAM or LUT RAM
#   timing_summary.rpt, timing_paths.rpt     after routing (impl = 1)
#   summary.txt                              the numbers in one place
#
# The AXI ports have no I/O pins out of context. Each side is given 30 % of
# the period as input and output delay, a rough budget for the logic of
# CPU_CACHE and LiteX around the L2; a path from an input straight to an
# output (AXI ready / valid passed through) then has 40 % of the period.
#---------------------------------------------------------------------------

set part   xc7a100tcsg324-1
set rtl    ../../RTL

set size   [expr {[llength $argv] > 0 ? [lindex $argv 0] : 262144}]
set ways   [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]
set rnd    [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0}]
set period [expr {[llength $argv] > 3 ? [lindex $argv 3] : 20.0}]
set impl   [expr {[llength $argv] > 4 ? [lindex $argv 4] : 1}]

set tag    "L2_[expr {$size / 1024}]K_${ways}w[expr {$rnd ? {_rnd} : {}}]"
set outdir ./output/$tag
file mkdir $outdir
puts "INFO: $tag, clock period $period ns, place and route: $impl"

set_part $part
read_verilog -sv [list \
    $rtl/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
    $rtl/CPU/CPU_L2/L2_TAG_ARRAY.sv \
    $rtl/CPU/CPU_L2/CPU_L2.sv \
]

synth_design -top CPU_L2 -part $part -mode out_of_context \
    -generic SIZE_BYTES=$size -generic WAYS=$ways -generic REPLACE_RANDOM=$rnd

create_clock -name clk -period $period [get_ports clk]
set io_dly [expr {0.3 * $period}]
set ins  [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}]
set outs [get_ports -filter {DIRECTION == OUT}]
set_input_delay  -clock clk $io_dly $ins
set_output_delay -clock clk $io_dly $outs
# rst_n comes from a reset synchronizer on the same clock (asynchronous
# assertion, synchronous release)
set_input_delay  -clock clk $io_dly [get_ports rst_n]

write_checkpoint -force $outdir/post_synth.dcp
report_utilization -hierarchical -file $outdir/utilization_synth.rpt
catch {report_ram_utilization -file $outdir/ram_utilization.rpt}

#---------------------------------------------------------------------------
# what the arrays became
#---------------------------------------------------------------------------
proc count {filter} { return [llength [get_cells -quiet -hier -filter $filter]] }
set n_ff    [count {PRIMITIVE_GROUP == FLOP_LATCH}]
set n_lut   [count {PRIMITIVE_GROUP == LUT}]
set n_b36   [count {REF_NAME =~ RAMB36*}]
set n_b18   [count {REF_NAME =~ RAMB18*}]
set n_lram  [count {REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* || REF_NAME =~ RAM256*}]
set n_tagb  [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* && NAME =~ *u_tag*}]]
set n_datb  [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* && NAME =~ *u_dat*}]]
set synth_msg [format "after synthesis: %d LUT, %d FF, RAMB36 %d, RAMB18 %d (tag %d, data %d primitives), LUT RAM cells %d" \
                   $n_lut $n_ff $n_b36 $n_b18 $n_tagb $n_datb $n_lram]
puts "INFO: $synth_msg"
# the arrays in flip-flops would be hundreds of thousands of them
if {$n_ff > 20000} {
    error "too many flip-flops ($n_ff): the L2 arrays were not inferred as RAM\
           (look for 'RAM template' of CACHE_DATA_ARRAY / L2_TAG_ARRAY in the log)"
}

set fh [open $outdir/summary.txt w]
puts $fh "$tag  (period $period ns, I/O delay $io_dly ns each side)"
puts $fh $synth_msg

#---------------------------------------------------------------------------
# place and route, out of context
#---------------------------------------------------------------------------
if {$impl} {
    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force $outdir/post_route.dcp
    report_utilization -hierarchical -file $outdir/utilization.rpt
    report_timing_summary -file $outdir/timing_summary.rpt
    report_timing -max_paths 20 -nworst 1 -path_type full -file $outdir/timing_paths.rpt
    # register to register only (the paths that do not depend on the I/O budget)
    report_timing -max_paths 10 -nworst 1 -from [all_registers] -to [all_registers] \
        -file $outdir/timing_reg2reg.rpt
    set wns   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    set r2r   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup \
                                       -from [all_registers] -to [all_registers]]]
    # slices of the L2 alone; in the full design its logic shares slices
    # with its neighbours, so this is only a rough figure of what it adds
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
