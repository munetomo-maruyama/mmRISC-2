/*---------------------------------------------------------------------------
 * fpkern.c : the matrix multiply of fpkern.S blocked for the D$
 *
 *   fpk_dgemm_blk(n, a, b, c)   c += a * b, n x n, row major
 *                               (n a multiple of 4)
 *
 * fpk_dgemm4 walks all of b for every four rows of a: 32 KB at n = 64,
 * twice the D$, so b comes from the L2 again and again (4.05 cycles a
 * multiply-add on the board against 2.18 when everything fits). Here b is
 * cut into panels of FPK_KC rows by FPK_NC columns that stay in the D$
 * while every row of a goes past them:
 *
 *   for each panel of columns jc, each panel of rows pc:
 *       copy b[pc..][jc..] into pb, four columns at a time
 *       for each four rows ic: fpk_mm4xn over the panel
 *
 * The copy ("packing") puts what the kernel reads of b for one k in 32
 * consecutive bytes and keeps the panel clear of conflicts in the sets of
 * the cache. a is read where it is: its four rows are used once for every
 * four columns of the panel and stay in the D$ meanwhile, and copying them
 * cost more than reading them through four pointers. The kernel and the C
 * around it are the same on the board (micro.c) and in the simulation
 * (SIM/SIM_SYS/bench/fploop.c).
 *-------------------------------------------------------------------------*/
#include "fpkern.h"

/* the panel of b: 64 x 16 = 8 KB, half the D$. Measured in SIM_SYS at
 * n = 64 (cycles a multiply-add; 3.25 not blocked): 64 x 16 2.23, 32 x 32
 * 2.24, 16 x 64 2.46, 64 x 24 2.30, 64 x 32 (16 KB) 2.46. The loads of
 * MA wait for a miss, so what is left over the kernel's 1.7 is the misses
 * themselves: a is read again for every panel of columns, c for every
 * panel of rows. 64 x 16 reads c once (and writes it back once). */
#ifndef FPK_KC
#define FPK_KC 64
#endif
#ifndef FPK_NC
#define FPK_NC 16
#endif

static double pb[FPK_KC * FPK_NC] __attribute__((aligned(64)));

void fpk_dgemm_blk(long n, const double *a, const double *b, double *c)
{
    for (long jc = 0; jc < n; jc += FPK_NC) {
        long nc = n - jc < FPK_NC ? n - jc : FPK_NC;
        for (long pc = 0; pc < n; pc += FPK_KC) {
            long kc = n - pc < FPK_KC ? n - pc : FPK_KC;
            /* the panel of b, four columns at a time: pb[jr][k][s] */
            for (long jr = 0; jr < nc; jr += 4)
                for (long k = 0; k < kc; k++) {
                    const double *src = &b[(pc + k) * n + jc + jr];
                    double *dst = &pb[(jr * kc) + k * 4];
                    dst[0] = src[0]; dst[1] = src[1];
                    dst[2] = src[2]; dst[3] = src[3];
                }
            for (long ic = 0; ic < n; ic += 4)
                fpk_mm4xn(kc, nc, &a[ic * n + pc], n, pb, &c[ic * n + jc], n);
        }
    }
}
