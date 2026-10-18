#!/bin/sh
# sim_tlb.sh : run by init before the shell on the card of make linux-tlb
# (E3a of ROADMAP.md). Small versions of the user-mode loads of
# software/bench/workload.sh, each under perf stat: cycles, instructions,
# the walks of the ITLB and the DTLB (r9 / ra), the cycles the walker works
# for the DTLB (r1b) and the cycles MR waits for the DTLB (r1d, CPU_CORE_SPEC.md
# decision 79). Built with other TLB sizes, the same runs show what a larger
# TLB would save.
EV=cycles,instructions,r9,ra,r1b,r1d
run() {
    echo "== tlb: $1"
    shift
    perf stat -x, -e $EV sh -c "$*" 2>&1 > /dev/null | grep -v "^$" | sed 's/^#/;/'
}
# CoreMark (coremark_zb_max of software/bench): too short for a valid score,
# but the difference of 90 and 30 iterations is its steady state, the cycles
# per iteration bench.sh measures (5 first, so that both find the binary in
# the page cache; decision 82 was found this way)
run warmup "/root/coremark 0x0 0x0 0x66 5"
run coremark "/root/coremark 0x0 0x0 0x66 30"
run coremark90 "/root/coremark 0x0 0x0 0x66 90"
run gunzip "gunzip -c /root/wl.gz"
run awk    "awk 'BEGIN { for (i = 0; i < 20000; i++) a[i % 5000] += i; print a[1] }'"
run md5sum "md5sum /root/wl.bin"
echo "== tlb: done"
