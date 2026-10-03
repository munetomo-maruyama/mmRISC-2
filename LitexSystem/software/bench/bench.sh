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
# CoreMark chooses its own count and runs for at least 10 seconds, which is
# what a valid result needs. Dhrystone repeats with ten times the count
# until a run lasts two seconds. micro takes about a minute.
#
# Run it on a quiet system: whatever else runs (stress.sh, a download) is
# counted in the time.
#---------------------------------------------------------------------------
SERVER=${1:?usage: sh bench.sh <tftp server> [MHz]}
MHZ=${2:-50}
DIR=/tmp/bench
LOG=/tmp/bench.log

mkdir -p "$DIR"
cd "$DIR" || exit 1
for f in coremark dhrystone micro; do
    tftp -g -r "$f" -l "$f" "$SERVER" || { echo "bench: cannot fetch $f from $SERVER"; exit 1; }
    chmod 755 "$f"
done

: > "$LOG"
echo "bench: $(uname -r), $MHZ MHz, $(date)" | tee -a "$LOG"

echo "=== coremark (10 s or more)" | tee -a "$LOG"
./coremark > coremark.out 2>&1
cat coremark.out >> "$LOG"
CM=$(grep "^Iterations/Sec" coremark.out | awk '{ print $3 }')
grep -q "Correct operation validated" coremark.out && CM_OK=ok || CM_OK=NG

echo "=== dhrystone" | tee -a "$LOG"
./dhrystone > dhrystone.out 2>&1
cat dhrystone.out >> "$LOG"
DPS=$(grep "^Dhrystones per Second" dhrystone.out | awk '{ print $4 }')

echo "=== micro" | tee -a "$LOG"
./micro "$MHZ" 2>&1 | tee -a "$LOG"

# The same two built with Zba / Zbb, when the server has them (a core
# without those extensions would trap on them: /proc/cpuinfo must list zba
# and zbb)
ZB=no
if grep -q "zba_zbb" /proc/cpuinfo &&
   tftp -g -r coremark_zb -l coremark_zb "$SERVER" 2> /dev/null &&
   tftp -g -r dhrystone_zb -l dhrystone_zb "$SERVER" 2> /dev/null; then
    ZB=yes
    chmod 755 coremark_zb dhrystone_zb
    echo "=== coremark, Zba / Zbb (10 s or more)" | tee -a "$LOG"
    ./coremark_zb > coremark_zb.out 2>&1
    cat coremark_zb.out >> "$LOG"
    CMZ=$(grep "^Iterations/Sec" coremark_zb.out | awk '{ print $3 }')
    grep -q "Correct operation validated" coremark_zb.out && CMZ_OK=ok || CMZ_OK=NG
    echo "=== dhrystone, Zba / Zbb" | tee -a "$LOG"
    ./dhrystone_zb > dhrystone_zb.out 2>&1
    cat dhrystone_zb.out >> "$LOG"
    DPSZ=$(grep "^Dhrystones per Second" dhrystone_zb.out | awk '{ print $4 }')
fi

echo "" | tee -a "$LOG"
echo "=== summary" | tee -a "$LOG"
awk -v cm="$CM" -v ok="$CM_OK" -v dps="$DPS" -v mhz="$MHZ" 'BEGIN {
    printf "CoreMark   %10.2f iterations/s  %6.3f CoreMark/MHz  (%s)\n", cm, cm / mhz, ok
    # 1 DMIPS = 1757 Dhrystones per second (VAX 11/780)
    printf "Dhrystone  %10d per second     %6.3f DMIPS/MHz\n", dps, dps / 1757 / mhz
}' | tee -a "$LOG"
if [ "$ZB" = yes ]; then
    awk -v cm="$CMZ" -v ok="$CMZ_OK" -v dps="$DPSZ" -v mhz="$MHZ" 'BEGIN {
        printf "CoreMark   %10.2f iterations/s  %6.3f CoreMark/MHz  (%s, Zba/Zbb)\n", cm, cm / mhz, ok
        printf "Dhrystone  %10d per second     %6.3f DMIPS/MHz  (Zba/Zbb)\n", dps, dps / 1757 / mhz
    }' | tee -a "$LOG"
fi
