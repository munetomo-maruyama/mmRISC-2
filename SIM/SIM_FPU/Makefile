#---------------------------------------------------------------------------
# Makefile : FPU verification (RTL/CPU/CPU_FPU)
#
#   make              : run the comparison against Berkeley SoftFloat
#   make OPS=1,2 run  : only some operations (numbers as in CORE_FPU)
#   make long         : many more random vectors
#   make lint
#   make clean
#
# SoftFloat is not part of this project. Build it once with the RISCV
# specialisation (the NaN rules and "tininess after rounding" of RISC-V):
#
#   git clone https://github.com/ucb-bar/berkeley-softfloat-3 ~/RISCV/berkeley-softfloat-3
#   cd ~/RISCV/berkeley-softfloat-3/build
#   cp -r Linux-x86_64-GCC Linux-aarch64-RISCV-GCC     # or your platform
#   sed -i 's/^SPECIALIZE_TYPE ?= .*/SPECIALIZE_TYPE ?= RISCV/' \
#          Linux-aarch64-RISCV-GCC/Makefile
#   make -C Linux-aarch64-RISCV-GCC
#---------------------------------------------------------------------------

TOP       := tb_FPU
RTL_DIR   := ../../RTL

SOFTFLOAT ?= $(HOME)/RISCV/berkeley-softfloat-3
SF_BUILD  ?= $(SOFTFLOAT)/build/Linux-aarch64-RISCV-GCC
SF_INC    := -I$(SOFTFLOAT)/source/include -I$(SF_BUILD)
SF_LIB    := $(SF_BUILD)/softfloat.a

RTL_SRCS := \
	$(RTL_DIR)/CPU/CPU_FPU/FPU_ROUND/FPU_ROUND.sv \
	$(RTL_DIR)/CPU/CPU_FPU/CORE_FPU/CORE_FPU.sv

SRCS     := $(RTL_SRCS) $(TOP).sv sf_dpi.c

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-BLKSEQ \
                   -CFLAGS "$(SF_INC)" -LDFLAGS "$(SF_LIB)"

PLUSARGS ?=
OPS      ?=
ifneq ($(OPS),)
PLUSARGS += +ops=$(OPS)
endif

.PHONY: all run long lint clean

all: run

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

obj_dir/V$(TOP): obj_dir/.srchash
	@test -f $(SF_LIB) || (echo "SoftFloat not built: $(SF_LIB)"; exit 1)
	$(VERILATOR) $(VERILATOR_FLAGS) $(SRCS)

run: obj_dir/V$(TOP)
	./obj_dir/V$(TOP) $(PLUSARGS)

long: obj_dir/V$(TOP)
	./obj_dir/V$(TOP) $(PLUSARGS) +rand=20000

lint:
	$(VERILATOR) --lint-only -Wall --timing --top-module $(TOP) $(RTL_SRCS) $(TOP).sv

clean:
	rm -rf obj_dir *.vcd
