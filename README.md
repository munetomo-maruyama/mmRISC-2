# mmRISC-2

[日本語](README_J.md)

A home-made 64-bit RISC-V CPU written in SystemVerilog that runs Linux on a Digilent Arty A7-100T. The
peripherals come from LiteX. The CPU has:

- RV64GC (IMAFDC) + Zba / Zbb / Zicond
- M / S / U modes, PMP
- Sv39 MMU (ITLB / DTLB, hardware page table walker)
- An 8-stage in-order pipeline
- Branch prediction (256-entry BTB, gshare, return address stack)
- FPU (single and double precision). Add / subtract, multiply, multiply-add and conversions in a pipeline that takes one operation every cycle
- L1 caches (I$ / D$ 16 KB each; the D$ is non-blocking and write-back)
- **L2 cache (256 KB)**
- The SoC's DMA also goes through the D$, and cache coherence is kept by hardware
- Built-in CLINT / PLIC, Sstc (S-mode timer)
- JTAG / cJTAG on-chip debug (Debug Spec 1.0, 4 hardware triggers)
- Performance counters (Zihpm, Sscofpmf; usable with Linux's `perf`)

## Status (2026-10-09)

On the Arty A7-100T board (50 MHz), LiteX BIOS → OpenSBI → **Linux 7.2** boots from the ext4 of the SD
card to the BusyBox shell, and Ethernet (DHCP, TFTP) works. The 120-minute stress test (memory, Ethernet
and SD card checked at the same time) passes with the L2 cache as well (2026-10-09).

| | |
|---|---|
| Performance (board, under Linux) | **2.786 CoreMark/MHz** (built with Zba/Zbb; 2.498 for rv64gc), **1.496 DMIPS/MHz**. +76 % / +82 % from the 1.584 / 0.823 of the first home-made version. Both are `-O2` values; built with the options that make it fastest, **3.025 CoreMark/MHz** and 1.542 DMIPS/MHz (section 17 of `LitexSystem/docs/BENCH.md`). Floating point: FIR 65.6 MFLOPS, matrix multiply 41.2 MFLOPS (assembler, 50 MHz). The L2 cache makes kernel-heavy loads (TFTP, SD reads, `ls -lR`) 1.5 to 1.7 times faster |
| ISA | RV64IMAFDC, Zicsr, Zifencei, Zicntr, Zihpm, **Zba, Zbb, Zicond**, Zihintpause, Zihintntl, M / S / U, Sv39, PMP 8 entries |
| Privileged extensions | **Sstc** (S-mode timer), **Sscofpmf** (overflow interrupts of the performance counters), **Smcntrpmf**, **Sdtrig** (4 debug triggers), privileged spec 1.12 |
| Performance counters | `hpmcounter3` to `6`, 19 events (cache, L2 and TLB misses, branch mispredictions, reasons for stalls). Usable with Linux's `perf stat` / `perf record` |
| Debug | JTAG / cJTAG (Debug Spec 1.0). Halt / step / registers / memory, software and hardware breakpoints and watchpoints with OpenOCD / gdb (they can be put on a running Linux kernel too) |
| FPGA | WNS +0.159 ns at 50 MHz, LUT 46,957 / 63,400 (74.1 %), slices 91.4 %, block RAM 108.5 / 135 tiles (L2 included) |

**The core**

- 8-stage pipeline (IF1 / IF2 / FQ / ID / EX / MR / MA / WB), issuing one instruction at a time in order
- Forwarding from EX, MR and MA
- Branch prediction: 256-entry BTB, gshare (8192-entry PHT), return address stack
- Branches decided by the value of a load are resolved in MR
- Loads and stores go to the D$ from EX, and the answer of a hit is visible 2 cycles later (in the cycle the instruction reaches MA)
- So MA does not wait, and loads and stores that hit go at **one every cycle** (throughput 1)
- The only wait is when the next instruction uses the result of a load (load-use). A chain of dependent loads takes about 3 cycles each
- Multiply in 1 to 2 cycles, divide with early termination
- L1 caches: I$ / D$ 16 KiB each (4 ways, 64 B lines); the D$ is non-blocking and write-back
- The SoC's DMA goes through the D$ too, so coherence is kept by hardware
- FPU (F / D): a 9-stage pipeline around one multiply-add datapath, one operation every cycle when there is no dependency. Divide and square root iterate
- L2 cache: 256 KB (4 ways, 64 B lines, write-back) between the L1 and LiteDRAM
- An L1 miss that hits in the L2 takes 14 cycles instead of 31, and kernel loads hit 85 to 95 % of the time (section 15 of [`BENCH.md`](LitexSystem/docs/BENCH.md))

The story of the bring-up is in [`LitexSystem/docs/BRINGUP.md`](LitexSystem/docs/BRINGUP.md), the
performance work and the breakdown on the board in
[`LitexSystem/docs/BENCH.md`](LitexSystem/docs/BENCH.md), the next themes in
[`LitexSystem/docs/ROADMAP.md`](LitexSystem/docs/ROADMAP.md).

## Documents

Every document has a Japanese version next to it (`XXXX.md` is English, `XXXX_J.md` in the same place is Japanese).

| Document | Contents |
|---|---|
| [`RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md) | CPU core (instruction set, pipeline, MMU, CSRs, debug, decisions 1 to 69) |
| [`RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md`](RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md) | L1 caches (parameters, interfaces, behavior, verification results) |
| [`RTL/CPU/CPU_L2/CPU_L2_SPEC.md`](RTL/CPU/CPU_L2/CPU_L2_SPEC.md) | L2 cache (design, behavior, resources, verification, effect on the board) |
| [`RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md`](RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md) | Debug logic (JTAG/cJTAG DTM, DM, authentication) |
| [`RTL/CPU/CPU_FPU/README.md`](RTL/CPU/CPU_FPU/README.md) | FPU (how it works, performance, how to write fast code) |
| [`LitexSystem/README.md`](LitexSystem/README.md) | Everything to put it in a LiteX SoC and run Linux |
| [`LitexSystem/docs/BRINGUP.md`](LitexSystem/docs/BRINGUP.md) | Record of the bring-up on the board (where it stopped, why, the fixes) and procedures |
| [`LitexSystem/docs/BENCH.md`](LitexSystem/docs/BENCH.md) | Performance measurements (simulation and board, where cycles go as seen by the PMU, version by version) |
| [`LitexSystem/docs/TIMING.md`](LitexSystem/docs/TIMING.md) | Record of timing closure at 50 MHz |
| [`LitexSystem/docs/JTAG.md`](LitexSystem/docs/JTAG.md) | JTAG / cJTAG debugging (pins, switches, OpenOCD) |
| [`LitexSystem/docs/ROADMAP.md`](LitexSystem/docs/ROADMAP.md) | Next design themes |
| [`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md) | Making the SD card, Ethernet, TFTP netboot, stress test, distributed binaries |
| [`LitexSystem/software/bench/README.md`](LitexSystem/software/bench/README.md) | Benchmarks on the board and `perf` |
| [`SIM/SIM_CORE/README.md`](SIM/SIM_CORE/README.md) | Verification environment of the core (32 home-made tests, riscv-tests, bug injection) |

## Directory layout

```
RTL/
├── TOP/            FPGA-only top (CPU_TOP + test RAM; for checking the debug logic on the board)
├── CPU/
│   ├── CPU_TOP/        top of the CPU block: core, caches, MMIO, debug, DMA port
│   ├── CPU_CORE/       CPU core  → CPU_CORE_SPEC.md
│   │   ├── CPU_CORE/       top of the core (8 stages, forwarding, traps, trigger matching, performance events)
│   │   ├── CORE_IFU/       instruction fetch (PC, outstanding request FIFO, fetch queue, branch history)
│   │   ├── CORE_BTB/       branch prediction (BTB, gshare, return address stack)
│   │   ├── CORE_DEC/       instruction decoder
│   │   ├── CORE_DECOMP/    expands compressed (C) instructions to 32 bits
│   │   ├── CORE_CSR/       CSRs and trap state (M / S / U, debug, triggers, performance counters)
│   │   ├── CORE_MDU/       multiply / divide (M)
│   │   ├── CORE_FRF/       floating point register file (32×64, 3R2W)
│   │   ├── CORE_RF/        integer register file (32×64bit, 2R2W)
│   │   ├── CORE_EXU/       ALU (including Zba / Zbb / Zicond), branch conditions, address generation
│   │   └── CORE_LSU/       load / store unit (early issue from EX, data cache port)
│   ├── CPU_MMU/        Sv39 MMU and PMP
│   │   ├── CORE_MMU/       ITLB / DTLB / walker / PMP together
│   │   ├── MMU_TLB/        TLB
│   │   ├── MMU_PTW/        page table walker
│   │   └── MMU_PMP/        PMP (8 entries)
│   ├── CPU_FPU/        floating point unit (F/D) → README.md (how it works, performance, how to write for it)
│   │   ├── FPU_PIPE/       9-stage pipeline of all operations (the one the core uses; divide / square root iterate)
│   │   ├── CORE_FPU/       all operations one at a time (the earlier version; the reference for unit tests and synthesis)
│   │   └── FPU_ROUND/      normalization, rounding, packing
│   ├── CPU_CACHE/      L1 instruction / data caches  → CPU_CACHE_SPEC.md
│   │   ├── CPU_CACHE/      I$ + D$ + BUS_ARB
│   │   ├── ICACHE/         instruction cache
│   │   ├── DCACHE/         data cache (MSHR, write-back, AMO/LR-SC, cancel)
│   │   ├── CACHE_PORT_ARB/ arbitration of the D$ port (CPU and second port)
│   │   ├── CACHE_TAG_ARRAY/    tag + valid + dirty
│   │   └── CACHE_DATA_ARRAY/   data array
│   ├── CPU_L2/         L2 cache (256 KB, behind the L1)  → CPU_L2_SPEC.md
│   ├── CPU_DMA/        DMA port (the SoC's DMA to memory through the data cache)
│   ├── CPU_MMIO/       routing to the built-in CLINT / PLIC
│   ├── CPU_CLINT/      CLINT (msip / mtime / mtimecmp)
│   ├── CPU_PLIC/       PLIC (2 contexts, M and S)
│   ├── CPU_DBG/        debug logic  → CPU_DBG_SPEC.md
│   │   ├── CPU_DBG/        top of the debug logic
│   │   ├── DBG_DTM/        JTAG DTM (Debug Spec 1.0)
│   │   ├── DBG_CJTAG/      cJTAG (OScan1) adapter
│   │   ├── DBG_CDC/        clock domain crossing DTM ↔ DM
│   │   ├── DBG_DM/         debug module (abstract commands, SBA, authentication)
│   │   ├── DBG_BUSMST/     bus master for debug (peripheral bus)
│   │   ├── DBG_CACHE/      debug accesses into the data cache
│   │   └── DBG_HART_STUB/  stand-in hart (used only in the BFM configuration; normally the core is the hart)
│   └── CPU_BFM/        BFM standing in for the CPU core (simulation)
└── BUS/
    ├── BUS_ARB/            AXI4 master arbitration
    ├── AXI4_ADDR_NARROW/   AXI4 address width conversion
    ├── AXIL_ADDR_NARROW/   AXI4-Lite address width conversion
    ├── AXI4_RAM/           RAM for simulation / FPGA (memory bus)
    └── AXIL_RAM/           RAM for simulation / FPGA (peripheral bus)

SIM/
├── SIM_CORE/       CPU core (home-made tests, riscv-tests, back pressure, bug injection)
├── SIM_MMU/        PMP alone (reference model, bug injection)
├── SIM_FPU/        FPU (against Berkeley SoftFloat)
├── SIM_CACHE/      L1 caches (reference model, CPU and DMA random at the same time, parameter sweep, bug injection)
├── SIM_L2/         L2 cache (reference model, concurrent random, stalled write-out, parameter sweep, bug injection)
├── SIM_CPU/        bus verification of CPU_TOP
├── SIM_SYS/        core + real caches + AXI + DMA port (bug injection, performance breakdown)
├── SIM_BIOS/       LiteX BIOS and Linux (OpenSBI → Linux → BusyBox, SD card model, perf)
├── SIM_DBG/        debug logic (JTAG / cJTAG)
└── SIM_OCD/        co-simulation with OpenOCD (remote_bitbang)

LitexSystem/        mmRISC-2 in a LiteX SoC running Linux on the Arty  → LitexSystem/README.md
FPGA/ARTY_A7_100T/  stand-alone build without LiteX (for checking the debug logic), constraints, OpenOCD configuration
LitexRocket/        LiteX with the Rocket configuration (workspace, kernel source, BusyBox; not in the repository)
```

## Simulation

`make` (Verilator) in each directory. The results are checked against home-made reference models and
official tests, down to confirming that the tests find deliberately broken RTL (bug injection).

| Command | Contents | Result |
|---|---|---|
| `cd SIM/SIM_CORE && make` | 32 home-made tests of the CPU core (instructions, traps, MMU, PMP, debug, branch prediction, triggers, performance counters and more) | All PASS |
| `cd SIM/SIM_CORE && make stress` | The same tests with back pressure on both cache ports | All PASS |
| `cd SIM/SIM_CORE && make riscv-tests` | The official riscv-tests (rv64ui / um / ua / uc / uf / ud / uzba / uzbb / uzicond / mi / si) | 167 PASS, 4 known failures (tests that need unimplemented features) |
| `cd SIM/SIM_CORE && make riscv-tests-v` | The same tests in the virtual memory (Sv39) environment | 143 PASS, 4 known failures |
| `cd SIM/SIM_CORE && make mdu / clint / plic` | Multiply / divide (reference model, 200,000 operations), CLINT (4 harts), PLIC | PASS |
| `cd SIM/SIM_CORE && ./bug_inject.sh` | 317 bug injections (with and without back pressure) | All detected |
| `cd SIM/SIM_SYS && make` | Core + real L1 / L2 caches + AXI + DMA port (25 home-made tests, 4 programs for DMA, PMU and others). `PARAMS=-GL2_SIZE=0` for no L2 | All PASS (with / without L2) |
| `cd SIM/SIM_SYS && make riscv-tests` | riscv-tests through the real caches | 133 PASS, 4 known failures |
| `cd SIM/SIM_SYS && ./bug_inject.sh` | 17 bug injections (including the cycle bounds of the floating point kernels, `bench/fploop`) | All detected |
| `cd SIM/SIM_CACHE && make` | All tests of the L1 caches (CPU and DMA port random on the same lines at the same time, cancel included) | PASS 64,943 checks |
| `cd SIM/SIM_CACHE && ./bug_inject.sh` | 40 bug injections | All detected |
| `cd SIM/SIM_L2 && make` / `./sweep.sh` / `./bug_inject.sh` | L2 cache (256 KB, 4 ways) / 11 configurations of capacity, ways and replacement / 31 bug injections | PASS about 1.5 million checks / all PASS / all detected |
| `cd SIM/SIM_MMU && make` / `./bug_inject.sh` | PMP against a reference model / 21 bug injections | PASS 200,000 checks / all detected |
| `cd SIM/SIM_FPU && make` / `./bug_inject.sh` | FPU against Berkeley SoftFloat / 34 bug injections | PASS about 580,000 checks / all detected |
| `cd SIM/SIM_FPU && make pipe` / `./bug_inject_pipe.sh` | The pipelined FPU (one operation every cycle) against SoftFloat / 28 bug injections | PASS about 700,000 checks / all detected |
| `cd SIM/SIM_DBG && make` / `./bug_inject.sh` | Debug logic / 15 bug injections | PASS 3,026 checks / all detected |
| `cd SIM/SIM_CPU && make` | Buses and L1 cache paths of CPU_TOP | PASS 46,718 checks |
| `cd SIM/SIM_BIOS && make check` | Runs the LiteX BIOS as it is (interrupts included) | PASS |
| `cd SIM/SIM_BIOS && make linux-sd` | Boots Linux from the SD card model (the same fw_jump.bin and Image as the board) | To the BusyBox prompt |
| `cd SIM/SIM_BIOS && make linux-perf` / `make pmu-sbi` | `perf` under Linux / OpenSBI's PMU calls in the same sequence as Linux | 6 counters at once, sampling on overflow interrupts / PASS |
| `cd SIM/SIM_OCD && make` | Co-simulation with OpenOCD (breakpoints, watchpoints, `reset halt` with the L2 included) | PASS |

Tools needed: Verilator 5.x, Icarus Verilog 12, GTKWave, riscv-openocd, the riscv64-unknown-elf /
riscv64-unknown-linux-gnu toolchains (`/opt/riscv`, GCC 13.2), Berkeley SoftFloat (SIM_FPU).

`make riscv-tests` uses the official riscv-tests. They are not in the repository; get them separately
(the default location is `~/RISCV/riscv-tests`, changed with `RVTESTS`).

```
git clone --recursive https://github.com/riscv-software-src/riscv-tests ~/RISCV/riscv-tests
```

`SIM/SIM_FPU` uses Berkeley SoftFloat as the reference model. How to prepare it:
[`SIM/SIM_FPU/README.md`](SIM/SIM_FPU/README.md).

## Running Linux on the Arty (LiteX)

```
LitexSystem/scripts/build_soc.sh        # generates the SoC and the BIOS (Linux side)
# build the bitstream of LitexSystem/build/gateware with Vivado (Windows side)
LitexSystem/scripts/build_opensbi.sh    # fw_jump.bin with the device tree (applies the patches)
sudo LitexSystem/scripts/sd_rootfs.sh /media/<user>/rootfs   # the SD card's root
```

The first partition of the SD card (FAT16) gets `Image`, `fw_jump.bin` and `boot.json` from
`LitexSystem/software/boot/` (they are in the repository; the bitstream and `fw_jump.bin` are used as a
pair). Details in [`LitexSystem/README.md`](LitexSystem/README.md) and
[`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md). Benchmarks on the board and
`perf`: [`LitexSystem/software/bench/README.md`](LitexSystem/software/bench/README.md).

## FPGA (without LiteX, for checking the debug logic)

```
cd FPGA/ARTY_A7_100T
vivado -mode batch -source build.tcl
```

The bitstream and reports go to `output/`. The OpenOCD configuration is in `openocd/`. Details in
[`FPGA/ARTY_A7_100T/README.md`](FPGA/ARTY_A7_100T/README.md).

## Progress

| Phase | Status |
|---|---|
| JTAG / cJTAG debug logic | Done. Connected to the core: halt / step / registers / memory / breakpoints on the board |
| L1 instruction / data caches | Done (sweeps, bug injection, up to concurrent random tests of CPU and DMA). With a DMA port |
| CPU core | RV64GC + Zba / Zbb / Zicond, M / S / U, 8-stage pipeline, branch prediction (gshare) |
| MMU (Sv39) and PMP | Done |
| Linux on the LiteX SoC | On the board from the SD card's ext4 to BusyBox. Ethernet, TFTP netboot. 120-minute stress test PASS |
| Performance | 2.786 CoreMark/MHz, 1.496 DMIPS/MHz (board, under Linux, `-O2`; 3.025 / 1.542 with the most optimization). The breakdown on the board can be measured with the performance counters and `perf` |
| L2 cache | Done (256 KB, [`CPU_L2_SPEC.md`](RTL/CPU/CPU_L2/CPU_L2_SPEC.md)). Kernel loads 1.2 to 1.7 times faster on the board |
| Next themes | A second-level TLB (user-mode loads), timing work before pipelining the FPU ([`ROADMAP.md`](LitexSystem/docs/ROADMAP.md)) |

## License

The files of this repository made here (RTL, testbenches, scripts, documents) are distributed under the
[Apache License 2.0](LICENSE). Using them without publishing source, modifying, redistributing and
building them into products are all free; the conditions are to include copies of LICENSE and
[NOTICE](NOTICE) and to state in modified files that they were modified.

The following files of others follow their own licenses (details in [NOTICE](NOTICE) and
[`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md)):

| File | Contents | License |
|---|---|---|
| `LitexSystem/software/boot/Image`, `linux.config` | The Linux kernel (litex-hub/linux, unmodified) and its configuration. The full source is on the Release [`linux-src-4929f78c004e`](https://github.com/munetomo-maruyama/mmRISC-2/releases/tag/linux-src-4929f78c004e) | GPL-2.0 |
| `LitexSystem/software/boot/fw_jump.bin`, `opensbi_patches/` | OpenSBI and its patches | BSD-2-Clause |
| `LitexSystem/software/rootfs/usr/share/udhcpc/default.script` | BusyBox's example script (unmodified) | GPL-2.0 |

The sources of LiteX, OpenSBI and Linux themselves are not in the repository; they are brought in from
outside when building.

## References

The specifications and documents the design relies on. The versions are those referred to (see the
publishers for the latest version of each).

| Document | Version | Published at |
|---|---|---|
| The RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture | 20260120 | [riscv/riscv-isa-manual](https://github.com/riscv/riscv-isa-manual/releases) |
| The RISC-V Instruction Set Manual, Volume II: Privileged Architecture | 20260120 | [riscv/riscv-isa-manual](https://github.com/riscv/riscv-isa-manual/releases) |
| The RISC-V Debug Specification | 1.0 (revised 2025-02-21, Ratified) | [riscv/riscv-debug-spec](https://github.com/riscv/riscv-debug-spec) |
| RISC-V Platform-Level Interrupt Controller Specification | 1.0.0 (2023-03) | [riscv/riscv-plic-spec](https://github.com/riscv/riscv-plic-spec) |
| The RISC-V Advanced Interrupt Architecture | 1.0 (revised 20250312) | [riscv/riscv-aia](https://github.com/riscv/riscv-aia) |
| RISC-V IOMMU Architecture Specification | 1.0.1 (2026-02-22) | [riscv-non-isa/riscv-iommu](https://github.com/riscv-non-isa/riscv-iommu) |
| RISC-V Profiles | 1.0 (2023-04-02) | [riscv/riscv-profiles](https://github.com/riscv/riscv-profiles) |
| RVA23 Profiles / RVB23 Profiles | 1.0 (2024-10-17) | [riscv/riscv-profiles](https://github.com/riscv/riscv-profiles) |
| Arty A7 Reference Manual, Arty A7 schematic | | [Digilent Reference](https://digilent.com/reference/programmable-logic/arty-a7/start) |

