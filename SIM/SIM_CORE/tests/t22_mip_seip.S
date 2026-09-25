// t22_mip_seip : a read-modify-write of mip while the PLIC asks for S
//
// mip.SEIP reads as the OR of a bit software can write and the supervisor
// line of the PLIC. csrrs / csrrc must only modify the software bit: the
// line is not theirs to copy. OpenSBI does csrc mip, STIP (and csrs) on
// every machine timer interrupt; a core that took the value it read as the
// base copied a pending supervisor interrupt into the software bit, and
// SEIP then stayed up after the PLIC had dropped it. Linux on the Arty
// ended in an endless supervisor external interrupt with nothing to claim.
//
// Interrupts stay disabled (mie = 0), so nothing is taken; only mip is
// looked at. The test bench drives the S line from bit 1 of 0x03000000.
#include "test.h"

#define TB_IRQ_EXT  0x03000000
#define MIP_STIP    (1 << 5)
#define MIP_SEIP    (1 << 9)

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    csrw mie, x0
    li   x10, TB_IRQ_EXT

    // the line up : SEIP reads as 1
    li   x11, 2
    sw   x11, 0(x10)
    lw   x11, 0(x10)                      // the write has arrived
    csrr x12, mip
    srli x12, x12, 9
    andi x12, x12, 1
    TEST_EQ(1, x12, 1)

    // what OpenSBI does on a machine timer interrupt, with the line up
    li   t0, MIP_STIP
    csrs mip, t0
    csrc mip, t0
    li   t0, MIP_SEIP
    csrc mip, x0                          // (rs1 = x0 : no write at all)

    // the line down : SEIP must follow it
    sw   x0, 0(x10)
    lw   x11, 0(x10)
    csrr x12, mip
    srli x12, x12, 9
    andi x12, x12, 1
    TEST_EQ(2, x12, 0)

    // the software bit itself is still machine mode's to set and clear
    li   t0, MIP_SEIP
    csrs mip, t0
    csrr x12, mip
    srli x12, x12, 9
    andi x12, x12, 1
    TEST_EQ(3, x12, 1)
    csrc mip, t0
    csrr x12, mip
    srli x12, x12, 9
    andi x12, x12, 1
    TEST_EQ(4, x12, 0)

    // and a csrc of SEIP with the line up leaves the line visible
    li   x11, 2
    sw   x11, 0(x10)
    lw   x11, 0(x10)
    li   t0, MIP_SEIP
    csrc mip, t0
    csrr x12, mip
    srli x12, x12, 9
    andi x12, x12, 1
    TEST_EQ(5, x12, 1)
    sw   x0, 0(x10)
    lw   x11, 0(x10)
    csrr x12, mip
    srli x12, x12, 9
    andi x12, x12, 1
    TEST_EQ(6, x12, 0)

    TEST_DONE

    TEST_FAIL_HANDLER

    TOHOST_SECTION
