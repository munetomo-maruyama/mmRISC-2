// t13_pmp : physical memory protection
//
// rv64mi-p-pmpaddr only checks what the registers keep of what is written to
// them. This one checks that the entries actually stop an access: the entry
// with the lowest number decides, machine mode walks past an entry that is
// not locked and is bound by one that is, and the three permissions are told
// apart.
//
//   entry 0 : 64 bytes around no_x_code, read and write but no execute
//   entry 1 : 64 bytes around prot_data, read only
//   entry 2 : everything, read write execute
//
//   x29 / x28 / x27 / x26 : a trap happened (1 in M, 2 in S), its cause,
//                           tval, epc
//   x24 : where the handler resumes (0 : behind the instruction)
//   x23 : if not zero, the handler sets MPP to x23[1:0] before MRET
#include "test.h"

#define PMP_R    0x01
#define PMP_W    0x02
#define PMP_X    0x04
#define PMP_NAPOT 0x18
#define PMP_L    0x80

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   t0, m_trap
    csrw mtvec, t0
    li   x29, 0
    li   x24, 0
    li   x23, 0

    // ---- the entries ----
    la   x10, no_x_code
    srli x10, x10, 2
    ori  x10, x10, 0x7                   // NAPOT, 64 bytes
    csrw pmpaddr0, x10

    la   x11, prot_data
    srli x11, x11, 2
    ori  x11, x11, 0x7
    csrw pmpaddr1, x11

    li   x12, -1                         // NAPOT, everything
    csrw pmpaddr2, x12

    li   x13, (PMP_NAPOT | PMP_R | PMP_W)                 /* entry 0 */   \
            | ((PMP_NAPOT | PMP_R) << 8)                  /* entry 1 */   \
            | ((PMP_NAPOT | PMP_R | PMP_W | PMP_X) << 16) /* entry 2 */
    csrw pmpcfg0, x13
    csrr x14, pmpcfg0
    TEST_EQ_REG(1, x14, x13)

    //-----------------------------------------------------------------
    // machine mode walks past an entry that is not locked
    //-----------------------------------------------------------------
    li   x29, 0
    la   x15, prot_data
    li   x16, 0x1234
    sd   x16, 0(x15)                     // entry 1 says read only ...
    TEST_EQ(2, x29, 0)                   // ... but M is not bound by it
    ld   x17, 0(x15)
    TEST_EQ(3, x17, 0x1234)

    li   x29, 0
    la   x18, no_x_code
    jalr x1, x18, 0                      // entry 0 says no execute ...
    TEST_EQ(4, x29, 0)                   // ... and M walks past that too

    //-----------------------------------------------------------------
    // into supervisor mode
    //-----------------------------------------------------------------
    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s
    csrw mepc, t0
    mret

in_s:
    // the read only entry now stops a store
    li   x29, 0
    la   x15, prot_data
    li   x16, 0x5678
    sd   x16, 0(x15)
    TEST_EQ(5, x29, 1)
    TEST_EQ(6, x28, 7)                   // store access fault
    TEST_EQ_REG(7, x27, x15)             // mtval is the address
    ld   x17, 0(x15)                     // reading is allowed
    TEST_EQ(8, x17, 0x1234)

    // and the entry without execute stops a fetch
    li   x29, 0
    la   x18, no_x_code
    la   x24, 1f                         // the handler cannot step over an
    jalr x1, x18, 0                      // instruction it could not fetch
1:
    TEST_EQ(9, x29, 1)
    TEST_EQ(10, x28, 1)                  // instruction access fault
    TEST_EQ_REG(11, x26, x18)            // mepc is the address it jumped to

    // reading the same place is allowed
    li   x29, 0
    ld   x19, 0(x18)
    TEST_EQ(12, x29, 0)

    // an access that hangs over the edge of an entry is refused as a whole:
    // the last eight bytes of the read only region plus the eight behind it
    la   x15, prot_data
    addi x20, x15, 56
    li   x29, 0
    ld   x21, 0(x20)                     // inside : allowed
    TEST_EQ(13, x29, 0)
    li   x29, 0
    sd   x21, 64(x20)                    // behind it : entry 2, allowed
    TEST_EQ(14, x29, 0)

    // back to machine mode
    la   x24, back_in_m
    li   x23, 4 | 3
    ecall

back_in_m:
    //-----------------------------------------------------------------
    // MPRV : a data access is checked as if it came from MPP
    //-----------------------------------------------------------------
    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, (1 << 11) | (1 << 17)       // MPP = S and MPRV
    csrs mstatus, t0

    li   x29, 0                          // a fetch is not affected by MPRV
    la   x18, no_x_code
    jalr x1, x18, 0
    TEST_EQ(22, x29, 0)

    li   x29, 0                          // a store is
    la   x15, prot_data
    li   x16, 0xDEAD
    sd   x16, 0(x15)
    TEST_EQ(23, x29, 1)
    TEST_EQ(24, x28, 7)

    li   t0, 1 << 17                     // without MPRV it is M again
    csrc mstatus, t0
    li   x29, 0
    sd   x16, 0(x15)
    TEST_EQ(25, x29, 0)
    ld   x17, 0(x15)
    TEST_EQ(26, x17, 0xDEAD)
    li   x16, 0x1234
    sd   x16, 0(x15)

    //-----------------------------------------------------------------
    // a locked entry binds machine mode as well
    //-----------------------------------------------------------------
    li   x13, (PMP_NAPOT | PMP_R | PMP_W)                                  \
            | (((PMP_NAPOT | PMP_R) | PMP_L) << 8)                         \
            | ((PMP_NAPOT | PMP_R | PMP_W | PMP_X) << 16)
    csrw pmpcfg0, x13

    li   x29, 0
    la   x15, prot_data
    li   x16, 0x9ABC
    sd   x16, 0(x15)
    TEST_EQ(15, x29, 1)
    TEST_EQ(16, x28, 7)                  // store access fault, in M mode
    li   x29, 0
    ld   x17, 0(x15)                     // reading is still allowed
    TEST_EQ(17, x29, 0)
    TEST_EQ(18, x17, 0x1234)

    // the locked entry cannot be changed any more
    li   x14, (PMP_NAPOT | PMP_R | PMP_W | PMP_X) << 8
    csrs pmpcfg0, x14
    csrr x14, pmpcfg0
    srli x14, x14, 8
    andi x14, x14, 0xFF
    li   x15, PMP_NAPOT | PMP_R | PMP_L
    TEST_EQ_REG(19, x14, x15)

    // nor can its address
    csrr x20, pmpaddr1
    li   x21, 0
    csrw pmpaddr1, x21
    csrr x21, pmpaddr1
    TEST_EQ_REG(20, x21, x20)

    // the entries behind it are still free
    li   x21, 0x1234
    csrw pmpaddr3, x21
    csrr x22, pmpaddr3
    TEST_EQ_REG(21, x22, x21)

    //-----------------------------------------------------------------
    // the entries this core does not check still have to answer
    //
    //   The privileged specification lets an implementation provide zero,
    //   sixteen or sixty four entries, and asks that the CSRs of the ones
    //   it does not provide read as zero instead of raising an illegal
    //   instruction. This core checks eight and shows sixteen.
    //-----------------------------------------------------------------
    li   x29, 0
    li   x21, -1

    csrw pmpaddr8, x21
    csrr x22, pmpaddr8
    TEST_EQ(22, x22, 0)

    csrw pmpaddr15, x21
    csrr x22, pmpaddr15
    TEST_EQ(23, x22, 0)

    csrw pmpcfg2, x21
    csrr x22, pmpcfg2
    TEST_EQ(24, x22, 0)

    TEST_EQ(25, x29, 0)                  // and none of that trapped

    //-----------------------------------------------------------------
    // a refused fetch whose trap is delegated to S
    //
    //   The hart stays in S after the trap, so the entry that refused the
    //   fetch still applies when fetching starts again at stvec. The fetch
    //   unit finds a refusal one cycle after the request (CPU_CORE_SPEC.md
    //   6.3) and must take it for that request only, not for an address it
    //   still holds from before.
    //-----------------------------------------------------------------
    li   t0, 1 << 1                      // instruction access fault to S
    csrs medeleg, t0
    la   t0, s_trap
    csrw stvec, t0
    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s2
    csrw mepc, t0
    mret

in_s2:
    li   x29, 0
    la   x18, no_x_code
    la   x24, 1f
    jalr x1, x18, 0
1:
    TEST_EQ(27, x29, 2)                  // taken in S
    TEST_EQ(28, x28, 1)                  // instruction access fault
    TEST_EQ_REG(29, x26, x18)
    la   x24, back_in_m2
    li   x23, 4 | 3                      // back in M
    ecall                                // not delegated : to M
back_in_m2:
    TEST_EQ(30, x28, 9)
    li   t0, 1 << 1
    csrc medeleg, t0

    la   t0, default_trap
    csrw mtvec, t0
    TEST_DONE

    //-----------------------------------------------------------------
    // a piece of code in its own 64 byte region
    //-----------------------------------------------------------------
    .align 6
no_x_code:
    jalr x0, x1, 0
    .align 6

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

    //-----------------------------------------------------------------
    // supervisor trap handler : records like the machine one (x29 = 2)
    //-----------------------------------------------------------------
    .align 2
s_trap:
    csrr x28, scause
    csrr x27, stval
    csrr x26, sepc
    li   x29, 2
    csrw sepc, x24
    li   x24, 0
    sret

    TEST_FAIL_HANDLER

    .section .data
    .align 6
prot_data:
    .dword 0, 0, 0, 0, 0, 0, 0, 0
    .dword 0, 0, 0, 0, 0, 0, 0, 0

    TOHOST_SECTION
