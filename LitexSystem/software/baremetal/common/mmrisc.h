//---------------------------------------------------------------------------
// mmrisc.h : the mmRISC-2 LiteX SoC for bare-metal programs (Arty A7-100T)
//
// Addresses from build/csr.json. Everything runs in machine mode, linked at
// the start of DRAM (0x8000_0000), loaded over JTAG after the LiteX BIOS has
// initialized the DRAM (LitexSystem/docs/ECLIPSE.md).
//---------------------------------------------------------------------------
#ifndef MMRISC_H
#define MMRISC_H

#include <stdint.h>

#define MMRISC_CLOCK_HZ    50000000UL      // the system clock
#define MMRISC_MTIME_HZ    500000UL        // mtime: the clock / 100 (CLINT_TICK_DIV)

// LiteX CSRs (32-bit registers, one every 4 bytes)
#define REG32(a)           (*(volatile uint32_t *)(uintptr_t)(a))
#define LEDS_OUT           REG32(0x12002800UL)   // LD4 to LD7, bit 0 = LD4
#define UART_RXTX          REG32(0x12004800UL)
#define UART_TXFULL        REG32(0x12004804UL)
#define UART_RXEMPTY       REG32(0x12004808UL)
#define UART_EV_PENDING    REG32(0x12004810UL)
#define UART_EV_ENABLE     REG32(0x12004814UL)
#define UART_EV_TX         0x1
#define UART_EV_RX         0x2

// CLINT (inside the core)
#define CLINT_MTIMECMP     (*(volatile uint64_t *)0x02004000UL)
#define CLINT_MTIME        (*(volatile uint64_t *)0x0200BFF8UL)

// CSRs
#define csr_read(csr) ({ uint64_t _v; __asm__ volatile ("csrr %0, " #csr : "=r"(_v)); _v; })
#define csr_write(csr, v) __asm__ volatile ("csrw " #csr ", %0" :: "rK"((uint64_t)(v)))
#define csr_set(csr, v)   __asm__ volatile ("csrs " #csr ", %0" :: "rK"((uint64_t)(v)))
#define csr_clear(csr, v) __asm__ volatile ("csrc " #csr ", %0" :: "rK"((uint64_t)(v)))

#define MSTATUS_MIE        (1UL << 3)
#define MIE_MTIE           (1UL << 7)
#define MCAUSE_INT         (1UL << 63)
#define IRQ_M_TIMER        7

static inline uint64_t mmrisc_mtime(void)  { return CLINT_MTIME; }
static inline uint64_t mmrisc_cycle(void)  { return csr_read(mcycle); }
static inline uint64_t mmrisc_instret(void){ return csr_read(minstret); }

// busy wait, in microseconds (mtime runs at 500 kHz: 2 us a tick)
static inline void mmrisc_delay_us(uint64_t us)
{
    uint64_t end = mmrisc_mtime() + us * (MMRISC_MTIME_HZ / 1000000.0);
    while (mmrisc_mtime() < end) ;
}

// the UART (also behind printf, syscalls.c)
void uart_putc(char c);
int  uart_getc(void);                   // -1 when nothing has come
void uart_puts(const char *s);

// the trap handler of crt0.S calls this; a program defines its own
void trap_handler(uint64_t mcause, uint64_t mepc, uint64_t mtval);

#endif
