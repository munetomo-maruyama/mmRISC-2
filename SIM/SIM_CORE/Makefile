#---------------------------------------------------------------------------
# Makefile : CPU core verification (RTL/CPU/CPU_CORE)
#
#   make            : build the tests and run them all (Verilator)
#   make TEST=t01_alu run : run one test
#   make stress     : run them all with back pressure on both cache ports
#   make bugs       : injected bug campaign (bug_inject.sh)
#   make riscv-tests: the official riscv-tests (rv64ui, rv64mi)
#   make trace      : run one test with the retirement trace
#   make wave       : run one test and dump tb_CORE.vcd
#   make iverilog   : run all tests with Icarus Verilog
#   make lint       : Verilator lint
#   make clean
#---------------------------------------------------------------------------

TOP      := tb_CORE
RTL_DIR  := ../../RTL

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_DEC/CORE_DEC.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_CSR/CORE_CSR.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_RF/CORE_RF.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_IFU/CORE_IFU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_EXU/CORE_EXU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_LSU/CORE_LSU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CPU_CORE/CPU_CORE.sv \
	$(RTL_DIR)/CPU/CPU_CLINT/CPU_CLINT.sv

SIM_SRCS := CORE_MEM_MODEL.sv $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-BLKSEQ
IVERILOG_FLAGS  := -g2012 -Wall -Wno-timescale -s $(TOP)

# RISC-V toolchain for the test programs
RVPREFIX := /opt/riscv/bin/riscv64-unknown-elf-
RVCC     := $(RVPREFIX)gcc
RVOBJCOPY:= $(RVPREFIX)objcopy
RVOBJDUMP:= $(RVPREFIX)objdump
RVFLAGS  := -march=rv64i_zicsr_zifencei -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles \
            -Wl,--no-warn-rwx-segments -T tests/link.ld

TESTS    := $(basename $(notdir $(wildcard tests/t*.S)))
HEXES    := $(addprefix tests/,$(addsuffix .hex,$(TESTS)))
TEST     ?= $(firstword $(TESTS))
PLUSARGS ?=

.PHONY: all run run-all stress bugs riscv-tests trace wave lint iverilog clean tests

# back pressure on both cache ports : ready is low in 40 % of the cycles
STRESS_ARGS := +istall=40 +dstall=40

all: run-all

tests: $(HEXES)

tests/%.elf: tests/%.S tests/link.ld tests/test.h
	$(RVCC) $(RVFLAGS) -o $@ $<

tests/%.hex: tests/%.elf tools/bin2hex.py
	$(RVOBJCOPY) -O binary $< $(@:.hex=.bin)
	python3 tools/bin2hex.py $(@:.hex=.bin) $@
	$(RVOBJDUMP) -d $< > $(@:.hex=.dis)

obj_dir/V$(TOP): $(SRCS)
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)

run: obj_dir/V$(TOP) tests/$(TEST).hex
	./obj_dir/V$(TOP) +hex=tests/$(TEST).hex +name=$(TEST) $(PLUSARGS)

stress: obj_dir/V$(TOP) $(HEXES)
	@$(MAKE) --no-print-directory run-all PLUSARGS="$(STRESS_ARGS)"

bugs: obj_dir/V$(TOP) $(HEXES)
	./bug_inject.sh

riscv-tests: obj_dir/V$(TOP)
	./run_riscv_tests.sh

run-all: obj_dir/V$(TOP) $(HEXES)
	@fail=0; \
	for t in $(TESTS); do \
	    ./obj_dir/V$(TOP) +hex=tests/$$t.hex +name=$$t $(PLUSARGS) | grep -E "PASS|FAIL" || fail=1; \
	    ./obj_dir/V$(TOP) +hex=tests/$$t.hex +name=$$t $(PLUSARGS) | grep -q PASS || fail=1; \
	done; \
	echo ""; \
	if [ $$fail -eq 0 ]; then echo "CORE TEST RESULT : PASS"; \
	else echo "CORE TEST RESULT : FAIL"; exit 1; fi

trace:
	$(MAKE) run PLUSARGS="+trace"

wave: $(HEXES)
	$(VERILATOR) $(VERILATOR_FLAGS) --trace -DDUMP_VCD -Mdir obj_trace $(SRCS)
	./obj_trace/V$(TOP) +hex=tests/$(TEST).hex +name=$(TEST) +vcd=$(TOP).vcd $(PLUSARGS)

lint:
	$(VERILATOR) --lint-only -Wall --timing --top-module $(TOP) $(SRCS)

iverilog: $(HEXES)
	iverilog $(IVERILOG_FLAGS) -o $(TOP).vvp $(SRCS)
	@for t in $(TESTS); do vvp $(TOP).vvp +hex=tests/$$t.hex +name=$$t | grep -E "PASS|FAIL"; done

clean:
	rm -rf obj_dir obj_trace bug_work rvtests $(TOP).vvp *.vcd *.log tests/*.elf tests/*.bin tests/*.hex tests/*.dis
