/*---------------------------------------------------------------------------
 * dhry_shim.c : what the Dhrystone of riscv-tests expects from its bare
 * metal environment (benchmarks/common), provided by Linux instead
 *
 *   debug_printf   printf (dhrystone.c has an empty one, renamed in the
 *                  copy, so the values it checks at the end are shown)
 *   setStats       nothing (the counters of the core are not readable
 *                  from user mode under this kernel)
 *   bench_usec     the timer: dhrystone.h reads read_csr(mcycle) with
 *                  HZ = 1000000; the Makefile turns that into bench_usec(),
 *                  microseconds of CLOCK_MONOTONIC, which matches the HZ
 *-------------------------------------------------------------------------*/
#include <stdio.h>
#include <stdarg.h>
#include <time.h>

void debug_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

void setStats(int enable)
{
    (void)enable;
}

long bench_usec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000L + ts.tv_nsec / 1000;
}
