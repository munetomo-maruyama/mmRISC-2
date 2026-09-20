// t03_ldst : loads and stores of every size, sign and zero extension
#include "test.h"
    .section .text.init
    .globl _start
_start:
    la   x10, scratch

    // ---- SD / LD ----
    li   x11, 0x0123456789ABCDEF
    sd   x11, 0(x10)
    ld   x12, 0(x10)
    TEST_EQ(1, x12, 0x0123456789ABCDEF)

    // ---- LW / LWU (sign and zero extension) ----
    lw   x13, 0(x10)                     // 0x89ABCDEF, sign extended
    TEST_EQ(2, x13, 0xFFFFFFFF89ABCDEF)
    lwu  x14, 0(x10)
    TEST_EQ(3, x14, 0x89ABCDEF)
    lw   x15, 4(x10)                     // 0x01234567
    TEST_EQ(4, x15, 0x01234567)

    // ---- LH / LHU ----
    lh   x16, 0(x10)                     // 0xCDEF -> negative
    TEST_EQ(5, x16, 0xFFFFFFFFFFFFCDEF)
    lhu  x17, 0(x10)
    TEST_EQ(6, x17, 0xCDEF)
    lh   x18, 2(x10)                     // 0x89AB
    TEST_EQ(7, x18, 0xFFFFFFFFFFFF89AB)
    lhu  x19, 6(x10)                     // 0x0123
    TEST_EQ(8, x19, 0x0123)

    // ---- LB / LBU ----
    lb   x20, 0(x10)                     // 0xEF
    TEST_EQ(9, x20, -17)
    lbu  x21, 0(x10)
    TEST_EQ(10, x21, 0xEF)
    lb   x22, 7(x10)                     // 0x01
    TEST_EQ(11, x22, 1)
    lbu  x23, 3(x10)                     // 0x89
    TEST_EQ(12, x23, 0x89)

    // ---- SB / SH / SW at every offset ----
    li   x11, 0
    sd   x11, 8(x10)
    li   x12, 0xA5
    sb   x12, 8(x10)
    sb   x12, 11(x10)
    sb   x12, 15(x10)
    ld   x13, 8(x10)
    TEST_EQ(13, x13, 0xA5000000A50000A5)

    li   x11, 0
    sd   x11, 16(x10)
    li   x12, 0xBEEF
    sh   x12, 16(x10)
    sh   x12, 22(x10)
    ld   x13, 16(x10)
    TEST_EQ(14, x13, 0xBEEF00000000BEEF)

    li   x11, 0
    sd   x11, 24(x10)
    li   x12, 0xDEADBEEF
    sw   x12, 24(x10)
    ld   x13, 24(x10)
    TEST_EQ(15, x13, 0x00000000DEADBEEF)
    sw   x12, 28(x10)
    ld   x13, 24(x10)
    TEST_EQ(16, x13, 0xDEADBEEFDEADBEEF)

    // ---- the value of a store comes from a register that was just loaded ----
    ld   x14, 0(x10)
    sd   x14, 32(x10)
    ld   x15, 32(x10)
    TEST_EQ(17, x15, 0x0123456789ABCDEF)

    // ---- negative offset ----
    addi x16, x10, 64
    li   x17, 0x1234
    sd   x17, -8(x16)
    ld   x18, 56(x10)
    TEST_EQ(18, x18, 0x1234)

    // ---- the sign of a half word comes from bit 15, not from bit 7 ----
    li   x11, 0x0080008000800080
    sd   x11, 48(x10)
    lh   x12, 48(x10)                    // 0x0080 : positive
    TEST_EQ(19, x12, 0x0080)
    lh   x13, 50(x10)                    // 0x0080 ... bit 15 clear
    TEST_EQ(20, x13, 0x0080)
    li   x11, 0x8000800080008000
    sd   x11, 48(x10)
    lh   x14, 48(x10)                    // 0x8000 : negative
    TEST_EQ(21, x14, 0xFFFFFFFFFFFF8000)
    lhu  x15, 48(x10)
    TEST_EQ(22, x15, 0x8000)
    // ---- the sign of a word comes from bit 31 ----
    li   x11, 0x0000008000000080
    sd   x11, 48(x10)
    lw   x16, 48(x10)
    TEST_EQ(23, x16, 0x80)
    lb   x17, 48(x10)                    // 0x80 : negative as a byte
    TEST_EQ(24, x17, 0xFFFFFFFFFFFFFF80)

    TEST_DONE
    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0, 0, 0, 0, 0
    .dword 0, 0, 0, 0, 0, 0, 0, 0

    TOHOST_SECTION
