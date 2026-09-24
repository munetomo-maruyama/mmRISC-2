// d01_dma : DMA through the data cache, coherent with the CPU
//
// A DMA master of the test bench (tb_SYS) reads and writes memory through
// the DMA port of CPU_TOP while the CPU holds the same lines in its data
// cache. It is told what to do through a mailbox the CPU does not cache
// (see tb_SYS.sv):
//
//   1 : the CPU leaves a pattern dirty in its cache; a DMA read has to see it
//   2 : the CPU has a buffer in its cache, clean; a DMA write has to reach it
//   3 : the CPU leaves a pattern dirty; a DMA write of bytes 2..5 of every
//       double word has to merge into it
//   4 : the same as 2 and 1 on memory the cache does not hold at all (the
//       uncached window), which the DMA port has to pass on to the bus
//
// pattern(seed, i) = seed + i * 0x9E3779B97F4A7C15
#include "test.h"

#define MBOX   0x10000800
#define N      64
#define K      0x9E3779B97F4A7C15

// x10 addr, x11 n, x12 seed, x13 cmd ; waits, then x14 = mismatches
#define DMA(cmd_)                       \
    li   x20, MBOX;                     \
    sd   x0,  40(x20);                  \
    sd   x10,  8(x20);                  \
    sd   x11, 16(x20);                  \
    sd   x12, 24(x20);                  \
    li   x13, cmd_;                     \
    sd   x13,  0(x20);                  \
1:  ld   x21, 40(x20);                  \
    beqz x21, 1b;                       \
    ld   x14, 32(x20);                  \
    sd   x0,  40(x20);

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    li   x25, K

    //-----------------------------------------------------------------
    // 1 : dirty lines, read by DMA
    //-----------------------------------------------------------------
    la   x10, buf_a
    li   x11, N
    li   x12, 0x1111222233334444
    call fill                          // cached stores : dirty lines
    DMA(1)
    TEST_EQ(1, x14, 0)

    //-----------------------------------------------------------------
    // 2 : clean lines in the cache, written by DMA
    //-----------------------------------------------------------------
    la   x10, buf_b
    li   x11, N
    call touch                         // bring the lines in, clean
    li   x12, 0x5555666677778888
    DMA(2)
    la   x10, buf_b
    li   x11, N
    li   x12, 0x5555666677778888
    call check
    TEST_EQ(2, x14, 0)

    //-----------------------------------------------------------------
    // 3 : dirty lines, bytes 2..5 written by DMA
    //-----------------------------------------------------------------
    la   x10, buf_c
    li   x11, N
    li   x12, 0x0123456789ABCDEF
    call fill
    li   x12, 0xFEDCBA9876543210
    DMA(3)
    call check_merged
    TEST_EQ(3, x14, 0)

    // the same after the cache has written everything back and forgotten
    // it : now it comes from memory
    fence.i
    call check_merged
    TEST_EQ(4, x14, 0)

    //-----------------------------------------------------------------
    // 4 : the uncached window
    //-----------------------------------------------------------------
    li   x10, 0x10000C00
    li   x11, 8
    li   x12, 0x0F0F0F0F0F0F0F0F
    DMA(2)
    li   x10, 0x10000C00
    li   x11, 8
    li   x12, 0x0F0F0F0F0F0F0F0F
    call check
    TEST_EQ(5, x14, 0)
    li   x10, 0x10000C00
    li   x11, 8
    li   x12, 0x0F0F0F0F0F0F0F0F
    DMA(1)
    TEST_EQ(6, x14, 0)

    TEST_DONE

    //-----------------------------------------------------------------
    // fill         : pattern(x12, i) into x11 double words at x10
    // check        : x14 = how many of x11 double words at x10 differ
    // touch        : load x11 double words at x10
    // check_merged : x14 = how many double words of buf_c are not bytes
    //                2..5 of the DMA pattern and the rest of the CPU one
    //-----------------------------------------------------------------
fill:
    li   x15, 0
1:  mul  x17, x15, x25
    add  x17, x17, x12
    slli x18, x15, 3
    add  x18, x18, x10
    sd   x17, 0(x18)
    addi x15, x15, 1
    blt  x15, x11, 1b
    ret

check:
    li   x14, 0
    li   x15, 0
1:  mul  x17, x15, x25
    add  x17, x17, x12
    slli x18, x15, 3
    add  x18, x18, x10
    ld   x19, 0(x18)
    beq  x19, x17, 2f
    addi x14, x14, 1
2:  addi x15, x15, 1
    blt  x15, x11, 1b
    ret

touch:
    li   x15, 0
1:  slli x18, x15, 3
    add  x18, x18, x10
    ld   x19, 0(x18)
    addi x15, x15, 1
    blt  x15, x11, 1b
    ret

check_merged:
    la   x10, buf_c
    li   x14, 0
    li   x15, 0
    li   x16, 0xFFFFFFFF0000                 // bytes 2..5
1:  mul  x17, x15, x25
    li   x18, 0x0123456789ABCDEF
    add  x18, x18, x17                       // what the CPU wrote
    li   x19, 0xFEDCBA9876543210
    add  x19, x19, x17                       // what the DMA wrote
    and  x19, x19, x16
    not  x22, x16
    and  x18, x18, x22
    or   x18, x18, x19
    ld   x23, 0(x10)
    beq  x23, x18, 2f
    addi x14, x14, 1
2:  addi x10, x10, 8
    addi x15, x15, 1
    li   x24, N
    blt  x15, x24, 1b
    ret

    TEST_FAIL_HANDLER

    .section .bss
    .align 6
buf_a:  .space 8 * N
buf_b:  .space 8 * N
buf_c:  .space 8 * N

    TOHOST_SECTION
