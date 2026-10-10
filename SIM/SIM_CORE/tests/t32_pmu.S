// t32_pmu : the counters of events and Sscofpmf (CPU_CORE_SPEC.md
// decision 69)
//
//   1 the CSRs: mhpmcounter3-6 and mhpmevent3-6 hold what is written (an
//     event that does not exist reads 0), 7-31 read 0 and ignore writes,
//     mcountinhibit has HPM3-6
//   2 counting, as differences between two reads (a counter is one cycle
//     behind its event; both reads see the same lag): cycles and
//     instructions against mcycle / minstret, loads, stores, conditional
//     branches and exceptions exactly; mispredictions, load use, MDU waits,
//     front end and back end stalls at least once
//   3 mcountinhibit stops a counter; MINH leaves M mode out, UINH U mode
//   4 overflow: OF set when the counter wraps, LCOFIP with it, the
//     interrupt (cause 13) taken in M mode and counted as an interrupt; a
//     counter whose OF is already set wraps without a new interrupt
//   5 delegated: the overflow interrupt taken in S mode, which sees LCOF
//     in sip / sie and clears it there
//   6 below M: hpmcounterN by mcounteren / scounteren, scountovf masked by
//     mcounteren, mhpm* not at all
//   7 Smcntrpmf: mcyclecfg / minstretcfg keep MINH / SINH / UINH; MINH
//     stops mcycle in M mode; minstret over a trip to U mode with MINH is
//     the four instructions of U mode, and with UINH the rest
//
//   x29 / x28 : machine traps (count), mcause of the last. x19 / x20 the
//   same for supervisor traps. Both handlers step over the instruction of
//   an exception; an ECALL from S or U brings the hart back to M; the
//   overflow handlers clear OF of counter 3 and LCOFIP.
#include "test.h"

#define MHPMCOUNTER3  0xb03
#define MHPMCOUNTER4  0xb04
#define MHPMCOUNTER5  0xb05
#define MHPMCOUNTER6  0xb06
#define MHPMCOUNTER7  0xb07
#define MHPMCOUNTER31 0xb1f
#define MHPMEVENT3    0x323
#define MHPMEVENT4    0x324
#define MHPMEVENT5    0x325
#define MHPMEVENT6    0x326
#define MHPMEVENT7    0x327
#define MCOUNTINHIBIT 0x320
#define HPMCOUNTER3   0xc03
#define HPMCOUNTER4   0xc04
#define SCOUNTOVF     0xda0
#define MCYCLECFG     0x321
#define MINSTRETCFG   0x322

#define OF    (1 << 63)
#define MINH  (1 << 62)
#define SINH  (1 << 61)
#define UINH  (1 << 60)
#define LCOF  (1 << 13)

// count event ev on counter 3 over the code between START and STOP: x25
#define START(ev)                   \
    li   t0, ev;                    \
    csrw MHPMEVENT3, t0;            \
    csrr x24, MHPMCOUNTER3;
// instructions counted with the filter in mhpmevent over a trip to
// u_block in U mode and back: x12
#define RUN_U(ev)                   \
    li   t0, ev;                    \
    csrw MHPMEVENT3, t0;            \
    csrw MHPMCOUNTER3, x0;          \
    la   t0, u_block;               \
    jal  ra, to_u;                  \
    csrw MHPMEVENT3, x0;            \
    nop; nop;                       \
    csrr x12, MHPMCOUNTER3;

// minstret over the same trip with minstretcfg = cfg: x12
#define RUN_UI(cfg)                 \
    li   t0, cfg;                   \
    csrw MINSTRETCFG, t0;           \
    csrr x13, minstret;             \
    la   t0, u_block;               \
    jal  ra, to_u;                  \
    csrr x12, minstret;             \
    csrw MINSTRETCFG, x0;           \
    sub  x12, x12, x13;

#define STOP                        \
    nop; nop; nop; nop;             \
    csrr x25, MHPMCOUNTER3;         \
    sub  x25, x25, x24;

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
    li   t0, 1 << 13                      // mstatus.FS, for the FP load
    csrs mstatus, t0

    //--------------------------------------------------------------
    // 1 the CSRs
    //--------------------------------------------------------------
    li   x11, 0x123456789abcdef0
    csrw MHPMCOUNTER3, x11
    csrw MHPMCOUNTER6, x11
    csrr x10, MHPMCOUNTER6
    TEST_EQ_REG(2, x10, x11)
    csrw MHPMCOUNTER7, x11
    csrr x10, MHPMCOUNTER7
    TEST_EQ(3, x10, 0)
    csrw MHPMCOUNTER31, x11
    csrr x10, MHPMCOUNTER31
    TEST_EQ(4, x10, 0)
    li   x11, MINH | SINH | 24            // the last event (a dirty victim copied out)
    csrw MHPMEVENT4, x11
    csrr x10, MHPMEVENT4
    TEST_EQ_REG(5, x10, x11)
    li   x11, 25                          // no such event
    csrw MHPMEVENT4, x11
    csrr x10, MHPMEVENT4
    TEST_EQ(6, x10, 0)
    li   x11, (1 << 32) | 2               // nor this one
    csrw MHPMEVENT4, x11
    csrr x10, MHPMEVENT4
    TEST_EQ(7, x10, 0)
    li   x11, -1
    csrw MHPMEVENT7, x11
    csrr x10, MHPMEVENT7
    TEST_EQ(8, x10, 0)
    csrw MCOUNTINHIBIT, x11
    csrr x10, MCOUNTINHIBIT
    TEST_EQ(9, x10, 0x7d)
    csrw MCOUNTINHIBIT, x0
    csrr x10, SCOUNTOVF
    TEST_EQ(10, x10, 0)
    TEST_EQ(11, x29, 0)                   // none of them trapped

    //--------------------------------------------------------------
    // 2 counting
    //--------------------------------------------------------------
    // cycles and instructions, against mcycle and minstret
    li   t0, 1
    csrw MHPMEVENT3, t0
    li   t0, 2
    csrw MHPMEVENT4, t0
    csrr x12, mcycle
    csrr x13, MHPMCOUNTER3
    csrr x14, minstret
    csrr x15, MHPMCOUNTER4
    li   x16, 20
1:  addi x16, x16, -1
    bnez x16, 1b
    csrr x17, mcycle
    csrr x18, MHPMCOUNTER3
    csrr x21, minstret
    csrr x22, MHPMCOUNTER4
    sub  x12, x17, x12
    sub  x13, x18, x13
    TEST_EQ_REG(12, x12, x13)
    sub  x14, x21, x14
    sub  x15, x22, x15
    TEST_EQ_REG(13, x14, x15)
    // loads, stores
    la   x16, buf
    START(3)
    ld   x10, 0(x16)
    lw   x10, 8(x16)
    lbu  x10, 9(x16)
    sd   x10, 16(x16)
    fld  f1, 0(x16)
    STOP
    TEST_EQ(14, x25, 4)
    START(4)
    sd   x10, 16(x16)
    sw   x10, 24(x16)
    ld   x10, 0(x16)
    sb   x10, 25(x16)
    STOP
    TEST_EQ(15, x25, 3)
    // conditional branches: 10 of the loop, 2 others, one on a load (it is
    // resolved in MR); a JAL is none
    la   x18, buf
    START(5)
    li   x16, 10
1:  addi x16, x16, -1
    bnez x16, 1b
    beqz x16, 2f
    nop
2:  bnez x16, 3f
    j    3f
3:  ld   x17, 0(x18)
    beqz x17, 4f
4:  nop
    STOP
    TEST_EQ(16, x25, 13)
    // exceptions: two ECALLs and an illegal instruction
    START(15)
    li   x29, 0
    ecall
    ecall
    .word 0
    STOP
    TEST_EQ(17, x25, 3)
    TEST_EQ(18, x29, 3)
    // mispredictions: the last turn of a loop at least
    START(6)
    li   x16, 30
1:  addi x16, x16, -1
    bnez x16, 1b
    STOP
    li   gp, 19
    beqz x25, fail
    // load use
    la   x16, buf
    START(13)
    ld   x10, 0(x16)
    addi x10, x10, 1
    ld   x10, 8(x16)
    add  x10, x10, x10
    STOP
    li   gp, 20
    beqz x25, fail
    // the MDU
    li   x10, 1000
    li   x11, 7
    START(14)
    div  x12, x10, x11
    STOP
    li   gp, 21
    beqz x25, fail
    // the front end: refetching after a fence.i
    START(12)
    fence.i
    STOP
    li   gp, 22
    beqz x25, fail
    // the back end: the issue waits for the divide
    START(17)
    div  x12, x10, x11
    add  x12, x12, x12
    STOP
    li   gp, 23
    beqz x25, fail

    //--------------------------------------------------------------
    // 3 inhibit and the level filters
    //--------------------------------------------------------------
    li   t0, 1                            // cycles
    csrw MHPMEVENT3, t0
    li   t0, 1 << 3
    csrw MCOUNTINHIBIT, t0
    csrr x12, MHPMCOUNTER3
    nop
    nop
    csrr x13, MHPMCOUNTER3
    TEST_EQ_REG(24, x12, x13)
    csrw MCOUNTINHIBIT, x0
    li   t0, MINH | 1                     // not in M
    csrw MHPMEVENT3, t0
    nop
    csrr x12, MHPMCOUNTER3
    nop
    nop
    csrr x13, MHPMCOUNTER3
    TEST_EQ_REG(25, x12, x13)
    // instructions over the same trip to U mode and back: with MINH only
    // the four of U mode (the ECALL traps, it does not retire), and what
    // MINH and UINH leave add up to the unfiltered count
    RUN_U(MINH | 2)
    TEST_EQ(26, x12, 4)
    mv   x14, x12
    RUN_U(UINH | 2)
    add  x14, x14, x12
    RUN_U(2)
    TEST_EQ_REG(27, x14, x12)

    //--------------------------------------------------------------
    // 4 overflow in M mode
    //--------------------------------------------------------------
    li   t0, 16                           // interrupts, on counter 4
    csrw MHPMEVENT4, t0
    csrw MHPMCOUNTER4, x0
    li   t0, 15                           // exceptions, on counter 5
    csrw MHPMEVENT5, t0
    csrw MHPMCOUNTER5, x0
    li   x29, 0
    ecall                                 // one exception in between
    li   t0, -20
    csrw MHPMCOUNTER3, t0
    li   t0, 1                            // cycles
    csrw MHPMEVENT3, t0
    li   x24, 200
1:  csrr x10, mip
    andi x10, x10, 0                      // (no interrupt yet: MIE is off)
    addi x24, x24, -1
    bnez x24, 1b
    csrr x10, MHPMEVENT3
    srli x10, x10, 63
    TEST_EQ(28, x10, 1)                   // OF
    li   x11, LCOF
    csrr x10, mip
    and  x10, x10, x11
    TEST_EQ(29, x10, LCOF)                // LCOFIP
    csrr x10, SCOUNTOVF
    TEST_EQ(30, x10, 8)
    TEST_EQ(52, x29, 1)
    li   x29, 0
    csrs mie, x11                         // LCOFIE
    csrsi mstatus, 8                      // MIE: taken now
    nop
    nop
    csrci mstatus, 8
    TEST_EQ(31, x29, 1)
    li   x10, (1 << 63) | 13
    TEST_EQ_REG(32, x28, x10)
    csrr x10, mip
    and  x10, x10, x11
    TEST_EQ(33, x10, 0)                   // the handler cleared it
    li   t0, 0                            // stop counter 3 before reading 4
    csrw MHPMEVENT3, t0
    nop
    nop
    csrr x10, MHPMCOUNTER4
    TEST_EQ(34, x10, 1)                   // one interrupt counted
    csrr x10, MHPMCOUNTER5
    TEST_EQ(53, x10, 1)                   //   and one exception
    // OF already set: wrapping again raises nothing
    li   t0, OF | 1
    csrw MHPMEVENT3, t0
    li   t0, -5
    csrw MHPMCOUNTER3, t0
    li   x24, 50
1:  addi x24, x24, -1
    bnez x24, 1b
    csrr x10, MHPMCOUNTER3
    li   gp, 35
    li   t0, 1000
    bltu t0, x10, fail                    // it has wrapped (small now)
    csrr x10, mip
    and  x10, x10, x11
    TEST_EQ(36, x10, 0)
    li   t0, 0
    csrw MHPMEVENT3, t0
    csrc mie, x11

    //--------------------------------------------------------------
    // 5 delegated to S mode
    //--------------------------------------------------------------
    csrw mideleg, x11
    li   t0, -1
    csrw mcounteren, t0
    li   t0, -20
    csrw MHPMCOUNTER3, t0
    li   t0, 1
    csrw MHPMEVENT3, t0
    la   t0, s_part5
    jal  ra, to_s
    TEST_EQ(37, x21, LCOF)                // sip showed it
    TEST_EQ(38, x19, 1)                   // one supervisor trap
    li   x10, (1 << 63) | 13
    TEST_EQ_REG(39, x20, x10)
    TEST_EQ(40, x22, 0)                   // gone from sip after the handler
    TEST_EQ(41, x23, 8)                   // scountovf, counter 3
    csrr x10, mip
    and  x10, x10, x11
    TEST_EQ(42, x10, 0)
    li   t0, 0
    csrw MHPMEVENT3, t0
    csrw mideleg, x0

    //--------------------------------------------------------------
    // 6 below M
    //--------------------------------------------------------------
    li   t0, OF | 1                       // OF of counter 3 set
    csrw MHPMEVENT3, t0
    li   t0, 1 << 4                       // hpmcounter4 only
    csrw mcounteren, t0
    csrw scounteren, t0
    la   t0, s_part6
    jal  ra, to_s
    TEST_EQ(43, x21, 2)                   // hpmcounter3: illegal
    TEST_EQ(44, x22, 0)                   // hpmcounter4: fine
    TEST_EQ(45, x23, 0)                   // scountovf without bit 3
    TEST_EQ(46, x26, 2)                   // mhpmcounter3: illegal
    li   t0, (1 << 3) | (1 << 4)
    csrw mcounteren, t0
    la   t0, s_part6
    jal  ra, to_s
    TEST_EQ(47, x21, 0)
    TEST_EQ(48, x23, 8)
    li   t0, 1 << 3                       // U: scounteren too
    csrw scounteren, t0
    la   t0, u_part6
    jal  ra, to_u
    TEST_EQ(49, x21, 0)                   // hpmcounter3
    TEST_EQ(50, x22, 2)                   // hpmcounter4: not in scounteren
    TEST_EQ(51, x23, 2)                   // scountovf: S only
    li   t0, 0
    csrw MHPMEVENT3, t0

    //--------------------------------------------------------------
    // 7 Smcntrpmf
    //--------------------------------------------------------------
    li   x11, -1
    csrw MCYCLECFG, x11
    csrr x10, MCYCLECFG
    li   x12, MINH | SINH | UINH
    TEST_EQ_REG(54, x10, x12)
    csrw MINSTRETCFG, x11
    csrr x10, MINSTRETCFG
    TEST_EQ_REG(55, x10, x12)
    csrw MINSTRETCFG, x0
    li   t0, MINH                         // mcycle stops in M
    csrw MCYCLECFG, t0
    csrr x12, mcycle
    nop
    nop
    csrr x13, mcycle
    TEST_EQ_REG(56, x12, x13)
    csrw MCYCLECFG, x0
    csrr x12, mcycle
    nop
    csrr x13, mcycle
    li   gp, 57
    beq  x12, x13, fail                   // and goes on again
    RUN_UI(MINH)
    TEST_EQ(58, x12, 4)                   // the four of U mode
    mv   x14, x12
    RUN_UI(UINH)
    add  x14, x14, x12
    RUN_UI(0)
    TEST_EQ_REG(59, x14, x12)

    TEST_DONE

    // a few instructions in U mode, then back to M
u_block:
    addi x10, x0, 1
    addi x10, x10, 1
    addi x10, x10, 1
    addi x10, x10, 1
    ecall
    ret

    // S mode: wait for the overflow, look at sip on the way
s_part5:
    li   x19, 0
    li   x21, 0
    li   x24, 400
1:  csrr x10, sip
    and  x10, x10, x11
    or   x21, x21, x10
    addi x24, x24, -1
    bnez x24, 1b
    csrr x23, SCOUNTOVF
    csrs sie, x11
    csrsi sstatus, 2                      // SIE: taken now
    nop
    nop
    csrci sstatus, 2
    csrr x22, sip
    and  x22, x22, x11
    ecall
    ret

    // S mode: which counters it may read (x21 / x22 / x23 / x26 : the
    // number of traps of each read, or the value of scountovf)
s_part6:
    li   x29, 0
    csrr x10, HPMCOUNTER3
    mv   x21, x28
    bnez x29, 1f
    li   x21, 0
1:  li   x29, 0
    csrr x10, HPMCOUNTER4
    mv   x22, x29
    csrr x23, SCOUNTOVF
    li   x29, 0
    csrr x10, MHPMCOUNTER3
    mv   x26, x28
    bnez x29, 1f
    li   x26, 0
1:  ecall
    ret

u_part6:
    li   x29, 0
    csrr x10, HPMCOUNTER3
    mv   x21, x29
    li   x29, 0
    li   x28, 0
    csrr x10, HPMCOUNTER4
    mv   x22, x28
    li   x29, 0
    li   x28, 0
    csrr x10, SCOUNTOVF
    mv   x23, x28
    ecall
    ret

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
    addi x29, x29, 1
    bltz x28, 4f                          // an interrupt: the overflow
    li   t6, 9                            // an ECALL from S or U: back to M
    beq  x28, t6, 2f
    li   t6, 8
    bne  x28, t6, 1f
2:  li   t6, 3 << 11
    csrs mstatus, t6
1:  csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret
4:  li   t6, OF                           // clear OF of counter 3, LCOFIP
    csrc MHPMEVENT3, t6
    li   t6, LCOF
    csrc mip, t6
    mret

s_trap:
    csrr x20, scause
    addi x19, x19, 1
    li   t6, LCOF                         // OF stays (mhpmevent is M's);
    csrc sip, t6                          //   LCOFIP is cleared through sip
    sret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
buf: .dword 0x1111, 0x2222, 0, 0

    TOHOST_SECTION
