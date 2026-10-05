#!/bin/sh
#---------------------------------------------------------------------------
# perf.sh : where CoreMark's cycles go, counted by the PMU of the board
#
#   tftp -g -r perf.sh 192.168.0.12 && sh perf.sh 192.168.0.12
#
# Fetches perf (scripts/build_perf.sh) and CoreMark from the TFTP server
# into /tmp/bench and runs CoreMark four times under perf stat, four events
# of the core at a time (there are four counters, hpmcounter3-6; cycles and
# instructions have counters of their own), then once under perf record.
# Each run takes CoreMark's 10 s or more. The log is /tmp/perf.log.
#
# rN is event N of the core (CPU_CORE_SPEC.md decision 69, also listed in
# the pmu node of the device tree). Needs the kernel with perf
# (CONFIG_PERF_EVENTS, CONFIG_RISCV_PMU_SBI) and a bitstream with the PMU.
#---------------------------------------------------------------------------
SERVER=${1:?usage: sh perf.sh <tftp server>}
DIR=/tmp/bench
LOG=/tmp/perf.log

mkdir -p "$DIR"
cd "$DIR" || exit 1
# CoreMark built with Zba / Zbb when the core has them
B=coremark
grep -q "zba_zbb" /proc/cpuinfo && B=coremark_zb
for f in perf $B; do
    tftp -g -r "$f" -l "$f" "$SERVER" || { echo "perf.sh: cannot fetch $f from $SERVER"; exit 1; }
    chmod 755 "$f"
done
[ -d /sys/bus/event_source/devices/cpu ] ||
    { echo "perf.sh: the kernel has no PMU driver (CONFIG_RISCV_PMU_SBI)"; exit 1; }

: > "$LOG"
echo "perf.sh: $(uname -r), $B, $(date)" | tee -a "$LOG"

# one run: perf stat -x, (value,unit,event,...) into stat.csv
run() {
    echo "=== $B under perf stat -e $1" | tee -a "$LOG"
    ./perf stat -x, -o stat.$2.csv -e "$1" ./$B > $B.out 2>&1
    grep -q "Correct operation validated" $B.out || echo "perf.sh: $B did not validate" | tee -a "$LOG"
    cat stat.$2.csv >> "$LOG"
}
run cycles,instructions,r3,r4,r5,r6 1
run cycles,instructions,r7,r8,r9,ra 2
run cycles,instructions,rb,rc,rd,re 3
run cycles,instructions,rf,r10,r11,r1 4

echo "" | tee -a "$LOG"
echo "=== summary (per 1000 instructions, or % of the cycles)" | tee -a "$LOG"
cat stat.1.csv stat.2.csv stat.3.csv stat.4.csv | awk -F, '
    $3 == "cycles"       { cyc += $1; nc++; next }
    $3 == "instructions" { ins += $1; ni++; next }
    $3 ~ /^r[0-9a-f]+$/  { v[$3] = $1 }
    END {
        c = cyc / nc; i = ins / ni
        printf "cycles %d, instructions %d, IPC %.3f (CPI %.3f)\n", c, i, i / c, c / i
        split("r3 loads|r4 stores|r5 conditional branches|r6 wrong guesses|r7 I$ misses|r8 D$ misses|r9 ITLB misses|ra DTLB misses|rf exceptions|r10 interrupts", e, "|")
        for (k = 1; k in e; k++) {
            n = substr(e[k], 1, index(e[k], " ") - 1)
            printf "  %-24s %12d  %8.2f /1000 instr\n", substr(e[k], index(e[k], " ") + 1), v[n], 1000 * v[n] / i
        }
        split("rb waiting for the D$|rc front end empty|rd load use|re waiting for MDU / FPU|r11 back end full", s, "|")
        for (k = 1; k in s; k++) {
            n = substr(s[k], 1, index(s[k], " ") - 1)
            printf "  %-24s %12d  %8.2f %% of cycles\n", substr(s[k], index(s[k], " ") + 1), v[n], 100 * v[n] / c
        }
        if (v["r5"] > 0) printf "  branch prediction: %.2f %% of the conditional branches wrong (r6 also has jumps)\n", 100 * v["r6"] / v["r5"]
        printf "  r1 (cycles on an hpmcounter) %d, cycles %d\n", v["r1"], c
    }' | tee -a "$LOG"

echo "" | tee -a "$LOG"
# every million cycles (50 a second): each sample is an overflow interrupt
# that stops and restarts the counters through OpenSBI, and at 100000 the
# kernel found that too slow and kept lowering its sample rate
echo "=== $B under perf record (r1 every 1000000 cycles, overflow interrupt)" | tee -a "$LOG"
./perf record -e r1 -c 1000000 -o perf.data ./$B > $B.out 2>&1
./perf report -i perf.data --stdio --sort dso 2>&1 | grep -v "^$\|^#$\|tips.txt" | tee -a "$LOG"
