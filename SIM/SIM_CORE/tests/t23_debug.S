// t23_debug : debug mode (RISC-V Debug Spec 1.0), against the debugger of
// the test bench
//
// The bench halts the core, steps it and reads and writes its registers
// through the debug port of the core, as DBG_DM does for OpenOCD (tb_CORE.sv,
// "debugger", which has the list of what it checks). The program only runs
// between the halts and looks at what the debugger left behind:
//
//   1 the core halts before the first instruction (resethaltreq), and the
//     debugger writes x10 and sets dcsr.ebreakm
//   2 the debugger halts the loop, steps it and writes x12
//   3 EBREAK halts (dcsr.ebreakm), no trap. The debugger writes x15, the low
//     half of x11, f1 and mscratch, steps over the addi with an interrupt
//     pending (which must not be taken) and over the ECALL (which stops on
//     the first instruction of the handler)
//   4 the debugger halts the core in WFI, writes x12 and sets dcsr.prv to
//     user mode: the program goes on in user mode, and its ECALL says so
//
// x13 and x19 hold the addresses the debugger compares dpc with.
#include "test.h"

#define TB_IRQ_EXT  0x03000000
#define LOOPS       3000

    .section .text.init
    .globl _start
_start:
    //--------------------------------------------------------------
    // 1 the debugger was here before the first instruction
    //--------------------------------------------------------------
    TEST_INIT
    INIT_PMP
    TEST_EQ(1, x10, 0x1234)
    li   t0, (1 << 13)                    // mstatus.FS = initial
    csrs mstatus, t0

    //--------------------------------------------------------------
    // 2 a loop to halt and step in
    //--------------------------------------------------------------
    li   x11, 0xAAAAAAAA55555555
    li   x12, 0
    li   x20, 0
    li   x21, LOOPS
1:  addi x20, x20, 1
    blt  x20, x21, 1b
    TEST_EQ(2, x12, 0x5678)
    TEST_EQ(3, x20, LOOPS)

    //--------------------------------------------------------------
    // 3 EBREAK
    //--------------------------------------------------------------
    la   t0, handler
    csrw mtvec, t0
    li   t0, 0x77
    csrw mscratch, t0
    li   x16, 0
    // the machine external line up and enabled in mie; mstatus.MIE is
    // off, so it is not taken
    li   x14, TB_IRQ_EXT
    li   t0, 1
    sw   t0, 0(x14)
    lw   t0, 0(x14)
    li   t0, (1 << 11)
    csrw mie, t0
    la   x13, bp
bp: ebreak
    addi x16, x0, 1                       // the debugger continues here
    ecall
    // back from the handler. First FS: the write to f1 has made it dirty
    // (before any FP instruction here does)
    csrr x17, mstatus
    srli x17, x17, 13
    andi x17, x17, 3
    TEST_EQ(13, x17, 3)
    TEST_EQ(4, x15, 0x9abc)
    TEST_EQ(5, x11, 0xAAAAAAAA12345678)
    TEST_EQ(6, x16, 1)
    fmv.x.d x17, f1
    TEST_EQ(7, x17, 0x3ff0000000000000)
    csrr x17, mscratch
    TEST_EQ(8, x17, 0x88)
    csrr x17, mcause                      // only the ECALL trapped
    TEST_EQ(9, x17, 11)
    csrr x17, mstatus                     // MIE was put back
    andi x17, x17, 8
    TEST_EQ(10, x17, 0)
    sw   x0, 0(x14)
    lw   t0, 0(x14)
    csrw mie, x0

    //--------------------------------------------------------------
    // 4 WFI with nothing to wake it up but the debugger
    //--------------------------------------------------------------
    la   t0, handler_u                    // for the ECALL behind it
    csrw mtvec, t0
    li   x12, 0
    la   x19, 2f
1:  wfi
2:  beqz x12, 1b
    TEST_EQ(11, x12, 1)
    // the debugger resumed in user mode
    ecall
    li   gp, 14
    j    fail

handler_u:
    csrr x17, mcause
    TEST_EQ(15, x17, 8)                   // ECALL from user mode
    csrr x17, mstatus                     // and MPP says so too
    srli x17, x17, 11
    andi x17, x17, 3
    TEST_EQ(16, x17, 0)
    TEST_DONE

    // the ECALL of part 3 (the debugger steps into the first instruction)
handler:
    csrr x17, mcause
    TEST_EQ(12, x17, 11)
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

    TEST_FAIL_HANDLER

    TOHOST_SECTION
