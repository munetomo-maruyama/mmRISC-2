// t11_fp : the F and D extensions as the core sees them
//
// The arithmetic itself is checked against SoftFloat in SIM_FPU and by the
// official rv64uf / rv64ud tests. What this one is for is everything around
// it: mstatus.FS, the NaN boxing on the load path, fcsr and the rounding
// mode, the store data coming out of the floating point file, and the
// hazards between the FPU and the rest of the pipeline.
#include "test.h"

#define MSTATUS_FS 0x6000

    .section .text.init
    .globl _start
_start:
    TEST_INIT

    // ---- with FS off every FP instruction is illegal ----
    la   x10, skip_trap
    csrw mtvec, x10
    li   x11, MSTATUS_FS
    csrc mstatus, x11                    // FS = Off
    li   x29, 0
    fmv.w.x f0, x0
    TEST_EQ(1, x29, 1)
    TEST_EQ(2, x28, 2)                   // illegal instruction
    li   x29, 0
    csrr x12, fcsr                       // the FP CSRs are gone as well
    TEST_EQ(3, x29, 1)

    // ---- switching it on makes them work, and marks the state dirty ----
    csrs mstatus, x11                    // FS = Dirty
    li   x29, 0
    fmv.w.x f0, x0
    TEST_EQ(4, x29, 0)
    csrr x13, mstatus
    srli x13, x13, 13
    andi x13, x13, 3
    TEST_EQ(5, x13, 3)
    la   x10, default_trap
    csrw mtvec, x10

    // ---- moves between the two register files ----
    li   x10, 0x0123456789ABCDEF
    fmv.d.x f1, x10
    fmv.x.d x11, f1
    TEST_EQ_REG(6, x11, x10)

    li   x12, 0xFFFFFFFF80000000
    fmv.w.x f2, x12                      // a single is boxed on the way in
    fmv.x.w x13, f2
    TEST_EQ(7, x13, 0xFFFFFFFF80000000)  // and sign extended on the way out
    fmv.x.d x14, f2
    TEST_EQ(8, x14, 0xFFFFFFFF80000000)  // the box is visible as a double

    // ---- the load path boxes a single ----
    la   x15, scratch
    li   x16, 0x3F800000                 // 1.0f
    sw   x16, 0(x15)
    flw  f3, 0(x15)
    fmv.x.d x17, f3
    TEST_EQ(9, x17, 0xFFFFFFFF3F800000)

    li   x16, 0x3FF0000000000000         // 1.0
    sd   x16, 8(x15)
    fld  f4, 8(x15)
    fmv.x.d x18, f4
    TEST_EQ_REG(10, x18, x16)

    // ---- the store path takes the data out of the FP file ----
    fsw  f3, 16(x15)
    lw   x19, 16(x15)
    TEST_EQ(11, x19, 0x3F800000)
    fsd  f4, 24(x15)
    ld   x20, 24(x15)
    TEST_EQ(12, x20, 0x3FF0000000000000)

    // ---- a value that is not boxed reads as the canonical NaN ----
    li   x21, 0x0000000012345678
    fmv.d.x f5, x21
    fadd.s f6, f5, f5
    fmv.x.w x22, f6
    TEST_EQ(13, x22, 0x7FC00000)        // FMV.X.W sign extends from bit 31

    // ---- arithmetic, and the result reaching the next instruction ----
    li   x10, 0x4008000000000000         // 3.0
    fmv.d.x f7, x10
    li   x11, 0x4010000000000000         // 4.0
    fmv.d.x f8, x11
    fadd.d f9, f7, f8
    fmv.x.d x12, f9
    TEST_EQ(14, x12, 0x401C000000000000) // 7.0
    fmul.d f10, f7, f8
    fmv.x.d x13, f10
    TEST_EQ(15, x13, 0x4028000000000000) // 12.0
    fsub.d f11, f8, f7
    fmv.x.d x14, f11
    TEST_EQ(16, x14, 0x3FF0000000000000) // 1.0
    fdiv.d f12, f8, f7
    fmadd.d f13, f7, f8, f7              // 3*4 + 3 = 15
    fmv.x.d x15, f13
    TEST_EQ(17, x15, 0x402E000000000000)

    li   x16, 0x4010000000000000         // 4.0
    fmv.d.x f14, x16
    fsqrt.d f15, f14
    fmv.x.d x17, f15
    TEST_EQ(18, x17, 0x4000000000000000) // 2.0

    // ---- comparisons and classify go to an integer register ----
    feq.d x18, f7, f7
    TEST_EQ(19, x18, 1)
    flt.d x19, f7, f8
    TEST_EQ(20, x19, 1)
    fle.d x20, f8, f7
    TEST_EQ(21, x20, 0)
    fclass.d x21, f7
    TEST_EQ(22, x21, 0x40)               // positive normal

    // ---- conversions ----
    li   x22, -5
    fcvt.d.l f16, x22
    fcvt.l.d x23, f16
    TEST_EQ(23, x23, -5)
    fcvt.s.d f17, f16                    // -5.0 as a single
    fmv.x.w x24, f17
    TEST_EQ(24, x24, 0xFFFFFFFFC0A00000)
    fcvt.d.s f18, f17
    fmv.x.d x25, f18
    TEST_EQ(25, x25, 0xC014000000000000)

    // ---- the rounding mode comes from frm when rm is dynamic ----
    la   x10, scratch
    li   x11, 0x3FF8000000000000         // 1.5
    fmv.d.x f19, x11
    csrwi frm, 1                         // towards zero
    fcvt.l.d x12, f19                    // the instruction says dynamic
    TEST_EQ(26, x12, 1)
    csrwi frm, 3                         // towards plus infinity
    fcvt.l.d x13, f19
    TEST_EQ(27, x13, 2)
    csrwi frm, 0

    // the mode written into the instruction wins over frm
    csrwi frm, 1
    fcvt.l.d x14, f19, rup
    TEST_EQ(28, x14, 2)
    csrwi frm, 0

    // ---- the flags pile up in fflags ----
    csrwi fflags, 0
    li    x15, 0x3FF0000000000000        // 1.0
    fmv.d.x f20, x15
    li    x16, 0x4008000000000000        // 3.0
    fmv.d.x f21, x16
    fdiv.d f22, f20, f21                 // 1/3 is inexact
    csrr  x17, fflags
    TEST_EQ(29, x17, 1)                  // NX

    fmv.d.x f23, x0                      // +0
    fdiv.d f24, f20, f23                 // 1/0
    csrr  x18, fflags
    TEST_EQ(30, x18, 9)                  // NX from before, and DZ

    csrwi fflags, 0
    fsqrt.d f25, f11                     // f11 is 1.0, exact
    csrr  x19, fflags
    TEST_EQ(31, x19, 0)

    li    x20, 0xBFF0000000000000        // -1.0
    fmv.d.x f26, x20
    fsqrt.d f27, f26                     // the root of a negative number
    csrr  x21, fflags
    TEST_EQ(32, x21, 0x10)               // NV

    // fcsr holds both halves
    csrwi fflags, 0
    csrwi frm, 2
    csrr  x22, fcsr
    TEST_EQ(33, x22, 0x40)
    csrwi frm, 0

    // ---- an operand that comes straight out of the cache ----
    //
    // The unit takes several cycles and latches what it is given at the
    // start, so it must not start while the load in front of it is still
    // waiting for the cache.
    csrwi fflags, 0
    li    x23, 0x4008000000000000        // 3.0
    sd    x23, 32(x10)
    li    x24, 0x4010000000000000        // 4.0
    sd    x24, 40(x10)
    fld   f28, 32(x10)
    fld   f29, 40(x10)
    fmul.d f30, f28, f29                 // reads both, right behind the loads
    fmv.x.d x25, f30
    TEST_EQ(34, x25, 0x4028000000000000) // 12.0

    fld   f28, 32(x10)
    fadd.d f31, f28, f28                 // one cycle behind the load
    fmv.x.d x26, f31
    TEST_EQ(35, x26, 0x4018000000000000) // 6.0

    // the same for the integer unit, which has the same shape
    li    x27, 7
    sd    x27, 48(x10)
    ld    x28, 48(x10)
    mul   x29, x28, x28
    TEST_EQ(36, x29, 49)
    ld    x28, 48(x10)
    div   x30, x28, x28
    TEST_EQ(37, x30, 1)

    // ---- a chain of dependent FP instructions ----
    li    x11, 0x3FF0000000000000        // 1.0
    fmv.d.x f0, x11
    fadd.d f1, f0, f0                    // 2
    fadd.d f2, f1, f0                    // 3
    fadd.d f3, f2, f1                    // 5
    fmul.d f4, f3, f2                    // 15
    fmv.x.d x12, f4
    TEST_EQ(38, x12, 0x402E000000000000)

    // ---- round to nearest breaks a tie towards even ----
    csrwi frm, 0
    li   x11, 0x3FE0000000000000         // 0.5
    fmv.d.x f5, x11
    fcvt.l.d x13, f5
    TEST_EQ(39, x13, 0)
    li   x11, 0x3FF8000000000000         // 1.5
    fmv.d.x f5, x11
    fcvt.l.d x13, f5
    TEST_EQ(40, x13, 2)
    li   x11, 0x4004000000000000         // 2.5
    fmv.d.x f5, x11
    fcvt.l.d x13, f5
    TEST_EQ(41, x13, 2)

    // a sum that lands exactly halfway goes to the even neighbour
    li   x19, 0x4330000000000000         // 2^52, where one ulp is one
    fmv.d.x f9, x19
    li   x20, 0x3FE0000000000000         // 0.5
    fmv.d.x f10, x20
    fadd.d f11, f9, f10
    fmv.x.d x21, f11
    TEST_EQ(44, x21, 0x4330000000000000)
    li   x20, 0x3FF8000000000000         // 1.5
    fmv.d.x f10, x20
    fadd.d f11, f9, f10
    fmv.x.d x21, f11
    TEST_EQ(45, x21, 0x4330000000000002)

    // ---- underflow is reported ----
    csrwi fflags, 0
    li   x14, 1                          // the smallest subnormal
    fmv.d.x f6, x14
    li   x15, 0x4000000000000000         // 2.0
    fmv.d.x f7, x15
    fdiv.d f8, f6, f7                    // half of it: tiny and inexact
    csrr x16, fflags
    TEST_EQ(42, x16, 3)                  // UF and NX

    // ---- mstatus.FS reads back what was written ----
    li   x17, MSTATUS_FS
    csrc mstatus, x17
    csrr x18, mstatus
    srli x18, x18, 13
    andi x18, x18, 3
    TEST_EQ(43, x18, 0)
    csrs mstatus, x17

    // ---- the third read port of the FP file, at several distances ----
    //
    // Forwarding covers the two instructions in front; one further back the
    // write and the read of the register file happen in the same cycle.
    li   x10, 0x3FF0000000000000         // 1.0
    fmv.d.x f0, x10
    li   x10, 0x4000000000000000         // 2.0
    fmv.d.x f1, x10

    fadd.d f5, f0, f0                    // 2.0
    nop
    nop
    fmadd.d f6, f1, f1, f5               // 2*2 + 2
    fmv.x.d x11, f6
    TEST_EQ(46, x11, 0x4018000000000000) // 6.0

    fadd.d f5, f0, f1                    // 3.0
    nop
    nop
    nop
    fmadd.d f7, f1, f1, f5               // 4 + 3
    fmv.x.d x12, f7
    TEST_EQ(47, x12, 0x401C000000000000) // 7.0

    fadd.d f5, f1, f1                    // 4.0
    nop
    nop
    nop
    nop
    fmadd.d f8, f1, f1, f5               // 4 + 4
    fmv.x.d x13, f8
    TEST_EQ(48, x13, 0x4020000000000000) // 8.0

    TEST_DONE

    .align 2
skip_trap:
    csrr x28, mcause
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    li   x29, 1
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0, 0, 0, 0, 0

    TOHOST_SECTION
