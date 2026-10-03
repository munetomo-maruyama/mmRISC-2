// t24_predict : branches across a fetch word, and the return address stack
//
// The branch predictor is transparent -- the execute stage corrects every
// wrong guess -- so what is checked here, besides the results, is the
// clock. Each part is run next to a reference with the same instructions
// whose branches a predictor without these features already gets right,
// and may take at most a quarter longer than it (a broken predictor takes
// 1.5 to 2.7 times as long). Measuring against a reference in the same run
// keeps the check valid under the back pressure of `make stress`. The
// cycles are left at BENCH_SLOT (+bench prints them): part, reference, ...
//
//   1 a loop whose 32 bit bne begins in the last parcel of a fetch word
//     and ends in the next one, predicted through the tail entry on the
//     second word (CPU_CORE_SPEC.md 4.2). Reference: the same loop with
//     the bne inside a word
//   2 the same kind of branch, `bnez sp`, whose upper half 0x0001 is a
//     c.nop: once it has been learned as taken, the program jumps straight
//     to that c.nop. The tail entry must not be used then -- the word was
//     jumped into, not reached from the one before -- or every jump costs
//     a refetch of a "predicted" c.nop. Reference: the same jump into a copy
//     of the word whose branch was never taken
//   3 one function called from two places in turn: its return goes to two
//     addresses, which only the return address stack gets right.
//     Reference: each caller has a function of its own, called through t1
//     (not a link register, so the stack has no part in it)
//   4 g calls h, and after h has returned, a branch in g goes one way or
//     the other after the bits of a constant, which no history predicts:
//     the mispredictions restore the fetch side's stack from the execute
//     stage's, which must still hold g's return. (It went the other way
//     every time until the gshare table learned that pattern, 2026-10.)
//     Reference: the same through t1 / t2
//   5 recursion twelve deep, deeper than the stack: the result must still
//     be right
//   6 a branch that is taken every other time, which only the global
//     history of the gshare table (CPU_CORE_SPEC.md 4.2) gets right: a
//     counter of its own is wrong half the time. A branch that is never
//     taken, and so never has an entry, sits in the loop too: neither side
//     of the history may count it. Reference: the same instructions without
//     the branches, written out 200 times, which no prediction can slow
//     down (the loop's own reference would suffer from a broken history as
//     much as the loop itself)
//   7 one jalr (not a call, not a return) that goes to A ten times and
//     then to B ninety times: the entry must follow the new target.
//     Reference: two jalr, each always to the same place, and callees of
//     its own (their returns would otherwise have learned part 7's)
//
// Built with the C extension (MARCH_t24_predict); .option norvc keeps the
// assembler from compressing, and the c.nop are written out as halfwords so
// that every instruction sits where the comments say (and norelax keeps
// the linker from moving them).
#include "test.h"

#define C_NOP  .2byte 0x0001

// fail with check n unless part <= reference * 5 / 4
#define WITHIN(n, part, ref)        \
    srli x22, ref, 2;               \
    add  x22, x22, ref;             \
    li   gp, n;                     \
    bgtu part, x22, fail;

// the same, unless part <= reference * 9 / 8
#define WITHIN8(n, part, ref)       \
    srli x22, ref, 3;               \
    add  x22, x22, ref;             \
    li   gp, n;                     \
    bgtu part, x22, fail;

    .option norvc
    .option norelax
    .section .text.init
    .globl _start
_start:
    TEST_INIT
    li   sp, 0x8000f000

    //--------------------------------------------------------------
    // 1 a loop on a branch across the word
    //--------------------------------------------------------------
    li   x10, 0
    li   x11, 200
    csrr x20, mcycle
    j    1f
    .balign 8
1:  addi x10, x10, 1                  // word + 0
    C_NOP                             // word + 4
    bne  x10, x11, 1b                 // word + 6 .. + 9
    csrr x21, mcycle
    sub  x24, x21, x20
    BENCH_MARK(0, x24)
    TEST_EQ(1, x10, 200)

    // reference: three instructions, the bne inside a word
    li   x10, 0
    csrr x20, mcycle
    j    1f
    .balign 8
1:  addi x10, x10, 1                  // word + 0
    nop                               // word + 4
    bne  x10, x11, 1b                 // word + 8
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(1, x25)
    TEST_EQ(2, x10, 200)
    WITHIN(3, x24, x25)

    //--------------------------------------------------------------
    // 2 jumping into the word behind a branch across the word
    //--------------------------------------------------------------
    li   x12, 0                       // through the c.nop at word + 8
    li   x13, 0                       // taken branch
    la   x14, w2
    li   x16, 20
    // learn the branch as taken
3:  jalr ra, 0(x14)
    addi x16, x16, -1
    bnez x16, 3b
    TEST_EQ(4, x13, 20)
    // now straight into its upper half
    addi x15, x14, 8
    li   x16, 20
    csrr x20, mcycle
4:  jalr ra, 0(x15)
    addi x16, x16, -1
    bnez x16, 4b
    csrr x21, mcycle
    sub  x24, x21, x20
    BENCH_MARK(2, x24)
    TEST_EQ(5, x12, 20)
    TEST_EQ(6, x13, 20)

    // reference: the same into the copy, whose branch was never taken
    la   x15, w2r + 8
    li   x16, 20
    csrr x20, mcycle
4:  jalr ra, 0(x15)
    addi x16, x16, -1
    bnez x16, 4b
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(3, x25)
    TEST_EQ(7, x12, 40)
    WITHIN(8, x24, x25)

    //--------------------------------------------------------------
    // 3 one function, two callers
    //--------------------------------------------------------------
    // (each call in a word of its own: the buffer keeps one branch per
    // word, and two calls in one word would take turns being predicted)
    li   x17, 0
    li   x16, 100
    csrr x20, mcycle
    j    5f
    .balign 8
5:  jal  ra, f3                       // caller A
    nop
    jal  ra, f3                       // caller B
    nop
    addi x16, x16, -1
    bnez x16, 5b
    csrr x21, mcycle
    sub  x24, x21, x20
    BENCH_MARK(4, x24)
    TEST_EQ(9, x17, 200)

    // reference: each caller with a function of its own, through t1
    li   x17, 0
    li   x16, 100
    csrr x20, mcycle
    j    5f
    .balign 8
5:  jal  t1, f3a                      // caller A
    nop
    jal  t1, f3b                      // caller B
    nop
    addi x16, x16, -1
    bnez x16, 5b
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(5, x25)
    TEST_EQ(10, x17, 200)
    WITHIN(11, x24, x25)

    //--------------------------------------------------------------
    // 4 a misprediction between two returns
    //--------------------------------------------------------------
    li   x18, 0
    li   x16, 100
    li   x29, 0x9E3779B97F4A7C15
    csrr x20, mcycle
    j    5f
    .balign 8
5:  jal  ra, g4
    addi x16, x16, -1
    bnez x16, 5b
    csrr x21, mcycle
    sub  x24, x21, x20
    BENCH_MARK(6, x24)
    TEST_EQ(12, x18, 158)             // h: 100, g's branch: 58 ones

    // reference: the same through t1 / t2
    li   x18, 0
    li   x16, 100
    li   x29, 0x9E3779B97F4A7C15
    csrr x20, mcycle
    j    5f
    .balign 8
5:  jal  t1, g4r
    addi x16, x16, -1
    bnez x16, 5b
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(7, x25)
    TEST_EQ(13, x18, 158)
    // a stack that the mispredictions leave wrong costs some 16 % here
    // (with or without back pressure); right, part and reference are equal
    WITHIN8(14, x24, x25)

    //--------------------------------------------------------------
    // 5 deeper than the stack
    //--------------------------------------------------------------
    li   a0, 12
    jal  ra, rec
    TEST_EQ(15, a0, 78)               // 12 + 11 + ... + 1

    //--------------------------------------------------------------
    // 6 taken every other time
    //--------------------------------------------------------------
    li   x26, 1
    jal  ra, alt6
    BENCH_MARK(8, x25)
    mv   x24, x25
    TEST_EQ(16, x19, 100)
    // reference: written out, no branch at all
    li   x10, 0
    li   x19, 0
    csrr x20, mcycle
    .rept 200
    and  x23, x10, x26
    nop
    nop
    nop
    addi x19, x19, 1
    nop
    addi x10, x10, 1
    .endr
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(9, x25)
    TEST_EQ(17, x19, 200)
    WITHIN(18, x24, x25)

    //--------------------------------------------------------------
    // 7 one jalr, a new target
    //--------------------------------------------------------------
    li   x17, 0
    csrr x20, mcycle
    la   x28, f7a
    li   x16, 10
    jal  ra, call7
    la   x28, f7b
    li   x16, 90
    jal  ra, call7
    csrr x21, mcycle
    sub  x24, x21, x20
    BENCH_MARK(10, x24)
    TEST_EQ(19, x17, 10 + 90 * 16)
    // reference: each target its own jalr
    li   x17, 0
    csrr x20, mcycle
    la   x28, f7ra
    li   x16, 10
    jal  ra, call7a
    la   x28, f7rb
    li   x16, 90
    jal  ra, call7b
    csrr x21, mcycle
    sub  x25, x21, x20
    BENCH_MARK(11, x25)
    TEST_EQ(20, x17, 10 + 90 * 16)
    WITHIN(21, x24, x25)

    TEST_DONE

    // 200 rounds; the branch is taken when x10 & x26 is 0. Out: x25 the
    // cycles, x19 the rounds that fell through. The branches are in words
    // of their own (one entry per word).
    .balign 8
alt6:
    li   x10, 0
    li   x11, 200
    li   x19, 0
    csrr x20, mcycle
    j    1f
    .balign 8
1:  and  x23, x10, x26                // word A
    bltz x10, fail                    // word A + 4 : never taken
    beqz x23, 2f                      // word B
    nop
    addi x19, x19, 1                  // word C, the fall through
    nop
2:  addi x10, x10, 1                  // word D
    bne  x10, x11, 1b
    csrr x21, mcycle
    sub  x25, x21, x20
    ret

    // part 7: x16 calls through x28 from one jalr (t1 is not a link
    // register, so neither the call nor the return is one for the stack)
    .balign 8
call7:
    .balign 8
1:  jalr t1, 0(x28)
    addi x16, x16, -1
    bnez x16, 1b
    ret
    .balign 8
call7a:
    .balign 8
1:  jalr t1, 0(x28)
    addi x16, x16, -1
    bnez x16, 1b
    ret
    .balign 8
call7b:
    .balign 8
1:  jalr t1, 0(x28)
    addi x16, x16, -1
    bnez x16, 1b
    ret
    .balign 8
f7a:
    addi x17, x17, 1
    jalr x0, 0(t1)
    .balign 8
f7b:
    addi x17, x17, 16
    jalr x0, 0(t1)
    // the reference's own, so that their returns always go to one place
    .balign 8
f7ra:
    addi x17, x17, 1
    jalr x0, 0(t1)
    .balign 8
f7rb:
    addi x17, x17, 16
    jalr x0, 0(t1)

    //--------------------------------------------------------------
    // part 2: the word with the branch across it, and its copy
    //--------------------------------------------------------------
    .balign 8
w2: C_NOP                             // word + 0
    C_NOP                             // word + 2
    C_NOP                             // word + 4
    bnez sp, 6f                       // word + 6: 0x00011663, upper half c.nop
    addi x12, x12, 1                  // word + 10
    jalr x0, 0(ra)                    // word + 14
6:  addi x13, x13, 1                  // word + 18
    jalr x0, 0(ra)

    .balign 8
w2r:C_NOP
    C_NOP
    C_NOP
    bnez sp, 6f
    addi x12, x12, 1
    jalr x0, 0(ra)
6:  addi x13, x13, 1
    jalr x0, 0(ra)

    // part 3
    .balign 8
f3: addi x17, x17, 1
    jalr x0, 0(ra)
    .balign 8
f3a:addi x17, x17, 1
    jalr x0, 0(t1)
    .balign 8
f3b:addi x17, x17, 1
    jalr x0, 0(t1)

    // part 4: g calls h, then a branch on the low bit of the count
    .balign 8
g4: addi sp, sp, -16
    sd   ra, 0(sp)
    jal  ra, h4
    srl  x19, x29, x16                // bit x16 of the constant
    andi x19, x19, 1
    beqz x19, 1f
    addi x18, x18, 1
1:  ld   ra, 0(sp)
    addi sp, sp, 16
    jalr x0, 0(ra)
    .balign 8
h4: addi x18, x18, 1
    jalr x0, 0(ra)

    .balign 8
g4r:addi sp, sp, -16
    sd   t1, 0(sp)
    jal  t2, h4r
    srl  x19, x29, x16
    andi x19, x19, 1
    beqz x19, 1f
    addi x18, x18, 1
1:  ld   t1, 0(sp)
    addi sp, sp, 16
    jalr x0, 0(t1)
    .balign 8
h4r:addi x18, x18, 1
    jalr x0, 0(t2)

    // part 4: rec(n) = n + rec(n - 1), rec(0) = 0
rec:
    beqz a0, 7f
    addi sp, sp, -16
    sd   ra, 0(sp)
    sd   a0, 8(sp)
    addi a0, a0, -1
    jal  ra, rec
    ld   x23, 8(sp)
    add  a0, a0, x23
    ld   ra, 0(sp)
    addi sp, sp, 16
7:  jalr x0, 0(ra)

    TEST_FAIL_HANDLER

    TOHOST_SECTION
