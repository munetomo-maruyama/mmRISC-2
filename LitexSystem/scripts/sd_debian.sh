#!/bin/bash
#---------------------------------------------------------------------------
# sd_debian.sh : write the Debian root (build_debian.sh) to an SD card
#
#   sudo ./scripts/sd_debian.sh <mount point of partition 2> [tarball]
#
# Partition 2 (ext4) gets the Debian tree; whatever is on it goes first, so
# use a second card, or keep the BusyBox root of the first one elsewhere
# (scripts/sd_rootfs.sh writes it again). Partition 1 (LITEXBOOT) is not
# touched: the same fw_jump.bin and Image boot Debian (root=/dev/mmcblk0p2).
# The tarball defaults to ~/mmlitex_build/debian-riscv64.tar of the user
# running sudo. A card of 4 GB or more; the tree is about 1 GB, plus a
# 512 MB swap file made at the first boot.
#---------------------------------------------------------------------------
set -e

DST=${1:?usage: sudo $0 <mount point of partition 2> [tarball]}
HOME_U=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
TAR=${2:-$HOME_U/mmlitex_build/debian-riscv64.tar}

[ "$(id -u)" = 0 ]   || { echo "run it with sudo (the files have to belong to root)"; exit 1; }
[ -d "$DST" ]        || { echo "no directory $DST"; exit 1; }
mountpoint -q "$DST" || { echo "$DST is not a mount point: is the SD card mounted?"; exit 1; }
[ -f "$TAR" ]        || { echo "no tarball $TAR (scripts/build_debian.sh makes it)"; exit 1; }
[ "$(findmnt -n -o FSTYPE "$DST")" = ext4 ] || { echo "$DST is not ext4: is it partition 2?"; exit 1; }

echo "This erases everything on $DST ($(findmnt -n -o SOURCE "$DST")) and writes Debian there."
read -r -p "Go on? [y/N] " ans
[ "$ans" = y ] || [ "$ans" = Y ] || { echo "nothing written"; exit 1; }

find "$DST" -mindepth 1 -maxdepth 1 ! -name lost+found -exec rm -rf {} +
tar -x -p --numeric-owner -f "$TAR" -C "$DST"
sync

echo "done. Check:"
echo "  ls -l $DST/sbin/init $DST/etc/inittab $DST/usr/bin/gcc"
echo "then: sudo umount $DST"
