#---------------------------------------------------------------------------
# Makefile : the LiteX BIOS of the Arty build on CPU_TOP (tb_BIOS)
#
#   make run     build the bench and the BIOS image, run at the real
#                speed of the UART (slow: the BIOS prints a lot)
#   make check   the regression: a faster UART, PASS once the BIOS reaches
#                "Initializing SDRAM" with the UART interrupt working
#   make trace   the same as run with a retirement trace
#---------------------------------------------------------------------------
TOP      := tb_BIOS
RTL_DIR  := ../../RTL
BIOS_BIN := ../../LitexSystem/build/software/bios/bios.bin

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

SIM_SRCS := ../SIM_SYS/AXI4_SLAVE_MEM.sv LITEX_PERIPH.sv $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-UNDRIVEN -Wno-fatal

PLUSARGS ?=

.PHONY: all run check trace clean FORCE
all: check

# the shared folder keeps file times to the second: rebuild on a new hash
obj_dir/.srchash: FORCE
	@mkdir -p obj_dir
	@h=`cat $(SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_dir/V$(TOP); echo "$$h" > $@; fi

obj_dir/V$(TOP): obj_dir/.srchash
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS) > obj_dir/build.log 2>&1 || (tail -30 obj_dir/build.log; exit 1)

bios.hex: $(BIOS_BIN)
	python3 ../SIM_CORE/tools/bin2hex.py $(BIOS_BIN) $@

run: obj_dir/V$(TOP) bios.hex
	./obj_dir/V$(TOP) +bios=bios.hex $(PLUSARGS)

check: obj_dir/V$(TOP) bios.hex
	./obj_dir/V$(TOP) +bios=bios.hex +uart_cycles=2000 +maxcycles=20000000 $(PLUSARGS) | grep -A4 "^====="

trace: obj_dir/V$(TOP) bios.hex
	./obj_dir/V$(TOP) +bios=bios.hex +trace $(PLUSARGS)

clean:
	rm -rf obj_dir bios.hex
