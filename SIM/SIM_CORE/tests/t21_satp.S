// t21_satp : turning the MMU on from supervisor mode, the way Linux does
//
// The kernel starts in S mode with satp = 0 (no translation), at its
// physical address. To get to its virtual address it points stvec at the
// virtual address of the instruction behind the satp write and writes
// satp. The physical address it runs at is not mapped in the new table, so
// the fetch of the next instruction takes an instruction page fault, and
// the trap is what takes it to the virtual address (head.S,
// relocate_enable_mmu).
//
// That only works if the instruction behind the write is fetched with the
// new translation. One that was fetched before, under the old one, would
// run on at the physical address.
//
//   VA 4000_0000 -> PA 8000_0000, one gigabyte page; the physical address
//   of the test is NOT mapped.
//
// A instruction page fault is delegated to S. x20 gets the address the
// instruction behind the satp write ran at.
#include "test.h"

#define PTE_V 0x001
#define PTE_R 0x002
#define PTE_W 0x004
#define PTE_X 0x008
#define PTE_A 0x040
#define PTE_D 0x080

#define VA_MINUS_PA (-0x40000000)

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP

    // the page table : l1pt[1], VA 4000_0000, is PA 8000_0000 as one
    // gigabyte page; l1pt[2], the identity, stays empty
    la   x10, l1pt
    li   x11, 512
1:
    sd   x0, 0(x10)
    addi x10, x10, 8
    addi x11, x11, -1
    bnez x11, 1b
    la   x10, l1pt
    li   x12, 0x80000000
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    sd   x12, 1*8(x10)

    li   t0, 1 << 12                     // instruction page fault to S
    csrw medeleg, t0

    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s
    csrw mepc, t0
    mret

    //-----------------------------------------------------------------
in_s:
    // stvec : the virtual address of 2f
    la   x10, 2f
    li   x11, VA_MINUS_PA
    add  x10, x10, x11
    csrw stvec, x10

    la   x12, l1pt
    srli x12, x12, 12
    li   x13, 8
    slli x13, x13, 60                    // MODE = Sv39
    or   x12, x12, x13
    li   x25, 0
    sfence.vma
    csrw satp, x12
    .align 2
2:
    // A core that runs on at the physical address gets here twice: once
    // at once, and once more when a later fetch faults and the trap takes
    // it to stvec. So the count comes first, before any branch that could
    // leave the physical address and fault.
    addi x25, x25, 1
    auipc x20, 0                         // where did we get here
    TEST_EQ(1, x25, 1)
    // x20 must be the virtual address: below 8000_0000
    srli x21, x20, 31
    TEST_EQ(2, x21, 0)
    csrr x22, scause
    TEST_EQ(3, x22, 12)                  // through the page fault

    TEST_DONE

    TEST_FAIL_HANDLER

    .section .bss
    .align 12
l1pt:   .space 4096

    TOHOST_SECTION
