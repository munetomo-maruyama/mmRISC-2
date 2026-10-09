# SD card

[日本語](README_J.md)

## What goes on it

The card is split into 2 partitions.

| Partition | Format | Label | Contents |
|---|---|---|---|
| 1 | FAT16, 512 MB | `LITEXBOOT` | The 3 files below (in the root) |
| 2 | ext4, all the rest | `rootfs` | Root file system |

The 3 files of the first partition are all in this directory (`software/boot/`).

| File | Where it comes from | Load address | md5 (2026-10-04) |
|---|---|---|---|
| `fw_jump.bin` | Made here by `scripts/build_opensbi.sh` (with the device tree) | 0x8000_0000 | `28461f3da61988ac2ee6e61d7ddf1570` |
| `Image` | The Linux kernel. The same configuration as built for the Rocket configuration, rebuilt with `CONFIG_PERF_EVENTS` / `CONFIG_RISCV_PMU_SBI` added for the performance counters (`perf`) (2026-10, `CPU_CORE_SPEC.md` decision 69) | 0x8020_0000 | `1d886448db1ae0b8e1629cfeba6b605b` |
| `boot.json` | The placement table the BIOS reads. Same as the Rocket configuration | ― | `a1c356008baa859fa615b879d0fa18f3` |

All 3 are under git, so a card can be made straight from a clone of the repository (where they come from
and their licenses: "Distributed binaries" below). When you change the device tree and run
`scripts/build_opensbi.sh` again, commit the new `fw_jump.bin` too (it is used as a pair with the
bitstream; if they do not match, nothing is printed).

The second partition is the BusyBox set of the Rocket configuration (`~/mmlitex_build/initramfs`) with
`software/rootfs/` of this repository on top (inittab, `sbin/init`, the udhcpc script, the stress test
`stress.sh`). `scripts/sd_rootfs.sh` writes it.

## Distributed binaries

| File | Source | How it is built | License |
|---|---|---|---|
| `Image` | Linux, [litex-hub/linux](https://github.com/litex-hub/linux) commit `4929f78c004ecab9b68bb41018a3d11749dcea62` (based on 7.2.0-rc2). Unmodified | The `.config` this `Image` was built with is `linux.config` in the same directory (the Rocket configuration's settings plus only `CONFIG_PERF_EVENTS`, `CONFIG_RISCV_PMU` and `CONFIG_RISCV_PMU_SBI`). Put it as `.config` and run `make ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- Image`. Compiler: riscv64-unknown-linux-gnu-gcc 13.2.0 | GPL-2.0. The corresponding source (a tar of that commit and `linux.config`) is on the GitHub Release [`linux-src-4929f78c004e`](https://github.com/munetomo-maruyama/mmRISC-2/releases/tag/linux-src-4929f78c004e) |
| `fw_jump.bin` | OpenSBI, [riscv-software-src/opensbi](https://github.com/riscv-software-src/opensbi) commit `3593a5facc4c6938b90429a6973ba9ee21fc5899` (v1.9 series). The source is not changed; the patches of `opensbi_patches/` (2026-10: `0001` also frees stopped counters on a stop with RESET; without it Linux's `perf` runs out of counters) are applied to a copy for the build | `scripts/build_opensbi.sh` (applies the patches, `PLATFORM=generic`, embeds the device tree `../mmrisc_arty.dts` with `FW_FDT_PATH`) | BSD-2-Clause (`COPYING.OpenSBI.BSD`) |
| `linux.config` | The configuration of the kernel above | ― | GPL-2.0 (part of the kernel) |
| `opensbi_patches/` | This repository (patches to OpenSBI) | ― | BSD-2-Clause, to match OpenSBI |
| `boot.json` | This repository | ― | Apache-2.0 (same as this repository) |

The `-dirty` in the kernel's version string is because the working tree lacks files whose names differ
only in case (13 of them, such as netfilter's `xt_*.h`), not because of a code change (it happens when
copying through a place that does not distinguish case). What was checked (2026-10-09): the only files
the working tree shows as "modified" are those 13 that differ only in case, all netfilter files and
tools tests, and `linux.config` has `CONFIG_NETFILTER` disabled, so none of them goes into the build.
`Image` can therefore be built as it is from the commit above and `linux.config`. Rebuilding from the
Release's tar and `linux.config` gives the same size (15,464,960 bytes) and the same `.config`; the only
differences are the build time (in the version banner and the time stamps of the built-in initramfs)
and the `./` of some file names (whether the build was in or out of the tree).

## Write the first partition from the Mac (since 2026-10-05)

**What is written to the first partition (FAT) from Ubuntu on Parallels can disappear after the card is
reinserted.** When the card reader is plugged in again, Parallels first connects it to the Mac and macOS
mounts the card. Even if it is then handed to the VM and written there, macOS keeps the old FAT and root
directory from when it mounted the card, and writes them back when the card returns to the Mac. The
files written from the VM disappear and only macOS's `.Spotlight-V100` remains. Once the write-back
corrupted the directory and Linux remounted it read-only (round 15 of `docs/BRINGUP.md`).

Writing the 3 files of the first partition from the Mac's Terminal is the sure way (the repository is in
the shared folder, so it is under the Mac's home):

```bash
cp ~/Documents/CQ/RISCV/mmRISC/mmRISC-2/LitexSystem/software/boot/{Image,fw_jump.bin,boot.json} /Volumes/LITEXBOOT/ && sync
md5 /Volumes/LITEXBOOT/Image /Volumes/LITEXBOOT/fw_jump.bin /Volumes/LITEXBOOT/boot.json
diskutil eject /Volumes/LITEXBOOT
```

If the md5s match the table above, eject and put the card in the board. The files macOS adds
(`.Spotlight-V100`, `.fseventsd`, `.Trashes`) do not affect booting. macOS does not touch the second
partition (ext4), so it may be written with the Ubuntu procedure below. To write the first partition
from Ubuntu as well, set the card reader in Parallels to "always connect to this virtual machine" and
never let the Mac mount it.

## Writing (Ubuntu on Parallels Desktop)

On Ubuntu in Parallels Desktop, a card may or may not be mounted automatically when inserted. The USB
card reader also sometimes drops and reconnects, and a drop in the middle of a write corrupts the file
system (round 10 of `docs/BRINGUP.md`). So every time, go **unmount everything → mount → write → sync →
unmount → power off**, all with `udisksctl`. `udisksctl` is the same mechanism as the desktop's
automount, and it also creates and removes the mount point (`/media/<user>/<label>`).

Run the following at the top of the repository.

**0. Find the card's device name.** If the card reader is not connected to the VM, connect it to Ubuntu
from the Parallels menu (Devices → USB).

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

The card is the one with the card's size (28.8G or so) and partitions `LITEXBOOT` and `rootfs`. Below it
is written as `/dev/sdb` (**substitute if different**; the name can change after a reconnect).

**1. Unmount everything.** If it is not mounted, it only says `is not mounted`, which does no harm.
Check that `MOUNTPOINT` in `lsblk` is empty.

```bash
udisksctl unmount -b /dev/sdb1
udisksctl unmount -b /dev/sdb2
lsblk -o NAME,MOUNTPOINT /dev/sdb
```

**2. Mount.** The mount point is printed, as in `Mounted /dev/sdb1 at /media/<user>/LITEXBOOT`.

```bash
udisksctl mount -b /dev/sdb1
udisksctl mount -b /dev/sdb2
```

**3. Write.** The first partition is mounted as yours, so no `sudo` is needed. The second partition is
written with `sudo` so that its files belong to root.

```bash
cp LitexSystem/software/boot/fw_jump.bin LitexSystem/software/boot/Image \
   LitexSystem/software/boot/boot.json /media/$USER/LITEXBOOT/
sudo LitexSystem/scripts/sd_rootfs.sh /media/$USER/rootfs
```

`sd_rootfs.sh` writes the whole set if the card has no BusyBox yet, or only the differences if it has
(files made on the card stay). Add `--full` to rewrite the whole set.

**4. Flush.**

```bash
sync
```

**5. Unmount and power off.** `power-off` completes all writes before detaching the card. Pull the card
(or disconnect the USB in Parallels) only after it finishes.

```bash
udisksctl unmount -b /dev/sdb1
udisksctl unmount -b /dev/sdb2
udisksctl power-off -b /dev/sdb
```

## Making a new card

**Everything on the card is erased.** Always check the device name (here `/dev/sdb`) with `lsblk`, and
never give the PC's disk (`sda`).

After steps 0 and 1 (unmount everything):

```bash
printf 'label: dos\nstart=2048, size=512MiB, type=6\ntype=83\n' | sudo sfdisk /dev/sdb
lsblk -o NAME,SIZE /dev/sdb                  # sdb1 is 512M, sdb2 the rest
udisksctl unmount -b /dev/sdb1               # unmount if they were mounted automatically right after
udisksctl unmount -b /dev/sdb2
sudo mkfs.vfat -F 16 -n LITEXBOOT /dev/sdb1
sudo mkfs.ext4 -L rootfs /dev/sdb2
```

The rest is the same as steps 2 to 5 above (`sd_rootfs.sh` writes the whole set to an empty partition).

## When it does not work

- `mount point does not exist`: with `sudo mount`, the mount point directory is missing (unmounting
  removed it). Use `udisksctl mount`.
- `Input/output error`, or `Synchronize Cache(10) failed` or `I/O error` in the kernel log
  (`sudo dmesg | tail -30`): the card reader dropped. Reconnect, start again from step 0, and check the
  file systems before writing (unmounted, as after step 1):
  ```bash
  sudo fsck.vfat -a /dev/sdb1
  sudo e2fsck -f /dev/sdb2
  ```
- To check that the card really has the data (reading from the card, not through the PC's cache):
  ```bash
  dd if=/media/$USER/LITEXBOOT/fw_jump.bin iflag=direct bs=4096 status=none | md5sum
  ```
- The board's BIOS says `cannot open boot.json (FatFs error 4)`: the files are missing from the first
  partition. If they were written from Ubuntu and are gone, it is the "write from the Mac" problem
  above. When remaking the first partition, always use FAT16 (`mkfs.vfat -F 16`); without `-F`, 512 MB
  becomes FAT32.
- Nothing after `Liftoff!` on the board: the files of the first partition are corrupted or old. Every
  version of `fw_jump.bin` is 279048 bytes, so the size tells nothing; compare the md5 with the table
  above.

## Before turning the power off

Cutting the power abruptly makes ext4 replay its journal at the next boot (`EXT4-fs (mmcblk0p2):
recovery complete`). Nothing breaks, but data written just before may be lost. Before turning it off,
run on the board

```sh
poweroff
```

and turn the power off after `reboot: Power down` appears (`reboot` restarts through LiteX's reset). The
`::shutdown:` lines of inittab flush and remount read-only, so `recovery complete` does not appear at
the next boot (checked on the board 2026-09-29).

The `sbi_srst_reset: type=0x0 reason=0x0 failed` at the end of `poweroff` is because this board has no
way to cut its power (OpenSBI's `Platform Shutdown Device: ---`). Everything has been flushed, so just
turn the power off or press RESET. `umount: devtmpfs busy - remounted read-only` is harmless too (`/dev`
lives in memory and is in use, so it cannot be unmounted).

## The device tree is not a separate file

It is **embedded** in `fw_jump.bin` (`FW_FDT_PATH`). So after changing `software/mmrisc_arty.dts`, do
not put a DTB on the SD card: run `scripts/build_opensbi.sh` again and replace `fw_jump.bin`.

## Booting

Serial at 115200 bps. At the `litex>` prompt:

```
sdcardboot
```

Success is LiteX BIOS → OpenSBI → Linux → BusyBox. Where to look when it gets stuck: `docs/BRINGUP.md`.

## Ethernet (since 2026-09-26)

The SoC is built with `--with-ethernet --eth-dhcp` (`scripts/build_soc.sh`). Ethernet changes the
placement of the CSRs and the interrupt numbers, so **always use the bitstream and `fw_jump.bin` as a
pair**. A bitstream with Ethernet with an old `fw_jump.bin` (or the other way round) prints nothing,
because the UART is somewhere else. The last bitstream without Ethernet is kept in
`build/known_good_noeth/`.

| | Without Ethernet | With Ethernet |
|---|---|---|
| CSRs of ethmac / ethphy | ― | 0x1200_1000 / 0x1200_1800 |
| SD card | 0x1200_2000, PLIC 3 | 0x1200_3000, PLIC 4 |
| timer0 | 0x1200_3000 | 0x1200_4000 |
| UART | 0x1200_3800 | 0x1200_4800 |
| Packet buffer | ― | 0x3000_0000 (8 KiB, uncached) |
| Ethernet interrupt | ― | PLIC 3 |

### Getting an IP in Linux

BusyBox's `udhcpc` neither brings the interface up nor sets the address by itself; it leaves that to a
script. And this BusyBox has an empty default script location (`CONFIG_UDHCPC_DEFAULT_SCRIPT=""`), so
**nothing is run unless a script is given with `-s`** (the interface stays DOWN and you get `Network is
down`). That script (`software/rootfs/usr/share/udhcpc/default.script`) is put on the card by
`sd_rootfs.sh` in the writing procedure above. inittab also runs `udhcpc` at boot, so normally there is
nothing to do. To get it again by hand, on the board:

```sh
udhcpc -i eth0 -s /usr/share/udhcpc/default.script
                        # set up when "Setting IP address ..." and "Adding router ..." appear
ifconfig eth0
ping <router IP>        # "... is alive!" (this BusyBox's ping is the simple one, without -c and the like)
```

To get it automatically at boot, add the following after the `--install -s` line of `/etc/inittab`
(`-b`: if none is obtained, keep waiting in the background):

```
::sysinit:/bin/busybox udhcpc -i eth0 -b -s /usr/share/udhcpc/default.script
```

Checked on the board 2026-09-26: `udhcpc` got 192.168.0.11, and `ping` reached the router and a PC on
the LAN.

The MAC address is `10:e2:d5:00:00:00`, the same as the BIOS (`local-mac-address` of the device tree), so
the BIOS and Linux get the same IP by DHCP.

### TFTP netboot of the LiteX BIOS

Loads the kernel and OpenSBI from a TFTP server on the PC instead of the SD card. Kernels and
`fw_jump.bin` can be tried without swapping SD cards. The root file system stays on the SD card as before
(`root=/dev/mmcblk0p2`). The automatic boot order is serial → SD card → network, so netboot is done by
hand from the `litex>` prompt.

**1. TFTP server (on the PC, once)**. It must be on the same network as the board. When it runs in a VM,
make the VM's network bridged (with NAT the board cannot reach it). The detailed procedure for Ubuntu on
Parallels Desktop on a Mac (bridge setting, `tftpd-hpa` configuration, opening UDP 69 in ufw, narrowing
things down with tcpdump) is in `docs/TFTP_SERVER.md`.

```bash
sudo apt install tftpd-hpa          # the published directory is /srv/tftp
sudo cp LitexSystem/software/boot/Image LitexSystem/software/boot/fw_jump.bin \
        LitexSystem/software/boot/boot.json /srv/tftp/   # the same as the first partition of the SD card
ip -4 addr                                # note the server's IP
```

**2. The board**. Power on and press `Q` during `Press Q or ESC to abort boot completely.` to get
`litex>`.

```
litex> eth_dhcp                       <- DHCP worked when "Local IP: 192.168.x.y" appears
litex> ping <server IP>               <- an answer means the route works
litex> eth_remote_ip <server IP>      <- the TFTP server (default 192.168.1.100)
litex> netboot                        <- reads boot.json, fetches Image and fw_jump.bin and boots
```

After `Copying Image to 0x80200000 ...`, success is OpenSBI and Linux appearing just as when booting from
the SD card (checked on the board 2026-09-26).

Moving on to `Booting from boot.bin...` right after `Booting from boot.json...` and ending in `Network
boot failed.` means not even `boot.json` could be fetched. Check that the TFTP server is running, that
the files are in `TFTP_DIRECTORY`, and **that the server's firewall lets UDP port 69 through** (that was
it on the board).

If the download finishes but nothing appears after `Liftoff!`, check what was loaded. Every version of
`fw_jump.bin` is 279048 bytes and cannot be told apart by size, so first see on the server whether
`strings fw_jump.bin | grep serial@` shows `serial@12004800`. If it still does not boot, put on the server
a JSON that loads to addresses the BIOS does not destroy when restarting and returns to the BIOS,

```json
{
    "fw_jump.bin": "0x81000000",
    "Image":       "0x81200000",
    "bootargs":    {"addr": "0x10000000"}
}
```

and compare `netboot check.json` → `Q` → `crc 0x81000000 <size>` and `crc 0x81200000 <size>` with the
CRC32 computed on the PC
(`python3 -c "import zlib,sys;print(hex(zlib.crc32(open(sys.argv[1],'rb').read())))" fw_jump.bin`).

To change the default TFTP server and rebuild the bitstream: `REMOTE_IP=192.168.x.y ./scripts/build_soc.sh`.

## Long stress test (`software/rootfs/root/stress.sh`)

Runs 3 jobs at the same time for hours on Linux, each checking its own data with md5.

| Job | What it does | What it mainly tests |
|---|---|---|
| net | Fetches `Image` (15 MB) from the TFTP server in blocks of 1024 bytes | Receiving large Ethernet frames, interrupts |
| sd | Writes 2 MB of random data to the SD card's ext4, drops the page cache and reads it back | The SD card's DMA (both directions) |
| mem | Writes 64 MB of zeros to `/tmp` (RAM) | Data cache and DRAM |

**Preparation**. Put `stress.sh` in the TFTP server's published directory (the `Image` placed there for
netboot is used as it is), and fetch it on the board:

```sh
udhcpc -i eth0 -s /usr/share/udhcpc/default.script     # not needed if it was obtained at boot
tftp -g -r stress.sh -l /root/stress.sh <server IP>
chmod +x /root/stress.sh
```

**Running it** (120 minutes if the minutes are omitted):

```sh
/root/stress.sh <server IP> 240
```

Every 10 minutes one line `stress: time n OK, m NG, uptime ...` appears. If these stop, the board has
stopped at that point. There is no second terminal, so to see progress without stopping it, look at
`/root/stress.log` afterwards (one line per round). At the end it prints the count for each job and any
kernel warnings (`warning` / `oops` / `error` and the like) that appeared while it ran, and finally `===
PASS ===` or `=== FAILED ===`. Files that failed the check are left in `/tmp/stress.d/net.bad`,
`/root/stress.d/sd.bad.<n>` and `/tmp/stress.d/mem.bad`.

To test without the network, pass `-` instead of the server (`/root/stress.sh - 240`).
