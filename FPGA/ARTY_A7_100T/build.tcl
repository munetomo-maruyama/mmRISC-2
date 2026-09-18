#---------------------------------------------------------------------------
# build.tcl : Vivado non-project batch build of RTL/TOP/TOP.sv
#             (Digilent Arty A7-100T, xc7a100tcsg324-1)
#
#   cd FPGA/ARTY_A7_100T
#   vivado -mode batch -source build.tcl
#
# Outputs (in ./output):
#   TOP.bit  : bitstream (Hardware Manager, volatile)
#   TOP.bin  : SPI flash image (Configuration Memory, s25fl128sxxxxxx0-spi-x1_x2_x4)
#   *.rpt    : utilization / timing / CDC reports
#---------------------------------------------------------------------------

set part   xc7a100tcsg324-1
set rtl    ../../RTL
set outdir ./output
file mkdir $outdir

set_part $part

read_verilog -sv [list \
    $rtl/CPU_DBG/DBG_CDC/DBG_CDC.sv \
    $rtl/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv \
    $rtl/CPU_DBG/DBG_DTM/DBG_DTM.sv \
    $rtl/CPU_DBG/DBG_DM/DBG_DM.sv \
    $rtl/CPU_DBG/DBG_HART_STUB/DBG_HART_STUB.sv \
    $rtl/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv \
    $rtl/CPU_DBG/CPU_DBG/CPU_DBG.sv \
    $rtl/BUS/BUS_ARB/BUS_ARB.sv \
    $rtl/BUS/AXI4_ADDR_NARROW/AXI4_ADDR_NARROW.sv \
    $rtl/BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv \
    $rtl/BUS/AXI4_RAM/AXI4_RAM.sv \
    $rtl/BUS/AXIL_RAM/AXIL_RAM.sv \
    $rtl/CPU/CPU_BFM/CPU_BFM.sv \
    $rtl/CPU/CPU_TOP/CPU_TOP.sv \
    $rtl/TOP/TOP.sv \
]
read_xdc TOP.xdc

synth_design -top TOP -part $part -generic SIM=0 -generic USE_BFM=0
read_xdc TOP_impl.xdc
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/utilization_synth.rpt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $outdir/post_route.dcp

report_utilization    -file $outdir/utilization.rpt
report_timing_summary -file $outdir/timing_summary.rpt
report_cdc -details    -file $outdir/cdc.rpt
report_clock_interaction -file $outdir/clock_interaction.rpt
report_methodology    -file $outdir/methodology.rpt
report_drc            -file $outdir/drc.rpt

write_bitstream -force $outdir/TOP.bit
write_cfgmem -force -format bin -interface spix4 -size 16 \
    -loadbit "up 0x0 $outdir/TOP.bit" -file $outdir/TOP.bin

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "INFO: build finished, worst setup slack = $wns ns"
