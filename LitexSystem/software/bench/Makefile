#---------------------------------------------------------------------------
# Makefile : benchmarks for mmRISC-2 under Linux (static RISC-V binaries)
#
#   make            out/coremark, out/dhrystone, out/micro
#   make tftp       copy them and bench.sh to the TFTP server (sudo); also
#                   perf.sh, workload.sh and out/perf when
#                   ../../scripts/build_perf.sh has made it (perf on the
#                   board: perf.sh, workload.sh)
#   make clean
#
# The sources of CoreMark (EEMBC) and Dhrystone (from riscv-tests) are not
# in this repository; they are read where they are:
#
#   COREMARK  a checkout of https://github.com/eembc/coremark
#   RVTESTS   a checkout of https://github.com/riscv-software-src/riscv-tests
#
# Nothing in them is changed. Dhrystone is copied into out/dhry and the copy
# gets its timer and its printing from Linux (dhry_shim.c): the riscv-tests
# version reads mcycle, which user mode cannot.
#
# Every binary is built with the same compiler and the same flags, so the
# same files can be run on another CPU on the same board (the Rocket build)
# for a comparison that only the CPU changes.
#---------------------------------------------------------------------------

# (not ?=: make has a CC of its own, cc)
CC       := /opt/riscv/bin/riscv64-unknown-linux-gnu-gcc
COREMARK ?= $(HOME)/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark
RVTESTS  ?= $(HOME)/RISCV/riscv-tests
TFTP_DIR ?= /srv/tftp

# rv64gc, lp64d: the default of the toolchain, written out so that it shows
ARCH     := -march=rv64imafdc -mabi=lp64d
OPT      := -O2
CFLAGS   := $(ARCH) $(OPT) -static
# the same with the bit manipulation of Zba / Zbb (CPU_CORE_SPEC.md decision
# 65): coremark_zb and dhrystone_zb. The C library stays rv64gc.
ARCH_ZB  := -march=rv64imafdc_zba_zbb -mabi=lp64d

DHRY_SRC := $(RVTESTS)/benchmarks/dhrystone

.PHONY: all tftp clean
all: out/coremark out/dhrystone out/micro out/coremark_zb out/dhrystone_zb

out:
	mkdir -p out out/dhry

# CoreMark: the posix port as it is, ITERATIONS=0 lets it choose a count that
# runs for at least 10 seconds, which is what a valid result needs
CM_SRCS  = $(COREMARK)/core_list_join.c $(COREMARK)/core_main.c \
	   $(COREMARK)/core_matrix.c $(COREMARK)/core_state.c \
	   $(COREMARK)/core_util.c $(COREMARK)/posix/core_portme.c

out/coremark: | out
	$(CC) $(CFLAGS) -I$(COREMARK)/posix -I$(COREMARK) \
	    -DFLAGS_STR='"$(ARCH) $(OPT) -static"' -DITERATIONS=0 -DPERFORMANCE_RUN=1 \
	    $(CM_SRCS) -lrt -o $@

out/coremark_zb: | out
	$(CC) $(ARCH_ZB) $(OPT) -static -I$(COREMARK)/posix -I$(COREMARK) \
	    -DFLAGS_STR='"$(ARCH_ZB) $(OPT) -static"' -DITERATIONS=0 -DPERFORMANCE_RUN=1 \
	    $(CM_SRCS) -lrt -o $@

# Dhrystone 2.2 of riscv-tests. In the copy of dhrystone.h the timer is
# bench_usec() (microseconds, HZ is 1000000 there already), and a run that
# lasts less than two seconds is repeated with ten times the count.
out/dhry/dhrystone.h: $(DHRY_SRC)/dhrystone.h | out
	sed -e 's/read_csr(mcycle)/bench_usec()/' \
	    -e 's/^#define Too_Small_Time 1$$/#define Too_Small_Time (2*HZ)/' $< > $@
	grep -q 'bench_usec()' $@
	grep -q 'Too_Small_Time (2\*HZ)' $@

out/dhry/util.h: | out
	printf 'void setStats(int);\nlong bench_usec(void);\n' > $@

# Its debug_printf is empty, which hides the values the benchmark checks at
# the end ("should be: ..."); the copy's is renamed so that dhry_shim.c's,
# which prints, is the one used. And HZ * Number_Of_Runs is an int product,
# which overflows past 2147 runs at HZ = 1000000: it is made a long.
out/dhrystone: out/dhry/dhrystone.h out/dhry/util.h dhry_shim.c
	sed -e 's/Dhrystones_Per_Second = (HZ \* Number_Of_Runs)/Dhrystones_Per_Second = ((long)HZ * Number_Of_Runs)/' \
	    $(DHRY_SRC)/dhrystone_main.c > out/dhry/dhrystone_main.c
	grep -q '(long)HZ' out/dhry/dhrystone_main.c
	sed -e 's/^void debug_printf(const char\* str, \.\.\.)$$/static void debug_printf_unused(const char* str, ...)/' \
	    $(DHRY_SRC)/dhrystone.c > out/dhry/dhrystone.c
	grep -q 'debug_printf_unused' out/dhry/dhrystone.c
	$(CC) $(CFLAGS) -std=gnu89 -fno-common -fno-builtin-printf -w -Iout/dhry \
	    out/dhry/dhrystone.c out/dhry/dhrystone_main.c dhry_shim.c -o $@

# the same sources as out/dhrystone, which made out/dhry/*.c
out/dhrystone_zb: out/dhrystone
	$(CC) $(ARCH_ZB) $(OPT) -static -std=gnu89 -fno-common -fno-builtin-printf -w -Iout/dhry \
	    out/dhry/dhrystone.c out/dhry/dhrystone_main.c dhry_shim.c -o $@

out/micro: micro.c loops.h fpkern.S fpkern.c fpkern.h | out
	$(CC) $(CFLAGS) -Wall -o $@ micro.c fpkern.c fpkern.S

# the input of workload.sh's gunzip: the board's BusyBox has no gzip
out/image2m.gz: ../boot/Image | out
	head -c 2097152 $< | gzip -6 -n > $@

tftp: all out/image2m.gz
	sudo cp out/coremark out/dhrystone out/micro out/coremark_zb out/dhrystone_zb \
	    bench.sh $(TFTP_DIR)/
	sudo chmod 644 $(TFTP_DIR)/coremark $(TFTP_DIR)/dhrystone $(TFTP_DIR)/micro \
	    $(TFTP_DIR)/coremark_zb $(TFTP_DIR)/dhrystone_zb $(TFTP_DIR)/bench.sh
	if [ -f out/perf ]; then \
	    sudo cp out/perf perf.sh workload.sh out/image2m.gz $(TFTP_DIR)/ && \
	    sudo chmod 644 $(TFTP_DIR)/perf $(TFTP_DIR)/perf.sh $(TFTP_DIR)/workload.sh \
	        $(TFTP_DIR)/image2m.gz; fi
	ls -l $(TFTP_DIR)

clean:
	rm -rf out
