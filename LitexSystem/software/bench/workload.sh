#!/bin/sh
#---------------------------------------------------------------------------
# workload.sh : Linux workloads beyond CoreMark, counted by the PMU
#
#   tftp -g -r workload.sh 192.168.0.12 && sh workload.sh 192.168.0.12
#
# CoreMark fits in the caches (BENCH.md 13). This runs ordinary work that
# does not, each one five times under perf stat:
#
#   gzip       gzip -6 of 2 MB of the kernel Image   integer work, ~256 KB tables
#   gunzip     the same back                         streaming, small working set
#   sha256     sha256sum of 4 MB                     streaming reads
#   find       find / -xdev and ls -lR of the root   kernel, VFS, dentry cache
#   tar        tar of /bin /sbin /usr /etc /lib,      ext4 and the SD card
#              page cache dropped first
#   sdread     dd of 16 MB of the root partition,     SD DMA through the D$
#              page cache dropped first
#   forkexec   100 x fork + exec of busybox uname     process creation, page
#                                                     faults, TLB
#   tftp       TFTP download of perf (3 MB)           Ethernet, IP stack
#
# Runs 1-4 count the 16 events of the core four at a time (there are four
# programmable counters; cycles and instructions have their own), run 5
# splits cycles and instructions into user and kernel mode. rN is event N
# of the core (CPU_CORE_SPEC.md decision 69). Each event is divided by the
# cycles or instructions of its own run. The log is /tmp/workload.log, the
# raw counts /tmp/wl/*.csv.
#
# Needs the PMU (bitstream, fw_jump.bin, Image with perf; perf.sh works).
# About 10 minutes.
#---------------------------------------------------------------------------
SERVER=${1:?usage: sh workload.sh <tftp server>}
DIR=${WL_DIR:-/tmp/wl}
LOG=${WL_LOG:-/tmp/workload.log}

mkdir -p "$DIR"
cd "$DIR" || exit 1
rm -f ./*.csv
for f in perf Image; do
    tftp -g -r "$f" -l "$f" "$SERVER" || { echo "workload.sh: cannot fetch $f from $SERVER"; exit 1; }
done
chmod 755 perf
[ -d /sys/bus/event_source/devices/cpu ] ||
    { echo "workload.sh: the kernel has no PMU driver (CONFIG_RISCV_PMU_SBI)"; exit 1; }

# the inputs, in /tmp (RAM)
dd if=Image of=in2m bs=1024 count=2048 2> /dev/null
dd if=Image of=in4m bs=1024 count=4096 2> /dev/null
gzip -6 -c in2m > in2m.gz

: > "$LOG"
echo "workload.sh: $(uname -r), $(date)" | tee -a "$LOG"

drop() {
    sync
    [ -w /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches
}

# the command of each workload (run by sh -c, so perf counts what it starts)
cmd() {
    case $1 in
    gzip)     echo "gzip -6 -c $DIR/in2m > /dev/null" ;;
    gunzip)   echo "gunzip -c $DIR/in2m.gz > /dev/null" ;;
    sha256)   echo "sha256sum $DIR/in4m > /dev/null" ;;
    find)     echo "find / -xdev > /dev/null; ls -lR /bin /sbin /usr /etc /lib > /dev/null 2>&1" ;;
    tar)      echo "tar cf - /bin /sbin /usr /etc /lib 2> /dev/null | cat > /dev/null" ;;
    sdread)   echo "dd if=/dev/mmcblk0p2 of=/dev/null bs=65536 count=256 2> /dev/null" ;;
    forkexec) echo "i=0; while [ \$i -lt 100 ]; do /bin/busybox uname > /dev/null; i=\$((i+1)); done" ;;
    tftp)     echo "tftp -g -r perf -l $DIR/perf.copy $SERVER" ;;
    esac
}

EVSETS="r7,r8,r9,ra rb,rc,r11,rd r5,r6,r3,r4 re,rf,r10,r1"
WORKLOADS="gzip gunzip sha256 find tar sdread forkexec tftp"

for w in $WORKLOADS; do
    c=$(cmd $w)
    echo "=== $w: $c" | tee -a "$LOG"
    g=1
    for ev in $EVSETS; do
        case $w in tar|sdread) drop ;; esac
        ./perf stat -x, -o "$w.$g.csv" -e "cycles,instructions,$ev" sh -c "$c" 2>> "$LOG"
        g=$((g+1))
    done
    case $w in tar|sdread) drop ;; esac
    ./perf stat -x, -o "$w.5.csv" -e "cycles:u,r1:k,instructions:u,r2:k" sh -c "$c" 2>> "$LOG"
    cat "$w".*.csv | grep -v "^#\|^$" >> "$LOG"
done

# one row per workload. In each file: field 1 the count, field 3 the event.
echo "" | tee -a "$LOG"
echo "=== summary" | tee -a "$LOG"
echo "per 1000 instructions: I\$ / D\$ misses (line fills), ITLB / DTLB misses (walks), exceptions" | tee -a "$LOG"
echo "% of cycles: D\$ wait, front end empty, back end full, load use; wrong guesses % of branches" | tee -a "$LOG"
echo "kern %: kernel share of the cycles" | tee -a "$LOG"
printf "%-9s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s\n" \
    workload Mcyc CPI 'I$' 'D$' ITLB DTLB exc 'D$w%' 'FE%' 'BE%' 'LU%' 'mis%' 'kern%' | tee -a "$LOG"
for w in $WORKLOADS; do
    for g in 1 2 3 4 5; do
        grep -v "^#\|^$" "$w.$g.csv" | sed "s/^/$g,/"
    done | awk -F, -v w="$w" '
        # $1 group, $2 count, $4 event
        { g = $1; v = $2 + 0; e = $4
          if (e == "cycles")              cyc[g] = v
          else if (e == "instructions")   ins[g] = v
          else if (e == "cycles:u")       cu = v
          else if (e == "r1:k")           ck = v
          else                            { val[e] = v; grp[e] = g } }
        function k(e)   { return (ins[grp[e]] > 0) ? 1000 * val[e] / ins[grp[e]] : 0 }
        function p(e)   { return (cyc[grp[e]] > 0) ?  100 * val[e] / cyc[grp[e]] : 0 }
        END {
            c = (cyc[1] + cyc[2] + cyc[3] + cyc[4]) / 4
            i = (ins[1] + ins[2] + ins[3] + ins[4]) / 4
            mis = (val["r5"] > 0) ? 100 * val["r6"] / val["r5"] : 0
            kern = (cu + ck > 0) ? 100 * ck / (cu + ck) : 0
            printf "%-9s %6.0f %6.3f %6.2f %6.2f %6.3f %6.3f %6.3f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f\n",
                   w, c / 1e6, (i > 0) ? c / i : 0, k("r7"), k("r8"), k("r9"), k("ra"), k("rf"),
                   p("rb"), p("rc"), p("r11"), p("rd"), mis, kern
        }'
done | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "CoreMark for comparison (perf.sh, BENCH.md 13): CPI 1.134, I\$ 0.49, D\$ 0.16, ITLB 0.002, DTLB 0.06," | tee -a "$LOG"
echo "  D\$ wait 0.7 %, front end 4.8 %, back end 5.6 %, load use 2.0 %, wrong guesses 7.2 %" | tee -a "$LOG"
