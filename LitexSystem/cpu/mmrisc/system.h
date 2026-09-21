#ifndef __SYSTEM_H
#define __SYSTEM_H

#ifdef __cplusplus
extern "C" {
#endif

/* The only cache maintenance instruction this core has is fence.i, and it
 * does the whole job: the data cache is written back and invalidated first
 * (CPU_CACHE_SPEC.md 5.3), then the instruction cache is invalidated. So
 * both of the calls below are the same instruction. Calling them one after
 * the other, as the BIOS does before it jumps to a freshly loaded image,
 * only costs a second flush of an already clean cache.
 *
 * A plain fence is not used here: this core does not send it to the cache
 * at all (it is a no-op with one hart and an in-order cache), so it would
 * write nothing back.
 */
__attribute__((unused)) static void flush_cpu_icache(void)
{
	asm volatile("fence.i" ::: "memory");
}

__attribute__((unused)) static void flush_cpu_dcache(void)
{
	asm volatile("fence.i" ::: "memory");
}

/* defined by LiteX in libbase/system.c; it does nothing unless the SoC
 * declares CONFIG_L2_SIZE, and this one has no L2 */
void flush_l2_cache(void);

void busy_wait(unsigned int ms);
void busy_wait_us(unsigned int us);

#include <csr-defs.h>

#define csrr(reg) ({ unsigned long __tmp; \
  asm volatile ("csrr %0, " #reg : "=r"(__tmp)); \
  __tmp; })

#define csrw(reg, val) ({ \
  if (__builtin_constant_p(val) && (unsigned long)(val) < 32) \
	asm volatile ("csrw " #reg ", %0" :: "i"(val)); \
  else \
	asm volatile ("csrw " #reg ", %0" :: "r"(val)); })

#define csrs(reg, bit) ({ \
  if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
	asm volatile ("csrrs x0, " #reg ", %0" :: "i"(bit)); \
  else \
	asm volatile ("csrrs x0, " #reg ", %0" :: "r"(bit)); })

#define csrc(reg, bit) ({ \
  if (__builtin_constant_p(bit) && (unsigned long)(bit) < 32) \
	asm volatile ("csrrc x0, " #reg ", %0" :: "i"(bit)); \
  else \
	asm volatile ("csrrc x0, " #reg ", %0" :: "r"(bit)); })

#ifdef __cplusplus
}
#endif

#endif /* __SYSTEM_H */
