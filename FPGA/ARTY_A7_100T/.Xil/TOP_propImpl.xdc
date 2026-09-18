set_property SRC_FILE_INFO {cfile:Z:/Documents/CQ/RISCV/mmRISC/mmRISC-2/FPGA/ARTY_A7_100T/TOP.xdc rfile:../TOP.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:8 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN E3  IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
set_property src_info {type:XDC file:1 line:9 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN C2  IOSTANDARD LVCMOS33} [get_ports CPU_RESETN]
set_property src_info {type:XDC file:1 line:15 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports SW2]      ;# auth enable
set_property src_info {type:XDC file:1 line:16 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports SW3]      ;# cJTAG enable
set_property src_info {type:XDC file:1 line:17 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {LED[4]}] ;# LD4 halted
set_property src_info {type:XDC file:1 line:18 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {LED[5]}] ;# LD5 running
set_property src_info {type:XDC file:1 line:19 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {LED[6]}] ;# LD6 dmactive
set_property src_info {type:XDC file:1 line:20 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {LED[7]}] ;# LD7 cJTAG online / heartbeat
set_property src_info {type:XDC file:1 line:31 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TCK]
set_property src_info {type:XDC file:1 line:32 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TDI]
set_property src_info {type:XDC file:1 line:33 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TDO]
set_property src_info {type:XDC file:1 line:34 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33 KEEPER TRUE} [get_ports JA_TMS]
set_property src_info {type:XDC file:1 line:35 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_TRSTN]
set_property src_info {type:XDC file:1 line:36 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports JA_SRSTN]
