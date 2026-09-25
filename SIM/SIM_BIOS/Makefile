#---------------------------------------------------------------------------
# Makefile : the LiteX BIOS of the Arty build on CPU_TOP (tb_BIOS)
#
#   make run     build the bench and the BIOS image, run at the real
#                speed of the UART (slow: the BIOS prints a lot)
#   make check   the regression: a faster UART, PASS once the BIOS reaches
#                "Initializing SDRAM" with the UART interrupt working
#   make trace   the same as run with a retirement trace
#   make linux   OpenSBI and the kernel, loaded straight into memory
#   make linux-initrd  the same with the BusyBox initramfs, into user space
#   make linux-sd      the board's own boot: the root from the SD card model
#                      (SD_MODEL.sv) with sdcard.img, made here like the card
#                (LINUX_ARGS adds plusargs, e.g. +pcmon=5000000)
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
	$(RTL_DIR)/CPU/CPU_DMA/DMA_CACHE.sv \
	$(RTL_DIR)/CPU/CPU_BFM/CPU_BFM.sv \
	$(RTL_DIR)/CPU/CPU_TOP/CPU_TOP.sv

SIM_SRCS := ../SIM_SYS/AXI4_SLAVE_MEM.sv LITEX_PERIPH.sv SD_MODEL.sv $(TOP).sv
SRCS     := $(RTL_SRCS) $(SIM_SRCS)

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -j 0 --top-module $(TOP) \
                   -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
                   -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
                   -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-UNDRIVEN -Wno-fatal

PLUSARGS ?=

.PHONY: all run check trace linux linux-initrd linux-sd clean FORCE

FW_BIN    := ../../LitexSystem/software/boot/fw_jump.bin
IMAGE_BIN := ../../LitexRocket/software/boot/Image
LINUX_ARGS ?= +pcmon=10000000 +uart_cycles=20 +maxcycles=2000000000
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

fw_jump.hex: $(FW_BIN)
	python3 ../SIM_CORE/tools/bin2hex.py $(FW_BIN) $@

Image.hex: $(IMAGE_BIN)
	python3 ../SIM_CORE/tools/bin2hex.py $(IMAGE_BIN) $@

linux: obj_dir/V$(TOP) fw_jump.hex Image.hex
	./obj_dir/V$(TOP) +linux +fw=fw_jump.hex +image=Image.hex $(LINUX_ARGS)

# The same kernel with the BusyBox initramfs of the Rocket build instead of
# the SD card, so that user space can be reached without an SD card model.
# The device tree is the one of the Arty with two changes made here, so the
# two cannot drift apart: the initramfs at 0x8200_0000, and bootargs that
# run BusyBox init from it (/init; on the SD card /sbin/init, the same
# program: its applet links are made at run time by inittab).
INITRD_BIN := /home/taka/mmlitex_build/initrd_bb
INITRD_ADDR := 0x82000000

sim_initrd.dts: ../../LitexSystem/software/mmrisc_arty.dts $(INITRD_BIN)
	sz=`stat -c %s $(INITRD_BIN)`; \
	end=`printf '0x%x' $$(( $(INITRD_ADDR) + $$sz ))`; \
	sed -e 's|bootargs = ".*";|bootargs = "console=liteuart earlycon=liteuart,0x12003800 rdinit=/init";\
		linux,initrd-start = <$(INITRD_ADDR)>;\
		linux,initrd-end = <'$$end'>;|' $< > $@

fw_jump_initrd.hex: sim_initrd.dts
	mkdir -p initrd_fw
	DTS=$(CURDIR)/sim_initrd.dts DTB=$(CURDIR)/initrd_fw/sim.dtb OUT=$(CURDIR)/initrd_fw \
	    ../../LitexSystem/scripts/build_opensbi.sh > initrd_fw/build.log 2>&1
	python3 ../SIM_CORE/tools/bin2hex.py initrd_fw/fw_jump.bin $@

initrd.hex: $(INITRD_BIN)
	python3 ../SIM_CORE/tools/bin2hex.py $(INITRD_BIN) $@

linux-initrd: obj_dir/V$(TOP) fw_jump_initrd.hex Image.hex initrd.hex
	./obj_dir/V$(TOP) +linux +fw=fw_jump_initrd.hex +image=Image.hex \
	    +initrd=initrd.hex $(LINUX_ARGS)

# The disk image of the SD card, laid out like the one of the board
# (LitexRocket/docs/BUILD_STATUS.md): an MBR, a small first partition and an
# ext4 second partition with the BusyBox tree and sbin/init -> ../bin/busybox.
# 18 MiB, so the card reports a C_SIZE of 35.
ROOTFS_SRC := /home/taka/mmlitex_build/initramfs

sdcard.img: $(INITRD_BIN)
	rm -rf sd_work; mkdir -p sd_work
	cp -a $(ROOTFS_SRC) sd_work/rootfs
	ln -sf ../bin/busybox sd_work/rootfs/sbin/init
	dd if=/dev/zero of=sd_work/p2.img bs=1M count=16 status=none
	/usr/sbin/mke2fs -q -t ext4 -L rootfs -d sd_work/rootfs sd_work/p2.img
	dd if=/dev/zero of=$@ bs=1M count=18 status=none
	printf 'label: dos\nstart=2048, size=2048, type=c\nstart=4096, type=83\n' | \
	    /usr/sbin/sfdisk -q $@
	dd if=sd_work/p2.img of=$@ bs=512 seek=4096 conv=notrunc status=none
	rm -rf sd_work

linux-sd: obj_dir/V$(TOP) fw_jump.hex Image.hex sdcard.img
	cp sdcard.img sdcard_run.img
	./obj_dir/V$(TOP) +linux +fw=fw_jump.hex +image=Image.hex \
	    +sdimg=sdcard_run.img $(LINUX_ARGS)

clean:
	rm -rf obj_dir bios.hex fw_jump.hex Image.hex fw_jump_initrd.hex initrd.hex sim_initrd.dts initrd_fw \
	       sdcard.img sdcard_run.img sd_work
