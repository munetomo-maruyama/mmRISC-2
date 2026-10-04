// t30_trig : Sdtrig, triggers of type 2 (mcontrol) that raise a breakpoint
// exception (action 0) (CPU_CORE_SPEC.md decision 67). Debug mode
// (dmode, action 1) is the business of t23_debug, whose debugger sets them.
//
//   1 the CSRs: tinfo (type 2 only), tdata3 (0), tselect (0..3, a larger
//     value is not taken), tdata1 (type 2 whatever type is written; dmode
//     and action 1 not from the program; the fields that exist read back),
//     tdata2 of each trigger its own, tcontrol (MTE, MPTE)
//   2 an execute trigger in M mode: nothing while tcontrol.MTE is clear;
//     with it set a breakpoint exception in front of the instruction
//     (mepc = mtval = its address), hit set, MTE cleared and MPTE set by
//     the trap and MTE put back by MRET; a trigger on the handler itself
//     does not fire there
//   3 load and store triggers: the access does not happen (a load does not
//     write its register, a store does not write memory), mtval is the
//     address; exact address only; a load trigger is blind to stores and
//     the other way round; an AMO is both; the breakpoint comes before the
//     misaligned address of the same access; hit only on the trigger that
//     fired
//   4 the m / s / u bits, in S and U mode (where tcontrol.MTE does not
//     matter)
//   5 nothing on a path that is thrown away: an instruction behind a
//     mispredicted branch, an instruction and a load behind an ECALL
//   6 an execute trigger comes before the illegal instruction exception
//   7 compressed instructions: a trigger on the second half of a word
//     fires on the instruction there, not on the one in front of it
//
//   x29 : traps (count), x28 / x27 / x26 / x24 : mcause, mtval, mepc and
//   tcontrol at the last one. The handler goes on at mepc + x30 (4, or 8 to
//   step over the instruction behind an ECALL as well); an ECALL from S or
//   U also brings the hart back to M.
#include "test.h"

#define TSELECT  0x7a0
#define TDATA1   0x7a1
#define TDATA2   0x7a2
#define TDATA3   0x7a3
#define TINFO    0x7a4
#define TCONTROL 0x7a5

#define T2   0x2000000000000000           // type 2
#define TM   0x40
#define TS   0x10
#define TU   0x08
#define TX   0x04                         // execute
#define TST  0x02                         // store
#define TLD  0x01                         // load
#define HIT  (1 << 20)

// p4a in U or S mode (to_u / to_s), back in M behind it
#define RUN_P4A(to)             \
    li   x21, 0;                \
    li   x29, 0;                \
    la   t0, p4a;               \
    jal  ra, to;

// trigger n: tdata2 first, so that it never fires on the old address
#define SET_TRIG(n, cfg, areg)  \
    csrwi TSELECT, n;           \
    csrw TDATA1, x0;            \
    csrw TDATA2, areg;          \
    li   t6, cfg;               \
    csrw TDATA1, t6;

#define CLR_TRIG(n)             \
    csrwi TSELECT, n;           \
    csrw TDATA1, x0;

// x10 = hit of trigger n
#define GET_HIT(n)              \
    csrwi TSELECT, n;           \
    csrr x10, TDATA1;           \
    srli x10, x10, 20;          \
    andi x10, x10, 1;

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP
    la   t0, m_trap
    csrw mtvec, t0
    csrw medeleg, x0
    csrw mideleg, x0
    csrw mie, x0
    li   x29, 0
    li   x30, 4

    //--------------------------------------------------------------
    // 1 the CSRs
    //--------------------------------------------------------------
    csrr x10, TINFO
    TEST_EQ(2, x10, 4)
    csrr x10, TDATA3
    TEST_EQ(3, x10, 0)
    csrr x10, TCONTROL
    TEST_EQ(4, x10, 0)
    li   x11, 3
    csrw TSELECT, x11
    csrr x10, TSELECT
    TEST_EQ(5, x10, 3)
    li   x11, 4                           // no trigger 4: tselect stays
    csrw TSELECT, x11
    csrr x10, TSELECT
    TEST_EQ(6, x10, 3)
    li   x11, -1                          // type 15: not there, all off
    csrw TDATA1, x11
    csrr x10, TDATA1
    li   x12, T2
    TEST_EQ_REG(7, x10, x12)
    li   x11, 0x2fffffffffffffff          // dmode, action 15, every field
    csrw TDATA1, x11
    csrr x10, TDATA1
    li   x12, T2 | HIT | TM | TS | TU | TX | TST | TLD
    TEST_EQ_REG(8, x10, x12)
    li   x11, T2 | 0x1000 | TU            // action 1 without dmode: 0
    csrw TDATA1, x11
    csrr x10, TDATA1
    li   x12, T2 | TU
    TEST_EQ_REG(9, x10, x12)
    csrw TDATA1, x0
    TEST_EQ(10, x29, 0)                   // none of them trapped
    // tdata2 of each trigger
    li   x13, 0
1:  csrw TSELECT, x13
    addi x11, x13, 0x100
    csrw TDATA2, x11
    addi x13, x13, 1
    li   x11, 4
    blt  x13, x11, 1b
    li   x13, 3
1:  csrw TSELECT, x13
    csrr x10, TDATA2
    addi x11, x13, 0x100
    li   gp, 11
    bne  x10, x11, fail
    addi x13, x13, -1
    bgez x13, 1b
    li   x11, -1
    csrw TCONTROL, x11
    csrr x10, TCONTROL
    TEST_EQ(12, x10, 0x88)
    csrw TCONTROL, x0
    csrr x10, TCONTROL
    TEST_EQ(13, x10, 0)

    //--------------------------------------------------------------
    // 2 an execute trigger in M mode
    //--------------------------------------------------------------
    la   x12, p2a
    SET_TRIG(0, T2 | TM | TX, x12)
    li   x13, 0
p2a:addi x13, x0, 5                       // MTE clear: runs
    TEST_EQ(14, x29, 0)
    TEST_EQ(15, x13, 5)
    GET_HIT(0)
    TEST_EQ(16, x10, 0)
    csrsi TCONTROL, 8                     // MTE
    la   x12, p2b
    csrw TDATA2, x12
    li   x13, 0
p2b:addi x13, x0, 5                       // breakpoint, stepped over
    TEST_EQ(17, x29, 1)
    TEST_EQ(18, x28, 3)
    TEST_EQ_REG(19, x27, x12)
    TEST_EQ_REG(20, x26, x12)
    TEST_EQ(21, x13, 0)
    TEST_EQ(22, x24, 0x80)                // in the handler: MPTE, no MTE
    csrr x10, TCONTROL
    TEST_EQ(23, x10, 0x88)                // MRET put MTE back
    GET_HIT(0)
    TEST_EQ(24, x10, 1)
    csrr x10, TDATA1                      // the program clears hit
    li   x11, ~HIT
    and  x10, x10, x11
    csrw TDATA1, x10
    GET_HIT(0)
    TEST_EQ(25, x10, 0)
    CLR_TRIG(0)
    // a trigger on the handler: MTE is clear there
    la   x12, m_trap
    SET_TRIG(1, T2 | TM | TX, x12)
    li   x29, 0
    ecall
    TEST_EQ(26, x29, 1)
    TEST_EQ(27, x28, 11)
    GET_HIT(1)
    TEST_EQ(28, x10, 0)
    CLR_TRIG(1)

    //--------------------------------------------------------------
    // 3 load and store triggers (M mode, MTE set)
    //--------------------------------------------------------------
    la   x14, buf
    li   x29, 0
    SET_TRIG(1, T2 | TM | TLD, x14)
    li   x15, 0x77
p3a:ld   x15, 0(x14)                      // breakpoint, no load
    TEST_EQ(29, x29, 1)
    TEST_EQ(30, x28, 3)
    TEST_EQ_REG(31, x27, x14)
    la   x11, p3a
    TEST_EQ_REG(32, x26, x11)
    TEST_EQ(33, x15, 0x77)
    lw   x15, 4(x14)                      // another address
    li   x16, 0x9999
    sd   x16, 0(x14)                      // a store
    TEST_EQ(34, x29, 1)
    TEST_EQ(35, x15, 0)
    GET_HIT(1)
    TEST_EQ(36, x10, 1)
    // the breakpoint before the misaligned address
    addi x11, x14, 1
    csrw TDATA2, x11
    lh   x15, 1(x14)
    TEST_EQ(37, x29, 2)
    TEST_EQ(38, x28, 3)
    TEST_EQ_REG(39, x27, x11)
    CLR_TRIG(1)
    ld   x15, 0(x14)
    TEST_EQ(40, x15, 0x9999)              // the store went through
    // a store trigger
    addi x11, x14, 8
    SET_TRIG(2, T2 | TM | TST, x11)
    li   x29, 0
    li   x16, 0x5555
    sd   x16, 8(x14)                      // breakpoint, no store
    sb   x16, 8(x14)                      // the same
    ld   x15, 8(x14)                      // a load
    TEST_EQ(41, x29, 2)
    TEST_EQ_REG(42, x27, x11)
    TEST_EQ(43, x15, 0x2222)
    addi x11, x14, 10
    csrw TDATA2, x11
    sw   x16, 10(x14)                     // misaligned: the breakpoint first
    TEST_EQ(44, x29, 3)
    TEST_EQ(45, x28, 3)
    GET_HIT(2)
    TEST_EQ(46, x10, 1)
    GET_HIT(3)                            // not the others
    TEST_EQ(47, x10, 0)
    CLR_TRIG(2)
    ld   x15, 8(x14)
    TEST_EQ(48, x15, 0x2222)
    // an AMO is a load and a store
    addi x20, x14, 16
    SET_TRIG(3, T2 | TM | TLD, x20)
    li   x29, 0
    li   x18, 0x44
    li   x19, 1
    amoadd.d x18, x19, (x20)
    TEST_EQ(49, x29, 1)
    TEST_EQ(50, x28, 3)
    TEST_EQ(51, x18, 0x44)
    li   t6, T2 | TM | TST
    csrw TDATA1, t6
    amoswap.d x18, x19, (x20)
    TEST_EQ(52, x29, 2)
    GET_HIT(3)
    TEST_EQ(53, x10, 1)
    GET_HIT(0)
    TEST_EQ(54, x10, 0)
    CLR_TRIG(3)
    ld   x15, 16(x14)
    TEST_EQ(55, x15, 0x3333)              // neither AMO wrote

    //--------------------------------------------------------------
    // 4 m / s / u, in S and U mode
    //--------------------------------------------------------------
    csrw TCONTROL, x0                     // MTE is for M mode only
    la   x12, p4a
    SET_TRIG(0, T2 | TU | TX, x12)
    RUN_P4A(to_u)                         // U: breakpoint
    TEST_EQ(56, x22, 1)
    TEST_EQ(57, x23, 3)
    TEST_EQ(58, x21, 0)
    RUN_P4A(to_s)                         // S: nothing
    TEST_EQ(59, x22, 0)
    TEST_EQ(60, x21, 1)
    SET_TRIG(0, T2 | TS | TX, x12)
    RUN_P4A(to_s)                         // S: breakpoint
    TEST_EQ(61, x22, 1)
    TEST_EQ(62, x21, 0)
    RUN_P4A(to_u)                         // U: nothing
    TEST_EQ(63, x22, 0)
    SET_TRIG(0, T2 | TM | TX, x12)        // M only: nothing in S or U
    RUN_P4A(to_s)
    TEST_EQ(64, x22, 0)
    RUN_P4A(to_u)
    TEST_EQ(65, x22, 0)
    CLR_TRIG(0)
    // a load trigger in S mode
    la   x14, buf
    SET_TRIG(2, T2 | TS | TLD, x14)
    li   x29, 0
    li   x15, 0x66
    la   t0, p4l
    jal  ra, to_s
    TEST_EQ(66, x22, 1)
    TEST_EQ(67, x23, 3)
    TEST_EQ_REG(68, x25, x14)
    TEST_EQ(69, x15, 0x66)
    CLR_TRIG(2)

    //--------------------------------------------------------------
    // 5 nothing on a path that is thrown away
    //--------------------------------------------------------------
    csrsi TCONTROL, 8
    la   x12, p5a
    SET_TRIG(1, T2 | TM | TX, x12)
    la   x14, buf
    SET_TRIG(2, T2 | TM | TLD, x14)
    li   x29, 0
    li   x15, 0x88
    li   x21, 0
    beq  x0, x0, 1f                       // not known to the BTB yet
p5a:addi x21, x0, 9
    ld   x15, 0(x14)
1:  li   x30, 8
    ecall                                 // the handler steps over it and
p5b:ld   x15, 0(x14)                      //   over the load
    ecall
    addi x21, x0, 7
    li   x30, 4
    TEST_EQ(70, x29, 2)                   // the two ECALLs
    TEST_EQ(71, x28, 11)
    TEST_EQ(72, x15, 0x88)
    TEST_EQ(73, x21, 0)
    GET_HIT(1)
    TEST_EQ(74, x10, 0)
    GET_HIT(2)
    TEST_EQ(75, x10, 0)
    CLR_TRIG(1)
    CLR_TRIG(2)

    //--------------------------------------------------------------
    // 6 before the illegal instruction
    //--------------------------------------------------------------
    la   x12, p6a
    SET_TRIG(3, T2 | TM | TX, x12)
    li   x29, 0
p6a:.word 0                               // illegal
    TEST_EQ(76, x29, 1)
    TEST_EQ(77, x28, 3)
    CLR_TRIG(3)
    li   x29, 0
    .word 0                               // without: illegal
    TEST_EQ(78, x29, 1)
    TEST_EQ(79, x28, 2)

    //--------------------------------------------------------------
    // 7 compressed instructions
    //--------------------------------------------------------------
    la   x12, p7b
    SET_TRIG(0, T2 | TM | TX, x12)
    li   x29, 0
    li   x21, 0
    li   x30, 2
    j    p7a
    .balign 4
    .option push
    .option rvc
p7a:c.addi x21, 1                         // at a word
p7b:c.addi x21, 2                         // breakpoint (2 bytes on)
    c.addi x21, 4
    c.addi x21, 8                         // the rest stays word aligned
    .option pop
    li   x30, 4
    TEST_EQ(80, x29, 1)
    TEST_EQ_REG(81, x26, x12)
    TEST_EQ(82, x21, 13)
    CLR_TRIG(0)
    csrw TCONTROL, x0

    TEST_DONE

    // part 4 in S or U mode: what the handler saw goes to x22 / x23 / x25,
    // the ECALL brings the hart back to M, and it returns to the caller
p4a:addi x21, x21, 1
    mv   x22, x29
    mv   x23, x28
    ecall
    jr   ra
p4l:ld   x15, 0(x14)
    mv   x22, x29
    mv   x23, x28
    mv   x25, x27
    ecall
    jr   ra

    // MRET to the address in t0, in U or S mode
to_u:
    li   t6, 3 << 11
    csrc mstatus, t6
    csrw mepc, t0
    mret
to_s:
    li   t6, 3 << 11
    csrc mstatus, t6
    li   t6, 1 << 11
    csrs mstatus, t6
    csrw mepc, t0
    mret

m_trap:
    csrr x28, mcause
    csrr x27, mtval
    csrr x26, mepc
    csrr x24, TCONTROL
    addi x29, x29, 1
    li   t6, 9                            // an ECALL from S or U: back to M
    beq  x28, t6, 2f
    li   t6, 8
    bne  x28, t6, 1f
2:  li   t6, 3 << 11
    csrs mstatus, t6
1:  add  t6, x26, x30
    csrw mepc, t6
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
buf: .dword 0, 0x2222, 0x3333

    TOHOST_SECTION
