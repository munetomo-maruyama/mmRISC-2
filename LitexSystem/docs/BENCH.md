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
