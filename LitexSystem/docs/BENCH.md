# Performance measurements (2026-10)

[日本語](BENCH_J.md)

CoreMark and Dhrystone are measured (1) in simulation (`SIM/SIM_SYS`, machine mode, core + real caches)
and (2) on the board (Arty, 50 MHz, as Linux user programs). In simulation the cycles and instructions of
the timed part are known exactly, and where cycles are lost can be counted. The board's numbers are the
real thing, memory (DDR3) and OS included.

| Environment | Built in | How to run |
|---|---|---|
| Simulation | `SIM/SIM_SYS/bench/` (no C library, CoreMark's `ee_printf`) | `cd SIM/SIM_SYS && make bench` |
| Board | `LitexSystem/software/bench/` (static, glibc) | `software/bench/README.md` |

### Build conditions

The compiler is **GCC 13.2.0** for both (riscv-gnu-toolchain, `gc891d8dc23e`, `/opt/riscv`). Optimization
is **`-O2` only**; options often used for published CoreMark results, such as `-O3`, `-funroll-loops` and
`-finline-functions`, are not used. Tuning is the toolchain's default `-mtune=rocket` (not specified).

| | Board (`LitexSystem/software/bench/`) | Simulation (`SIM/SIM_SYS/bench/`) |
|---|---|---|
| Compiler | `riscv64-unknown-linux-gnu-gcc` 13.2.0 | `riscv64-unknown-elf-gcc` 13.2.0 |
| Architecture | `-march=rv64imafdc -mabi=lp64d` (`coremark` / `dhrystone`)<br>`-march=rv64imafdc_zba_zbb -mabi=lp64d` (`coremark_zb` / `dhrystone_zb`, section 11) | `-march=rv64imafdc_zicsr_zifencei -mabi=lp64d` (`_zba_zbb` added for the comparison of section 11) |
| Optimization | `-O2` | `-O2` |
| Other | `-static` (glibc 2.40 linked statically; the C library itself is rv64gc) | `-mcmodel=medany -nostdlib -fno-tree-loop-distribute-patterns` (no C library; `memset` and the like are the home-made `minilib.c`) |
| CoreMark | The posix port as it is, `-DITERATIONS=0 -DPERFORMANCE_RUN=1` (it chooses a count that runs 10 seconds or more) | `-DITERATIONS=10 -DPERFORMANCE_RUN=1`, output to `tohost` with `ee_printf` |
| Dhrystone | Dhrystone 2.2 of riscv-tests, `-std=gnu89 -fno-common -fno-builtin-printf -w`. Timed with `bench_usec()` (microseconds); under 2 seconds, measured again with 10 times the count | Dhrystone 2.2 of riscv-tests, 500 runs, timed with `mcycle` |

CoreMark prints the compiler and options it was built with at run time (`Compiler version : GCC13.2.0`,
`Compiler flags : -march=rv64imafdc -mabi=lp64d -O2 -static`).

Dhrystone's string functions (`strcpy` / `strcmp`) are glibc's word-at-a-time versions on the board and
home-made byte-at-a-time versions in simulation. That is the main reason the two numbers differ for the
same Dhrystone (simulation lower) (sections 2 and 10).

## 1. Simulation (timed part only)

| | CoreMark (10 iterations) | Dhrystone (500 runs) |
|---|---|---|
| Cycles | 5,834,958 | 426,006 |
| Instructions | 3,589,223 | 202,550 |
| CPI | 1.626 | 2.103 |
| Per iteration | 583,496 cycles | 852 cycles (405 instructions) |
| **Performance** | **1.71 CoreMark/MHz** | **0.67 DMIPS/MHz** |

(Dhrystone's string functions are the home-made byte-at-a-time versions, slower than the board's glibc.
CoreMark calls no library in its timed part. tb_SYS's memory answers faster than DDR3.)

### Where cycles are lost (counted at the issue point ID → EX)

"where an instruction is issued" of `+profile`. Each cycle is counted once, either as issuing an
instruction to EX or as one reason it could not, and the total is the cycle count.

| | CoreMark | Dhrystone |
|---|---|---|
| Issued | 61.5 % | 47.5 % |
| **EX held: MA waiting for the D$'s answer** | **23.6 %** | **33.8 %** |
| Branch mispredictions (redirect + refill) | 6.6 % | 11.2 % |
| EX held: MDU / FPU | 4.8 % | 4.3 % |
| EX held: load-use | 3.5 % | 3.2 % |
| Others (fetch, serialization, translation) | 0.0 % | 0.0 % |

| Mispredicted / executed | CoreMark | Dhrystone |
|---|---|---|
| Conditional branches | 82,387 / 582,985 (14 %) | 3,506 / 28,002 (13 %) |
| `jal` | 7,996 / 43,640 (18 %) | 6,008 / 8,503 (**71 %**) |
| `jalr` (mostly function returns) | 7,055 / 21,377 (33 %) | 4,008 / 7,003 (57 %) |
| Loss per misprediction | about 3.9 cycles | about 3.5 cycles |

### What this says

1. **Even on a D$ hit, every load / store stops for about 1 cycle** (the largest loss, 23 to 34 %). The
   D$ can take one access every cycle (section 8 of `CPU_CACHE_SPEC.md`), but request to answer takes 2
   cycles. The core makes the request in MR and waits for the answer in the next cycle, with the
   instruction in MA, so MA waits 1 cycle and every instruction behind stops too. The stall per data
   access is 1.08 to 1.12 cycles, almost all of it this.
2. **Many mispredictions of `jal` and `jalr`**. The target of `jal` is written in the instruction
   itself, but if it is not in the BTB (64 entries, direct mapped) it is not known until EX. The target
   of a function return (`jalr`) changes with each caller, and there is no return address stack.
3. The MDU (multiply 3 cycles, divide 32/64 cycles) takes 4 to 5 %.

## 2. Board (2026-10-01, 50 MHz, Linux 7.2, HZ=100)

| | Result | Simulation | Difference |
|---|---|---|---|
| CoreMark | 79.21 iterations/s, **1.584 CoreMark/MHz** (validated ok) | 1.71 | The slowness of DDR3 and the OS |
| Dhrystone | 72,303 per second, **0.823 DMIPS/MHz** | 0.67 | The board has glibc's string functions (fast) |

`micro` (cycles converted at 50 MHz):

| Item | Result |
|---|---|
| Bandwidth 8 KiB (in the D$) | read 68.6 MB/s, write 104.8 MB/s, copy 45.2 MB/s |
| Bandwidth 8 MiB (DRAM) | read 38.4 MB/s, write 38.5 MB/s, copy 19.0 MB/s |
| Latency of dependent loads | 8 KiB: 5.3 cycles, 8 MiB: 74.6 cycles (DRAM + TLB misses on 4 KiB pages) |
| Misaligned 8-byte load | **1629 cycles** (155 times aligned; trapped and done in software) |
| Double precision multiply-add (dgemm 64×64) | 3.69 MFLOPS, 27 cycles per multiply-add (the FPU is not pipelined) |
| Interrupts | Timer 100 /s, UART about 50 /s. Ethernet / SD 0 during the measurement |

### The one number that did not match simulation → a constraint on where branch predictions are placed

The aligned load loop of `micro` (4 instructions, all D$ hits) took 10.5 cycles an iteration on the board
and 6.3 in simulation. The same instruction sequence was run on both to narrow it down (`loops.h`,
`micro 50 loops` / `sweep`, `SIM/SIM_SYS/bench/ldloop.c`):

| Loop | Branch address | Position in the 8-byte word | Board | Simulation |
|---|---|---|---|---|
| No load | — | — | 4.56 | 4.29 |
| `ld` same word | 0x10d8e (2-byte `c.bnez`) | 6 | 6.59 | 6.32 |
| `ld` stride 8 | 0x10d4c | 4 | 6.62 | 6.42 |
| `ld` stride 64 (`loops`) | 0x10d9e | **6 (second half in the next word)** | **10.81** | 6.31 |
| `ld` stride 64 (`sweep`, 64 lines) | 0x1097a | 2 | 6.58 | 6.19 |

It was neither the caches nor paging (simulation gives 6.30 even with three-level page tables of 4 KiB
pages): **the loop's 32-bit branch starts in the last 2 bytes of an 8-byte fetch word, with its second
half in the next word**. The BTB does not predict branches in that position (`CPU_CORE_SPEC.md` decisions
33 and 34), so it is mispredicted every time and loses about 4.5 cycles. The simulation's loop happened
to have its branch inside one word.

In C-extension code, 32-bit instructions start at 2-byte granularity, so branches in this position are
not rare. Counted in the profile:

| | CoreMark | Dhrystone |
|---|---|---|
| 32-bit branches / `jal` across words (executed) | 171,935 / 626,625 (27 %) | 6,001 / 36,505 |
| Of those mispredicted | 52,164 = **54 % of all mispredictions** | 4,501 = 33 % |
| Loss (× about 3.9 cycles) | about 3.5 % of the total cycles | about 4 % |

## 3. Candidates for improvement (largest effect first)

| Candidate | Estimate | Size | Contents |
|---|---|---|---|
| A. Do not stop MA on a D$ hit | CoreMark up to +31 %, Dhrystone up to +51 % | Large | Answer a cycle earlier (fitting block RAM output to way select in one cycle; tight on timing), or write the result of a load one cycle after MA (lengthens the load-use distance, and the handling of precise exceptions for bus errors has to be decided again) |
| B. Predict 32-bit branches across words too | CoreMark about +3.5 %, Dhrystone about +4 % | Medium | Remove the constraint of decision 34. Use the prediction in the next word, which holds the second half of the branch (or have the entry of the first word wait for the fetch of the next word before jumping) |
| C. Jump on `jal` in ID + return address stack | CoreMark about +1 %, Dhrystone about +9 % | Medium | The target of `jal` is an immediate, so it can be redirected in ID, costing 1 to 2 cycles even on a BTB miss. Predict `jalr` returns with a small stack. Overlaps with B (`jal` across words) |
| D. A shorter multiplier | a few % | Small to medium | 3 cycles → 2 cycles (pipelining the DSPs) |
| E. Misaligned accesses in hardware (task 6) | 0 for ordinary code | Large | 1629 cycles each down to a few. Helps only code that uses misaligned accesses heavily (packet processing and the like) |

The estimates are upper bounds assuming those stalls vanish entirely (A all of the D$ wait, B all
mispredictions of branches across words, C all mispredictions of `jal` / `jalr`).

## 4. Results of B and C (2026-10-02, simulation)

B (predicting 32-bit branches across words with a tail entry of the next word), of C the return address
stack (8 entries, two of them on the fetch side and the execute side), and the BTB from 64 to 256
entries. `CPU_CORE_SPEC.md` 4.2, decisions 56 and 57.

| | Before | After | |
|---|---|---|---|
| CoreMark cycles | 5,834,958 | 5,684,843 | **+2.6 %** (1.759 CoreMark/MHz) |
| CoreMark mispredictions (branch / jal / jalr) | 82,387 / 7,996 / 7,055 | 54,001 / 1,028 / 3,559 | |
| Dhrystone cycles | 426,006 | 396,032 | **+7.6 %** (0.72 DMIPS/MHz) |
| Dhrystone mispredictions (branch / jal / jalr) | 3,506 / 6,008 / 4,008 | 2,505 / 2,015 / 12 | |

Changing only the size of the BTB (with B + the stack):

| BTB | CoreMark | Dhrystone |
|---|---|---|
| 64 | 5,701,143 | 410,008 |
| 256 | 5,684,843 | 396,032 |

Jumping on `jal` in ID was not done. The remaining `jal` mispredictions are about 4 per Dhrystone run, and
it would only be one cycle earlier than fixing them in EX: about 0.5 %.

The main remaining mispredictions are CoreMark's conditional branches (9.3 %, 2-bit counters). A
predictor with history (gshare or the like) that halved them would give about 2 %.

Verification: `t24_predict` (branches across words, misuse of the tail, calls from 2 places,
mispredictions between returns, recursion deeper than the stack; each part compared with a reference of
the same instruction sequence and within 1.25 times), mutations M233 to M239 all detected, M174, M177 and
M180 updated for the new lines (M175 was invisible before too). All SIM_CORE tests, back pressure,
Icarus, riscv-tests p / v, SIM_SYS, BIOS, Linux boot from the SD model.

### Board (2026-10-02, WNS +0.002 ns after place and route)

| | Before B and C | After | |
|---|---|---|---|
| CoreMark | 1.584 /MHz | **1.667 /MHz** | +5.2 % |
| Dhrystone | 0.823 DMIPS/MHz | **0.849 DMIPS/MHz** | +3.2 % |
| `ld` stride 64 loop (branch across words) | 10.81 cycles | 6.63 | |
| The misaligned load example (loop with a branch across words) | 10.5 | 6.5 | |

The board gains more than the simulation (CoreMark +2.6 %), presumably because the board's binaries
(glibc, Linux) have more branches across words and more function returns.

## 5. A1: answering D$ hits in 2 cycles (2026-10-02, simulation)

Section 5 of `RTL/CPU/CPU_CORE/PLAN_LOAD_LATENCY.md`. CoreMark 1.76 → **2.00 CoreMark/MHz** (+13.7 %),
Dhrystone +22 %. MA's D$ wait becomes 13.8 % for CoreMark and 22.2 % for Dhrystone (A2 removes the
rest).

Board (2026-10-02, WNS +0.052 ns after place and route): **1.895 CoreMark/MHz** (+13.7 % from the 1.667
after B and C), **1.024 DMIPS/MHz** (+20.6 %). The loop of `micro` with loads went 6.6 → 5.5 cycles, and
the read bandwidth of 8 KiB 83.7 → 107.9 MB/s.

## 6. A2: issuing loads and stores from EX (2026-10-02, simulation)

Section 6 of `RTL/CPU/CPU_CORE/PLAN_LOAD_LATENCY.md`, `CPU_CORE_SPEC.md` 5.4. The request to the D$ is
made in EX, and MR lets it go or takes it back. The answer of a hit is visible in the cycle the
instruction reaches MA.

| | After A1 | After A2 | |
|---|---|---|---|
| CoreMark (10 iterations) | 4,998,815 cycles | **4,312,829** | **+15.9 %, 2.32 CoreMark/MHz** (CPI 1.20) |
| Dhrystone (500 runs) | 324,545 | **253,069** | **+28 %**, 506 cycles per run (CPI 1.25) |

Breakdown counted at the issue point (after A2):

| | CoreMark | Dhrystone |
|---|---|---|
| Issued | 83.2 % | 80.0 % |
| EX held: MA waiting for the D$'s answer | **0.0 %** | **0.0 %** |
| EX held: MDU / FPU | 6.5 % | 7.2 % |
| EX held: load-use | 4.7 % | 5.3 % |
| Branch mispredictions (redirect + refill) | 5.6 % | 7.4 % |

The wait for D$ hits is gone, and what remains is **multiply / divide**, **load-use** and **branch
mispredictions**, of about the same size. Conditional branch mispredictions in CoreMark: 54,001 / 582,985
(9.3 %).

Board (2026-10-02, WNS +0.004 ns after place and route):

| | After A1 | After A2 | |
|---|---|---|---|
| CoreMark | 1.895 /MHz | **2.211 /MHz** (110.6 iterations / s) | +16.7 % (as estimated, 2.2) |
| Dhrystone | 1.024 DMIPS/MHz | **1.297 DMIPS/MHz** | +26.7 % |
| `micro` loop with loads | 5.5 cycles | **4.4** (same as the loop without loads) | The wait of loads is gone |
| Bandwidth 8 KiB (in the D$) | read 107.9 MB/s | read **150.9**, write 245.9, copy 88.2 MB/s | |
| Latency of dependent loads 8 KiB | | 3.2 cycles | Close to the lower bound of request → answer 2 + load-use 1 |
| dgemm 64×64 | | 4.81 MFLOPS, 20.8 cycles per multiply-add | The FPU is not pipelined (outside the next candidates) |

+40 % from before B and C (section 2, 1.584 CoreMark/MHz). The timing margin went from +0.052 to
+0.004 ns (EX's add → D$ index is a new path).

After the timing work (section 24 of `TIMING.md`, WNS +0.004 → **+0.346 ns**) the board still gives
CoreMark 2.213 /MHz and Dhrystone 1.298 DMIPS/MHz.

## 7. Shortening multiply (2026-10-03, simulation)

`CPU_CORE_SPEC.md` decision 61. EX's wait for MUL / MULW from 3 to 1 cycle, and for the MULH family from
3 to 2.

| | Before | After | |
|---|---|---|---|
| CoreMark (10 iterations) | 4,312,829 cycles | **4,124,913** | **+4.6 %, 2.42 CoreMark/MHz** (CPI 1.149) |
| CoreMark EX held: MDU | 281,880 (6.5 %) | 93,960 (2.3 %) | 93,960 multiplies × 1 |
| Dhrystone (500 runs) | 253,069 | 252,069 | +0.4 % |

Dhrystone's MDU wait (17,195 cycles, 6.8 %) is about 500 **divides** (around 34 cycles each), which the
shorter multiply does not help. Early termination of divide (skipping the leading zeros of the dividend,
the equivalent of Rocket's `divEarlyOut`) can shorten it.

Board (2026-10-03, WNS +0.162 ns after place and route): **2.313 CoreMark/MHz** (+4.5 % from 2.213),
1.302 DMIPS/MHz (+0.3 %). As the simulation's ratio says.

### Early termination of divide (2026-10-03, simulation)

`CPU_CORE_SPEC.md` decision 62. The leading stages whose quotient bits are known to be 0 are skipped in
one cycle.

| | Before | After | |
|---|---|---|---|
| Dhrystone (500 runs) | 252,069 cycles | **237,406** | **+6.2 %** (CPI 1.172) |
| Dhrystone EX held: MDU | 17,195 (6.8 %) | 2,529 (1.1 %) | |
| CoreMark | 4,124,913 | 4,124,913 | No divides in the timed part |

Board (2026-10-03, WNS +0.525 ns after place and route): CoreMark 2.316 /MHz (unchanged), **1.400
DMIPS/MHz** (+7.5 % from 1.302. A little more than the simulation's +6.2 % because the board's Dhrystone
has glibc's fast string functions, which raises the weight of the divides).

## 8. The board so far (50 MHz, under Linux)

| Version | CoreMark/MHz | DMIPS/MHz | WNS |
|---|---|---|---|
| First (section 2) | 1.584 | 0.823 | |
| B and C: branch prediction (branches across words, RAS, BTB 256) | 1.667 | 0.849 | +0.002 ns |
| A1: D$ hit 3 → 2 cycles | 1.895 | 1.024 | +0.052 ns |
| A2: loads and stores issued from EX | 2.211 | 1.297 | +0.004 ns |
| Timing work (section 24 of `TIMING.md`) | 2.213 | 1.298 | +0.346 ns |
| Multiply 3 → 1 cycle | 2.313 | 1.302 | +0.162 ns |
| Early termination of divide | 2.316 | 1.400 | +0.525 ns |
| gshare (section 9) | 2.358 | 1.438 | +0.094 ns |
| Work on the PMP path (section 28 of `TIMING.md`), SD I/O | 2.354 | 1.439 | +0.681 ns |
| Late branches (section 10) | 2.429 | 1.448 | +0.301 ns |
| How the BTB's update source is chosen (section 29 of `TIMING.md`) | 2.429 | 1.451 | +0.306 ns |
| Removing checks for exceptions that cannot happen (section 30 of `TIMING.md`) | 2.429 | 1.451 | +0.121 ns |
| Zba / Zbb (section 11; benchmarks still rv64gc) | 2.434 | 1.455 | +0.491 ns |
| Same version, benchmarks rebuilt with Zba / Zbb | 2.714 | 1.460 | +0.491 ns |
| Sstc (section 12), rv64gc benchmarks | 2.469 | 1.473 | +0.381 ns |
| Same version, Zba / Zbb benchmarks | **2.754** | **1.482** | +0.381 ns |
| Sdtrig, Zicond, PMU (section 13), rv64gc benchmarks | 2.462 | 1.475 | +0.452 ns |
| Same version, Zba / Zbb benchmarks | 2.747 | 1.482 | +0.452 ns |
| L2 cache 256 KB (section 15), rv64gc benchmarks | 2.498 | 1.488 | +0.159 ns |
| Same version, Zba / Zbb benchmarks | **2.786** | **1.496** | +0.159 ns |

CoreMark +46 % and Dhrystone +70 % from the first. CoreMark in simulation (`SIM_SYS`) is at CPI 1.149,
and the remaining stalls are branch mispredictions 5.6 %, load-use 4.7 %, multiply 2.3 %.

## 9. gshare (2026-10-03, simulation)

`CPU_CORE_SPEC.md` 4.2 and decision 63. The direction of conditional branches is taken from a table of
2-bit counters indexed by the word address and the global history (8192 entries, 12 bits of history).

| | Before | After | |
|---|---|---|---|
| CoreMark conditional branch mispredictions | 54,001 / 582,985 (9.3 %) | **31,435 (5.4 %)** | −42 % |
| CoreMark (10 iterations) | 4,124,913 cycles | **4,033,497** | **+2.3 %, 2.48 CoreMark/MHz** (CPI 1.124) |
| Dhrystone (500 runs) | 237,406 | 233,430 | +1.7 % |

The table size and the way history is taken were swept (CoreMark conditional branch mispredictions):

| Method | 1024 | 4096 | 8192 | 16384 |
|---|---|---|---|---|
| 2 bits of the target of taken transfers (path history), history folded into the low bits | 61,684 to 76,718 | | | |
| Same, folded into the high bits, initial value weakly taken | 56,548 | 50,556 | | |
| **1 bit for the direction of conditional branches** (adopted) | 48,592 | 36,150 | **31,435** | 31,801 |

With path history, the backward branches of loops filled the history, and it was hardly better than the
earlier BTB counters (54,001). Folding the history into the low bits made branches in nearby words
collide and was worse.

`t24_predict` gained 6 (a branch taken every other time; half mispredicted without history) and 7 (a
jalr whose target changes; there had been no test to catch mutation M175, which drops the update of the
BTB's target), and the branch of 4 changed from every other time to a constant bit pattern (gshare now
predicts every-other-time, so the mispredictions that test restoring the return address stack no longer
happened).

The `Errors detected` that CoreMark prints in `SIM_SYS` is counted by CoreMark itself when it runs under
10 seconds; the CRC checks pass (the board's `bench.sh` runs 10 seconds or more, so it does not appear).

Board (2026-10-03, WNS +0.094 ns after place and route, LUT 42,323 = 66.8 %): **2.358 CoreMark/MHz**
(+1.8 % from 2.316), **1.438 DMIPS/MHz** (+2.7 %). +49 % / +75 % from the first (1.584 / 0.823).

## 10. Load-use: resolving conditional branches on the value of a load in MR (2026-10-03, simulation)

When EX waits on load-use, the waiting instruction was counted (`+profile` of `SIM_SYS`, the "waiting:"
line).

| Waiting instruction | CoreMark | Dhrystone |
|---|---|---|
| **Conditional branch** (jalr: 0) | **135,299 (67 %)** | **12,000 (89 %)** |
| The address of the next load / store (pointer chasing) | 57,650 (28 %) | 0 |
| Integer arithmetic | 9,912 (5 %) | 1,002 |
| Only the data of a store | 420 | 500 |

Conditional branches are predicted, so they need not wait for the value in EX. They go on to MR with
their prediction and are resolved there against the load's answer (`CPU_CORE_SPEC.md` decision 64).

| | Before | After | |
|---|---|---|---|
| CoreMark (10 iterations) | 4,033,501 cycles | **3,908,766** | **+3.2 %, 2.56 CoreMark/MHz** (CPI 1.089) |
| CoreMark load-use wait | 203,281 | 67,982 | The rest is addresses and arithmetic |
| Branches resolved in MR / of those wrong | | 135,299 / 2,321 (1.7 %) | |
| Dhrystone (500 runs) | 233,430 | **221,932** | **+5.2 %** (CPI 1.096) |

Board (2026-10-03, WNS +0.301 ns after place and route): **2.429 CoreMark/MHz** (+3.2 % from 2.354, as in
simulation), 1.448 DMIPS/MHz (+0.6 %). Dhrystone gains less than in simulation (+5.2 %) because the
simulation's Dhrystone uses home-made byte-at-a-time string functions (`beq` right after `lbu`), which
have many late branches, while the board's glibc word-at-a-time string functions have few. +53 % / +76 %
from the first (1.584 / 0.823).

## 11. Zba / Zbb (2026-10-03, simulation)

`CPU_CORE_SPEC.md` decision 65. The same CoreMark / Dhrystone rebuilt with
`-march=rv64imafdc_zba_zbb_zicsr_zifencei` and compared (the hardware is the same; what is compared is
whether the compiler can use the new instructions).

| | rv64gc | rv64gc + Zba / Zbb | |
|---|---|---|---|
| CoreMark instructions | 3,589,223 | **3,185,981** | −11.2 % |
| CoreMark cycles | 3,908,766 | **3,513,870** | **+11.2 %, 2.85 CoreMark/MHz** (CPI 1.103) |
| Dhrystone cycles | 221,932 | 220,919 | +0.5 % |

CoreMark used `zext.h` (49 places), `sext.h` (23), `sh1add.uw` / `sh2add.uw` / `add.uw` / `sh*add` (53),
`max` and `slli.uw`. CoreMark handles 16-bit values, so 2 to 3 instructions of extension and address
calculation each become 1. CPI is about the same; what helped is the instruction count. The board's
`bench.sh` binaries are still rv64gc, so this gain appears when they are rebuilt.

Board (2026-10-03, WNS +0.491 ns after place and route): `zba_zbb` appears in the isa of `/proc/cpuinfo`,
and Linux runs with the Zbb string functions. `bench.sh`'s binaries are still rv64gc, so 2.434
CoreMark/MHz and 1.455 DMIPS/MHz, unchanged (the kernel's string functions do not affect the benchmarks).

`coremark_zb` / `dhrystone_zb` (`-march=rv64imafdc_zba_zbb`, C library rv64gc) on the same board
(2026-10-04): **2.714 CoreMark/MHz** (+11.6 % from rv64gc's 2.432, as the simulation's +11.2 %), 1.460
DMIPS/MHz (+0.4 %). CoreMark +71 % and Dhrystone +77 % from before the work (1.584 / 0.823).

## 12. Sstc (2026-10-04, board)

`CPU_CORE_SPEC.md` decision 66. Linux writes `stimecmp` itself and no longer calls OpenSBI at every timer
(`dmesg`: `riscv-timer: Timer interrupt in S-mode is available via sstc extension`). WNS +0.381 ns after
place and route.

| | Zba / Zbb version | Sstc version | |
|---|---|---|---|
| CoreMark (rv64gc) | 2.432 /MHz | **2.469** | +1.5 % |
| CoreMark (Zba / Zbb) | 2.714 | **2.754** | +1.5 % |
| Dhrystone (Zba / Zbb) | 1.460 DMIPS/MHz | 1.482 | +1.5 % |
| `micro` loop without loads | 4.40 cycles | 4.34 | |

The core's logic is the same, so the gain is the OS's work. Each timer (100 per second) used to be: M-mode
timer interrupt → OpenSBI sets STIP → S-mode interrupt → Linux → asks OpenSBI for the next time with an
SBI ECALL → return. Now it is only the S-mode interrupt and a write of `stimecmp`. 1.5 % corresponds to
about 7,500 cycles each (1.5 % of 50 MHz / 100 Hz). CoreMark +74 % (Zba / Zbb version) and Dhrystone
+80 % from before the work (1.584 / 0.823).

## 13. The Sdtrig / Zicond / PMU version, and CoreMark on the board as the PMU sees it (2026-10-05)

`CPU_CORE_SPEC.md` decisions 67 to 69 (4 triggers, Zicond, `hpmcounter3` to `6` and 17 events, Sscofpmf,
Smcntrpmf). WNS +0.452 ns after place and route. OpenSBI shows `sscofpmf, zihpm, smcntrpmf, sdtrig`,
`MHPM Info: 4 (0x78)`, `Debug Triggers: 4`, and Linux `riscv-pmu-sbi: 16 firmware and 6 hardware
counters`.

The benchmarks are the same as the previous version (section 12) within noise (CoreMark 2.462 / 2.747,
Dhrystone 1.475 / 1.482). The added logic is not on the performance paths. The 0.3 % drop of CoreMark is
either the context switching of the kernel with `perf`, or measurement noise.

**CoreMark counted with the PMU on the board (Zba / Zbb version, `software/bench/perf.sh`).** The
breakdown that only the simulation's profiler could give before, counted as it is under Linux (the OS's
part included).

| | Value | |
|---|---|---|
| Cycles / instructions | 1,133.8 M / 999.9 M | **CPI 1.134** |
| Loads / stores | 171.5 / 46.2 | per 1000 instructions |
| Conditional branches / mispredictions (jumps included) | 182.1 / 13.0 | 7.2 % of conditional branches |
| I$ misses / D$ misses | 0.49 / 0.16 | per 1000 instructions |
| ITLB / DTLB misses (page table walks) | 0.002 / 0.06 | per 1000 instructions |
| Back end blocked | 5.57 % | of the cycles |
| of which load-use | 1.95 % | |
| of which MDU / FPU wait (the 1-cycle wait of multiply and so on) | 2.60 % | |
| of which D$ wait | 0.70 % | |
| Front end empty (refill after mispredictions, I$ misses) | 4.84 % | |

134 cycles are lost per 1000 instructions: back end 63, front end 55, and the remaining 16 the redirect
of mispredictions itself. One misprediction costs about 5 cycles of redirect and refill (from the front
end's share minus about 10 for I$ misses). Caches and TLBs hardly matter (CoreMark runs on about 2 KB of
data). The large remaining items are mispredictions, load-use and the multiply wait, which agrees with
the assessment of section 1 of `ROADMAP.md` (all a few % or less).

Cycles counted with an `hpmcounter` (`r1`, 1,132.9 M) agree with the fixed `cycle` (1,133.8 M in another
run) within 0.08 %. `perf record` took 12K samples on overflow interrupts (CoreMark 99.1 %, kernel
0.9 %).

## 14. Beyond CoreMark: counting Linux loads with the PMU (2026-10-06, board)

`software/bench/workload.sh` (`ROADMAP.md` D1). Each of 8 loads was run 5 times under `perf stat`,
counting 16 events and the user / kernel split (each event divided by the cycles and instructions of the
same run). I$ / D$ / ITLB / DTLB and exceptions are per 1000 instructions; D$ wait, front end empty, back
end blocked and load-use are shares of the cycles; mispredictions are a share of conditional branches
(jump mispredictions are in the numerator too, so it comes out high).

| Load | Mcyc | CPI | I$ | D$ | ITLB | DTLB | D$ wait | Front | Back | Load-use | Mispredict | Kernel |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| CoreMark (section 13) | 1,134 | 1.134 | 0.49 | 0.16 | 0.002 | 0.06 | 0.7 % | 4.8 % | 5.6 % | 2.0 % | 7.2 % | 1 % |
| `gunzip` (2 MB) | 260 | 1.353 | 0.80 | 3.46 | 0.016 | 7.91 | 11.7 % | 3.7 % | 21.5 % | 0.9 % | 12.9 % | 7 % |
| `md5sum` (4 MB) | 97 | 1.218 | 1.18 | 2.95 | 0.069 | 0.48 | 12.3 % | 3.6 % | 14.2 % | 0.3 % | 9.6 % | 19 % |
| `awk` (table of 5000 entries) | 1,013 | 1.671 | 1.46 | 3.44 | 2.66 | 14.03 | 8.3 % | 11.2 % | 26.5 % | 0.9 % | 33.3 % | 5 % |
| `ls -lR` | 24 | 3.079 | 31.94 | 15.06 | 3.49 | 11.40 | 21.4 % | 34.5 % | 30.5 % | 1.0 % | 39.0 % | 61 % |
| `ext4read` (8 MB) | 147 | 4.037 | 42.61 | 22.03 | 0.71 | 8.55 | 33.8 % | 33.2 % | 42.6 % | 1.1 % | 59.3 % | 99 % |
| `sdread` (16 MB) | 392 | 4.463 | 41.92 | 27.86 | 0.70 | 8.44 | 39.6 % | 29.2 % | 48.2 % | 0.9 % | 61.5 % | 100 % |
| `forkexec` (100 times) | 305 | 2.737 | 19.08 | 17.91 | 0.48 | 5.37 | 31.2 % | 23.4 % | 37.3 % | 1.2 % | 27.1 % | 76 % |
| `tftp` (3 MB) | 725 | 4.797 | 61.40 | 31.41 | 1.27 | 14.28 | 29.0 % | 39.4 % | 36.6 % | 0.8 % | 69.0 % | 94 % |

**Kernel-heavy loads (`ls`, `ext4read`, `sdread`, `forkexec`, `tftp`) spend 50 to 70 % of their cycles
waiting for the caches.** CPI 2.7 to 4.8. I$ misses are 19 to 61 per 1000 instructions and D$ misses 15
to 31 (40 to 130 times and 100 to 190 times CoreMark), and front end empty (almost all I$ misses) plus D$
wait come to 50 to 70 %. The kernel's code and data do not fit in the 16 KB L1. One miss is 30 to 50
cycles (`tftp`: front end empty 39.4 % ÷ I$ misses 61 ≈ 31, D$ wait 29.0 % ÷ D$ misses 31 ≈ 44). **An L2
cache** between the L1 and memory would help.

**User-mode loads (`gunzip`, `md5sum`, `awk`) have mostly enough cache, and too little TLB.** CPI 1.2 to
1.7, I$ misses 1.5 or fewer. DTLB misses (page table walks), on the other hand, are 7.9 for `gunzip` and
14.0 for `awk` (130 to 230 times CoreMark). The 8-entry DTLB overflows with pages scattered over input,
output, tables, stack and library data. What remains of the back end after D$ wait and load-use (waiting
for the walker, MDU / FPU and so on) is 9 to 17 %, which divided by the DTLB and ITLB misses gives about
15 cycles each. **A larger TLB (a second-level TLB)** would help.

**Streaming reads (`md5sum`)** have 12 % D$ wait. They are misses of lines read only once, so an L2 does
not reduce them; **next-line prefetch** does.

Mispredictions are high in the kernel (27 to 69 %) both because jumps (function returns, indirect calls)
are in the numerator and because the code is large and the BTB (256 entries) too small. That remains
even when the L2 reduces I$ misses.

**Estimate**: an L2 (hit about 12 cycles, 60 to 80 % of L1 misses hitting) would make kernel loads 20 to
30 % faster (about 30 % for `tftp`, about 20 % for `forkexec`). A second-level TLB would make user-mode
loads 5 to 15 % faster, and kernel loads a few %. CoreMark hardly changes with either.

## 15. L2 cache (2026-10-07, board)

The version with `RTL/CPU/CPU_L2` (256 KB, 4 ways, 64 B lines, write-back, `CPU_L2_SPEC.md`) between the
L1 and LiteDRAM. WNS +0.159 ns after place and route, LUT 46,957 (74.1 %), slices 91.4 %, block RAM
108.5 / 135 (section 32 of `TIMING.md`). In Linux, `perf list` shows `LLC-loads` / `LLC-load-misses`
(38,499 / 13,316 for `ls -lR /etc`, the same counts as `r12` / `r13`).

**`workload.sh`** (the same 8 loads as section 14; left is section 14 without the L2, right with the L2.
L2 is L2 reads per 1000 instructions = L1 fills, and the hit rate is 100 − L2m%):

| Load | Mcyc | CPI | Speed | I$ | D$ | D$ wait | Front | L2 reads | L2 hit rate | Kernel |
|---|---|---|---|---|---|---|---|---|---|---|
| `gunzip` | 260 → 243 | 1.353 → 1.263 | **1.07×** | 0.77 | 3.46 | 11.7 → 7.0 % | 3.7 → 2.9 % | 4.2 | 92 % | 5 % |
| `md5sum` | 97 → 91 | 1.218 → 1.145 | **1.07×** | 1.12 | 2.90 | 12.3 → 9.1 % | 3.6 → 1.9 % | 4.1 | 71 % | 15 % |
| `awk` | 1,013 → 974 | 1.671 → 1.608 | **1.04×** | 1.41 | 2.94 | 8.3 → 7.1 % | 11.2 → 9.6 % | 4.4 | 91 % | 3 % |
| `ls -lR` | 24 → 16 | 3.079 → 2.113 | **1.46×** | 31.4 | 15.2 | 21.4 → 15.8 % | 34.5 → 22.2 % | 46.3 | 90 % | 60 % |
| `ext4read` | 147 → 107 | 4.037 → 2.594 | **1.56×** | 43.3 | 23.2 | 33.8 → 30.7 % | 33.2 → 22.6 % | 70.0 | 95 % | 99 % |
| `sdread` | 392 → 259 | 4.463 → 2.968 | **1.50×** | 41.6 | 28.5 | 39.6 → 38.8 % | 29.2 → 20.0 % | 72.5 | 85 % | 99 % |
| `forkexec` | 305 → 250 | 2.737 → 2.257 | **1.21×** | 18.7 | 17.6 | 31.2 → 27.5 % | 23.4 → 19.2 % | 36.5 | 58 % | 72 % |
| `tftp` | 725 → 426 | 4.797 → 2.884 | **1.66×** | 61.0 | 30.4 | 29.0 → 22.0 % | 39.4 → 30.0 % | 96.4 | 90 % | 95 % |

(Speed is the ratio of CPI. The instruction counts agree within 3 % with and without the L2. Only for
`ext4read` did the instruction count change, 36 → 41 M (a difference in state after dropping the page
cache), so by cycles it is 1.37×. The numbers of I$ / D$ misses are the L1's, so the L2 does not change
them.)

**Kernel-heavy loads became 1.2 to 1.7 times faster**, beyond the estimate (section 1 of
`CPU_L2_SPEC.md`, 1.23 to 1.37 times): `tftp` 1.66×, `ext4read` 1.56×, `sdread` 1.50×, `ls` 1.46×. The
reason is that the L2 hit rate was **85 to 95 %**, higher than the estimated 60 to 80 % (the kernel's
code and frequently used data fit in 256 KB). The cost of one L1 miss (estimated as front end empty ÷ I$
misses, D$ wait ÷ D$ misses):

| | Without the L2 | With the L2 |
|---|---|---|
| One I$ miss (`ls` / `tftp` / `sdread`) | 31 to 33 cycles | **14 to 15 cycles** |
| One D$ miss (`ls` / `tftp`) | 44 cycles | **21 to 22 cycles** |
| One D$ miss (`sdread` / `ext4read`) | 62 to 63 cycles | 34 to 41 cycles |

I$ misses came down almost to an L2 hit (2 cycles from AR to the first beat + the L1's fill). The D$ wait
of `sdread` / `ext4read` hardly went down (38.8 %, 30.7 %). The SD card's DMA writes go through the D$
(write-through) and pass through the L2 to memory as partial writes, each waiting for memory's answer.
What remains is thought to be the D$ being blocked meanwhile (not confirmed). Catching the DMA writes in
the L2 (allocating whole lines, answering early) should reduce it (section 8 of `CPU_L2_SPEC.md`).

`forkexec` has a low hit rate, 58 %. Each fork and exec touches new pages (page tables, copied pages, the
new process's data), so many lines are touched for the first time. `md5sum` (71 %) is a stream read only
once, the kind prefetch reduces rather than an L2 (as section 14 assessed). The user-mode loads
(`gunzip`, `awk`) have few L1 misses and gain 1.04 to 1.07 times. What remains is the DTLB (7.9 to 15.6
per 1000 instructions), the territory of E3.

**`bench.sh` / `perf.sh`** (compared with the version of section 13):

| | Without the L2 | With the L2 | |
|---|---|---|---|
| CoreMark (rv64gc / Zba and Zbb) | 2.462 / 2.747 | **2.498 / 2.786** | +1.4 to 1.5 % |
| Dhrystone (rv64gc / Zba and Zbb) | 1.475 / 1.482 | 1.488 / 1.496 | +0.9 % |
| CoreMark CPI (`perf.sh`) | 1.134 | 1.118 | D$ wait 0.70 → 0.25 %, front end empty 4.84 → 3.99 % |
| `micro` dgemm 64×64 (double) | 20.9 cycles per multiply-add | **17.6** (5.69 MFLOPS) | 96 KB for the 3 matrices, fits in the L2 |
| `micro` dependent loads 8 MiB | 75 cycles | **62.6** | The page table reads hit in the L2 |
| `micro` read 8 MiB | 54 MB/s | 50.3 MB/s | Streams that miss the L2 are slower by the +3 cycles of a miss |
| `micro` dependent loads 8 KiB, bandwidth 8 KiB | 3.1 to 3.2 cycles, 151 MB/s | 3.1 cycles, 156 MB/s | Unchanged (inside the L1) |

CoreMark fits in the L1, so as expected it hardly changes (the OS's part and the fills right after
start-up got a little faster). dgemm getting 16 % faster is a number that changes the premise of
pipelining the FPU (C2): of the 17.6 cycles per multiply-add now, what remains after the memory waits is
the share of the unpipelined FPU.


## 16. Pipelining the FPU (C2, 2026-10-09, board)

The version with the core's `CORE_FPU` replaced by `FPU_PIPE` (`CPU_CORE_SPEC.md` 10.11, WNS +0.286 ns
after place and route, slices 89.0 %, section 33 of `TIMING.md`). Assembler kernels
(`software/bench/fpkern.S`) were added to `micro`, and `micro 50 fp` measures only the floating point
part.

**`micro` (cycles per multiply-add)**. SIM_SYS is the same kernels run by `SIM/SIM_SYS/bench/fploop.c`
(matrices 16×16, fitting in the D$). "Earlier version" is the same fploop run on the RTL before stage 2
(4cb3603):

| | Board (64×64 and so on) | SIM_SYS | SIM_SYS earlier version | Speed (SIM_SYS) |
|---|---|---|---|---|
| dgemm, assembler 4×4 | **4.05** (24.7 MFLOPS) | 2.18 | 11.19 | 5.1× |
| FIR 8 taps, assembler | **1.52** (65.7 MFLOPS) | 1.45 | 10.10 | 7.0× |
| Dot product, assembler | **3.66** (27.3 MFLOPS) | 3.66 | 12.81 | 3.5× |
| dgemm, C (`-O2`) | 18.6 → after the fix **16.6** (6.02 MFLOPS) | 17.60 → **15.67** | 16.73 | |

- **The FIR almost reached the goal of one a cycle** (1.52, 65.7 MFLOPS; 11.5 times the 5.69 MFLOPS of
  the C dgemm before stage 2. 64 multiply-adds plus 8 FLDs, 8 FSDs and 3 loop instructions make 83 ÷ 64 =
  1.30, the lower bound of issue). It fits in the D$ on the board too, so the same as SIM_SYS.
- **The dot product is set by its 2 FLDs per multiply-add** (3.66, the same on the board and in SIM_SYS).
- **The assembler dgemm is 4.05 on the board** (up from SIM_SYS's 2.18). The three 64×64 matrices (96 KB)
  do not fit in the D$ (16 KB), and every block of 4 columns walks all of B (32 KB), so the rows of B come
  from the L2 every time. 4.1 times the C version after the fix (16.6), 4.3 times the C version before
  stage 2 (17.6). To go faster, the next step is to cut B into panels that fit in the D$ (cache blocking),
  which is not an FPU matter.
- The results of the dot product and the FIR agree with C (`answers agree with C`). CoreMark 2.497 /
  2.785 (Zba and Zbb) and Dhrystone 1.489 / 1.497 are unchanged from section 15 (2.498 / 2.786, 1.488 /
  1.496). Bandwidth, dependent loads, misaligned loads and the 4-instruction loops are unchanged too.

**The C dgemm had become slower, 17.6 → 18.6 (a bug of stage 2, fixed)**. The inner loop is the 7
instructions `fld c; fld b; addi; addi; fmadd; fsd; bne`, and `fsd` waits in EX for the answer of
`fmadd`. The LSU issues accesses early from EX (`lsu_e_valid`), but its condition lacked "not waiting for
the FPU's answer", so the waiting `fsd` sent a request to the D$ with stale data. The request was taken
back in the next cycle (the answer was right), and then, through `ex_e_blocked`, it went **from MA, not
from EX**, 2 cycles after the answer was there. In the earlier version `fmadd` itself occupied EX, so
`fsd` never got to EX first, and this hole could not be seen. The trace showed one iteration 16 → 17
cycles (earlier version → stage 2), and 11 cycles from the retirement of `fmadd` to that of `fsd` (+2
against the 9 of an FP dependency). Adding `~fp_wait` to `lsu_e_valid` gives **15 cycles an iteration**,
and SIM_SYS's C dgemm goes 17.60 → 15.67 (faster than the earlier version's 16.73). **On the board too,
18.6 → 16.6** (16.7 expected), 6 % faster than before stage 2 (17.6 of section 15). With the fixed
bitstream (WNS +0.113 ns, section 34 of `TIMING.md`) `bench.sh` was run again: CoreMark 2.498 / 2.785,
Dhrystone 1.488 / 1.496, the assembler kernels (4.04 / 1.52 / 3.66) and the other values of `micro` are
the same as before the fix.

A bug that changes no answer and only loses cycles was seen by neither the tests nor bug injection.
`fploop` got a cycle bound per kernel (about 5 % above the present value), failing above it. SIM_SYS's
`bug_inject.sh` runs `fploop` too and detects the mutation that brings back this hole (M19).

**Cache blocking of the matrix multiply** (2026-10-09, `software/bench/fpkern.c`, SIM_SYS). `fpk_dgemm4`
walks all of B (32 KB at n = 64, twice the D$) for every 4 rows, so B comes from the L2 every time. B is
cut into panels of KC rows × NC columns kept in the D$, and the rows of A go past them 4 at a time:

- **The panel of B is packed**. The 4 values the kernel reads for one k are put in 32 bytes, which also
  removes conflicts in the sets.
- **A is not packed**. At first the 4 rows of A were packed too, but copying them one element at a time
  in C ran 4,096 elements × the number of panels, and instructions came to 2.03 per multiply-add (1.59
  for the kernel alone). Having the kernel read the 4 rows of A directly through 4 pointers (4 adds every
  2 k, about 0.1 per multiply-add) and calling it once for the whole width of the panel (`fpk_mm4xn`)
  brought it to 1.79.
- **What remains is D$ misses**. MA waits for the answer of a miss, so misses do not overlap with
  computation. A is read again for every panel of columns (n / NC times) and C for every panel of rows
  (n / KC times, read and written back). With the panel kept at 8 KB (half the D$), every way of cutting
  gives about the same number of misses.

| KC × NC (panel) | SIM_SYS, n = 64 |
|---|---|
| No blocking (`fpk_dgemm4`) | 3.25 |
| 32 × 32 (8 KB), the version that also packs A | 2.46 |
| **64 × 16 (8 KB)** | **2.23** |
| 32 × 32 (8 KB) | 2.24 |
| 16 × 64 (8 KB) | 2.46 |
| 64 × 20 / 24 (10 / 12 KB) | 2.30 |
| 64 × 28 / 32 (14 / 16 KB) | 2.39 / 2.46 |

64 × 16 was made the default (C is read and written only once). SIM_SYS's 3.25 → 2.23 is 1.46 times.

**Board (`micro 50 fp`)**:

| dgemm 64×64 | Per multiply-add | MFLOPS |
|---|---|---|
| C (`-O2`), before stage 2 (section 15) | 17.6 | 5.69 |
| C (`-O2`) | 16.6 | 6.04 |
| Assembler 4×4, no blocking | 4.01 | 24.9 |
| **Assembler, blocking** | **2.42** | **41.2** |

Blocking gives 1.66 times (more than SIM_SYS's 1.46: misses are heavier on the board, so cutting them
helps more). The difference of 0.19 from SIM_SYS's 2.23 is the difference in the weight of misses.
**7.2 times** the C dgemm before C2. 41 MFLOPS at 50 MHz is 70 % of the upper bound of the kernel (about
1.7) on this core, which can issue only one FLD or FMADD at a time. `fploop` gained a blocked 32×32
version (24 KB, not fitting in the D$, 2.40, bound 2.52).

## 17. CoreMark and Dhrystone with the most optimization (2026-10-09)

The values so far were built with `-O2` (and Zba / Zbb) to keep comparisons on equal terms. Next to them,
builds with the options that make this core fastest are measured too ("Most optimization" in
`software/bench/README.md`).

**How the options were chosen**: `SIM/SIM_SYS/bench/optsweep.sh` builds CoreMark (10 iterations) and
Dhrystone (500 runs) with 10 sets of options × rv64gc / Zba and Zbb, runs them in SIM_SYS and compares the
cycles. CoreMark's answer (`crcfinal` 0xfcaf) is the same for all. SIM_SYS's Dhrystone has simple
home-made string functions (the board has glibc), so its values are lower than the board's; what is
looked at is the order:

| Options | CoreMark/MHz | + Zba and Zbb | DMIPS/MHz | + Zba and Zbb |
|---|---|---|---|---|
| `-O2` (so far) | 2.558 | 2.845 | 1.282 | 1.288 |
| `-O3` | 2.673 | 2.986 | 1.297 | 1.300 |
| `-O3 -funroll-loops` | 2.669 | 2.991 | 1.312 | 1.324 |
| **sf** = `-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-{functions,jumps,loops}=4` | **2.739** | **3.084** | 1.314 | 1.276 |
| sf `-fipa-pta` | 2.736 | 3.085 | 1.291 | 1.324 |
| sf, alignment 8 | 2.726 | 3.085 | 1.265 | 1.296 |
| **sf `-mtune=sifive-7-series`** | 2.699 | 3.066 | **1.368** | **1.324** |
| `-O2 -flto` | 2.500 | 2.819 | *1.502* | *1.510* |
| `-O3 -flto` | 2.729 | 3.052 | 1.277 | 1.257 |
| sf `-flto` | 2.555 | 2.903 | 1.398 | 1.462 |

- **CoreMark: sf** (+7.1 % / +8.4 % from `-O2`). Unroll all loops, expand functions, align branch targets
  to 4 bytes. `-flto` is actually slower (its code is 26 KB against sf's 32 KB, smaller, so it is not the
  size of the I$; the reason was not investigated).
- **Dhrystone: sf + `-mtune=sifive-7-series`** (+6.7 % / +2.8 %). `-mtune` is the model for scheduling
  instructions, and the SiFive 7 series is in-order, one at a time, like this core (less effect in the Zba
  / Zbb version).
- **Dhrystone with `-O2 -flto` (+17 %) is outside the rules**. It breaks Dhrystone's rules (`dhrystone.h`:
  separate compilation, no procedure merging, other optimizations allowed if stated) by expanding
  procedures across the two files, so it is built separately as `dhrystone_lto` and labelled "off-rule"
  in the summary.

**Board** (2026-10-09, `bench.sh`, next to `-O2` on the same bitstream):

| | `-O2` | Most optimization | Difference | Difference in SIM_SYS |
|---|---|---|---|---|
| CoreMark/MHz (rv64gc) | 2.499 | **2.682** | +7.3 % | +7.1 % |
| CoreMark/MHz (Zba and Zbb) | 2.785 | **3.025** | +8.6 % | +8.4 % |
| DMIPS/MHz (rv64gc) | 1.490 | **1.536** | +3.1 % | +6.7 % |
| DMIPS/MHz (Zba and Zbb) | 1.501 | **1.542** | +2.7 % | +2.8 % |
| DMIPS/MHz, `-O2 -flto` (outside the rules, rv64gc / Zba and Zbb) | | 1.555 / 1.561 | +4.4 % / +4.0 % | +17 % |

- **CoreMark gains as the simulation said**, and with Zba and Zbb reaches **3.025 CoreMark/MHz** (151.2
  iterations/s). CoreMark does not call libc (except for timing), so the compiler options act on every
  instruction, and simulation and board agree.
- **Dhrystone gains less on the board**. The +17 % of `-flto` stays at +4 %. The board's Dhrystone spends
  part of its time in glibc's `strcpy` / `strcmp` (prebuilt, so the options do not act on them), while
  the simulation uses simple home-made string functions (built with the same options); that is thought to
  be why (not investigated). The `-O2` value also differs: 1.490 on the board against 1.282 in
  simulation.
- The highest Dhrystone within the rules is **1.536 / 1.542 DMIPS/MHz**.
- **Reproducibility**: run again after a reboot, CoreMark 2.497 / 2.787 / 2.681 / 3.020 and Dhrystone
  1.490 / 1.499 / 1.535 / 1.541 / 1.554 / 1.562; every value within 0.2 % of the first run.

## 18. What the memory waits are made of (M0, 2026-10-10, simulation)

M0 of `ROADMAP.md`: before choosing among M1 to M4, count which waits there are. Added for it
(`CPU_CORE_SPEC.md` decision 71):

- **PMU events 20 to 24**: MA waits for a store; MA waits while the D$ handles a miss; one / two or more
  line fills outstanding; MA waits while the D$ copies a dirty victim out. `software/bench/workload.sh`
  counts them on the board (two more runs per load, a second table "the memory waits").
- **The SIM_SYS profiler** (`make profile`, `make bench`): MA's waits by kind of access and per access
  (before the fill is asked for / while it is outstanding / after it), the distance from each retired load
  to the first instruction that reads its value (the retired instructions are decoded again by a copy of
  `CORE_DECOMP` + `CORE_DEC`), and how many fills are outstanding per cycle.

| | Cycles | MA waits | On a miss: loads / stores | Dirty victim copy | Missed loads used by the next 1 / 2 instructions | M4 could hide at most | 2 fills outstanding |
|---|---|---|---|---|---|---|---|
| CoreMark | 3,908,920 | 178 (0.005 %) | 0 / 129 | 0 | ― | ― | 27 cycles |
| Dhrystone | 221,979 | 0 | 0 / 0 | 0 | ― | ― | 0 |
| `t19_ldbench` (C, lists, sorting) | 56,954 | 1,336 (2.3 %) | 25 / 1,172 | 0 | 1 / 0 of 1 | 0 % | 26 cycles |
| `ldloop` (micro's loops, user mode) | 88,459 | 4,967 (5.6 %) | 4,335 / 294 | 1,830 | 13 / 341 of 355 | 7.5 % | 0 |
| `fploop` (FP kernels, dgemm) | 613,197 | 82,124 (13.4 %) | 28,378 / 41,550 | 22,040 | 16 / 587 of 2,803 | 38.7 % | 123 cycles |

"M4 could hide at most": of the cycles the missed loads waited, the part the instructions between the
load and the first use of its value could cover at one a cycle (an upper bound for stall on use).

**What it says**

1. **CoreMark and Dhrystone have no memory waits** (they fit in the L1). What M1 to M4 could gain has to
   be looked at on loads that do not fit: in simulation `fploop` and `ldloop`, on the board the Linux loads
   of section 14 (D$ wait 12 to 40 %) with the new events.
2. **The copy of a dirty victim is a large share**: in `fploop`, 22,040 of the 82,124 cycles of waiting
   (27 %), in `ldloop` 1,830 of 4,967 (37 %). With a dirty victim the fill engine of the D$ first copies the
   8 words of the victim into a writeback buffer (`F_WB_READ` → `F_WB_WAIT` → `F_WB_PUSH`, about 11 cycles)
   and only then asks for the new line. Asking first and copying while the fill is outstanding would hide
   it: the copy reads one word a cycle through the read port, the fill writes one beat a cycle through the
   write port, and the first beat comes at the earliest 2 cycles after the address, so the copy stays ahead.
   This is the cheapest overlap of all (candidate M5 of `ROADMAP.md`).
3. **Stores**: on misses they wait as long as loads (16 to 31 cycles each, write-allocate). In `fploop`
   they are 59 % of the waits on misses (writing C back), in `t19_ldbench` almost all of them. This is
   what M1 (store buffer) takes away.
4. **Missed loads are mostly used soon**: in `ldloop` 341 of 355 by the instruction 2 later (pointer
   chasing and sums), so M4 could hide at most 7.5 % of their waits. In `fploop` the matrix kernels load
   ahead, and up to 39 % could be hidden. M4 helps code that loads ahead; for code that uses the value at
   once, prefetch (M2 / M3) is what helps.
5. **Two misses at once are rare** (up to 0.02 % of the cycles), and **the bus takes one read at a time
   anyway**: the arbiter of `CPU_CACHE` keeps a read until its last beat, and the L2 takes one transaction
   at a time, so a second miss waits behind the first even though the D$ has 2 MSHRs. M3 / M4 would overlap
   misses with computation, not misses with each other; overlapping misses would also need the bus side.

The board numbers are in 18.1.

### 18.1 On the board (2026-10-10)

`workload.sh` with events 20 to 24 (bitstream of TIMING 36). The first table agrees with section 15 within
the noise (CPI `gunzip` 1.263 → 1.260, `ls` 2.113 → 2.118, `tftp` 2.884 → 2.900), and MA's waits counted in
two different runs agree (event 11: 6.6 / 9.1 / 16.4 / 38.3 % against 6.69 / 9.23 / 16.01 / 41.25 %).

| Load | MA waits | Stores | While a miss is handled | Dirty victim copy | Without a miss | Fill outstanding | Two outstanding | Front end empty |
|---|---|---|---|---|---|---|---|---|
| `gunzip` | 6.69 % | 1.48 % | 3.68 % | 0.52 % | 3.01 % | 4.54 % | 0.09 % | 2.9 % |
| `md5sum` | 9.23 % | 2.80 % | 5.13 % | 0.71 % | 4.10 % | 6.28 % | 0.12 % | 1.8 % |
| `awk` | 5.90 % | 1.32 % | 2.05 % | 0.36 % | 3.85 % | 3.00 % | 0.06 % | 9.7 % |
| `ls -lR` | 16.01 % | 4.89 % | 11.49 % | 2.00 % | 4.52 % | 29.88 % | 0.89 % | 22.0 % |
| `ext4read` | 32.35 % | 9.02 % | 14.59 % | 3.11 % | **17.76 %** | 34.19 % | 1.02 % | 23.0 % |
| `sdread` | 41.25 % | 13.46 % | 20.48 % | 3.68 % | **20.77 %** | 36.89 % | 0.96 % | 20.1 % |
| `forkexec` | 27.31 % | 10.72 % | 21.04 % | 3.07 % | 6.27 % | 36.35 % | 1.45 % | 19.1 % |
| `tftp` | 21.86 % | 5.71 % | 17.03 % | 3.40 % | 4.83 % | 46.10 % | 2.12 % | 30.1 % |

All are shares of the cycles; "without a miss" is MA's waits minus those while a miss is handled. The
columns overlap (a store that misses is in both "stores" and "while a miss is handled").

1. **Stores are 22 to 39 % of MA's waits, 1.3 to 13.5 % of the cycles** (`forkexec` 10.7 %, `sdread`
   13.5 %). They include store hits that wait, and all of them go away with a store buffer for the
   cacheable region (M1), short of it filling up. **The largest item on the core side.**
2. **The dirty victim copy is 0.4 to 3.7 % of the cycles** (6 to 16 % of MA's waits, less than the 27 to 37 %
   of the simulated kernels). M5 hides most of it, with a change to the D$ only.
3. **Waits without a miss**: 3 to 6 % in most loads (hits issued from MA that wait 2 to 3 cycles, stores,
   uncached accesses), but **18 to 21 % in `ext4read` / `sdread`**. These two are kernel loads that drive the
   SD card; the most likely cause is the driver reading the registers of LiteSDCard (uncached, through
   AXI4-Lite) while it waits for the card, that is time spent waiting for the device whatever the CPU does.
   Not checked (it needs the uncached accesses as an event of their own).
4. **Two fills outstanding: 0.06 to 2.1 % of the cycles**. The single-read bus costs at most that much now;
   it becomes a limit only with prefetch.
5. **The front end is as large as MA's waits in the kernel loads** (19 to 30 % of the cycles, I$ misses 19 to
   61 per 1000 instructions), and a fill is outstanding in 30 to 46 % of their cycles, mostly the I$'s. The
   L2 hit rate is high (86 to 95 % except `md5sum` and `forkexec`), so these are L2 hits of 14 to 22 cycles;
   a next-line prefetch for the I$ (in the I$ or the L2, M3) works on them, which no D$-side theme touches.
6. Missed loads: what is left of "while a miss is handled" after the stores (at least 0.7 to 11 % of the
   cycles, kernel loads at the top). In simulation most missed loads are used by the next 1 or 2
   instructions (section 18), so M4 would hide only part of it; prefetch fits better.

**For the order**: M5 (small, up to 3.7 %) → M1 (medium, up to 13.5 %) → prefetch (M2 for the code we write,
M3 in the L2 for the I$ and streams). M4 stays after them.

## 19. Asking for the fill before copying the dirty victim out (M5, 2026-10-10, simulation)

M5 of `ROADMAP.md`, the cheapest overlap M0 found (section 18). A miss whose victim is dirty now raises
the read address of its line in the same cycle the copy of the victim into the write-back buffer starts;
the copy reads a word a cycle through the read port while the fill writes its beats through the write
port (`CPU_CACHE_SPEC.md` 4.3). Only `DCACHE` changes.

| | Before | M5 | Difference |
|---|---|---|---|
| SIM_CACHE, 8 dirty evictions in a row (cycles per miss) | 22.0 | **12.7** | −42 % (a clean miss is 12.0) |
| `fploop` (cycles) | 613,197 | **594,887** | **−3.0 %** |
| `fploop`, MA's waits | 82,124 | 63,766 | −22 % |
| `fploop`, before the fill is asked for: loads / stores | 10,777 / 17,346 | 4,010 / 4,295 | |
| `ldloop` (user mode part, cycles) | 88,459 | **87,532** | **−1.0 %** |
| `ldloop`, MA's waits | 4,967 | 4,077 | −18 % |
| CoreMark | 3,908,920 | 3,908,920 | 0 (no dirty misses) |

What is left "before the fill is asked for" is the bus busy with another read and a write-back of the same
line (`f_ar_block`). On the board the copy was 0.4 to 3.7 % of the cycles of the Linux loads (18.1), so a
gain of that order is expected there; event 24 now counts the copy running alongside the fill, so it no
longer measures a wait of its own.

### 19.1 On the board (2026-10-10)

`workload.sh` on the bitstream of TIMING 37, against the run of 18.1 (M5 is the only change).

| Load | CPI, 18.1 → M5 | Change | Victim copy in 18.1 (the expected gain) | MA's waits, 18.1 → M5 |
|---|---|---|---|---|
| `gunzip` | 1.260 → 1.254 | −0.5 % | 0.52 % | 6.69 → 6.15 % |
| `md5sum` | 1.145 → 1.138 | −0.6 % | 0.71 % | 9.23 → 8.56 % |
| `awk` | 1.582 → 1.560 | −1.4 % | 0.36 % | 5.90 → 5.45 % |
| `ls -lR` | 2.118 → 2.069 | −2.3 % | 2.00 % | 16.01 → 14.87 % |
| `ext4read` | 2.533 → 2.469 | −2.5 % | 3.11 % | 32.35 → 31.02 % |
| `sdread` | 2.900 → 2.795 | **−3.6 %** | 3.68 % | 41.25 → 39.59 % |
| `forkexec` | 2.250 → 2.187 | −2.8 % | 3.07 % | 27.31 → 25.47 % |
| `tftp` | 2.900 → 2.792 | **−3.7 %** | 3.40 % | 21.86 → 19.55 % |

- **The gain is what M0 said it would be**: in every load the CPI went down by about the share of the cycles
  the victim copy took in 18.1 (0.5 to 3.7 %); the kernel loads gain most. MA's waits went down by 0.5 to
  2.3 points.
- `awk` gained more than its 0.36 % (−1.4 %); its D$ misses also changed (2.42 → 1.79 per 1000
  instructions) and so did its DTLB walks, which M5 does not touch, so this is mostly the run to run
  variation of `awk` (its table lands at other addresses).
- Event 24 ("victim%") stays about the same, as expected: it now counts the copy running alongside the
  fill, not a wait of its own.
- Stores are now the largest item of MA's waits that the core can do something about (1.4 to 12.9 % of the
  cycles): M1.

## 20. Not waiting for store misses (M1, 2026-10-10, simulation)

M1 of `ROADMAP.md`, done in the D$ only (`CPU_CACHE_SPEC.md` 4.3): a store miss below 4 GiB is answered
when the D$ accepts it, and later stores to the line being filled join it in a line-wide buffer of the
MSHR instead of waiting for the fill. The core is unchanged: it already waits in MA only until the answer.

| | M5 | M1 | Difference |
|---|---|---|---|
| SIM_CACHE, 8 store misses in a row (cycles per miss) | 12.0 | **10.6** | the fills, one at a time, are the limit |
| `fploop` (cycles) | 594,887 | **584,470** | **−1.75 %** |
| `fploop`, MA waits for stores: on a miss / without | 29,783 / 5,624 | 17,787 / 6,659 | −31 % in all |
| `t19_ldbench` (cycles) | 56,954 | **56,532** | −0.74 % |
| `t19_ldbench`, MA waits for stores: on a miss / without | 1,172 / 138 | 605 / 270 | −33 % |
| `ldloop` (user mode part) | 87,532 | 87,611 | +0.09 % (no store misses to speak of) |
| CoreMark | 3,908,920 | 3,908,847 | 0 |

**What is left of the store waits** (`fploop`, cycles MA waits for a store, by what the D$ is doing):

| Reason | Cycles | Note |
|---|---|---|
| The store's word has already been written by the fill | 6,782 | It waits for the end of the fill and runs again as a hit. Writing it into the array instead was tried: the beats come back to back, so the write port is never free before the fill ends |
| Not in the D$ yet (stage 1 busy, the victim copy holding the read port) | 6,486 | |
| Going this cycle / answered but behind older answers | 4,216 / 2,476 | The 1 to 2 cycles until the answer. Only the core could save these, by not waiting for the answer of an accepted store (the answers of the LSU would no longer all belong to MA; M1b, not done) |
| Others (the first cycle of a miss, the write port busy for a hit) | 4,355 | |

The gain is smaller than the store waits measured in M0 suggested, because a store that misses is mostly
followed by stores to the same line, which wait for the fill to pass their word anyway. On the board the
store waits were 1.4 to 12.9 % of the cycles; about a third of them going away would be 0.5 to 4 %.

### 20.1 On the board (2026-10-10)

`workload.sh` on the bitstream of TIMING 38, against 19.1 (M1 is the only change).

| Load | CPI, M5 → M1 | Change | MA waits for stores, M5 → M1 | Change |
|---|---|---|---|---|
| `gunzip` | 1.254 → 1.250 | −0.3 % | 1.38 → 0.99 % | −28 % |
| `md5sum` | 1.138 → 1.137 | −0.1 % | 2.77 → 2.52 % | −9 % |
| `awk` | 1.560 → 1.551 | −0.6 % | 1.35 → 1.14 % | −16 % |
| `ls -lR` | 2.069 → 2.057 | −0.6 % | 4.59 → 3.16 % | −31 % |
| `ext4read` | 2.469 → 2.503 | +1.4 % (*) | 8.75 → 7.25 % | −17 % |
| `sdread` | 2.795 → 2.725 | **−2.5 %** | 12.93 → 10.23 % | −21 % |
| `forkexec` | 2.187 → 2.123 | **−2.9 %** | 10.23 → 6.52 % | **−36 %** |
| `tftp` | 2.792 → 2.775 | −0.6 % | 5.52 → 3.42 % | −38 % |

- **The store waits went down by 9 to 38 %** (0.25 to 3.7 points of the cycles), in line with the −31 % of
  the simulation. The loads that gain most are those with the most store waits: `forkexec` (copying pages
  at fork, 3.7 points) −2.9 %, `sdread` −2.5 %.
- (*) `ext4read` got slower although its MA waits went down (31.02 → 30.04 %) and its back end too (40.9 →
  39.9 %). Its DTLB walks went from 8.2 to 14.2 per 1000 instructions, and those of `tftp` from 10.1 to 15.2;
  the DTLB numbers of these two loads have moved between 8 and 15 from run to run since section 14 (where the
  kernel puts the page cache and the buffers), which M1 does not touch. +6 walks per 1000 instructions at
  about 15 cycles each is +0.09 CPI, more than the +0.034 seen.
- Since M0 (18.1) the three themes together (M5, M1) gave 0.8 to 5.6 % on the Linux loads (`forkexec`
  2.250 → 2.123, −5.6 %; `sdread` 2.900 → 2.725, −6.0 %).

## 21. Next-line prefetch of the I$ (M3, 2026-10-11, simulation)

M3 of `ROADMAP.md`, the front end first: in the kernel loads of section 18.1 the front end is empty 19 to 30 %
of the cycles, mostly on I$ misses that hit in the L2 (about 13 cycles each), and no D$-side theme touches
that. A prefetch into the L2 would not help those; the line has to come closer.

**Measured first** (Linux boot to the shell prompt in SIM_BIOS, `+fillstat`): of 3.45 M I$ fills, 52.7 %
are the line after one of the last 4, mostly 16 to 63 cycles after it (the code runs through a line in
between); the front end is empty 6.7 % of the boot while an I$ fill is outstanding.

**Built** (`CPU_CACHE_SPEC.md` 4.2): after a miss of line X the I$ reads X+1 (same 4 KB page) into a
one-line buffer; a miss of it is served from there (also while it is still arriving) and asks for the next
line again; a miss of another line waits for the prefetch to leave the bus.

**Linux boot, prefetch off and on** (the boot is not a fixed amount of work: drivers poll and wait in WFI
for the SD card and the timers, so cycles are compared outside WFI):

| | Off | On |
|---|---|---|
| Instructions | 138.0 M | 131.6 M |
| Cycles outside WFI | 254.2 M | 239.8 M |
| **CPI outside WFI** | 1.842 | **1.822 (−1.1 %)** |
| Front end empty (of the cycles outside WFI) | 18.6 % | 17.9 % |
| Demand fills of the I$ | 3.45 M | 1.64 M |
| Prefetches / misses served from the buffer | ― | 3.03 M / 1.46 M (48 %) |

- **Half the misses are now served from the buffer, but the gain is small**: 1.46 M misses saved several
  cycles each (about 10 M cycles), the CPI shows about 2.6 M. The other half of the prefetches are not used,
  and each holds the single-read bus for a burst that a miss of the I$ or the D$ then waits behind (`BENCH.md`
  18 (5)).
- **Prefetching only after a miss that continues a sequence** (the line after the last miss, or the one the
  buffer held) was played against the demand fills of the boot: 46.7 % of its prefetches would be used
  against 46.8 % for every miss, with half as many prefetches. It is not more accurate, only covers less.
- So the prefetch stays as built (`IC_PREFETCH = 1`, 0 switches it off). What would make it pay better is
  the bus: a miss behind an unused prefetch should not wait for its whole burst (a second read in the L2 and
  the arbiter, or letting the demand go first), which is the same limit M0 found.

CoreMark and Dhrystone do not change (their code fits in the I$).

### 21.1 On the board (2026-10-11)

`workload.sh` on the bitstream of TIMING 39, against 20.1 (M3 is the only change). **On the board the
prefetch is a loss.**

| Load | CPI, M1 → M3 | Change | I$ fills / 1000 instr. | Front end empty | L2 reads / 1000 instr. | Prefetches / 1000 instr., used |
|---|---|---|---|---|---|---|
| `gunzip` | 1.250 → 1.251 | +0.1 % | 0.78 → 0.47 | 3.0 → 3.0 % | 4.23 → 4.67 | 0.76, 40 % |
| `md5sum` | 1.137 → 1.140 | +0.3 % | 1.11 → 0.71 | 2.0 → 2.1 % | 4.10 → 4.95 | 1.10, 37 % |
| `awk` | 1.551 → 1.557 | +0.4 % | 1.35 → 0.89 | 10.0 → 9.9 % | 4.35 → 4.88 | 1.37, 35 % |
| `ls -lR` | 2.057 → 2.089 | +1.6 % | 31.3 → 18.5 | 22.9 → 23.5 % | 46.2 → 64.7 | 30.8, 41 % |
| `ext4read` | 2.503 → 2.503 | 0 (*) | 43.3 → 24.0 | 24.2 → 24.5 % | 69.3 → 93.3 | 42.2, 46 % |
| `sdread` | 2.725 → 2.797 | +2.6 % | 41.2 → 22.9 | 21.7 → 21.7 % | 71.8 → 95.5 | 40.0, 46 % |
| `forkexec` | 2.123 → 2.167 | +2.1 % | 18.6 → 10.4 | 20.8 → 20.7 % | 36.0 → 46.2 | 18.2, 44 % |
| `tftp` | 2.775 → 2.886 | **+4.0 %** | 61.1 → 32.1 | 32.4 → 32.8 % | 96.5 → 129.3 | 59.4, 49 % |

- **The prefetch works as in the simulation**: 37 to 49 % of the prefetches serve a miss, and the demand
  fills of the I$ go down by exactly as many (`tftp`: 28.8 used per 1000 instructions, 29.0 fewer demand
  fills; the same within 0.1 for every kernel load, which also checks events 25 and 26 against event 7).
- **But the front end is not empty any less**, and the cycles it is empty per demand fill about double
  (front end empty cycles / demand fills: `tftp` 14.7 → 29.5, `sdread` 14.4 → 26.5, `forkexec` 23.8 → 43.0).
  The misses that are left are those where the code jumps to another line, and that is just when the
  prefetch of the line after the last miss has gone out: the jump's miss waits for its whole burst first.
- **The back end too**: the L2 reads go up by 29 to 40 % (the unused half of the prefetches), and the D$
  misses, which share the one read of the bus, wait longer (MA waits on a D$ miss, M1 → M3: `sdread` 16.75 →
  17.49 %, `forkexec` 18.02 → 18.91 %, `ext4read` 10.96 → 12.10 %; back end full `sdread` 45.5 → 47.0 %).
- (*) `ext4read` hides the same loss behind its DTLB walks, which went back from 14.2 to 8.0 per 1000
  instructions (the swing of 20.1).
- **Why the simulation showed a gain**: the memory model of SIM_BIOS answers at once, while the DDR3 of the
  board takes some tens of cycles for every L2 miss. An unused prefetch that misses in the L2 costs little
  in the simulation and a lot on the board; most of the kernel loads also miss in the I$ more than the boot (19 to
  61 against 25 per 1000 instructions).

So the next-line prefetch only pays if a demand miss does not have to wait for it: the read side of the bus
has to take a second read, or let a demand miss go first (the same limit as M0 and section 21). Until then
the prefetch is switched off (`IC_PREFETCH = 0`, the default since 2026-10-11; SIM_CACHE still tests it on).

### 21.2 The prefetch off, with T2 and T5 (2026-10-11, board)

`workload.sh` on the bitstream of TIMING 40: the prefetch switched off, and T2 / T5 (decisions 72 and 73 of
`CPU_CORE_SPEC.md`, which change no cycle count in SIM_CORE). Against 20.1 (M1), which it should equal:

| Load | CPI, M1 → this | Change | DTLB walks / 1000 instr. |
|---|---|---|---|
| `gunzip` | 1.250 → 1.268 | +1.4 % (*) | 7.92 → 7.93 |
| `md5sum` | 1.137 → 1.136 | −0.1 % | 0.62 → 0.47 |
| `awk` | 1.551 → 1.550 | −0.1 % | 13.49 → 14.02 |
| `ls -lR` | 2.057 → 2.049 | −0.4 % | 10.8 → 11.6 |
| `ext4read` | 2.503 → 2.455 | −1.9 % | 14.2 → 8.6 |
| `sdread` | 2.725 → 2.751 | +1.0 % | 8.2 → 9.0 |
| `forkexec` | 2.123 → 2.118 | −0.2 % | 5.97 → 5.12 |
| `tftp` | 2.775 → 2.768 | −0.3 % | 15.2 → 13.6 |

- The prefetch is off (events 25 and 26 are 0), and the losses of 21.1 are gone: the I$ fills, the front end
  and the L2 reads are back at the numbers of 20.1.
- The DTLB miss now waits in MR instead of EX at the same cost: `awk` (14 walks per 1000 instructions, the
  most of the user loads) is unchanged, and so is the back end of every load.
- (*) `gunzip` is the only load outside its range so far (1.250 to 1.263 since section 15), with every one of
  its columns (misses, walks, D$ wait, front end, back end, wrong guesses) the same as in 20.1, so no cause the
  counters can see; `ext4read` and `sdread` move with their DTLB walks, as since section 14.

On the bitstream of TIMING 41 (T4, first step, no change to any cycle count) the loads are the same again
(`gunzip` 1.268, `md5sum` 1.135, `ls` 2.048, `ext4read` 2.445, `sdread` 2.734, `forkexec` 2.116, `tftp` 2.757),
except `awk` 1.550 → 1.592 (+2.7 %). That is one disturbed run, not the design: `workload.sh` runs each load
once per group of events and takes the CPI from runs 1 to 4, and event `rb` (all of MA's waits) is counted in
two of them. For `awk` the two now disagree (run 2: 6.9 %, run 7: 5.5 %; they agreed within 0.1 before), and
the other columns of run 2 are up with it (back end 22.0 → 24.8 %); `gunzip`'s run 2 shows the same (7.2 against
5.9 %). Which of the kernel's activities hits a run is not seen by the counters of the load.

## 22. The read side of the bus (2026-10-12, simulation)

Item (4) of the findings of section 18 and of `ROADMAP.md`: the bus takes one read at a time, and the
prefetch of section 21 lost on the board for that reason. Before building a second read into the L2
(hit under miss), what it could gain was measured.

**First the simulation was made to see the board's memory.** SIM_BIOS's memory answered at once, which is
why the prefetch looked like a gain there (section 21) and was a loss on the board (21.1). The memory model
now takes `+rlat` cycles before the first beat of a read and `+blat` before a write's answer; from the board
(an I$ miss without the L2 took 31 to 33 cycles against 12 to 13 with the ideal memory, section 15) they are
set to 20 and 10. With that, the Linux boot (CPI outside WFI) shows the board's verdict on the prefetch:

| | Prefetch off | Prefetch on |
|---|---|---|
| Ideal memory (section 21) | 1.842 | 1.822 (−1.1 %) |
| `+rlat=20 +blat=10` | 1.957 | 1.981 (**+1.2 %**, as on the board) |

**What a second read could take** (prefetch off, `+fillstat`, 270.8 M cycles outside WFI): the cycles a fill of
the I$ or the D$ waits for the bus (`arvalid` without `arready`) and the core waits with it (front end empty /
MA waiting), by what is on the bus then:

| While | I$ | D$ | Of the cycles |
|---|---|---|---|
| (A) the L2 waits for memory, no beat of its fill yet | 0.14 M | 0.56 M | 0.26 % |
| (B) the other cache's beats are on their way | 0.32 M | 1.56 M | 0.69 % |
| (C) neither | 2.51 M | 2.33 M | **1.8 %** |

- A second read in the L2 (hit under miss) can only take (A): the channel from the L2 to the L1s carries one
  burst at a time, so (B) stays. **0.26 % is not worth reworking the L2**, and it is not dropped for lack of a
  better target.
- (C) was 1.6 cycles of every fill, and most of it the arbiter of `CPU_CACHE` itself: its grant is a flip-flop,
  so every read reached the L2 one cycle after it was raised.
- With the prefetch on, its cost is also not (A): the waits of the I$ behind its own prefetches grow by 2.6 M
  cycles, almost all of them while the prefetch's beats come from an L2 hit. Only a demand miss that can take
  the channel from a prefetch would help there.

**Built instead: the grant in the cycle of the request** (`FAST_READ` of `BUS_ARB`, set in `CPU_CACHE`). With
no read granted, the one that asks goes through in the same cycle (made from the `arvalid`s, the D$ first);
the grant flip-flop then holds it to the last beat as before. Both caches raise `arvalid` from a flip-flop,
so the new path is short.

| `+rlat=20 +blat=10` | Before | `FAST_READ` |
|---|---|---|
| Linux boot, CPI outside WFI, prefetch off | 1.957 | **1.904 (−2.7 %)** |
| Front end empty (of those cycles) | 19.8 % | 18.4 % |
| Fill waits that cost, (C) | 4.84 M | 2.20 M |
| Linux boot, prefetch on | 1.981 | 1.951 (still +2.5 % over off) |
| SIM_CACHE: I$ misses in a row (cycles each) | 13.0 | 11.0 |
| SIM_CACHE: D$ load misses / store misses in a row | 12.0 / 10.6 | 11.0 / 9.7 |

The prefetch stays off.

### 22.1 On the board (2026-10-12)

`workload.sh` on the bitstream of TIMING 42, against the run of TIMING 41 (21.2; `FAST_READ` is the only
change since).

| Load | CPI | Change | Front end empty | Fills outstanding (fill1%) |
|---|---|---|---|---|
| `gunzip` | 1.268 → 1.246 | −1.7 % | 2.8 → 3.0 % | 4.50 → 4.12 % |
| `md5sum` | 1.135 → 1.133 | −0.2 % | 1.9 → 1.8 % | 6.49 → 6.26 % |
| `awk` | 1.592 → 1.573 | (*) | 9.6 → 9.9 % | 3.03 → 2.82 % |
| `ls -lR` | 2.048 → 2.012 | −1.8 % | 23.3 → 22.4 % | 30.97 → 29.58 % |
| `ext4read` | 2.445 → 2.363 | **−3.4 %** | 24.4 → 23.2 % | 36.07 → 34.22 % |
| `sdread` | 2.734 → 2.678 | −2.0 % | 21.7 → 20.7 % | 39.97 → 37.99 % |
| `forkexec` | 2.116 → 2.080 | −1.7 % | 20.8 → 20.3 % | 39.20 → 38.19 % |
| `tftp` | 2.757 → 2.660 | **−3.5 %** | 32.4 → 30.7 % | 48.37 → 45.97 % |

- **The kernel loads gain 1.7 to 3.5 %**, as the Linux boot of the simulation with the board's latency
  predicted (−2.7 %): the more the I$ and D$ miss, the more cycles of grant were paid, and the front end and
  the time fills are outstanding go down with them. The user loads, which miss little, move by 0 to 2 %.
- (*) `awk` is still not a clean measurement: its D$ misses move between 1.8 and 3.0 per 1000 instructions
  from run to run since section 18, and its two counts of event `rb` disagree again (5.5 against 6.2 %).
- Since M0 (18.1) the memory themes (M5, M1, `FAST_READ`) took the kernel loads 5 to 9 % down (`tftp` 2.900 →
  2.660, −8.3 %; `sdread` 2.900 → 2.678, −7.7 %; `forkexec` 2.250 → 2.080, −7.6 %).

## 23. Zicboz and perf by function (F2, D2, 2026-10-12, board)

`workload.sh` and `perf.sh` on the bitstream of TIMING 43: T6 (no cycle changed), Zicboz (decision 76 of
`CPU_CORE_SPEC.md`; the device tree of the new `fw_jump.bin` names it, so Linux zeroes its pages with
`cbo.zero`), and `perf` with libelf (D2). Against 22.1:

| Load | CPI | Change | D$ fills / 1000 instr. | MA waits for stores | L2 reads / 1000 instr. |
|---|---|---|---|---|---|
| `gunzip` | 1.246 → 1.245 | −0.1 % | 3.55 → 3.40 | 0.99 → 0.94 % | 4.19 → 4.16 |
| `md5sum` | 1.133 → 1.133 | 0 | 2.92 → 2.99 | 2.54 → 2.42 % | 4.06 → 4.11 |
| `awk` | 1.573 → 1.545 | (*) | 2.60 → 1.89 | 1.36 → 1.77 % | 3.13 → 3.12 |
| `ls -lR` | 2.012 → 2.009 | −0.1 % | 15.13 → 15.11 | 3.23 → 2.74 % | 46.05 → 46.24 |
| `ext4read` | 2.363 → 2.370 | +0.3 % | 22.26 → 22.75 | 7.24 → 7.16 % | 68.56 → 69.07 |
| `sdread` | 2.678 → 2.657 | −0.8 % | 28.07 → 28.34 | 10.54 → 10.53 % | 72.33 → 72.58 |
| `forkexec` | 2.080 → 2.042 | **−1.8 %** | 17.84 → **16.29** | 6.53 → **3.34 %** | 36.32 → 34.72 |
| `tftp` | 2.660 → 2.701 | +1.5 % (**) | 31.23 → 31.66 | 3.39 → 3.38 % | 96.75 → 97.87 |

- **`forkexec` is where pages are zeroed**: its D$ fills went down by 9 % and its stores waiting in MA halved (the
  stores of the old `clear_page`, each a line read from memory first), 1.8 % on the CPI. The other loads zero few
  pages and stay within their range.
- (*) `awk` moves as in 21.2 and 22.1. (**) `tftp`'s DTLB walks went from 10.4 to 12.8 per 1000 instructions,
  the swing noted since section 14 (about +0.035 CPI at 15 cycles each, as much as the change).

**`perf` by function** (`perf.sh`): CoreMark's own functions (`core_bench_list` 22 %, `core_state_transition`
21 %, `matrix_mul_matrix_bitextract` 14 %, ...), and the kernel's under the fork / exec loop: `memcpy` 3.6 %,
`next_uptodate_folio` 3.4 %, `folio_add_file_rmap_ptes` 2.8 %, `handle_page_fault` 1.9 %, `filemap_map_pages`
1.9 %, ..., `clear_page` 1.3 % (now with `cbo.zero`), `crc32c` 0.7 % (F3 would do it with Zbc). BusyBox shows
addresses only: it is stripped. CoreMark on this bitstream: CPI 1.123 (1.134 in section 13).

## 24. Where the loads spend their cycles, by function (2026-10-12, board)

`sh workload.sh <server> profile` (perf with libelf, section 23): each load sampled once (r1 every 100,000
cycles). BusyBox is stripped, so the user-mode loads (`gunzip`, `awk`, `md5sum`'s own part) show addresses only.

| Load | First functions (% of its samples) |
|---|---|
| `md5sum` | the kernel's copy to user space 7.4 %, then BusyBox's MD5 |
| `ls -lR` | **`crc32c` 5.0 %** (and `ext4_inode_csum` 0.6 %: ext4 checks the checksums of its directory blocks and inodes), `link_path_walk` 3.9 %, `kmem_cache_free` 3.3 % |
| `ext4read` | `queue_work_on` 17.5 % (*), the SD card driver (`litex_mmc_send_cmd` 3.4 %, `litex_mmc_request` 2.5 %), `memcpy_fromio` 1.1 % |
| `sdread` | **the kernel's copy to user space 22.3 %**, `queue_work_on` 11.8 % (*) |
| `forkexec` | `memcpy` 4.6 %, `next_uptodate_folio` 2.9 %, ..., `clear_page` 1.2 %, `crc32c` 0.4 % |
| `tftp` | **`liteeth_start_xmit` 9.8 %** (it copies each packet into the SRAM of LiteEth with `memcpy_toio`, uncached), the copy to user space 4.7 %, `do_csum` 2.0 % (the IP checksum) |

- (*) Samples are taken by the overflow interrupt, which waits while interrupts are off; they land on the
  instruction that turns them back on (`queue_work_on`, `_raw_spin_unlock_irq(restore)`, `finish_task_switch`).
  These functions stand for the time spent with interrupts off before them, not for themselves.
- The copy to user space is `fallback_scalar_usercopy_sum_enabled` (`arch/riscv/lib/uaccess.S`, the scalar copy
  loop the kernel takes without the vector extension).
- **Zbc (F3)** would speed `crc32c` up (the kernel computes it with `clmul` when it has Zbc,
  `lib/crc/riscv`): 5 % of `ls`, under 0.5 % of the others. `do_csum` of `tftp` is not a CRC.
- **Larger targets** show up instead: the copy to user space (22 % of `sdread`, 7 % of `md5sum`, 5 % of `tftp`;
  `memcpy` 4.6 % of `forkexec`), where every line of the destination is read from the L2 or memory first and
  then overwritten, and the uncached writes of the drivers (`liteeth_start_xmit` 10 % of `tftp`), each of which
  waits for the answer of the peripheral bus.

## 25. Zbc and Zbs (F3, F1, T7, 2026-10-12, board, Rev.01)

`workload.sh` and `workload.sh profile` on the bitstream of TIMING 44: Zbc (`clmul` in the MDU, an answer in 5
cycles), Zbs and T7 (no cycle changed), with a new `fw_jump.bin` whose device tree names `zbc` and `zbs`.
Against 23:

| Load | CPI | Change | Note |
|---|---|---|---|
| `gunzip` | 1.245 → 1.245 | 0 | |
| `md5sum` | 1.133 → 1.131 | −0.2 % | |
| `awk` | 1.545 → 1.598 | (*) | |
| `ls -lR` | 2.009 → 2.046 | +1.8 % (**) | the instructions about −5 %, the cycles about −3 % |
| `ext4read` | 2.370 → 2.361 | −0.4 % | |
| `sdread` | 2.657 → 2.646 | −0.4 % | |
| `forkexec` | 2.042 → 2.040 | −0.1 % | |
| `tftp` | 2.701 → 2.688 | −0.5 % | DTLB walks 12.8 → 10.0 per 1000 instructions (the swing of 23) |

- (**) **`ls -lR` does the same work with fewer instructions**: the kernel computes `crc32c` with `clmul`
  (`crc32_lsb_clmul`) instead of a table, so its CPI is not the measure. Everything that is counted per 1000
  instructions and does not depend on the CRC went up by about 5 %: the exceptions (system calls and page
  faults, the same in every run) 0.115 → 0.121, the ITLB walks 3.51 → 3.68, the I$ fills 31.3 → 33.3. So the
  instructions went down by about 5 % and the cycles by about 3 % (×1.018 / 1.05), the kernel's share 58.7 →
  57.4 %. (`Mcyc` is rounded: 15 in both; the raw counts are in `/tmp/workload.log`.) The MDU's waits went 0.4 →
  0.8 % of the cycles, `clmul` being 5 cycles.
- **The profile agrees**: the CRCs of `ls` are 5.5 → 3.9 % of its samples (`crc32_lsb_clmul` 2.4 %, the
  `crc32c` wrapper 0.5 %, `ext4_inode_csum(_set)` 1.0 %), those of `forkexec` 0.4 → 0.2 %. `ls` has about 200
  samples (0.49 % each), so these are rough.
- (*) `awk` takes one of its two values (1.545 / 1.598 since 21.2, DTLB walks 13.5 / 14.0 per 1000 instructions
  by where its pages land). The other loads have no CRC, and stay where they were.
- Zbs: the kernel's configuration does not use it yet (nothing in the profile). It completes the B extension
  for programs built with `-march=rv64gc_zba_zbb_zbs`.
- **What is left by function** (`profile`): the copy to user space (`fallback_scalar_usercopy_sum_enabled`)
  21.1 % of `sdread`, 6.6 % of `md5sum`, 3.6 % of `tftp`; `liteeth_start_xmit` 10.7 % of `tftp`; `memcpy` 4.2 % of
  `forkexec`. These are the next themes (W1 and W2 of `ROADMAP.md`).

## 26. The page table walks, with the TLBs at other sizes (E3a, 2026-10-17, simulation)

E3a of `ROADMAP.md`: three new events (decision 79 of `CPU_CORE_SPEC.md`: 27 / 28 the cycles the walker works
for the DTLB / ITLB, 29 the cycles MR waits for the DTLB) and `make linux-tlb ITLB=.. DTLB=..` of SIM_BIOS,
which boots Linux from the SD card model with the TLBs at other sizes and runs small versions of the user-mode
loads of `workload.sh` under `perf stat` (`sim_tlb.sh`: `gunzip` of 256 KB of `Image`, `awk` over 20,000
iterations, `md5sum` of 256 KB). Change of the cycles against the 8 entries of today:

| Load | DTLB entries (ITLB 8) | Cycles | DTLB walks / 1000 instr. | MR waits for the DTLB |
|---|---|---|---|---|
| `gunzip` | 8 | 33.96 M | 7.62 | 8.5 % |
| | 16 | **−9.8 %** | 0.34 | 0.7 % |
| | 32 | −10.3 % | 0.11 | 0.3 % |
| | 64 | −10.6 % | 0.06 | 0.2 % |
| `awk` | 8 | 198.4 M | 15.49 | 14.4 % |
| | 16 | **−14.2 %** | 3.18 | 4.2 % |
| | 32 | **−17.7 %** | 0.16 | 0.9 % |
| | 64 | −17.4 % | 0.04 | 0.7 % |
| | 32, ITLB 32 too | **−20.0 %** | 0.15 | 0.3 % |

- **The simulation sees the board's walks**: with 8 entries `gunzip` walks 7.6 times and `awk` 15.5 times per 1000
  instructions, against 7.9 and 14.0 on the board (section 14).
- **16 entries take 95 % of the walks of `gunzip` and 80 % of those of `awk`, 32 entries 98 to 99 %.** The cycles
  saved are more than MR waited for the DTLB (8.5 % / 14.4 %): the reads of the walks also took lines of the D$
  and of the L2. A walk took 11 cycles with 8 entries (its reads hit in the caches) and 20 to 25 with more (the
  few walks left miss in them).
- `awk` also gains from a larger ITLB (2.8 walks per 1000 instructions with 8 entries: −17.7 → −20.0 %).
- `md5sum` (12 M cycles) is too short here: its instruction count moves between runs (7.6 to 8.2 M) and its walks
  are few (2.1 per 1000 instructions with 8 entries).
- These runs have no memory latency model (`+rlat` / `+blat`, section 22), so a walk that misses in the caches
  costs less than on the board: the gains are a lower bound.
- **For E3b**: a DTLB of 16 entries takes most of it for `gunzip`, `awk` wants 32 or a second level. The DTLB's
  compare is on the worst path (TIMING 44), so a larger first level has to be checked in synthesis; a second
  level of 64 entries keeps the compare as it is and costs a cycle or two on a miss of the first.

### 26.1 On the board: a DTLB of 16 entries (2026-10-17)

`workload.sh` (run 8, with the events 27 to 29) on the bitstream of TIMING 45: the DTLB of 16 entries
(decision 80). Against 25 (Rev.01, 8 entries); the DTLB walks of 8 entries are those of section 14 (the table
has not changed size since), `tftp`'s of section 25:

| Load | CPI | Change | DTLB walks / 1000 instr. | MR waits for the DTLB | Walker for the DTLB / ITLB |
|---|---|---|---|---|---|
| `gunzip` | 1.245 → 1.108 | **−11.0 %** | 7.91 → 0.22 | 0.4 % | 0.4 / 0.0 % |
| `md5sum` | 1.131 → 1.129 | −0.2 % | 0.48 → 0.34 | 0.6 % | 0.5 / 0.1 % |
| `awk` | 1.598 → 1.363 | **−14.7 %** (*) | 14.03 → 3.41 | 4.1 % | 2.7 / 2.2 % |
| `ls -lR` | 2.046 → 1.926 | **−5.9 %** | 11.40 → 4.28 | 4.2 % | 3.3 / 2.4 % |
| `ext4read` | 2.361 → 2.275 | −3.6 % | 8.55 → 2.06 | 2.6 % | 2.0 / 0.3 % |
| `sdread` | 2.646 → 2.566 | −3.0 % | 8.44 → 2.03 | 2.3 % | 1.8 / 0.2 % |
| `forkexec` | 2.040 → 1.995 | −2.2 % | 5.37 → 1.90 | 2.2 % | 1.8 / 0.4 % |
| `tftp` | 2.688 → 2.581 | −4.0 % | 10.0 → 4.55 | 4.1 % | 3.4 / 0.8 % |

- **The simulation was right, and a little low**: `gunzip` −11.0 % on the board against −9.8 % in section 26,
  `awk` −14.7 % against −14.2 % (its walks 3.41 against 3.18 per 1000 instructions, MR's waits 4.1 % against
  4.2 %). The memory of the board is slower than the model, so a walk saved is worth more there.
- (*) `awk` against its slower value of 25 (1.598); against the faster one (1.545) −11.8 %. The two values came
  from the walks (13.5 / 14.0 per 1000 instructions, by where its pages land); with 16 entries there is only one
  so far.
- **The kernel loads gain 2 to 6 %**: their walks fell by 55 to 78 %. `md5sum` had few walks to begin with.
- **What is left of the walks** (the upper bound of a larger TLB): MR waits for the DTLB 4.1 to 4.2 % of the
  cycles of `awk`, `ls` and `tftp`, 2.2 to 2.6 % of the other kernel loads, under 1 % of `gunzip` and `md5sum`;
  the walker works for the ITLB 2.2 to 2.4 % of `awk` and `ls`. A walk takes 11 to 12 cycles in `awk` (its page
  tables stay in the caches) and 15 to 22 in the kernel loads.

### 26.2 What a larger TLB would add to 16 entries (2026-10-17, simulation)

`make linux-tlb` as in 26, against the DTLB of 16 and the ITLB of 8 of today (`md5sum` left out, as in 26):

| ITLB / DTLB | `gunzip` | `awk` | `awk`: ITLB / DTLB walks per 1000 instr. | `awk`: MR waits for the DTLB |
|---|---|---|---|---|
| 8 / 16 (today) | 30.64 M | 170.3 M | 2.83 / 3.18 | 4.2 % |
| 16 / 16 | 0 | −1.6 % | 0.72 / 3.37 | 3.9 % |
| 8 / 32 | −0.5 % | −4.1 % | 2.83 / 0.16 | 0.9 % |
| **16 / 32** | −0.5 % | **−6.0 %** | 0.72 / 0.16 | 0.4 % |
| 32 / 32 | −0.5 % | −6.8 % | 0.00 / 0.16 | 0.3 % |

- **`gunzip` has nothing left** (−0.5 % at most). The rest is `awk` and, by their MR waits on the board (26.1),
  `ls -lR` and `tftp` (4 %), less the other kernel loads (2 to 2.6 %).
- **ITLB 16 + DTLB 32 takes 88 % of what is left in `awk`**; 32 / 32 adds 0.8 %. On the board this would be
  about −6 % for `awk` (the board has gained a little more than the simulation, 26.1) and, if the kernel loads
  lose their MR waits as `awk` does, 2 to 4 % for them.
- A second level (E3b) could not take more than this: what is left after 16 / 32 is under 0.5 % of the cycles.
  The question is only whether the first levels of 16 / 32 entries fit the timing (TIMING 45: the DTLB's own path
  has more than +0.83 ns) and the slices (87.9 %; the 8 entries of TIMING 45 took +274, so the 24 more about +800, to about 93 %).

### 26.3 On the board: an ITLB of 16 and a DTLB of 32 entries (2026-10-17)

`workload.sh` on the bitstream of TIMING 46 (decision 81). Against 26.1 (ITLB 8, DTLB 16) and 25 (Rev.01, 8 / 8):

| Load | CPI | Change from 26.1 | From Rev.01 | ITLB / DTLB walks per 1000 instr. | MR waits for the DTLB |
|---|---|---|---|---|---|
| `gunzip` | 1.108 → 1.103 | −0.5 % | **−11.4 %** | 0.007 / 0.05 | 0.4 → 0.1 % |
| `md5sum` | 1.129 → 1.120 | −0.8 % | −1.0 % | 0.006 / 0.03 | 0.6 → 0.1 % |
| `awk` | 1.363 → 1.271 | **−6.7 %** | **−20.5 %** | 0.19 / 0.14 | 4.1 → 0.3 % |
| `ls -lR` | 1.926 → 1.865 | **−3.2 %** | **−8.8 %** | 1.78 / 2.24 | 4.2 → 2.4 % |
| `ext4read` | 2.275 → 2.227 | −2.1 % | −5.7 % | 0.74 / 0.57 | 2.6 → 1.1 % |
| `sdread` | 2.566 → 2.521 | −1.8 % | −4.7 % | 0.72 / 0.65 | 2.3 → 1.1 % |
| `forkexec` | 1.995 → 1.970 | −1.3 % | −3.4 % | 0.29 / 0.82 | 2.2 → 1.3 % |
| `tftp` | 2.581 → 2.522 | −2.3 % | −6.2 % | 0.62 / 2.02 | 4.1 → 3.0 % |

- **`awk` as the simulation said, a little better** (−6.7 % against −6.0 % in 26.2): its walks fell from 2.66 /
  3.41 to 0.19 / 0.14 per 1000 instructions, MR's waits 4.1 → 0.3 %, and with them the D$ fills (2.78 → 1.66,
  the walks' reads gone) and the back end full (11.3 → 7.1 %).
- **The kernel loads gain 1.3 to 3.2 %**, `ls -lR` the most (its ITLB walks 3.68 → 1.78). What is left of the
  TLBs is now 1 to 3 % of their cycles (`ls` and `tftp`: they touch many pages once, which no TLB keeps).
- **E3 is done**: from Rev.01, `awk` −20.5 %, `gunzip` −11.4 %, the kernel loads −3.4 to −8.8 %, for parameters
  only. The price is the timing margin (TIMING 46: +0.065 ns).
