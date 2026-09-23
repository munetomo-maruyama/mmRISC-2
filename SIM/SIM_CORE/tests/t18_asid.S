// t18_asid : a prediction left behind by another address space
//
// The branch target buffer is tagged with the virtual address alone and is
// flushed by fence.i and SFENCE.VMA, but not by a write to satp. An
// operating system that gives every process an ASID switches satp without a
// fence, so a branch one process has taught the buffer can be looked up at
// the same address in another process, where something else lives. The
// core has to execute what is there, whatever the buffer says.
//
// Two page tables map the same virtual page, 4000_0000, to two different
// physical pages:
//
//   ASID 1 : page_1, three taken branches
//   ASID 2 : page_2, at the same three addresses: an addition, a load and a
//            division (which holds EX for many cycles while it is marked).
//            In each, the instruction at +4 is the one a core that follows
//            the stale prediction (taken, to +8) would skip.
//
// The code of both pages is copied from the snippets below and made
// visible to the fetch side with fence.i; the snippets are position
// independent. The rest of the test (VA 8000_0000) is mapped the same way
// in both tables, as one gigabyte page.
//
// The three places are 0x40 apart so that they fall on three different
// entries of the buffer (it is indexed with bits 8:3 of the address);
// 0x100 apart, the first and the third shared one and the first was
// never predicted at all.
//
//   x20 .. x23 : what the snippets add up
#include "test.h"

#define PTE_V 0x001
#define PTE_R 0x002
#define PTE_W 0x004
#define PTE_X 0x008
#define PTE_A 0x040
#define PTE_D 0x080

#define ALIAS 0x40000000

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    INIT_PMP

    //-----------------------------------------------------------------
    // the two pages of code
    //-----------------------------------------------------------------
    la   x10, snip_1
    la   x11, page_1
    li   x12, 0x100 / 8
    call copy
    la   x10, snip_2
    la   x11, page_2
    li   x12, 0x100 / 8
    call copy
    fence.i

    //-----------------------------------------------------------------
    // the two page tables, each root -> l2 -> l3 -> one page at ALIAS
    //-----------------------------------------------------------------
    la   x10, root_1
    li   x11, 6 * 512
1:
    sd   x0, 0(x10)
    addi x10, x10, 8
    addi x11, x11, -1
    bnez x11, 1b

    la   x10, root_1
    la   x11, l2_1
    la   x12, l3_1
    la   x13, page_1
    call build
    la   x10, root_2
    la   x11, l2_2
    la   x12, l3_2
    la   x13, page_2
    call build

    //-----------------------------------------------------------------
    // ASID 1, and every translation of both tables fenced once
    //-----------------------------------------------------------------
    la   x10, root_1
    srli x10, x10, 12
    li   x11, 8
    slli x11, x11, 60                    // MODE = Sv39
    or   x10, x10, x11
    li   x11, 1
    slli x11, x11, 44                    // ASID = 1
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
    li   x20, 0
    li   x21, 0
    li   x22, 0
    li   x23, 0
    li   x24, 0x1234
    la   x25, data_word

    // teach the buffer the three branches of ASID 1
    li   x13, 4
1:
    li   x14, ALIAS + 0x000
    jalr x1, x14, 0
    li   x14, ALIAS + 0x040
    jalr x1, x14, 0
    li   x14, ALIAS + 0x080
    jalr x1, x14, 0
    addi x13, x13, -1
    bnez x13, 1b
    TEST_EQ(1, x20, 0)
    TEST_EQ(2, x21, 12)

    // ASID 2, no fence: the architecture allows it, since ASID 2 has not
    // been used since the last SFENCE.VMA
    la   x10, root_2
    srli x10, x10, 12
    li   x11, 8
    slli x11, x11, 60
    or   x10, x10, x11
    li   x11, 2
    slli x11, x11, 44                    // ASID = 2
    or   x10, x10, x11
    csrw satp, x10

    li   x14, ALIAS + 0x000              // an addition where a branch was
    jalr x1, x14, 0
    TEST_EQ(3, x20, 3)
    TEST_EQ(4, x22, 1)

    li   x14, ALIAS + 0x040              // a load where a branch was
    jalr x1, x14, 0
    TEST_EQ(5, x23, 0x5A5A)
    TEST_EQ(6, x20, 3 + 0x5A5A)
    TEST_EQ(7, x22, 2)

    li   x26, 7
    li   x14, ALIAS + 0x080              // a division where a branch was
    jalr x1, x14, 0
    TEST_EQ(8, x24, 0x1234 / 7)
    TEST_EQ(9, x20, 7 + 0x5A5A)
    TEST_EQ(10, x22, 3)

    // once more: the buffer is not told, so the same thing happens again
    li   x14, ALIAS + 0x000
    jalr x1, x14, 0
    TEST_EQ(11, x20, 10 + 0x5A5A)
    TEST_EQ(12, x22, 4)

    // and back to ASID 1: the branches are still branches
    la   x10, root_1
    srli x10, x10, 12
    li   x11, 8
    slli x11, x11, 60
    or   x10, x10, x11
    li   x11, 1
    slli x11, x11, 44
    or   x10, x10, x11
    csrw satp, x10
    li   x14, ALIAS + 0x040
    jalr x1, x14, 0
    TEST_EQ(13, x21, 13)
    TEST_EQ(14, x20, 10 + 0x5A5A)

    TEST_DONE

    //-----------------------------------------------------------------
    // copy x12 double words from x10 to x11
    //-----------------------------------------------------------------
copy:
    ld   x13, 0(x10)
    sd   x13, 0(x11)
    addi x10, x10, 8
    addi x11, x11, 8
    addi x12, x12, -1
    bnez x12, copy
    ret

    //-----------------------------------------------------------------
    // x10 root, x11 l2, x12 l3, x13 the page to put at ALIAS
    //-----------------------------------------------------------------
build:
    // root[2] : 8000_0000 as one gigabyte, the test itself
    li   x14, 0x80000000
    srli x14, x14, 12
    slli x14, x14, 10
    ori  x14, x14, PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
    sd   x14, 2*8(x10)
    // root[1] -> l2 -> l3 -> the page, not global
    srli x14, x11, 12
    slli x14, x14, 10
    ori  x14, x14, PTE_V
    sd   x14, 1*8(x10)
    srli x14, x12, 12
    slli x14, x14, 10
    ori  x14, x14, PTE_V
    sd   x14, 0(x11)
    srli x14, x13, 12
    slli x14, x14, 10
    ori  x14, x14, PTE_V | PTE_R | PTE_X | PTE_A
    sd   x14, 0(x12)
    ret

    TEST_FAIL_HANDLER

    //-----------------------------------------------------------------
    // the code of the two pages, copied there at the start. No compressed
    // instructions, so that every one of them sits where the comments say.
    //-----------------------------------------------------------------
    .option push
    .option norvc
    .balign 0x100, 0
snip_1:
    // +0x000
    beq  x0, x0, 1f                      // taken, to +0x008
    addi x20, x20, 100
1:  addi x21, x21, 1
    jalr x0, x1, 0
    .balign 0x40, 0
    // +0x040
    beq  x0, x0, 1f
    addi x20, x20, 100
1:  addi x21, x21, 1
    jalr x0, x1, 0
    .balign 0x40, 0
    // +0x080
    beq  x0, x0, 1f
    addi x20, x20, 100
1:  addi x21, x21, 1
    jalr x0, x1, 0
    .balign 0x40, 0

    .balign 0x100, 0
snip_2:
    // +0x000 : the buffer says "taken to +0x008"
    addi x20, x20, 1
    addi x20, x20, 2
    addi x22, x22, 1
    jalr x0, x1, 0
    .balign 0x40, 0
    // +0x040 : a load, and the instruction right behind uses it
    ld   x23, 0(x25)
    add  x20, x20, x23
    addi x22, x22, 1
    jalr x0, x1, 0
    .balign 0x40, 0
    // +0x080 : a division holds EX while it is marked
    divu x24, x24, x26
    addi x20, x20, 4
    addi x22, x22, 1
    jalr x0, x1, 0
    .balign 0x40, 0
    .option pop

    //-----------------------------------------------------------------
    .section .data
    .align 3
data_word:
    .dword 0x5A5A

    .section .bss
    .align 12
root_1: .space 4096
root_2: .space 4096
l2_1:   .space 4096
l2_2:   .space 4096
l3_1:   .space 4096
l3_2:   .space 4096
page_1: .space 4096
page_2: .space 4096

    TOHOST_SECTION
