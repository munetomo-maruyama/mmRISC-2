#!/bin/sh
# sim_perf.sh : run by init before the shell on the card of make linux-perf.
# The PMU (CPU_CORE_SPEC.md decision 69) through Linux's perf: the generic
# events the device tree maps, raw events of the core (rN = event N), and a
# sample on the overflow interrupt of Sscofpmf (r1 = cycles on an
# hpmcounter). perf stat -v shows each event's count with the time it was
# enabled and the time it really ran on a counter; /proc/interrupts the
# overflow interrupts (riscv-pmu) the runs took.
echo "== sim_perf: interrupts before"
grep -i "pmu\|IPI\|timer" /proc/interrupts
echo "== sim_perf: perf stat -v, cycles and instructions (fixed counters)"
perf stat -v -e cycles,instructions /bin/busybox ls / 2>&1 > /dev/null
echo "== sim_perf: perf stat -v, one generic event"
perf stat -v -e branches /bin/busybox ls / 2>&1 > /dev/null
echo "== sim_perf: perf stat -v, four raw events in a group"
perf stat -v -e '{r3,r4,r5,r6}' /bin/busybox ls / 2>&1 > /dev/null
echo "== sim_perf: perf stat -x, (what perf.sh of the board reads)"
perf stat -x, -e cycles,instructions,r7,r8,r9,ra /bin/busybox ls / 2>&1 > /dev/null
echo "== sim_perf: the L2 (LLC-loads / LLC-load-misses = r12 / r13, CPU_L2_SPEC.md 7)"
perf stat -x, -e LLC-loads,LLC-load-misses,r12,r13 /bin/busybox ls / 2>&1 > /dev/null
echo "== sim_perf: perf record on r1"
perf record -e r1 -c 20000 -o /tmp/perf.data /bin/busybox ls / 2>&1 > /dev/null
# (a line of perf report that starts with "# " would look like the shell
# prompt to tb_BIOS and end the run)
perf report -i /tmp/perf.data --stdio --sort dso 2>&1 | grep -v "^$" | sed 's/^#/;/' | head -20
echo "== sim_perf: interrupts after"
grep -i "pmu\|IPI\|timer" /proc/interrupts
echo "== sim_perf: kernel messages of perf"
dmesg | grep -i "perf\|pmu" | tail -10
echo "== sim_perf: done"
