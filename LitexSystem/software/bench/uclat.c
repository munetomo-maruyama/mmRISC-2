//---------------------------------------------------------------------------
// uclat.c : the cost of uncached accesses on the board (ROADMAP.md W2)
//
//   ./uclat [count]          (root: it maps LiteX's CSRs through /dev/mem)
//
// Times loops of single accesses to the peripheral bus and prints the
// cycles of one iteration at 50 MHz, the empty loop taken off:
//
//   sw uncached    a store to ctrl_scratch (a register of LiteX that does
//                  nothing), as the drivers write their registers
//   lw uncached    a load of ctrl_scratch
//   lw liteeth     a load of LiteEth's TX ready, as liteeth_start_xmit does
//   sw + sh,lw     an uncached store, then a cacheable store and load, the
//                  order of liteeth_start_xmit after its register writes
//   sh,lw cached   the same without the uncached store
//
// ctrl_scratch is written back with what it held. Nothing of LiteEth is
// written. The kernel has no STRICT_DEVMEM (software/boot/linux.config).
//---------------------------------------------------------------------------
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define CSR_BASE      0x12000000UL   // build/csr.json
#define CTRL_SCRATCH  0x0004
#define ETH_TX_READY  0x101c         // ethmac_sram_reader_ready

static double now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e9 + t.tv_nsec;
}

// each body runs n times in a loop of its own (addi + bnez around it)
#define LOOP(body, ...)                                                      \
    ({ long _n = n; double _t = now_ns();                                    \
       __asm__ volatile("1:\n" body "\naddi %[n], %[n], -1\nbnez %[n], 1b"   \
                        : [n] "+r"(_n) : __VA_ARGS__ : "memory", "t0");      \
       (now_ns() - _t) * 0.05 / n; })   // cycles at 50 MHz

int main(int argc, char **argv)
{
    long n = (argc > 1) ? atol(argv[1]) : 200000;
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("uclat: /dev/mem"); return 1; }
    volatile uint8_t *csr = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, CSR_BASE);
    if (csr == MAP_FAILED) { perror("uclat: mmap"); return 1; }
    volatile uint32_t *scratch = (volatile uint32_t *)(csr + CTRL_SCRATCH);
    volatile uint32_t *ready   = (volatile uint32_t *)(csr + ETH_TX_READY);
    static volatile uint16_t cached[32];
    uint32_t keep = *scratch;

    double empty = LOOP("nop", [p] "r"(cached));
    double sw    = LOOP("sw   %[n], 0(%[p])", [p] "r"(scratch));
    double lw    = LOOP("lw   t0, 0(%[p])", [p] "r"(scratch));
    double lweth = LOOP("lw   t0, 0(%[p])", [p] "r"(ready));
    double mix   = LOOP("sw   %[n], 0(%[p])\nsh %[n], 2(%[c])\nlw t0, 0(%[c])",
                        [p] "r"(scratch), [c] "r"(cached));
    double cach  = LOOP("sh   %[n], 2(%[c])\nlw t0, 0(%[c])", [c] "r"(cached));
    *scratch = keep;

    printf("uclat: %ld iterations, cycles of one at 50 MHz (empty loop %.1f taken off)\n", n, empty);
    printf("  sw uncached   %7.1f\n", sw - empty);
    printf("  lw uncached   %7.1f\n", lw - empty);
    printf("  lw liteeth    %7.1f\n", lweth - empty);
    printf("  sw + sh,lw    %7.1f\n", mix - empty);
    printf("  sh,lw cached  %7.1f\n", cach - empty);
    return 0;
}
