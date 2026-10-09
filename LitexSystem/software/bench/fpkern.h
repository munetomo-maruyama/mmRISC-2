/*---------------------------------------------------------------------------
 * fpkern.h : the kernels of fpkern.S and fpkern.c, and the same sums in C
 * to hold their answers against (micro.c on the board,
 * SIM/SIM_SYS/bench/fploop.c in the simulation)
 *-------------------------------------------------------------------------*/
#ifndef FPKERN_H
#define FPKERN_H

/* y[i] = h[0]*x[i] + ... + h[7]*x[i+7], i < n (n a multiple of 8) */
void   fpk_fir8(long n, const double *x, const double *h, double *y);
/* c += a * b, n x n, row major (n a multiple of 4) */
void   fpk_dgemm4(long n, const double *a, const double *b, double *c);
/* x[0]*y[0] + ... + x[n-1]*y[n-1] (n a multiple of 8) */
double fpk_dot(long n, const double *x, const double *y);
/* c[0..3][0..nc-1] += a[0..3][0..kc-1] * (a panel of b packed as
 * fpkern.c packs it); rows lda / ldc apart, kc even, nc a multiple of 4 */
void   fpk_mm4xn(long kc, long nc, const double *a, long lda, const double *pb,
                 double *c, long ldc);
/* c += a * b, n x n, row major, blocked for the D$ (fpkern.c; n a
 * multiple of 4) */
void   fpk_dgemm_blk(long n, const double *a, const double *b, double *c);

static inline void ref_fir8(long n, const double *x, const double *h, double *y)
{
    for (long i = 0; i < n; i++) {
        double s = 0.0;
        for (int t = 0; t < 8; t++)
            s += h[t] * x[i + t];
        y[i] = s;
    }
}

static inline void ref_dgemm(long n, const double *a, const double *b, double *c)
{
    for (long i = 0; i < n; i++)
        for (long k = 0; k < n; k++)
            for (long j = 0; j < n; j++)
                c[i * n + j] += a[i * n + k] * b[k * n + j];
}

static inline double ref_dot(long n, const double *x, const double *y)
{
    double s = 0.0;
    for (long i = 0; i < n; i++)
        s += x[i] * y[i];
    return s;
}

/* the kernels add in an order of their own: equal to a part in 10^12 */
static inline int fpk_close(double a, double b)
{
    double d = a - b, m = (a < 0 ? -a : a) + (b < 0 ? -b : b);
    if (d < 0) d = -d;
    return d <= 1e-12 * m;
}

#endif
