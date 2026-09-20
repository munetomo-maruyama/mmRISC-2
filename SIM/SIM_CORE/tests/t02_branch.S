// t02_branch : conditional branches, JAL and JALR
#include "test.h"
    .section .text.init
    .globl _start
_start:
    li   x10, 5
    li   x11, 7
    li   x12, -3

    // ---- BEQ / BNE ----
    li   x13, 0
    beq  x10, x10, 1f
    j    fail
1:  bne  x10, x11, 1f
    j    fail
1:  beq  x10, x11, fail_taken
    bne  x10, x10, fail_taken

    // ---- BLT / BGE (signed) ----
    blt  x10, x11, 1f
    j    fail
1:  blt  x12, x10, 1f                    // -3 < 5
    j    fail
1:  bge  x11, x10, 1f
    j    fail
1:  bge  x10, x12, 1f                    // 5 >= -3
    j    fail
1:  blt  x11, x10, fail_taken
    bge  x12, x10, fail_taken

    // ---- BLTU / BGEU (unsigned) ----
    bltu x10, x11, 1f
    j    fail
1:  bltu x10, x12, 1f                    // -3 unsigned is huge
    j    fail
1:  bgeu x12, x10, 1f
    j    fail
1:  bgeu x11, x11, 1f
    j    fail
1:  bltu x12, x10, fail_taken

    // ---- JAL : the link register holds the return address ----
    li   gp, 10
    jal  x14, jal_target
    j    fail                            // must not come back here
jal_back:
    // x14 points at the instruction after the JAL
    li   gp, 11
    lw   x15, 0(x14)                     // the word at the link address
    li   t6, 0x0000006f                  // "j fail" is a JAL x0
    andi x16, x15, 0x7F
    li   t6, 0x6F
    bne  x16, t6, fail

    // ---- JALR ----
    li   gp, 12
    la   x17, jalr_target
    jalr x18, x17, 0
    j    fail
jalr_back:
    // ---- loop with a counter ----
    li   gp, 13
    li   x19, 0
    li   x20, 10
1:  addi x19, x19, 1
    blt  x19, x20, 1b
    TEST_EQ(14, x19, 10)

    // ---- backward and forward jumps ----
    li   gp, 15
    j    2f
1:  li   x21, 0x55
    j    3f
2:  li   x21, 0x11
    j    1b
3:  TEST_EQ(16, x21, 0x55)

    TEST_DONE

fail_taken:
    // a branch that must not be taken was taken
    li   gp, 99
    j    fail

jal_target:
    // x14 was written with the address of the instruction after the JAL
    j    jal_back

jalr_target:
    j    jalr_back

    TEST_FAIL_HANDLER
    TOHOST_SECTION
