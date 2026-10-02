// t25_lsu : accesses that go to the cache early from EX (CPU_CORE_SPEC.md 5)
//
// EX sends a load or store to the cache before MR knows whether it may go;
// MR then lets it go or takes it back, and what was taken back goes again
// from MA. This test sets up the cases where that can go wrong:
//
//   1 stores and loads in a row, some of the stores taken back (the one in
//     front waits in MA) and sent again from MA: a younger load must not
//     overtake them
//   2 an older load faults on the bus, in MA, while a younger load has
//     already gone from MR: its answer comes after the trap and must be
//     thrown away, not handed to the first load of the handler
//   3 the same older load, with an uncached load behind it that has a side
//     effect (the claim of the PLIC): it must not go before the older one
//     is known not to trap
//   4 the same, with a store behind it that the handler then skips: the
//     store must never have happened
//
// The older load reads BAD, which nothing answers but with a bus error, so
// it waits in MA for a few cycles and then takes a load access fault (5).
// The handler checks the cause, does the work of the part (x26 says which)
// and returns behind the faulting load, or behind the store too (x27).
#include "test.h"

#define BAD           0x70000000
#define PLIC_PRIO0    0x0C000000
#define PLIC_ENABLE0  0x0C002000
#define PLIC_THRESH0  0x0C200000
#define PLIC_CLAIM0   0x0C200004
#define TBSRC         0x03000008

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   t0, h_bad
    csrw mtvec, t0
    csrw mie, x0
    li   x25, BAD

    //--------------------------------------------------------------
    // 1 stores taken back, loads behind them
    //--------------------------------------------------------------
    la   x10, buf
    li   x11, 0x0101010101010101
    li   x12, 0x0202020202020202
    sd   x11, 0(x10)
    sd   x12, 8(x10)
    sd   x11, 16(x10)
    ld   x13, 0(x10)
    sd   x12, 0(x10)
    ld   x14, 0(x10)
    ld   x15, 8(x10)
    sb   x11, 1(x10)
    ld   x16, 0(x10)
    TEST_EQ(1, x13, 0x0101010101010101)
    TEST_EQ(2, x14, 0x0202020202020202)
    TEST_EQ(3, x15, 0x0202020202020202)
    TEST_EQ(4, x16, 0x0202020202020102)
    // an AMO in between
    li   x17, 5
    amoadd.d x18, x17, (x10)
    ld   x19, 0(x10)
    TEST_EQ(5, x18, 0x0202020202020102)
    TEST_EQ(6, x19, 0x0202020202020107)

    //--------------------------------------------------------------
    // 2 an answer in flight at a trap
    //--------------------------------------------------------------
    li   x26, 2
    li   x27, 4                       // return behind the faulting load
    la   x16, w1
    la   x18, w2
    li   x20, 0
    li   x23, 0
    ld   x20, 0(x25)                  // faults, in MA, some cycles later
    ld   x23, 0(x16)                  // has gone by then
    TEST_EQ(7, x17, 0x2222222222222222)   // the handler's own load
    TEST_EQ(8, x23, 0x1111111111111111)   // done again after the return

    //--------------------------------------------------------------
    // 3 an uncached load with a side effect behind a trap
    //--------------------------------------------------------------
    // source 3 pending at the PLIC, interrupts off
    li   x10, PLIC_PRIO0 + 4*3
    li   x11, 1
    sw   x11, 0(x10)
    li   x10, PLIC_ENABLE0
    li   x11, (1 << 3)
    sw   x11, 0(x10)
    li   x10, PLIC_THRESH0
    sw   x0, 0(x10)
    li   x10, TBSRC
    li   x11, (1 << 3)
    sw   x11, 0(x10)
    lw   x11, 0(x10)                  // the write has arrived
    li   x26, 3
    li   x27, 4
    li   x10, PLIC_CLAIM0
    li   x19, 0
    ld   x20, 0(x25)                  // faults
    lw   x19, 0(x10)                  // claims, but only once it may
    TEST_EQ(9, x19, 3)
    sw   x19, 0(x10)                  // complete
    li   x10, TBSRC
    sw   x0, 0(x10)
    lw   x11, 0(x10)

    //--------------------------------------------------------------
    // 4 a store behind a trap, skipped by the handler
    //--------------------------------------------------------------
    li   x26, 4
    li   x27, 8                       // return behind the store as well
    la   x10, w3
    li   x11, 0x0BAD0BAD0BAD0BAD
    ld   x20, 0(x25)                  // faults
    sd   x11, 0(x10)                  // skipped: must never write
    ld   x12, 0(x10)
    TEST_EQ(10, x12, 0x3333333333333333)

    TEST_DONE

    //--------------------------------------------------------------
    // the load of BAD faulted
    //--------------------------------------------------------------
h_bad:
    csrr t0, mcause
    li   t6, 5
    li   gp, 11
    bne  t0, t6, fail
    li   t6, 2
    bne  x26, t6, 1f
    ld   x17, 0(x18)                  // part 2: the first load of the handler
1:  csrr t0, mepc
    add  t0, t0, x27
    csrw mepc, t0
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
w1:  .dword 0x1111111111111111
w2:  .dword 0x2222222222222222
w3:  .dword 0x3333333333333333
buf: .dword 0, 0, 0, 0

    TOHOST_SECTION
