/*---------------------------------------------------------------------------
 * micro.c : small measurements of mmRISC-2 under Linux
 *
 *   micro [MHz]        (default 50, only used to turn time into cycles)
 *
 * Each test runs for about a second of wall clock, measured with
 * clock_gettime (the user mode of this kernel may read time, not cycle).
 * The numbers are per access or per byte, and in clock cycles at the given
 * frequency, so that they can be held against the size of the caches:
 *
 *   D$ 16 KiB (64 sets x 4 ways x 64 bytes), no L2, DDR3 behind LiteDRAM
 *
 *   read / write / copy   bandwidth of a buffer that fits in the D$ and of
 *                         one that does not
 *   chase                 latency of a dependent load, random order
 *   misaligned            an 8 byte load at an address that is not a
 *                         multiple of 8: the core traps, and the access is
 *                         done in software (OpenSBI or the kernel)
 *   dgemm                 double precision multiply and add, in C
 *   fp kernels            (micro 50 fp for these alone) the kernels of
 *                         fpkern.S in assembler for the pipelined FPU:
 *                         matrix multiply in 4 x 4 blocks, FIR of 8 taps,
 *                         dot product; their answers held against C
 *   sweep                 (micro 50 sweep) the stride 64 load loop over
 *                         8 ... 256 lines, all within the D$
 *   loops                 four loops of four instructions (loops.h), the
 *                         same ones SIM/SIM_SYS/bench/ldloop.c runs in the
 *                         simulation: cycles per iteration, one for one
 *-------------------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "loops.h"
#include "fpkern.h"

static double mhz = 50.0;

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* run body(n) with n doubling until it takes at least `min` seconds;
 * returns the seconds of the last run and its n */
typedef void (*body_t)(long n);
static double timed(body_t body, long *n_io, double min)
{
    long   n = *n_io;
    double t;
    for (;;) {
        double t0 = now();
        body(n);
        t = now() - t0;
        if (t >= min) break;
        n *= 2;
    }
    *n_io = n;
    return t;
}

static volatile uint64_t sink;

/*--------------------------------------------------------------------------*/
static uint64_t *buf;
static size_t    words;                 /* size of the buffer in 8 byte words */

static void body_read(long n)
{
    uint64_t s = 0;
    for (long r = 0; r < n; r++)
        for (size_t i = 0; i < words; i += 4)
            s += buf[i] + buf[i + 1] + buf[i + 2] + buf[i + 3];
    sink = s;
}

static void body_write(long n)
{
    for (long r = 0; r < n; r++)
        for (size_t i = 0; i < words; i += 4) {
            buf[i] = r; buf[i + 1] = r; buf[i + 2] = r; buf[i + 3] = r;
        }
}

static uint64_t *buf2;
static void body_copy(long n)
{
    for (long r = 0; r < n; r++)
        memcpy(buf2, buf, words * 8);
}

static void bandwidth(const char *what, size_t bytes)
{
    long   n;
    double t;

    words = bytes / 8;
    buf  = aligned_alloc(64, bytes);
    buf2 = aligned_alloc(64, bytes);
    memset(buf, 1, bytes);
    memset(buf2, 2, bytes);

    printf("%-6s %8zu KiB :", what, bytes / 1024);
    n = 1; t = timed(body_read,  &n, 1.0);
    printf("  read %7.1f MB/s", n * (double)bytes / t / 1e6);
    n = 1; t = timed(body_write, &n, 1.0);
    printf("  write %7.1f MB/s", n * (double)bytes / t / 1e6);
    n = 1; t = timed(body_copy,  &n, 1.0);
    printf("  copy %7.1f MB/s\n", n * (double)bytes / t / 1e6);

    free(buf);
    free(buf2);
}

/*--------------------------------------------------------------------------*/
static uint64_t **chain;

static void body_chase(long n)
{
    uint64_t **p = chain;
    for (long i = 0; i < n; i++)
        p = (uint64_t **)*p;
    sink = (uint64_t)(uintptr_t)p;
}

static void chase(size_t bytes)
{
    /* one pointer per 64 byte line, visited in a random cycle */
    size_t  lines = bytes / 64;
    char   *mem   = aligned_alloc(64, bytes);
    size_t *perm  = malloc(lines * sizeof(size_t));
    long    n = 1024;
    double  t;

    for (size_t i = 0; i < lines; i++) perm[i] = i;
    srand(1);
    for (size_t i = lines - 1; i > 0; i--) {
        size_t j = (size_t)rand() % (i + 1);
        size_t x = perm[i]; perm[i] = perm[j]; perm[j] = x;
    }
    for (size_t i = 0; i < lines; i++)
        *(char **)(mem + perm[i] * 64) = mem + perm[(i + 1) % lines] * 64;
    chain = (uint64_t **)(mem + perm[0] * 64);

    t = timed(body_chase, &n, 1.0);
    printf("chase  %8zu KiB :  %6.1f ns  %5.1f cycles per load\n",
           bytes / 1024, t / n * 1e9, t / n * mhz * 1e6);
    free(perm);
    free(mem);
}

/*--------------------------------------------------------------------------*/
static char *mis_base;
static int   mis_off;

static void body_mis(long n)
{
    uint64_t s = 0;
    for (long r = 0; r < n; r++) {
        char *p = mis_base + mis_off;
        for (int i = 0; i < 64; i++, p += 64) {
            uint64_t v;
            /* a real ld: the compiler must not split it into bytes */
            __asm__ volatile ("ld %0, 0(%1)" : "=r"(v) : "r"(p));
            s += v;
        }
    }
    sink = s;
}

static void misaligned(void)
{
    long   n;
    double t_al, t_mis;

    mis_base = aligned_alloc(64, 64 * 64 + 64);
    memset(mis_base, 3, 64 * 64 + 64);

    mis_off = 0; n = 1;
    t_al  = timed(body_mis, &n, 1.0);
    t_al  = t_al / (n * 64.0);
    mis_off = 1; n = 1;
    t_mis = timed(body_mis, &n, 1.0);
    t_mis = t_mis / (n * 64.0);
    printf("ld 8 bytes, aligned    :  %8.1f ns  %8.1f cycles\n", t_al * 1e9, t_al * mhz * 1e6);
    printf("ld 8 bytes, misaligned :  %8.1f ns  %8.1f cycles  (x%.0f)\n",
           t_mis * 1e9, t_mis * mhz * 1e6, t_mis / t_al);
    free(mis_base);
}

/*--------------------------------------------------------------------------*/
#define DN 64
static double A[DN][DN], B[DN][DN], C[DN][DN];

static void body_dgemm(long n)
{
    for (long r = 0; r < n; r++)
        for (int i = 0; i < DN; i++)
            for (int k = 0; k < DN; k++) {
                double a = A[i][k];
                for (int j = 0; j < DN; j++)
                    C[i][j] += a * B[k][j];
            }
}

static void dgemm(void)
{
    long   n = 1;
    double t;
    for (int i = 0; i < DN; i++)
        for (int j = 0; j < DN; j++) {
            A[i][j] = 1.0 + i * 0.001;
            B[i][j] = 2.0 - j * 0.001;
            C[i][j] = 0.0;
        }
    t = timed(body_dgemm, &n, 1.0);
    printf("dgemm %dx%d (double)    :  %6.2f MFLOPS  %5.1f cycles per multiply-add\n",
           DN, DN, 2.0 * DN * DN * DN * n / t / 1e6,
           t * mhz * 1e6 / ((double)DN * DN * DN * n));
}

/*--------------------------------------------------------------------------*/
/* the kernels of fpkern.S. The matrices are dgemm's (64 x 64, more than the
 * D$ holds); the FIR (1024 outputs) and the dot product (512) fit in it */
#define FIRN 1024
#define DOTN 512
static double C2[DN][DN];
static double fx[FIRN + 8], fh[8], fy[FIRN], fy_ref[FIRN];
static double du[DOTN], dv[DOTN];
static volatile double dsink;

static void body_dgemm4(long n)
{
    for (long r = 0; r < n; r++)
        fpk_dgemm4(DN, &A[0][0], &B[0][0], &C2[0][0]);
}

static void body_fir(long n)
{
    for (long r = 0; r < n; r++)
        fpk_fir8(FIRN, fx, fh, fy);
}

static void body_dot(long n)
{
    double s = 0.0;
    for (long r = 0; r < n; r++)
        s += fpk_dot(DOTN, du, dv);
    dsink = s;
}

static void fp_report(const char *what, double t, double macs)
{
    printf("%s:  %6.2f MFLOPS  %5.2f cycles per multiply-add\n",
           what, 2.0 * macs / t / 1e6, t * mhz * 1e6 / macs);
}

static void fp_kernels(void)
{
    long   n;
    double t;
    int    bad = 0;

    for (int i = 0; i < DN; i++)
        for (int j = 0; j < DN; j++) {
            A[i][j] = 1.0 + i * 0.001;
            B[i][j] = 2.0 - j * 0.001;
            C[i][j] = C2[i][j] = 0.0;
        }
    ref_dgemm(DN, &A[0][0], &B[0][0], &C[0][0]);
    fpk_dgemm4(DN, &A[0][0], &B[0][0], &C2[0][0]);
    for (int i = 0; i < DN; i++)
        for (int j = 0; j < DN; j++)
            if (!fpk_close(C[i][j], C2[i][j])) bad++;
    n = 1;
    t = timed(body_dgemm4, &n, 1.0);
    fp_report("dgemm 64x64 asm 4x4     ", t, (double)DN * DN * DN * n);

    for (int i = 0; i < FIRN + 8; i++) fx[i] = (i % 17) * 0.25 - 2.0;
    for (int k = 0; k < 8; k++)        fh[k] = 0.125 * (k + 1);
    ref_fir8(FIRN, fx, fh, fy_ref);
    fpk_fir8(FIRN, fx, fh, fy);
    for (int i = 0; i < FIRN; i++)
        if (!fpk_close(fy[i], fy_ref[i])) bad++;
    n = 1;
    t = timed(body_fir, &n, 1.0);
    fp_report("FIR 8 taps x 1024 asm   ", t, 8.0 * FIRN * n);

    for (int i = 0; i < DOTN; i++) {
        du[i] = 1.0 / (i + 1);
        dv[i] = i * 0.5 - 3.0;
    }
    if (!fpk_close(fpk_dot(DOTN, du, dv), ref_dot(DOTN, du, dv))) bad++;
    n = 1;
    t = timed(body_dot, &n, 1.0);
    fp_report("dot product x 512 asm   ", t, (double)DOTN * n);

    printf("fp kernels              :  %s\n", bad ? "WRONG ANSWERS" : "answers agree with C");
}

/*--------------------------------------------------------------------------*/
static char *lp_buf;
static int   lp_kind;

static void body_loops(long n)
{
    unsigned long s = 0;
    for (long r = 0; r < n; r++) {
        switch (lp_kind) {
        case 0:  s += loop_n  (lp_buf, lp_buf + 4096, 64); break;
        case 1:  s += loop_ld0(lp_buf, 64);                break;
        case 2:  s += loop_ld (lp_buf, lp_buf + 512, 8);   break;
        default: s += loop_ld (lp_buf, lp_buf + 4096, 64); break;
        }
    }
    sink = s;
}

static void loops(void)
{
    static const char *name[4] = {
        "no load, 64 iterations     ",
        "ld the same word           ",
        "ld stride 8, one 512 B     ",
        "ld stride 64, 4 KiB        ",
    };
    lp_buf = aligned_alloc(4096, 8192);
    memset(lp_buf, 5, 8192);
    for (lp_kind = 0; lp_kind < 4; lp_kind++) {
        long   n = 1;
        double t = timed(body_loops, &n, 1.0);
        printf("loop %s:  %5.2f cycles per iteration\n",
               name[lp_kind], t * mhz * 1e6 / (n * 64.0));
    }
    free(lp_buf);
}

/* the stride 64 loop over 8 ... 256 lines (512 B ... 16 KiB, all of them
 * fit in the D$): flat in the simulation */
static int sw_lines;

static void body_sweep(long n)
{
    unsigned long s = 0;
    for (long r = 0; r < n; r++)
        s += loop_ld(lp_buf, lp_buf + sw_lines * 64, 64);
    sink = s;
}

static void sweep(void)
{
    static const int lines[] = { 8, 16, 32, 48, 64, 96, 128, 192, 256 };
    lp_buf = aligned_alloc(4096, 16384);
    memset(lp_buf, 5, 16384);
    for (unsigned k = 0; k < sizeof lines / sizeof lines[0]; k++) {
        long   n = 1;
        double t;
        sw_lines = lines[k];
        t = timed(body_sweep, &n, 1.0);
        printf("sweep %3d lines (%5d B) :  %5.2f cycles per load\n",
               sw_lines, sw_lines * 64, t * mhz * 1e6 / ((double)n * sw_lines));
    }
    free(lp_buf);
}

/*--------------------------------------------------------------------------*/
int main(int argc, char **argv)
{
    if (argc > 1) mhz = atof(argv[1]);
    printf("micro : %.0f MHz assumed for the cycle counts\n", mhz);
    /* micro loops / micro sweep : only those */
    if (argc > 2 && strcmp(argv[2], "loops") == 0) {
        loops();
        return 0;
    }
    if (argc > 2 && strcmp(argv[2], "sweep") == 0) {
        sweep();
        return 0;
    }
    if (argc > 2 && strcmp(argv[2], "fp") == 0) {
        dgemm();
        fp_kernels();
        return 0;
    }
    bandwidth("buffer", 8 * 1024);          /* in the D$ */
    bandwidth("buffer", 8 * 1024 * 1024);   /* DRAM */
    chase(8 * 1024);
    chase(8 * 1024 * 1024);
    misaligned();
    dgemm();
    fp_kernels();
    loops();
    return 0;
}
