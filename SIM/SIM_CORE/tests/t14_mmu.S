// t14_mmu : Sv39 address translation
//
// Builds a page table by hand, turns satp on, drops to supervisor mode and
// checks what the three levels, the permission bits and SFENCE.VMA do.
//
//   identity  : VA 8000_0000 -> PA 8000_0000 as one 1G page (code and data)
//   4000_0000 : page_a, read and write
//   4000_1000 : page_b, a user page
//   4000_2000 : page_a, read only
//   4000_3000 : page_a with the accessed bit clear
//   4000_4000 : not mapped
//   4000_6000 : the code page, without execute
//   4000_7000 : the code page, with execute
//   4020_0000 : PA 8000_0000 as one 2M page
//
//   x29 / x28 / x27 / x26 : a trap happened, its cause, tval, epc
//   x24 : where the handler resumes (0 : behind the instruction)
//   x23 : if not zero, the handler sets MPP to x23[1:0] before MRET
#include "test.h"

#define PTE_V 0x001
#define PTE_R 0x002
#define PTE_W 0x004
#define PTE_X 0x008
#define PTE_U 0x010
#define PTE_A 0x040
#define PTE_D 0x080

#define CAUSE_IPAGE 12
#define CAUSE_LPAGE 13
#define CAUSE_SPAGE 15

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP
    la   t0, m_trap
    csrw mtvec, t0
    li   x29, 0
    li   x24, 0
    li   x23, 0

    //-----------------------------------------------------------------
    // the page table, three levels of 512 entries
    //-----------------------------------------------------------------
    la   x10, l1pt
    li   x11, 3 * 512
1:
    sd   x0, 0(x10)
    addi x10, x10, 8
    addi x11, x11, -1
    bnez x11, 1b

    // l1pt[2] : one gigabyte at 8000_0000, everything the test itself uses
    la   x10, l1pt
    li   x12, 0x80000000
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    sd   x12, 2*8(x10)

    // l1pt[0] : the same gigabyte once more, as a user page. User mode runs
    // out of it, at its own address minus 8000_0000.
    li   x12, 0x80000000
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D
    sd   x12, 0*8(x10)

    // l1pt[3] stays zero : C000_0000 has no second level at all

    // l1pt[4] : a gigabyte page whose number is not aligned to a gigabyte
    li   x12, 0x80001000
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd   x12, 4*8(x10)

    // l1pt[1] -> l2pt   (4000_0000 .. 7FFF_FFFF)
    la   x13, l2pt
    srli x12, x13, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V
    sd   x12, 1*8(x10)

    // l2pt[0] -> l3pt   (4000_0000 .. 401F_FFFF)
    la   x14, l3pt
    srli x12, x14, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V
    sd   x12, 0*8(x13)

    // l2pt[1] : two megabytes at 8000_0000  (4020_0000)
    li   x12, 0x80000000
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd   x12, 1*8(x13)

    // l3pt[0] : page_a, read and write
    la   x15, page_a
    srli x12, x15, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd   x12, 0*8(x14)

    // l3pt[1] : page_b, a user page
    la   x16, page_b
    srli x12, x16, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D
    sd   x12, 1*8(x14)

    // l3pt[2] : page_a, read only. D is set so that the store below can
    // only fail on the write permission.
    srli x12, x15, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_A | PTE_D
    sd   x12, 2*8(x14)

    // l3pt[10] : page_a, writable but not yet dirty
    srli x12, x15, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A
    sd   x12, 10*8(x14)

    // l3pt[3] : page_a, but not yet accessed
    srli x12, x15, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_D
    sd   x12, 3*8(x14)

    // l3pt[4] stays zero : not mapped

    // l3pt[6] : the code page, readable but not executable
    li   x17, 0x80000000
    srli x12, x17, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_A
    sd   x12, 6*8(x14)

    // l3pt[7] : the code page, executable
    srli x12, x17, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_X | PTE_A
    sd   x12, 7*8(x14)

    //-----------------------------------------------------------------
    // turn translation on and drop to supervisor mode
    //-----------------------------------------------------------------
    la   x10, l1pt
    srli x10, x10, 12
    li   x11, 8
    slli x11, x11, 60                    // MODE = Sv39
    or   x10, x10, x11
    csrw satp, x10
    sfence.vma

    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s
    csrw mepc, t0
    mret

    //-----------------------------------------------------------------
in_s:
    // the identity mapping carries the test itself
    li   x29, 0
    la   x10, page_a
    li   x11, 0x1234
    sd   x11, 0(x10)
    ld   x12, 0(x10)
    TEST_EQ(1, x12, 0x1234)
    TEST_EQ(2, x29, 0)

    // ---- a four kilobyte page, three levels down ----
    li   x20, 0x40000000
    li   x11, 0xABCDEF
    sd   x11, 0(x20)
    TEST_EQ(3, x29, 0)
    la   x10, page_a
    ld   x12, 0(x10)                     // the same place, physically
    TEST_EQ(4, x12, 0xABCDEF)
    ld   x13, 0(x20)
    TEST_EQ(5, x13, 0xABCDEF)

    // ---- read only : the store is a page fault, the load is not ----
    li   x29, 0
    li   x21, 0x40002000
    sd   x11, 0(x21)
    TEST_EQ(6, x29, 1)
    TEST_EQ(7, x28, CAUSE_SPAGE)
    TEST_EQ_REG(8, x27, x21)             // mtval is the virtual address
    li   x29, 0
    ld   x14, 0(x21)
    TEST_EQ(9, x29, 0)
    TEST_EQ(10, x14, 0xABCDEF)

    // ---- nothing mapped there ----
    li   x29, 0
    li   x22, 0x40004000
    ld   x15, 0(x22)
    TEST_EQ(11, x29, 1)
    TEST_EQ(12, x28, CAUSE_LPAGE)

    // ---- a user page is out of reach while SUM is clear ----
    li   x29, 0
    li   x19, 0x40001000
    ld   x16, 0(x19)
    TEST_EQ(13, x29, 1)
    TEST_EQ(14, x28, CAUSE_LPAGE)

    li   t0, 1 << 18                     // SUM
    csrs sstatus, t0
    li   x29, 0
    li   x11, 0x5A5A
    sd   x11, 0(x19)
    ld   x16, 0(x19)
    TEST_EQ(15, x29, 0)
    TEST_EQ(16, x16, 0x5A5A)
    la   x10, page_b
    ld   x17, 0(x10)
    TEST_EQ(17, x17, 0x5A5A)
    csrc sstatus, t0

    // ---- the accessed bit is not set by the hardware ----
    li   x29, 0
    li   x18, 0x40003000
    ld   x15, 0(x18)
    TEST_EQ(18, x29, 1)
    TEST_EQ(19, x28, CAUSE_LPAGE)

    la   x14, l3pt                       // set it and invalidate that page
    ld   x12, 3*8(x14)
    ori  x12, x12, PTE_A
    sd   x12, 3*8(x14)
    sfence.vma x18, x0

    li   x29, 0
    ld   x15, 0(x18)
    TEST_EQ(20, x29, 0)
    TEST_EQ(21, x15, 0xABCDEF)

    // ---- a page that may be written but is not dirty yet ----
    li   x29, 0
    li   x10, 0x4000A000
    ld   x11, 0(x10)                     // reading is allowed
    TEST_EQ(31, x29, 0)
    li   x29, 0
    sd   x11, 0(x10)
    TEST_EQ(32, x29, 1)
    TEST_EQ(33, x28, CAUSE_SPAGE)

    // ---- execute ----
    la   x10, exec_probe
    li   x11, 0x80000000
    sub  x10, x10, x11                   // the offset inside the code page

    li   x29, 0
    li   x12, 0x40006000
    add  x12, x12, x10
    la   x24, 1f
    jalr x1, x12, 0                      // no execute permission
1:
    TEST_EQ(22, x29, 1)
    TEST_EQ(23, x28, CAUSE_IPAGE)
    TEST_EQ_REG(24, x26, x12)            // mepc is the address it jumped to

    li   x29, 0
    li   x13, 0x40007000
    add  x13, x13, x10
    li   x30, 0
    jalr x1, x13, 0                      // this one may be executed
    TEST_EQ(25, x29, 0)
    TEST_EQ(26, x30, 0x600D)

    // ---- a two megabyte page ----
    li   x14, 0x40200000
    ld   x15, 0(x14)
    li   x16, 0x80000000
    ld   x17, 0(x16)
    TEST_EQ_REG(27, x15, x17)
    li   x18, 0x1FF8                     // the last double word of the page,
    add  x14, x14, x18                   // which holds a marker so that an
    add  x16, x16, x18                   // address built the wrong way reads
    ld   x15, 0(x14)                     // something else
    ld   x17, 0(x16)
    TEST_EQ_REG(28, x15, x17)
    li   x19, 0x5A5AA5A5
    TEST_EQ_REG(280, x15, x19)

    // ---- SFENCE.VMA with an address takes the old entry away ----
    la   x14, l3pt
    la   x16, page_b
    srli x12, x16, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd   x12, 0*8(x14)                   // 4000_0000 now points at page_b
    sfence.vma x20, x0
    li   x29, 0
    ld   x15, 0(x20)
    TEST_EQ(29, x29, 0)
    TEST_EQ(30, x15, 0x5A5A)             // what was written into page_b

    // ---- a virtual address that is not a sign extension of bit 38 ----
    //      Its page number is the one of the identity mapping, so only the
    //      bits above 38 can make it fail.
    li   x29, 0
    li   x10, 1
    slli x10, x10, 39
    li   x11, 0x80000000
    add  x10, x10, x11
    ld   x11, 0(x10)
    TEST_EQ(34, x29, 1)
    TEST_EQ(35, x28, CAUSE_LPAGE)

    // ---- the first level entry itself is not valid ----
    li   x29, 0
    li   x10, 3
    slli x10, x10, 30                    // C000_0000
    ld   x11, 0(x10)
    TEST_EQ(36, x29, 1)
    TEST_EQ(37, x28, CAUSE_LPAGE)

    // ---- write without read is a reserved encoding ----
    la   x14, l3pt
    la   x15, page_a
    srli x13, x15, 12
    slli x13, x13, 10
    li   x12, PTE_V | PTE_W | PTE_A | PTE_D
    or   x12, x12, x13
    sd   x12, 8*8(x14)                   // 4000_8000
    // ---- and one that may only be executed ----
    li   x12, PTE_V | PTE_X | PTE_A
    or   x12, x12, x13
    sd   x12, 9*8(x14)                   // 4000_9000
    sfence.vma

    li   x29, 0
    li   x10, 0x40008000
    ld   x11, 0(x10)
    TEST_EQ(38, x29, 1)
    TEST_EQ(39, x28, CAUSE_LPAGE)

    li   x29, 0
    li   x10, 0x40009000
    ld   x11, 0(x10)
    TEST_EQ(40, x29, 1)
    TEST_EQ(41, x28, CAUSE_LPAGE)

    li   t0, 1 << 19                     // MXR : execute counts as read
    csrs sstatus, t0
    li   x29, 0
    ld   x11, 0(x10)
    TEST_EQ(42, x29, 0)
    TEST_EQ(43, x11, 0xABCDEF)
    csrc sstatus, t0

    // ---- a superpage whose page number is not aligned to its size ----
    la   x13, l2pt
    li   x12, 0x80001000                 // not a multiple of two megabytes
    srli x12, x12, 12
    slli x12, x12, 10
    ori  x12, x12, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
    sd   x12, 2*8(x13)                   // 4040_0000
    sfence.vma
    li   x29, 0
    li   x10, 0x40400000
    ld   x11, 0(x10)
    TEST_EQ(44, x29, 1)
    TEST_EQ(45, x28, CAUSE_LPAGE)

    // ---- and the same one level up ----
    li   x29, 0
    li   x10, 1
    slli x10, x10, 32                    // 1_0000_0000
    ld   x11, 0(x10)
    TEST_EQ(51, x29, 1)
    TEST_EQ(52, x28, CAUSE_LPAGE)

    //-----------------------------------------------------------------
    // user mode, out of the gigabyte mapped at zero
    //-----------------------------------------------------------------
    li   x31, 0x80000000
    la   t0, in_u
    sub  t0, t0, x31                     // the same code, seen from zero
    csrw sepc, t0
    li   t0, 1 << 8
    csrc sstatus, t0                     // SPP = U
    sret

in_u:
    // a user page is reachable
    li   x29, 0
    li   x19, 0x40001000
    ld   x16, 0(x19)
    TEST_EQ(46, x29, 0)
    TEST_EQ(47, x16, 0x5A5A)

    // a supervisor page is not, whatever SUM says
    li   x29, 0
    li   x20, 0x40002000
    ld   x17, 0(x20)
    TEST_EQ(48, x29, 1)
    TEST_EQ(49, x28, CAUSE_LPAGE)

    // ---- back to machine mode, which does not translate ----
    li   x31, 0x80000000
    la   x24, done_in_m
    add  x24, x24, x31
    li   x23, 4 | 3
    ecall

done_in_m:
    // Machine mode does not translate, so taking the execute permission
    // away from the identity mapping changes nothing for the code running
    // here. If it did, this very fetch would fault.
    la   x14, l1pt
    ld   x12, 2*8(x14)
    li   x13, ~PTE_X
    and  x12, x12, x13
    sd   x12, 2*8(x14)
    sfence.vma
    li   x29, 0
    nop
    nop
    nop
    TEST_EQ(50, x29, 0)

    csrw satp, x0                        // translation off again
    sfence.vma
    la   t0, default_trap
    csrw mtvec, t0
    TEST_DONE

    //-----------------------------------------------------------------
    // a target for the execute tests; it is reached through two different
    // virtual addresses and returns to the one it was called from
    //-----------------------------------------------------------------
exec_probe:
    li   x30, 0x600D
    jalr x0, x1, 0

    //-----------------------------------------------------------------
    .align 2
m_trap:
    csrr x28, mcause
    csrr x27, mtval
    csrr x26, mepc
    li   x29, 1
    beq  x23, x0, 1f
    li   t0, 3 << 11
    csrc mstatus, t0
    andi t0, x23, 3
    slli t0, t0, 11
    csrs mstatus, t0
    li   x23, 0
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

    //-----------------------------------------------------------------
    // the last double word of the second four kilobyte page of the image;
    // the two megabyte test reads it through its own mapping
    .section .data
    .align 12
    .space 0xFF8
marker_1ff8:
    .dword 0x5A5AA5A5

    //-----------------------------------------------------------------
    .section .bss
    .align 12
l1pt:   .space 4096
l2pt:   .space 4096
l3pt:   .space 4096
page_a: .space 4096
page_b: .space 4096

    TOHOST_SECTION
