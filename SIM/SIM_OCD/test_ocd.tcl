#---------------------------------------------------------------------------
# test_ocd.tcl : OpenOCD test sequence for tb_OCD
#   openocd -f openocd_sim.cfg -f test_ocd.tcl   (AUTH=1: authdata first)
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
chk "marchid" "0x6d6d3032" [format 0x%x [lindex [reg marchid] 2]]
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

# step / resume / reset halt
step
chk "pc after step" "0x0000000080001004" [lindex [reg pc] 2]
resume
sleep 100
chk "state after resume" "running" [riscv.cpu curstate]
reset halt
chk "state after reset halt" "halted" [riscv.cpu curstate]
chk "pc after reset" "0x0000000080000000" [lindex [reg pc] 2]
chk "RAM kept over ndmreset" "0xdeadbeef" [format 0x%08x [read_memory 0x80000000 32 1]]
resume

if {$errors == 0} {
    echo "OPENOCD TEST RESULT : PASS"
} else {
    echo "OPENOCD TEST RESULT : FAIL ($errors errors)"
}
shutdown
