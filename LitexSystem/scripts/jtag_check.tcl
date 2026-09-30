#---------------------------------------------------------------------------
# jtag_check.tcl : the debug port of the LiteX SoC, on the board
#
#   openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg  -f scripts/jtag_check.tcl
#   openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_cjtag.cfg -f scripts/jtag_check.tcl
#
# (from LitexSystem/). It can run whatever the CPU is doing -- the BIOS
# prompt, Linux at the shell -- and leaves it running as it found it: it
# halts, looks, steps three instructions, writes a register and puts it
# back, and resumes. Nothing in memory is written.
#
# It prints JTAG CHECK RESULT : PASS at the end and leaves OpenOCD running
# (telnet localhost 4444 for more, docs/JTAG.md).
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
proc regval {name} { return [lindex [reg $name] 2] }

halt
chk "state after halt" "halted" [riscv.cpu curstate]

set dcsr [regval dcsr]
set prv  [expr {$dcsr & 3}]
echo "pc      = [regval pc]"
echo "dcsr    = $dcsr (cause [expr {($dcsr >> 6) & 7}], privilege [lindex {U S ? M} $prv])"
echo "mstatus = [regval mstatus]"
echo "satp    = [regval satp]"

chk "misa" "0x800000000014112d" [regval misa]
chk "dcsr.xdebugver" "4" [expr {($dcsr >> 28) & 15}]

# The identifier of the SoC, one character per 32 bit word in the CSR space:
# a read through the system bus and the peripheral bus of the CPU.
set id ""
if {[catch {read_memory 0x12002000 32 64} words]} {
    echo "read of the identifier failed: $words"
    set words {}
}
foreach w $words {
    if {$w == 0} break
    append id [format %c $w]
}
echo "identifier : $id"
if {[string match "LiteX SoC on Arty A7*" $id]} {
    echo "\[ OK \] identifier through the system bus"
} else {
    echo "\[FAIL\] identifier through the system bus"
    incr errors
}

# a register, written and put back
set a0 [regval a0]
reg a0 0x0123456789abcdef
chk "a0 written" "0x0123456789abcdef" [regval a0]
reg a0 $a0
chk "a0 back" $a0 [regval a0]

# three single steps: dcsr.cause 4, and the pc moves
for {set i 1} {$i <= 3} {incr i} {
    set pc0 [regval pc]
    step
    set pc1 [regval pc]
    chk "step $i : dcsr.cause" "4" [expr {([regval dcsr] >> 6) & 7}]
    if {$pc1 != $pc0} {
        echo "\[ OK \] step $i : pc $pc0 -> $pc1"
    } else {
        echo "\[FAIL\] step $i : pc stays at $pc0"
        incr errors
    }
}

resume
sleep 100
chk "state after resume" "running" [riscv.cpu curstate]

if {$errors == 0} {
    echo "JTAG CHECK RESULT : PASS"
} else {
    echo "JTAG CHECK RESULT : FAIL ($errors errors)"
}
