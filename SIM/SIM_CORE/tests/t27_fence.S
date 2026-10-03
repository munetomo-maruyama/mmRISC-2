// t27_fence : FENCE (CPU_CORE_SPEC.md 5.3)
//
// FENCE does nothing of its own: ID holds it until the pipeline is empty,
// and a pipeline is empty when every access in front of it has been
// answered (an uncached store only when the bus has answered the write).
// That is enough for one hart whose data cache also serves the DMA. The
// test bench checks the rule on every FENCE (fence_error_tb): when it
// leaves ID, nothing in front of it may still be in flight. This test
// puts FENCEs where that matters:
//
//   1 every encoding: FENCE with any predecessor / successor set,
//     FENCE.TSO, PAUSE (Zihintpause), and the reserved fields (rd, rs1,
//     fm) set, which have to be ignored: no trap, and rd is not written
//   2 right behind stores, behind a row of them, behind an uncached store
//     and an uncached load (mtimecmp of the CLINT, all ones: it never
//     fires, and interrupts are off)
//   3 as the first instruction of a trap handler, while the answer of a
//     load that went from MR before the trap (and is thrown away) may
//     still be on its way
#include "test.h"

#define MTIMECMP 0x02004000

    .section .text.init
    .globl _start
_start:
    TEST_INIT

    //--------------------------------------------------------------
    // 1 the encodings
    //--------------------------------------------------------------
    li   x10, 0x5A5A
    li   x11, 0x1234
    fence
    fence rw, rw
    fence w, o
    fence i, r
    fence r, rw
    .word 0x8330000f                  // fence.tso
    .word 0x0100000f                  // pause
    .word 0x0ff5850f                  // fence iorw, iorw with rd = x10, rs1 = x11
    .word 0x1ff0000f                  // fm = 0001 (reserved)
    TEST_EQ(2, x10, 0x5A5A)           // rd is not written
    TEST_EQ(3, x11, 0x1234)

    //--------------------------------------------------------------
    // 2 behind stores and uncached accesses
    //--------------------------------------------------------------
    la   x20, buf
    li   x21, 0x1111
    li   x22, 0x2222
    li   x23, 0x3333
    sd   x21, 0(x20)
    fence
    ld   x24, 0(x20)
    TEST_EQ(4, x24, 0x1111)
    sd   x21, 0(x20)
    sd   x22, 8(x20)
    sw   x23, 16(x20)
    sb   x21, 24(x20)
    fence w, w
    ld   x24, 8(x20)
    lw   x25, 16(x20)
    lbu  x26, 24(x20)
    TEST_EQ(5, x24, 0x2222)
    TEST_EQ(6, x25, 0x3333)
    TEST_EQ(7, x26, 0x11)
    li   x27, MTIMECMP
    li   x28, -1
    sd   x28, 0(x27)                  // uncached store
    fence w, o
    ld   x24, 0(x27)                  // uncached load
    fence i, r
    ld   x25, 0(x20)
    TEST_EQ(8, x24, -1)
    TEST_EQ(9, x25, 0x1111)
    // a store, then at once a load of the same word and a FENCE
    sd   x22, 0(x20)
    ld   x24, 0(x20)
    fence
    TEST_EQ(10, x24, 0x2222)

    //--------------------------------------------------------------
    // 3 a FENCE first thing in a trap handler
    //--------------------------------------------------------------
    la   t0, h_fence
    csrw mtvec, t0
    li   x28, 0
    ecall                             // traps in MA; the load behind it may
    ld   x24, 8(x20)                  //   have gone from MR already
    ecall
    sd   x23, 8(x20)
    ecall
    lw   x25, 0(x27)
    TEST_EQ(11, x28, 3)
    TEST_EQ(12, x24, 0x2222)

    TEST_DONE

h_fence:
    fence
    addi x28, x28, 1
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
buf: .dword 0, 0, 0, 0

    TOHOST_SECTION
