# Next design themes (as of 2026-10-09)

[日本語](ROADMAP_J.md)

Where things stand after the themes of 2026-10-03 to 10-09 (A, B, C2, D1, E1, G1, H). The history of
each theme is in the table of section 2 and in the sections of the documents it points to (earlier
versions of this document are in the git history).

## 1. Where things are

On the board (Arty A7-100T, 50 MHz, Linux 7.2):

| | Value | Document |
|---|---|---|
| CoreMark | **2.498 /MHz** (rv64gc), **2.785 /MHz** (built with Zba and Zbb) | Sections 15 and 16 of `BENCH.md` |
| Dhrystone | 1.488 / 1.496 DMIPS/MHz | Same |
| Floating point | 8-tap FIR **1.53 cycles per multiply-add** (65.6 MFLOPS), matrix multiply 64×64 **2.42** (41.2 MFLOPS, assembler + cache blocking) | `RTL/CPU/CPU_FPU/README.md` |
| Resources | LUT 44,833 (70.7 %), FF 24,712 (19.5 %), **slices 86.2 % (about 2,190 left)**, block RAM 108.5 / 135 (26.5 left), DSP 32 / 240 | Section 34 of `TIMING.md` |
| Timing | WNS +0.113 ns (50 MHz). The worst path is the debugger's CSR number → CSR checks → EX exception → stall | Same |

**Where the time goes**:

- **CoreMark** (fits in the caches): CPI 1.118. The losses are front end empty 4.0 %, MDU / FPU wait
  2.6 %, load-use 2.0 %, D$ wait 0.25 % and so on, all a few % (sections 13 and 15 of `BENCH.md`).
  What remains in the pipeline is hardly worth the effort and the risk.
- **Real Linux loads** (`workload.sh`, with the L2): of the cycles, **D$ wait is 7 to 9 % in user-mode
  loads and 16 to 39 % in kernel-heavy loads**, front end empty (I$ misses) 2 to 30 % (section 15 of
  `BENCH.md`). User-mode loads also show many DTLB misses (8 to 16 per 1000 instructions).
- **Floating point**: what remains of the matrix multiply (the gap between 2.42 and the kernel's 1.7)
  is D$ misses.

The core today **waits in MA for the answer when a load or store misses, and nothing moves meanwhile**
(stall on miss). The D$ itself accepts hits to other lines during a miss (2 MSHRs, an 8-entry ROB that
answers in order), and there is an L2, but the core does not make use of them. That is where the next
big gain is (section 3, M).

---

## 2. Themes done

| # | Theme | Result | Document |
|---|---|---|---|
| A1 / H1 | Long stress tests | 120 minutes three times (after A1, H1 and E1), all OK | Rounds 14, 16 and 17 of `BRINGUP.md` |
| A2 | Timing of the SD card inputs | Already taken in the I/O block's `IDDR` (no change) | Round 13 of `BRINGUP.md` |
| A3 | `fence` | Confirmed that doing nothing is enough for a single hart, and added tests | `CPU_CORE_SPEC.md` 5.3 |
| B1 | Zba / Zbb | CoreMark +11.6 %, Linux's string functions switch to the Zbb versions | Decision 65 |
| B2 | Sstc | CoreMark +1.5 % (no more going through OpenSBI at every timer) | Decision 66 |
| B3 | Zicond / Zihintpause / Zihintntl | 2 operations in the ALU; the hints only put in the device tree | Decision 68 |
| B4 | Sdtrig (4 triggers) | Hardware breakpoints and watchpoints in gdb | Decision 67, section 5 of `JTAG.md` |
| B5 | PMU (Zihpm, Sscofpmf, Smcntrpmf) | `perf stat` / `perf record` on the board | Decision 69, section 13 of `BENCH.md` |
| C2 | Pipelining the FPU | Add / subtract, multiply, multiply-add and conversions at one a cycle. FIR 1.53, matrix multiply 2.42 cycles per multiply-add (17.6 in C with the earlier version). Resources even went down | `RTL/CPU/CPU_FPU/README.md`, `CPU_CORE_SPEC.md` 10.11, section 16 of `BENCH.md` |
| D1 | Measuring real Linux loads with the PMU | `workload.sh` (8 loads) | Section 14 of `BENCH.md` |
| E1 | L2 cache (256 KB) | 1.2 to 1.7 times on kernel-heavy loads | `CPU_L2_SPEC.md`, section 15 of `BENCH.md` |
| G1 | Triggers with gdb on the board | `hbreak` / `watch` on a running kernel | Section 5 of `JTAG.md` |
| H2 | How to write the SD card | Write the first partition from the Mac | `software/boot/README.md` |

---

## 3. Next themes

### M. Overlapping memory waits with computation (new, the main one)

The rule today is "**a load or store in MA stops until the D$ answers**" (`stall_ma = ma_valid & ma_mem
& ~lsu_resp_valid`). On a miss the whole pipeline stops for 14 to 22 cycles on an L2 hit, and 60 cycles
or more when it goes to DRAM. Stores are the same: a write-allocate miss waits until the line arrives.
There are 4 levels of overlap, from the lightest, and they can be combined.

| # | Theme | Size | Contents | Where it helps |
|---|---|---|---|---|
| M0 | **Measure what the waits are made of** | Small | **Done (2026-10-10, section 18 of `BENCH.md`, simulation and board; events 20 to 24, decision 71 of `CPU_CORE_SPEC.md`).** Count first which waits are worth removing: (1) the share of stores and of loads in MA's waits, (2) the distribution of the distance (in instructions) from a load to the instruction that uses its value, (3) the number of misses in flight per cycle. Add them to the profiler of SIM_SYS and as PMU events (2 or 3), and look with `workload.sh` and `micro` | Decides which of M1 to M4 to do |
| M1 | **Do not wait for stores** (store buffer) | Medium | **Done in the D$ (2026-10-10, `BENCH.md` 20: store waits −9 to −38 % on the board, `forkexec` −2.9 %, `sdread` −2.5 %). The core-side part (M1b: not waiting for the answer of an accepted store) is left: 1 to 2 cycles a store.** A store to the cacheable region retires when the D$ accepts it, without waiting for the answer. The D$ always performs the stores it accepted in order, so later loads line up behind them and the order is kept. Cacheable stores get no bus errors (only the uncached region, AMO and SC do, and those keep waiting as now). Add the rule that `fence` waits for it to be empty | Store misses (`memset`, `memcpy`, copying pages at fork, writing C back in the matrix multiply). (1) of M0 tells how much |
| M2 | **Software prefetch** (Zicbop, `prefetch.r` / `prefetch.w`) | Small to medium | A prefetch instruction only makes the D$ start handling a miss (MSHR); the core does not wait for the answer (the D$ answers as soon as it accepts it and does not block the ROB). Zicbop is a hint shaped like an ORI, so the core today runs it as an instruction that does nothing. **The running kernel is already built with `CONFIG_RISCV_ISA_ZICBOP=y`**, so putting `zicbop` in the device tree makes the kernel's `prefetch` / `prefetchw` start to work. GCC 13.2 turns `__builtin_prefetch` into `prefetch.r` with `-march=..._zicbop` (checked) | The assembler kernels (the matrix multiply reading the rows of A and C one panel ahead: 2.42 → about 2.0 expected), hand-written loops like `memcpy`, parts of the kernel |
| M3 | **Hardware prefetch** | Medium | The D$ or the L2 watches the pattern of accesses (next line, constant stride) and starts reading the next line by itself. No software change needed. Putting it in the L2 is safer (does not pollute the L1, far from the core's timing). Follows 1 or 2 streams with the L2's spare capacity | Streaming loads (`md5sum` with its 71 % L2 hit rate, `gunzip`, the copy of SD reads). The "kind that prefetch reduces" of section 14 of `BENCH.md` |
| M4 | **Do not stop on a load miss** (stall on use) | Large | A load that misses leaves MA without waiting for the result, and the result is written later through **the second write port of the register file** (the port C2 made for the FPU). The destination register gets a pending bit (the same form as C2's `gpr_pend` / `fp_pend`), and only instructions that read it wait. The D$ answers in order, so a FIFO of the loads' destinations is enough | Matrix multiply (getting close to the kernel's 1.7), integer code with independent work after a load. Pointer-chasing loops use the value right away and gain nothing |
| M5 | **Ask for the fill before copying the dirty victim out** (new, from M0) | Small | **Done (2026-10-10, `BENCH.md` 19: a dirty miss 22.0 → 12.7 cycles; on the board the Linux loads 0.5 to 3.7 % faster, as M0 predicted).** Today the fill engine of the D$ copies the 8 words of a dirty victim into a writeback buffer (`F_WB_READ` → `F_WB_PUSH`, about 11 cycles) and only then raises the read address of the new line. Raise it first and copy while the fill is outstanding: the copy reads a word a cycle through the read port, the fill writes a beat a cycle through the write port and its first beat comes at the earliest 2 cycles after the address, so the copy stays ahead (an interlock holds `rready` should it ever fall behind). Only the D$ changes | Every miss that evicts a dirty line: 27 % of MA's waits in `fploop`, 37 % in `ldloop` (`BENCH.md` 18); on the board, event 24 of `workload.sh` |

**The hard parts of M4** (which M1 and M2 do not have):

- **Precise exceptions**: exceptions of address translation and PMP are known in MR (before leaving
  MA), so they stay precise. Only bus errors come later, and the cacheable region has none (DRAM and the
  L2 return no errors). The uncached region, LR / SC, AMO and the debugger's accesses keep waiting as now.
- **Competition for the write port**: the FPU's answers come out in fixed cycles and cannot be stopped,
  so a load result arriving in the same cycle waits a cycle in a buffer of 1 or 2 entries (or the LVT
  gets 3 banks).
- **Order**: an instruction that writes the same register later (WAW), a trap while results are still
  coming (they are past the point of being taken back, so the trap waits for them), the debugger's halt,
  `fence`. The same kind of problems as C2, so t33 and the form of the bug injections can be reused.
- Resources: about LUT +1,000 to 2,000 on the core side. Slices go back from 86.2 % to 89 to 92 %.

**Recommended order**: M0 → M1 and M2 (both medium and independent; M2 also helps Linux) → M3 or M4
depending on M0's numbers. M4 helps the widest range, but it is about as large as stage 2 of C2.

**What M0 found** (simulation, `BENCH.md` 18): (1) the copy of dirty victims is a large and cheap part (M5);
(2) on misses stores wait as long as loads (M1); (3) missed loads are mostly used one or two instructions
later, so M4 hides little in code that uses the value at once (7.5 % in `ldloop`, 39 % in the matrix
kernels, which load ahead); (4) **the bus takes one read at a time** (the arbiter of `CPU_CACHE` keeps a read
until its last beat, the L2 takes one transaction at a time): two misses at once are rare now, but a
prefetch (M2 / M3) would occupy the bus, and a demand miss behind it waits for the whole prefetch. Before
M3, or if M2 shows that, the read side of the bus needs to take a second read (or let a demand miss go first).

**Considered only (probably not done)**: issuing an FLD and an FP operation in the same cycle (dual issue
of memory and floating point). The FIR would go 1.53 → about 1.0 and the matrix multiply kernel 1.7 →
about 1.1, but making fetch, decode and issue two wide is in effect a new pipeline, not worth it at
50 MHz with the slices left.

### T. Getting timing margin back (small to medium, before M4)

WNS is +0.113 ns. Before adding logic with a large theme, deal with the paths that are known.

| # | Theme | Size | Contents |
|---|---|---|---|
| T1 | Separate EX's CSR checks from the debugger's number | Small | **Done (2026-10-10, decision 70 of `CPU_CORE_SPEC.md`): the path is gone, WNS +0.048 ns set by the next families (section 35 of `TIMING.md`).** The worst path today (section 34 of `TIMING.md`). The read address of the CSR file goes through a "debugger's number / EX's instruction" multiplexer, and EX's exception checks are behind it. The debugger reads CSRs only while halted, so build EX's exception from `ex_csr_addr` alone and give the debugger checks of its own |
| T2 | Separate EX's stall from the DTLB compare | Medium | "Forwarding from MA → EX's address add → DTLB compare → stall" of section 32 of `TIMING.md`. A DTLB miss only needs to be known in MR. What taking back the D$ request involves when the stall comes a cycle later needs study |
| T3 | Duplicate `ma_mem` | Small | Reduce the fanout of the first level (72). A small measure whose effect depends on placement |
| T5 | The FPU / MDU start without the CSR check | Small | Section 38 of `TIMING.md`: `ex_csr_addr` → CSR check → `ex_exc_pre` → `fpu_active` → `lsu_e_valid` → D$. Not a real path (a CSR instruction is none of those); give `mdu_active`, `fpu_active`, `d_tr_req` and `ex_late` an `ex_exc_pre` without the CSR term |
| T4 | Data-side PMP compare a cycle earlier | Small to medium | The second family of section 35 of `TIMING.md` (276 of the worst 300): `pmpaddr` → PMP compare (14 levels of CARRY4) → cancel of the early request → the D$'s ROB, in one cycle. Register the range comparisons (or compare in EX against the DTLB's answer) so that MR only selects by priority |

### E. What remains of the memory hierarchy

| # | Theme | Size | Contents |
|---|---|---|---|
| E1a | Compare L2 replacement policies | Small | Pseudo-LRU against random (`SIM/SIM_L2` has a sweep, but they were not compared on the board's loads) |
| E1b | Catch the SD card's DMA writes in the L2 | Medium | The D$ wait of `sdread` / `ext4read` (39 % / 31 %) did not go down with the L2. The DMA writes pass through the L2 as the D$'s write-through, and the D$ is thought to be blocked while each waits for memory's answer (not confirmed). Allocate the line in the L2 and answer early (section 8 of `CPU_L2_SPEC.md`). Confirm first with the same tools as M0 |
| E2 | L1 from 16 to 32 KB | Medium | Staying VIPT (4 KB per way) needs 8 ways, which widens the D$ hit path (tight on timing). With the L2 the gain is also small now. Probably not done |
| E3 | Larger TLBs (or a second level) | Medium | ITLB / DTLB have 8 entries. User-mode loads have 8 to 16 DTLB misses per 1000 instructions (section 14 of `BENCH.md`), the main cause of what user-mode loads lose after the L2. Add a second level of 32 to 64 entries |

### F. Small ISA items (visible to Linux)

| # | Theme | Size | Contents |
|---|---|---|---|
| F1 | Zbs (single-bit operations) | Small | `bset` / `bclr` / `binv` / `bext`. With Zba / Zbb it completes the B extension. Only additions to the ALU |
| F2 | Zicboz (`cbo.zero`) | Medium | The kernel already has `CONFIG_RISCV_ISA_ZICBOZ=y`. Zeroing pages allocates the D$ line as zeros without reading it from memory, cutting the reads at every fork, exec and page fault. Adds a new instruction to the D$. Goes well with M1 |
| F3 | Zbc (carry-less multiply) | Small to medium | The kernel has `CONFIG_RISCV_ISA_ZBC=y`. Used by CRC32 (ext4 metadata). Add to the MDU as a multi-cycle operation |
| (M2) | Zicbop | | Put under M |

### G / D. Finishing debug and measurement

| # | Theme | Size | Contents |
|---|---|---|---|
| G2 | Range matching of triggers (match 1, NAPOT) | Small | Today only exact matches, so gdb's `watch` stops only on accesses to the first address of a variable |
| D2 | `perf` with function names | Small to medium | Build elfutils statically and add it. `perf report` then works per function of the kernel and user programs. Needed to follow M0 down to "which functions wait on misses" |

### C. Large themes (on hold)

| # | Theme | Judgement |
|---|---|---|
| C1 | Misaligned accesses in hardware | About 1,070 cycles each (OpenSBI does them). Linux measures them as "slow" at boot and avoids them, so traps are rare. On hold until a load that needs them shows up |
| C3 | Trying an ASIC (GF180MCU) | There is a workspace in `../mmRISC-2-GF180MCU`. When the core has settled |
| C4 | Multi-core | Does not fit the A7-100T (about 2,190 slices left). The guide in section 6.4 of `CPU_CACHE_SPEC.md` is ready |

---

## 4. Recommended order

1. **T1** (small): get timing margin back. Only cutting the debugger's path
2. **M0** (small): measure what the memory waits are made of. **Done** (`BENCH.md` 18): on the board stores
   are up to 13.5 % of the cycles, dirty victim copies up to 3.7 %, the front end (I$) 19 to 30 % in kernel loads
3. **M5** (small, new): the cheapest overlap M0 found. Then **M1 (store buffer)**, the largest item on the
   core side. T4 / T2 wait until added logic takes the margin away (WNS +0.717 ns, `TIMING.md` 36)
4. **Prefetch**: **M3 in the L2** with the I$'s fills in view (next line; the front end is 19 to 30 % of the
   kernel loads' cycles), and **M2 (Zicbop)** for the code we write. Both meet the single-read bus (M0 (4))
5. Then **E3 (TLB)** or **M4 (no stop on load misses)**; M0 says M4 hides little in code that uses the
   value at once. T2 before M4
6. In between, **F1 (Zbs)**, F2 / F3, G2
7. C1 and C3 stay on hold
