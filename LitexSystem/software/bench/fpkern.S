//---------------------------------------------------------------------------
// fpkern.S : floating point kernels in assembler, written for the pipelined
// FPU (CPU_CORE_SPEC.md 10.11): an operation a cycle when nothing waits for
// an answer, and an answer 9 cycles after its operation. Each kernel keeps
// at least nine operations between an answer and its use, and as few loads
// as it can, since a load and an operation take an issue slot each.
//
// The same file on the board (micro.c, under Linux) and in the simulation
// (SIM/SIM_SYS/bench/fploop.c, bare machine). fpkern.h has the prototypes.
//
//   fpk_fir8(n, x, h, y)    y[i] = h[0]*x[i] + ... + h[7]*x[i+7], i < n
//                           (n a multiple of 8, x has n + 7 elements)
//   fpk_dgemm4(n, a, b, c)  c += a * b, n x n, row major (n a multiple of 4)
//   fpk_dot(n, x, y)        x[0]*y[0] + ... (n a multiple of 8)
//
// The order of the additions is the kernels' own, so the results may differ
// from a plain C loop in the last bits (the callers compare with a margin).
//---------------------------------------------------------------------------
    .text
    .altmacro

// %(expression) is worked out only in the arguments of a macro: these take
// the register numbers and the offsets that the kernels compute
.macro FLDR r, off, base
    fld     f\r, \off(\base)
.endm
.macro FSDR r, off, base
    fsd     f\r, \off(\base)
.endm
.macro FMAR d, a, b
    fmadd.d f\d, f\a, f\b, f\d
.endm
.macro FMULR d, a, b
    fmul.d  f\d, f\a, f\b
.endm

//---------------------------------------------------------------------------
// FIR, 8 taps, 8 outputs at a time
//
//   h[t]  f10 .. f17     y[i+j]  f0 .. f7
//   x[k]  f18 .. f25, at f(18 + k % 8): a window that slides by one each
//         round and comes back to the same registers after eight
//
// Round t (t = 0 .. 7) loads x[i+t+7] and does y[i+j] += h[t] * x[i+t+j]
// for j = 0 .. 7: eight operations and one load, so the round that comes
// next finds each y's answer ready. Round 0 is a multiply (no zeroing).
// 64 multiply-adds, 8 loads and 8 stores a block: about 1.3 cycles each.
//---------------------------------------------------------------------------
.macro FIR_OP t, j
    .if \t == 0
    FMULR   \j, %(10 + \t), %(18 + (\t + \j) - (((\t + \j) >> 3) << 3))
    .else
    FMAR    \j, %(10 + \t), %(18 + (\t + \j) - (((\t + \j) >> 3) << 3))
    .endif
.endm

.macro FIR_ROUND t
    FLDR    %(18 + (\t + 7) - (((\t + 7) >> 3) << 3)), %(8 * (\t + 7)), a1
    .irp j, 0, 1, 2, 3, 4, 5, 6, 7
    FIR_OP  \t, \j
    .endr
.endm

    .globl fpk_fir8
fpk_fir8:                           // a0 n, a1 x, a2 h, a3 y
    addi    sp, sp, -64
    .irp r, 18, 19, 20, 21, 22, 23, 24, 25
    FSDR    \r, %(8 * (\r - 18)), sp
    .endr
    .irp t, 0, 1, 2, 3, 4, 5, 6, 7
    FLDR    %(10 + \t), %(8 * \t), a2
    .endr
    .irp k, 0, 1, 2, 3, 4, 5, 6
    FLDR    %(18 + \k), %(8 * \k), a1
    .endr
    beqz    a0, 2f
1:
    .irp t, 0, 1, 2, 3, 4, 5, 6, 7
    FIR_ROUND \t
    .endr
    addi    a1, a1, 64
    addi    a0, a0, -8
    .irp j, 0, 1, 2, 3, 4, 5, 6, 7
    FSDR    \j, %(8 * \j), a3
    .endr
    addi    a3, a3, 64
    bnez    a0, 1b
2:
    .irp r, 18, 19, 20, 21, 22, 23, 24, 25
    FLDR    \r, %(8 * (\r - 18)), sp
    .endr
    addi    sp, sp, 64
    ret

//---------------------------------------------------------------------------
// matrix multiply, 4 x 4 blocks of c held in registers
//
//   c[i+r][j+s]  f(r * 4 + s) for r < 2, f(16 + (r - 2) * 4 + s) for r >= 2
//                (f0 .. f7, f16 .. f23)
//   b[k][j+s]    f24 .. f27      a[i+r][k]  f28 .. f31
//   (f18 .. f27 are the caller's: saved and restored)
//
// For each k: the four of b and the four of a are loaded, then sixteen
// multiply-adds, each c once: 8 loads and 16 operations, about 1.6 cycles a
// multiply-add. The loads of a are put between the operations so that none
// waits for its load.
//---------------------------------------------------------------------------
.macro CREG r, s
    .if \r < 2
    .set creg, \r * 4 + \s
    .else
    .set creg, 16 + (\r - 2) * 4 + \s
    .endif
.endm

.macro MM_ROW r
    .irp s, 0, 1, 2, 3
    CREG    \r, \s
    FMAR    %creg, %(28 + \r), %(24 + \s)
    .endr
.endm

.macro MM_CROW op, r                // load or store a row of the block of c
    .irp s, 0, 1, 2, 3
    CREG    \r, \s
    \op     %creg, %(8 * \s), t3
    .endr
    add     t3, t3, t6
.endm

    .globl fpk_dgemm4
fpk_dgemm4:                         // a0 n, a1 a, a2 b, a3 c
    addi    sp, sp, -80
    .irp r, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27
    FSDR    \r, %(8 * (\r - 18)), sp
    .endr
    beqz    a0, 9f
    slli    t6, a0, 3               // a row: n * 8 bytes
    li      t0, 0                   // i
1:  li      t1, 0                   // j
2:  // c[i..i+3][j..j+3] into the registers
    mul     t3, t0, t6
    add     t3, t3, a3
    slli    t4, t1, 3
    add     t3, t3, t4              // &c[i][j]
    mv      t5, t3
    .irp r, 0, 1, 2, 3
    MM_CROW FLDR, \r
    .endr
    mul     t3, t0, t6
    add     t3, t3, a1              // &a[i][0]
    add     t4, t4, a2              // &b[0][j]
    mv      t2, a0                  // k
3:  fld     f24,  0(t4)
    fld     f25,  8(t4)
    fld     f26, 16(t4)
    fld     f27, 24(t4)
    add     t4, t4, t6
    fld     f28, 0(t3)
    add     a4, t3, t6
    fld     f29, 0(a4)
    MM_ROW  0
    add     a4, a4, t6
    fld     f30, 0(a4)
    MM_ROW  1
    add     a4, a4, t6
    fld     f31, 0(a4)
    MM_ROW  2
    addi    t3, t3, 8
    addi    t2, t2, -1
    MM_ROW  3
    bnez    t2, 3b
    // and back to c
    mv      t3, t5
    .irp r, 0, 1, 2, 3
    MM_CROW FSDR, \r
    .endr
    addi    t1, t1, 4
    bne     t1, a0, 2b
    addi    t0, t0, 4
    bne     t0, a0, 1b
9:
    .irp r, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27
    FLDR    \r, %(8 * (\r - 18)), sp
    .endr
    addi    sp, sp, 80
    ret

//---------------------------------------------------------------------------
// dot product, eight sums
//
// Two loads for each multiply-add: the loads are what it waits for (about
// three cycles a multiply-add), not the FPU. Eight sums so that each sum's
// next operation is more than nine cycles behind the one before. The
// operands go round four pairs of registers (x in f10 .. f13, y in
// f14 .. f17) and are loaded two multiply-adds ahead of their use.
//---------------------------------------------------------------------------
.macro DOT_LD s
    FLDR    %(10 + \s - ((\s >> 2) << 2)), %(8 * \s), a1
    FLDR    %(14 + \s - ((\s >> 2) << 2)), %(8 * \s), a2
.endm

.macro DOT_OP s
    FMAR    \s, %(10 + \s - ((\s >> 2) << 2)), %(14 + \s - ((\s >> 2) << 2))
    .if \s < 6
    DOT_LD  %(\s + 2)
    .endif
.endm

    .globl fpk_dot
fpk_dot:                            // a0 n, a1 x, a2 y -> fa0
    .irp s, 0, 1, 2, 3, 4, 5, 6, 7
    fmv.d.x f\s, x0
    .endr
    beqz    a0, 2f
1:  DOT_LD  0
    DOT_LD  1
    .irp s, 0, 1, 2, 3, 4, 5, 6, 7
    DOT_OP  \s
    .endr
    addi    a1, a1, 64
    addi    a2, a2, 64
    addi    a0, a0, -8
    bnez    a0, 1b
2:
    fadd.d  f0, f0, f1
    fadd.d  f2, f2, f3
    fadd.d  f4, f4, f5
    fadd.d  f6, f6, f7
    fadd.d  f0, f0, f2
    fadd.d  f4, f4, f6
    fadd.d  fa0, f0, f4
    ret
