//---------------------------------------------------------------------------
// timer_irq : an interrupt in a bare-metal program on mmRISC-2
//
// The CLINT's timer interrupts every 100 ms (mtimecmp), the handler moves
// the LEDs on and counts, main() sleeps in WFI in between and prints the
// count. A breakpoint in trap_handler() stops in the interrupt.
//---------------------------------------------------------------------------
#include <stdio.h>
#include "mmrisc.h"

#define PERIOD_TICKS (MMRISC_MTIME_HZ / 10)   // 100 ms

volatile uint32_t ticks;

void trap_handler(uint64_t mcause, uint64_t mepc, uint64_t mtval)
{
    if (mcause == (MCAUSE_INT | IRQ_M_TIMER)) {
        CLINT_MTIMECMP += PERIOD_TICKS;      // the next one (also clears the request)
        ticks++;
        LEDS_OUT = ticks & 0xf;
        return;
    }
    printf("\nunexpected trap: mcause %llx mepc %llx mtval %llx\n",
           (unsigned long long)mcause, (unsigned long long)mepc, (unsigned long long)mtval);
    __asm__ volatile ("ebreak");
    for (;;) ;
}

int main(void)
{
    printf("\ntimer_irq: the CLINT every 100 ms\n");
    CLINT_MTIMECMP = mmrisc_mtime() + PERIOD_TICKS;
    csr_set(mie, MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);

    uint32_t seen = 0;
    while (ticks < 20) {
        __asm__ volatile ("wfi");
        if (ticks != seen) {
            seen = ticks;
            if (seen % 5 == 0) printf("  %u interrupts\n", (unsigned)seen);
        }
    }
    csr_clear(mstatus, MSTATUS_MIE);
    csr_clear(mie, MIE_MTIE);
    LEDS_OUT = 0;
    printf("done\n");
    return 0;
}
