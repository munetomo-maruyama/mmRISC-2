#!/bin/sh
#---------------------------------------------------------------------------
# bench.sh : run the benchmarks on the board (BusyBox ash)
#
#   tftp -g -r bench.sh 192.168.0.12 && sh bench.sh 192.168.0.12 [MHz]
#
# Fetches coremark, dhrystone and micro from the TFTP server into /tmp (RAM,
# nothing is written to the SD card), runs them one after the other and
# prints a summary per MHz. The log is /tmp/bench.log.
#
# CoreMark and Dhrystone run in up to four builds (Makefile), each when the
# server has it:
#
#   coremark / dhrystone            rv64gc, -O2 (the comparison with others)
#   coremark_zb / dhrystone_zb      the same with Zba / Zbb (only when
#                                   /proc/cpuinfo lists zba and zbb: a core
#                                   without them would trap)
#   coremark_max / dhrystone_max    rv64gc, the flags that make each fastest
#                                   (OPT_MAX_CM / OPT_MAX_DHRY in the Makefile)
#   coremark_zb_max / dhrystone_zb_max   both
#   dhrystone_lto / dhrystone_zb_lto     Dhrystone with -flto: inlined across
#                                   its two files, which its rules forbid. A
#                                   number to know, outside the rules
#                                   ("off-rule" in the summary)
#
# CoreMark chooses its own count and runs for at least 10 seconds, which is
# what a valid result needs. Dhrystone repeats with ten times the count
# until a run lasts two seconds. micro takes about a minute. All of it
# about three minutes.
#
# Run it on a quiet system: whatever else runs (stress.sh, a download) is
# counted in the time.
#---------------------------------------------------------------------------
SERVER=${1:?usage: sh bench.sh <tftp server> [MHz]}
MHZ=${2:-50}
DIR=/tmp/bench
LOG=/tmp/bench.log
SUMMARY=/tmp/bench.summary

mkdir -p "$DIR"
cd "$DIR" || exit 1
for f in coremark dhrystone micro; do
    tftp -g -r "$f" -l "$f" "$SERVER" || { echo "bench: cannot fetch $f from $SERVER"; exit 1; }
    chmod 755 "$f"
done

: > "$LOG"
: > "$SUMMARY"
echo "bench: $(uname -r), $MHZ MHz, $(date)" | tee -a "$LOG"

# run_pair <suffix> <label> : coremark<suffix> and dhrystone<suffix>, and
# their lines of the summary
run_pair() {
    sfx=$1
    label=$2
    echo "=== coremark$sfx (10 s or more)" | tee -a "$LOG"
    ./coremark$sfx > coremark$sfx.out 2>&1
    cat coremark$sfx.out >> "$LOG"
    cm=$(grep "^Iterations/Sec" coremark$sfx.out | awk '{ print $3 }')
    grep -q "Correct operation validated" coremark$sfx.out && ok=ok || ok=NG
    echo "=== dhrystone$sfx" | tee -a "$LOG"
    ./dhrystone$sfx > dhrystone$sfx.out 2>&1
    cat dhrystone$sfx.out >> "$LOG"
    dps=$(grep "^Dhrystones per Second" dhrystone$sfx.out | awk '{ print $4 }')
    awk -v cm="$cm" -v ok="$ok" -v dps="$dps" -v mhz="$MHZ" -v l="$label" 'BEGIN {
        printf "CoreMark   %10.2f iterations/s  %6.3f CoreMark/MHz  (%s%s)\n", cm, cm / mhz, ok, l
        # 1 DMIPS = 1757 Dhrystones per second (VAX 11/780)
        printf "Dhrystone  %10d per second     %6.3f DMIPS/MHz%s\n", dps, dps / 1757 / mhz,
               l == "" ? "" : "  (" substr(l, 3) ")"
    }' >> "$SUMMARY"
}

# run_dhry <suffix> <label> : dhrystone<suffix> alone
run_dhry() {
    echo "=== dhrystone$1" | tee -a "$LOG"
    ./dhrystone$1 > dhrystone$1.out 2>&1
    cat dhrystone$1.out >> "$LOG"
    dps=$(grep "^Dhrystones per Second" dhrystone$1.out | awk '{ print $4 }')
    awk -v dps="$dps" -v mhz="$MHZ" -v l="$2" 'BEGIN {
        printf "Dhrystone  %10d per second     %6.3f DMIPS/MHz  (%s)\n", dps, dps / 1757 / mhz, l
    }' >> "$SUMMARY"
}

# fetch <suffix> : both binaries of a build, if the server has them
fetch() {
    tftp -g -r coremark$1 -l coremark$1 "$SERVER" 2> /dev/null &&
    tftp -g -r dhrystone$1 -l dhrystone$1 "$SERVER" 2> /dev/null &&
    chmod 755 coremark$1 dhrystone$1
}

run_pair "" ""

echo "=== micro" | tee -a "$LOG"
./micro "$MHZ" 2>&1 | tee -a "$LOG"

ZB=no
grep -q "zba_zbb" /proc/cpuinfo && ZB=yes
[ $ZB = yes ] && fetch _zb && run_pair _zb ", Zba/Zbb"
fetch _max && run_pair _max ", max opt"
[ $ZB = yes ] && fetch _zb_max && run_pair _zb_max ", Zba/Zbb, max opt"
tftp -g -r dhrystone_lto -l dhrystone_lto "$SERVER" 2> /dev/null &&
    chmod 755 dhrystone_lto && run_dhry _lto "LTO, off-rule"
[ $ZB = yes ] && tftp -g -r dhrystone_zb_lto -l dhrystone_zb_lto "$SERVER" 2> /dev/null &&
    chmod 755 dhrystone_zb_lto && run_dhry _zb_lto "Zba/Zbb, LTO, off-rule"

echo "" | tee -a "$LOG"
echo "=== summary" | tee -a "$LOG"
tee -a "$LOG" < "$SUMMARY"
