// t04_hazard : the bypass network and the interlocks
//
//   EX -> EX  (the result of the instruction right in front)
//   MA -> EX  (one instruction in between)
//   load use  (the answer of the cache reaches EX directly)
//   the data of a store, and a branch on a value that was just computed
//
// The frame uses gp (x3), t0 (x5) and t6 (x31), so the test itself only uses
// x10 .. x30.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    la   x10, scratch

    // ---- EX -> EX, back to back ----
    addi x11, x0, 1
    addi x11, x11, 1
    addi x11, x11, 1
    addi x11, x11, 1
    TEST_EQ(1, x11, 4)

    // ---- MA -> EX, one instruction in between ----
    addi x12, x0, 10
    addi x13, x0, 20                     // filler
    add  x14, x12, x12
    TEST_EQ(2, x14, 20)

    // ---- both operands from the instruction in front ----
    addi x15, x0, 7
    add  x16, x15, x15
    TEST_EQ(3, x16, 14)

    // ---- the address of a load comes from the instruction in front ----
    li   x17, 0x0123456789ABCDEF
    sd   x17, 0(x10)
    addi x18, x10, 0                     // a copy of the address
    ld   x19, 0(x18)                     // uses it right away
    TEST_EQ(4, x19, 0x0123456789ABCDEF)

    // ---- load use : the value is needed by the very next instruction ----
    ld   x20, 0(x10)
    addi x21, x20, 1
    TEST_EQ(5, x21, 0x0123456789ABCDF0)

    // ---- load use through the second operand ----
    ld   x22, 0(x10)
    sub  x23, x22, x22
    TEST_EQ(6, x23, 0)

    // ---- the value of a store comes from the instruction in front ----
    addi x24, x0, 0x55
    sd   x24, 8(x10)
    ld   x25, 8(x10)
    TEST_EQ(7, x25, 0x55)

    // ---- the value of a store comes from a load that just answered ----
    ld   x26, 0(x10)
    sd   x26, 16(x10)
    ld   x27, 16(x10)
    TEST_EQ(8, x27, 0x0123456789ABCDEF)

    // ---- the address of a store comes from the instruction in front ----
    addi x28, x10, 24
    li   x29, 0x1234
    sd   x29, 0(x28)
    ld   x30, 24(x10)
    TEST_EQ(9, x30, 0x1234)

    // ---- a branch on a value that was just computed ----
    addi x11, x0, 5
    addi x12, x0, 5
    beq  x11, x12, 1f                    // taken, both from EX / MA
    j    fail
1:
    addi x13, x0, 3
    blt  x13, x11, 2f                    // 3 < 5, taken
    j    fail
2:
    li   gp, 10

    // ---- a branch on a value that a load just delivered ----
    li   x14, 42
    sd   x14, 32(x10)
    ld   x15, 32(x10)
    li   x16, 42
    beq  x15, x16, 3f                    // load use on a branch
    j    fail
3:
    li   gp, 11

    // ---- a jump whose target comes from the instruction in front ----
    la   x17, 4f
    jalr x18, x17, 0                     // x18 <- the address of 6b
6:
    j    fail
4:
    la   x19, 6b
    li   gp, 12
    bne  x18, x19, fail                  // the link address has to be right

    // ---- a chain of dependent operations across the whole pipeline ----
    li   x20, 1
    add  x21, x20, x20                   // 2
    add  x22, x21, x20                   // 3
    add  x23, x22, x21                   // 5
    add  x24, x23, x22                   // 8
    add  x25, x24, x23                   // 13
    TEST_EQ(13, x25, 13)

    // ---- a store and a load to the same address, back to back ----
    li   x26, -1
    sd   x26, 40(x10)
    ld   x27, 40(x10)
    TEST_EQ(14, x27, -1)
    sw   x0, 40(x10)
    ld   x28, 40(x10)
    TEST_EQ(15, x28, 0xFFFFFFFF00000000)

    // ---- the operand of an instruction that waits for the cache ----
    //
    // The address of the load comes from the instruction two in front. While
    // the store in between sits in MA the load waits in EX, and by then the
    // instruction that produced the address has left the pipeline: EX has to
    // keep the value it was given.
    li   x11, 0x5A5A5A5A
    addi x12, x10, 48                    // the address
    sd   x11, 0(x10)                     // holds EX back
    ld   x13, 0(x12)                     // its address must survive the wait
    li   gp, 16
    bne  x13, x0, fail                   // scratch + 48 is still zero
    sd   x11, 48(x10)
    addi x14, x10, 48
    sd   x11, 0(x10)
    ld   x15, 0(x14)
    TEST_EQ(17, x15, 0x5A5A5A5A)

    // ---- the data of a store that waits for the cache ----
    li   x16, 0x77
    ld   x17, 0(x10)                     // holds EX back
    sd   x16, 56(x10)                    // its data must survive the wait
    ld   x18, 56(x10)
    TEST_EQ(18, x18, 0x77)

    TEST_DONE
    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0, 0, 0, 0, 0

    TOHOST_SECTION
