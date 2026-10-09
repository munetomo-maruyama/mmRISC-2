# SIM_CORE — verification of the CPU core alone

[日本語](README_J.md)

An environment that runs `RTL/CPU/CPU_CORE` on its own. In place of the real caches it connects
`CORE_MEM_MODEL.sv` (a memory model that speaks the protocol of the cache ports) and runs assembler
tests and the official riscv-tests. The CLINT (`RTL/CPU/CPU_CLINT`) sits next to the model and appears
at its proper address.

Addresses:

| Range | Contents |
|---|---|
| 0x8000_0000 + 64KiB | Memory (program and data) |
| 0x0200_0000 + 64KiB | CLINT |
| 0x0300_0000 | Testbench register. bit0 is the external interrupt line |
| Anything else | No response = access fault |

The specification is in 12.3 and 12.4 of [`../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md).

## Usage

| Command | What it does |
|---|---|
| `make` | Builds the test programs and runs them all (Verilator) |
| `make TEST=t03_ldst run` | Runs one only |
| `make stress` | Runs them all with back pressure on both cache ports (ready dropped in 40 % of the cycles) |
| `make trace` | Runs one with a retirement trace |
| `make wave` | Writes a VCD |
| `make iverilog` | The same tests on Icarus Verilog |
| `make mdu` | Checks `CORE_MDU` against a reference model (`tb_MDU.sv`, 200,000 operations by default): boundary operands, cycle counts (1 for MUL / MULW, 2 for the MULH family), answers taken late, kills midway. What a program cannot choose |
| `make clint` | Drives `CPU_CLINT` directly in a 4-hart configuration (`tb_CLINT.sv`). Checks the parts of the register map a single-core program cannot reach |
| `make plic` | Drives the register port of `CPU_PLIC` directly (`tb_PLIC.sv`) |
| `make riscv-tests` | The official riscv-tests (rv64ui / um / ua / uc / uf / ud / uzba / uzbb / uzicond / mi / si). `RVTESTS` gives the location of the repository |
| `make riscv-tests-v` | The same tests in the virtual memory environment (`-v`, running under Sv39 while pages are allocated) |
| `make bugs` / `./bug_inject.sh` | Bug injection, 315 mutations (judged both with and without back pressure. M211 to M231 are debug mode, M298 to M314 triggers, M320 to M340 performance counters, M341 to M358 the connection of the pipelined FPU and the register files, M240 and later the early issue from EX. Mutations of `CORE_MDU` are also judged with `tb_MDU`) |
| `make lint` | Verilator lint |

Plusargs:

| Argument | Meaning |
|---|---|
| `+hex=<file>` `+name=<name>` | Program image and test name |
| `+tohost=<addr>` | Address of tohost (default 0x8000_2000; taken from the ELF for riscv-tests) |
| `+trace` | Prints retired instructions (PC, instruction word, register written) and traps |
| `+dtrace` | Prints requests / responses of the data port |
| `+ftrace` | Prints the operations handed to the FPU, with format, rounding mode and operands |
| `+istall=<n>` `+dstall=<n>` | Drops `ready` of the instruction / data port in about n % of the cycles |
| `+maxcycles=<n>` | Watchdog (default 200000) |

## Test programs

`tests/*.S` are assembled with `/opt/riscv/bin/riscv64-unknown-elf-gcc`. The default is
`-march=rv64ima_zicsr_zifencei` (no C), because knowing the width of every instruction makes it easier
to write handlers that "skip the trapping instruction by adding 4". Only the compressed instruction test
`t08_rvc` is built with C, through `MARCH_t08_rvc`. The official riscv-tests are all built with C, so
they are the tests of mixed instruction streams. `tests/link.ld` puts `.text` at 0x8000_0000, `.data` at
0x8000_1000 and `.tohost` at 0x8000_2000.

With the same convention as riscv-tests, writing 1 to `tohost` passes and writing `(check number << 1) |
1` fails. The testbench picks up `tohost` from the store channel and ends the test as soon as something
other than 0 is written (the program may loop forever after that). The frame (`tests/test.h`) uses gp
(x3), t0 (x5) and t6 (x31), so the body of a test must use only x10 to x30. `TEST_INIT` installs the
default trap handler. An unexpected trap is reported as `64 + cause`, and the testbench then prints the
cause, `mepc` and `mtval`.

| Test | Contents |
|---|---|
| `t01_alu` | Immediate and register operations, shifts, LUI/AUIPC, the 32-bit forms, signed / unsigned compares |
| `t02_branch` | The 6 branches, JAL/JALR, loops, forward and backward jumps |
| `t03_ldst` | Loads / stores of all sizes, sign / zero extension, byte lanes, negative offsets |
| `t04_hazard` | Forwarding, load-use, store data, operands held during a stall |
| `t05_csr` | CSR instructions, WARL fields, exactness of the counters, illegal CSR accesses |
| `t06_irq` | CLINT (timer / software / external), masks, WFI, vectored mtvec |
| `t07_trap` | Bus access faults, misalignment, `mtval`/`mepc`, suppression of the instructions behind a trap, the `minstret` count across a trap (thrown-away instructions do not retire) |
| `t08_rvc` | Compressed instructions, 32-bit instructions across a word boundary, branches into the middle of a word, illegal compressed instructions |
| `t09_muldiv` | Signs of multiply / divide, divide by zero, overflow, the 32-bit forms |
| `t10_atomic` | LR/SC and all AMOs, 32/64 bit, misaligned |
| `t11_fp` | `mstatus.FS`, NaN-boxing, `fcsr` / rounding modes, the data source of FP stores, hazards between the FPU and other units |
| `t12_priv` | S / U modes, delegation, SRET. The path M → S → U and back, delegation of interrupts, TVM / TW / TSR of `mstatus` (the official rv64si does not go as far as U mode) |
| `t13_pmp` | That PMP really stops accesses: lower numbered entries win, M passes through unlocked entries and obeys locked ones, R / W / X are told apart |
| `t14_mmu` | Sv39: three-level translation with hand-made page tables, permission bits, `SFENCE.VMA` |
| `t15_plic` | The PLIC from a program: raise a line → external interrupt → claim / complete in the handler → return |
| `t16_bench` | For measurement (3 loops that exercise the front end). In bug injection it checks that the predictor works, through the cycle count of BENCH_LIMIT |
| `t17_btb` | Wrong fetches of the branch predictor: the fetch unit gets back the instructions the prediction threw away |
| `t18_asid` | Predictions left behind by another address space (the BTB is not cleared when `satp` changes). Whatever the prediction says, the instruction that is there is executed |
| `t19_ldbench` | Load / store measurement written in C (`t19_ldbench.c`) |
| `t20_ptw_pmp` | When PMP refuses a page table read, the result is an access fault of the access's kind, not a page fault |
| `t21_satp` | Turns the MMU on from S mode the way Linux does (moving to the virtual address through the instruction page fault right after writing `satp`) |
| `t22_mip_seip` | While the PLIC's S line is up, `csrs` / `csrc mip` do not leak into the software SEIP (decision 51) |
| `t23_debug` | Debug mode. A debugger inside the testbench (the debugger of `tb_CORE.sv`) drives the core's `dbg_*` in place of the DM and checks halt right after reset, halt and step in a loop, EBREAK, reading and writing GPR/FPR/CSR (32-bit writes, errors), step with an interrupt pending, step over ECALL, halt during WFI, resume into U mode, and the debugger's triggers (an execute trigger and a load trigger with dmode and action 1, in U mode: they stop before the instruction or load, set hit and do not trap, and the program cannot rewrite them). The debugger runs only for this test name |
| `t24_predict` | Branch prediction (the tail entry of a 32-bit branch across a word, not using the tail in a word jumped into, the return address stack, a branch taken every other time — half of them mispredicted without gshare's history). A misprediction does not change the result, so the time is compared with a reference in the same run that does not rely on prediction, and more than 1.25 times fails |
| `t25_lsu` | Requests issued early from EX (`CPU_CORE_SPEC.md` 5.4): a load behind a store that was taken back, answers in flight at a trap, a PLIC claim behind a trap (an I/O load with side effects waits for the instruction in front to be final), a store the handler skips |
| `t26_late` | Conditional branches on the value of a load (the "late branch" decided in MR, `CPU_CORE_SPEC.md` decision 64): 6 compares × load as rs1 / rs2 / both, prediction right and wrong in both directions, that the store, faulting load, divide or CSR write in EX at a misprediction leaves nothing behind, a branch right behind a late branch, that the trap wins when the load faults, the timing of a loop branch waiting behind a late branch (without waiting the BTB does not learn), jalr to a loaded address (which waits in EX) |
| `t27_fence` | FENCE (`CPU_CORE_SPEC.md` 5.3): all encodings (`fence.tso`, `pause`, ones with reserved fields set neither trap nor write rd), right behind stores, uncached stores / loads, at the head of a trap handler while the answer of a load is being thrown away. The testbench checks every time that a FENCE does not go before the accesses in front of it are done |
| `t28_bitmanip` | Checks Zba / Zbb (`CPU_CORE_SPEC.md` decision 65) against a Python model (generated by `tools/gen_t28.py`; do not edit by hand). For each of 47 instructions / immediates it runs the pairs of 8 edge values and 32 xorshift64 pairs and compares a checksum folding the results by rotate, xor and multiply. Encodings next to the new ones (PACKW, undefined unary operations, Zbs) stay illegal |
| `t29_sstc` | Sstc and the CSRs of privileged spec 1.12 (`CPU_CORE_SPEC.md` decision 66): the implemented fields of `menvcfg` / `senvcfg` / `mcountinhibit`, CY / IR stopping the counters, STCE deciding whether `mip.STIP` is a writable bit or a comparison, `stimecmp` from S needing both STCE and `mcounteren.TM`, taking the S timer interrupt from `stimecmp` in S mode |
| `t30_trig` | Sdtrig triggers that raise exceptions (`CPU_CORE_SPEC.md` decision 67): reading and writing `tselect` / `tdata1` / `tdata2` / `tdata3` / `tinfo` / `tcontrol`, M-mode execute triggers with `tcontrol.MTE` / MPTE, no firing inside the handler, load / store / AMO triggers (the access does not happen, mtval, exact match, priority over misalignment), the m / s / u bits (S and U modes), no firing or hit on paths that are thrown away (behind a misprediction, the instruction and load behind ECALL), priority over illegal instruction |
| `t31_zicond` | Zicond (`CPU_CORE_SPEC.md` decision 68): a table of values of `czero.eqz` / `czero.nez` (only the lowest, highest and upper-half bit of rs2 set), rd = rs1 / rd = rs2 / rs1 = rs2 / x0, forwarding from the ALU and a load just before, results used for a branch and an address. PAUSE, NTL.* and C.NTL.* neither trap nor write anything |
| `t32_pmu` | Performance counters (Zihpm, Sscofpmf, `CPU_CORE_SPEC.md` decision 69): the implemented range of `mhpmcounter` / `mhpmevent` and 0 read from 7 to 31, the HPM bits of `mcountinhibit`, cycles and instructions equal to the differences of `mcycle` / `minstret`, exact counts of loads, stores, conditional branches (including those resolved in MR) and exceptions, that mispredictions, load-use, MDU waits and front end / back end stalls are counted, `mcountinhibit` with MINH / UINH, OF and LCOFIP set on overflow and the interrupt (cause 13) taken in M, no second interrupt while OF is set, delegation to S (`sip` / `sie`), the restriction of `hpmcounterN` and `scountovf` by `mcounteren` / `scounteren`, Smcntrpmf (`mcyclecfg` / `minstretcfg`). The cache and TLB events are in SIM_SYS's `progs/d04_pmu.S` |
| `t33_fpipe` | The pipelined FPU (`CPU_CORE_SPEC.md` 10.11): 16 independent FMADD.D flowing at one a cycle, a dependent chain and its integer answer straight into an ADDI, FSD of the answer just in front, FLD and integer writes to a register the FPU has not written yet (WAW), FMV.X.D into a branch and FEQ.D into an address, FRFLAGS right behind, operations taken back behind a trap and behind FENCE.I (the instruction behind is rewritten by a store first), integer ⇄ double, behind a divide, an FADD in the shadow of a late branch, FP operations right behind loads, the FPU's integer answers read later from the register file (rs1 / rs2), reads 1 to 5 instructions after an FLD (a read in the same cycle as the write) |

## What the testbench checks on its own

- The reason for stopping (stopping anywhere but ECALL fails)
- Violations of the cache port rules (M1 allows one access at a time)
- That the same PC does not retire in 2 consecutive cycles (double retirement)
- That an access in MA is waiting for every answer of the data port (an answer nobody waits for fails;
  this catches handing over an answer that should have been thrown away by a flush)
- That when a FENCE leaves ID, all accesses in front of it have been answered (`os == drop` of the LSU;
  answers to be thrown away are not counted)
- Watchdog (a hang fails)
