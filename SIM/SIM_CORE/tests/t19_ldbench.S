// t19_ldbench : the start of the C benchmark in t19_ldbench.c
//
// Sets up a stack at the top of the memory both test benches have (64 KiB
// from 8000_0000), clears .bss, runs main, and turns its return value into
// tohost: 0 passes, n fails as check n.
#include "test.h"

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    li   sp, 0x80010000

    la   x10, __bss_start
    la   x11, __bss_end
1:
    bgeu x10, x11, 2f
    sd   x0, 0(x10)
    addi x10, x10, 8
    j    1b
2:
    call main
    mv   gp, a0
    beqz gp, 3f
    j    fail
3:
    TEST_DONE

    TEST_FAIL_HANDLER

    TOHOST_SECTION
