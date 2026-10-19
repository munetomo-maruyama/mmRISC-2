# Debian on mmRISC-2: compiling on the board itself

[日本語](DEBIAN_J.md)

The board normally boots a small BusyBox root (`software/boot/README.md`). This document replaces it with
**Debian 13 (trixie, riscv64)** on the SD card, with **gcc, make, gdb and git on the board**: C programs are
written, compiled and run on mmRISC-2 itself, and `apt` installs more of Debian's packages from the Internet.
The kernel, OpenSBI and the bitstream stay as they are; only the second partition of the SD card changes.

What it looks like (Rev.02 board, 50 MHz):

```
Debian GNU/Linux 13 mmrisc2 ttyLXU0

mmrisc2 login: root
root@mmrisc2:~# cat t.c
#include <stdio.h>
int main(void)
{
    printf("build on mmRISC-2\n");
    return 0;
}
root@mmrisc2:~# time gcc -O2 -o t t.c && ./t

real    0m20.712s
user    0m7.682s
sys     0m6.799s
build on mmRISC-2
```

## 1. What you need

| | |
|---|---|
| Board | Arty A7-100T with the mmRISC-2 bitstream, booting Linux from the SD card as in `software/boot/README.md` |
| SD card | A second card, 4 GB or more (8 GB or more recommended). The Debian tree takes about 1 GB and a 512 MB swap file is made on it |
| Network | The board's Ethernet on a LAN with DHCP and a way to the Internet (NTP for the clock, `apt`) |
| Host | Linux with `mmdebstrap`, `qemu-user-static`, `binfmt-support` and `arch-test` (Ubuntu 24.04, x86_64 or arm64, was used), Internet access, about 2 GB free |

On Ubuntu, once:

```bash
sudo apt install mmdebstrap qemu-user-static binfmt-support arch-test
```

`qemu-user-static` lets the host run riscv64 programs, which the package scripts of Debian need while the tree
is made; no root is needed for the build itself.

## 2. Making the Debian tree

At the top of the repository:

```bash
./LitexSystem/scripts/build_debian.sh
```

It writes `~/mmlitex_build/debian-riscv64.tar` (about 1 GB; another file name as argument). It takes 10 to 20
minutes, downloading the packages from deb.debian.org. At the end it compiles and runs a C program inside the
tree (under qemu) and prints `build_debian.sh: gcc in the tree compiles and runs`.

Debian's signing keys: Ubuntu's copy of the Debian keyring predates Debian 13's keys. The script then fetches
Debian 12's keyring, which has them, checking every step (Debian 12's signed index against the keys Ubuntu has,
the package list against its hash, the keyring package against the list), so nothing unchecked is trusted.

## 3. Writing the SD card

Partition and format the card as for the BusyBox root ("Making a new card" in `software/boot/README.md`:
partition 1 FAT16 512 MB `LITEXBOOT`, partition 2 ext4 `rootfs`), and copy the three files of
`software/boot/` (`Image`, `fw_jump.bin`, `boot.json`) to partition 1. They are the same for Debian.

Then partition 2, mounted (here at `/media/$USER/rootfs`):

```bash
sudo ./LitexSystem/scripts/sd_debian.sh /media/$USER/rootfs
```

It asks before erasing partition 2, unpacks the tarball with its owners and permissions, and says `done`.
Then `sync`, unmount and take the card out.

With Ubuntu in a virtual machine on a Mac, write partition 1 from the Mac (the FAT written from the VM can be
overwritten by macOS: "Write the first partition from the Mac" in `software/boot/README.md`); partition 2 (ext4)
is written from the VM.

## 4. Booting

Put the card in, connect Ethernet, press RESET. After the usual LiteX BIOS, OpenSBI and Linux, Debian's init
starts:

```
INIT: version 3.14 booting
Using makefile-style concurrent boot in runlevel S.
Checking root file system...rootfs: clean, 27442/1855952 files, 422107/7423744 blocks
...
Configuring network interfaces...
[  171.446968] random: crng init done
DHCPACK of 192.168.0.13 from 192.168.0.1
...
INIT: Entering runlevel: 2
Starting time daemon: chronyd.
Starting OpenBSD Secure Shell server: sshd.
[  189.733096] Adding 524284k swap on /swapfile.

Debian GNU/Linux 13 mmrisc2 ttyLXU0

mmrisc2 login:
```

**The login comes about 3 minutes after RESET.** Most of it is DHCP waiting for the kernel's random number
generator (`crng init done`, about 170 s: the board has no hardware random source, and the generator gathers
its entropy from interrupt timing). Log in as `root`; there is no password on the serial console.

## 5. Using it

```sh
date                         # set by chrony from NTP within seconds of boot
chronyc tracking | head -4   # which server, and the offset
free -m                      # 237 MB of memory, 511 MB of swap
gcc --version; gdb --version # gcc 14.2, gdb 16.3
```

Compiling on the board: a small C file takes about 20 s with `gcc -O2` (the compiler itself is read from the SD
card and runs at 50 MHz); larger programs take correspondingly longer. `make`, `gdb` (with breakpoints in user
programs), `git` and `strace` are there too.

More packages:

```sh
apt update                   # Debian's package lists are large for this board
apt install -y tree          # update + 3 small packages: about 20 minutes
```

SSH: set a password first (`passwd`); then `ssh root@<address>` from the LAN (the address is in `ip addr show
eth0`). Or put a public key in `/root/.ssh/authorized_keys`.

Before turning the power off:

```sh
poweroff
```

and turn it off (or press RESET) after `reboot: Power down`.

To go back to BusyBox, put the BusyBox card in, or write the BusyBox root to partition 2 again with
`scripts/sd_rootfs.sh --full` (`software/boot/README.md`).

## 6. What differs from a stock Debian

`build_debian.sh` starts from Debian's minimal base (`mmdebstrap --variant=minbase`) and makes these changes for
the board:

| | Why |
|---|---|
| sysvinit instead of systemd | Lighter on 256 MB at 50 MHz; the kernel of `software/boot/` has what sysvinit needs |
| A login on the LiteX UART (`ttyLXU0`), root without a password there | The serial console is the board's terminal. SSH refuses root without a password, so the LAN cannot log in until one is set |
| `eth0` by DHCP (`ifupdown`, `isc-dhcp-client`) | |
| chrony | There is no real-time clock: the clock starts at 1970, and `apt` refuses a package list "not valid yet". chrony steps it to the right time at boot (`makestep` of Debian's `chrony.conf`) |
| A 512 MB swap file (`/swapfile`), made at the first boot by `/etc/rc.local` | gcc on larger files needs more than the 237 MB of memory |
| `e2fsprogs` | Debian 13 leaves it out of the minimal base, and the root file system is checked at boot (`fsck.ext4`) |
| `busybox` | So that `software/bench/` (`tftp` and the like) runs as on the BusyBox root |
| gcc, make, gdb, git, strace, OpenSSH, less, vim-tiny, nano, file, ca-certificates, all locales | The development tools |

## 7. When it does not work

| Symptom | Cause, what to do |
|---|---|
| `build_debian.sh`: `riscv64 programs do not run here` | `qemu-user-static` / `binfmt-support` not installed on the host |
| `build_debian.sh`: `The repository ... is not signed` | The keyring could not be fetched or checked (network, or a change of Debian's keys); the messages before say which step |
| The board stops at `Waiting for root device` or `VFS: Unable to mount` | Partition 2 is not ext4 or empty; check with `ls` on the host that `usr/sbin/init` is there |
| It stops in a maintenance shell after `Checking root file system` | A tree made before `e2fsprogs` was added (no `fsck.ext4`): make the tarball again and rewrite partition 2 |
| `date` shows 1970 (or a far future) | chrony has not reached a server yet (no Internet, or DNS): check `ip addr`, `ping 8.8.8.8`, then `/etc/init.d/chrony restart` |
| `apt update`: "not valid yet" or "expired" | The clock is wrong: as above |
| No login prompt for minutes | Wait for `crng init done` (section 4); without Ethernet, DHCP gives up after about a minute more |
| Messages `Cannot persist the following output on disc` | Harmless: the boot log is written once the root is writable |

## 8. How it works

- The same `fw_jump.bin` (OpenSBI with the device tree) and `Image` (Linux 7.2) as for BusyBox boot Debian:
  the kernel command line in the device tree already says `root=/dev/mmcblk0p2`, and the kernel has what Debian's
  userland needs (devtmpfs, tmpfs, Unix sockets, inotify, signalfd / timerfd / eventfd, ext4, swap).
- `build_debian.sh` runs `mmdebstrap` in unshare mode (no root): it downloads the packages, unpacks them and runs
  their scripts with qemu-user, then applies the changes of section 6 as customize hooks, and checks gcc. The
  tarball keeps the owners (root) and permissions, which `sd_debian.sh` restores with `tar --numeric-owner`.
- `/etc/inittab` starts `getty` on `ttyLXU0`, the console of the LiteX UART driver; the other `getty`s (for
  virtual terminals the board does not have) are removed.
