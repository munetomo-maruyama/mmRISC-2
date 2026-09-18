#---------------------------------------------------------------------------
# Makefile : L1 cache verification (RTL/CACHE)
#
#   make            : run with Verilator
#   make wave       : run with Verilator and dump tb_CACHE.vcd
#   make iverilog   : run with Icarus Verilog
#   make lint       : Verilator lint
#   make sweep      : parameter sweep (sets / ways / block / MSHR)
#   make bug        : bug injection campaign
#   make clean
#
#   Plusargs: +from=<n> +to=<n> run only test sections n..m
#   Parameters can be overridden, e.g.  make PARAMS="-GDC_WAYS=1 -GDC_BLOCK=16"
#---------------------------------------------------------------------------

TOP      := tb_CACHE
RTL_DIR  := ../../RTL
SIM_CPU  := ../SIM_CPU

RTL_SRCS := \
	$(RTL_DIR)/CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv \
	$(RTL_DIR)/CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
	$(RTL_DIR)/CACHE/ICACHE/ICACHE.sv \
	$(RTL_DIR)/CACHE/DCACHE/DCACHE.sv \
	$(RTL_DIR)/CACHE/CPU_CACHE/CPU_CACHE.sv \
	$(RTL_DIR)/BUS/BUS_ARB/BUS_ARB.sv \
	$(RTL_DIR)/BUS/AXI4_ADDR_NARROW/AXI4_ADDR_NARROW.sv \
	$(RTL_DIR)/BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv

SIM_SRCS := $(SIM_CPU)/AXI4_SLAVE_MEM.sv $(SIM_CPU)/AXIL_SLAVE_MEM.sv $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

PARAMS   ?=
PLUSARGS ?=

VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-MULTIDRIVEN

IVERILOG_FLAGS := -g2012 -Wall -Wno-timescale -s $(TOP)

.PHONY: all run wave lint iverilog sweep bug clean

all: run

run:
	$(VERILATOR) $(VERILATOR_FLAGS) $(PARAMS) $(SRCS)
	./obj_dir/V$(TOP) $(PLUSARGS)

VERILATOR := verilator

wave:
	$(VERILATOR) $(VERILATOR_FLAGS) --trace -DDUMP_VCD -Mdir obj_trace $(PARAMS) $(SRCS)
	./obj_trace/V$(TOP) $(PLUSARGS)

lint:
	$(VERILATOR) --lint-only -Wall --timing --top-module $(TOP) $(SRCS)

iverilog:
	iverilog $(IVERILOG_FLAGS) -o $(TOP).vvp $(SRCS)
	vvp $(TOP).vvp $(PLUSARGS)

sweep:
	./sweep.sh

bug:
	./bug_inject.sh | tee bug_inject.log

clean:
	rm -rf obj_dir obj_trace sweep_work bug_work $(TOP).vvp *.vcd *.log
