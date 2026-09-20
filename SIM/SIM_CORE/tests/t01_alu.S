// t01_alu : register and immediate ALU operations, including the 32 bit forms
//
// The frame uses gp (x3), t0 (x5) and t6 (x31), so the test itself only uses
// x10 .. x30.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    // ---- immediate ----
    addi x10, x0, 5
    TEST_EQ(1, x10, 5)

    addi x11, x10, -10
    TEST_EQ(2, x11, -5)

    li   x12, 0x123
    slti x13, x12, 0x200
    TEST_EQ(3, x13, 1)
    slti x13, x12, 0x100
    TEST_EQ(4, x13, 0)

    li   x14, -1
    sltiu x15, x14, 1                    // -1 is huge when unsigned
    TEST_EQ(5, x15, 0)
    sltu x15, x0, x14
    TEST_EQ(6, x15, 1)

    li   x12, 0x123
    xori x16, x12, 0x0FF
    TEST_EQ(7, x16, 0x1DC)
    ori  x16, x12, 0x400
    TEST_EQ(8, x16, 0x523)
    andi x16, x12, 0x0F0
    TEST_EQ(9, x16, 0x020)

    // ---- shifts (64 bit) ----
    li   x17, 1
    slli x18, x17, 40
    TEST_EQ(10, x18, 0x10000000000)
    srli x19, x18, 36
    TEST_EQ(11, x19, 0x10)
    li   x20, -256
    srai x21, x20, 4
    TEST_EQ(12, x21, -16)
    srli x22, x20, 60
    TEST_EQ(13, x22, 0xF)

    // ---- register operations ----
    li   x23, 100
    li   x24, 7
    add  x25, x23, x24
    TEST_EQ(14, x25, 107)
    sub  x25, x23, x24
    TEST_EQ(15, x25, 93)
    sll  x25, x24, x24                   // 7 << 7
    TEST_EQ(16, x25, 896)
    slt  x25, x24, x23
    TEST_EQ(17, x25, 1)
    sltu x25, x23, x24
    TEST_EQ(18, x25, 0)
    xor  x25, x23, x24
    TEST_EQ(19, x25, 99)
    or   x25, x23, x24
    TEST_EQ(20, x25, 103)
    and  x25, x23, x24
    TEST_EQ(21, x25, 4)
    srl  x25, x23, x24                   // 100 >> 7
    TEST_EQ(22, x25, 0)
    li   x26, -1024
    sra  x25, x26, x24
    TEST_EQ(23, x25, -8)

    // ---- LUI / AUIPC ----
    lui  x27, 0x12345
    TEST_EQ(24, x27, 0x12345000)
    auipc x28, 0
    srli x28, x28, 12                    // the PC has to be inside the text page
    TEST_EQ(25, x28, 0x80000)

    // ---- 32 bit operations ----
    li   x10, 0x7FFFFFFF
    addiw x11, x10, 1                    // wraps into the sign bit
    TEST_EQ(26, x11, 0xFFFFFFFF80000000)
    li   x12, 0x100000000                // bit 32 set
    addiw x13, x12, 5                    // only the low 32 bits count
    TEST_EQ(27, x13, 5)
    li   x14, 1
    slliw x15, x14, 31
    TEST_EQ(28, x15, 0xFFFFFFFF80000000)
    srliw x16, x15, 31
    TEST_EQ(29, x16, 1)
    sraiw x17, x15, 31
    TEST_EQ(30, x17, -1)
    li   x18, 0x100000002
    li   x19, 0x200000003
    addw x20, x18, x19
    TEST_EQ(31, x20, 5)
    subw x20, x19, x18
    TEST_EQ(32, x20, 1)
    li   x21, 4
    li   x22, 30
    sllw x23, x21, x22                   // 4 << 30 = 0x1_0000_0000 -> 0
    TEST_EQ(33, x23, 0)
    li   x24, -16
    li   x25, 2
    sraw x26, x24, x25
    TEST_EQ(34, x26, -4)
    srlw x26, x24, x25                   // logical on the low 32 bits
    TEST_EQ(35, x26, 0x3FFFFFFC)

    // ---- signed against unsigned comparison ----
    li   x10, -1
    li   x11, 1
    slt  x12, x10, x11                   // -1 < 1 signed
    TEST_EQ(36, x12, 1)
    sltu x12, x10, x11                   // huge >= 1 unsigned
    TEST_EQ(37, x12, 0)
    slti x12, x10, 0                     // -1 < 0 signed
    TEST_EQ(38, x12, 1)
    sltiu x12, x10, 0
    TEST_EQ(39, x12, 0)
    li   x13, -5
    li   x14, -3
    slt  x15, x13, x14                   // -5 < -3
    TEST_EQ(40, x15, 1)
    slt  x15, x14, x13
    TEST_EQ(41, x15, 0)

    // ---- the shift amount of a 32 bit shift is five bits ----
    li   x16, 1
    li   x17, 33                         // 33 & 31 = 1
    sllw x18, x16, x17
    TEST_EQ(42, x18, 2)
    li   x19, 0x80000000
    li   x20, 36                         // 36 & 31 = 4
    srlw x21, x19, x20
    TEST_EQ(43, x21, 0x08000000)
    sraw x22, x19, x20
    TEST_EQ(44, x22, 0xFFFFFFFFF8000000)
    li   x23, 64                         // 64 & 63 = 0 for the 64 bit form
    li   x24, 0x1234
    sll  x25, x24, x23
    TEST_EQ(45, x25, 0x1234)

    TEST_DONE
    TEST_FAIL_HANDLER
    TOHOST_SECTION
