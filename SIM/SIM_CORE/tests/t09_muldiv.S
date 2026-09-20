// t09_muldiv : the M extension
//
// The official rv64um tests cover the arithmetic; this one is here so that
// the injected bug campaign, which only runs the tests of this directory,
// sees the multiplier and the divider.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    TEST_INIT

    // ---- MUL and the high halves ----
    li   x10, 6
    li   x11, 7
    mul  x12, x10, x11
    TEST_EQ(1, x12, 42)

    li   x13, -6
    mul  x14, x13, x11
    TEST_EQ(2, x14, -42)

    li   x15, 0x7FFFFFFFFFFFFFFF
    li   x16, 2
    mul  x17, x15, x16                   // wraps around
    TEST_EQ(3, x17, 0xFFFFFFFFFFFFFFFE)
    mulh x18, x15, x16
    TEST_EQ(4, x18, 0)

    li   x19, -1
    mulh x20, x19, x19                   // (-1) * (-1) = 1, high half 0
    TEST_EQ(5, x20, 0)
    mulhu x21, x19, x19                  // huge * huge
    TEST_EQ(6, x21, 0xFFFFFFFFFFFFFFFE)
    mulhsu x22, x19, x19                 // -1 * huge
    TEST_EQ(7, x22, 0xFFFFFFFFFFFFFFFF)

    li   x23, 0x4000000000000000
    mulh x24, x23, x16                   // 2^62 * 2 = 2^63
    TEST_EQ(8, x24, 0)
    mulhu x24, x23, x16
    TEST_EQ(9, x24, 0)
    li   x25, 4
    mulh x26, x23, x25                   // 2^62 * 4 = 2^64
    TEST_EQ(10, x26, 1)

    // one negative operand in the high half
    li   x10, 0x8000000000000000
    li   x11, 2
    mulh x12, x10, x11
    TEST_EQ(11, x12, 0xFFFFFFFFFFFFFFFF)
    mulhu x13, x10, x11
    TEST_EQ(12, x13, 1)
    mulhsu x14, x10, x11
    TEST_EQ(13, x14, 0xFFFFFFFFFFFFFFFF)

    // ---- MULW ----
    li   x15, 0x100000003
    li   x16, 0x200000005
    mulw x17, x15, x16                   // only the low halves count
    TEST_EQ(14, x17, 15)
    li   x18, 0x10000
    mulw x19, x18, x18                   // 2^32 -> 0 in 32 bits
    TEST_EQ(15, x19, 0)

    // ---- DIV and REM ----
    li   x20, 100
    li   x21, 7
    div  x22, x20, x21
    TEST_EQ(16, x22, 14)
    rem  x23, x20, x21
    TEST_EQ(17, x23, 2)

    li   x24, -100
    div  x25, x24, x21
    TEST_EQ(18, x25, -14)                // rounds towards zero
    rem  x26, x24, x21
    TEST_EQ(19, x26, -2)                 // the sign of the dividend
    li   x27, -7
    div  x28, x24, x27
    TEST_EQ(20, x28, 14)
    rem  x29, x24, x27
    TEST_EQ(21, x29, -2)

    divu x30, x20, x21
    TEST_EQ(22, x30, 14)
    remu x30, x20, x21
    TEST_EQ(23, x30, 2)
    divu x30, x24, x21                   // -100 is huge when unsigned
    li   t6, 0xFFFFFFFFFFFFFFFF
    li   gp, 24
    beq  x30, t6, fail                   // it is a real division, not -1

    // ---- division by zero ----
    li   x10, 1234
    li   x11, 0
    div  x12, x10, x11
    TEST_EQ(25, x12, -1)
    rem  x13, x10, x11
    TEST_EQ(26, x13, 1234)
    divu x14, x10, x11
    TEST_EQ(27, x14, 0xFFFFFFFFFFFFFFFF)
    remu x15, x10, x11
    TEST_EQ(28, x15, 1234)

    // ---- the one overflow ----
    li   x16, 0x8000000000000000
    li   x17, -1
    div  x18, x16, x17
    TEST_EQ(29, x18, 0x8000000000000000)
    rem  x19, x16, x17
    TEST_EQ(30, x19, 0)

    // ---- the 32 bit forms ----
    li   x20, 0x100000064                // the low half is 100
    li   x21, 0x200000007                // the low half is 7
    divw x22, x20, x21
    TEST_EQ(31, x22, 14)
    remw x23, x20, x21
    TEST_EQ(32, x23, 2)
    li   x24, -100
    divw x25, x24, x21
    TEST_EQ(33, x25, -14)
    remw x26, x24, x21
    TEST_EQ(34, x26, -2)
    divuw x27, x20, x21
    TEST_EQ(35, x27, 14)
    remuw x28, x20, x21
    TEST_EQ(36, x28, 2)

    li   x29, 0
    divw x30, x20, x29
    TEST_EQ(37, x30, -1)
    remw x30, x20, x29
    TEST_EQ(38, x30, 100)
    divuw x30, x20, x29
    TEST_EQ(39, x30, 0xFFFFFFFFFFFFFFFF)

    li   x10, 0xFFFFFFFF80000000         // -2^31 in the low half
    li   x11, -1
    divw x12, x10, x11
    TEST_EQ(40, x12, 0xFFFFFFFF80000000) // overflow of the 32 bit form
    remw x13, x10, x11
    TEST_EQ(41, x13, 0)

    // the result of a 32 bit form is always sign extended
    li   x14, 0x40000000
    li   x15, 2
    mulw x16, x14, x15                   // 2^31 -> negative as a word
    TEST_EQ(42, x16, 0xFFFFFFFF80000000)

    // ---- the result reaches the next instruction (forwarding) ----
    li   x17, 9
    li   x18, 9
    mul  x19, x17, x18
    addi x20, x19, 1
    TEST_EQ(43, x20, 82)
    div  x21, x19, x17
    sub  x22, x21, x17
    TEST_EQ(44, x22, 0)

    TEST_DONE
    TEST_FAIL_HANDLER
    TOHOST_SECTION
