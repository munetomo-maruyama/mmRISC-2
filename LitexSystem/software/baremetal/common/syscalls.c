//---------------------------------------------------------------------------
// syscalls.c : what newlib needs underneath printf, malloc and exit
//
// stdout / stderr go to the LiteX UART (the board's USB serial, 115200 baud),
// "\n" sent as "\r\n"; stdin reads from it, waiting for a character. exit()
// prints nothing and stops at an EBREAK: under a debugger (OpenOCD sets
// dcsr.ebreakm) the program halts there, without one the trap handler
// takes it.
//---------------------------------------------------------------------------
#include <errno.h>
#include <stddef.h>
#include <sys/stat.h>
#include <sys/time.h>
#include "mmrisc.h"

#undef errno
extern int errno;

void uart_putc(char c)
{
    while (UART_TXFULL) ;
    UART_RXTX = (uint32_t)(unsigned char)c;
}

int uart_getc(void)
{
    if (UART_RXEMPTY) return -1;
    int c = (int)(UART_RXTX & 0xff);
    UART_EV_PENDING = UART_EV_RX;        // the LiteX UART moves on when RX is acknowledged
    return c;
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

int _write(int fd, const char *buf, int len)
{
    (void)fd;
    for (int i = 0; i < len; i++) {
        if (buf[i] == '\n') uart_putc('\r');
        uart_putc(buf[i]);
    }
    return len;
}

int _read(int fd, char *buf, int len)
{
    (void)fd;
    int n = 0, c;
    if (len <= 0) return 0;
    while ((c = uart_getc()) < 0) ;      // wait for the first character
    do {
        buf[n++] = (char)(c == '\r' ? '\n' : c);
        if (c == '\r' || c == '\n') break;
    } while (n < len && (c = uart_getc()) >= 0);
    return n;
}

extern char _end[], __stack_bottom[];
static char *heap_top = _end;

void *_sbrk(ptrdiff_t incr)
{
    char *prev = heap_top;
    if (heap_top + incr > __stack_bottom) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_top += incr;
    return prev;
}

void _exit(int code)
{
    (void)code;
    __asm__ volatile ("ebreak");
    for (;;) __asm__ volatile ("wfi");
}

int _gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    uint64_t t = mmrisc_mtime();
    tv->tv_sec  = t / MMRISC_MTIME_HZ;
    tv->tv_usec = (t % MMRISC_MTIME_HZ) * (1000000 / MMRISC_MTIME_HZ);
    return 0;
}

int _close(int fd)                   { (void)fd; return -1; }
int _fstat(int fd, struct stat *st)  { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd)                  { (void)fd; return 1; }
int _lseek(int fd, int off, int how) { (void)fd; (void)off; (void)how; return 0; }
int _kill(int pid, int sig)          { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void)                    { return 1; }

// the default trap handler: an exception is reported and stops the program
__attribute__((weak)) void trap_handler(uint64_t mcause, uint64_t mepc, uint64_t mtval)
{
    uart_puts("\ntrap: mcause ");
    for (int s = 60; s >= 0; s -= 4) uart_putc("0123456789abcdef"[(mcause >> s) & 0xf]);
    uart_puts(" mepc ");
    for (int s = 60; s >= 0; s -= 4) uart_putc("0123456789abcdef"[(mepc >> s) & 0xf]);
    uart_puts(" mtval ");
    for (int s = 60; s >= 0; s -= 4) uart_putc("0123456789abcdef"[(mtval >> s) & 0xf]);
    uart_puts("\n");
    _exit(1);
}
