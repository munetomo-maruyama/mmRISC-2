#!/bin/bash
#---------------------------------------------------------------------------
# build_debian.sh : a Debian riscv64 root file system for self-hosted builds
#
#   ./scripts/build_debian.sh [output tarball]   (default ~/mmlitex_build/debian-riscv64.tar)
#
# Debian 13 (trixie, riscv64 is an official port) with gcc, make, gdb and
# git on the board itself (docs/DEBIAN.md). Built without root
# by mmdebstrap (unshare mode); the riscv64 programs of the package scripts
# run under qemu-user through binfmt. Needs, once on the host:
#
#   sudo apt install mmdebstrap qemu-user-static binfmt-support arch-test
#
# Then write the tarball to the second partition of an SD card with
# scripts/sd_debian.sh (sudo). The first partition stays as it is: the same
# fw_jump.bin and Image boot Debian (root=/dev/mmcblk0p2).
#
# What differs from a stock Debian, for this board:
#   - sysvinit instead of systemd (256 MB at 50 MHz; the kernel has what
#     sysvinit needs and not all systemd wants)
#   - a login on the LiteX UART (ttyLXU0), root without a password on it
#     (set one with passwd; SSH does not let root in without one)
#   - eth0 by DHCP, the clock set by chrony at boot (there is no RTC, and
#     apt refuses a Release file "not yet valid" in 1970; chrony steps the
#     clock by 56 years at once, makestep of its default chrony.conf. The
#     ntpdate of ntpsec stepped it twice, to 2083, and BusyBox's ntpd is
#     not in Debian's busybox)
#   - a 512 MB swap file made at the first boot (/swapfile, fallocate: no
#     wait for writing 512 MB to the card)
#   - busybox, so that software/bench (tftp, ...) runs as on the BusyBox root
#   - e2fsprogs: trixie leaves it out of minbase, and the root is checked
#     at boot (fstab pass 1) with fsck.ext4
#
# About 10 to 20 minutes on the host. The packages come from deb.debian.org.
#---------------------------------------------------------------------------
set -e
OUT=${1:-$HOME/mmlitex_build/debian-riscv64.tar}
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}

command -v mmdebstrap > /dev/null || { echo "build_debian.sh: mmdebstrap is not installed"; exit 1; }
arch-test riscv64 > /dev/null 2>&1 || { echo "build_debian.sh: riscv64 programs do not run here (qemu-user-static, binfmt-support)"; exit 1; }
mkdir -p "$(dirname "$OUT")"

# The keys of the suite. Ubuntu's debian-archive-keyring (2023) predates
# trixie's keys; then the one of Debian 12 (bookworm), which has them, is
# fetched through a chain of checks: bookworm's InRelease verified with the
# host's keys, the package index against its hash, the keyring package
# against the index.
KEYDIR=$HOME/mmlitex_build/debian-keyring
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
curl -sfL -o /tmp/InRelease.$$ "$MIRROR/dists/$SUITE/InRelease"
if ! gpgv --keyring "$KEYRING" /tmp/InRelease.$$ > /dev/null 2>&1; then
    KEYRING=$KEYDIR/y/usr/share/keyrings/debian-archive-keyring.gpg
    if ! gpgv --keyring "$KEYRING" /tmp/InRelease.$$ > /dev/null 2>&1; then
        echo "build_debian.sh: fetching Debian's archive keyring (bookworm)"
        mkdir -p "$KEYDIR" && cd "$KEYDIR"
        curl -sfL -o InRelease.bookworm "$MIRROR/dists/bookworm/InRelease"
        gpgv --keyring /usr/share/keyrings/debian-archive-keyring.gpg InRelease.bookworm 2> /dev/null ||
            { echo "build_debian.sh: bookworm's InRelease does not verify"; exit 1; }
        H=$(awk '/^SHA256:/{f=1;next} /^[A-Z]/{f=0} f && $3=="main/binary-amd64/Packages.xz"{print $1}' InRelease.bookworm)
        curl -sfL -o Packages.xz "$MIRROR/dists/bookworm/main/binary-amd64/Packages.xz"
        echo "$H  Packages.xz" | sha256sum -c --quiet
        read -r FN KH < <(xz -dc Packages.xz | awk '/^Package: debian-archive-keyring$/{f=1} f&&/^Filename:/{fn=$2} f&&/^SHA256:/{h=$2} f&&/^$/{print fn, h; exit}')
        curl -sfL -o keyring.deb "$MIRROR/$FN"
        echo "$KH  keyring.deb" | sha256sum -c --quiet
        rm -rf y && dpkg -x keyring.deb y
        cd - > /dev/null
        gpgv --keyring "$KEYRING" /tmp/InRelease.$$ > /dev/null 2>&1 ||
            { echo "build_debian.sh: $SUITE's InRelease does not verify with it either"; exit 1; }
    fi
fi
rm -f /tmp/InRelease.$$
echo "build_debian.sh: keys $KEYRING"
# mmdebstrap's apt runs as a mapped user that may not read the home
# directory: give it a copy it can read
cp "$KEYRING" /tmp/mmrisc-debian-keyring.$$.gpg && chmod 644 /tmp/mmrisc-debian-keyring.$$.gpg
KEYRING=/tmp/mmrisc-debian-keyring.$$.gpg
trap 'rm -f /tmp/mmrisc-debian-keyring.$$.gpg' EXIT

PKGS=sysvinit-core,e2fsprogs,ifupdown,isc-dhcp-client,iproute2,iputils-ping,netbase,chrony
PKGS=$PKGS,openssh-server,ca-certificates,procps,less,vim-tiny,nano,file,busybox,kmod
PKGS=$PKGS,build-essential,gdb,git,make,strace,locales-all

mmdebstrap --mode=unshare --variant=minbase --architectures=riscv64 --keyring="$KEYRING" \
    --aptopt='APT::Install-Recommends "false"' \
    --include="$PKGS" \
    --customize-hook='echo mmrisc2 > "$1/etc/hostname"' \
    --customize-hook='printf "127.0.0.1\tlocalhost\n127.0.1.1\tmmrisc2\n" > "$1/etc/hosts"' \
    --customize-hook='printf "/dev/mmcblk0p2\t/\text4\tdefaults,noatime\t0\t1\nproc\t/proc\tproc\tdefaults\t0\t0\ntmpfs\t/tmp\ttmpfs\tdefaults\t0\t0\n" > "$1/etc/fstab"' \
    --customize-hook='printf "auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n" > "$1/etc/network/interfaces"' \
    --customize-hook='sed -i "/:respawn:\/sbin\/getty.* tty[0-9]/d" "$1/etc/inittab"' \
    --customize-hook='echo "T0:2345:respawn:/sbin/getty -L ttyLXU0 115200 vt100" >> "$1/etc/inittab"' \
    --customize-hook='echo ttyLXU0 >> "$1/etc/securetty" || true' \
    --customize-hook='chroot "$1" passwd -d root' \
    --customize-hook='printf "#!/bin/sh\n# once, a swap file (chrony sets the clock)\nif [ ! -f /swapfile ]; then\n    { fallocate -l 512M /swapfile 2> /dev/null || dd if=/dev/zero of=/swapfile bs=1M count=512 2> /dev/null; } && chmod 600 /swapfile && mkswap /swapfile > /dev/null\nfi\nswapon /swapfile 2> /dev/null || true\nexit 0\n" > "$1/etc/rc.local"; chmod 755 "$1/etc/rc.local"' \
    --customize-hook='printf "int main(void) { return 0; }\n" > "$1/tmp/t.c" && chroot "$1" gcc -O2 -o /tmp/t /tmp/t.c && chroot "$1" /tmp/t && rm -f "$1/tmp/t" "$1/tmp/t.c" && echo "build_debian.sh: gcc in the tree compiles and runs"' \
    "$SUITE" "$OUT" "$MIRROR"

ls -l "$OUT"
