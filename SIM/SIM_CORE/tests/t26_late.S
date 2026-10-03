// t26_late : branches resolved in MR on the value of a load (CPU_CORE_SPEC.md
// decision 64, "late branch")
//
// A conditional branch that reads the register a load in MR is about to
// bring does not wait in EX: it goes on to MR with its prediction and is
// resolved there, with the answer of the load (then in MA). A wrong guess
// redirects from MR and throws away what is in EX. This test sets up:
//
//   1 every comparison, with the load in rs1, in rs2 and in both, the values
//     chosen so that signed and unsigned disagree. The first time a branch
//     is seen it is guessed not taken, so the taken cases are wrong guesses
//   2 the same branch guessed taken (trained) and then not taken
//   3 what sits in EX behind a wrong guess must leave no trace: a store, a
//     load from an address that would fault, a divide, a CSR write
//   4 a branch right behind a late branch (it waits in EX for the first)
//   5 the load faults: the trap wins, the branch is not resolved (the
//     handler returns to it, and it then sees the old value)
//   6 a loop whose taken branch sits right behind a late branch: it has to
//     wait for the late one, or the buffer only ever hears from the late
//     one and the loop branch is guessed wrong every time round.
//     Reference: the same loop with a nop that makes the first branch an
//     ordinary one (it may take at most a quarter longer than that)
//   7 a jalr through the register a load brings, right behind it: unlike a
//     branch it waits in EX (it needs the value for its target), and it
//     must not be decided before the load has answered
#include "test.h"

#define BAD 0x70000000

// branch op on a register loaded from addr and the value b: x14 = 1 when
// taken, 0 when not. pos 1: the load is rs1, 2: rs2, 3: both
#define LATE1(n, op, addr, b, expect)   \
    la   x11, addr;                     \
    li   x12, b;                        \
    ld   x13, 0(x11);                   \
    op   x13, x12, 1f;                  \
    li   x14, 0;                        \
    j    2f;                            \
1:  li   x14, 1;                        \
2:  TEST_EQ(n, x14, expect)

#define LATE2(n, op, addr, a, expect)   \
    la   x11, addr;                     \
    li   x12, a;                        \
    ld   x13, 0(x11);                   \
    op   x12, x13, 1f;                  \
    li   x14, 0;                        \
    j    2f;                            \
1:  li   x14, 1;                        \
2:  TEST_EQ(n, x14, expect)

#define LATE3(n, op, addr, expect)      \
    la   x11, addr;                     \
    ld   x13, 0(x11);                   \
    op   x13, x13, 1f;                  \
    li   x14, 0;                        \
    j    2f;                            \
1:  li   x14, 1;                        \
2:  TEST_EQ(n, x14, expect)

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   t0, h_bad
    csrw mtvec, t0

    //--------------------------------------------------------------
    // 1 every comparison (m1 = -1, p1 = 1, mn = most negative)
    //--------------------------------------------------------------
    LATE1( 2, beq,  m1, -1, 1)
    LATE1( 3, beq,  m1,  1, 0)
    LATE1( 4, bne,  m1,  1, 1)
    LATE1( 5, bne,  p1,  1, 0)
    LATE1( 6, blt,  m1,  1, 1)       // -1 < 1 signed
    LATE1( 7, bltu, m1,  1, 0)       // but not unsigned
    LATE1( 8, bge,  p1, -1, 1)
    LATE1( 9, bgeu, p1, -1, 0)
    LATE1(10, blt,  mn,  0, 1)
    LATE1(11, bge,  mn,  0, 0)
    LATE2(12, blt,  p1, -1, 1)       // -1 < (1)
    LATE2(13, bltu, p1, -1, 0)
    LATE2(14, bgeu, m1,  1, 0)       // 1 >= 0xff..ff unsigned : no
    LATE2(15, beq,  p1,  1, 1)
    LATE3(16, beq,  m1, 1)
    LATE3(17, bne,  m1, 0)
    LATE3(18, bge,  mn, 1)
    LATE3(19, bltu, p1, 0)

    //--------------------------------------------------------------
    // 2 trained taken, then not taken (and the other way)
    //--------------------------------------------------------------
    la   x11, seq                     // 1 1 1 1 1 1 0, then 0 0 0 0 0 0 1
    li   x15, 14
    li   x16, 0                       // taken count
    li   x17, 0                       // not taken count
3:  ld   x13, 0(x11)
    bnez x13, 4f
    addi x17, x17, 1
    j    5f
4:  addi x16, x16, 1
5:  addi x11, x11, 8
    addi x15, x15, -1
    bnez x15, 3b
    TEST_EQ(20, x16, 7)
    TEST_EQ(21, x17, 7)

    //--------------------------------------------------------------
    // 3 the wrong path in EX leaves nothing behind
    //--------------------------------------------------------------
    la   x11, z0                      // a zero: beqz is taken, guessed not
    la   x21, mark
    li   x20, 0x0BAD
    li   x22, BAD
    li   x23, 1000000007
    li   x24, 3
    csrw mscratch, x0
    li   x25, 0                       // the handler counts faults here
    ld   x13, 0(x11)
    beqz x13, 6f
    sd   x20, 0(x21)                  // in EX when the branch is resolved
    j    fail
6:  ld   x13, 0(x11)
    beqz x13, 7f
    ld   x26, 0(x22)                  // would fault
    j    fail
7:  ld   x13, 0(x11)
    beqz x13, 8f
    div  x27, x23, x24
    j    fail
8:  ld   x13, 0(x11)
    beqz x13, 9f
    csrw mscratch, x20
    j    fail
9:  ld   x10, 0(x21)
    TEST_EQ(22, x10, 0)               // no store
    TEST_EQ(23, x25, 0)               // no fault
    csrr x10, mscratch
    TEST_EQ(24, x10, 0)               // no CSR write
    // the divide unit is free again and right (another division than the
    // one thrown away, so that its answer cannot pass for this one)
    div  x27, x23, x20
    TEST_EQ(25, x27, 334560)

    //--------------------------------------------------------------
    // 4 a branch right behind a late branch
    //--------------------------------------------------------------
    li   x14, 0
    la   x11, z0
    li   x15, 1
    ld   x13, 0(x11)
    beqz x13, 10f                     // late, taken (guessed not)
    j    fail
10: ld   x13, 0(x11)
    bnez x13, fail                    // late, not taken
    beqz x15, fail                    // waits in EX for the one before
    addi x14, x14, 1
    ld   x13, 0(x11)
    bnez x13, fail
    bnez x15, 11f                     // taken, guessed not, behind a late one
    j    fail
11: addi x14, x14, 1
    TEST_EQ(26, x14, 2)

    //--------------------------------------------------------------
    // 5 the load faults under the branch
    //--------------------------------------------------------------
    li   x25, 0
    li   x13, 5                       // what the branch sees after the trap
    li   x22, BAD
    ld   x13, 0(x22)                  // access fault; the handler returns
    beqz x13, fail                    // here, and x13 is still 5
    TEST_EQ(27, x25, 1)

    //--------------------------------------------------------------
    // 6 a loop branch behind a late branch
    //--------------------------------------------------------------
    la   x11, z0
    li   x15, 100
    csrr x20, mcycle
    j    12f
    .balign 8
12: addi x15, x15, -1
    ld   x13, 0(x11)
    bnez x13, fail                    // late, never taken (no entry)
    bnez x15, 12b                     // in EX while the late one is in MR
    csrr x21, mcycle
    sub  x24, x21, x20
    BENCH_MARK(0, x24)
    li   x15, 100
    csrr x20, mcycle
    j    13f
    .balign 8
13: addi x15, x15, -1
    ld   x13, 0(x11)
    nop                               // the branch is an ordinary one
    bnez x13, fail
    bnez x15, 13b
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(1, x25)
    srli x22, x25, 2
    add  x22, x22, x25
    li   gp, 28
    bgtu x24, x22, fail

    //--------------------------------------------------------------
    // 7 a jalr on a loaded address
    //--------------------------------------------------------------
    li   x14, 0
    la   x11, ptr7
    ld   x13, 0(x11)
    jalr x0, 0(x13)
    j    fail
14: addi x14, x14, 1
    TEST_EQ(29, x14, 1)

    TEST_DONE

    // a load access fault: count it, go on behind the load
h_bad:
    csrr t0, mcause
    li   t6, 5
    li   gp, 90
    bne  t0, t6, fail
    addi x25, x25, 1
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
m1:   .dword -1
p1:   .dword 1
mn:   .dword 0x8000000000000000
z0:   .dword 0
mark: .dword 0
seq:  .dword 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1
ptr7: .dword 14b

    TOHOST_SECTION
