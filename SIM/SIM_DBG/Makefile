#---------------------------------------------------------------------------
# Makefile : debug logic verification (RTL/TOP/TOP.sv + RTL/CPU/CPU_DBG)
#
#   make            : run with Verilator (default simulator)
#   make wave       : run with Verilator and dump tb_DBG.vcd
#   make lint       : Verilator lint
#   make iverilog   : run with Icarus Verilog
#   make iverilog-wave : run with Icarus Verilog and dump tb_DBG.vcd
#   make run-pullup : sections 1-3 and 14 with TMSC pull-up instead of keeper
#   make wave-jtag  : JTAG memory access (sections 9-10) -> tb_DBG_jtag.vcd
#   make wave-cjtag : cJTAG online/activation + access (section 14) -> tb_DBG_cjtag.vcd
#   make gtkwave-jtag / gtkwave-cjtag : open the VCD with its .gtkw
#   make gtkw       : regenerate the .gtkw files (gen_gtkw.py, also SIM_OCD)
#   make bug        : bug injection campaign (bug_inject.sh, Icarus Verilog)
#
#   Plusargs: +from=<n> +to=<n> run only test sections n..m
#   make clean      : remove generated files
#---------------------------------------------------------------------------

TOP      := tb_DBG
RTL_DIR  := ../../RTL

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_DTM/DBG_DTM.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_DM/DBG_DM.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_HART_STUB/DBG_HART_STUB.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv \
	$(RTL_DIR)/CPU/CPU_DBG/CPU_DBG/CPU_DBG.sv \
	$(RTL_DIR)/CPU/CPU_DBG/DBG_CACHE/DBG_CACHE.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/ICACHE/ICACHE.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/DCACHE/DCACHE.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/CACHE_PORT_ARB/CACHE_PORT_ARB.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/CPU_CACHE/CPU_CACHE.sv \
	$(RTL_DIR)/BUS/BUS_ARB/BUS_ARB.sv \
	$(RTL_DIR)/BUS/AXI4_ADDR_NARROW/AXI4_ADDR_NARROW.sv \
	$(RTL_DIR)/BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv \
	$(RTL_DIR)/BUS/AXI4_RAM/AXI4_RAM.sv \
	$(RTL_DIR)/BUS/AXIL_RAM/AXIL_RAM.sv \
	$(RTL_DIR)/CPU/CPU_CLINT/CPU_CLINT.sv \
	$(RTL_DIR)/CPU/CPU_PLIC/CPU_PLIC.sv \
	$(RTL_DIR)/CPU/CPU_MMIO/CPU_MMIO.sv \
	$(RTL_DIR)/CPU/CPU_BFM/CPU_BFM.sv \
	$(RTL_DIR)/CPU/CPU_TOP/CPU_TOP.sv \
	$(RTL_DIR)/TOP/TOP.sv

SIM_SRCS := $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-MULTIDRIVEN \
                   -Wno-SYNCASYNCNET -Wno-PINCONNECTEMPTY -Wno-LATCH

IVERILOG        := iverilog
IVERILOG_FLAGS  := -g2012 -Wall -Wno-timescale -s $(TOP)

.PHONY: all run run-pullup wave wave-build wave-jtag wave-cjtag gtkwave-jtag gtkwave-cjtag gtkw lint iverilog iverilog-wave bug clean

all: run

run:
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)
	./obj_dir/V$(TOP)

wave: wave-build
	./obj_trace/V$(TOP)

wave-build:
	$(VERILATOR) $(VERILATOR_FLAGS) --trace -DDUMP_VCD -Mdir obj_trace $(SRCS)

wave-jtag: wave-build
	./obj_trace/V$(TOP) +from=9 +to=10 +vcd=$(TOP)_jtag.vcd

wave-cjtag: wave-build
	./obj_trace/V$(TOP) +from=14 +to=14 +vcd=$(TOP)_cjtag.vcd

# cJTAG / JTAG basics with the TMSC pull-up model (FPGA PULLUP)
run-pullup:
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)
	./obj_dir/V$(TOP) +tmsc_pullup +from=1 +to=3
	./obj_dir/V$(TOP) +tmsc_pullup +from=14 +to=14

gtkwave-jtag:
	@test -f $(TOP)_jtag.vcd || $(MAKE) wave-jtag
	gtkwave $(TOP)_jtag.vcd $(TOP)_jtag.gtkw &

gtkwave-cjtag:
	@test -f $(TOP)_cjtag.vcd || $(MAKE) wave-cjtag
	gtkwave $(TOP)_cjtag.vcd $(TOP)_cjtag.gtkw &

gtkw:
	python3 gen_gtkw.py

lint:
	$(VERILATOR) --lint-only -Wall --timing --top-module $(TOP) $(SRCS)

iverilog:
	$(IVERILOG) $(IVERILOG_FLAGS) -o $(TOP).vvp $(SRCS)
	vvp $(TOP).vvp

iverilog-wave:
	$(IVERILOG) $(IVERILOG_FLAGS) -DDUMP_VCD -o $(TOP).vvp $(SRCS)
	vvp $(TOP).vvp

bug:
	./bug_inject.sh | tee bug_inject.log

clean:
	rm -rf obj_dir obj_trace bug_work $(TOP).vvp $(TOP).vcd *.log
