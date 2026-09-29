#!/bin/bash
#---------------------------------------------------------------------------
# sd_rootfs.sh : write the root file system of the SD card (partition 2)
#
#   sudo ./scripts/sd_rootfs.sh <mount point of partition 2>
#   sudo ./scripts/sd_rootfs.sh --full <mount point of partition 2>
#
# The root is the BusyBox tree of the Rocket build (BASE, default
# ~/mmlitex_build/initramfs, the same tree as its initrd_bb) with what this
# repository adds on top of it, software/rootfs/:
#
#   etc/inittab                      mounts, DHCP on eth0, clean shutdown
#   sbin/init -> ../bin/busybox      the kernel looks for /sbin/init
#   usr/share/udhcpc/default.script  sets the address udhcpc obtains
#   root/stress.sh                   the long run (software/boot/README.md)
#
# On an empty partition (no bin/busybox yet), or with --full, the whole tree
# is written first; otherwise only software/rootfs/ is, so what is already
# on the card stays. Everything ends up owned by root. Unmount the card
# before taking it out.
#---------------------------------------------------------------------------
set -e

FULL=0
if [ "$1" = "--full" ]; then FULL=1; shift; fi
DST=${1:?usage: sudo $0 [--full] <mount point of the SD card root>}

HERE=$(cd "$(dirname "$0")" && pwd)
OVERLAY="$(dirname "$HERE")/software/rootfs"
BASE=${BASE:-$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)/mmlitex_build/initramfs}

[ "$(id -u)" = 0 ]   || { echo "run it with sudo (the files have to belong to root)"; exit 1; }
[ -d "$DST" ]        || { echo "no directory $DST"; exit 1; }
mountpoint -q "$DST" || { echo "$DST is not a mount point: is the SD card mounted?"; exit 1; }

if [ $FULL = 1 ] || [ ! -e "$DST/bin/busybox" ]; then
	[ -x "$BASE/bin/busybox" ] || { echo "no BusyBox tree at $BASE (set BASE=...)"; exit 1; }
	echo "writing the BusyBox tree from $BASE"
	cp -a "$BASE/." "$DST/"
fi

echo "writing $OVERLAY"
cp -a "$OVERLAY/." "$DST/"
chown -R 0:0 "$DST"
chmod 755 "$DST/root/stress.sh" "$DST/usr/share/udhcpc/default.script"
sync

echo "done. Check:"
echo "  ls -l $DST/sbin/init $DST/etc/inittab"
echo "then: sudo umount $DST"
