// d04_pmu : the events of the PMU that need the real caches and the page
// table walker (CPU_CORE_SPEC.md decision 69; the rest is in t32_pmu)
//
//   1 D$ misses: eight loads, one in each of eight lines never touched
//     before, are eight line fills; loading them again is none
//   2 I$ misses: calling code that has not been fetched yet fills at least
//     one line, calling it again none
//   3 TLB misses: in S mode through a page table (one 1 GiB page, the
//     identity), the first fetch and the first load each walk the table,
//     the second load of the page does not; after sfence.vma the fetch
//     walks again (and no load follows)
//   4 the L2 (events 18 / 19), when tb_SYS has one (it puts L2_SIZE at
//     0x1000_07f8): every L1 fill is one L2 read; eight lines never
//     touched are eight L2 misses; eight lines 4 KB apart (one set of the
//     4 way D$, eight sets of the L2) read again: at least four have left
//     the D$, and each of those is an L2 read that hits. Without an L2
//     both events stay 0
#include "test.h"

#define MHPMCOUNTER3  0xb03
#define MHPMCOUNTER4  0xb04
#define MHPMEVENT3    0x323
#define MHPMEVENT4    0x324

#define EV_IC_MISS    7
#define EV_DC_MISS    8
#define EV_ITLB_MISS  9
#define EV_DTLB_MISS  10
#define EV_L2_READ    18
#define EV_L2_MISS    19
#define MHPMCOUNTER5  0xb05
#define MHPMCOUNTER6  0xb06
#define MHPMEVENT5    0x325
#define MHPMEVENT6    0x326
#define L2_SIZE_ADDR  0x100007f8

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP

    //--------------------------------------------------------------
    // 1 D$ misses
    //--------------------------------------------------------------
    li   t0, EV_DC_MISS
    csrw MHPMEVENT3, t0
    la   x10, lines
    csrr x20, MHPMCOUNTER3
    ld   x11, 0(x10)
    ld   x11, 64(x10)
    ld   x11, 128(x10)
    ld   x11, 192(x10)
    ld   x11, 256(x10)
    ld   x11, 320(x10)
    ld   x11, 384(x10)
    ld   x11, 448(x10)
    fence
    csrr x21, MHPMCOUNTER3
    sub  x21, x21, x20
    TEST_EQ(2, x21, 8)
    csrr x20, MHPMCOUNTER3
    ld   x11, 8(x10)
    ld   x11, 72(x10)
    ld   x11, 456(x10)
    fence
    csrr x21, MHPMCOUNTER3
    sub  x21, x21, x20
    TEST_EQ(3, x21, 0)                    // they are in the cache now

    //--------------------------------------------------------------
    // 2 I$ misses
    //--------------------------------------------------------------
    li   t0, EV_IC_MISS
    csrw MHPMEVENT3, t0
    csrr x20, MHPMCOUNTER3
    call far_code
    csrr x21, MHPMCOUNTER3
    sub  x21, x21, x20
    li   gp, 4
    beqz x21, fail
    csrr x20, MHPMCOUNTER3
    call far_code
    csrr x21, MHPMCOUNTER3
    sub  x21, x21, x20
    TEST_EQ(5, x21, 0)

    //--------------------------------------------------------------
    // 4 the L2. count8 gives the four counts of eight loads:
    //   a2 L2 reads, a3 L2 misses, a4 I$ fills, a5 D$ fills
    //--------------------------------------------------------------
    li   t0, EV_L2_READ
    csrw MHPMEVENT3, t0
    li   t0, EV_L2_MISS
    csrw MHPMEVENT4, t0
    li   t0, EV_IC_MISS
    csrw MHPMEVENT5, t0
    li   t0, EV_DC_MISS
    csrw MHPMEVENT6, t0
    li   t0, L2_SIZE_ADDR
    ld   s2, 0(t0)                        // 0: no L2
    // the first call brings count8 itself into the I$ (lines are in the D$)
    la   a0, lines
    li   a1, 64
    call count8
    // 4a eight lines never touched
    la   a0, lines_l2
    li   a1, 64
    call count8
    beqz s2, 41f
    TEST_EQ(10, a5, 8)                    // D$ fills
    TEST_EQ(11, a2, 8)                    // one L2 read each (I$: a4 = 0)
    TEST_EQ(12, a4, 0)
    TEST_EQ(13, a3, 8)                    // and the L2 had none of them
    j    42f
41: or   a2, a2, a3
    TEST_EQ(14, a2, 0)                    // no L2: nothing counted
42:
    // 4b eight lines 4 KB apart, twice
    la   a0, far_lines
    li   a1, 4096
    call count8
    la   a0, far_lines
    li   a1, 4096
    call count8
    beqz s2, 43f
    li   gp, 15
    li   t0, 4
    blt  a5, t0, fail                     // at least four left the D$
    TEST_EQ_REG(16, a2, a5)               // every D$ fill read the L2
    TEST_EQ(17, a3, 0)                    // and found the line there
    j    44f
43: or   a2, a2, a3
    TEST_EQ(18, a2, 0)
44:

    //--------------------------------------------------------------
    // 3 TLB misses, in S mode
    //--------------------------------------------------------------
    li   t0, EV_ITLB_MISS
    csrw MHPMEVENT3, t0
    li   t0, EV_DTLB_MISS
    csrw MHPMEVENT4, t0
    la   t0, m_trap
    csrw mtvec, t0
    // the root of the page table: entry 2 maps 0x8000_0000 (1 GiB) to
    // itself, readable, writable, executable, accessed, dirty, global.
    // The walker reads no other entry here.
    la   t0, page_table
    li   t1, 0x200000ef
    sd   t1, 16(t0)
    fence
    la   t0, page_table
    srli t0, t0, 12
    li   t1, 8 << 60                      // Sv39
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma
    csrr x20, MHPMCOUNTER3
    csrr x22, MHPMCOUNTER4
    li   t0, 3 << 11                      // MPP = S
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0
    la   t0, s_code
    csrw mepc, t0
    mret
back_in_m:
    csrw satp, x0
    sfence.vma
    // the first fetch and load in S, then the ones after sfence.vma
    TEST_EQ(6, x23, 1)                    // ITLB, before sfence.vma
    TEST_EQ(7, x24, 1)                    // DTLB
    TEST_EQ(8, x25, 2)                    // ITLB, after it
    TEST_EQ(9, x26, 1)                    // DTLB: no load since
    TEST_DONE

    // S mode. mhpmcounter is M's, so the M handler of the ECALLs below
    // reads the counters: x23 / x24 after the first walks, x25 / x26 after
    // the second.
s_code:
    la   x10, lines
    ld   x11, 0(x10)                      // the first load: a walk
    ld   x11, 64(x10)                     // the same page: none
    li   x27, 1
    ecall                                 // M reads the counters
    sfence.vma
    li   x27, 2                           // the fetch walks again
    ecall
    // not reached

m_trap:
    csrr x28, MHPMCOUNTER3
    csrr x29, MHPMCOUNTER4
    sub  x28, x28, x20
    sub  x29, x29, x22
    li   t6, 1
    bne  x27, t6, 1f
    mv   x23, x28
    mv   x24, x29
    csrr t6, mepc                         // back to S, behind the ECALL
    addi t6, t6, 4
    csrw mepc, t6
    mret
1:  mv   x25, x28
    mv   x26, x29
    j    back_in_m

    // eight loads, a1 apart from a0, between two reads of the counters
    // 3 .. 6; the differences in a2 .. a5. Aligned and padded, so that the
    // fetch of the code around it is not counted after its first call
    .balign 64
count8:
    csrr t1, MHPMCOUNTER3
    csrr t2, MHPMCOUNTER4
    csrr t3, MHPMCOUNTER5
    csrr t4, MHPMCOUNTER6
    mv   t5, a0
    li   t6, 8
1:  ld   t0, 0(t5)
    add  t5, t5, a1
    addi t6, t6, -1
    bnez t6, 1b
    fence
    nop
    nop
    csrr a2, MHPMCOUNTER3
    csrr a3, MHPMCOUNTER4
    csrr a4, MHPMCOUNTER5
    csrr a5, MHPMCOUNTER6
    sub  a2, a2, t1
    sub  a3, a3, t2
    sub  a4, a4, t3
    sub  a5, a5, t4
    ret
    .fill 16, 4, 0x00000013

    // code no instruction has come near yet
    .balign 256
    .fill 64, 4, 0x00000013               // nops in front, to keep it apart
far_code:
    addi x12, x0, 1
    addi x12, x12, 1
    ret

    TEST_FAIL_HANDLER

    .section .data
    .balign 64
lines:
    .fill 64, 8, 0

    .section .bss
    .balign 4096
page_table:
    .space 4096
lines_l2:
    .space 512
    .balign 4096
far_lines:
    .space 8 * 4096

    TOHOST_SECTION
