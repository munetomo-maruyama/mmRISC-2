# load.gdb : what the Eclipse launch configurations do, from the command line
#
#   riscv-none-elf-gdb -x ../common/load.gdb out/hello.elf
#
# with OpenOCD running (FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg). No reset:
# the hart is halted wherever it is (the LiteX BIOS, which has set up the
# DRAM), the program is loaded into the DRAM, pc set to _start, and it runs
# to main.
set confirm off
set pagination off
set mem inaccessible-by-default off
set arch riscv:rv64
set remote hardware-breakpoint-limit 4
set remote hardware-watchpoint-limit 4
target extended-remote localhost:3333
monitor halt
load
set $pc = _start
break main
continue
