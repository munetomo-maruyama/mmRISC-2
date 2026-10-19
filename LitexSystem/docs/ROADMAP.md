# Design themes (final, as of 2026-10-19: Rev.02)

[日本語](ROADMAP_J.md)

**mmRISC-2 closes with Rev.02.** The criterion set when the gains began to level off (2026-10-17): drop any theme
whose estimated upper bound is under a few percent, and close when what the remaining themes give is 1 to 2 %.
After E3 (the TLBs, up to −20 % on the user-mode loads) the two themes left with a measured target, W1 and W2,
were checked on the board and W1 was also built and simulated; neither saves anything worth its risk (section 3).
A last look at CoreMark found a lost-cycles bug left by T2 (decision 82), fixed in the final version.

Section 1 is the state of Rev.02, section 2 the themes done (one line each; their history is in the documents
they point to), section 3 the themes tried and not taken, with why, and section 4 what is left for whoever takes
the design further. Earlier versions of this document are in the git history (Rev.01's on the tag `Rev.01`).

## 1. Where things are (Rev.02)

On the board (Arty A7-100T, 50 MHz, Linux 7.2):

| | Value | Document |
|---|---|---|
| CoreMark | **2.504 /MHz** (rv64gc), **2.794 /MHz** (Zba and Zbb), both `-O2`; **3.034 /MHz** with the options that make it fastest | Section 28 of `BENCH.md` |
| Dhrystone | 1.495 / 1.501 DMIPS/MHz (`-O2`), 1.541 / 1.545 (fastest options within the rules) | Same |
| Floating point | 8-tap FIR **1.50 cycles per multiply-add** (66.6 MFLOPS), matrix multiply 64×64 **2.30** (43.6 MFLOPS, assembler and cache blocking) | Same, `RTL/CPU/CPU_FPU/README.md` |
| Linux loads | Against Rev.01: `awk` −20.5 %, `gunzip` −11.4 %, `ls -lR` −8.7 %, the other kernel loads −3.5 to −5.9 % | Section 28 of `BENCH.md` |
| ISA | RV64GC, Zba, Zbb, Zbs, Zbc, Zicond, Zicboz, Zihintpause, Zihintntl, Sstc, Sdtrig, Zihpm / Sscofpmf / Smcntrpmf, Sv39 (ITLB 16, DTLB 32 entries), PMP 8 entries | `README.md` |
| Resources | LUT 50,301 (79.3 %), FF 29,473 (23.2 %), **slices 92.9 % (about 1,130 left)**, block RAM 108.5 / 135, DSP 32 / 240 | Section 47 of `TIMING.md` |
| Timing | **WNS +0.140 ns** (50 MHz). The worst paths are the load's value forwarded from MA through EX's address add and the compare of the DTLB's 32 entries into `mr_paddr` / `mr_tr_fault` | Same |
| Stress | 120 minutes of `stress.sh`, PASS | Round 19 of `BRINGUP.md` |
| Software development | Bare-metal C in Eclipse, debugged over JTAG / cJTAG; Debian 13 from the SD card with gcc, make, gdb and git on the board (a small C file in about 20 s) | `ECLIPSE.md`, `DEBIAN.md`, round 20 of `BRINGUP.md` |

**Where the time goes** (`perf.sh`, `workload.sh`, `workload.sh profile`, section 28 of `BENCH.md`):

| Kind | Loads | CPI | What the cycles go to |
|---|---|---|---|
| Fits in the caches | CoreMark | 1.115 | Nothing large: front end empty 4.0 %, back end 5.0 %, load use 2.0 %, MDU 2.6 % |
| User mode | `gunzip`, `md5sum`, `awk` | 1.10 to 1.27 | The TLB walks (10 to 13 % before E3) are under 0.3 %. Branch mispredictions (13 to 33 % of the branches), `md5sum`'s copy to user space (7 %) |
| Kernel heavy | `ls`, `ext4read`, `sdread`, `forkexec`, `tftp` | 1.87 to 2.53 | Front end empty 22 to 33 % (I$ misses, mostly L2 hits) and D$ wait 12 to 35 %. By function: the copy to user space (24 % of `sdread`), `memcpy` (7 % of `forkexec`), `liteeth_start_xmit` (8 % of `tftp`), time with interrupts off around the SD card driver, wrong guesses on 27 to 68 % of the branches |

---

## 2. Themes done

| # | Theme | Result | Document |
|---|---|---|---|
| A1 / H1 | Long stress tests | 120 minutes five times (after A1, H1, E1, on Rev.01 and on Rev.02), all OK | Rounds 14, 16 to 19 of `BRINGUP.md` |
| A2 | Timing of the SD card inputs | Already taken in the I/O block's `IDDR` (no change) | Round 13 of `BRINGUP.md` |
| A3 | `fence` | Doing nothing is enough for a single hart; tests added | `CPU_CORE_SPEC.md` 5.3 |
| B1 | Zba / Zbb | CoreMark +11.6 %, Linux's string functions switch to the Zbb versions | Decision 65 of `CPU_CORE_SPEC.md` |
| B2 | Sstc | CoreMark +1.5 % (no more going through OpenSBI at every timer) | Decision 66 |
| B3 | Zicond / Zihintpause / Zihintntl | 2 operations in the ALU; the hints only in the device tree | Decision 68 |
| B4 | Sdtrig (4 triggers) | Hardware breakpoints and watchpoints in gdb | Decision 67, section 5 of `JTAG.md` |
| B5 | PMU (Zihpm, Sscofpmf, Smcntrpmf) | `perf stat` / `perf record` on the board | Decision 69, section 13 of `BENCH.md` |
| C2 | Pipelining the FPU | One add, multiply, multiply-add or conversion a cycle. FIR 1.50, matrix multiply 2.30 cycles per multiply-add (Rev.02) | `RTL/CPU/CPU_FPU/README.md`, section 16 of `BENCH.md` |
| D1 | Linux loads measured with the PMU | `workload.sh` (8 loads) | Section 14 of `BENCH.md` |
| D2 | `perf` with function names (2026-10-12) | `perf` with libelf (`scripts/build_perf_libs.sh`); `perf.sh` and `workload.sh profile` report by function, the kernel's names included | Sections 23 and 24 of `BENCH.md` |
| E1 | L2 cache (256 KB) | Kernel-heavy loads 1.2 to 1.7 times faster | `CPU_L2_SPEC.md`, section 15 of `BENCH.md` |
| E3 | The TLBs (2026-10-17) | Events 27 to 29 for the walks; **ITLB 8 → 16, DTLB 8 → 32 entries** (parameters only): `awk` −20.5 %, `gunzip` −11.4 %, kernel loads −3.5 to −8.7 % from Rev.01. A second-level TLB was dropped: under 0.5 % of the cycles left for it (section 3) | Decisions 79 to 81, sections 26 to 26.3 of `BENCH.md`, sections 45 and 46 of `TIMING.md` |
| F1 | Zbs (2026-10-12) | `bset` / `bclr` / `binv` / `bext` in the ALU; with Zba / Zbb the B extension | Decision 77 |
| F2 | Zicboz (2026-10-12) | `cbo.zero` makes a line of zeros in the D$ without reading memory; `forkexec` −1.8 %, its D$ fills −9 %, its store waits halved | Decision 76, section 23 of `BENCH.md` |
| F3 | Zbc (2026-10-12) | `clmul` / `clmulh` / `clmulr` in the MDU (16 bits a cycle, 5 cycles); the kernel's `crc32c` uses it: `ls -lR` about −3 % of its cycles | Decision 77, section 25 of `BENCH.md` |
| G1 | Triggers with gdb on the board | `hbreak` / `watch` on a running kernel | Section 5 of `JTAG.md` |
| H2 | How to write the SD card | Write the first partition from the Mac | `software/boot/README.md` |
| M0 | What the memory waits are made of (2026-10-10) | Events 20 to 24, the profiler of SIM_SYS; found M5, M1 and the single-read bus | Decision 71, section 18 of `BENCH.md` |
| M1 | Not waiting for store misses (2026-10-10) | A cacheable store is answered when the D$ takes it; store waits −9 to −38 %, `forkexec` −2.9 %, `sdread` −2.5 % | Section 20 of `BENCH.md`, `CPU_CACHE_SPEC.md` 4.3 |
| M3 | I$ next-line prefetch (2026-10-11) | Built, but **off** (`IC_PREFETCH = 0`): on the board a demand miss waits behind the whole burst of an unused prefetch (0 to 4 % loss). Needs a demand miss that can take the bus from it | Section 21 of `BENCH.md` |
| M5 | The fill asked for before the dirty victim is copied (2026-10-10) | A dirty miss 22.0 → 12.7 cycles; Linux loads 0.5 to 3.7 % faster | Section 19 of `BENCH.md` |
| (bus) | The read granted in the cycle of the request (`FAST_READ`, 2026-10-12) | Measured first: a second read in the L2 would take 0.26 % of the cycles, the arbiter's registered grant 1.8 %. Kernel loads −1.7 to −3.5 % | Section 22 of `BENCH.md`, `CPU_CACHE_SPEC.md` 5.7 |
| T1 | EX's CSR checks apart from the debugger's number (2026-10-10) | The worst path then gone | Decision 70, section 35 of `TIMING.md` |
| T2 | A DTLB miss waits in MR, not as a stall of EX (2026-10-11) | The same cycles (but see decision 82) | Decision 73, section 40 of `TIMING.md` |
| (fix) | A late branch that guessed wrong also clears MR's wait for the DTLB (2026-10-19) | Since T2 MR waited for a walk of the wrong path (in CoreMark a walk to page 0 at the end of every list, 0.79 % of its cycles). CoreMark +0.6 % on the board: **3.034 /MHz** | Decision 82, section 28 of `BENCH.md`, section 47 of `TIMING.md` |
| T4 (first step) | The NAPOT mask of the PMP kept in a register (2026-10-11) | The PMP family left the top; the core +0.977 ns | Decision 74, section 41 of `TIMING.md` |
| T5 | The FPU / MDU start without the CSR check (2026-10-11) | | Decision 72, section 40 of `TIMING.md` |
| T6 | The DTLB's fault raised in MR (2026-10-12) | The same cycles | Decision 75, section 43 of `TIMING.md` |
| T7 | The DTLB's compare off the enable of `mr_paddr` (2026-10-12) | WNS +0.393 → +0.664 ns | Decision 78, section 44 of `TIMING.md` |
| (sim) | A memory latency model in simulation (2026-10-12) | `AXI4_SLAVE_MEM` `r_lat` / `b_lat` (`+rlat=20 +blat=10` in SIM_BIOS) like the board's DDR3; with it the simulation gives the board's verdict on the prefetch | Section 22 of `BENCH.md` |

---

## 3. Themes tried and not taken

| # | Theme | What it was to do, and the estimate | What happened | Document |
|---|---|---|---|---|
| W1 | **Write-validate of whole lines** (2026-10-18) | A copy overwrites its destination line by line, and every line was first read (write-allocate). The D$'s MSHR would hold the read of a line a store missed on while more stores come, and make a line its stores cover from them (the path of `cbo.zero`). The profile by instruction (`workload.sh ips`) showed the copy's stores waiting about 10 % of the cycles of `sdread` (85 of the 170 cycles a line), so the estimate was an upper bound of **6 to 8 % for `sdread`, 1.5 to 2 % for `md5sum`, under 1 % for the others** (realistic about half) | Built and verified (SIM_CACHE section 22, the sweep, 66 mutations), then measured in SIM_BIOS with the latency model: **+0.1 % on a pure copy** (a hold of 3 cycles), worse with a hold of 8 (copy +1.9 %, `__clear_user` +5.0 %). Of 33,000 lines opened by a store during the copy, 8 were covered: a store that misses keeps MA waiting for its answer, so the copy's stores come 4 to 5 cycles apart, and the read of the destination (an L2 hit) was already hidden under them. The 85 cycles are the stores' own pace (M1b), not the read. Taken out | Sections 27 and 27.1 of `BENCH.md` |
| W2 | **Posted uncached stores** (2026-10-18) | Answer a store to the peripherals when the bus takes it instead of at its `b`, with later uncached loads, AMOs and `fence` waiting for the posted ones. Aimed at `liteeth_start_xmit` (about 10 % of `tftp`), thought to wait on its register writes | Measured with `uclat` (`/dev/mem`): an uncached store costs **13 cycles**, the driver's three register writes and one read about 60 cycles a packet, against about 3,700 cycles a packet at that spot. So W2 could take **under 0.1 % of `tftp`**; what the samples there stand for is not these accesses. Not built | Section 27 of `BENCH.md` |
| (E3c) | A second-level TLB (2026-10-17) | 64 to 128 entries shared by the two L1 TLBs | After the ITLB of 16 and the DTLB of 32 entries less than 0.5 % of the cycles was left for it. Not built | Section 26.2 of `BENCH.md` |

What W1 left behind is worth keeping: the copy's stores are slow because the core waits for the answer of every
store that misses, which is M1b below, a change of the pipeline (its ordering of stores with side effects), not of
the D$.

---

## 4. Left for the future

None of these is in Rev.02. They are ranked roughly by what they would give; the timing margin (+0.140 ns) and
the slices (about 1,130 left) limit what can be added without T8 first.

| # | Theme | Size | Contents |
|---|---|---|---|
| M1b | The core not waiting for the answer of an accepted store | Small to medium | What W1 showed: a store that misses keeps MA waiting, and the next store goes only when MA commits, so a copy stores one double word every 4 to 5 cycles. The copy to user space is 24 % of `sdread` |
| E1b | The SD card's DMA writes in the L2 | Medium | The D$ wait of `sdread` / `ext4read` (35 % / 26 %) did not go down with the L2; the DMA's writes pass through the L2 to memory as partial writes. Confirm first with the memory-wait events (M0) |
| M2 | Software prefetch (Zicbop) | Small to medium | Pays only where the code is ours (the matrix multiply: 2.30 → about 2.0 expected) |
| M3b | A demand miss that can go before a prefetch | Medium | What would let the I$ prefetch (M3, built, off) be switched on |
| E1a | Compare L2 replacement policies | Small | Pseudo-LRU against random (`SIM/SIM_L2` has a sweep) |
| E2 | L1 from 16 to 32 KB | Medium | Staying VIPT needs 8 ways, which widens the hit path. Probably not worth it |
| M4 | Not stopping on a load miss (stall on use) | Large | Helps the matrix multiply, little else |
| T8 | The DTLB's permission check a cycle later | Small to medium | The worst paths of Rev.02 are the DTLB's compare; register the one-hot hit and the flags at the end of EX and check them in MR. Needed before anything is added near the core |
| T3 / T4 | Duplicate `ma_mem`; the data side's PMP compares a cycle earlier | Small | Timing only |
| G2 | Range matches of the triggers | Small | gdb's `watch` on a whole variable |
| C1 | Misaligned accesses in hardware | Large | About 1,060 cycles each in OpenSBI; Linux avoids them |
| C3 | An ASIC (GF180MCU) | Large | A workspace is in `../mmRISC-2-GF180MCU` |
| C4 | Multi-core | Large | Does not fit the A7-100T (about 1,130 slices left); the guide in section 6.4 of `CPU_CACHE_SPEC.md` is ready |
| C5 | Issuing an FLD with an FP operation | Large | In effect a new pipeline; FIR 1.50 → about 1.0 |
