#---------------------------------------------------------------------------
# Makefile : CoreMark and Dhrystone on the bare machine of SIM_SYS
#
#   make -C bench        bench/coremark.hex, bench/dhrystone.hex (and
#                        ldloop.hex, fploop.hex: the loops and the floating
#                        point kernels of micro.c)
#   make bench           (in SIM_SYS) build and run both with +profile
#
# The same benchmark sources as LitexSystem/software/bench (the board, under
# Linux), here in machine mode without a C library (minilib.c), so that the cycles and the
# instructions of the timed part can be read exactly and the profile of
# tb_SYS says where the cycles go. The memory of tb_SYS answers faster than
# the DDR3 of the board: a miss costs less here.
#---------------------------------------------------------------------------

.DEFAULT_GOAL := all

RVPREFIX := /opt/riscv/bin/riscv64-unknown-elf-
CC       := $(RVPREFIX)gcc
COREMARK ?= $(HOME)/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark
RVTESTS  ?= $(HOME)/RISCV/riscv-tests
DHRY_SRC := $(RVTESTS)/benchmarks/dhrystone

# 10 iterations: about three million cycles, a few minutes of simulation
CM_ITER  ?= 10

ARCH     := -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
OPT      := -O2
# -fno-tree-loop-distribute-patterns: otherwise the loop of memset in
# minilib.c is recognised as a memset and becomes a call to itself
CFLAGS   := $(ARCH) $(OPT) -mcmodel=medany -nostdlib -T link.ld \
            -fno-tree-loop-distribute-patterns -Wl,--no-warn-rwx-segments
ENV      := crt.S minilib.c ee/ee_printf.c link.ld

# CoreMark's printf for the bare metal, with its output hook (an #error in
# the original) sending to tohost, and ee_vsprintf made visible for the
# debug_printf of Dhrystone
ee/ee_printf.c: $(COREMARK)/barebones/ee_printf.c
	mkdir -p ee
	sed -e 's/^#error "You must implement the method uart_send_char.*$$/    extern void tohost_putc(char); tohost_putc(c);/' \
	    -e '/^static int$$/{N;s/^static int\nee_vsprintf/int\nee_vsprintf/}' $< > $@
	grep -q '^ee_vsprintf' $@
	grep -q 'tohost_putc(c)' $@
	! grep -q '^#error' $@

.PHONY: all clean
all: coremark.hex dhrystone.hex ldloop.hex fploop.hex

%.hex: %.elf ../../SIM_CORE/tools/bin2hex.py
	$(RVPREFIX)objcopy -O binary $< $*.bin
	python3 ../../SIM_CORE/tools/bin2hex.py $*.bin $@
	$(RVPREFIX)objdump -d $< > $*.dis
	$(RVPREFIX)nm $< | awk '$$3 == "tohost" { print $$1 }' > $*.tohost

coremark.elf: $(ENV) core_portme.c core_portme.h
	$(CC) $(CFLAGS) -I. -I$(COREMARK) \
	    -DFLAGS_STR='"$(ARCH) $(OPT)"' -DITERATIONS=$(CM_ITER) -DPERFORMANCE_RUN=1 \
	    crt.S minilib.c ee/ee_printf.c core_portme.c \
	    $(COREMARK)/core_list_join.c $(COREMARK)/core_main.c \
	    $(COREMARK)/core_matrix.c $(COREMARK)/core_state.c $(COREMARK)/core_util.c \
	    -lgcc -o $@

# the same patched copy as on the board, except that the timer is mcycle
dhry/dhrystone.h: $(DHRY_SRC)/dhrystone.h
	mkdir -p dhry
	sed -e 's/read_csr(mcycle)/bench_usec()/' $< > $@
	grep -q 'bench_usec()' $@
	printf 'void setStats(int);\nlong bench_usec(void);\n' > dhry/util.h

dhrystone.elf: $(ENV) dhry/dhrystone.h dhry_shim.c
	sed -e 's/^void debug_printf(const char\* str, \.\.\.)$$/static void debug_printf_unused(const char* str, ...)/' \
	    $(DHRY_SRC)/dhrystone.c > dhry/dhrystone.c
	sed -e 's/Dhrystones_Per_Second = (HZ \* Number_Of_Runs)/Dhrystones_Per_Second = ((long)HZ * Number_Of_Runs)/' \
	    $(DHRY_SRC)/dhrystone_main.c > dhry/dhrystone_main.c
	$(CC) $(CFLAGS) -std=gnu89 -fno-common -fno-builtin-printf -Dprintf=ee_printf -w \
	    -Idhry -I. -I$(COREMARK) \
	    crt.S minilib.c ee/ee_printf.c dhry_shim.c dhry/dhrystone.c dhry/dhrystone_main.c \
	    -lgcc -o $@

# the four loops of micro.c (LitexSystem/software/bench/loops.h), to hold
# against the board one for one
ldloop.elf: $(ENV) ldloop.c ../../../LitexSystem/software/bench/loops.h
	$(CC) $(CFLAGS) -I. -I$(COREMARK) crt.S minilib.c ee/ee_printf.c ldloop.c -lgcc -o $@

# the floating point kernels of micro.c (LitexSystem/software/bench/fpkern.S)
FPK := ../../../LitexSystem/software/bench
fploop.elf: $(ENV) fploop.c $(FPK)/fpkern.S $(FPK)/fpkern.h
	$(CC) $(CFLAGS) -I. -I$(COREMARK) crt.S minilib.c ee/ee_printf.c fploop.c \
	    $(FPK)/fpkern.S -lgcc -o $@

clean:
	rm -rf dhry ee *.elf *.bin *.hex *.dis *.tohost
