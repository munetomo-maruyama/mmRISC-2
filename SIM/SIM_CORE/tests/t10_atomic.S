// t10_atomic : the A extension
//
// LR / SC and the atomic memory operations. The cache does the read modify
// write and keeps the reservation, so this also checks that the core hands
// the right command and the right operand over.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   x10, scratch

    // ---- LR and SC ----
    li   x11, 0x1234
    sd   x11, 0(x10)
    lr.d x12, (x10)
    TEST_EQ(1, x12, 0x1234)
    li   x13, 0x5678
    sc.d x14, x13, (x10)
    TEST_EQ(2, x14, 0)                   // it worked
    ld   x15, 0(x10)
    TEST_EQ(3, x15, 0x5678)

    // an SC without a reservation fails and writes nothing
    li   x16, 0x9999
    sc.d x17, x16, (x10)
    TEST_EQ(4, x17, 1)
    ld   x18, 0(x10)
    TEST_EQ(5, x18, 0x5678)

    // a store in between breaks the reservation
    lr.d x19, (x10)
    li   x20, 0x1111
    sd   x20, 0(x10)
    sc.d x21, x16, (x10)
    TEST_EQ(6, x21, 1)
    ld   x22, 0(x10)
    TEST_EQ(7, x22, 0x1111)

    // ---- LR.W and SC.W sign extend ----
    li   x11, 0xFFFFFFFF80000000
    sd   x11, 8(x10)
    addi x23, x10, 8
    lr.w x24, (x23)
    TEST_EQ(8, x24, 0xFFFFFFFF80000000)
    li   x25, 1
    sc.w x26, x25, (x23)
    TEST_EQ(9, x26, 0)
    ld   x27, 8(x10)
    TEST_EQ(10, x27, 0xFFFFFFFF00000001) // only the low word was written

    // ---- the atomic operations, 64 bit ----
    li   x11, 0x00FF
    sd   x11, 16(x10)
    addi x12, x10, 16
    li   x13, 0x0F0F
    amoswap.d x14, x13, (x12)
    TEST_EQ(11, x14, 0x00FF)             // rd is the old value
    ld   x15, 16(x10)
    TEST_EQ(12, x15, 0x0F0F)

    li   x13, 5
    amoadd.d x14, x13, (x12)
    TEST_EQ(13, x14, 0x0F0F)
    ld   x15, 16(x10)
    TEST_EQ(14, x15, 0x0F14)

    li   x13, 0xFF
    amoand.d x14, x13, (x12)
    ld   x15, 16(x10)
    TEST_EQ(15, x15, 0x14)
    li   x13, 0x300
    amoor.d x14, x13, (x12)
    ld   x15, 16(x10)
    TEST_EQ(16, x15, 0x314)
    li   x13, 0x14
    amoxor.d x14, x13, (x12)
    ld   x15, 16(x10)
    TEST_EQ(17, x15, 0x300)

    // signed and unsigned minimum and maximum
    li   x13, -1
    sd   x13, 24(x10)
    addi x16, x10, 24
    li   x17, 1
    amomin.d x18, x17, (x16)             // min(-1, 1) = -1
    ld   x19, 24(x10)
    TEST_EQ(18, x19, -1)
    amomax.d x18, x17, (x16)             // max(-1, 1) = 1
    ld   x19, 24(x10)
    TEST_EQ(19, x19, 1)
    li   x13, -1
    sd   x13, 24(x10)
    amominu.d x18, x17, (x16)            // unsigned: 1 is the smaller one
    ld   x19, 24(x10)
    TEST_EQ(20, x19, 1)
    li   x13, -1
    sd   x13, 24(x10)
    amomaxu.d x18, x17, (x16)
    ld   x19, 24(x10)
    TEST_EQ(21, x19, -1)

    // ---- the 32 bit forms work on the low word and sign extend ----
    li   x11, 0xFFFFFFFF80000000
    sd   x11, 32(x10)
    addi x12, x10, 32
    li   x13, 1
    amoadd.w x14, x13, (x12)
    TEST_EQ(22, x14, 0xFFFFFFFF80000000) // the old value, sign extended
    ld   x15, 32(x10)
    TEST_EQ(23, x15, 0xFFFFFFFF80000001) // the high word is untouched

    li   x11, 0x00000001FFFFFFFF
    sd   x11, 40(x10)
    addi x12, x10, 40
    li   x13, 1
    amomin.w x14, x13, (x12)             // -1 against 1, signed
    ld   x15, 40(x10)
    TEST_EQ(24, x15, 0x00000001FFFFFFFF)
    amominu.w x14, x13, (x12)            // unsigned: 1 wins
    ld   x15, 40(x10)
    TEST_EQ(25, x15, 0x0000000100000001)

    // ---- an atomic operation that is not aligned traps ----
    la   x20, skip_trap
    csrw mtvec, x20
    li   x29, 0
    addi x21, x10, 1
    amoadd.d x22, x13, (x21)
    TEST_EQ(26, x29, 1)
    TEST_EQ(27, x28, 6)                  // store/AMO address misaligned
    li   x29, 0
    lr.d x22, (x21)
    TEST_EQ(28, x29, 1)
    TEST_EQ(29, x28, 4)                  // LR is a load
    la   x20, default_trap
    csrw mtvec, x20

    TEST_DONE

    .align 2
skip_trap:
    csrr x28, mcause
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    li   x29, 1
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0, 0, 0, 0, 0

    TOHOST_SECTION
