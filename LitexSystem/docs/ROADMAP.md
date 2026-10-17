# Next design themes (as of 2026-10-18)

[日本語](ROADMAP_J.md)

Where things stand after the themes of 2026-10-10 to 10-12 (memory waits M, timing T, ISA F, measurement D).
This version is reorganized: the themes done are one line each in section 2 (their history is in the
documents they point to; earlier versions of this document are in the git history), and section 3 holds only
what is left, ranked again by what the board's loads spend their cycles on, function by function (sections 24
and 25 of `BENCH.md`).

Section 1 was the state of **Rev.01** (the tag on `main`, 2026-10-12); the themes of section 3 are developed in the
`dev` branch, and section 1 now follows `dev` (E3: the ITLB of 16 and the DTLB of 32 entries, 2026-10-17).

## 1. Where things are

On the board (Arty A7-100T, 50 MHz, Linux 7.2):

| | Value | Document |
|---|---|---|
| CoreMark | **2.499 /MHz** (rv64gc), **2.785 /MHz** (Zba and Zbb), both `-O2`; **3.025 /MHz** with the options that make it fastest | Sections 16 and 17 of `BENCH.md` |
| Dhrystone | 1.490 / 1.501 DMIPS/MHz (`-O2`), 1.536 / 1.542 (fastest options within the rules) | Section 17 of `BENCH.md` |
| Floating point | 8-tap FIR **1.53 cycles per multiply-add** (65.6 MFLOPS), matrix multiply 64×64 **2.42** (41.2 MFLOPS, assembler and cache blocking) | `RTL/CPU/CPU_FPU/README.md` |
| ISA | RV64GC, Zba, Zbb, **Zbs**, **Zbc**, Zicond, **Zicboz**, Zihintpause, Zihintntl, Sstc, Sdtrig, Zihpm / Sscofpmf / Smcntrpmf, Sv39, PMP 8 entries | `README.md` |
| Resources | LUT 49,700 (78.4 %), FF 29,485 (23.3 %), **slices 89.6 % (about 1,650 left)**, block RAM 108.5 / 135 (26.5 left), DSP 32 / 240 | Section 46 of `TIMING.md` |
| Timing | **WNS +0.065 ns** (50 MHz; Rev.01 +0.664 ns). The worst paths are the load's value forwarded from MA through EX's address add and the compare of the DTLB's 32 entries into `mr_tr_fault` / `mr_paddr` (T8) | Same |

**Where the time goes** (`workload.sh`, `workload.sh profile`, sections 24 and 25 of `BENCH.md`):

| Kind | Loads | CPI | What the cycles go to |
|---|---|---|---|
| Fits in the caches | CoreMark | 1.12 | Nothing large: front end empty 4.8 %, back end 5.6 %, load use 2.0 % |
| User mode | `gunzip`, `md5sum`, `awk` | 1.10 to 1.27 | The TLB walks were 10 to 13 % of the cycles of `gunzip` and `awk`; **E3 took −11.4 % / −20.5 %** (sections 26.1 and 26.3 of `BENCH.md`), and less than 0.3 % is left. `md5sum`: the copy to user space 6.6 %, D$ wait 8 % |
| Kernel heavy | `ls`, `ext4read`, `sdread`, `forkexec`, `tftp` | 1.9 to 2.5 (3.4 to 8.8 % less with E3; the TLBs 1 to 3 % left) | Front end empty 21 to 31 % (I$ misses 19 to 61 per 1000 instructions, mostly L2 hits) and D$ wait 13 to 34 %. By function: **the copy to user space** (21 % of `sdread`, 4 % of `tftp`), **`memcpy`** (4 % of `forkexec`), **`liteeth_start_xmit`** (11 % of `tftp`: uncached writes to LiteEth), time with interrupts off around the SD card driver (`queue_work_on` 15 to 20 % of `ext4read` / `sdread`), wrong guesses on 27 to 68 % of the branches |

What was the main theme of the previous version, overlapping memory waits, is done as far as it pays: the D$
no longer makes the core wait for store misses (M1), asks for the fill before copying a dirty victim out (M5),
zeroes pages without reading them (F2), and the bus grants a read in the cycle it is asked (`FAST_READ`). What is
left is in the writes that the copies and the drivers make (the TLBs are done too: E3).

---

## 2. Themes done

| # | Theme | Result | Document |
|---|---|---|---|
| A1 / H1 | Long stress tests | 120 minutes four times (after A1, H1, E1 and on Rev.01), all OK | Rounds 14, 16, 17 and 18 of `BRINGUP.md` |
| A2 | Timing of the SD card inputs | Already taken in the I/O block's `IDDR` (no change) | Round 13 of `BRINGUP.md` |
| A3 | `fence` | Doing nothing is enough for a single hart; tests added | `CPU_CORE_SPEC.md` 5.3 |
| B1 | Zba / Zbb | CoreMark +11.6 %, Linux's string functions switch to the Zbb versions | Decision 65 of `CPU_CORE_SPEC.md` |
| B2 | Sstc | CoreMark +1.5 % (no more going through OpenSBI at every timer) | Decision 66 |
| B3 | Zicond / Zihintpause / Zihintntl | 2 operations in the ALU; the hints only in the device tree | Decision 68 |
| B4 | Sdtrig (4 triggers) | Hardware breakpoints and watchpoints in gdb | Decision 67, section 5 of `JTAG.md` |
| B5 | PMU (Zihpm, Sscofpmf, Smcntrpmf) | `perf stat` / `perf record` on the board | Decision 69, section 13 of `BENCH.md` |
| C2 | Pipelining the FPU | One add, multiply, multiply-add or conversion a cycle. FIR 1.53, matrix multiply 2.42 cycles per multiply-add | `RTL/CPU/CPU_FPU/README.md`, section 16 of `BENCH.md` |
| D1 | Linux loads measured with the PMU | `workload.sh` (8 loads) | Section 14 of `BENCH.md` |
| D2 | `perf` with function names (2026-10-12) | `perf` with libelf (`scripts/build_perf_libs.sh`); `perf.sh` and `workload.sh profile` report by function, the kernel's names included | Sections 23 and 24 of `BENCH.md` |
| E1 | L2 cache (256 KB) | Kernel-heavy loads 1.2 to 1.7 times faster | `CPU_L2_SPEC.md`, section 15 of `BENCH.md` |
| E3 | The TLBs (2026-10-17) | Events 27 to 29 for the walks; **ITLB 8 → 16, DTLB 8 → 32 entries** (parameters only): `awk` −20.5 %, `gunzip` −11.4 %, kernel loads −3.4 to −8.8 % from Rev.01; WNS +0.664 → +0.065 ns. A second-level TLB was dropped: under 0.5 % of the cycles left for it | Decisions 79 to 81, sections 26 to 26.3 of `BENCH.md`, sections 45 and 46 of `TIMING.md` |
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
| T2 | A DTLB miss waits in MR, not as a stall of EX (2026-10-11) | The same cycles | Decision 73, section 40 of `TIMING.md` |
| T4 (first step) | The NAPOT mask of the PMP kept in a register (2026-10-11) | The PMP family left the top; the core +0.977 ns | Decision 74, section 41 of `TIMING.md` |
| T5 | The FPU / MDU start without the CSR check (2026-10-11) | | Decision 72, section 40 of `TIMING.md` |
| T6 | The DTLB's fault raised in MR (2026-10-12) | The same cycles | Decision 75, section 43 of `TIMING.md` |
| T7 | The DTLB's compare off the enable of `mr_paddr` (2026-10-12) | WNS +0.393 → +0.664 ns | Decision 78, section 44 of `TIMING.md` |
| (sim) | A memory latency model in simulation (2026-10-12) | `AXI4_SLAVE_MEM` `r_lat` / `b_lat` (`+rlat=20 +blat=10` in SIM_BIOS) like the board's DDR3; with it the simulation gives the board's verdict on the prefetch | Section 22 of `BENCH.md` |

---

## 3. Next themes

### W. Writes (new, from the profile)

| # | Theme | Size | Contents | Where it helps |
|---|---|---|---|---|
| W1 | **Write-validate of whole lines** | Medium | **Checked (2026-10-18, section 27 of `BENCH.md`): the copy's stores wait about 10 % of the cycles of `sdread`; upper bound `sdread` 6 to 8 %, `md5sum` 1.5 to 2 %, the others under 1 %.** A copy writes the destination line by line, and today every line is first read (write-allocate: an L2 hit or a DRAM read) and then entirely overwritten. The MSHR already keeps a word and its byte enables for every word of the line (stores join it, M1), and F2 already lets an MSHR make its beats itself instead of asking the bus (`ms_zero`). An MSHR opened by a store to the first word of a line waits a few cycles before its read; if the stores that join it cover all 8 words, it makes its beats from them, without the read. Otherwise the read goes out a few cycles later than today. The kernel's copy loops (`uaccess.S`, `memcpy`) load 8 words and then store them in a row once the destination is aligned | The copy to user space (21 % of `sdread`, 6.6 % of `md5sum`, 3.6 % of `tftp`), `memcpy` (4.2 % of `forkexec`), the L2's reads. Confirm first where the copy's samples fall (the source's loads or the destination's stores: `perf script` addresses against the kernel's disassembly on the host) |
| W2 | **Posted uncached stores** | Dropped | **Measured (2026-10-18, section 27 of `BENCH.md`): an uncached store takes 13 cycles, the driver's register accesses about 60 cycles a packet: under 0.1 % of `tftp` to take.** A store to the uncached region (the peripherals) waits today for the bus's answer (`b`), the round trip through the peripheral bus and LiteX's bridge. Answer it when it is taken (as M1 does for cacheable stores below `STORE_ACK_LIMIT`), and make a later uncached load, an AMO and `fence` wait until the posted stores are done (the order the device sees stays the same). A bus error of a posted store can no longer be precise: report it as an interrupt, or keep the stores to addresses that can fail waiting. First check with `perf script` whether `liteeth_start_xmit`'s samples are its `memcpy_toio` (the stores) or its polling of LiteEth's state (the loads, which this would not change) | `liteeth_start_xmit` (10.7 % of `tftp`), the SD card driver's writes of its registers |

### E. What remains of the memory hierarchy

| # | Theme | Size | Contents |
|---|---|---|---|
| E1b | The SD card's DMA writes in the L2 | Medium | The D$ wait of `sdread` / `ext4read` (34 % / 26 %) did not go down with the L2. The DMA's writes come as the D$'s write-through and pass through the L2 to memory as partial writes, each waiting for memory's answer; the D$ is thought to be held meanwhile (not confirmed). Allocate whole lines in the L2, or answer early with a write buffer (section 8 of `CPU_L2_SPEC.md`). Confirm first with the memory-wait events (M0) and W1's check of the copy |
| E1a | Compare L2 replacement policies | Small | Pseudo-LRU against random on the board's loads (`SIM/SIM_L2` has a sweep) |
| E2 | L1 from 16 to 32 KB | Medium | Front end empty is still 21 to 31 % of the kernel loads. Staying VIPT (4 KB a way) needs 8 ways, which widens the hit path. Probably not done; the L2 takes most of these misses in about 13 cycles |

### M. What remains of overlapping memory waits

| # | Theme | Size | Contents |
|---|---|---|---|
| M1b | The core not waiting for the answer of an accepted store | Small | 1 to 2 cycles a store, now that the D$ answers an accepted store at once (M1) |
| M2 | Software prefetch (Zicbop) | Small to medium | A prefetch only opens an MSHR, answered at once. The kernel is built with `CONFIG_RISCV_ISA_ZICBOP=y`, so naming `zicbop` in the device tree starts its `prefetch` / `prefetchw`. The bus takes one read at a time, and a demand miss waits behind a prefetch (what turned M3 off), so it pays only where the code is ours (the matrix multiply: 2.42 → about 2.0 expected) |
| M3b | A demand miss that can go before a prefetch | Medium | What would let M3 (I$ next line) be switched on: the arbiter or the L2 ending or putting aside a prefetch's burst when a demand miss comes. Measured first in simulation with the latency model |
| M4 | Not stopping on a load miss (stall on use) | Large | The result of a missed load written later through the register file's second write port, with a pending bit per register. M0 found that a missed load is mostly used one or two instructions later (7.5 % hidden in `ldloop`, 39 % in the matrix kernels): it helps the matrix multiply, little else. About LUT +1,000 to 2,000 |

### T. Timing

WNS +0.065 ns. The worst paths are the load's value forwarded from MA through EX's address add and the compare of
the DTLB's 32 entries into the fault of the translation and the physical address (section 46 of `TIMING.md`).
**Any theme that adds logic near the core needs T8 first** (or the DTLB back to 16 entries, +0.514 ns). Next
are the IFU's prefetch queue into decode (+0.394 ns) and the data side's PMP (T4, second step).

| # | Theme | Size | Contents |
|---|---|---|---|
| T8 | The DTLB's permission check a cycle later | Small to medium | Register the one-hot hit (32 bits) and the hit entry's flags at the end of EX, and check U / R / W / X, A / D, SUM / MXR in MR, where the fault is raised since decision 75. `mr_paddr` keeps the compare and select (+0.209 ns) |
| T3 | Duplicate `ma_mem` | Small | Reduce the fanout of the first level. Its effect depends on placement |
| T4 (second step) | The data side's PMP range compares a cycle earlier | Small to medium | The range compares (14 levels of CARRY4) are still in MR, before the cancel of the early request. Register them or compare in EX against the DTLB's answer |

### G. Debug

| # | Theme | Size | Contents |
|---|---|---|---|
| G2 | Range matches of the triggers (match 1, NAPOT) | Small | Today only exact matches, so gdb's `watch` stops only on accesses to the first address of a variable |

### C. Large themes (on hold)

| # | Theme | Judgement |
|---|---|---|
| C1 | Misaligned accesses in hardware | About 1,070 cycles each (OpenSBI does them). Linux measures them as slow at boot and avoids them, so traps are rare. On hold until a load needs them |
| C3 | Trying an ASIC (GF180MCU) | A workspace is in `../mmRISC-2-GF180MCU`. When the core has settled |
| C4 | Multi-core | Does not fit the A7-100T (about 2,190 slices left). The guide in section 6.4 of `CPU_CACHE_SPEC.md` is ready |
| (C5) | Issuing an FLD with an FP operation (dual issue of memory and floating point) | FIR 1.53 → about 1.0, matrix multiply 1.7 → about 1.1, but fetch, decode and issue two wide is in effect a new pipeline. Not worth it at 50 MHz with the slices left |

---

## 4. Recommended order

0. ~~A 120-minute `stress.sh` on the current bitstream~~: **done, PASS** (round 18 of `BRINGUP.md`, Rev.01).
1. ~~E3~~: **done** (ITLB 16, DTLB 32, sections 26.1 and 26.3 of `BENCH.md`). T8 before any theme that needs
   timing margin.
2. **W1** (write-validate): checked (section 27 of `BENCH.md`), an upper bound of 6 to 8 % for `sdread` and
   under 2 % for the others, in the D$'s MSHRs. To do, or to close with Rev.02.
3. ~~W2~~: **dropped** (an uncached store takes 13 cycles, section 27 of `BENCH.md`).
4. **E1b** if the measurement shows the D$ held by the SD card's DMA writes (`sdread` / `ext4read`).
5. As margin or need calls for them: M1b, M2 / M3b, T3 / T4, G2. M4 and the C themes stay on hold.
