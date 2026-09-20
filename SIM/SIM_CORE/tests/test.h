// Common frame for the core tests (riscv-tests convention).
//
//   TEST_EQ(n, reg, value) : the register has to hold the value, otherwise
//                            the test ends with tohost = (n << 1) | 1
//   TEST_DONE              : tohost = 1, then ECALL to stop the core
//
// gp holds the number of the check that is running.

#define TEST_EQ(n, reg, value)      \
    li   gp, n;                     \
    li   t6, value;                 \
    bne  reg, t6, fail;

#define TEST_DONE                   \
    li   gp, 1;                     \
    la   t0, tohost;                \
    sd   gp, 0(t0);                 \
    ecall;

// gp still being zero means the test failed before the first check; 98 is
// reported instead, because (0 << 1) | 1 is the value of a pass
#define TEST_FAIL_HANDLER           \
fail:                               \
    bne  gp, x0, 8f;                \
    li   gp, 98;                    \
8:                                  \
    slli gp, gp, 1;                 \
    ori  gp, gp, 1;                 \
    la   t0, tohost;                \
    sd   gp, 0(t0);                 \
    ecall;

#define TOHOST_SECTION              \
    .section .tohost, "aw";         \
    .align 3;                       \
    .globl tohost;                  \
tohost:                             \
    .dword 0;
