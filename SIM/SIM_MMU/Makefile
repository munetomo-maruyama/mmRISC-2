#---------------------------------------------------------------------------
# Makefile : MMU verification (RTL/CPU/CPU_MMU)
#
#   make        : run every bench (Verilator)
#   make pmp    : MMU_PMP against the model
#   make long   : ten times as many cases
#   make iverilog
#   make clean
#---------------------------------------------------------------------------

RTL_DIR := ../../RTL/CPU/CPU_MMU

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-BLKSEQ
IVERILOG_FLAGS  := -g2012 -Wall -Wno-timescale

N ?= 200000

PMP_SRCS := $(RTL_DIR)/MMU_PMP/MMU_PMP.sv tb_PMP.sv

.PHONY: all pmp long iverilog clean

all: pmp

# The project lives on a shared folder whose file times have a resolution of
# one second, so make cannot tell from a time stamp alone whether a source has
# changed since the last build. Every build target therefore depends on a file
# that holds a hash of the sources; when the hash moves, the rule throws the
# executable away, which is what makes the build happen. Without this a run
# can silently use the executable of the previous edit.
.PHONY: FORCE

obj_pmp/.srchash: FORCE
	@mkdir -p obj_pmp
	@h=`cat $(PMP_SRCS) | md5sum | cut -d' ' -f1`; \
	 if [ "`cat $@ 2>/dev/null`" != "$$h" ]; then \
	     rm -f obj_pmp/Vtb_PMP; echo "$$h" > $@; fi

obj_pmp/Vtb_PMP: obj_pmp/.srchash
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_PMP -Mdir obj_pmp \
	    $(RTL_DIR)/MMU_PMP/MMU_PMP.sv tb_PMP.sv

pmp: obj_pmp/Vtb_PMP
	./obj_pmp/Vtb_PMP +n=$(N)

long:
	@$(MAKE) --no-print-directory pmp N=2000000

iverilog:
	iverilog $(IVERILOG_FLAGS) -s tb_PMP -o tb_PMP.vvp \
	    $(RTL_DIR)/MMU_PMP/MMU_PMP.sv tb_PMP.sv
	vvp tb_PMP.vvp +n=20000

clean:
	rm -rf obj_pmp *.vvp *.vcd
