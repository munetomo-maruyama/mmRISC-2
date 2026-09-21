// t12_priv : supervisor and user mode, delegation, SRET
//
// The official rv64si tests stay in supervisor mode and never reach user
// mode, the delegation of an interrupt or the traps that the T bits of
// mstatus are there for. This one walks M -> S -> U and back.
//
//   x29 / x28 / x27 / x26 : a machine trap happened, its cause, tval, epc
//   x19 / x22 / x21 / x20 : the same for a supervisor trap
//   x24 : where the machine handler resumes (0 : behind the instruction)
//   x23 : if not zero, the machine handler sets MPP to x23[1:0] before MRET
//   x18 : where the supervisor handler resumes (0 : behind the instruction)
//   x17 : if not zero, the supervisor handler sets SPP to x17[0] before SRET
#include "test.h"
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
    li   x29, 0
    li   x19, 0
    li   x24, 0
    li   x23, 0
    li   x18, 0
    li   x17, 0

    // misa has to advertise S and U now
    csrr x10, misa
    srli x11, x10, 18
    andi x11, x11, 1
    TEST_EQ(1, x11, 1)                   // 'S'
    srli x11, x10, 20
    andi x11, x11, 1
    TEST_EQ(2, x11, 1)                   // 'U'

    //-----------------------------------------------------------------
    // into supervisor mode
    //-----------------------------------------------------------------
    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11                     // MPP = S
    csrs mstatus, t0
    la   t0, in_s1
    csrw mepc, t0
    mret
    j    fail                            // MRET has to leave

    //-----------------------------------------------------------------
    // supervisor mode, nothing delegated yet
    //-----------------------------------------------------------------
in_s1:
    // an ECALL from S is cause 9 and goes to machine mode
    li   x29, 0
    ecall
    TEST_EQ(3, x29, 1)
    TEST_EQ(4, x28, 9)

    // a machine CSR is not readable here
    li   x29, 0
    csrr x11, mstatus
    TEST_EQ(5, x29, 1)
    TEST_EQ(6, x28, 2)                   // illegal instruction

    // ... and neither is it writable
    li   x29, 0
    csrw mscratch, x0
    TEST_EQ(7, x29, 1)
    TEST_EQ(8, x28, 2)

    // sstatus is the same register as mstatus seen through a mask
    li   x12, (1 << 18) | (1 << 19)      // SUM and MXR
    csrs sstatus, x12
    csrr x13, sstatus
    and  x13, x13, x12
    TEST_EQ_REG(9, x13, x12)
    csrc sstatus, x12
    csrr x13, sstatus
    and  x13, x13, x12
    TEST_EQ(10, x13, 0)

    // MRET is a machine instruction
    li   x29, 0
    mret
    TEST_EQ(11, x29, 1)
    TEST_EQ(12, x28, 2)

    // SFENCE.VMA is allowed in S while TVM is clear
    li   x29, 0
    sfence.vma
    TEST_EQ(13, x29, 0)

    // back to machine mode
    la   x24, back_in_m
    li   x23, 4 | 3                      // not zero, MPP = M
    ecall
    j    fail

    //-----------------------------------------------------------------
    // machine mode again : turn the delegation on
    //-----------------------------------------------------------------
back_in_m:
    li   t0, (1 << 8) | (1 << 9)         // ECALL from U and from S
    csrw medeleg, t0
    csrr x10, medeleg
    TEST_EQ_REG(14, x10, t0)

    // ECALL from M can never be delegated
    li   t0, 1 << 11
    csrs medeleg, t0
    csrr x10, medeleg
    srli x10, x10, 11
    andi x10, x10, 1
    TEST_EQ(15, x10, 0)

    // only the three supervisor interrupts can be delegated
    li   t0, -1
    csrw mideleg, t0
    csrr x10, mideleg
    TEST_EQ(16, x10, 0x222)
    csrw mideleg, x0

    // TVM makes SFENCE.VMA and satp trap in supervisor mode
    li   t0, 1 << 20
    csrs mstatus, t0

    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s2
    csrw mepc, t0
    mret

    //-----------------------------------------------------------------
    // supervisor mode with the delegation on
    //-----------------------------------------------------------------
in_s2:
    // TVM : SFENCE.VMA and satp are caught by machine mode
    li   x29, 0
    sfence.vma
    TEST_EQ(17, x29, 1)
    TEST_EQ(18, x28, 2)

    li   x29, 0
    csrr x11, satp
    TEST_EQ(19, x29, 1)
    TEST_EQ(20, x28, 2)

    // now ECALL from S stays in supervisor mode
    li   x29, 0
    li   x19, 0
    la   x16, 1f
    ecall
1:
    TEST_EQ(21, x19, 1)                  // the supervisor handler ran
    TEST_EQ(22, x29, 0)                  // ... and the machine one did not
    TEST_EQ(23, x22, 9)                  // ECALL from S
    la   x16, 1b
    addi x16, x16, -4
    TEST_EQ_REG(24, x20, x16)            // sepc is the ECALL itself

    //-----------------------------------------------------------------
    // into user mode
    //-----------------------------------------------------------------
    li   t0, 1 << 8
    csrc sstatus, t0                     // SPP = U
    la   t0, in_u
    csrw sepc, t0
    sret
    j    fail

in_u:
    // an ECALL from U is cause 8 and is delegated to S
    li   x29, 0
    li   x19, 0
    ecall
    TEST_EQ(25, x19, 1)
    TEST_EQ(26, x29, 0)
    TEST_EQ(27, x22, 8)

    // a supervisor CSR is out of reach from user mode, and that trap is not
    // delegated, so it goes all the way to machine mode
    li   x29, 0
    li   x19, 0
    csrr x11, sstatus
    TEST_EQ(28, x29, 1)
    TEST_EQ(29, x19, 0)
    TEST_EQ(30, x28, 2)

    // SRET is not a user instruction either
    li   x29, 0
    sret
    TEST_EQ(31, x29, 1)
    TEST_EQ(32, x28, 2)

    // the counters are closed while mcounteren says so
    li   x29, 0
    csrr x11, cycle
    TEST_EQ(33, x29, 1)
    TEST_EQ(34, x28, 2)

    // back to machine mode: an illegal instruction is not delegated
    la   x24, back_in_m2
    li   x23, 4 | 3
    csrr x11, sstatus
    j    fail

    //-----------------------------------------------------------------
    // machine mode : what the trap from user mode left behind
    //-----------------------------------------------------------------
back_in_m2:
    // the trap before this one came from user mode, so MPP was U
    TEST_EQ(35, x25, 0)

    // mcounteren opens cycle for supervisor mode, scounteren for user mode
    li   t0, 1
    csrw mcounteren, t0
    csrw scounteren, x0
    li   t0, 1 << 1                      // delegate the supervisor software
    csrw mideleg, t0                     // interrupt and enable it
    csrw mie, t0
    li   t0, 1 << 20
    csrc mstatus, t0                     // TVM off again
    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s3
    csrw mepc, t0
    mret

in_s3:
    li   x29, 0
    csrr x11, cycle                      // mcounteren bit 0 is set
    TEST_EQ(36, x29, 0)

    //-----------------------------------------------------------------
    // a delegated software interrupt
    //-----------------------------------------------------------------
    li   x29, 0
    li   x19, 0
    csrsi sstatus, 2                     // SIE
    // sip.SSIP is writable from S when the interrupt is delegated, and
    // machine mode set mideleg and mie.SSIE on the way in
    la   x18, 2f                         // the handler resumes here
    csrsi sip, 2
    nop
2:
    TEST_EQ(37, x19, 1)                  // the supervisor handler ran
    TEST_EQ(38, x29, 0)
    li   t0, 1
    slli t0, t0, 63
    ori  t0, t0, 1                       // interrupt, cause 1
    TEST_EQ_REG(39, x22, t0)

    // and it is gone once the handler cleared it
    csrr x11, sip
    andi x11, x11, 2
    TEST_EQ(40, x11, 0)

    // Leave supervisor mode for the last time. ECALL from S is delegated by
    // now, so it would not reach machine mode; an illegal instruction is not
    // delegated and does.
    la   x24, done_in_m
    li   x23, 4 | 3
    csrr x11, mstatus
    j    fail

done_in_m:
    la   t0, default_trap
    csrw mtvec, t0
    TEST_DONE

    //-----------------------------------------------------------------
    // machine trap handler
    //-----------------------------------------------------------------
    .align 2
m_trap:
    csrr x28, mcause
    csrr x27, mtval
    csrr x26, mepc
    csrr x25, mstatus
    srli x25, x25, 11
    andi x25, x25, 3                     // MPP : where the trap came from
    li   x29, 1
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
    csrr x22, scause
    csrr x21, stval
    csrr x20, sepc
    li   x19, 1
    csrci sip, 2                         // an interrupt would come straight back
    beq  x17, x0, 1f
    li   t0, 1 << 8
    csrc sstatus, t0
    andi t0, x17, 1
    slli t0, t0, 8
    csrs sstatus, t0
    li   x17, 0
1:
    bne  x18, x0, 2f
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    sret
2:
    csrw sepc, x18
    li   x18, 0
    sret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0

    TOHOST_SECTION
