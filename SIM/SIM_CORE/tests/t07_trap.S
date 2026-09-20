// t07_trap : the traps that the official tests do not reach
//
// The access faults of the bus (an address that no slave answers) and the
// order in which two conditions of the same instruction are reported.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   x10, skip_trap
    csrw mtvec, x10
    li   x29, 0
    li   x28, 0
    li   x24, 0                          // 0 : the handler steps over the
                                         // instruction, otherwise it resumes
                                         // at the address in x24

    // ---- a load from an address that nothing answers ----
    li   x10, 0x00001000                 // no slave there
    li   x29, 0
    ld   x11, 0(x10)
    TEST_EQ(1, x29, 1)
    TEST_EQ(2, x28, 5)                   // load access fault
    TEST_EQ_REG(3, x27, x10)             // mtval is the address

    // ---- a store to the same place ----
    li   x29, 0
    sd   x11, 0(x10)
    TEST_EQ(4, x29, 1)
    TEST_EQ(5, x28, 7)                   // store access fault
    TEST_EQ_REG(6, x27, x10)

    // ---- the store of the instruction behind a trap must not happen ----
    la   x12, scratch
    li   x13, 0x1234
    sd   x13, 0(x12)                     // a known value
    li   x29, 0
    la   x24, 4f                         // the handler goes on behind the store
    ld   x15, 0(x10)                     // traps
    sd   x0, 0(x12)                      // must not be executed: it is killed
4:
    TEST_EQ(7, x29, 1)
    ld   x16, 0(x12)
    TEST_EQ(8, x16, 0x1234)

    // ---- a misaligned load reports the address ----
    li   x29, 0
    addi x17, x12, 1
    lh   x18, 0(x17)
    TEST_EQ(9, x29, 1)
    TEST_EQ(10, x28, 4)
    TEST_EQ_REG(11, x27, x17)

    // ---- a misaligned double word ----
    li   x29, 0
    ld   x18, 0(x17)
    TEST_EQ(32, x29, 1)
    TEST_EQ(33, x28, 4)

    // ---- a misaligned store, and the memory must not be touched ----
    li   x29, 0
    sw   x13, 0(x17)
    TEST_EQ(12, x29, 1)
    TEST_EQ(13, x28, 6)
    ld   x20, 0(x12)
    TEST_EQ(34, x20, 0x1234)
    li   x29, 0
    sd   x13, 4(x12)                     // misaligned double word store
    TEST_EQ(35, x29, 1)
    TEST_EQ(36, x28, 6)
    ld   x20, 0(x12)
    TEST_EQ(37, x20, 0x1234)
    ld   x20, 8(x12)
    TEST_EQ(38, x20, 0)

    // ---- an illegal instruction reports the instruction word ----
    li   x29, 0
    .word 0x00000000                     // not an instruction
    TEST_EQ(14, x29, 1)
    TEST_EQ(15, x28, 2)
    TEST_EQ(16, x27, 0)

    // ---- EBREAK reports its own address ----
    li   x29, 0
    la   x19, 1f
1:  ebreak
    TEST_EQ(17, x29, 1)
    TEST_EQ(18, x28, 3)
    TEST_EQ_REG(19, x27, x19)            // mtval is the address of the ebreak
    TEST_EQ_REG(20, x26, x19)            // and so is mepc

    // ---- ECALL ----
    li   x29, 0
    ecall
    TEST_EQ(21, x29, 1)
    TEST_EQ(22, x28, 11)                 // environment call from machine mode

    // ---- a jump to a misaligned address ----
    li   x29, 0
    la   x20, 2f
    addi x20, x20, 2
    jalr x21, x20, 0
    TEST_EQ(23, x29, 1)
    TEST_EQ(24, x28, 0)                  // instruction address misaligned
    TEST_EQ_REG(25, x27, x20)            // mtval is the target
2:

    // ---- mstatus.MPIE holds the interrupt enable of the trap ----
    li   x22, 8                          // MIE
    csrs mstatus, x22
    li   x29, 0
    ecall                                // the handler looks at MPIE
    TEST_EQ(26, x29, 1)
    TEST_EQ(27, x25, 1)                  // MPIE was set inside the handler
    csrr x23, mstatus
    andi x23, x23, 8
    TEST_EQ(28, x23, 8)                  // MRET put MIE back
    csrc mstatus, x22

    // ---- the fetch of an address that nothing answers ----
    li   x29, 0
    la   x24, 3f
    li   x10, 0x00001000
    jalr x21, x10, 0                     // jump into nowhere
3:
    TEST_EQ(29, x29, 1)
    TEST_EQ(30, x28, 1)                  // instruction access fault
    TEST_EQ_REG(31, x26, x10)            // mepc is the address that was fetched

    la   x10, default_trap
    csrw mtvec, x10
    TEST_DONE

    //-----------------------------------------------------------------
    // x28 = mcause, x27 = mtval, x26 = mepc, x25 = mstatus.MPIE,
    // x29 = a trap happened. The handler steps over the instruction that
    // trapped, unless x24 holds an address to go on at.
    //-----------------------------------------------------------------
    .align 2
skip_trap:
    csrr x28, mcause
    csrr x27, mtval
    csrr x26, mepc
    csrr x25, mstatus
    srli x25, x25, 7
    andi x25, x25, 1
    li   x29, 1
    bne  x24, x0, resume_at
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
resume_at:
    csrw mepc, x24
    li   x24, 0
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0

    TOHOST_SECTION
