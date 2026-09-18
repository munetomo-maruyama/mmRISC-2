#---------------------------------------------------------------------------
# TOP.xdc : mmRISC-2 debug bring-up on Digilent Arty A7-100T
#---------------------------------------------------------------------------

#----------------------------------------------------------------
# Clock / reset
#----------------------------------------------------------------
set_property -dict {PACKAGE_PIN E3  IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
set_property -dict {PACKAGE_PIN C2  IOSTANDARD LVCMOS33} [get_ports CPU_RESETN]
create_clock -name clk100 -period 10.000 [get_ports CLK100MHZ]

#----------------------------------------------------------------
# Switches / LEDs
#----------------------------------------------------------------
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports SW2]      ;# auth enable
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports SW3]      ;# cJTAG enable
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {LED[4]}] ;# LD4 halted
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {LED[5]}] ;# LD5 running
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {LED[6]}] ;# LD6 dmactive
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {LED[7]}] ;# LD7 cJTAG online / heartbeat

#----------------------------------------------------------------
# PMOD JA : JTAG / cJTAG
#   JA1 TCK/TCKC  JA2 TDI  JA3 TDO  JA4 TMS/TMSC  JA7 nTRST  JA8 nSRST
#   FPGA internal pull-up on all JTAG / cJTAG pins except JA4.
#   JA4 (TMS in JTAG, TMSC in cJTAG) has no pull-up: TMSC is driven
#   alternately by the host and the target, and a bus keeper holds the last
#   driven level while both are released (OScan1 TDO phase hand-over).
#   A pin can have only one of PULLUP / PULLDOWN / KEEPER.
#----------------------------------------------------------------
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TCK]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TDI]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TDO]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33 KEEPER TRUE} [get_ports JA_TMS]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TRSTN]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_SRSTN]

# TCK/TCKC and TMSC (escape detector) are clocks on general purpose pins
create_clock -name jtag_tck  -period 100.000 [get_ports JA_TCK]
create_clock -name jtag_tmsc -period 100.000 [get_ports JA_TMS]
# CLOCK_DEDICATED_ROUTE FALSE is set in TOP_impl.xdc (applied after synthesis,
# when the input buffer nets exist)

# Fully asynchronous clock domains (CDC is handled by the design)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk100] \
    -group [get_clocks jtag_tck] \
    -group [get_clocks jtag_tmsc]

# Low-speed board / debug I/O
set_false_path -from [get_ports {CPU_RESETN SW2 SW3 JA_TRSTN JA_SRSTN}]
set_false_path -to   [get_ports {LED[*]}]
set_false_path -from [get_ports {JA_TDI JA_TMS}]
set_false_path -to   [get_ports {JA_TDO JA_TMS}]

#----------------------------------------------------------------
# Configuration
#----------------------------------------------------------------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
