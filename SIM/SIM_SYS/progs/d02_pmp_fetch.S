// d02_pmp_fetch : a fetch the PMP refuses never reaches the bus
//
// The PMP of the fetch side answers one cycle after the request, when the
// cache takes the physical address, and a refusal cancels the request
// there (i_cancel, CPU_CORE_SPEC.md 6.3). The cache must not have gone to
// memory or to the bus by then: a read of a device can have a side effect.
//
// The target sits in the uncached window, where the instruction cache
// reads single double words over AXI4-Lite, and the test bench counts the
// reads of 0x1000_0F00 (tb_SYS, into 0x1000_0FA0). Supervisor mode jumps
// there; the PMP gives that 64 byte region no execute permission.
//
//   x29 / x28 : a trap happened, its cause ; x24 : where to resume
#include "test.h"

#define TARGET 0x10000F00
#define COUNT  0x10000FA0

    .section .text.init
    .globl _start
_start:
    TEST_INIT
    la   t0, m_trap
    csrw mtvec, t0
    li   x29, 0
    li   x24, 0

    // entry 0 : 64 bytes at TARGET, read and write, no execute
    // entry 1 : everything
    li   x10, TARGET
    srli x10, x10, 2
    ori  x10, x10, 0x7
    csrw pmpaddr0, x10
    li   x10, -1
    csrw pmpaddr1, x10
    li   x10, (0x1F << 8) | 0x1B
    csrw pmpcfg0, x10

    // a return at the target, in case the fetch were not refused
    li   x10, TARGET
    li   x11, 0x00008067                 // jalr x0, 0(x1)
    sw   x11, 0(x10)
    li   x10, COUNT
    sd   x0, 0(x10)

    li   t0, 3 << 11
    csrc mstatus, t0
    li   t0, 1 << 11
    csrs mstatus, t0                     // MPP = S
    la   t0, in_s
    csrw mepc, t0
    mret

in_s:
    li   x29, 0
    li   x18, TARGET
    la   x24, 1f
    jalr x1, x18, 0
1:
    TEST_EQ(1, x29, 1)
    TEST_EQ(2, x28, 1)                   // instruction access fault
    li   x10, COUNT
    ld   x11, 0(x10)
    TEST_EQ(3, x11, 0)                   // and nothing went to the bus
    TEST_DONE

    .align 2
m_trap:
    csrr x28, mcause
    li   x29, 1
    csrw mepc, x24
    li   x24, 0
    mret

    TEST_FAIL_HANDLER
    TOHOST_SECTION
