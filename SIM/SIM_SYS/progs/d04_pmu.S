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
#include "test.h"

#define MHPMCOUNTER3  0xb03
#define MHPMCOUNTER4  0xb04
#define MHPMEVENT3    0x323
#define MHPMEVENT4    0x324

#define EV_IC_MISS    7
#define EV_DC_MISS    8
#define EV_ITLB_MISS  9
#define EV_DTLB_MISS  10

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

    TOHOST_SECTION
