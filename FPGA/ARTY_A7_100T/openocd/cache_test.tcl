#---------------------------------------------------------------------------
# cache_test.tcl : data cache check from the debugger (Arty A7-100T)
#
#   openocd -f openocd/ft2232h_jtag.cfg  -f openocd/cache_test.tcl
#   openocd -f openocd/ft2232h_cjtag.cfg -f openocd/cache_test.tcl
#
# Runs the sequence of chapter 5 of the README with automatic checks:
# write miss / read miss / read hit / write hit, several lines, a block that
# refills every set of the 16KiB data cache, and finally a reset to show that
# the values are in memory (debug writes are write through).
#
# The image for load_image / verify_image is generated here, there is no
# binary in the repository. It is written to the directory OpenOCD was
# started in (cache_test_image.bin) and can be deleted afterwards.
#---------------------------------------------------------------------------

# size of the block used for the replacement test (32KiB = twice the cache).
# Set it to a smaller value before sourcing this file when the link is slow
# (for example against the RTL simulation).
if {![info exists cache_test_bytes]} { set cache_test_bytes 32768 }

set errors 0

proc chk {name expected actual} {
    global errors
    if {$expected eq $actual} {
        echo "\[ OK \] $name = $actual"
    } else {
        echo "\[FAIL\] $name : expected $expected, got $actual"
        incr errors
    }
}

proc rd32 {addr} {
    return [format 0x%08x [read_memory $addr 32 1]]
}

# the board config files already call init; when this script is used with a
# config that does not, do it here (the run stage commands do not exist yet)
if {[info commands halt] eq ""} { init }

halt

#---------------------------------------------------------------------------
# 1. one line : write miss, read miss, read hit, write hit
#---------------------------------------------------------------------------
echo ""
echo "--- 1. single line : miss and hit ---"
mww 0x80001000 0x11111111
chk "read miss  @0x80001000" 0x11111111 [rd32 0x80001000]
chk "read hit   @0x80001000" 0x11111111 [rd32 0x80001000]
chk "read hit   @0x80001004" 0x00000000 [rd32 0x80001004]
mww 0x80001004 0x22222222
chk "write hit  @0x80001004" 0x22222222 [rd32 0x80001004]
chk "line kept  @0x80001000" 0x11111111 [rd32 0x80001000]

#---------------------------------------------------------------------------
# 2. more lines and more sets
#---------------------------------------------------------------------------
echo ""
echo "--- 2. several lines ---"
for {set i 0} {$i < 8} {incr i} {
    set a [expr {0x80002000 + $i * 0x40}]
    mww $a [expr {0xA5A50000 + $i}]
}
for {set i 0} {$i < 8} {incr i} {
    set a [expr {0x80002000 + $i * 0x40}]
    chk "line $i @[format 0x%08x $a]" [format 0x%08x [expr {0xA5A50000 + $i}]] [rd32 $a]
}

#---------------------------------------------------------------------------
# 3. 32KiB through the cache : every set is refilled twice (D$ is 16KiB)
#---------------------------------------------------------------------------
echo ""
echo "--- 3. block of $cache_test_bytes bytes : replacement ---"
set fname "cache_test_image.bin"
set f [open $fname wb]
fconfigure $f -translation binary
for {set i 0} {$i < $cache_test_bytes} {incr i} {
    puts -nonewline $f [format %c [expr {($i * 7 + 3) & 0xff}]]
}
close $f
load_image $fname 0x80004000 bin
if {[catch {verify_image $fname 0x80004000 bin} err]} {
    echo "\[FAIL\] verify_image : $err"
    incr errors
} else {
    echo "\[ OK \] load_image / verify_image ($cache_test_bytes bytes)"
}

# the lines of step 1 and 2 were replaced by the block above: reading them
# again is a miss, and the values must still be there
chk "after replacement @0x80001000" 0x11111111 [rd32 0x80001000]
chk "after replacement @0x80001004" 0x22222222 [rd32 0x80001004]
chk "after replacement @0x80002000" 0xa5a50000 [rd32 0x80002000]

#---------------------------------------------------------------------------
# 4. reset : the cache is empty afterwards, memory keeps the values
#    (debug writes are write through, see CPU_CACHE_SPEC.md 4.7)
#---------------------------------------------------------------------------
echo ""
echo "--- 4. after reset halt ---"
reset halt
chk "pc after reset" 0x0000000080000000 [lindex [reg pc] 2]
chk "memory kept @0x80001000" 0x11111111 [rd32 0x80001000]
chk "memory kept @0x80001004" 0x22222222 [rd32 0x80001004]
chk "memory kept @0x80004000" 0x18110a03 [rd32 0x80004000]   ;# bytes 03 0a 11 18

#---------------------------------------------------------------------------
# 5. peripheral bus (not cached)
#---------------------------------------------------------------------------
echo ""
echo "--- 5. peripheral bus ---"
mww 0x12000100 0x13579bdf
chk "peripheral @0x12000100" 0x13579bdf [rd32 0x12000100]

echo ""
if {$errors == 0} {
    echo "CACHE TEST RESULT : PASS"
} else {
    echo "CACHE TEST RESULT : FAIL ($errors errors)"
}
echo ""
