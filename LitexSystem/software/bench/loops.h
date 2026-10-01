/*---------------------------------------------------------------------------
 * loops.h : the same few instructions on the board (micro.c, under Linux)
 * and in the simulation (SIM/SIM_SYS/bench/ldloop.c, bare machine), so that
 * the cycles per iteration can be compared one for one
 *
 *   loop_n(p, end, stride)   addi t0,p,0 / addi p,p,stride / add / bne
 *   loop_ld(p, end, stride)  ld   t0,0(p) / addi p,p,stride / add / bne
 *
 * Both walk from p to end (exclusive) and return the sum; with stride 0
 * end is the count of iterations in units of 8 bytes past p.
 *-------------------------------------------------------------------------*/
#ifndef LOOPS_H
#define LOOPS_H

static inline unsigned long loop_n(char *p, char *end, long stride)
{
    unsigned long s = 0, t;
    __asm__ volatile (
        "1: addi %[t], %[p], 0\n"
        "   add  %[p], %[p], %[st]\n"
        "   add  %[s], %[s], %[t]\n"
        "   bne  %[p], %[e], 1b\n"
        : [s] "+r"(s), [p] "+r"(p), [t] "=&r"(t)
        : [e] "r"(end), [st] "r"(stride));
    return s;
}

static inline unsigned long loop_ld(char *p, char *end, long stride)
{
    unsigned long s = 0, t;
    __asm__ volatile (
        "1: ld   %[t], 0(%[p])\n"
        "   add  %[p], %[p], %[st]\n"
        "   add  %[s], %[s], %[t]\n"
        "   bne  %[p], %[e], 1b\n"
        : [s] "+r"(s), [p] "+r"(p), [t] "=&r"(t)
        : [e] "r"(end), [st] "r"(stride)
        : "memory");
    return s;
}

/* a load that always hits the same word: p does not move, a counter does */
static inline unsigned long loop_ld0(char *p, long n)
{
    unsigned long s = 0, t;
    __asm__ volatile (
        "1: ld   %[t], 0(%[p])\n"
        "   addi %[n], %[n], -1\n"
        "   add  %[s], %[s], %[t]\n"
        "   bnez %[n], 1b\n"
        : [s] "+r"(s), [n] "+r"(n), [t] "=&r"(t)
        : [p] "r"(p)
        : "memory");
    return s;
}

#endif
