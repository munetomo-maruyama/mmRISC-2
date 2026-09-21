// Common frame for the core tests (riscv-tests convention).
//
//   TEST_INIT              : install the default trap handler. Every test
//                            starts with it; a test that wants its own
//                            handler writes mtvec again afterwards
//   TEST_EQ(n, reg, value) : the register has to hold the value, otherwise
//                            the test ends with tohost = (n << 1) | 1
//   TEST_DONE              : tohost = 1
//   TEST_FAIL_HANDLER      : the `fail` label and the default trap handler
//
// gp holds the number of the check that is running. A trap that no test
// expected reports 64 + the cause, and the test bench prints the cause, the
// address and mtval of the last trap on top of that.
//
// The frame uses gp (x3), t0 (x5) and t6 (x31), so a test itself only uses
// x10 .. x30.

#define TEST_INIT                   \
    la   t0, default_trap;          \
    csrw mtvec, t0;

// A test that leaves machine mode needs one PMP entry that lets S and U
// reach everything; without a matching entry they get nothing (M5).
#define INIT_PMP                    \
    li   t0, -1;                    \
    csrw pmpaddr0, t0;              \
    li   t0, 0x1F;                  \
    csrw pmpcfg0, t0;

#define TEST_EQ(n, reg, value)      \
    li   gp, n;                     \
    li   t6, value;                 \
    bne  reg, t6, fail;

#define TEST_EQ_REG(n, a, b)        \
    li   gp, n;                     \
    bne  a, b, fail;

#define TEST_DONE                   \
    li   gp, 1;                     \
    j    write_tohost;

#define TEST_FAIL_HANDLER           \
fail:                               \
    bne  gp, x0, 8f;                \
    li   gp, 98;                    \
8:                                  \
    slli gp, gp, 1;                 \
    ori  gp, gp, 1;                 \
write_tohost:                       \
    la   t0, tohost;                \
    sd   gp, 0(t0);                 \
9:                                  \
    j    9b;                        \
default_trap:                       \
    csrr gp, mcause;                \
    andi gp, gp, 31;                \
    addi gp, gp, 64;                \
    j    fail;

#define TOHOST_SECTION              \
    .section .tohost, "aw";         \
    .align 3;                       \
    .globl tohost;                  \
tohost:                             \
    .dword 0;
