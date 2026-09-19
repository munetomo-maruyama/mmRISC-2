#---------------------------------------------------------------------------
# Makefile : CPU_TOP bus verification
#
#   make            : run with Verilator (default simulator)
#   make wave       : run with Verilator and dump tb_CPU_TOP.vcd
#   make gtkwave    : run with Verilator, then open GTKWave
#   make iverilog   : run with Icarus Verilog
#   make iverilog-wave : run with Icarus Verilog and dump tb_CPU_TOP.vcd
#   make gtkwave-iv : run with Icarus Verilog, then open GTKWave
#   make clean      : remove generated files
#
# GTKWave save files (signal order / formatting):
#   tb_CPU_TOP.gtkw          : for the Verilator VCD  (scope TOP.tb_CPU_TOP.*)
#   tb_CPU_TOP_iverilog.gtkw : for the Icarus VCD     (scope tb_CPU_TOP.*)
# Two files are needed because Verilator wraps the design in an extra
# "TOP." scope while Icarus Verilog does not.
#---------------------------------------------------------------------------

TOP      := tb_CPU_TOP
RTL_DIR  := ../../RTL

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_DTM/DBG_DTM.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_DM/DBG_DM.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_HART_STUB/DBG_HART_STUB.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv \
	$(RTL_DIR)/CPU/CPU_DBG/CPU_DBG/CPU_DBG.sv \
	$(RTL_DIR)/BUS/BUS_ARB/BUS_ARB.sv \
	$(RTL_DIR)/CPU/CPU_BFM/CPU_BFM.sv \
	$(RTL_DIR)/CPU/CPU_TOP/CPU_TOP.sv \
	$(RTL_DIR)/BUS/AXI4_ADDR_NARROW/AXI4_ADDR_NARROW.sv \
	$(RTL_DIR)/BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv

SIM_SRCS := \
	AXI4_SLAVE_MEM.sv \
	AXIL_SLAVE_MEM.sv \
	$(TOP).sv

SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME

IVERILOG        := iverilog
IVERILOG_FLAGS  := -g2012 -Wall -s $(TOP)

GTKWAVE := gtkwave

.PHONY: all run wave gtkwave iverilog iverilog-wave gtkwave-iv lint clean

all: run

#--- Verilator ------------------------------------------------------------
run:
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)
	./obj_dir/V$(TOP)

wave:
	$(VERILATOR) $(VERILATOR_FLAGS) --trace -DDUMP_VCD $(SRCS)
	./obj_dir/V$(TOP)

gtkwave: wave
	$(GTKWAVE) $(TOP).vcd $(TOP).gtkw &

lint:
	$(VERILATOR) --lint-only --timing --top-module $(TOP) $(SRCS)

#--- Icarus Verilog -------------------------------------------------------
iverilog:
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(TOP).vvp $(SRCS)
	vvp $(TOP).vvp

iverilog-wave:
	$(IVERILOG) $(IVERILOG_FLAGS) -DDUMP_VCD -o $(TOP).vvp $(SRCS)
	vvp $(TOP).vvp

gtkwave-iv: iverilog-wave
	$(GTKWAVE) $(TOP).vcd $(TOP)_iverilog.gtkw &

#--- Housekeeping ---------------------------------------------------------
clean:
	rm -rf obj_dir $(TOP).vvp $(TOP).vcd
