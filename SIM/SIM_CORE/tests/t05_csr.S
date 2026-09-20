// t05_csr : the CSR instructions and the machine mode CSRs
//
// The official rv64mi tests cover the common cases; this one adds what is
// specific to this core: the WARL fields of an implementation that has
// machine mode only, and the exactness of the counters.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    TEST_INIT

    // ---- mscratch : read and write ----
    li   x10, 0x0123456789ABCDEF
    csrw mscratch, x10
    csrr x11, mscratch
    TEST_EQ(1, x11, 0x0123456789ABCDEF)

    // ---- CSRRW hands the old value back ----
    li   x12, 0x55
    csrrw x13, mscratch, x12
    TEST_EQ(2, x13, 0x0123456789ABCDEF)
    csrr x14, mscratch
    TEST_EQ(3, x14, 0x55)

    // ---- CSRRS sets, CSRRC clears ----
    li   x15, 0x100
    csrrs x16, mscratch, x15
    TEST_EQ(4, x16, 0x55)
    csrr x17, mscratch
    TEST_EQ(5, x17, 0x155)
    li   x18, 0x55
    csrrc x19, mscratch, x18
    TEST_EQ(6, x19, 0x155)
    csrr x20, mscratch
    TEST_EQ(7, x20, 0x100)

    // ---- x0 as the source does not write ----
    csrrs x21, mscratch, x0
    TEST_EQ(8, x21, 0x100)
    csrr x22, mscratch
    TEST_EQ(9, x22, 0x100)

    // ---- the immediate forms ----
    csrrwi x23, mscratch, 31
    TEST_EQ(10, x23, 0x100)
    csrr x24, mscratch
    TEST_EQ(11, x24, 31)
    csrrsi x25, mscratch, 0              // a zero immediate does not write
    TEST_EQ(12, x25, 31)
    csrrci x26, mscratch, 1
    csrr x27, mscratch
    TEST_EQ(13, x27, 30)

    // ---- mstatus : MPP is WARL and machine mode is the only legal value ----
    csrw mstatus, x0
    csrr x10, mstatus
    srli x11, x10, 11
    andi x11, x11, 3
    TEST_EQ(14, x11, 3)

    li   x12, 0x88                       // MIE (3) and MPIE (7)
    csrs mstatus, x12
    csrr x13, mstatus
    andi x13, x13, 0x88
    TEST_EQ(15, x13, 0x88)
    csrc mstatus, x12
    csrr x14, mstatus
    andi x14, x14, 0x88
    TEST_EQ(16, x14, 0)

    // ---- mepc drops the low two bits (there is no C extension yet) ----
    li   x15, 0x80001006
    csrw mepc, x15
    csrr x16, mepc
    TEST_EQ(17, x16, 0x80001004)

    // ---- mtvec : mode 0 and 1 are kept, the reserved ones are not ----
    la   x17, default_trap
    ori  x18, x17, 1
    csrw mtvec, x18
    csrr x19, mtvec
    TEST_EQ_REG(18, x19, x18)
    ori  x20, x17, 3
    csrw mtvec, x20
    csrr x21, mtvec
    andi x22, x21, 3
    TEST_EQ(19, x22, 0)
    csrw mtvec, x17                      // back to the default handler

    // ---- misa : MXL = 2 and the letter I ----
    csrr x23, misa
    srli x24, x23, 62
    TEST_EQ(20, x24, 2)
    srli x25, x23, 8
    andi x25, x25, 1
    TEST_EQ(21, x25, 1)

    csrr x26, mhartid
    TEST_EQ(22, x26, 0)

    // ---- minstret is exact : a CSR access is serialising ----
    csrr x10, minstret
    addi x11, x0, 0
    addi x11, x0, 0
    csrr x12, minstret
    sub  x13, x12, x10                   // the first csrr and the two addi
    TEST_EQ(23, x13, 3)

    // ---- mcycle runs ----
    csrr x14, mcycle
    csrr x15, mcycle
    sub  x16, x15, x14
    li   gp, 24
    blez x16, fail

    // ---- the counters can be written ----
    li   x17, 0x1000
    csrw minstret, x17
    csrr x18, minstret
    // the write takes precedence over the increment of the instruction that
    // performs it (privileged specification), so the value stays 0x1000
    TEST_EQ(25, x18, 0x1000)
    li   x19, 0x2000
    csrw mcycle, x19
    csrr x20, mcycle
    li   gp, 26
    li   x21, 0x2000
    blt  x20, x21, fail

    // ---- an access that is not allowed raises an illegal instruction ----
    la   x10, skip_trap
    csrw mtvec, x10

    li   x29, 0
    csrwi 0xC00, 0                       // cycle is read only
    TEST_EQ(27, x29, 1)
    TEST_EQ(28, x28, 2)                  // illegal instruction
    TEST_EQ(33, x27, 0xC0005073)         // mtval is the instruction word

    li   x29, 0
    csrr x11, 0x7C0                      // this CSR does not exist
    TEST_EQ(29, x29, 1)

    li   x29, 0
    csrr x11, 0x180                      // satp comes with the MMU (M5)
    TEST_EQ(30, x29, 1)

    li   x29, 0
    csrr x11, mscratch                   // this one exists : no trap
    TEST_EQ(31, x29, 0)

    // reading a read only CSR is allowed
    li   x29, 0
    csrr x11, 0xC00
    TEST_EQ(32, x29, 0)

    la   x10, default_trap
    csrw mtvec, x10

    TEST_DONE

    // a handler that steps over the instruction that trapped and remembers
    // the cause in x28 and the fact that it happened in x29
    .align 2
skip_trap:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    csrr x28, mcause
    csrr x27, mtval
    li   x29, 1
    mret

    TEST_FAIL_HANDLER
    TOHOST_SECTION
