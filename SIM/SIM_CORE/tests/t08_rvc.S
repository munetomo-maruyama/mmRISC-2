// t08_rvc : the C extension
//
// The file is built with C, so the frame and the checks are compressed by the
// assembler wherever it can; on top of that the instructions of the extension
// are written out and the awkward cases of the fetch are built by hand:
// a 32 bit instruction across a word boundary and a branch into the middle
// of a word.
#include "test.h"
    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   x2, stack                       // the forms with the stack pointer

    // ---- the register forms ----
    li   x10, 5
    li   x11, 7
    c.mv   x12, x10
    TEST_EQ(1, x12, 5)
    c.add  x12, x11
    TEST_EQ(2, x12, 12)
    c.sub  x12, x10
    TEST_EQ(3, x12, 7)
    c.and  x12, x10
    TEST_EQ(4, x12, 5)
    c.or   x12, x11
    TEST_EQ(5, x12, 7)
    c.xor  x12, x11
    TEST_EQ(6, x12, 0)

    li   x13, 0x123
    c.addi x13, 1
    TEST_EQ(7, x13, 0x124)
    // ADDIW is not ADDI: the result is the low half, sign extended.
    // 0x7FFFFFFF is built without an ADDIW, so that the check cannot be
    // cancelled out by the way the assembler loads the constant.
    lui  x13, 0x80000
    srli x13, x13, 33
    c.addiw x13, 1
    TEST_EQ(8, x13, 0xFFFFFFFF80000000)
    c.li   x14, -8
    TEST_EQ(9, x14, -8)
    c.lui  x15, 0x12
    TEST_EQ(10, x15, 0x12000)

    // the shift and the AND with an immediate only reach x8 .. x15
    li   x8, 1
    c.slli x8, 40
    TEST_EQ(11, x8, 0x10000000000)
    c.srli x8, 36
    TEST_EQ(12, x8, 0x10)
    li   x9, -256
    c.srai x9, 4
    TEST_EQ(13, x9, -16)
    c.andi x9, 7
    TEST_EQ(14, x9, 0)

    li   x12, 0x100000002
    li   x13, 0x200000003
    c.addw x12, x13
    TEST_EQ(15, x12, 5)
    c.subw x12, x13
    TEST_EQ(16, x12, 2)                  // SUBW works on the low half

    // ---- the memory forms ----
    la   x10, scratch
    li   x11, 0x0123456789ABCDEF
    c.sd   x11, 0(x10)
    c.ld   x12, 0(x10)
    TEST_EQ(17, x12, 0x0123456789ABCDEF)
    // the immediate of C.LW is not the one of C.LD: different words are put
    // at 4 and 8 and read back through the compressed form
    li   x12, 0x11112222
    sw   x12, 4(x10)
    li   x12, 0x33334444
    sw   x12, 8(x10)
    c.lw   x13, 4(x10)
    TEST_EQ(18, x13, 0x11112222)
    c.lw   x13, 8(x10)
    TEST_EQ(45, x13, 0x33334444)
    c.sw   x13, 12(x10)
    lw   x13, 12(x10)
    TEST_EQ(46, x13, 0x33334444)
    c.sdsp x11, 16(x2)                   // x2 is the stack pointer
    c.ldsp x14, 16(x2)
    TEST_EQ(19, x14, 0x0123456789ABCDEF)
    c.swsp x11, 24(x2)
    c.lwsp x15, 24(x2)
    TEST_EQ(20, x15, 0xFFFFFFFF89ABCDEF)
    c.addi4spn x10, x2, 8
    addi x16, x2, 8
    TEST_EQ_REG(21, x10, x16)

    // ---- the jumps ----
    li   gp, 22
    c.j  1f
    j    fail
1:
    li   x17, 0
    la   x18, 2f
    c.jr x18
    j    fail
2:
    li   gp, 23
    la   x19, 3f
    c.jalr x19                           // the link goes into x1
jalr_link:
    j    fail
3:
    la   x20, jalr_link                  // the address behind the c.jalr
    li   gp, 24
    bne  x1, x20, fail

    // ---- the branches of the extension ----
    li   x14, 0
    c.beqz x14, 4f
    j    fail
4:
    li   x14, 1
    c.bnez x14, 5f
    j    fail
5:
    li   gp, 25

    // ---- a 32 bit instruction across the boundary of a fetch word ----
    .balign 8
    c.nop
    c.nop
    c.nop
    lui  x22, 0x54321                    // starts six bytes into the word
    TEST_EQ(26, x22, 0x54321000)

    .balign 8
    c.nop
    c.nop
    c.nop
    jal  x23, 6f                         // a jump across the boundary too
    j    fail
6:
    li   gp, 27

    // ---- a branch into the middle of a word ----
    li   x24, 1
    beqz x24, fail
    j    7f
    .balign 8
    c.nop
    c.nop
    c.nop
7:                                       // six bytes into the word
    li   gp, 28
    c.nop
    li   x25, 0x77
    TEST_EQ(29, x25, 0x77)

    // ---- a C.J whose target is far enough that the high bits of the
    //      offset matter ----
    li   gp, 47
    c.j  far_target
    .space 160
far_target:
    li   x26, 0x5A
    TEST_EQ(48, x26, 0x5A)

    // ---- a compressed EBREAK ----
    la   x10, skip_trap
    csrw mtvec, x10
    li   x29, 0
    c.ebreak
    TEST_EQ(30, x29, 1)
    TEST_EQ(31, x28, 3)                  // breakpoint
    // mepc is the address of the c.ebreak, and it is two bytes wide, so the
    // handler adds two
    TEST_EQ(32, x27, 2)

    // ---- an illegal compressed instruction reports its two bytes ----
    li   x29, 0
    .half 0x0000                         // not an instruction
    TEST_EQ(33, x29, 1)
    TEST_EQ(34, x28, 2)                  // illegal instruction
    TEST_EQ(35, x26, 0)                  // mtval is the parcel

    la   x10, default_trap
    csrw mtvec, x10
    TEST_DONE

    // the handler steps over the instruction that trapped, 2 or 4 bytes wide
    // (x27 says how much), and remembers the cause in x28 and mtval in x26
    .balign 4
skip_trap:
    csrr x28, mcause
    csrr x26, mtval
    csrr t0, mepc
    lhu  t6, 0(t0)                       // how wide is the instruction
    andi t6, t6, 3
    li   x30, 3
    li   x27, 4
    beq  t6, x30, 8f
    li   x27, 2
8:
    add  t0, t0, x27
    csrw mepc, t0
    li   x29, 1
    mret

    TEST_FAIL_HANDLER

    .section .data
    .align 3
scratch:
    .dword 0, 0, 0, 0, 0, 0, 0, 0
stack:
    .dword 0, 0, 0, 0, 0, 0, 0, 0

    TOHOST_SECTION
