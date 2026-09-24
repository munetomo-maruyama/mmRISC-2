// d03_fencei : fence.i waits for the write back before the refetch
//
// fence.i writes the whole data cache back and only then invalidates the
// instruction cache and fetches again (CPU_CACHE_SPEC.md 5.3). If the
// fetch could start before the write back had finished, a line of code
// that was changed through the data cache could be read from memory while
// memory still holds the old instruction.
//
// To give that race room, the data cache is filled with dirty lines first
// and the changed code sits in set 63, the last one the write back reaches
// (0x8000_1FC0 : bits 11..6 all ones).
#include "test.h"

#define LI_A0_2 0x00200513                 // addi a0, x0, 2

    .section .text.init
    .globl _start
_start:
    TEST_INIT

    call patch_site
    TEST_EQ(1, x10, 1)                     // the code as it was

    // every line of the data cache dirty (16 KiB)
    la   x11, fill_buf
    li   x12, 16384 / 8
1:  sd   x12, 0(x11)
    addi x11, x11, 8
    addi x12, x12, -1
    bnez x12, 1b

    // change the code, through the data cache
    la   x11, patch_site
    li   x12, LI_A0_2
    sw   x12, 0(x11)
    fence.i

    call patch_site
    TEST_EQ(2, x10, 2)                     // the code as it is now
    TEST_DONE

    TEST_FAIL_HANDLER

    //-----------------------------------------------------------------
    .section .data
    .org 0xFC0                             // 0x8000_1FC0, set 63
patch_site:
    addi x10, x0, 1
    jalr x0, x1, 0

    .section .bss
    .align 6
fill_buf: .space 16384

    TOHOST_SECTION
