//---------------------------------------------------------------------------
// hello : the first bare-metal program on mmRISC-2
//
// Prints who it runs on, counts on the LEDs (LD4 to LD7) and times a loop
// with mcycle and mtime. Something to step through in the debugger:
// count_primes() and the variables of main() are plain C.
//---------------------------------------------------------------------------
#include <stdio.h>
#include "mmrisc.h"

volatile uint32_t led_count;            // watch it in the debugger

static int is_prime(int n)
{
    if (n < 2) return 0;
    for (int d = 2; d * d <= n; d++)
        if (n % d == 0) return 0;
    return 1;
}

static int count_primes(int limit)
{
    int n = 0;
    for (int i = 2; i <= limit; i++)
        n += is_prime(i);
    return n;
}

int main(void)
{
    printf("\nHello from mmRISC-2 (bare metal, machine mode)\n");
    printf("  misa    %016llx\n", (unsigned long long)csr_read(misa));
    printf("  mhartid %llu\n", (unsigned long long)csr_read(mhartid));

    uint64_t c0 = mmrisc_cycle(), i0 = mmrisc_instret(), t0 = mmrisc_mtime();
    int primes = count_primes(20000);
    uint64_t c1 = mmrisc_cycle(), i1 = mmrisc_instret(), t1 = mmrisc_mtime();
    printf("  primes up to 20000: %d\n", primes);
    printf("  %llu cycles, %llu instructions, CPI %.3f, %llu us\n",
           (unsigned long long)(c1 - c0), (unsigned long long)(i1 - i0),
           (double)(c1 - c0) / (double)(i1 - i0),
           (unsigned long long)((t1 - t0) * (1000000 / MMRISC_MTIME_HZ)));

    for (int k = 0; k < 16; k++) {
        led_count = k;
        LEDS_OUT  = led_count;
        mmrisc_delay_us(100000);
    }
    LEDS_OUT = 0;
    printf("done\n");
    return 0;
}
