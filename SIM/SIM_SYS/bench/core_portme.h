/*---------------------------------------------------------------------------
 * core_portme.h : CoreMark on the bare machine of SIM_SYS (tb_SYS)
 *
 * Time is mcycle, one tick per clock; EE_TICKS_PER_SEC is the clock of the
 * Arty build (50 MHz), so that the "seconds" CoreMark prints are those the
 * board would take. The simulated memory answers faster than the DDR3 of
 * the board, so the board is a little slower than this says.
 *-------------------------------------------------------------------------*/
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT        0      /* no libm: no %f, and no modf for it */
#define HAS_TIME_H       0
#define USE_CLOCK        0
#define HAS_STDIO        0
#define HAS_PRINTF       0      /* ee_printf of barebones/ */

#define COMPILER_VERSION "GCC" __VERSION__
#define COMPILER_FLAGS   FLAGS_STR
#define MEM_LOCATION     "STATIC"

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef unsigned long  ee_ptr_int;
typedef size_t         ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE unsigned long
typedef unsigned long CORE_TICKS;

#define SEED_METHOD      SEED_VOLATILE
#define MEM_METHOD       MEM_STATIC
#define MULTITHREAD      1
#define USE_PTHREAD      0
#define USE_FORK         0
#define USE_SOCKET       0
#define MAIN_HAS_NOARGC  1
#define MAIN_HAS_NORETURN 0

#define EE_TICKS_PER_SEC 50000000UL

extern ee_u32 default_num_contexts;

int ee_printf(const char *fmt, ...);

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#define PERFORMANCE_RUN 1
#endif

#endif
