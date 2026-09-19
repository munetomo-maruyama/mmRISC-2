#---------------------------------------------------------------------------
# Makefile : L1 cache verification (RTL/CPU/CPU_CACHE)
#
#   make            : run with Verilator
#   make perf       : throughput patterns, numbers only
#   make wave-perf  : throughput patterns -> 4 VCD + GTKWave save files
#   make wave       : run with Verilator and dump tb_CACHE.vcd
#   make iverilog   : run with Icarus Verilog
#   make lint       : Verilator lint
#   make sweep      : parameter sweep (sets / ways / block / MSHR)
#   make bug        : bug injection campaign
#   make clean
#
#   Plusargs: +from=<n> +to=<n> run only test sections n..m
#             +ops=<n>            number of random operations (section 11)
#             +hb=<cycles>        print a progress line every <cycles>
#   Parameters can be overridden, e.g.  make PARAMS="-GDC_WAYS=1 -GDC_BLOCK=16"
#---------------------------------------------------------------------------

TOP      := tb_CACHE
RTL_DIR  := ../../RTL
SIM_CPU  := ../SIM_CPU

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/ICACHE/ICACHE.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/DCACHE/DCACHE.sv \
	$(RTL_DIR)/CPU/CPU_CACHE/CPU_CACHE/CPU_CACHE.sv \
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

.PHONY: all run wave wave-build perf wave-perf gtkw gtkwave-ihit gtkwave-imiss \
        gtkwave-dhit gtkwave-dmiss lint iverilog sweep bug clean

all: run

run:
	$(VERILATOR) $(VERILATOR_FLAGS) $(PARAMS) $(SRCS)
	./obj_dir/V$(TOP) $(PLUSARGS)

VERILATOR := verilator

wave: wave-build
	./obj_trace/V$(TOP) $(PLUSARGS)

wave-build:
	$(VERILATOR) $(VERILATOR_FLAGS) --trace -DDUMP_VCD -Mdir obj_trace $(PARAMS) $(SRCS)

#---------------------------------------------------------------------------
# Throughput patterns (tb_CACHE_perf.svh)
#
#   make perf       : numbers only (all patterns, no VCD)
#   make wave-perf  : one VCD + GTKWave save file per pattern
#---------------------------------------------------------------------------
PERF_ARGS := +from=99 +to=99

perf:
	$(VERILATOR) $(VERILATOR_FLAGS) $(PARAMS) $(SRCS)
	./obj_dir/V$(TOP) $(PERF_ARGS) +perf $(PLUSARGS)

wave-perf: wave-build
	./obj_trace/V$(TOP) $(PERF_ARGS) +perf=1 +vcd=$(TOP)_ihit.vcd  +marks=$(TOP)_ihit.marks
	./obj_trace/V$(TOP) $(PERF_ARGS) +perf=2 +vcd=$(TOP)_imiss.vcd +marks=$(TOP)_imiss.marks
	./obj_trace/V$(TOP) $(PERF_ARGS) +perf=3 +vcd=$(TOP)_dhit.vcd  +marks=$(TOP)_dhit.marks
	./obj_trace/V$(TOP) $(PERF_ARGS) +perf=4 +vcd=$(TOP)_dmiss.vcd +marks=$(TOP)_dmiss.marks
	$(MAKE) gtkw

gtkw:
	python3 gen_gtkw.py

gtkwave-ihit:
	gtkwave $(TOP)_ihit.vcd $(TOP)_ihit.gtkw &
gtkwave-imiss:
	gtkwave $(TOP)_imiss.vcd $(TOP)_imiss.gtkw &
gtkwave-dhit:
	gtkwave $(TOP)_dhit.vcd $(TOP)_dhit.gtkw &
gtkwave-dmiss:
	gtkwave $(TOP)_dmiss.vcd $(TOP)_dmiss.gtkw &

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
	rm -rf obj_dir obj_trace sweep_work bug_work $(TOP).vvp *.vcd *.gtkw *.marks *.log gtkw_filter
