// t17_btb : the branch target buffer, and the one case it must not get wrong
//
// The predictor is transparent by design: every existing test would still
// pass with it removed. What needs a test of its own is the misfetch the
// fetch unit has to catch.
//
// The buffer works on eight byte words, so a prediction throws away the
// parcels behind the branch. The entry was written from a branch that
// really executed, but the same bytes can be decoded at another alignment
// if the program jumps into the middle of an instruction. Then an
// instruction can begin exactly where the word was cut, and its second half
// would come from the predicted target -- an instruction that exists on
// neither path. The fetch unit has to notice and fetch again.
//
// The block below is built so that the same eight bytes decode two ways:
//
//   entered at W    : bne x6, x0, W+8      (parcels 0 and 1)
//   entered at W-2  : addi x21, x6, 326    (parcels -1 and 0)
//                     lb   x0, 0(x10)      (parcels 1 and 2)
//                     c.li x20, 1          (parcel 3)
//
// 0x1463 is both the low half of the bne and the high half of the addi;
// 0x0003 is both the high half of the bne and the low half of the lb. A
// core without a predictor decodes whatever the alignment gives it, and so
// must this one.
#include "test.h"

    .section .text.init
    .globl _start
_start:
    TEST_INIT

    //-----------------------------------------------------------------
    // 1. a loop the buffer should learn
    //-----------------------------------------------------------------
    li   x10, 0
    li   x11, 0
    li   x12, 64
1:
    add  x10, x10, x11
    addi x11, x11, 1
    blt  x11, x12, 1b
    TEST_EQ(1, x10, 2016)                // 63*64/2

    //-----------------------------------------------------------------
    // 2. a call and a return, both of them indirect targets
    //-----------------------------------------------------------------
    li   x13, 0
    li   x11, 0
2:
    jal  x1, leaf
    add  x13, x13, x14
    addi x11, x11, 1
    blt  x11, x12, 2b
    TEST_EQ(2, x13, 64 * 7)

    //-----------------------------------------------------------------
    // 3. the same branch, taken and then not taken
    //-----------------------------------------------------------------
    li   x15, 0
    li   x11, 0
3:
    addi x11, x11, 1
    addi x15, x15, 1
    li   x16, 8
    blt  x11, x16, 3b                    // taken seven times, then not
    TEST_EQ(3, x15, 8)

    //-----------------------------------------------------------------
    // 4. the misfetch
    //
    //    First walk the block the ordinary way, so the buffer learns that
    //    the word begins with a 32 bit branch. Then enter it two bytes
    //    earlier, where the bytes mean something else entirely.
    //-----------------------------------------------------------------
    li   x6, 1                           // the branch is taken
    li   x20, 0
    li   x21, 0
    la   x10, scratch                    // the load below needs an address

    la   x17, wblock
    li   x18, 0
    li   x19, 4
4:
    jalr x1, x17, 0                      // path A, three times over, so the
    addi x18, x18, 1                     // entry is strongly taken
    blt  x18, x19, 4b
    TEST_EQ(4, x20, 0)                   // path A runs none of the others

    la   x17, wblock
    addi x17, x17, -2                    // path B : into the middle
    jalr x1, x17, 0
    TEST_EQ(5, x21, 327)                 // addi x21, x6, 326
    TEST_EQ(6, x20, 1)                   // c.li x20, 1

    TEST_DONE

leaf:
    li   x14, 7
    jalr x0, x1, 0

    //-----------------------------------------------------------------
    // the block whose bytes mean two things
    //-----------------------------------------------------------------
    .align 3
wpre:
    .half 0x0001                         // W-8 : c.nop
    .half 0x0001                         // W-6 : c.nop
    .half 0x0001                         // W-4 : c.nop
    .half 0x0a93                         // W-2 : low half of addi x21,x6,326
wblock:
    .half 0x1463                         // low half of bne / high half of addi
    .half 0x0003                         // high half of bne / low half of lb
    .half 0x0005                         // high half of lb x0, 0(x10)
    .half 0x4a05                         // c.li x20, 1
    jalr x0, x1, 0                       // W+8 : both paths end up here

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0

    TOHOST_SECTION
