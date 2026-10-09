# LitexSystem — the LiteX / Linux system of mmRISC-2

[日本語](README_J.md)

Everything needed to build a LiteX SoC **whose CPU is mmRISC-2** on the Digilent Arty A7-100T and to
boot Linux on it.

`LitexRocket/` next to it is **for reference only**: LiteX's standard Rocket Chip on the same board,
already booting Linux (not under git; how to build it: "Preparation" below). The job here is to take the software and the way of building the
SD card established there as they are, and **replace only the CPU**.

## Status (2026-10-05)

On the board (50 MHz), LiteX BIOS → OpenSBI → Linux 7.2 boots from the ext4 of the SD card to the
BusyBox shell, and Ethernet works (DHCP, ping, TFTP netboot from the BIOS). The 120-minute stress test
(memory, Ethernet and SD card checked at the same time) passes.

| | |
|---|---|
| Performance | **2.747 CoreMark/MHz** (built with Zba/Zbb; 2.462 for rv64gc), **1.482 DMIPS/MHz** |
| ISA (as Linux sees it) | `rv64imafdc_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_smcntrpmf_sscofpmf_sstc`, 4 debug triggers (Sdtrig) |
| Performance counters | `hpmcounter3` to `6`, 17 events. Usable with Linux's `perf stat` / `perf record` (`software/bench/perf.sh`) |
| Timing | WNS +0.452 ns at 50 MHz (MET) |
| Resources | LUT 45,598 / 63,400 (71.9 %), block RAM 40.5 / 135 tiles |

The problems found on the way and their fixes are in `docs/BRINGUP.md`, timing in `docs/TIMING.md`,
performance in `docs/BENCH.md`, the next themes in `docs/ROADMAP.md`. The JTAG / cJTAG debug port is
brought out on PMOD JA. Hardware breakpoints and watchpoints work with OpenOCD and gdb (checked on a
running Linux kernel; `docs/JTAG.md`; the pinout is the same as `FPGA/ARTY_A7_100T`).

## Differences from the Rocket configuration

At first the memory map matched the Rocket configuration byte for byte, so only the CPU node of the
device tree had to be rewritten. Since then three things have changed:

- **No LiteX L2** (`--l2-size 0`). mmRISC-2 connects its memory bus straight to LiteDRAM. Instead the
  CPU has an L2 of its own (2026-10-06, `RTL/CPU/CPU_L2`, 256 KB). `build_soc.sh --cpu-l2-size 0`
  removes it (for before / after comparisons).
- **A DMA port**. The DMA of the SD card and Ethernet goes to memory through the CPU's data cache
  (`dma_bus`). The DMA coherence Linux assumes is kept by hardware.
- **Ethernet** (`--with-ethernet --eth-dhcp`). ethmac / ethphy came in at the start of the CSR space,
  so the CSRs of the SD card, timer0 and the UART moved back by 0x1000 each, and the interrupts became
  uart 0, timer0 1, ethmac 2, sdcard 3 (+1 in the PLIC).

OpenSBI (with the device tree embedded in `fw_jump.bin`; one patch is applied to a copy) and the root
file system are built in this directory. Linux's `Image` is the source and configuration of the Rocket
configuration, rebuilt with `CONFIG_PERF_EVENTS` / `CONFIG_RISCV_PMU_SBI` added for the performance
counters (`software/boot/README.md`). **Use the bitstream and `fw_jump.bin` as a pair** (if the layout
differs, the UART is somewhere else and nothing is printed; and since the device tree declares the CPU's
extensions, it cannot be paired with an older bitstream without them either).

## Layout

```
LitexSystem/
├── cpu/mmrisc/          LiteX CPU wrapper (Python) and C runtime
│   ├── core.py          bus, memory map, parameters, list of RTL files
│   ├── system.h         cache operations (fence.i)
│   ├── irq.h            PLIC
│   ├── crt0.S           start-up and trap entry (single core)
│   └── boot-helper.S
├── scripts/
│   ├── setup_litex.sh   LiteX workspace at the pinned commits (litex_repos.py; "Preparation")
│   ├── build_soc.sh     generates the SoC (Linux side; does not run Vivado)
│   ├── build_digilent_arty.bat   runs Vivado (Windows side)
│   ├── build_opensbi.sh fw_jump.bin with the device tree (applies opensbi_patches)
│   ├── build_perf.sh    builds perf (static) and puts it in bench/out
│   ├── sd_rootfs.sh     writes the root file system of the SD card
│   ├── timing_paths.tcl / .bat   report of the 300 worst paths (Windows side)
│   └── jtag_check.tcl   JTAG check on the board (OpenOCD)
├── software/
│   ├── mmrisc_arty.dts  device tree
│   ├── boot/            what goes on the first partition of the SD card (Image, fw_jump.bin,
│   │                    boot.json), the kernel configuration, the OpenSBI patches and procedure
│   ├── rootfs/          what is added to the root file system (inittab, udhcpc script,
│                        stress test stress.sh)
│   └── bench/           benchmarks (CoreMark, Dhrystone, micro) and perf.sh; to the board by TFTP
├── docs/
│   ├── BRINGUP.md       bring-up record and procedure
│   ├── TIMING.md        record of timing closure
│   ├── JTAG.md          JTAG / cJTAG debugging (pins, switches, OpenOCD)
│   ├── BENCH.md         performance measurements (simulation and board, where cycles are lost)
│   ├── ROADMAP.md       next design themes
│   └── TFTP_SERVER.md   making Ubuntu on Parallels a TFTP server
└── build/               generated files (not under git)
```

## Preparation

The scripts here use things that are **not in the repository**: the LiteX workspace and the OpenSBI source
under `LitexRocket/` (next to `LitexSystem/`), and the BusyBox tree under `~/mmlitex_build/`. This section
builds them on a new machine. It follows what was done for the Rocket configuration (2026-09-13), with the
versions that are in use now. The commands are run at the top of the repository (`mmRISC-2/`) unless they
`cd` somewhere.

### What is needed for what

| Path | Used by | Needed |
|---|---|---|
| `LitexRocket/.venv/` | `scripts/build_soc.sh` (Python and LiteX) | Yes |
| `LitexRocket/litex_ws/` | `scripts/build_soc.sh` (LiteX, litex-boards, LiteDRAM, LiteEth, LiteSDCard ...) | Yes |
| `LitexRocket/software/opensbi/` | `scripts/build_opensbi.sh` (`fw_jump.bin`) | Yes |
| `~/mmlitex_build/initramfs/` | `scripts/sd_rootfs.sh` (2nd partition of the SD card), `SIM/SIM_BIOS` | Yes, for the SD card |
| `~/mmlitex_build/initrd_bb` | `SIM/SIM_BIOS` (`make linux` and the targets after it) | Only for the Linux simulation |
| `LitexRocket/software/linux/` | `scripts/build_perf.sh`, rebuilding `Image` | Only for `perf` or a new kernel (`Image` itself is in `software/boot/`) |
| `LitexRocket/litex_ws/build/`, `software/boot/`, `docs/` | The Rocket configuration itself | No (reference only) |

### 0. Host

- **Linux side**: Ubuntu 24.04 (here arm64 on Parallels Desktop on an Apple Silicon Mac; x86_64 works the
  same way). Everything except Vivado runs here.
- **Vivado side**: Vivado 2025.1 (on Windows 11 here; Vivado is x86 only). It reads `build/gateware/` through
  a folder shared with the Linux side. `build_soc.sh` makes the paths in the tcl relative for that.
- Packages (Ubuntu):
  ```bash
  sudo apt install git build-essential python3-venv device-tree-compiler \
       flex bison bc libssl-dev libncurses-dev cpio fakeroot curl
  ```

### 1. Cross compilers (`/opt/riscv`)

All scripts put `/opt/riscv/bin` on `PATH`. Two compilers are used: `riscv64-unknown-elf-` (the LiteX BIOS,
benchmarks, test programs) and `riscv64-unknown-linux-gnu-` (OpenSBI, the kernel, BusyBox, perf). Both are
GCC 13.2.0 from [riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain), configured with
`--with-arch=rv64imafdc --with-abi=lp64d --enable-multilib`:

```bash
git clone https://github.com/riscv-collab/riscv-gnu-toolchain
cd riscv-gnu-toolchain
./configure --prefix=/opt/riscv --with-arch=rv64imafdc --with-abi=lp64d --enable-multilib
sudo make            # riscv64-unknown-elf-   (newlib)
sudo make linux      # riscv64-unknown-linux-gnu-   (glibc)
```

A newer GCC also works; the Zba / Zbb builds of the benchmarks need GCC 12 or later.

### 2. LiteX workspace (`LitexRocket/.venv`, `LitexRocket/litex_ws`)

```bash
LitexSystem/scripts/setup_litex.sh
```

It makes the virtual environment `LitexRocket/.venv`, clones the LiteX repositories into
`LitexRocket/litex_ws` **at the commits this project is built with** (`scripts/litex_repos.py`, 41
repositories, about 2.6 GB), installs them into the venv with `litex_setup.py --install`, and adds `meson`
and `ninja` (for the LiteX BIOS). The main ones:

| Repository | Commit (2026-09) |
|---|---|
| litex | `6d8a38cade2092cb1e7db3e5602e81093aead8f9` |
| litex-boards | `bca0201f1f22de6789a30ff809367cf16ab6a0bc` |
| migen | `4c2ae8dfeea37f235b52acb8166f12acaaae4f7c` |
| litedram | `ab27325fa488ada7a0e1cef271e5bd7d94c2bb7e` |
| liteeth | `8c9150ff121cb3148d8ea26ce3b1c5200479848d` |
| litesdcard | `227d61bc2b92ca56cac78a539b98e378468b1ba1` |

`scripts/litex_repos.py` was written by `litex_setup.py --freeze` from the workspace used for the board.
LiteX itself is not changed: `--cpu-type mmrisc` comes from `LitexSystem/cpu` ("Nothing changed on the LiteX
side" below). The CSR map and the interrupt numbers depend on the LiteX version, so if you move to other
commits, check `build/csr.json` against `software/mmrisc_arty.dts`.

Check: `LitexSystem/scripts/build_soc.sh` goes through to `build/gateware/digilent_arty.v` and
`build/software/bios/bios.bin`.

### 3. OpenSBI (`LitexRocket/software/opensbi`)

```bash
mkdir -p LitexRocket/software
git clone https://github.com/riscv-software-src/opensbi LitexRocket/software/opensbi
git -C LitexRocket/software/opensbi checkout 3593a5facc4c6938b90429a6973ba9ee21fc5899
```

`build_opensbi.sh` builds a copy of it with the patches of `software/boot/opensbi_patches/`, so the clone
stays clean. Check: the `fw_jump.bin` it makes has the md5 of the table in `software/boot/README.md` (as long
as the device tree has not changed).

### 4. BusyBox and the root file system (`~/mmlitex_build`)

The same as `scripts/build_software.sh` of
[linux-on-litex-rocket](https://github.com/litex-hub/linux-on-litex-rocket). Build it on the local disk, not
in a shared folder (a shared folder is slow, and on the Mac it does not distinguish the case of file names).

```bash
mkdir -p ~/mmlitex_build && cd ~/mmlitex_build
export PATH=/opt/riscv/bin:$PATH
git clone https://github.com/litex-hub/linux-on-litex-rocket
curl https://busybox.net/downloads/busybox-1.36.1.tar.bz2 | tar xfj -
cd busybox-1.36.1
cp ../linux-on-litex-rocket/conf/busybox-1.36.1-rv64gc.config .config
make CROSS_COMPILE=riscv64-unknown-linux-gnu-
cd ..

mkdir initramfs && cd initramfs
mkdir -p bin sbin lib etc dev home proc sys tmp mnt nfs root usr/bin usr/sbin usr/lib
cp ../busybox-1.36.1/busybox bin/
ln -s bin/busybox ./init
cat > etc/inittab <<'EOT'
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/busybox mount -t tmpfs tmpfs /tmp
::sysinit:/bin/busybox mount -t sysfs sysfs /sys
::sysinit:/bin/busybox --install -s
/dev/console::sysinit:-/bin/ash
EOT
fakeroot sh -c 'find . | cpio -H newc -o' | gzip > ../initrd_bb
```

`initramfs/` is the base of the SD card's root; `sd_rootfs.sh` lays `software/rootfs/` of this repository
(its own `inittab`, `sbin/init`, the udhcpc script, `stress.sh`) over it. `initrd_bb` is the same tree as an
initramfs, used only by `SIM/SIM_BIOS`.

### 5. Linux source (optional, `LitexRocket/software/linux`)

`software/boot/Image` is in the repository, so the kernel source is needed only for `build_perf.sh` or to
change the kernel. Clone it on a file system that distinguishes case (see `software/boot/README.md` for what
happens otherwise), and link it to the place the scripts look (`build_perf.sh` also takes the path as its
argument):

```bash
cd ~/mmlitex_build
git clone https://github.com/litex-hub/linux -b litex-rebase
git -C linux checkout 4929f78c004ecab9b68bb41018a3d11749dcea62
cd -
ln -s ~/mmlitex_build/linux LitexRocket/software/linux

# to rebuild Image:
cp LitexSystem/software/boot/linux.config ~/mmlitex_build/linux/.config
make -C ~/mmlitex_build/linux ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- Image
```

The source of exactly this commit, with `linux.config`, is also on the GitHub Release
[`linux-src-4929f78c004e`](https://github.com/munetomo-maruyama/mmRISC-2/releases/tag/linux-src-4929f78c004e).

### 6. Optional: the Rocket configuration itself

To build the reference SoC with LiteX's Rocket Chip on the same board (not needed for mmRISC-2):

```bash
cd LitexRocket/litex_ws
source ../.venv/bin/activate
export PATH=/opt/riscv/bin:$PATH
python3 litex-boards/litex_boards/targets/digilent_arty.py --build --variant a7-100 \
    --cpu-type rocket --cpu-variant linux --cpu-num-cores 1 --cpu-mem-width 1 \
    --sys-clk-freq 50e6 --with-sdcard
```

`pythondata-cpu-rocket` is among the repositories `setup_litex.sh` clones. Vivado is run on
`litex_ws/build/digilent_arty/gateware/` the same way as for mmRISC-2.

## Procedure

```bash
# 1. Generate the SoC (Linux VM)
./scripts/build_soc.sh

# 2. Bitstream (Vivado on the Windows VM)
#    run build_digilent_arty.bat in build/gateware/

# 3. Build OpenSBI with the device tree and put it on the first partition of the SD card
#    (Image, fw_jump.bin, boot.json; write from the Mac: software/boot/README.md)
./scripts/build_opensbi.sh          # -> software/boot/fw_jump.bin

# 4. The second partition of the SD card (ext4)
sudo ./scripts/sd_rootfs.sh /media/<user>/rootfs
```

How to make the SD card, Ethernet, TFTP netboot and the stress test: `software/boot/README.md`.

## Nothing changed on the LiteX side

LiteX picks up directories holding a `core.py` both from its own tree and from **the current
directory** (`collect_cpus` in `litex/soc/cores/cpu/__init__.py`). `build_soc.sh` starts from
`LitexSystem/cpu`, so `--cpu-type mmrisc` works as it is. The LiteX checkout is not changed at all.
