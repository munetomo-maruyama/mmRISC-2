// t31_zicond : Zicond and the hints of Zihintpause / Zihintntl
// (CPU_CORE_SPEC.md decision 68)
//
//   1 czero.eqz / czero.nez on a table of values: rs2 zero, one bit only
//     (the lowest, the highest, one in the upper half), all ones
//   2 the registers: rd = rs1, rd = rs2, rs1 = rs2, x0 as rs1, as rs2 and
//     as rd
//   3 forwarding: rs2 from the instruction just in front, from a load just
//     in front, the result straight into a branch and into an address
//   4 the hints: PAUSE, NTL.P1 .. NTL.ALL and C.NTL.* are no traps and
//     write nothing
#include "test.h"

    .option arch, +zicond

#define EQZ(n, a, b, exp)   \
    li   x10, a;            \
    li   x11, b;            \
    czero.eqz x12, x10, x11;\
    TEST_EQ(n, x12, exp)

#define NEZ(n, a, b, exp)   \
    li   x10, a;            \
    li   x11, b;            \
    czero.nez x12, x10, x11;\
    TEST_EQ(n, x12, exp)

    .section .text.init
    .globl _start
_start:
    TEST_INIT

    //--------------------------------------------------------------
    // 1 values
    //--------------------------------------------------------------
    EQZ( 2, 0x123456789abcdef0, 0, 0)
    EQZ( 3, 0x123456789abcdef0, 1, 0x123456789abcdef0)
    EQZ( 4, 0x123456789abcdef0, 0x8000000000000000, 0x123456789abcdef0)
    EQZ( 5, 0x123456789abcdef0, 0x0000000100000000, 0x123456789abcdef0)
    EQZ( 6, -1, -1, -1)
    EQZ( 7, 0, 5, 0)
    NEZ( 8, 0x123456789abcdef0, 0, 0x123456789abcdef0)
    NEZ( 9, 0x123456789abcdef0, 1, 0)
    NEZ(10, 0x123456789abcdef0, 0x8000000000000000, 0)
    NEZ(11, 0x123456789abcdef0, 0x0000000100000000, 0)
    NEZ(12, -1, 0, -1)
    NEZ(13, -1, -1, 0)

    //--------------------------------------------------------------
    // 2 registers
    //--------------------------------------------------------------
    li   x10, 0x55
    li   x11, 7
    czero.eqz x10, x10, x11           // rd = rs1
    TEST_EQ(14, x10, 0x55)
    li   x11, 0
    czero.eqz x10, x10, x11
    TEST_EQ(15, x10, 0)
    li   x10, 0x66
    li   x11, 3
    czero.nez x11, x10, x11           // rd = rs2
    TEST_EQ(16, x11, 0)
    li   x11, 0
    czero.nez x11, x10, x11
    TEST_EQ(17, x11, 0x66)
    li   x10, 0x77
    czero.eqz x12, x10, x10           // rs1 = rs2
    TEST_EQ(18, x12, 0x77)
    czero.nez x12, x10, x10
    TEST_EQ(19, x12, 0)
    czero.eqz x12, x10, x0            // rs2 = x0: always zero
    TEST_EQ(20, x12, 0)
    czero.nez x12, x10, x0            //   ... always rs1
    TEST_EQ(21, x12, 0x77)
    li   x12, 9
    czero.nez x12, x0, x0             // rs1 = x0
    TEST_EQ(22, x12, 0)
    czero.nez x0, x10, x0             // rd = x0
    TEST_EQ(23, x0, 0)

    //--------------------------------------------------------------
    // 3 forwarding
    //--------------------------------------------------------------
    li   x10, 0x1234
    li   x13, 5
    addi x11, x13, -5                 // 0, from the ALU just in front
    czero.nez x12, x10, x11
    TEST_EQ(24, x12, 0x1234)
    addi x11, x13, -4                 // 1
    czero.nez x12, x10, x11
    TEST_EQ(25, x12, 0)
    la   x14, data
    ld   x11, 0(x14)                  // 0, from a load just in front
    czero.eqz x12, x10, x11
    TEST_EQ(26, x12, 0)
    ld   x11, 8(x14)                  // 3
    czero.eqz x12, x10, x11
    TEST_EQ(27, x12, 0x1234)
    // the result into a branch
    li   x15, 0
    czero.eqz x12, x10, x11
    bnez x12, 1f
    li   x15, 1
1:  TEST_EQ(28, x15, 0)
    czero.nez x12, x10, x11
    bnez x12, 1f
    li   x15, 2
1:  TEST_EQ(29, x15, 2)
    // into an address: data + 8 when x11 is not zero
    li   x16, 8
    czero.eqz x17, x16, x11
    add  x17, x17, x14
    ld   x18, 0(x17)
    TEST_EQ(30, x18, 3)
    // a select: x11 != 0 ? x19 : x20
    li   x19, 0xaaaa
    li   x20, 0xbbbb
    czero.eqz x21, x19, x11
    czero.nez x22, x20, x11
    or   x21, x21, x22
    TEST_EQ(31, x21, 0xaaaa)

    //--------------------------------------------------------------
    // 4 the hints
    //--------------------------------------------------------------
    li   x10, 0x5a
    .word 0x0100000f                  // pause
    .word 0x00200033                  // ntl.p1   (add x0, x0, x2)
    .word 0x00300033                  // ntl.pall (add x0, x0, x3)
    .word 0x00400033                  // ntl.s1   (add x0, x0, x4)
    .word 0x00500033                  // ntl.all  (add x0, x0, x5)
    .half 0x900a                      // c.ntl.p1 (c.add x0, x2)
    .half 0x9016                      // c.ntl.all (c.add x0, x5)
    TEST_EQ(32, x10, 0x5a)
    TEST_EQ(33, x0, 0)

    TEST_DONE

    TEST_FAIL_HANDLER

    .section .data
    .align 3
data: .dword 0, 3

    TOHOST_SECTION
