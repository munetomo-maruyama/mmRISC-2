// t06_irq : the CLINT, the interrupt lines and WFI
//
// The official tests do not touch the CLINT at all, so this is where the
// timer, the software interrupt and the external line are checked, together
// with the masking through mstatus.MIE, mie and mip.
//
//   CLINT : msip 0x02000000, mtimecmp 0x02004000, mtime 0x0200BFF8
//   the test bench drives the external interrupt from 0x03000000
#include "test.h"

#define CLINT_MSIP     0x02000000
#define CLINT_MTIMECMP 0x02004000
#define CLINT_MTIME    0x0200BFF8
#define TB_IRQ_EXT     0x03000000

#define MIE_MSIE (1 << 3)
#define MIE_MTIE (1 << 7)
#define MIE_MEIE (1 << 11)
#define MSTATUS_MIE (1 << 3)

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   x10, irq_handler
    csrw mtvec, x10
    li   x29, 0                          // number of interrupts taken
    li   x28, 0                          // mcause of the last one

    // ---- mtime runs ----
    li   x10, CLINT_MTIME
    ld   x11, 0(x10)
    ld   x12, 0(x10)
    sub  x13, x12, x11
    li   gp, 1
    blez x13, fail

    // ---- the timer interrupt is pending but not enabled ----
    li   x14, CLINT_MTIMECMP
    ld   x15, 0(x10)                     // mtime
    addi x15, x15, 20
    sd   x15, 0(x14)                     // mtimecmp = mtime + 20
1:  ld   x16, 0(x10)
    blt  x16, x15, 1b                    // wait until it fired
    csrr x17, mip
    srli x17, x17, 7
    andi x17, x17, 1
    TEST_EQ(2, x17, 1)                   // MTIP is set
    TEST_EQ(3, x29, 0)                   // but no interrupt was taken

    // ---- enabling mie alone is not enough ----
    li   x18, MIE_MTIE
    csrs mie, x18
    addi x19, x0, 0
    addi x19, x0, 0
    addi x19, x0, 0
    TEST_EQ(4, x29, 0)                   // mstatus.MIE is still clear

    // ---- now let it in ----
    li   x20, MSTATUS_MIE
    csrs mstatus, x20
    addi x19, x0, 0                      // the interrupt hits one of these
    addi x19, x0, 0
    addi x19, x0, 0
    TEST_EQ(5, x29, 1)
    li   x21, 0x8000000000000007         // interrupt, machine timer
    TEST_EQ_REG(6, x28, x21)

    // the handler cleared MTIE, so nothing else comes
    csrr x22, mstatus
    andi x22, x22, MSTATUS_MIE
    TEST_EQ(7, x22, MSTATUS_MIE)         // MRET put MIE back

    // ---- the software interrupt ----
    li   x29, 0
    li   x10, MIE_MSIE
    csrs mie, x10
    li   x11, CLINT_MSIP
    li   x12, 1
    sw   x12, 0(x11)                     // raise it
    addi x19, x0, 0
    addi x19, x0, 0
    addi x19, x0, 0
    TEST_EQ(8, x29, 1)
    li   x21, 0x8000000000000003
    TEST_EQ_REG(9, x28, x21)
    lw   x13, 0(x11)
    TEST_EQ(10, x13, 0)                  // the handler cleared msip

    // ---- the external interrupt ----
    li   x29, 0
    li   x10, MIE_MEIE
    csrs mie, x10
    li   x11, TB_IRQ_EXT
    li   x12, 1
    sd   x12, 0(x11)
    addi x19, x0, 0
    addi x19, x0, 0
    addi x19, x0, 0
    TEST_EQ(11, x29, 1)
    li   x21, 0x800000000000000B
    TEST_EQ_REG(12, x28, x21)

    // ---- mstatus.MIE = 0 keeps everything out ----
    li   x29, 0
    li   x10, MSTATUS_MIE
    csrc mstatus, x10
    li   x11, MIE_MSIE
    csrs mie, x11
    li   x12, CLINT_MSIP
    li   x13, 1
    sw   x13, 0(x12)
    addi x19, x0, 0
    addi x19, x0, 0
    addi x19, x0, 0
    TEST_EQ(13, x29, 0)
    csrr x14, mip
    srli x14, x14, 3
    andi x14, x14, 1
    TEST_EQ(14, x14, 1)                  // pending, but not taken

    // ---- WFI returns although mstatus.MIE is clear ----
    wfi                                  // msip is pending and enabled
    TEST_EQ(15, x29, 0)                  // it did not trap either
    sw   x0, 0(x12)                      // clear msip

    // ---- WFI waits for the timer and then traps ----
    li   x29, 0
    li   x10, MSTATUS_MIE
    csrs mstatus, x10
    li   x11, MIE_MTIE
    csrs mie, x11
    li   x14, CLINT_MTIME
    li   x15, CLINT_MTIMECMP
    ld   x16, 0(x14)
    addi x16, x16, 50
    sd   x16, 0(x15)
    wfi
    TEST_EQ(16, x29, 1)
    li   x21, 0x8000000000000007
    TEST_EQ_REG(17, x28, x21)

    // ---- a vectored mtvec sends the timer interrupt to base + 4 * 7 ----
    li   x29, 0
    li   x30, 0
    la   x10, vec_base
    ori  x10, x10, 1                     // mode 1 : vectored
    csrw mtvec, x10
    li   x11, MIE_MTIE
    csrs mie, x11
    ld   x16, 0(x14)
    addi x16, x16, 20
    sd   x16, 0(x15)
1:  beq  x30, x0, 1b                     // the vectored handler sets x30
    TEST_EQ(18, x30, 7)
    TEST_EQ(19, x29, 1)

    la   x10, default_trap
    csrw mtvec, x10
    TEST_DONE

    //-----------------------------------------------------------------
    // the handler of the direct mode : count, remember, disable the source
    //-----------------------------------------------------------------
    .align 2
irq_handler:
    csrr x28, mcause
    addi x29, x29, 1
    // switch the source that fired off again
    li   t0, 0x8000000000000007
    beq  x28, t0, irq_timer
    li   t0, 0x8000000000000003
    beq  x28, t0, irq_soft
    li   t0, 0x800000000000000B
    beq  x28, t0, irq_ext
    j    fail                            // an exception, not an interrupt
irq_timer:
    li   t0, CLINT_MTIMECMP
    li   t6, -1
    sd   t6, 0(t0)                       // mtimecmp = -1 : no longer pending
    mret
irq_soft:
    li   t0, CLINT_MSIP
    sw   x0, 0(t0)
    mret
irq_ext:
    li   t0, TB_IRQ_EXT
    sd   x0, 0(t0)
    mret

    //-----------------------------------------------------------------
    // the vectored table : entry 7 is the machine timer
    //-----------------------------------------------------------------
    .align 6
vec_base:
    j    vec_bad                         // 0
    j    vec_bad
    j    vec_bad
    j    vec_bad                         // 3 : machine software
    j    vec_bad
    j    vec_bad
    j    vec_bad
    j    vec_timer                       // 7 : machine timer
vec_bad:
    j    fail
vec_timer:
    li   x30, 7
    addi x29, x29, 1
    li   t0, CLINT_MTIMECMP
    li   t6, -1
    sd   t6, 0(t0)
    mret

    TEST_FAIL_HANDLER
    TOHOST_SECTION
