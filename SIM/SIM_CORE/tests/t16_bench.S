// t16_bench : a workload for measuring, not for finding bugs
//
// Three loops, each a thousand iterations, chosen for what they do to the
// front end:
//
//   1. a backward branch that is always taken, with straight line work in
//      between : the best case for a predictor
//   2. a call and a return every iteration : the return is a JALR, which a
//      branch target buffer can only get right while the call site does not
//      change
//   3. a branch whose direction comes from an LFSR : not predictable at all,
//      so the misprediction penalty shows up undiluted
//
// Each loop checks its own result, so the test is still a test; the number
// worth looking at is the cycle count the bench prints at the end.
#include "test.h"

#define N 1000

    .section .text.init
    .globl _start
_start:
    TEST_INIT

    //-----------------------------------------------------------------
    // 1. a loop that always branches back
    //-----------------------------------------------------------------
    csrr x23, mcycle
    li   x10, 0                          // sum
    li   x11, 0                          // i
    li   x12, N
1:
    slli x13, x11, 1
    add  x13, x13, x11                   // 3*i
    xor  x13, x13, x11
    add  x10, x10, x13
    addi x11, x11, 1
    blt  x11, x12, 1b
    csrr x24, mcycle
    sub  x25, x24, x23
    BENCH_MARK(0, x25)
    li   x20, 0x148CE8
    TEST_EQ_REG(1, x10, x20)

    //-----------------------------------------------------------------
    // 2. a call and a return every iteration
    //-----------------------------------------------------------------
    csrr x23, mcycle
    li   x14, 0
    li   x11, 0
2:
    mv   x15, x11
    jal  x1, helper
    add  x14, x14, x15
    addi x11, x11, 1
    blt  x11, x12, 2b
    csrr x24, mcycle
    sub  x25, x24, x23
    BENCH_MARK(1, x25)
    li   x20, 0xF4240
    TEST_EQ_REG(2, x14, x20)

    //-----------------------------------------------------------------
    // 3. a branch nobody can predict
    //-----------------------------------------------------------------
    csrr x23, mcycle
    li   x16, 0                          // sum
    li   x11, 0
    li   x17, 0x2345                     // the LFSR, sixteen bits
3:
    andi x18, x17, 1
    beq  x18, x0, 4f
    addi x16, x16, 3
    j    5f
4:
    addi x16, x16, 1
5:
    srli x19, x17, 1
    andi x21, x17, 1
    beq  x21, x0, 6f
    li   x22, 0xB400
    xor  x19, x19, x22
6:
    mv   x17, x19
    addi x11, x11, 1
    blt  x11, x12, 3b

    csrr x24, mcycle
    sub  x25, x24, x23
    BENCH_MARK(2, x25)
    li   x20, 0x7DA
    TEST_EQ_REG(3, x16, x20)
    li   x20, 0xFBF9
    TEST_EQ_REG(4, x17, x20)

    TEST_DONE

helper:
    slli x15, x15, 1
    addi x15, x15, 1
    jalr x0, x1, 0

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0

    TOHOST_SECTION
