// t33_fpipe : the pipelined FPU in the core (CPU_CORE_SPEC.md 10.11)
//
//   1 sixteen independent FMADD.D back to back: one a cycle (the whole
//     run, with the FPU drained by the CSR read behind it, in under 40
//     cycles; the unit of before took 10 cycles for each). Run twice and
//     the second one measured: the first fetches the code, which with the
//     caches of SIM_SYS (and their stalls) is not what is measured
//   2 a chain of dependent operations, the last one's integer answer
//     (FCVT.L.D) straight into an ADDI, and read again later (from the
//     register file's bank the FPU wrote, not from its bypass)
//   3 FSD of the answer of the operation just in front
//   4 a register the FPU still owes written by FLD right behind (FDIV,
//     then FADD): the load is the younger and must win
//   5 an integer register the FPU owes written by an integer instruction
//     right behind; FMV.X.D straight into a branch, FEQ.D into an address
//   6 FRFLAGS right behind the operation that raised the flag
//   7 an FADD behind a load that traps: taken back, it must count once when
//     the handler returns to it (its operand is loaded well before, so that
//     nothing holds it in EX: it is in MR, P0 of the FPU, when the trap is
//     taken). Then FENCE.I behind a store that puts a new instruction in
//     place of the FADD behind it: the old FADD, fetched before the store,
//     is in P0 when FENCE.I empties the pipeline and must be taken back
//     (a flush that is not a trap, the one way P0 is taken back on its
//     own: a trap takes back P1 as well, and with it whatever moves there)
//   8 integer -> double -> integer back to back
//   9 operations behind a divide wait for it and are right
//  10 an FADD in the shadow of a late branch (on the value of a load, taken
//     but guessed not taken): thrown away, it must not count
//  11 FP operations right behind loads: while MA waits for the memory the
//     operation stands in MR and P0 of the FPU must wait with it
//  12 FLD and then a use of the register 1 ... 5 instructions behind: one
//     of them reads the file in ID in the cycle the load writes it in WB
#include "test.h"

#define MSTATUS_FS 0x6000

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    li   t0, MSTATUS_FS
    csrs mstatus, t0
    la   x10, data
    fld  f0,  0(x10)                      // 1.0
    fld  f1,  8(x10)                      // 2.0
    fld  f2, 16(x10)                      // 3.0
    fld  f30, 24(x10)                     // 7.0

    //--------------------------------------------------------------
    // 1 one a cycle
    //--------------------------------------------------------------
    li   x26, 2
2:  csrr x20, mcycle
    fmadd.d f8,  f1, f2, f0
    fmadd.d f9,  f1, f2, f0
    fmadd.d f10, f1, f2, f0
    fmadd.d f11, f1, f2, f0
    fmadd.d f12, f1, f2, f0
    fmadd.d f13, f1, f2, f0
    fmadd.d f14, f1, f2, f0
    fmadd.d f15, f1, f2, f0
    fmadd.d f16, f1, f2, f0
    fmadd.d f17, f1, f2, f0
    fmadd.d f18, f1, f2, f0
    fmadd.d f19, f1, f2, f0
    fmadd.d f20, f1, f2, f0
    fmadd.d f21, f1, f2, f0
    fmadd.d f22, f1, f2, f0
    fmadd.d f23, f1, f2, f0
    csrr x21, mcycle
    addi x26, x26, -1
    bnez x26, 2b
    sub  x21, x21, x20
    li   gp, 2
    li   t6, 40
    bgeu x21, t6, fail
    feq.d x12, f8, f30
    TEST_EQ(3, x12, 1)
    feq.d x12, f16, f30
    TEST_EQ(4, x12, 1)
    feq.d x12, f23, f30
    TEST_EQ(5, x12, 1)

    //--------------------------------------------------------------
    // 2 a chain, and its integer answer straight into an ADDI
    //--------------------------------------------------------------
    fadd.d  f24, f1, f1                   // 4
    fmul.d  f25, f24, f24                 // 16
    fadd.d  f26, f25, f0                  // 17
    fcvt.l.d x13, f26
    addi    x14, x13, 1
    TEST_EQ(6, x14, 18)
    TEST_EQ(23, x13, 17)                  // read again later, from the file:
    li      t6, 17                        // as rs1 and as rs2
    li      gp, 24
    bne     t6, x13, fail

    //--------------------------------------------------------------
    // 3 FSD of the answer just in front
    //--------------------------------------------------------------
    fmul.d  f27, f2, f2                   // 9
    fsd     f27, 32(x10)
    ld      x15, 32(x10)
    TEST_EQ(7, x15, 0x4022000000000000)

    //--------------------------------------------------------------
    // 4 FLD behind an operation that writes the same register
    //--------------------------------------------------------------
    fdiv.d  f28, f1, f2
    fld     f28, 0(x10)                   // 1.0 must win
    feq.d   x16, f28, f0
    TEST_EQ(8, x16, 1)
    fadd.d  f29, f1, f2
    fld     f29, 8(x10)                   // 2.0 must win
    feq.d   x16, f29, f1
    TEST_EQ(9, x16, 1)

    //--------------------------------------------------------------
    // 5 the integer side
    //--------------------------------------------------------------
    fcvt.l.d x17, f2                      // 3 ...
    li      x17, 5                        // ... and then 5
    TEST_EQ(10, x17, 5)
    fmv.x.d x18, f1                       // the bits of 2.0, into a branch
    li      t6, 0x4000000000000000
    li      gp, 11
    bne     x18, t6, fail
    feq.d   x19, f0, f0                   // 1, into an address
    slli    x19, x19, 3
    add     x19, x19, x10
    ld      x19, 0(x19)                   // data[1]
    TEST_EQ(12, x19, 0x4000000000000000)

    //--------------------------------------------------------------
    // 6 the flags right behind
    //--------------------------------------------------------------
    fld     f4, 40(x10)                   // 0.0
    csrw    fflags, x0
    fdiv.d  f3, f1, f4                    // divide by zero
    frflags x20
    TEST_EQ(13, x20, 0x08)

    //--------------------------------------------------------------
    // 7 taken back behind a trap
    //--------------------------------------------------------------
    fld     f5, 0(x10)                    // 1.0
    la      t0, skip_trap
    csrw    mtvec, t0
    ld      x21, 1(x10)                   // misaligned: the handler goes on behind it
    fadd.d  f5, f5, f0                    // 2.0, once
    la      t0, default_trap
    csrw    mtvec, t0
    feq.d   x22, f5, f1
    TEST_EQ(14, x22, 1)
    lw      t1, new_insn                  // FADD.D f6, f1, f0 ...
    la      t0, smc
    sw      t1, 0(t0)                     // ... over the FADD at smc
    fmv.d   f6, f0                        // 1.0
    .balign 4
    fence.i
smc:
    fadd.d  f5, f5, f0                    // fetched before the store: gone
    feq.d   x22, f5, f1                   // f5 still 2.0
    TEST_EQ(21, x22, 1)
    fadd.d  f31, f1, f0                   // 3.0
    feq.d   x22, f6, f31                  // the new instruction ran
    TEST_EQ(22, x22, 1)

    //--------------------------------------------------------------
    // 8 integer -> double -> integer
    //--------------------------------------------------------------
    li      x23, -7
    fcvt.d.l f6, x23
    fcvt.l.d x24, f6
    addi    x24, x24, 10
    TEST_EQ(15, x24, 3)

    //--------------------------------------------------------------
    // 9 behind a divide
    //--------------------------------------------------------------
    fdiv.d  f7, f2, f1                    // 1.5
    fadd.d  f9, f0, f0                    // 2.0, waits for the divide
    fsub.d  f10, f7, f0                   // 0.5
    fld     f31, 48(x10)                  // 0.5
    feq.d   x25, f10, f31
    TEST_EQ(16, x25, 1)
    feq.d   x25, f9, f1
    TEST_EQ(17, x25, 1)

    //--------------------------------------------------------------
    // 10 in the shadow of a late branch
    //--------------------------------------------------------------
    fld     f6, 0(x10)                    // 1.0
    ld      x26, 40(x10)                  // 0.0 as bits: 0
    beq     x26, x0, 1f                   // taken, on the load just in front
    fadd.d  f6, f6, f0                    // never
    fadd.d  f6, f6, f0
1:  feq.d   x27, f6, f0                   // still 1.0
    TEST_EQ(18, x27, 1)

    //--------------------------------------------------------------
    // 11 right behind loads
    //--------------------------------------------------------------
    li      x28, 8
    fmv.d   f12, f0                       // 1.0
3:  ld      x29, 0(x10)
    fadd.d  f12, f12, f0                  // + 1.0
    ld      x29, 8(x10)
    fmul.d  f13, f1, f2                   // 6.0, independent
    addi    x28, x28, -1
    bnez    x28, 3b
    fcvt.l.d x29, f12
    TEST_EQ(19, x29, 9)
    fcvt.l.d x29, f13
    TEST_EQ(20, x29, 6)

    //--------------------------------------------------------------
    // 12 an FP register read in ID as FLD writes it in WB (the write
    //    first bypass of the file), at every distance
    //--------------------------------------------------------------
    li      gp, 25
    .irp gap, 1, 2, 3, 4, 5
    fmv.d   f7, f0                        // 1.0, then the load
    fsd     f2, 56(x10)                   // 3.0
    fld     f7, 56(x10)
    .rept \gap
    addi    x31, x31, 1
    .endr
    fadd.d  f8, f7, f0                    // 4.0 if the load is seen
    fadd.d  f9, f2, f0                    // 4.0
    feq.d   x30, f8, f9
    beqz    x30, fail
    .endr

    TEST_DONE

    .balign 4
new_insn:
    fadd.d  f6, f1, f0                    // never run here: copied to smc

skip_trap:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

    TEST_FAIL_HANDLER

    .section .data
    .balign 8
data:
    .double 1.0, 2.0, 3.0, 7.0
    .dword  0                             // 32 : FSD writes here
    .double 0.0                           // 40
    .double 0.5                           // 48
    .dword  0                             // 56 : and here

    TOHOST_SECTION
