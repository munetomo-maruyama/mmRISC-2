/*---------------------------------------------------------------------------
 * ldloop.c : the four loops of LitexSystem/software/bench/loops.h, which
 * micro.c runs on the board under Linux, on the bare machine of SIM_SYS:
 * cycles per iteration to hold against the board's, one for one
 *
 * They run in machine mode, and once more in user mode under Sv39 with
 * 4 KiB pages (the first 2 MiB from 0x8000_0000 mapped onto themselves
 * through three levels of tables), the way Linux runs them on the board.
 * Then micro's sweep (the stride 64 loop over 8 ... 256 lines) in user
 * mode. The profile marks cover the user mode run.
 *-------------------------------------------------------------------------*/
#include "../../../LitexSystem/software/bench/loops.h"

extern volatile unsigned long tohost;
int ee_printf(const char *fmt, ...);

static char buf[16384] __attribute__((aligned(4096)));
static unsigned long root[512] __attribute__((aligned(4096)));
static unsigned long l1[512]   __attribute__((aligned(4096)));
static unsigned long l0[512]   __attribute__((aligned(4096)));
volatile unsigned long sink;
static int user_mode;

static inline unsigned long cycles(void)
{
    unsigned long v;
    if (user_mode) __asm__ volatile ("rdcycle %0" : "=r"(v));
    else           __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

static void run_all(const char *mode)
{
    static const char *name[4] = {
        "no load, 64 iterations     ",
        "ld the same word           ",
        "ld stride 8, one 512 B     ",
        "ld stride 64, 4 KiB        ",
    };
    for (int k = 0; k < 4; k++) {
        unsigned long s = 0, c0, c1;
        /* once to warm the caches, then 20 times */
        for (int r = 0; r < 21; r++) {
            if (r == 1) c0 = cycles();
            switch (k) {
            case 0:  s += loop_n  (buf, buf + 4096, 64); break;
            case 1:  s += loop_ld0(buf, 64);             break;
            case 2:  s += loop_ld (buf, buf + 512, 8);   break;
            default: s += loop_ld (buf, buf + 4096, 64); break;
            }
        }
        c1 = cycles();
        sink = s;
        ee_printf("%s loop %s: %lu.%02lu cycles per iteration\n", mode, name[k],
                  (c1 - c0) / 1280, ((c1 - c0) % 1280) * 100 / 1280);
    }
}

/* micro's sweep: the stride 64 loop over 8 ... 256 lines */
static void sweep(const char *mode)
{
    static const int lines[] = { 8, 16, 32, 48, 64, 96, 128, 192, 256 };
    for (unsigned k = 0; k < sizeof lines / sizeof lines[0]; k++) {
        unsigned long s = 0, c0 = 0, c1, n = lines[k];
        for (int r = 0; r < 11; r++) {
            if (r == 1) c0 = cycles();
            s += loop_ld(buf, buf + n * 64, 64);
        }
        c1 = cycles();
        sink = s;
        ee_printf("%s sweep %3lu lines : %lu.%02lu cycles per load\n", mode, n,
                  (c1 - c0) / (10 * n), ((c1 - c0) % (10 * n)) * 100 / (10 * n));
    }
}

static void user(void)
{
    user_mode = 1;
    tohost = 0x0200000000000000UL;
    run_all("user   ");
    sweep("user   ");
    tohost = 0x0201000000000000UL;
    tohost = 1;                                 /* passed */
    for (;;) ;
}

int main(void)
{
    for (int i = 0; i < 16384; i++) buf[i] = 5;
    run_all("machine");

    /* 0x8000_0000 - 0x801F_FFFF onto itself in 4 KiB pages: V R W X U A D;
     * the tables above them only have V */
    for (int i = 0; i < 512; i++)
        l0[i] = ((0x80000UL + i) << 10) | 0xDF;
    l1[0]   = (((unsigned long)l0) >> 12 << 10) | 0x01;
    root[2] = (((unsigned long)l1) >> 12 << 10) | 0x01;
    __asm__ volatile ("csrw pmpaddr0, %0" :: "r"(-1L));
    __asm__ volatile ("csrw pmpcfg0, %0"  :: "r"(0x1FL));
    __asm__ volatile ("csrw mcounteren, %0" :: "r"(7L));
    __asm__ volatile ("csrw scounteren, %0" :: "r"(7L));
    __asm__ volatile ("csrw satp, %0" :: "r"((8UL << 60) | ((unsigned long)root >> 12)));
    __asm__ volatile ("sfence.vma");
    __asm__ volatile ("csrw mepc, %0" :: "r"(user));
    __asm__ volatile ("li t0, 0x1800; csrc mstatus, t0" ::: "t0");   /* MPP = U */
    __asm__ volatile ("mret");
    return 1;
}
