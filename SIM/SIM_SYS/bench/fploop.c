/*---------------------------------------------------------------------------
 * fploop.c : the floating point kernels of LitexSystem/software/bench
 * (fpkern.S, which micro.c runs on the board under Linux) on the bare
 * machine of SIM_SYS: cycles per multiply-add, and the answers held against
 * the same sums in C (fpkern.h). The C matrix multiply is timed as well.
 *
 * Each one runs twice and the second run is timed, so that the caches hold
 * the code and the data. The sizes are small to keep the simulation short;
 * all of it fits in the D$. Returns the count of wrong answers and of
 * kernels slower than their bound: a loss of a cycle or two in the core
 * changes no answer, only these counts (an FSD that waited for the FPU
 * once went from MA instead of EX: CPU_CORE_SPEC.md 10.11.2).
 *-------------------------------------------------------------------------*/
#include "../../../LitexSystem/software/bench/fpkern.h"

int ee_printf(const char *fmt, ...);

#define MN  16          /* matrix multiply: 16 x 16, 4096 multiply-adds */
#define FN  256         /* FIR: 256 outputs, 2048 multiply-adds */
#define DN  512         /* dot product: 512 multiply-adds */
#define BN  32          /* blocked matrix multiply: 32 x 32 (24 KB, more
                           than the D$), 32768 multiply-adds */

static double a[MN * MN], b[MN * MN], c[MN * MN], c_ref[MN * MN];
static double x[FN + 8], h[8], y[FN], y_ref[FN];
static double u[DN], v[DN];
static double ba[BN * BN], bb[BN * BN], bc[BN * BN];

static inline unsigned long cycles(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

static int slow;

/* cycles per multiply-add, two places after the point; bound100 is the
 * most it may take (in hundredths: about 5 % above what it takes) */
static void report(const char *what, unsigned long cyc, unsigned long macs,
                   unsigned long bound100)
{
    unsigned long c100 = cyc * 100 / macs;
    ee_printf("%s : %lu.%02lu cycles per multiply-add (%lu cycles, %lu)%s\n",
              what, c100 / 100, c100 % 100, cyc, macs,
              c100 > bound100 ? "  SLOWER THAN ITS BOUND" : "");
    if (c100 > bound100) slow++;
}

int main(void)
{
    int bad = 0;
    unsigned long c0, c1;

    for (int i = 0; i < MN * MN; i++) {
        a[i] = 1.0 + i * 0.001;
        b[i] = 2.0 - i * 0.0007;
    }
    for (int i = 0; i < FN + 8; i++) x[i] = (i % 17) * 0.25 - 2.0;
    for (int t = 0; t < 8; t++)      h[t] = 0.125 * (t + 1);
    for (int i = 0; i < DN; i++) {
        u[i] = 1.0 / (i + 1);
        v[i] = i * 0.5 - 3.0;
    }

    /* matrix multiply: c = a * b */
    for (int r = 0; r < 2; r++) {
        for (int i = 0; i < MN * MN; i++) c[i] = 0.0;
        c0 = cycles();
        fpk_dgemm4(MN, a, b, c);
        c1 = cycles();
    }
    report("dgemm 16x16, asm 4x4 ", c1 - c0, MN * MN * MN, 230);
    for (int r = 0; r < 2; r++) {
        for (int i = 0; i < MN * MN; i++) c_ref[i] = 0.0;
        c0 = cycles();
        ref_dgemm(MN, a, b, c_ref);
        c1 = cycles();
    }
    report("dgemm 16x16, C -O2   ", c1 - c0, MN * MN * MN, 1650);
    for (int i = 0; i < MN * MN; i++)
        if (!fpk_close(c[i], c_ref[i])) bad++;

    /* matrix multiply blocked for the D$ (fpkern.c); checked at 64 places,
     * a whole C reference would take longer than the rest of the run */
    for (int i = 0; i < BN * BN; i++) {
        ba[i] = 1.0 + i * 0.0003;
        bb[i] = 2.0 - i * 0.0002;
    }
    for (int r = 0; r < 2; r++) {
        for (int i = 0; i < BN * BN; i++) bc[i] = 0.0;
        c0 = cycles();
        fpk_dgemm_blk(BN, ba, bb, bc);
        c1 = cycles();
    }
    report("dgemm 32x32, blocked ", c1 - c0, BN * BN * BN, 252);
    for (int t = 0; t < 64; t++) {
        int i = (t * 7) % BN, j = (t * 13 + 5) % BN;
        double s = 0.0;
        for (int k = 0; k < BN; k++)
            s += ba[i * BN + k] * bb[k * BN + j];
        if (!fpk_close(s, bc[i * BN + j])) bad++;
    }

    /* FIR */
    for (int r = 0; r < 2; r++) {
        c0 = cycles();
        fpk_fir8(FN, x, h, y);
        c1 = cycles();
    }
    report("FIR 8 taps, asm      ", c1 - c0, FN * 8, 155);
    ref_fir8(FN, x, h, y_ref);
    for (int i = 0; i < FN; i++)
        if (!fpk_close(y[i], y_ref[i])) bad++;

    /* dot product */
    double d = 0.0;
    for (int r = 0; r < 2; r++) {
        c0 = cycles();
        d = fpk_dot(DN, u, v);
        c1 = cycles();
    }
    report("dot product, asm     ", c1 - c0, DN, 385);
    if (!fpk_close(d, ref_dot(DN, u, v))) bad++;

    ee_printf("fploop : %d wrong answers, %d slower than the bound\n", bad, slow);
    return bad + slow;
}
