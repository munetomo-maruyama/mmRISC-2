#---------------------------------------------------------------------------
# test_ocd.tcl : OpenOCD test sequence for tb_OCD
#   openocd -f openocd_sim.cfg -f test_ocd.tcl   (AUTH=1: authdata first)
#
# The hart is the CPU core (USE_BFM=0). After the power-on reset it runs
# whatever the RAM holds (nothing: it traps around), so the test halts it,
# puts a small loop into the RAM and debugs that:
#
#   0x80001000  addi a0, a0, 1
#   0x80001004  addi a1, a1, 2
#   0x80001008  j    0x80001000
#
#   0x80001100  addi a0, a0, 1           (a second one, for the triggers)
#   0x80001104  sd   a0, 0(a2)
#   0x80001108  ld   a1, 0(a2)
#   0x8000110c  j    0x80001100
#
# The core has no program buffer (progbufsize=0). OpenOCD probes a few CSRs
# the core does not have (vlenb, mtopi), and when the abstract command
# answers "no such register" it tries the program buffer and prints "Unable
# to insert program into progbuf". That is harmless: it then takes them as
# absent (no vector unit, no AIA). The triggers (Sdtrig, 4 of type 2) are
# there: a hardware breakpoint and watchpoints are set on the second loop.
#---------------------------------------------------------------------------
set errors 0
proc chk {name exp act} {
    global errors
    if {$exp != $act} {
        echo "\[FAIL\] $name : expected=$exp actual=$act"
        incr errors
    } else {
        echo "\[ OK \] $name = $act"
    }
}

if {[info exists env(AUTH)] && $env(AUTH) == 1} {
    init
    riscv authdata_write 0xbeefcafe
    echo "authdata written"
    # re-examine after authentication
    riscv.cpu arp_examine
} else {
    init
}

halt
chk "state after halt" "halted" [riscv.cpu curstate]

# registers
reg a0 0x0123456789abcdef
chk "reg a0" "0x0123456789abcdef" [lindex [reg a0] 2]
reg s11 0xfedcba9876543210
chk "reg s11" "0xfedcba9876543210" [lindex [reg s11] 2]
chk "misa" "0x800000000014112d" [lindex [reg misa] 2]
chk "mhartid" "0x0" [format 0x%x [lindex [reg mhartid] 2]]
reg pc 0x80001000
chk "pc (dpc)" "0x0000000080001000" [lindex [reg pc] 2]
reg ft0 0x3ff0000000000000
chk "ft0" "0x3ff0000000000000" [lindex [reg ft0] 2]

# memory bus (0x8000_0000)
mww 0x80000000 0xdeadbeef
mwd 0x80000008 0x1122334455667788
mwh 0x80000010 0xa5a5
mwb 0x80000013 0x5a
chk "mdw 0x80000000" "0xdeadbeef" [format 0x%08x [read_memory 0x80000000 32 1]]
chk "mdd 0x80000008" "0x1122334455667788" [format 0x%016x [read_memory 0x80000008 64 1]]
chk "mdh 0x80000010" "0xa5a5" [format 0x%04x [read_memory 0x80000010 16 1]]
chk "mdb 0x80000013" "0x5a" [format 0x%02x [read_memory 0x80000013 8 1]]

# block write / read (256 words)
set data {}
for {set i 0} {$i < 256} {incr i} { lappend data [format 0x%x [expr {($i * 0x01010101) ^ 0xc0ffee00}]] }
write_memory 0x80002000 32 $data
set rd {}
foreach v [read_memory 0x80002000 32 256] { lappend rd [format 0x%x $v] }
if {$rd == $data} { echo "\[ OK \] block 256 words" } else { echo "\[FAIL\] block 256 words"; incr errors }

# peripheral bus (0x1200_0000)
mwd 0x12000100 0x0badf00d0badf00d
mww 0x12000108 0x13579bdf
chk "periph mdd" "0x0badf00d0badf00d" [format 0x%016x [read_memory 0x12000100 64 1]]
chk "periph mdw" "0x13579bdf" [format 0x%08x [read_memory 0x12000108 32 1]]

# load_image / verify_image
set f [open "image.bin" wb]
for {set i 0} {$i < 4096} {incr i} { puts -nonewline $f [format %c [expr {($i * 7 + 3) & 0xff}]] }
close $f
load_image image.bin 0x80004000 bin
if {[catch {verify_image image.bin 0x80004000 bin} err]} {
    echo "\[FAIL\] verify_image : $err"
    incr errors
} else {
    echo "\[ OK \] load_image / verify_image 4KiB"
}

# a program: step through it
mww 0x80001000 0x00150513
mww 0x80001004 0x00258593
mww 0x80001008 0xff9ff06f
reg pc 0x80001000
reg a0 0
reg a1 0
step
chk "pc after step 1" "0x0000000080001004" [lindex [reg pc] 2]
chk "a0 after step 1" "0x0000000000000001" [lindex [reg a0] 2]
step
chk "pc after step 2" "0x0000000080001008" [lindex [reg pc] 2]
chk "a1 after step 2" "0x0000000000000002" [lindex [reg a1] 2]
step
chk "pc after step 3" "0x0000000080001000" [lindex [reg pc] 2]

# a software breakpoint (EBREAK written through the data cache, which the
# instruction cache has to see)
bp 0x80001004 4
resume
wait_halt 2000
chk "state at breakpoint" "halted" [riscv.cpu curstate]
chk "pc at breakpoint" "0x0000000080001004" [lindex [reg pc] 2]
chk "a0 at breakpoint" "0x0000000000000002" [lindex [reg a0] 2]
resume
wait_halt 2000
chk "pc at breakpoint again" "0x0000000080001004" [lindex [reg pc] 2]
chk "a0 at breakpoint again" "0x0000000000000003" [lindex [reg a0] 2]
chk "a1 at breakpoint again" "0x0000000000000004" [lindex [reg a1] 2]
rbp 0x80001004
chk "instruction back after rbp" "0x00258593" [format 0x%08x [read_memory 0x80001004 32 1]]

# hardware breakpoint (a trigger: the instruction is not touched)
bp 0x80001008 4 hw
chk "instruction under a hw breakpoint" "0xff9ff06f" [format 0x%08x [read_memory 0x80001008 32 1]]
reg a0 0
reg pc 0x80001000
resume
wait_halt 2000
chk "pc at hw breakpoint" "0x0000000080001008" [lindex [reg pc] 2]
chk "dcsr.cause trigger" "2" [expr {([lindex [reg dcsr] 2] >> 6) & 7}]
chk "a0 at hw breakpoint" "0x0000000000000001" [lindex [reg a0] 2]
resume
wait_halt 2000
chk "pc at hw breakpoint again" "0x0000000080001008" [lindex [reg pc] 2]
chk "a0 at hw breakpoint again" "0x0000000000000002" [lindex [reg a0] 2]
rbp 0x80001008

# watchpoints: a store, then a load. The hart halts in front of the access
mww 0x80001100 0x00150513
mww 0x80001104 0x00a63023
mww 0x80001108 0x00063583
mww 0x8000110c 0xff5ff06f
mwd 0x80003000 0
reg pc 0x80001100
reg a0 0
reg a1 0
reg a2 0x80003000
wp 0x80003000 8 w
resume
wait_halt 2000
chk "pc at the store watchpoint" "0x0000000080001104" [lindex [reg pc] 2]
chk "dcsr.cause trigger (store)" "2" [expr {([lindex [reg dcsr] 2] >> 6) & 7}]
chk "the store did not happen" "0x0000000000000000" [format 0x%016x [read_memory 0x80003000 64 1]]
resume
wait_halt 2000
chk "pc at the store watchpoint again" "0x0000000080001104" [lindex [reg pc] 2]
chk "the first store happened" "0x0000000000000001" [format 0x%016x [read_memory 0x80003000 64 1]]
rwp 0x80003000
wp 0x80003000 8 r
resume
wait_halt 2000
chk "pc at the load watchpoint" "0x0000000080001108" [lindex [reg pc] 2]
chk "a1 still the load before (memory has 2)" "0x0000000000000001" [lindex [reg a1] 2]
chk "the store before it happened" "0x0000000000000002" [format 0x%016x [read_memory 0x80003000 64 1]]
rwp 0x80003000
reg pc 0x80001000

# free run
resume
sleep 100
chk "state after resume" "running" [riscv.cpu curstate]
halt
set a0 [lindex [reg a0] 2]
if {$a0 > 3} { echo "\[ OK \] the loop ran: a0 = $a0" } else { echo "\[FAIL\] the loop did not run: a0 = $a0"; incr errors }
chk "dcsr.cause haltreq" "3" [expr {([lindex [reg dcsr] 2] >> 6) & 7}]

# reset halt : the core stops before its first instruction
reset halt
chk "state after reset halt" "halted" [riscv.cpu curstate]
chk "pc after reset" "0x0000000080000000" [lindex [reg pc] 2]
# OpenOCD holds haltreq over the reset (cause 3); resethaltreq would be 5
set cause [expr {([lindex [reg dcsr] 2] >> 6) & 7}]
if {$cause == 3 || $cause == 5} { echo "\[ OK \] dcsr.cause after reset = $cause" } else { echo "\[FAIL\] dcsr.cause after reset = $cause"; incr errors }
chk "RAM kept over ndmreset" "0xdeadbeef" [format 0x%08x [read_memory 0x80000000 32 1]]
reg pc 0x80001000
resume

if {$errors == 0} {
    echo "OPENOCD TEST RESULT : PASS"
} else {
    echo "OPENOCD TEST RESULT : FAIL ($errors errors)"
}
shutdown
