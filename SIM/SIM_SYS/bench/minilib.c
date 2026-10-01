/*---------------------------------------------------------------------------
 * minilib.c : the little of a C library the benchmarks use, on the bare
 * machine of SIM_SYS
 *
 * The newlib of the toolchain is built for the low code model and cannot be
 * linked at 0x8000_0000, so there is no C library at all: printing is
 * CoreMark's own ee_printf (barebones/ee_printf.c, copied with its output
 * hook filled in), and the string functions are here.
 *-------------------------------------------------------------------------*/
#include <stddef.h>

extern volatile unsigned long tohost;

/* the output of ee_printf: every byte is a console command to tb_SYS
 * (device 1, command 1) */
void tohost_putc(char c)
{
    tohost = (1UL << 56) | (1UL << 48) | (unsigned char)c;
}

void *memcpy(void *d, const void *s, size_t n)
{
    char *dp = d; const char *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    char *dp = d;
    while (n--) *dp++ = (char)c;
    return d;
}

char *strcpy(char *d, const char *s)
{
    char *r = d;
    while ((*d++ = *s++) != '\0') ;
    return r;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
