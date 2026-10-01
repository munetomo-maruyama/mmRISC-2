/*---------------------------------------------------------------------------
 * dhry_shim.c : what the Dhrystone of riscv-tests expects, on the bare
 * machine of SIM_SYS
 *
 *   debug_printf  ee_vsprintf of CoreMark's barebones printf (dhrystone.c
 *                 has an empty one, renamed in the copy); printf is
 *                 ee_printf (-Dprintf=ee_printf)
 *   bench_usec    mcycle / 50: microseconds at the 50 MHz of the board,
 *                 which is what dhrystone.h's HZ of 1000000 expects
 *   setStats      prints the cycles and instructions of the timed loop
 *-------------------------------------------------------------------------*/
#include <stdarg.h>

int ee_printf(const char *fmt, ...);
int ee_vsprintf(char *buf, const char *fmt, va_list args);
void tohost_putc(char c);

static inline unsigned long rd(int which)
{
    unsigned long v;
    if (which) __asm__ volatile ("csrr %0, minstret" : "=r"(v));
    else       __asm__ volatile ("csrr %0, mcycle"   : "=r"(v));
    return v;
}

void debug_printf(const char *fmt, ...)
{
    char    buf[256], *p;
    va_list ap;
    va_start(ap, fmt);
    ee_vsprintf(buf, fmt, ap);
    va_end(ap);
    for (p = buf; *p; p++) tohost_putc(*p);
}

long bench_usec(void)
{
    return (long)(rd(0) / 50);
}

static unsigned long c0, i0;

/* the marks of the part tb_SYS profiles (+profile) */
extern volatile unsigned long tohost;

void setStats(int enable)
{
    if (enable) {
        tohost = 0x0200000000000000UL;
        i0 = rd(1);
        c0 = rd(0);
    } else {
        unsigned long c = rd(0) - c0, n = rd(1) - i0;
        tohost = 0x0201000000000000UL;
        ee_printf("timed part : %lu cycles, %lu instructions, CPI %lu.%03lu\n",
               c, n, c / n, (c % n) * 1000 / n);
    }
}
