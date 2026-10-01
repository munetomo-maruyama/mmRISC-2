// crt.S : start of a C program on the bare machine of SIM_SYS (tb_SYS)
//
// Machine mode, physical addresses. The stack is at the top of the 2 MiB of
// memory the bench has, the floating point unit is switched on (newlib and
// the benchmarks use it), .bss is cleared, and the return value of main
// becomes tohost: 0 passes (tohost = 1), n fails (tohost = n << 1 | 1).
// A trap that nobody expects ends the run as a failure with 64 + mcause.

    .section .text.init
    .globl _start
_start:
    la   t0, trap
    csrw mtvec, t0
    li   t0, (1 << 13)              // mstatus.FS = initial
    csrs mstatus, t0
    csrw fcsr, x0
    li   sp, 0x80200000

    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sd   x0, 0(t0)
    addi t0, t0, 8
    j    1b
2:
    call main
    .globl _exit
_exit:
    slli a0, a0, 1
    ori  a0, a0, 1
    la   t0, tohost
    sd   a0, 0(t0)
3:  j    3b

    .align 2
trap:
    csrr a0, mcause
    andi a0, a0, 31
    addi a0, a0, 64
    j    _exit

    .section .tohost, "aw"
    .align 3
    .globl tohost
tohost:
    .dword 0
