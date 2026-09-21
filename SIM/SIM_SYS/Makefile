#---------------------------------------------------------------------------
# Makefile : the core running through the real caches (SIM_SYS)
#
#   make            : build and run every test program
#   make TEST=t01_alu run
#   make profile    : run one test and print where the cycles went
#   make stall      : run them all with random stalls on both bus slaves
#   make riscv-tests: the official tests, through the caches
#   make lint
#   make clean
#
# The test programs and the tools come from SIM_CORE; only the machine
# around the core is different. SIM_CORE answers in a fixed number of
# cycles, this one hits or misses in a real cache.
#---------------------------------------------------------------------------

TOP      := tb_SYS
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
	$(RTL_DIR)/CPU/CPU_CORE/CORE_BTB/CORE_BTB.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_IFU/CORE_IFU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_EXU/CORE_EXU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CORE_LSU/CORE_LSU.sv \
	$(RTL_DIR)/CPU/CPU_CORE/CPU_CORE/CPU_CORE.sv \
	$(RTL_DIR)/CPU/CPU_CLINT/CPU_CLINT.sv \
	$(RTL_DIR)/CPU/CPU_PLIC/CPU_PLIC.sv \
	$(RTL_DIR)/CPU/CPU_MMIO/CPU_MMIO.sv \
	$(RTL_DIR)/BUS/BUS_ARB/BUS_ARB.sv \
	$(RTL_DIR)/CPU/CPU_BFM/CPU_BFM.sv \
	$(RTL_DIR)/CPU/CPU_TOP/CPU_TOP.sv

SIM_SRCS := AXI4_SLAVE_MEM.sv AXIL_PERIPH.sv $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-UNDRIVEN

# the programs that do not need anything SIM_CORE puts in its own test bench
TESTS    := t01_alu t02_branch t03_ldst t04_hazard t05_csr t07_trap t08_rvc \
            t09_muldiv t10_atomic t11_fp t12_priv t13_pmp t14_mmu \
            t16_bench t17_btb
TEST     ?= t01_alu
PLUSARGS ?=

.PHONY: all run run-all profile stall romboot riscv-tests lint clean FORCE

all: run-all

# the shared folder has one second time stamps, so the build depends on a
# hash of the sources and not on their time (see SIM_CORE/Makefile)
obj_dir/.srchash: FORCE
	@mkdir -p obj_dir
	@h=`cat $(SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_dir/V$(TOP); echo "$$h" > $@; fi

obj_dir/V$(TOP): obj_dir/.srchash
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)

tests/%.hex:
	$(MAKE) -C ../SIM_CORE tests/$*.hex

run: obj_dir/V$(TOP) tests/$(TEST).hex
	./obj_dir/V$(TOP) +hex=tests/$(TEST).hex +name=$(TEST) $(PLUSARGS)

profile:
	@$(MAKE) --no-print-directory run PLUSARGS="+profile"

run-all: obj_dir/V$(TOP)
	@$(MAKE) -s -C ../SIM_CORE tests > /dev/null
	@fail=0; \
	for t in $(TESTS); do \
	    ./obj_dir/V$(TOP) +hex=tests/$$t.hex +name=$$t $(PLUSARGS) \
	        | grep -E "PASS|FAIL" || fail=1; \
	    ./obj_dir/V$(TOP) +hex=tests/$$t.hex +name=$$t $(PLUSARGS) \
	        | grep -q PASS || fail=1; \
	done; \
	echo ""; \
	if [ $$fail -eq 0 ]; then echo "SYS TEST RESULT : PASS"; \
	else echo "SYS TEST RESULT : FAIL"; exit 1; fi

stall:
	@$(MAKE) --no-print-directory run-all PLUSARGS="+stall"

riscv-tests: obj_dir/V$(TOP)
	./run_riscv_tests.sh

# The BIOS of LiteX runs from a ROM below MEM_BASE, so its instructions are
# fetched uncached over AXI4-Lite. Nothing else exercises that path from the
# core: this run starts there, on a stub that jumps into main memory.
obj_rom/.srchash: FORCE
	@mkdir -p obj_rom
	@h=`cat $(SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_rom/V$(TOP); echo "$$h" > $@; fi

obj_rom/V$(TOP): obj_rom/.srchash
	$(VERILATOR) $(VERILATOR_FLAGS) -GRESET_ADDR=0x10000000 -Mdir obj_rom $(SRCS)

romboot: obj_rom/V$(TOP)
	@$(MAKE) -s -C ../SIM_CORE tests > /dev/null
	@fail=0; \
	for t in $(TESTS); do \
	    ./obj_rom/V$(TOP) +hex=tests/$$t.hex +name=$$t $(PLUSARGS) \
	        | grep -E "PASS|FAIL" || fail=1; \
	    ./obj_rom/V$(TOP) +hex=tests/$$t.hex +name=$$t $(PLUSARGS) \
	        | grep -q PASS || fail=1; \
	done; \
	echo ""; \
	if [ $$fail -eq 0 ]; then echo "ROMBOOT TEST RESULT : PASS"; \
	else echo "ROMBOOT TEST RESULT : FAIL"; exit 1; fi

lint:
	$(VERILATOR) --lint-only -Wall --timing --top-module $(TOP) $(SRCS)

clean:
	rm -rf obj_dir obj_rom *.vcd *.log
