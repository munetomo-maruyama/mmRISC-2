// t15_plic : the platform level interrupt controller, seen from a program
//
// tb_PLIC drives the register port directly. This one goes the whole way:
// a line is raised in a register of the test bench, the PLIC turns it into
// an external interrupt of the core, the handler claims it, completes it,
// and comes back.
//
//   0x0C000000 + 4*s            priority of source s
//   0x0C002000 + 0x80*c         enable word 0 of context c
//   0x0C200000 + 0x1000*c       threshold of context c
//   0x0C200000 + 0x1000*c + 4   claim on read, complete on write
//   0x03000008                  the source lines, one bit each (test bench)
//
//   context 0 is machine mode, context 1 supervisor mode
//
//   x29 : a trap happened     x28 : mcause      x26 : interrupts counted
//   x22 : the sources that were claimed, one byte each, most recent last
//   x20 / x21 : the same for the supervisor handler
#include "test.h"

#define PLIC_PRIO0    0x0C000000
#define PLIC_ENABLE0  0x0C002000
#define PLIC_ENABLE1  0x0C002080
#define PLIC_THRESH0  0x0C200000
#define PLIC_CLAIM0   0x0C200004
#define PLIC_THRESH1  0x0C201000
#define PLIC_CLAIM1   0x0C201004
#define TBSRC         0x03000008

#define MIE_MEIE      (1 << 11)
#define MIE_SEIE      (1 << 9)
#define MSTATUS_MIE   (1 << 3)

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP
    la   t0, m_trap
    csrw mtvec, t0
    la   t0, s_trap
    csrw stvec, t0
    li   x29, 0
    li   x26, 0
    li   x22, 0
    li   x20, 0
    csrw medeleg, x0
    csrw mideleg, x0

    //-----------------------------------------------------------------
    // 1. nothing is pending after reset
    //-----------------------------------------------------------------
    li   x10, PLIC_CLAIM0
    lw   x11, 0(x10)
    TEST_EQ(1, x11, 0)

    //-----------------------------------------------------------------
    // 2. one source, from the line to the handler and back
    //-----------------------------------------------------------------
    li   x10, PLIC_PRIO0 + 4*3
    li   x11, 1
    sw   x11, 0(x10)                     // priority of source 3
    li   x10, PLIC_ENABLE0
    li   x11, 1 << 3
    sw   x11, 0(x10)                     // enabled for machine mode
    li   x10, PLIC_THRESH0
    sw   x0, 0(x10)

    li   t0, MIE_MEIE
    csrs mie, t0
    li   t0, MSTATUS_MIE
    csrs mstatus, t0

    li   x22, 0
    li   x26, 0
    li   x10, TBSRC
    li   x11, 1 << 3
    sw   x11, 0(x10)                     // raise the line
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(2, x26, 1)                   // one interrupt was taken
    TEST_EQ(3, x22, 3)                   // and it was source 3
    li   x12, 1                          // machine external interrupt
    slli x12, x12, 63
    ori  x12, x12, 11
    TEST_EQ_REG(4, x28, x12)

    li   x10, TBSRC                      // the handler cleared the line
    lw   x11, 0(x10)
    TEST_EQ(5, x11, 0)

    //-----------------------------------------------------------------
    // 3. two sources at once : the higher priority is served first
    //-----------------------------------------------------------------
    li   x10, PLIC_PRIO0 + 4*5
    li   x11, 2
    sw   x11, 0(x10)
    li   x10, PLIC_PRIO0 + 4*7
    li   x11, 6
    sw   x11, 0(x10)
    li   x10, PLIC_ENABLE0
    li   x11, (1 << 3) | (1 << 5) | (1 << 7)
    sw   x11, 0(x10)

    li   x22, 0
    li   x26, 0
    li   x10, TBSRC
    li   x11, (1 << 5) | (1 << 7)
    sw   x11, 0(x10)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(6, x26, 2)
    TEST_EQ(7, x22, 0x0705)              // source 7 first, then source 5

    //-----------------------------------------------------------------
    // 3b. two sources of the same priority : the lower number goes first
    //-----------------------------------------------------------------
    li   x10, PLIC_PRIO0 + 4*9
    li   x11, 3
    sw   x11, 0(x10)
    li   x10, PLIC_PRIO0 + 4*11
    li   x11, 3
    sw   x11, 0(x10)
    li   x10, PLIC_ENABLE0
    li   x11, (1 << 9) | (1 << 11)
    sw   x11, 0(x10)

    li   x22, 0
    li   x26, 0
    li   x10, TBSRC
    li   x11, (1 << 9) | (1 << 11)
    sw   x11, 0(x10)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(17, x26, 2)
    TEST_EQ(18, x22, 0x090B)             // source 9 first, then source 11

    li   x10, PLIC_ENABLE0               // put the enables back
    li   x11, (1 << 3) | (1 << 5) | (1 << 7)
    sw   x11, 0(x10)

    //-----------------------------------------------------------------
    // 4. the threshold holds a source back
    //-----------------------------------------------------------------
    li   x10, PLIC_THRESH0
    li   x11, 4
    sw   x11, 0(x10)                     // above the priority of source 5

    li   x22, 0
    li   x26, 0
    li   x10, TBSRC
    li   x11, 1 << 5
    sw   x11, 0(x10)
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(8, x26, 0)                   // nothing was taken
    li   x10, PLIC_CLAIM0
    lw   x11, 0(x10)
    TEST_EQ(9, x11, 0)                   // and nothing can be claimed

    li   x10, PLIC_THRESH0               // let it through
    sw   x0, 0(x10)
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(10, x26, 1)
    TEST_EQ(11, x22, 5)

    //-----------------------------------------------------------------
    // 4b. a priority equal to the threshold does not get through
    //-----------------------------------------------------------------
    li   x10, PLIC_THRESH0
    li   x11, 2
    sw   x11, 0(x10)                     // source 5 has priority 2 as well
    li   x22, 0
    li   x26, 0
    li   x10, TBSRC
    li   x11, 1 << 5
    sw   x11, 0(x10)
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(20, x26, 0)                  // equal is not above

    li   x10, PLIC_THRESH0
    li   x11, 1
    sw   x11, 0(x10)                     // now the priority is above it
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(21, x26, 1)
    TEST_EQ(22, x22, 5)
    li   x10, PLIC_THRESH0
    sw   x0, 0(x10)

    //-----------------------------------------------------------------
    // 4c. reading the threshold is not a claim, and a completion from a
    //     context that has not enabled the source is ignored
    //-----------------------------------------------------------------
    li   t0, MSTATUS_MIE
    csrc mstatus, t0                     // keep the handler out of the way

    li   x10, TBSRC
    li   x11, 1 << 3
    sw   x11, 0(x10)
    nop
    nop
    nop
    li   x10, PLIC_THRESH0
    lw   x12, 0(x10)                     // a read next to the claim register
    TEST_EQ(23, x12, 0)
    li   x10, PLIC_CLAIM0
    lw   x11, 0(x10)
    TEST_EQ(24, x11, 3)                  // it was still there to be claimed

    li   x10, PLIC_CLAIM1                // context 1 never enabled source 3
    li   x11, 3
    sw   x11, 0(x10)
    nop
    nop
    nop
    li   x10, PLIC_CLAIM0
    lw   x11, 0(x10)
    TEST_EQ(25, x11, 0)                  // so the gateway is still shut

    li   x10, TBSRC                      // drop the line, then complete
    sw   x0, 0(x10)
    nop
    nop
    li   x10, PLIC_CLAIM0
    li   x11, 3
    sw   x11, 0(x10)
    nop
    nop
    nop
    lw   x11, 0(x10)
    TEST_EQ(26, x11, 0)                  // nothing is left

    li   t0, MSTATUS_MIE
    csrs mstatus, t0

    //-----------------------------------------------------------------
    // 5. the supervisor context is a different one
    //-----------------------------------------------------------------
    li   t0, MIE_SEIE                    // delegate and enable
    csrs mideleg, t0
    csrs mie, t0

    li   x10, PLIC_PRIO0 + 4*4
    li   x11, 1
    sw   x11, 0(x10)
    li   x10, PLIC_ENABLE1               // only context 1 gets source 4
    li   x11, 1 << 4
    sw   x11, 0(x10)
    li   x10, PLIC_THRESH1
    sw   x0, 0(x10)

    // machine mode must not see it: source 4 is not in its enable word
    li   x26, 0
    li   x10, TBSRC
    li   x11, 1 << 4
    sw   x11, 0(x10)
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(12, x26, 0)

    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s
    csrw mepc, t0
    mret

in_s:
    li   x20, 0
    csrsi sstatus, 2                     // SIE : the line is already up
    nop
    nop
    nop
    nop
    nop
    nop
    TEST_EQ(13, x20, 1)                  // the supervisor handler ran
    TEST_EQ(14, x21, 4)                  // and claimed source 4
    TEST_EQ(15, x26, 0)                  // machine mode never saw it

    li   x10, PLIC_CLAIM1                // nothing is left for it
    lw   x11, 0(x10)
    TEST_EQ(16, x11, 0)

    // back to machine mode; ECALL from S is not delegated here
    la   x24, done_in_m
    li   x23, 4 | 3
    ecall

done_in_m:
    csrw mie, x0
    csrw mideleg, x0
    la   t0, default_trap
    csrw mtvec, t0
    TEST_DONE

    //-----------------------------------------------------------------
    // machine trap handler
    //-----------------------------------------------------------------
    .align 2
m_trap:
    csrr x28, mcause
    li   x29, 1

    li   t0, 1
    slli t0, t0, 63
    ori  t0, t0, 11
    bne  x28, t0, m_not_ext

    li   t0, PLIC_CLAIM0
    lw   x27, 0(t0)                      // claim
    li   t1, 1
    sll  t1, t1, x27                     // drop that line in the bench
    not  t1, t1
    li   t0, TBSRC
    lw   t2, 0(t0)
    and  t2, t2, t1
    sw   t2, 0(t0)
    li   t0, PLIC_CLAIM0
    sw   x27, 0(t0)                      // complete

    slli x22, x22, 8
    or   x22, x22, x27
    addi x26, x26, 1
    mret

m_not_ext:
    // an exception : step over it, or go where x24 says, with MPP from x23
    beq  x23, x0, 1f
    li   t0, 3 << 11
    csrc mstatus, t0
    andi t0, x23, 3
    slli t0, t0, 11
    csrs mstatus, t0
    li   x23, 0
1:
    bne  x24, x0, 2f
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
2:
    csrw mepc, x24
    li   x24, 0
    mret

    //-----------------------------------------------------------------
    // supervisor trap handler
    //-----------------------------------------------------------------
    .align 2
s_trap:
    csrr t0, scause
    li   t1, 1
    slli t1, t1, 63
    ori  t1, t1, 9
    bne  t0, t1, fail                    // only the external one is expected

    li   t0, PLIC_CLAIM1
    lw   x21, 0(t0)
    li   t1, 1
    sll  t1, t1, x21
    not  t1, t1
    li   t0, TBSRC
    lw   t2, 0(t0)
    and  t2, t2, t1
    sw   t2, 0(t0)
    li   t0, PLIC_CLAIM1
    sw   x21, 0(t0)

    li   x20, 1
    sret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0

    TOHOST_SECTION
