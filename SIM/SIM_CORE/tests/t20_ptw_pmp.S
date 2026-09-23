// t20_ptw_pmp : a page table the protection does not let the walk read
//
// The walker reads the page table at the privilege of the access it walks
// for, and those reads are checked by the PMP like any other. A walk that
// is refused ends in an access fault of the kind of the access (load 5,
// store 7, fetch 1), not in a page fault.
//
//   VA 8000_0000 : the test itself, one gigabyte page
//   VA 4000_0000 : root -> l2pt -> l3pt -> page_a (R, W)
//
// PMP entry 0 covers l3pt and grants nothing; entry 1 grants everything
// else. Machine mode is not held by an unlocked entry, so the handler and
// the setup are not affected.
//
//   x29 / x28 / x27 : a trap happened, its cause, mtval
//   x24 : where the handler resumes (0 : behind the instruction)
#include "test.h"

#define PTE_V 0x001
#define PTE_R 0x002
#define PTE_W 0x004
#define PTE_X 0x008
#define PTE_A 0x040
#define PTE_D 0x080

#define CAUSE_IFAULT 1
#define CAUSE_LFAULT 5
#define CAUSE_SFAULT 7

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   t0, m_trap
    csrw mtvec, t0
    li   x29, 0
    li   x24, 0

    //-----------------------------------------------------------------
    // the page table
    //-----------------------------------------------------------------
    la   x10, l1pt
    li   x11, 3 * 512
1:
    sd   x0, 0(x10)
    addi x10, x10, 8
    addi x11, x11, -1
    bnez x11, 1b

    la   x10, l1pt
    li   x12, 0x80000000                  // l1pt[2] : the test, 1G
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    sd   x12, 2*8(x10)
    la   x11, l2pt                        // l1pt[1] -> l2pt
    srli x12, x11, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V
    sd   x12, 1*8(x10)
    la   x13, l3pt                        // l2pt[0] -> l3pt
    srli x12, x13, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V
    sd   x12, 0(x11)
    la   x14, page_a                      // l3pt[0] -> page_a
    srli x12, x14, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd   x12, 0(x13)

    li   x12, 0x5A5A
    sd   x12, 0(x14)                      // what the load should see

    //-----------------------------------------------------------------
    // PMP : entry 0 = l3pt (4 KiB, NAPOT, nothing), entry 1 = everything
    //-----------------------------------------------------------------
    la   x13, l3pt
    srli x12, x13, 2
    ori  x12, x12, (4096 / 8) - 1
    csrw pmpaddr0, x12
    li   x12, -1
    csrw pmpaddr1, x12
    li   x12, (0x1F << 8) | 0x18          // 1 : NAPOT RWX, 0 : NAPOT none
    csrw pmpcfg0, x12

    la   x10, l1pt
    srli x10, x10, 12
    li   x11, 8
    slli x11, x11, 60                     // MODE = Sv39
    or   x10, x10, x11
    csrw satp, x10
    sfence.vma

    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                      // MPP = S
    la   t0, in_s
    csrw mepc, t0
    mret

    //-----------------------------------------------------------------
in_s:
    li   x20, 0x40000000

    // a load: the walk cannot read l3pt
    li   x29, 0
    li   x21, 0
    ld   x21, 0(x20)
    TEST_EQ(1, x29, 1)
    TEST_EQ(2, x28, CAUSE_LFAULT)
    TEST_EQ_REG(3, x27, x20)
    TEST_EQ(4, x21, 0)

    // a store
    li   x29, 0
    sd   x20, 0(x20)
    TEST_EQ(5, x29, 1)
    TEST_EQ(6, x28, CAUSE_SFAULT)
    TEST_EQ_REG(7, x27, x20)

    // a fetch
    li   x29, 0
    la   x24, 1f
    jalr x0, x20, 0
1:
    TEST_EQ(8, x29, 1)
    TEST_EQ(9, x28, CAUSE_IFAULT)
    TEST_EQ_REG(10, x27, x20)

    // let S read l3pt : the same load goes through
    li   x29, 0
    ecall                                 // to M, which opens entry 0
    TEST_EQ(11, x28, 9)                   // the ECALL itself
    li   x29, 0
    ld   x21, 0(x20)
    TEST_EQ(12, x29, 0)
    TEST_EQ(13, x21, 0x5A5A)

    TEST_DONE

    //-----------------------------------------------------------------
    // machine mode trap handler. An ECALL from S opens PMP entry 0 for
    // reading (and fences the translation, which the specification asks
    // for after a change of the PMP).
    //-----------------------------------------------------------------
    .align 2
m_trap:
    csrr x28, mcause
    csrr x27, mtval
    li   x29, 1
    li   t0, 9
    bne  x28, t0, 1f
    csrr t0, pmpcfg0
    ori  t0, t0, 0x01                     // entry 0 : R
    csrw pmpcfg0, t0
    sfence.vma
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

    TEST_FAIL_HANDLER

    .section .bss
    .align 12
l1pt:   .space 4096
l2pt:   .space 4096
l3pt:   .space 4096
page_a: .space 4096

    TOHOST_SECTION
