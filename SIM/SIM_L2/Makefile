#---------------------------------------------------------------------------
# Makefile : L2 cache verification (RTL/CPU/CPU_L2)
#
#   make            : run with Verilator
#   make wave       : run with Verilator and dump tb_L2.vcd
#   make lint       : Verilator lint of the RTL
#   make sweep      : parameter sweep (size / ways / replacement)
#   make bug        : bug injection campaign
#   make clean
#
#   Plusargs: +ops=<n>   operations per thread in each random phase
#             +seed=<n>  random seed
#   Parameters can be overridden, e.g.  make PARAMS="-GL2_SIZE=8192 -GL2_WAYS=2"
#
#   Verilator runs every time (as in SIM_CACHE), so a stale model is never
#   reused (the shared folder has 1 second time stamps).
#---------------------------------------------------------------------------

TOP      := tb_L2
RTL_DIR  := ../../RTL
SIM_CPU  := ../SIM_CPU

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
	$(RTL_DIR)/CPU/CPU_L2/L2_TAG_ARRAY.sv \
	$(RTL_DIR)/CPU/CPU_L2/CPU_L2.sv

SIM_SRCS := $(SIM_CPU)/AXI4_SLAVE_MEM.sv $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

PARAMS   ?=
PLUSARGS ?=

VERILATOR := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-MULTIDRIVEN

.PHONY: all run wave lint sweep bug clean

all: run

run:
	$(VERILATOR) $(VERILATOR_FLAGS) $(PARAMS) $(SRCS)
	./obj_dir/V$(TOP) $(PLUSARGS)

wave:
	$(VERILATOR) $(VERILATOR_FLAGS) --trace -DDUMP_VCD -Mdir obj_trace $(PARAMS) $(SRCS)
	./obj_trace/V$(TOP) $(PLUSARGS)

lint:
	$(VERILATOR) --lint-only -Wall --top-module CPU_L2 $(RTL_SRCS)

sweep:
	./sweep.sh | tee sweep.log

bug:
	./bug_inject.sh | tee bug_inject.log

clean:
	rm -rf obj_dir obj_trace sweep_work bug_work *.vcd *.log
