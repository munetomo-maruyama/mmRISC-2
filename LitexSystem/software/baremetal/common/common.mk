#---------------------------------------------------------------------------
# common.mk : included by the Makefile of each bare-metal program
#
#   TARGET   the name of the program (the .elf the debugger loads)
#   SRCS     its sources (crt0.S and syscalls.c are added here)
#
#   make                 out/TARGET.elf, .bin, .dis, .map
#   make hex             out/TARGET.hex as well, for SIM/SIM_BIOS (+linux +fw=)
#
# (Eclipse builds the same program into Debug/ or Release/ from its own
# project files; out/ is kept apart so that it does not see these.)
#   make CROSS=riscv64-unknown-elf-  another toolchain (its newlib has to be
#                        built with -mcmodel=medany: the DRAM is at 2 GB)
#   make OPT=0           without optimization (stepping in the debugger)
#---------------------------------------------------------------------------
COMMON := $(dir $(lastword $(MAKEFILE_LIST)))

CROSS   ?= riscv-none-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

# the core: RV64GC + Zba / Zbb / Zbs (Zbc and Zicond too, with a newer gcc)
ARCH    ?= rv64imafdc_zicsr_zifencei_zba_zbb_zbs
ABI     ?= lp64d
OPT     ?= 2

CFLAGS  += -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O$(OPT) -g3 -Wall \
           -ffunction-sections -fdata-sections -I$(COMMON)
LDFLAGS += -march=$(ARCH) -mabi=$(ABI) -T $(COMMON)link.ld -nostartfiles \
           -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-Map=$(OUT).map
LDLIBS  += -lm

ALL_SRCS := $(COMMON)crt0.S $(COMMON)syscalls.c $(SRCS)

OUT := out/$(TARGET)

.PHONY: all hex clean
all: $(OUT).elf $(OUT).bin $(OUT).dis

$(OUT).elf: $(ALL_SRCS) $(COMMON)mmrisc.h $(COMMON)link.ld
	@mkdir -p out
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(ALL_SRCS) $(LDLIBS)
	$(SIZE) $@

$(OUT).bin: $(OUT).elf
	$(OBJCOPY) -O binary $< $@

$(OUT).dis: $(OUT).elf
	$(OBJDUMP) -d -S $< > $@

hex: $(OUT).hex
$(OUT).hex: $(OUT).bin
	python3 $(COMMON)../../../../SIM/SIM_CORE/tools/bin2hex.py $< $@

clean:
	rm -rf out
