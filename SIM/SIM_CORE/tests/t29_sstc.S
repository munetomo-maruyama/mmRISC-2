// t29_sstc : Sstc, menvcfg, senvcfg, mcountinhibit (CPU_CORE_SPEC.md
// decision 66)
//
//   1 the new CSRs exist and keep only their implemented fields: menvcfg
//     only STCE, senvcfg nothing, mcountinhibit CY, IR and HPM3-6; CY and IR
//     really stop mcycle and minstret
//   2 mip.STIP: with STCE clear the bit M mode writes, with STCE set
//     time >= stimecmp, and then a write of M mode does not change it
//   3 stimecmp from S mode: an illegal instruction unless both
//     menvcfg.STCE and mcounteren.TM are set
//   4 the supervisor timer interrupt from stimecmp, delegated, taken in S
//     mode; the handler moves stimecmp out and the interrupt goes away
//
//   x29 / x28 : a machine trap happened (count), its cause. The machine
//               handler steps over the instruction; an ECALL from S also
//               brings the hart back to M.
//   x19 / x20 : the same for a supervisor trap (the timer interrupt)
#include "test.h"

#define STIP   (1 << 5)
#define STCE   (1 << 63)
// by number: the assembler knows the names only with the extension in -march
#define SENVCFG       0x10a
#define STIMECMP      0x14d
#define MENVCFG       0x30a
#define MCOUNTINHIBIT 0x320

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP
    la   t0, m_trap
    csrw mtvec, t0
    la   t0, s_trap
    csrw stvec, t0
    csrw medeleg, x0
    csrw mideleg, x0
    csrw mie, x0
    li   x29, 0
    li   x19, 0

    //--------------------------------------------------------------
    // 1 the CSRs and their fields
    //--------------------------------------------------------------
    csrr x10, MENVCFG
    TEST_EQ(2, x10, 0)
    csrr x10, SENVCFG
    TEST_EQ(3, x10, 0)
    csrr x10, MCOUNTINHIBIT
    TEST_EQ(4, x10, 0)
    TEST_EQ(5, x29, 0)                // none of them trapped
    li   x11, -1
    csrw MENVCFG, x11
    csrr x10, MENVCFG
    li   x12, STCE
    TEST_EQ_REG(6, x10, x12)          // STCE alone
    csrw MENVCFG, x0
    csrr x10, MENVCFG
    TEST_EQ(7, x10, 0)
    csrw SENVCFG, x11
    csrr x10, SENVCFG
    TEST_EQ(8, x10, 0)
    csrw MCOUNTINHIBIT, x11
    csrr x10, MCOUNTINHIBIT
    TEST_EQ(9, x10, 0x7d)             // CY, IR and the four hpmcounters
    // CY stops mcycle (minstret goes on)
    li   x10, 1
    csrw MCOUNTINHIBIT, x10
    csrr x13, mcycle
    csrr x15, minstret
    nop
    nop
    nop
    csrr x14, mcycle
    csrr x16, minstret
    TEST_EQ_REG(10, x13, x14)
    li   gp, 11
    beq  x15, x16, fail
    // IR stops minstret (mcycle goes on)
    li   x10, 4
    csrw MCOUNTINHIBIT, x10
    csrr x13, mcycle
    csrr x15, minstret
    nop
    nop
    nop
    csrr x14, mcycle
    csrr x16, minstret
    TEST_EQ_REG(12, x15, x16)
    li   gp, 13
    beq  x13, x14, fail
    csrw MCOUNTINHIBIT, x0
    csrr x13, mcycle
    nop
    csrr x14, mcycle
    li   gp, 14
    beq  x13, x14, fail               // counts again

    //--------------------------------------------------------------
    // 2 mip.STIP
    //--------------------------------------------------------------
    li   x12, STIP
    csrs mip, x12                     // STCE clear: written by M
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(15, x10, STIP)
    csrc mip, x12
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(16, x10, 0)
    li   x11, STCE
    csrs MENVCFG, x11                 // STCE set: the comparison
    li   x13, -1
    csrw STIMECMP, x13
    nop
    nop
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(17, x10, 0)
    csrs mip, x12                     // a write of M mode does not count
    nop
    nop
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(18, x10, 0)
    csrw STIMECMP, x0                 // time >= 0
    nop
    nop
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(19, x10, STIP)
    csrr x10, STIMECMP
    TEST_EQ(20, x10, 0)
    csrw STIMECMP, x13
    nop
    nop
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(21, x10, 0)
    // STCE clear again: the bit M wrote while it was set did not stick
    csrc MENVCFG, x11
    csrr x10, mip
    and  x10, x10, x12
    TEST_EQ(22, x10, 0)

    //--------------------------------------------------------------
    // 3 stimecmp from S mode
    //--------------------------------------------------------------
    csrs MENVCFG, x11                 // STCE set, TM clear
    csrw mcounteren, x0
    la   t0, s3a
    jal  ra, to_s
s3a:
    li   x29, 0
    csrr x10, STIMECMP                // illegal
    mv   x21, x29
    mv   x22, x28
    ecall                             // back to M
    TEST_EQ(23, x21, 1)
    TEST_EQ(24, x22, 2)
    li   x10, 2                       // TM set, STCE clear
    csrw mcounteren, x10
    csrc MENVCFG, x11
    la   t0, s3b
    jal  ra, to_s
s3b:
    li   x29, 0
    csrr x10, STIMECMP                // illegal
    mv   x21, x29
    ecall
    TEST_EQ(25, x21, 1)
    csrs MENVCFG, x11                 // both set
    la   t0, s3c
    jal  ra, to_s
s3c:
    li   x29, 0
    li   x10, 0x123456789
    csrw STIMECMP, x10
    csrr x23, STIMECMP
    mv   x21, x29
    ecall
    TEST_EQ(26, x21, 0)
    TEST_EQ(27, x23, 0x123456789)

    //--------------------------------------------------------------
    // 4 the supervisor timer interrupt from stimecmp
    //--------------------------------------------------------------
    li   x10, STIP
    csrw mideleg, x10
    li   x10, -1
    csrw STIMECMP, x10
    la   t0, s4
    jal  ra, to_s
s4:
    li   x19, 0
    li   x10, STIP
    csrs sie, x10
    csrsi sstatus, 2                  // SIE
    rdtime x10
    addi x10, x10, 200
    csrw STIMECMP, x10
    li   x24, 100000
1:  bnez x19, 2f
    addi x24, x24, -1
    bnez x24, 1b
2:  csrci sstatus, 2
    csrr x25, sip
    ecall
    TEST_EQ(28, x19, 1)               // taken once
    li   x10, (1 << 63) | 5
    TEST_EQ_REG(29, x20, x10)         // supervisor timer interrupt
    andi x25, x25, STIP
    TEST_EQ(30, x25, 0)               // gone with stimecmp moved out

    TEST_DONE

    // MRET to the address in t0, in S mode
to_s:
    li   t6, 3 << 11
    csrc mstatus, t6
    li   t6, 1 << 11
    csrs mstatus, t6
    csrw mepc, t0
    mret

m_trap:
    csrr x28, mcause
    addi x29, x29, 1
    li   t6, 9                        // an ECALL from S: back to M
    bne  x28, t6, 1f
    li   t6, 3 << 11
    csrs mstatus, t6
1:  csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

s_trap:
    csrr x20, scause
    addi x19, x19, 1
    li   t6, -1
    csrw STIMECMP, t6                 // the interrupt goes away
    sret

    TEST_FAIL_HANDLER
    TOHOST_SECTION
