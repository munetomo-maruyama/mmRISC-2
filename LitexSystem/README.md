# LitexSystem — the LiteX / Linux system of mmRISC-2

[日本語](README_J.md)

Everything needed to build a LiteX SoC **whose CPU is mmRISC-2** on the Digilent Arty A7-100T and to
boot Linux on it.

`LitexRocket/` next to it is **for reference only**: LiteX's standard Rocket Chip on the same board,
already booting Linux (not under git). The job here is to take the software and the way of building the
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
