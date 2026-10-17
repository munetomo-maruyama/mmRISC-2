#!/bin/sh
#---------------------------------------------------------------------------
# workload.sh : Linux workloads beyond CoreMark, counted by the PMU
#
#   tftp -g -r workload.sh 192.168.0.12 && sh workload.sh 192.168.0.12
#   ... && sh workload.sh 192.168.0.12 profile     (by function instead)
#   ... && sh workload.sh 192.168.0.12 ips         (by instruction, W1 / W2)
#   ... && sh workload.sh 192.168.0.12 ips report  (the same, from the last data)
#
# CoreMark fits in the caches (BENCH.md 13). This runs ordinary work that
# does not, each one five times under perf stat. Only applets the BusyBox of
# the SD card has (it has no gzip, sha256sum or find):
#
#   gunzip     2 MB of the kernel Image, gzipped on   streaming, user mode
#              the host (image2m.gz, make tftp)
#   md5sum     md5sum of 4 MB                         streaming hash
#   awk        an awk loop over a 5000 entry table    an interpreter: much code,
#                                                     hash tables
#   ls         ls -lR of the root                     kernel, VFS, lstat
#   ext4read   cat of an 8 MB file on the SD card,    ext4, the SD card
#              page cache dropped first
#   sdread     dd of 16 MB of the root partition,     SD DMA through the D$
#              page cache dropped first
#   forkexec   100 x fork + exec of busybox uname     process creation, page
#                                                     faults, TLB
#   tftp       TFTP download of perf (3 MB)           Ethernet, IP stack
#
# Each command is run once first and has to succeed; one that does not is
# reported as FAILED instead of being counted.
#
# Runs 1-4 count the 16 events of the core four at a time (there are four
# programmable counters; cycles and instructions have their own), run 5 the
# L2 (r12 reads = L1 fills, r13 misses; both 0 on a bitstream without the
# L2), runs 6-7 the memory waits of M0 (ROADMAP.md): r14 MA waits for a
# store, r15 MA waits while the D$ handles a miss, r16 / r17 one / two or
# more line fills outstanding, r18 MA waits while a dirty victim is copied
# out, with rb (all of MA's waits) again, r19 / r1a the prefetches of the I$
# and the misses served by them (M3), run 8 the page table walks (E3a): r1b /
# r1c the cycles the walker works for the DTLB / ITLB, r1d the cycles MR waits
# for the DTLB, with ra (DTLB walks) again. Run 0 splits cycles and
# instructions into user and kernel mode. rN is event N of the core, in hex
# (CPU_CORE_SPEC.md decision 69). Each event is divided by the cycles or
# instructions of its own run. The log is /tmp/workload.log, the raw counts
# /tmp/wl/*.csv.
#
# With "profile" as the second argument it counts nothing but samples each
# load once with perf record (r1 every 100000 cycles) and lists its first
# functions, then the share of the CRC and checksum functions in each load
# (it judged Zbc, ROADMAP.md F3: BENCH.md 24 and 25). Needs perf with libelf (D2).
#
# With "ips" it samples md5sum, sdread, forkexec and tftp three times each
# (perf record every 20000 events of r1 cycles, r14 MA waits for a store, r15
# MA waits while the D$ handles a miss) and counts the samples by instruction
# (symbol+offset), the first 15 of each, to be read against the kernel's
# disassembly on the host (ROADMAP.md W1 / W2). An interrupt is attached to
# the instruction entering EX, so a sample lands about two instructions after
# the one MA waits for.
#
# Needs the PMU (bitstream, fw_jump.bin, Image with perf; perf.sh works).
# About 16 minutes (profile: about 4, ips: about 3).
#---------------------------------------------------------------------------
SERVER=${1:?usage: sh workload.sh <tftp server>}
DIR=${WL_DIR:-/tmp/wl}
LOG=${WL_LOG:-/tmp/workload.log}

mkdir -p "$DIR"
cd "$DIR" || exit 1
rm -f ./*.csv
for f in perf Image image2m.gz; do
    tftp -g -r "$f" -l "$f" "$SERVER" || { echo "workload.sh: cannot fetch $f from $SERVER"; exit 1; }
done
chmod 755 perf
[ -d /sys/bus/event_source/devices/cpu ] ||
    { echo "workload.sh: the kernel has no PMU driver (CONFIG_RISCV_PMU_SBI)"; exit 1; }

# the inputs: in /tmp (RAM), and one file on the SD card (removed at the end)
dd if=Image of=in4m bs=1024 count=4096 2> /dev/null
SDFILE=/root/wl_file
dd if=Image of=$SDFILE bs=65536 count=128 2> /dev/null
sync

: > "$LOG"
echo "workload.sh: $(uname -r), $(date)" | tee -a "$LOG"

drop() {
    sync
    [ -w /proc/sys/vm/drop_caches ] && echo 3 > /proc/sys/vm/drop_caches
}

# the command of each workload (run by sh -c, so perf counts what it starts)
cmd() {
    case $1 in
    gunzip)   echo "gunzip -c $DIR/image2m.gz > /dev/null" ;;
    md5sum)   echo "md5sum $DIR/in4m > /dev/null" ;;
    awk)      echo "awk 'BEGIN { for (i = 0; i < 100000; i++) a[i % 5000] += i; print a[1] }' > /dev/null" ;;
    ls)       echo "ls -lR /bin /sbin /usr /etc /root /lib > /dev/null" ;;
    ext4read) echo "cat $SDFILE > /dev/null" ;;
    sdread)   echo "dd if=/dev/mmcblk0p2 of=/dev/null bs=65536 count=256 2> /dev/null" ;;
    forkexec) echo "i=0; while [ \$i -lt 100 ]; do /bin/busybox uname > /dev/null; i=\$((i+1)); done" ;;
    tftp)     echo "tftp -g -r perf -l $DIR/perf.copy $SERVER" ;;
    esac
}

EVSETS="r7,r8,r9,ra rb,rc,r11,rd r5,r6,r3,r4 re,rf,r10,r1 r12,r13 r14,r15,r16,r17 r18,rb,r19,r1a r1b,r1c,r1d,ra"
WORKLOADS="gunzip md5sum awk ls ext4read sdread forkexec tftp"

cold() { case $1 in ext4read|sdread) drop ;; esac; }

if [ "$2" = ips ]; then
    for w in md5sum sdread forkexec tftp; do
        c=$(cmd $w)
        for ev in r1 r14 r15; do
            if [ "$3" != report ]; then
                cold $w
                ./perf record -e $ev -c 20000 -o "$w.$ev.data" sh -c "$c" > /dev/null 2>> "$LOG"
            fi
            # the first 15 by count (BusyBox has no sort)
            ./perf script -i "$w.$ev.data" -F ip,sym,symoff 2>/dev/null |
                awk -v w="$w" -v ev="$ev" '{ k = ($2 == "") ? $1 : $2; n[k]++; t++ }
                    END { printf "=== %s %s: %d samples\n", w, ev, t
                          for (i = 0; i < 15; i++) {
                              m = 0
                              for (k in n) if (n[k] > m) { m = n[k]; b = k }
                              if (m == 0) break
                              printf "%6.2f %5d %s\n", 100 * m / t, m, b
                              delete n[b]
                          } }' | tee -a "$LOG"
        done
    done
    rm -f "$SDFILE"
    exit 0
fi

if [ "$2" = profile ]; then
    for w in $WORKLOADS; do
        c=$(cmd $w)
        echo "=== $w by function: $c" | tee -a "$LOG"
        cold $w
        ./perf record -e r1 -c 100000 -o "$w.data" sh -c "$c" > /dev/null 2>> "$LOG"
        ./perf report -i "$w.data" --stdio --sort dso,sym 2>/dev/null |
            grep -v "^#\|^$" | head -15 | tee -a "$LOG"
    done
    echo "" | tee -a "$LOG"
    echo "=== CRC and checksum functions, % of each load's samples" | tee -a "$LOG"
    for w in $WORKLOADS; do
        ./perf report -i "$w.data" --stdio --sort sym 2>/dev/null | grep -v "^#\|^$" |
            awk -v w="$w" '/crc|csum|chksum|checksum/ { t += $1; l = l " " $NF "(" $1 ")" }
                           END { printf "%-9s %6.2f %%  %s\n", w, t, l }' | tee -a "$LOG"
    done
    rm -f "$SDFILE"
    exit 0
fi

for w in $WORKLOADS; do
    c=$(cmd $w)
    echo "=== $w: $c" | tee -a "$LOG"
    if ! sh -c "$c" >> "$LOG" 2>&1; then
        echo "workload.sh: $w FAILED (the command does not succeed; see $LOG)" | tee -a "$LOG"
        continue
    fi
    g=1
    for ev in $EVSETS; do
        cold $w
        ./perf stat -x, -o "$w.$g.csv" -e "cycles,instructions,$ev" sh -c "$c" 2>> "$LOG"
        g=$((g+1))
    done
    cold $w
    ./perf stat -x, -o "$w.0.csv" -e "cycles:u,r1:k,instructions:u,r2:k" sh -c "$c" 2>> "$LOG"
    cat "$w".*.csv | grep -v "^#\|^$" >> "$LOG"
done

# one row per workload. In each file: field 1 the count, field 3 the event.
echo "" | tee -a "$LOG"
echo "=== summary" | tee -a "$LOG"
echo "per 1000 instructions: I\$ / D\$ misses (line fills), ITLB / DTLB misses (walks), exceptions" | tee -a "$LOG"
echo "% of cycles: D\$ wait, front end empty, back end full, load use, MDU / FPU wait; wrong guesses % of branches" | tee -a "$LOG"
echo "kern %: kernel share of the cycles; L2: reads per 1000 instructions, misses % of the reads" | tee -a "$LOG"
printf "%-9s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s %6s\n" \
    workload Mcyc CPI 'I$' 'D$' ITLB DTLB exc 'D$w%' 'FE%' 'BE%' 'LU%' 'MDU%' 'mis%' 'kern%' L2 'L2m%' | tee -a "$LOG"
for w in $WORKLOADS; do
    if [ ! -f "$w.0.csv" ]; then
        printf "%-9s FAILED\n" "$w"
        continue
    fi
    for g in 0 1 2 3 4 5; do
        grep -v "^#\|^$" "$w.$g.csv" | sed "s/^/$g,/"
    done | awk -F, -v w="$w" '
        # $1 group, $2 count, $4 event
        { g = $1; v = $2 + 0; e = $4
          if (e == "cycles" && g > 0)     cyc[g] = v
          else if (e == "instructions" && g > 0) ins[g] = v
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
            l2m = (val["r12"] > 0) ? 100 * val["r13"] / val["r12"] : 0
            printf "%-9s %6.0f %6.3f %6.2f %6.2f %6.3f %6.3f %6.3f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.2f %6.1f\n",
                   w, c / 1e6, (i > 0) ? c / i : 0, k("r7"), k("r8"), k("r9"), k("ra"), k("rf"),
                   p("rb"), p("rc"), p("r11"), p("rd"), p("re"), mis, kern, k("r12"), l2m
        }'
done | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "=== the memory waits (M0), % of cycles: MA waits (all, as stores, while the D\$ handles a miss," | tee -a "$LOG"
echo "    while a dirty victim is copied out), line fills outstanding (1 or more, 2 or more);" | tee -a "$LOG"
echo "    I\$ prefetches per 1000 instructions and the share of them that served a miss" | tee -a "$LOG"
printf "%-9s %7s %7s %7s %7s %7s %7s %7s %7s\n" workload 'MAw%' 'store%' 'miss%' 'victim%' 'fill1%' 'fill2%' 'pfI$' 'pfuse%' | tee -a "$LOG"
for w in $WORKLOADS; do
    [ -f "$w.7.csv" ] || continue
    for g in 6 7; do
        grep -v "^#\|^$" "$w.$g.csv" | sed "s/^/$g,/"
    done | awk -F, -v w="$w" '
        { g = $1; v = $2 + 0; e = $4
          if (e == "cycles")            cyc[g] = v
          else if (e == "instructions") ins[g] = v
          else                          { val[e] = v; grp[e] = g } }
        function p(e) { return (cyc[grp[e]] > 0) ? 100 * val[e] / cyc[grp[e]] : 0 }
        function k(e) { return (ins[grp[e]] > 0) ? 1000 * val[e] / ins[grp[e]] : 0 }
        END {
            use = (val["r19"] > 0) ? 100 * val["r1a"] / val["r19"] : 0
            printf "%-9s %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.1f\n",
                   w, p("rb"), p("r14"), p("r15"), p("r18"), p("r16"), p("r17"), k("r19"), use
        }'
done | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "=== the page table walks (E3a), % of cycles: the walker works for the DTLB / ITLB, MR waits for" | tee -a "$LOG"
echo "    the DTLB; cycles per walk of each side (the ITLB walks counted in run 1)" | tee -a "$LOG"
printf "%-9s %7s %7s %7s %7s %7s %7s\n" workload 'DTLB' 'Dwalk%' 'Iwalk%' 'MRw%' 'cyc/Dw' 'cyc/Iw' | tee -a "$LOG"
for w in $WORKLOADS; do
    [ -f "$w.8.csv" ] || continue
    for g in 1 8; do
        grep -v "^#\|^$" "$w.$g.csv" | sed "s/^/$g,/"
    done | awk -F, -v w="$w" '
        { g = $1; v = $2 + 0; e = $4
          if (e == "cycles")            cyc[g] = v
          else if (e == "instructions") ins[g] = v
          else                          val[g, e] = v }
        END {
            dw = val[8, "ra"]; iw = (ins[1] > 0) ? val[1, "r9"] * ins[8] / ins[1] : 0
            printf "%-9s %7.2f %7.2f %7.2f %7.2f %7.1f %7.1f\n", w,
                   (ins[8] > 0) ? 1000 * dw / ins[8] : 0,
                   (cyc[8] > 0) ? 100 * val[8, "r1b"] / cyc[8] : 0,
                   (cyc[8] > 0) ? 100 * val[8, "r1c"] / cyc[8] : 0,
                   (cyc[8] > 0) ? 100 * val[8, "r1d"] / cyc[8] : 0,
                   (dw > 0) ? val[8, "r1b"] / dw : 0, (iw > 0) ? val[8, "r1c"] / iw : 0
        }'
done | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "CoreMark for comparison (perf.sh, BENCH.md 13): CPI 1.134, I\$ 0.49, D\$ 0.16, ITLB 0.002, DTLB 0.06," | tee -a "$LOG"
echo "  D\$ wait 0.7 %, front end 4.8 %, back end 5.6 %, load use 2.0 %, wrong guesses 7.2 %" | tee -a "$LOG"
rm -f "$SDFILE"
