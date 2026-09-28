#!/bin/sh
#---------------------------------------------------------------------------
# stress.sh : long run of mmRISC-2 on the Arty, under Linux (BusyBox ash)
#
#   stress.sh <tftp server> [minutes]      default 120 minutes
#   stress.sh -             [minutes]      without the network worker
#
# Three workers run at the same time, each checking its own data:
#
#   net  fetches Image (15 MB) from the TFTP server with 1024 byte blocks,
#        so every frame is a large one, and compares its md5
#   sd   writes 2 MB of random data to the ext4 root on the SD card, syncs,
#        drops the page cache so the read comes from the card again, and
#        compares the md5 of what it wrote with what it reads back
#   mem  writes 64 MB of zeros to /tmp (RAM) and compares the md5, which
#        runs the data cache and the DRAM through far more than they hold
#
# Together they keep the CPU, the data cache, the SD card DMA and the
# Ethernet interrupts busy at once, which is where the cache bugs of
# September 2026 were (LitexSystem/docs/BRINGUP.md).
#
# Every iteration is one line in /root/stress.log. A failed check keeps its
# file (net.bad / sd.bad.<n> / mem.bad) for a look afterwards. At the end
# the counts are printed, and dmesg is searched for warnings.
#
# Needs: the address set up (udhcpc), Image on the TFTP server.
#---------------------------------------------------------------------------

SERVER=${1:?usage: stress.sh <tftp server | -> [minutes]}
MINUTES=${2:-120}

IMAGE=Image
IMAGE_MD5=1d0caecd9f373a9fb203dc9c28c2cd34     # LitexRocket/software/boot/Image
ZERO64_MD5=7f614da9329cd3aebf59b91aadc30bf0    # 64 MiB of zeros

LOG=${STRESS_LOG:-/root/stress.log}
WORK_SD=${STRESS_SD:-/root/stress.d}           # on the SD card (ext4)
WORK_RAM=${STRESS_RAM:-/tmp/stress.d}          # tmpfs
END=$(( $(date +%s) + MINUTES * 60 ))

mkdir -p "$WORK_SD" "$WORK_RAM"
: > "$LOG"

log() {
	echo "$(date +%H:%M:%S) $*" >> "$LOG"
}

# 1 : time is up
over() {
	[ "$(date +%s)" -ge "$END" ]
}

md5() {
	md5sum "$1" | awk '{ print $1 }'
}

#---------------------------------------------------------------------------
worker_net() {
	i=0; ok=0; ng=0
	while ! over; do
		i=$((i + 1))
		f=$WORK_RAM/net.img
		rm -f "$f"
		t0=$(date +%s)
		if tftp -g -b 1024 -r "$IMAGE" -l "$f" "$SERVER" 2>> "$LOG"; then
			m=$(md5 "$f")
			t=$(( $(date +%s) - t0 ))
			if [ "$m" = "$IMAGE_MD5" ]; then
				ok=$((ok + 1)); log "net $i OK  ${t}s"
			else
				ng=$((ng + 1)); log "net $i NG  md5 $m"
				# keep the first one only: 15 MB each, in RAM
				[ -e "$WORK_RAM/net.bad" ] || mv "$f" "$WORK_RAM/net.bad"
			fi
		else
			ng=$((ng + 1)); log "net $i NG  tftp failed"
		fi
		rm -f "$f"
	done
	echo "net $i $ok $ng" > "$WORK_RAM/result.net"
}

#---------------------------------------------------------------------------
worker_sd() {
	i=0; ok=0; ng=0
	while ! over; do
		i=$((i + 1))
		f=$WORK_SD/blob
		dd if=/dev/urandom of="$f" bs=64k count=32 2> /dev/null
		m1=$(md5 "$f")
		sync
		# read it back from the card, not from the page cache
		{ echo 3 > /proc/sys/vm/drop_caches; } 2> /dev/null
		m2=$(md5 "$f")
		if [ "$m1" = "$m2" ]; then
			ok=$((ok + 1)); log "sd  $i OK"
		else
			ng=$((ng + 1)); log "sd  $i NG  written $m1 read $m2"
			mv "$f" "$WORK_SD/sd.bad.$i"
		fi
		rm -f "$f"
	done
	sync
	echo "sd  $i $ok $ng" > "$WORK_RAM/result.sd"
}

#---------------------------------------------------------------------------
worker_mem() {
	i=0; ok=0; ng=0
	while ! over; do
		i=$((i + 1))
		f=$WORK_RAM/mem.fill
		dd if=/dev/zero of="$f" bs=64k count=1024 2> /dev/null
		m=$(md5 "$f")
		if [ "$m" = "$ZERO64_MD5" ]; then
			ok=$((ok + 1)); log "mem $i OK"
		else
			ng=$((ng + 1)); log "mem $i NG  md5 $m"
			[ -e "$WORK_RAM/mem.bad" ] || mv "$f" "$WORK_RAM/mem.bad"
		fi
		rm -f "$f"
	done
	echo "mem $i $ok $ng" > "$WORK_RAM/result.mem"
}

#---------------------------------------------------------------------------
rm -f "$WORK_RAM"/result.*
echo "stress: $MINUTES minutes, log in $LOG (tail -f $LOG to watch)"
log "start, $MINUTES minutes, server $SERVER"
dmesg > "$WORK_RAM/dmesg.before"

pids=""
if [ "$SERVER" != "-" ]; then
	worker_net & pids="$pids $!"
fi
worker_sd  & pids="$pids $!"
worker_mem & pids="$pids $!"

# a line on the console every 10 minutes, so a hang shows
n=0
while ! over; do
	sleep 60
	n=$((n + 1))
	[ $((n % 10)) -eq 0 ] &&
		echo "stress: $(date +%H:%M:%S) $(grep -c ' OK' "$LOG") OK, $(grep -c ' NG' "$LOG") NG, $(uptime)"
done
wait $pids

log "end"
echo ""
echo "=== stress result (iterations, ok, ng) ==="
cat "$WORK_RAM"/result.* 2> /dev/null
echo "=== new kernel messages that look like trouble ==="
dmesg > "$WORK_RAM/dmesg.after"
# only the lines that were not there before the run
awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' \
	"$WORK_RAM/dmesg.before" "$WORK_RAM/dmesg.after" |
	grep -i -E 'warning|oops|bug|error|fail|timeout|call trace' || echo "(none)"
if grep -q ' NG' "$LOG"; then
	echo "=== FAILED: see the NG lines in $LOG ==="
	grep ' NG' "$LOG"
else
	echo "=== PASS ==="
fi
