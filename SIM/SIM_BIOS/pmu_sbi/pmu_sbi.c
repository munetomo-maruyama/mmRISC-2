// pmu_sbi.c : the PMU of the core as Linux's perf sees it, without Linux
//
// OpenSBI starts this in S mode in place of the kernel (make pmu-sbi). It
// makes the calls of the SBI PMU extension that Linux's riscv_pmu_sbi
// driver makes and checks what comes back: the counters OpenSBI reports,
// the counter each kind of event is given (a generic event, a cache event,
// a raw event, cycles and instructions on the fixed counters, which needs
// Smcntrpmf once Sscofpmf is there), that the counters count, and that an
// overflow arrives as the local counter overflow interrupt in S mode.
//
// It prints through the legacy console of OpenSBI and ends with "\n# ",
// where tb_BIOS stops a Linux run. "PMU_SBI RESULT : PASS / FAIL" sums up.
#include <stdint.h>

#define SBI_EXT_PMU          0x504D55
#define PMU_NUM_COUNTERS     0
#define PMU_COUNTER_GET_INFO 1
#define PMU_CFG_MATCH        2
#define PMU_START            3
#define PMU_STOP             4
#define PMU_EVENT_GET_INFO   8           // SBI 3.0

#define CFG_SKIP_MATCH       (1 << 0)
#define CFG_CLEAR_VALUE      (1 << 1)
#define CFG_SET_SINH         (1 << 4)
#define CFG_SET_UINH         (1 << 5)
#define CFG_SET_VSINH        (1 << 6)
#define CFG_SET_VUINH        (1 << 7)
#define START_SET_INIT       (1 << 0)
#define STOP_RESET           (1 << 0)

#define EV_CYCLES            0x00001
#define EV_INSTRUCTIONS      0x00002
#define EV_CACHE_MISSES      0x00004
#define EV_BRANCHES          0x00005
#define EV_BRANCH_MISSES     0x00006
#define EV_L1D_READ_ACCESS   0x10000
#define EV_RAW_V2            0x30000

struct sbiret { long error; long value; };

static struct sbiret ecall(long ext, long fid, long a0, long a1, long a2,
                           long a3, long a4)
{
    register long r0 asm("a0") = a0;
    register long r1 asm("a1") = a1;
    register long r2 asm("a2") = a2;
    register long r3 asm("a3") = a3;
    register long r4 asm("a4") = a4;
    register long r6 asm("a6") = fid;
    register long r7 asm("a7") = ext;
    asm volatile("ecall" : "+r"(r0), "+r"(r1)
                 : "r"(r2), "r"(r3), "r"(r4), "r"(r6), "r"(r7) : "memory");
    return (struct sbiret){ r0, r1 };
}

static void putc_(char c) { ecall(0x01, 0, c, 0, 0, 0, 0); }   // legacy console
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void puthex(uint64_t v)
{
    puts_("0x");
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void putdec(long v)
{
    char b[24]; int n = 0;
    if (v < 0) { putc_('-'); v = -v; }
    do { b[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) putc_(b[--n]);
}

static int fails;
static void check(const char *what, int ok)
{
    puts_(ok ? "  ok   " : "  FAIL "); puts_(what); putc_('\n');
    if (!ok) fails++;
}

// a counter by its CSR (cycle 0xC00 .. hpmcounter31 0xC1F), from S mode
static uint64_t read_ctr(int idx)
{
    uint64_t v = 0;
    switch (idx) {
    case 0: asm volatile("csrr %0, 0xc00" : "=r"(v)); break;
    case 2: asm volatile("csrr %0, 0xc02" : "=r"(v)); break;
    case 3: asm volatile("csrr %0, 0xc03" : "=r"(v)); break;
    case 4: asm volatile("csrr %0, 0xc04" : "=r"(v)); break;
    case 5: asm volatile("csrr %0, 0xc05" : "=r"(v)); break;
    case 6: asm volatile("csrr %0, 0xc06" : "=r"(v)); break;
    }
    return v;
}

// some work with branches, loads and a wrong guess or two
static volatile uint64_t sink[64];
static void work(int n)
{
    for (int i = 0; i < n; i++) {
        sink[i & 63] += i;
        if ((i % 3) == 0) sink[(i * 7) & 63] ^= i;
    }
}

static long match(const char *name, long cmask, long flags, long ev, long data)
{
    struct sbiret r = ecall(SBI_EXT_PMU, PMU_CFG_MATCH, 0, cmask, flags, ev, data);
    puts_("  match "); puts_(name); puts_(": error "); putdec(r.error);
    puts_(", counter "); putdec(r.value); putc_('\n');
    return r.error ? -1 : r.value;
}

static void stop(long idx)
{
    ecall(SBI_EXT_PMU, PMU_STOP, idx, 1, STOP_RESET, 0, 0);
}

volatile int lcof_seen;
void s_trap(void)
{
    uint64_t cause, ovf;
    asm volatile("csrr %0, scause" : "=r"(cause));
    asm volatile("csrr %0, 0xda0" : "=r"(ovf));          // scountovf
    if (cause == ((1ULL << 63) | 13)) {
        lcof_seen = (int)ovf;
        asm volatile("csrc sip, %0" :: "r"(1 << 13));
        asm volatile("csrc sie, %0" :: "r"(1 << 13));
    } else {
        puts_("unexpected trap "); puthex(cause); putc_('\n');
        fails++;
        uint64_t epc;
        asm volatile("csrr %0, sepc" : "=r"(epc));
        asm volatile("csrw sepc, %0" :: "r"(epc + 4));
    }
}

void main(void)
{
    puts_("\nPMU_SBI: the SBI PMU extension on mmRISC-2\n");

    struct sbiret r = ecall(SBI_EXT_PMU, PMU_NUM_COUNTERS, 0, 0, 0, 0, 0);
    puts_("  counters: "); putdec(r.value); putc_('\n');
    long hwmask = 0;
    for (long i = 0; i < r.value && i < 32; i++) {
        struct sbiret q = ecall(SBI_EXT_PMU, PMU_COUNTER_GET_INFO, i, 0, 0, 0, 0);
        if (q.error || (q.value < 0)) continue;            // firmware counter
        hwmask |= 1L << i;
        puts_("  counter "); putdec(i); puts_(": csr "); puthex(q.value & 0xfff);
        puts_(", width "); putdec(((q.value >> 12) & 63) + 1); putc_('\n');
    }
    check("hardware counters 0, 2, 3-6", hwmask == 0x7d);

    // which standard events OpenSBI says it has (SBI 3.0): Linux asks this
    // at boot and does not offer the ones it says no to
    {
        static struct { uint32_t idx, out; uint64_t data; } __attribute__((aligned(16)))
            info[6] = { { EV_CYCLES }, { EV_INSTRUCTIONS }, { EV_CACHE_MISSES },
                        { EV_BRANCHES }, { EV_BRANCH_MISSES }, { EV_L1D_READ_ACCESS } };
        struct sbiret q = ecall(SBI_EXT_PMU, PMU_EVENT_GET_INFO,
                                (long)info, 0, 6, 0, 0);
        puts_("  event info: error "); putdec(q.error); puts_(", supported");
        int all = (q.error == 0);
        for (int k = 0; k < 6; k++) {
            putc_(' '); puthex(info[k].idx); putc_('='); putdec(info[k].out & 1);
            all &= info[k].out & 1;
        }
        putc_('\n');
        check("cycles, instructions and the mapped events reported", all);
    }

    // cycles and instructions, as Linux asks for them (no SKIP_MATCH)
    long c_cyc = match("cycles", hwmask, CFG_CLEAR_VALUE, EV_CYCLES, 0);
    long c_ins = match("instructions", hwmask, CFG_CLEAR_VALUE, EV_INSTRUCTIONS, 0);
    check("cycles on counter 0 (Smcntrpmf)", c_cyc == 0);
    check("instructions on counter 2", c_ins == 2);

    // four events on the four programmable counters, a fifth finds none
    long c_br  = match("branches", hwmask, CFG_CLEAR_VALUE, EV_BRANCHES, 0);
    long c_bm  = match("branch-misses", hwmask, CFG_CLEAR_VALUE, EV_BRANCH_MISSES, 0);
    long c_ld  = match("L1-dcache-loads", hwmask, CFG_CLEAR_VALUE, EV_L1D_READ_ACCESS, 0);
    long c_raw = match("raw r2 (instructions)", hwmask, CFG_CLEAR_VALUE, EV_RAW_V2, 2);
    long c_x   = match("cache-misses, a fifth", hwmask, CFG_CLEAR_VALUE, EV_CACHE_MISSES, 0);
    check("four programmable counters handed out",
          c_br >= 3 && c_bm >= 3 && c_ld >= 3 && c_raw >= 3 &&
          c_br != c_bm && c_br != c_ld && c_br != c_raw && c_bm != c_ld &&
          c_bm != c_raw && c_ld != c_raw);
    check("no counter for a fifth", c_x < 0);

    // count
    long all[6] = { c_cyc, c_ins, c_br, c_bm, c_ld, c_raw };
    for (int k = 0; k < 6; k++)
        if (all[k] >= 0) ecall(SBI_EXT_PMU, PMU_START, all[k], 1, START_SET_INIT, 0, 0);
    work(1000);
    uint64_t v[6];
    for (int k = 0; k < 6; k++) v[k] = all[k] >= 0 ? read_ctr(all[k]) : 0;
    for (int k = 0; k < 6; k++) if (all[k] >= 0) stop(all[k]);
    const char *nm[6] = { "cycles", "instructions", "branches", "branch-misses",
                          "L1-dcache-loads", "raw r2" };
    for (int k = 0; k < 6; k++) {
        puts_("  "); puts_(nm[k]); puts_(" = "); putdec(v[k]); putc_('\n');
    }
    check("cycles counted", v[0] > 1000);
    check("instructions counted", v[1] > 1000 && v[1] < v[0]);
    check("branches counted", v[2] >= 1000 && v[2] < v[1]);
    check("a wrong guess or more", v[3] > 0 && v[3] < v[2]);
    check("loads counted", v[4] >= 1000 && v[4] < v[1]);
    check("raw r2 about the instructions", v[5] > v[1] / 2 && v[5] <= v[1] + 100);

    // a raw event as Linux's perf stat asks for it: every counter Linux
    // knows (the firmware ones too) and exclude_guest (VSINH / VUINH)
    long c_lx = match("raw r3, as Linux asks", 0x7ffffdL,
                      CFG_CLEAR_VALUE | CFG_SET_VSINH | CFG_SET_VUINH, EV_RAW_V2, 3);
    check("raw event with Linux's mask and flags", c_lx >= 3 && c_lx <= 6);
    if (c_lx >= 0) stop(c_lx);

    // released the way Linux's riscv_pmu_del() does it: a stop, then a stop
    // with RESET on the stopped counter. The counter must be free after it
    // (OpenSBI used to keep it: opensbi_patches/0001)
    long c_d = match("branches, for a Linux-style release", hwmask, CFG_CLEAR_VALUE,
                     EV_BRANCHES, 0);
    if (c_d >= 0) {
        ecall(SBI_EXT_PMU, PMU_START, c_d, 1, START_SET_INIT, 0, 0);
        ecall(SBI_EXT_PMU, PMU_STOP, c_d, 1, 0, 0, 0);
        ecall(SBI_EXT_PMU, PMU_STOP, c_d, 1, STOP_RESET, 0, 0);
    }
    long c_d2 = match("branches, the same counter again", hwmask, CFG_CLEAR_VALUE,
                      EV_BRANCHES, 0);
    check("a stop, then a stop with RESET frees the counter", c_d >= 3 && c_d2 == c_d);
    if (c_d2 >= 0) stop(c_d2);

    // stopped: they are all free again
    long c_again = match("branches, after the stop", hwmask, CFG_CLEAR_VALUE, EV_BRANCHES, 0);
    check("a counter again after the stop", c_again >= 3);
    if (c_again >= 0) stop(c_again);

    // user mode left out (UINH): nothing of S mode is lost
    long c_f = match("instructions, UINH, on a programmable counter",
                     hwmask & ~5L, CFG_CLEAR_VALUE | CFG_SET_UINH, EV_RAW_V2, 2);
    if (c_f >= 0) {
        ecall(SBI_EXT_PMU, PMU_START, c_f, 1, START_SET_INIT, 0, 0);
        work(100);
        uint64_t f = read_ctr(c_f);
        stop(c_f);
        puts_("  counted in S with UINH: "); putdec(f); putc_('\n');
        check("UINH does not stop S mode", f > 100);
    } else check("UINH filter accepted", 0);

    // the overflow: cycles on a programmable counter, 2000 before the wrap
    long c_o = match("raw r1 (cycles), for the overflow", hwmask & ~5L,
                     CFG_CLEAR_VALUE, EV_RAW_V2, 1);
    if (c_o >= 0) {
        extern void s_trap_entry(void);
        asm volatile("csrw stvec, %0" :: "r"(s_trap_entry));
        asm volatile("csrs sie, %0" :: "r"(1 << 13));
        asm volatile("csrsi sstatus, 2");
        ecall(SBI_EXT_PMU, PMU_START, c_o, 1, START_SET_INIT, -2000, 0);
        for (int i = 0; i < 200 && !lcof_seen; i++) work(10);
        asm volatile("csrci sstatus, 2");
        stop(c_o);
        puts_("  scountovf at the interrupt: "); puthex(lcof_seen); putc_('\n');
        // OpenSBI keeps OF set on a counter it is not using (that is how
        // it keeps it from interrupting), so only this counter's bit counts
        check("overflow interrupt taken in S mode", (lcof_seen >> c_o) & 1);
    } else check("a counter for the overflow", 0);

    puts_(fails ? "PMU_SBI RESULT : FAIL\n" : "PMU_SBI RESULT : PASS\n");
    puts_("\n# ");
    for (;;) asm volatile("wfi");
}
