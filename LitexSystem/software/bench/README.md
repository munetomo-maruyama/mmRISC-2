# Benchmarks (on the board, under Linux)

[日本語](README_J.md)

CoreMark, Dhrystone and small measurements (`micro`) are built as statically linked Linux user
programs and handed to the board by TFTP (the SD card is not rewritten). Running the same binaries on
another CPU (the Rocket configuration) gives a comparison where only the CPU differs. Results and
analysis: `../../docs/BENCH.md`.

| File | Contents |
|---|---|
| `Makefile` | `make` builds `out/coremark`, `out/dhrystone`, `out/micro`, the Zba / Zbb builds `out/coremark_zb` and `out/dhrystone_zb`, and the builds with the most optimization `out/coremark_max`, `out/dhrystone_max`, `out/coremark_zb_max`, `out/dhrystone_zb_max`, `out/dhrystone_lto`, `out/dhrystone_zb_lto` ("Most optimization" below). `make tftp` copies them to the TFTP server (sudo) |
| `bench.sh` | Run on the board. Fetches the 3 programs by TFTP into `/tmp`, runs them one after the other and prints the values per MHz. Also runs `*_zb` (when the core has Zba / Zbb, `/proc/cpuinfo`), `*_max`, `*_zb_max` and `dhrystone_*lto` if the server has them |
| `micro.c` | Bandwidth (fits in the D$ / does not), latency of dependent loads, misaligned loads, double precision multiply-add (in C and in the assembler of `fpkern.S`). `micro 50 fp` runs only the floating point part |
| `fpkern.S` / `fpkern.c` / `fpkern.h` | Assembler kernels for the pipelined FPU (`CPU_CORE_SPEC.md` 10.11): matrix multiply (4×4 blocks, as it is and cut to fit the D$ (`fpkern.c`, section 16 of `../../docs/BENCH.md`)), 8-tap FIR, dot product. `fpkern.h` has C versions of the same sums (to check the answers). In simulation `SIM/SIM_SYS/bench/fploop.c` runs the same kernels |
| `dhry_shim.c` | What the Dhrystone of riscv-tests expects from its bare environment (timer, printing), under Linux |
| `workload.sh` | Run on the board. Counts loads other than CoreMark (gunzip, md5sum, awk, ls, reading ext4 and the SD card, fork + exec, TFTP) with the PMU, one row per load ("workload.sh" below) |
| `perf.sh` | Run on the board. Fetches `perf` and CoreMark by TFTP and counts where CoreMark's cycles go with the performance counters (`CPU_CORE_SPEC.md` decision 69) ("perf" below) |

The compiler is `/opt/riscv/bin/riscv64-unknown-linux-gnu-gcc` (**GCC 13.2.0**, glibc 2.40), the options
**`-march=rv64imafdc -mabi=lp64d -O2 -static`** (`-march=rv64imafdc_zba_zbb` for `*_zb`). `-mtune` is the
toolchain's default (`rocket`). To keep comparisons on equal terms, the basic values are measured
without `-O3` and the like (details in "Build conditions" of `../../docs/BENCH.md`). Separately, builds
with the options that make this core fastest are measured next to them (next section).

### Most optimization (`*_max`, `dhrystone_lto`)

CoreMark and Dhrystone are also built with options aimed at speed alone. Which options are fastest
differed between the two benchmarks, so they were chosen separately (by comparing cycles in simulation
with `SIM/SIM_SYS/bench/optsweep.sh`; section 17 of `../../docs/BENCH.md`):

| | Options (variable in the `Makefile`) |
|---|---|
| CoreMark (`OPT_MAX_CM`) | `-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4` |
| Dhrystone (`OPT_MAX_DHRY`) | The same + `-mtune=sifive-7-series` |
| Dhrystone, outside the rules (`OPT_LTO_DHRY`) | `-O2 -flto` |

- CoreMark prints its options with the result (`Compiler flags`). CoreMark's rules allow any options as
  long as they are reported.
- `dhrystone_max` follows Dhrystone's rules (the head of `dhrystone.h`: separate compilation, no
  procedure merging, other optimizations allowed if stated), so it does not use `-flto`. `-flto`
  expands procedures across the two files and was the fastest in simulation (+17 %), so it is built
  separately as `dhrystone_lto` / `dhrystone_zb_lto` and marked "off-rule" in the summary.

## Procedure

```bash
cd LitexSystem/software/bench
make
make tftp              # to /srv/tftp (sudo)
```

On the board (shell, with the network up):

```sh
cd /tmp && tftp -g -r bench.sh 192.168.0.12 && sh bench.sh 192.168.0.12
```

CoreMark takes 10 seconds or more, Dhrystone a few seconds, `micro` about a minute; all four builds
take about 3 minutes in total. A summary at the end:

```
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok, Zba/Zbb)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (Zba/Zbb)
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok, max opt)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (max opt)
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok, Zba/Zbb, max opt)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (Zba/Zbb, max opt)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (LTO, off-rule)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (Zba/Zbb, LTO, off-rule)
```

The log is `/tmp/bench.log`. Measure with nothing else running (`stress.sh` and the like). Time is
measured with `clock_gettime` (mtime, 500 kHz) and converted to cycles at 50 MHz.

## perf (performance counters)

The core's performance counters (`hpmcounter3` to `6`, 17 events, `CPU_CORE_SPEC.md` decision 69) are
read with Linux's `perf`. What is needed:

- A bitstream with the PMU, and an `fw_jump.bin` built with a device tree that has the `pmu` node
- A kernel with `CONFIG_PERF_EVENTS` / `CONFIG_RISCV_PMU_SBI` (`../boot/Image`, configuration in
  `../boot/linux.config`)
- `perf` itself: `../../scripts/build_perf.sh` builds it statically from `tools/perf` of the kernel
  source and puts it in `out/perf` (`make tftp` sends that to the TFTP server too)

```bash
../../scripts/build_perf.sh
make tftp
```

On the board:

```sh
cd /tmp && tftp -g -r perf.sh 192.168.0.12 && sh perf.sh 192.168.0.12
```

Runs CoreMark 4 times under `perf stat` (4 counters, so 4 events a run) and once under `perf record`
(10 seconds or more each). At the end it prints a summary of counts per 1000 instructions and shares of
the cycles. The log is `/tmp/perf.log`.

Events as `perf` sees them:

| Name | What it counts |
|---|---|
| `cycles` / `instructions` | The fixed counters (`cycle` / `instret`) |
| `branches` / `branch-misses` | Conditional branches / mispredicted branches and jumps |
| `cache-misses`, `L1-dcache-load-misses` | D$ misses (line fills; store misses included) |
| `L1-dcache-loads` / `L1-dcache-stores` | Retired loads / stores |
| `L1-icache-load-misses` | I$ misses |
| `dTLB-load-misses` / `iTLB-load-misses` | Page table walks |
| `stalled-cycles-frontend` / `stalled-cycles-backend` | Cycles nothing could be issued (front end empty / EX and later stages blocked) |
| `r1` to `r11` | The core's event numbers themselves (hex). `r1` cycles, `r2` instructions, `r3` loads, `r4` stores, `r5` conditional branches, `r6` mispredictions, `r7` I$ misses, `r8` D$ misses, `r9` ITLB misses, `ra` DTLB misses, `rb` D$ wait, `rc` front end empty, `rd` load-use, `re` MDU / FPU wait, `rf` exceptions, `r10` interrupts, `r11` back end blocked |

`perf record` samples on the overflow interrupt of Sscofpmf. The fixed cycle counter cannot raise an
overflow interrupt, so use `-e r1` (cycles counted in an `hpmcounter`). This `perf` is built without
libelf, so no function names are shown (`--sort dso` tells which binary).

## workload.sh (loads other than CoreMark, 2026-10-06)

CoreMark fits in the caches (section 13 of `../../docs/BENCH.md`), so ordinary Linux work is counted
with the same counters (`ROADMAP.md` D1). `perf`, the kernel `Image` used as input and its first 2 MB
gzipped on the host (`out/image2m.gz`; the BusyBox on the SD card has no gzip, sha256sum or find) are
fetched by TFTP into `/tmp` (RAM), and each of the 8 loads below runs 5 times under `perf stat`. Each is
run once first to check that it succeeds; one that fails shows as FAILED in the table.

| Load | What it does | What it shows |
|---|---|---|
| `gunzip` | Decompresses 2 MB | Streaming processing, user mode |
| `md5sum` | `md5sum` of 4 MB | Streaming reads and hashing |
| `awk` | An awk loop over a table of 5000 entries | An interpreter (large code, hash tables) |
| `ls` | `ls -lR` of the root | Kernel, VFS, lstat |
| `ext4read` | `cat` of an 8 MB file written to the SD card (after dropping the page cache) | ext4, SD card |
| `sdread` | `dd` of 16 MB of the root partition (same) | SD DMA (through the D$) |
| `forkexec` | fork + exec of `busybox uname` 100 times | Process creation, page faults, TLB |
| `tftp` | TFTP of `perf` (3 MB) | Ethernet, IP stack |

Runs 1 to 4 count the 16 events four at a time, run 5 counts L2 reads and misses (`r12` / `r13`, added
2026-10-06; 0 with a bitstream without the L2), run 6 splits cycles and instructions into user and
kernel (each event is divided by the cycles and instructions of the same run). About 12 minutes. The
log is `/tmp/workload.log`, the raw counts `/tmp/wl/*.csv`.

```bash
make tftp
```

```sh
cd /tmp && tftp -g -r workload.sh 192.168.0.12 && sh workload.sh 192.168.0.12
```

Columns of the final table: `Mcyc` (millions of cycles), `CPI`, I$ / D$ misses (line fills), ITLB /
DTLB misses (page table walks) and exceptions per 1000 instructions, the shares of the cycles spent
waiting for the D$ / with the front end empty / with the back end blocked / on load-use, the
misprediction rate of conditional branches, the kernel's share, `L2` (L2 reads = L1 fills per 1000
instructions) and `L2m%` (L2 miss rate). The before / after comparison of the L2 is in section 15 of
`../../docs/BENCH.md`. The same numbers for CoreMark are listed last.
