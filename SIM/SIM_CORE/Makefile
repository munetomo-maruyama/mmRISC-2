#---------------------------------------------------------------------------
# Makefile : CPU core verification (RTL/CPU/CPU_CORE)
#
#   make            : build the tests and run them all (Verilator)
#   make TEST=t01_alu run : run one test
#   make stress     : run them all with back pressure on both cache ports
#   make bugs       : injected bug campaign (bug_inject.sh)
#   make riscv-tests: the official riscv-tests, physical environment
#   make riscv-tests-v : the same tests under Sv39 in user mode (env/v)
#   make clint      : CPU_CLINT with several harts (tb_CLINT)
#   make plic       : CPU_PLIC with several contexts (tb_PLIC)
#   make trace      : run one test with the retirement trace
#   make wave       : run one test and dump tb_CORE.vcd
#   make iverilog   : run all tests with Icarus Verilog
#   make lint       : Verilator lint
#   make clean
#---------------------------------------------------------------------------

TOP      := tb_CORE
RTL_DIR  := ../../RTL

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_MMU/MMU_PMP/MMU_PMP.sv \
	$(RTL_DIR)/CPU/CPU_MMU/MMU_TLB/MMU_TLB.sv \
	$(RTL_DIR)/CPU/CPU_MMU/MMU_PTW/MMU_PTW.sv \
	$(RTL_DIR)/CPU/CPU_MMU/CORE_MMU/CORE_MMU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_DEC/CORE_DEC.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_CSR/CORE_CSR.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_MDU/CORE_MDU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_FRF/CORE_FRF.sv \
	$(RTL_DIR)/CPU/CPU_FPU/FPU_ROUND/FPU_ROUND.sv \
	$(RTL_DIR)/CPU/CPU_FPU/CORE_FPU/CORE_FPU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_RF/CORE_RF.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_IFU/CORE_IFU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_EXU/CORE_EXU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_LSU/CORE_LSU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CPU_CORE/CPU_CORE.sv \
	$(RTL_DIR)/CPU/CPU_CLINT/CPU_CLINT.sv \
	$(RTL_DIR)/CPU/CPU_PLIC/CPU_PLIC.sv

SIM_SRCS := CORE_MEM_MODEL.sv $(TOP).sv
CLINT_SRCS := $(RTL_DIR)/CPU/CPU_CLINT/CPU_CLINT.sv tb_CLINT.sv
PLIC_SRCS  := $(RTL_DIR)/CPU/CPU_PLIC/CPU_PLIC.sv tb_PLIC.sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_BASE  := --binary --timing -j 0 \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-BLKSEQ -Wno-MULTIDRIVEN
VERILATOR_FLAGS := $(VERILATOR_BASE) --top-module $(TOP)
IVERILOG_FLAGS  := -g2012 -Wall -Wno-timescale -s $(TOP)

# RISC-V toolchain for the test programs
RVPREFIX := /opt/riscv/bin/riscv64-unknown-elf-
RVCC     := $(RVPREFIX)gcc
RVOBJCOPY:= $(RVPREFIX)objcopy
RVOBJDUMP:= $(RVPREFIX)objdump
# the tests are built without the C extension so that the size of every
# instruction is known (a handler that steps over one adds 4); t08 is the one
# about compressed instructions and gets C
MARCH_DEFAULT := rv64imafd_zicsr_zifencei
MARCH_t08_rvc := rv64imafdc_zicsr_zifencei
RVFLAGS   = -march=$(or $(MARCH_$*),$(MARCH_DEFAULT)) -mabi=lp64 -mcmodel=medany \
            -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -T tests/link.ld

TESTS    := $(basename $(notdir $(wildcard tests/t*.S)))
HEXES    := $(addprefix tests/,$(addsuffix .hex,$(TESTS)))
TEST     ?= $(firstword $(TESTS))
PLUSARGS ?=

.PHONY: all run run-all stress bugs riscv-tests riscv-tests-v clint plic \
        trace wave lint iverilog clean tests

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

# The project lives on a shared folder whose file times have a resolution of
# one second, so make cannot tell from a time stamp alone whether a source has
# changed since the last build. Every build target therefore depends on a file
# that holds a hash of the sources; when the hash moves, the rule throws the
# executable away, which is what makes the build happen. Without this a run
# can silently use the executable of the previous edit.
.PHONY: FORCE

obj_dir/.srchash: FORCE
	@mkdir -p obj_dir
	@h=`cat $(SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_dir/V$(TOP); echo "$$h" > $@; fi

obj_plic/.srchash: FORCE
	@mkdir -p obj_plic
	@h=`cat $(PLIC_SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_plic/Vtb_PLIC; echo "$$h" > $@; fi

obj_clint/.srchash: FORCE
	@mkdir -p obj_clint
	@h=`cat $(CLINT_SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_clint/Vtb_CLINT; echo "$$h" > $@; fi

obj_dir/V$(TOP): obj_dir/.srchash
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)

run: obj_dir/V$(TOP) tests/$(TEST).hex
	./obj_dir/V$(TOP) +hex=tests/$(TEST).hex +name=$(TEST) $(PLUSARGS)

stress: obj_dir/V$(TOP) $(HEXES)
	@$(MAKE) --no-print-directory run-all PLUSARGS="$(STRESS_ARGS)"

bugs: obj_dir/V$(TOP) $(HEXES)
	./bug_inject.sh

riscv-tests: obj_dir/V$(TOP)
	./run_riscv_tests.sh

# The environment of env/v boots into supervisor mode with Sv39 on and runs
# the test in user mode, handing out its pages on demand: every instruction
# is translated and the page table is walked thousands of times.
riscv-tests-v: obj_dir/V$(TOP)
	./run_riscv_tests.sh -v

# the multi hart register map of the CLINT cannot be reached from a program
# on a single core, so it has a bench of its own
obj_clint/Vtb_CLINT: obj_clint/.srchash
	$(VERILATOR) $(VERILATOR_BASE) --top-module tb_CLINT -Mdir obj_clint \
	    $(RTL_DIR)/CPU/CPU_CLINT/CPU_CLINT.sv tb_CLINT.sv

clint: obj_clint/Vtb_CLINT
	./obj_clint/Vtb_CLINT

obj_plic/Vtb_PLIC: obj_plic/.srchash
	$(VERILATOR) $(VERILATOR_BASE) --top-module tb_PLIC -Mdir obj_plic \
	    $(PLIC_SRCS)

plic: obj_plic/Vtb_PLIC
	./obj_plic/Vtb_PLIC

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

# The watchdog of the test bench counts clock cycles, so it cannot end a run
# in which simulation time never advances at all -- a delta cycle storm, as
# an always block that wakes itself up produces. Such a run would sit at a
# hundred percent of a core for ever, so the wall clock limit is here.
iverilog: $(HEXES)
	iverilog $(IVERILOG_FLAGS) -o $(TOP).vvp $(SRCS)
	@fail=0; \
	for t in $(TESTS); do \
	    out=`timeout 120 vvp $(TOP).vvp +hex=tests/$$t.hex +name=$$t | grep -E "PASS|FAIL"`; \
	    if [ -z "$$out" ]; then \
	        echo " $$t : FAIL   (no result in 120 s of wall clock: time is not advancing)"; \
	        fail=1; \
	    else \
	        echo "$$out"; \
	        echo "$$out" | grep -q PASS || fail=1; \
	    fi; \
	done; \
	exit $$fail

clean:
	rm -rf obj_dir obj_trace obj_clint obj_plic bug_work rvtests $(TOP).vvp *.vcd *.log tests/*.elf tests/*.bin tests/*.hex tests/*.dis
