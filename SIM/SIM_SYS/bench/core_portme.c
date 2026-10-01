/*---------------------------------------------------------------------------
 * core_portme.c : CoreMark on the bare machine of SIM_SYS (tb_SYS)
 *
 * The timed part also prints mcycle and minstret, so that the cycles per
 * instruction of the benchmark itself (without the printing around it) can
 * be read off.
 *-------------------------------------------------------------------------*/
#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static inline unsigned long rd_cycle(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(v));
    return v;
}

static inline unsigned long rd_instret(void)
{
    unsigned long v;
    __asm__ volatile ("csrr %0, minstret" : "=r"(v));
    return v;
}

static unsigned long t0, t1, i0, i1;

/* the marks of the part tb_SYS profiles (+profile) */
extern volatile unsigned long tohost;
#define PROFILE_START() (tohost = 0x0200000000000000UL)
#define PROFILE_STOP()  (tohost = 0x0201000000000000UL)

void start_time(void)
{
    PROFILE_START();
    i0 = rd_instret();
    t0 = rd_cycle();
}

void stop_time(void)
{
    t1 = rd_cycle();
    i1 = rd_instret();
    PROFILE_STOP();
}

CORE_TICKS get_time(void)
{
    return t1 - t0;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks / (secs_ret)EE_TICKS_PER_SEC;
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    unsigned long c = t1 - t0, n = i1 - i0;
    ee_printf("timed part       : %lu cycles, %lu instructions, CPI %lu.%03lu\n",
           c, n, c / n, (c % n) * 1000 / n);
    ee_printf("CoreMark/MHz     : %lu.%03lu\n",
           (unsigned long)ITERATIONS * 1000000UL / c,
           ((unsigned long)ITERATIONS * 1000000000UL / c) % 1000);
    p->portable_id = 0;
}
