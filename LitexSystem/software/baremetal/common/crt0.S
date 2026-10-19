//---------------------------------------------------------------------------
// crt0.S : start of a bare-metal program on mmRISC-2 (machine mode)
//
// The debugger loads the program and sets pc to _start (docs/ECLIPSE.md). The
// LiteX BIOS it interrupts may have left interrupts on and its own trap
// vector, so everything the program relies on is set here: interrupts off,
// mtvec, gp, sp, the FPU on, .bss cleared. Then main(); its return value
// goes to exit(), which stops at an EBREAK (syscalls.c).
//---------------------------------------------------------------------------
    .section .text.init, "ax"
    .globl _start
_start:
    csrw  mie, zero
    csrci mstatus, 0x8                  // MIE = 0
    la    t0, trap_entry
    csrw  mtvec, t0
    .option push
    .option norelax
    la    gp, __global_pointer$
    .option pop
    la    sp, __stack_top
    li    t0, 1 << 13                   // mstatus.FS = Initial: the FPU on
    csrs  mstatus, t0
    csrw  fcsr, zero

    la    t0, __bss_start               // .bss and .sbss
    la    t1, __bss_end
1:
    bgeu  t0, t1, 2f
    sd    zero, 0(t0)
    addi  t0, t0, 8
    j     1b
2:
    li    a0, 0                         // argc
    li    a1, 0                         // argv
    call  main
    call  exit
3:
    j     3b

//---------------------------------------------------------------------------
// trap_entry : saves the registers a C function may change, calls
// trap_handler(mcause, mepc, mtval) and returns with MRET. An interrupt
// returns to where it came; for an exception trap_handler has to move
// mepc on (or not return).
//---------------------------------------------------------------------------
    .section .text, "ax"
    .align 2
    .globl trap_entry
trap_entry:
    addi  sp, sp, -16*8
    sd    ra,  0*8(sp)
    sd    t0,  1*8(sp)
    sd    t1,  2*8(sp)
    sd    t2,  3*8(sp)
    sd    a0,  4*8(sp)
    sd    a1,  5*8(sp)
    sd    a2,  6*8(sp)
    sd    a3,  7*8(sp)
    sd    a4,  8*8(sp)
    sd    a5,  9*8(sp)
    sd    a6, 10*8(sp)
    sd    a7, 11*8(sp)
    sd    t3, 12*8(sp)
    sd    t4, 13*8(sp)
    sd    t5, 14*8(sp)
    sd    t6, 15*8(sp)
    csrr  a0, mcause
    csrr  a1, mepc
    csrr  a2, mtval
    call  trap_handler
    ld    ra,  0*8(sp)
    ld    t0,  1*8(sp)
    ld    t1,  2*8(sp)
    ld    t2,  3*8(sp)
    ld    a0,  4*8(sp)
    ld    a1,  5*8(sp)
    ld    a2,  6*8(sp)
    ld    a3,  7*8(sp)
    ld    a4,  8*8(sp)
    ld    a5,  9*8(sp)
    ld    a6, 10*8(sp)
    ld    a7, 11*8(sp)
    ld    t3, 12*8(sp)
    ld    t4, 13*8(sp)
    ld    t5, 14*8(sp)
    ld    t6, 15*8(sp)
    addi  sp, sp, 16*8
    mret
