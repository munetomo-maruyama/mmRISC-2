# CPU_FPU — floating point unit (F / D)

[日本語](README_J.md)

The floating point unit of mmRISC-2. It executes every instruction of the F (single precision) and D
(double precision) extensions of RV64GC in hardware, down to the 5 IEEE 754 rounding modes, the
exception flags and subnormals.

On 2026-10-09 it was replaced by the **pipelined `FPU_PIPE`** (ROADMAP C2). Add / subtract, multiply,
multiply-add and conversions to and from integers flow at **one instruction a cycle** when there is no
register dependency. The intent is DSP-like processing (FIR, matrix multiply, dot product) written in
assembler to be fast.

The detailed specification is section 10 of [`../CPU_CORE/CPU_CORE_SPEC.md`](../CPU_CORE/CPU_CORE_SPEC.md)
(10.11 is the pipelined version), the measurements section 16 of
[`../../../LitexSystem/docs/BENCH.md`](../../../LitexSystem/docs/BENCH.md).

---

## 1. Structure

| Directory | Contents |
|---|---|
| `FPU_PIPE/` | **The version the core uses**. All operations in a 9-stage pipeline. Divide and square root use an iterative engine |
| `CORE_FPU/` | The earlier version. A state machine that takes one operation at a time and answers it (EX stops meanwhile). Kept as the reference that `SIM/SIM_FPU` and `FPGA/FPU_OOC` compare against |
| `FPU_ROUND/` | Normalization, rounding and packing. Everything that is rounded goes through here (both versions use it) |

### 1.1 How the operations are done

- **One multiply-add datapath**. FADD / FSUB / FMUL and the 4 FMAs all compute `a × b + c` exactly in a
  common 128-bit frame and **round once** (the very definition of fused). FADD is `a × 1.0 + c`, FMUL is
  the same path with no addend. The partial products all come out of DSP48s in one cycle (16 DSPs).
- **Divide and square root iterate by restoring** (128 iterations for a double precision divide, 64 for
  a single precision divide and for square root). The quotient is produced down to the rounding
  position of the deepest subnormal, so the input of the rounder is 128 bits wide.
- **The rounder `FPU_ROUND` takes 2 cycles**. The first cycle shifts, truncates and decides whether to
  round up, preparing the exponent for both "carry" and "no carry". The second only adds 1 and selects.
- Subnormals are handled fully, not flushed to zero. NaN-boxing, the canonical NaN, tininess detected
  after rounding (RISC-V's conventions).

### 1.2 The pipeline (`FPU_PIPE`)

| Stage | Where the core is | Contents |
|---|---|---|
| P0 | MR | Copy of the operands and the control |
| P1 | MA | Unpacking (kind of value, exponent, significand with its leading 1 aligned) |
| P2 | | Multiply-add: the partial products. Others: the answer, or what is handed to the rounder (the "bundle") |
| P3 | | Sum of the partial products (the bundle waits) |
| P4 | | Alignment of the addend (the bundle waits) |
| P5 | | Addition (the bundle waits) |
| P6 | | Select: the normalized sum, the bundle, or the result of a divide / square root |
| P7 | | First half of the rounding, second half of a conversion to integer |
| P8 | | Second half of the rounding, the answer |

- **The stages are the states of the earlier version**. Each state already wrote registers of its own,
  so neither the cuts nor the paths changed, and no DSPs were added.
- **The latency is 9 for everything** (except divide and square root). All operations go through the
  same number of stages, so answers come out in the order they were accepted, at most one a cycle, and
  the order of register writes and flags is kept. Operations other than multiply-add make their answer
  in P2 and wait through P3 to P5.
- **Divide and square root** leave the pipeline at P1 for the engine, and nothing new is accepted until
  they finish (`in_ready` = 0). By then the pipeline is empty, and the answer enters at P6 to be
  rounded. A divide or square root of special values (NaN, 0, infinity) does not use the engine and
  flows down the pipeline.
- **P0 and P1 stop and are taken back together with the core's MR and MA** (`hold0` / `hold1`, `kill0` /
  `kill1`). From P2 on nothing is taken back any more, so those stages never stop.

---

## 2. How it connects to the core (`CPU_CORE`)

```
  ID           EX              MR    MA    WB
  ──────────────────────────────────────────────────────────────────
  read GPRs    hand the FP     P0    P1    (writes nothing)
  (wait for    op over ──────> P2 → … → P8 ─┬─> 2nd write port of the FRF (+ straight to EX)
   int results)                               └─> 2nd write port of the RF
```

| Item | How |
|---|---|
| Issue | Once EX hands an FP operation to the FPU, the main pipeline writes nothing for it and goes on to retire it |
| Writing the answer | 9 cycles later the FPU writes straight into the second write port of a register file (FP answers to the FRF, integer answers to the RF). `fflags` are accumulated when the answer comes out too |
| FP dependencies | The pending bits `fp_pend[32]` are checked **in EX**. In the cycle the answer comes out it goes from the last stage straight to EX (dependent operations are 9 cycles apart) |
| Integer dependencies | `gpr_pend[32]` is checked **in ID**. The answer is picked up through the write-first read of the register file (10 cycles apart). This adds no input to the integer forwarding, which heads the longest path of the design |
| WAW | An FLD, an integer instruction or another FP operation that would write a register the FPU has not written yet waits. At most one writer of a register is ever in flight |
| Taking back | A trap, xRET, FENCE.I, SFENCE or refetch in MA takes back P0 (`kill0 = flush`). Only a trap takes back P1 (`kill1 = trap_taken`) |
| What waits for the FPU to be empty | CSR instructions, xRET, SFENCE, FENCE.I, the debugger's register accesses (`fpu_busy`) |
| Early issue of loads / stores | An FSD / FLD waiting for an answer of the FPU does not issue to the D$ early from EX (`~fp_wait` in `lsu_e_valid`) |

**The register files have 2 write ports** (`CORE_RF`, `CORE_FRF`): two banks of distributed RAM (A: WB of
the pipeline, B: the FPU) and a 32-bit table telling which bank is newer (LVT, live value table).
Smaller than the earlier flip-flop version (FF −4,096); the contents are not initialized at reset.

---

## 3. Performance

### 3.1 Cycles per instruction

| Instruction | Issue interval (no dependency) | Until the answer can be used |
|---|---|---|
| FADD / FSUB / FMUL / FMADD family, compare, sign injection, FMV, FCVT (single and double) | **1** | FP answers: 9; integer answers (FEQ, FCVT.L.D, FMV.X.D, ...): 10 |
| FDIV.D | The next FP operation waits until it finishes | about 134 |
| FDIV.S / FSQRT | Same | about 70 |
| FLD / FSD | 1 (on a D$ hit) | The value of an FLD can be used from the instruction after next |

In the earlier version (`CORE_FPU`) every operation occupied EX, and the multiply-add family ran at one
instruction every 10 cycles.

### 3.2 Measured on the board (Arty A7-100T, 50 MHz, Linux, `micro 50 fp`)

| Workload | Cycles per multiply-add | MFLOPS |
|---|---|---|
| FIR 8 taps × 1024, assembler | **1.53** | **65.6** |
| Matrix multiply 64×64, assembler, cache blocking | **2.42** | **41.2** |
| Matrix multiply 64×64, assembler, no blocking | 4.01 | 24.9 |
| Dot product × 512, assembler | 3.66 | 27.3 |
| Matrix multiply 64×64, C (`-O2`) | 16.6 | 6.04 |
| For reference: earlier version, matrix multiply 64×64, C (`-O2`) | 17.6 | 5.69 |

Compared with the same assembler kernels on the core with the earlier FPU (SIM_SYS, data sized to fit
in the D$): matrix multiply 11.19 → 2.18 (5.1×), FIR 10.10 → 1.45 (7.0×), dot product 12.81 → 3.66
(3.5×).

- **The FIR runs at almost one a cycle**. 64 multiply-adds plus 8 FLDs, 8 FSDs and 3 loop instructions
  make 83 instructions ÷ 64 = 1.30, the lower bound of issue.
- **The matrix multiply** does 8 FLDs and 16 FMADDs per k (about 1.7 for the kernel alone). The three
  64×64 matrices (96 KB) do not fit in the D$ (16 KB), so packing B into 64×16 panels (8 KB) kept in the
  D$ (blocking) takes it from 4.01 to 2.42. What remains is D$ misses: MA waits for the answer of a
  missing load, so the misses do not overlap with computation ("Overlap memory waits" in the ROADMAP).
- **The dot product** needs 2 FLDs per multiply-add and is bound by the loads.
- **Loops in C** hardly get faster. Code like `s += a[i] * b[i]` piles onto one sum, so the 9 cycles of
  the dependency show as they are. Even with `-O3 -funroll-loops` there is still only one sum.

### 3.3 How to write fast code (assembler)

`LitexSystem/software/bench/fpkern.S` has examples (FIR, matrix multiply, dot product).

1. **Line up 9 or more independent operations**. An answer takes 9 cycles, so split sums that pile onto
   one register into 9 or more (the FIR's round is 8 outputs + 1 load = 9 instructions; the matrix
   multiply has 4×4 = 16 sums of C).
2. **Cut down the loads**. FLDs and FP operations together issue only one a cycle. Keep coefficients
   and windows in registers and use a value read once many times (the FIR rotates its window through 8
   registers).
3. **Load 2 or more instructions ahead**. Using the value right after the FLD waits one cycle.
4. **FSD after the answer is out**. FSD waits in EX for its answer (and nothing else moves meanwhile), so
   place it 9 cycles after the operation or put other work in between.
5. **Integer answers (FCVT.L.D, FEQ) take 10 cycles**. Issue early what feeds a branch or an address.
6. **A CSR instruction reading `fcsr` waits for the pipeline to empty**. Do not read `frflags` inside a
   loop.
7. **Block when the data does not fit in the D$ (16 KB)**. Misses do not overlap with computation, so
   their number counts directly (`fpkern.c`).
8. Calling convention: f8 to f9 and f18 to f27 are saved by the callee.

---

## 4. Resources and timing

| | `CORE_FPU` | `FPU_PIPE` |
|---|---|---|
| Alone (`FPGA/FPU_OOC`, 50 MHz) | LUT 9,757, FF 2,008, DSP 16, 2,260 slices, register-to-register WNS +3.43 ns | LUT 9,060, FF 2,631 (+ SRL 177), DSP 16, 2,309 slices, +3.76 ns |
| Whole SoC (the board's build) | LUT 46,957 (74.1 %), FF 28,019, slices 91.4 %, WNS +0.159 ns | LUT 44,833 (70.7 %), FF 24,712, slices 86.2 %, WNS +0.113 ns |

Pipelining was almost free in the FPU itself (the multiplexers of the state machine disappeared and LUTs
went down). In the whole design it even got smaller, thanks to the register files moving to distributed
RAM. The FPU is not on the critical path (sections 33 and 34 of `LitexSystem/docs/TIMING.md`).

---

## 5. Verification

| What | Where | Size |
|---|---|---|
| The operations themselves | `SIM/SIM_FPU` (against Berkeley SoftFloat's RISC-V specialization): all operations × both precisions × 5 rounding modes × all pairs of special values + random, result and all 5 exception flags | `CORE_FPU` about 580,000 checks, `FPU_PIPE` (`make pipe`, one a cycle) about 700,000 checks |
| Pipeline control | `tb_FPU_PIPE` of `SIM/SIM_FPU`: holding, taking back, long holds, a divide left in P1 | All 28 bug injections detected (`bug_inject_pipe.sh`) |
| Connection to the core | `SIM/SIM_CORE/tests/t33_fpipe.S`: one a cycle, dependent chains, WAW, flags, taking back behind a trap, FENCE.I and a late branch, right behind loads | All 315 bug injections of the core detected (the FPU connection is M78, M88, M341 to M358) |
| Real instruction streams | riscv-tests (`rv64uf` / `rv64ud`), SIM_SYS (through the real caches), booting Linux | |
| Cycle counts | `SIM/SIM_SYS/bench/fploop.c` (a cycle bound per kernel) | Detects SIM_SYS bug injection M19 |

Of what the reference model and the tests found, the things hand-written tests would not have caught:

- UF not raised when rounding reaches the smallest normal (tininess was decided on the packed exponent),
  `flt` returning 1 for equal values, FSGNJ of values that are not NaN-boxed, and so on (found by
  SoftFloat, in the earlier version).
- Values where the sticky bit of the square root decides the answer are not hit by random values. 8
  found by search were added.
- Taking back an FP operation behind FENCE.I: if the same instruction simply flows again, forgetting to
  take it back cannot be seen (the same value is written twice). The test rewrites the instruction
  behind it with a store first.
- **An FSD waiting for its answer issued to the D$ early with stale data, was taken back and went again
  from MA**. The answer was right; only cycles were lost (the C matrix multiply went 17.6 → 18.6). Found
  with `micro` on the board, and now watched by the cycle bounds of `fploop`.

---

## 6. History

| Date | What |
|---|---|
| 2026-09-20 to 21 | `CORE_FPU` (M4): the wait-in-EX scheme, checked with SoftFloat, all F / D riscv-tests pass |
| 2026-10-09 | Direction: for DSP-like use, add / subtract, multiply, multiply-add and conversions at one a cycle. Divide and square root may stay long. What should be fast is written in assembler |
| 2026-10-09 | Stage 1: `FPU_PIPE` (verified and synthesized on its own) |
| 2026-10-09 | Stage 2: integration into the core (pending bits, second write ports, LVT register files) |
| 2026-10-09 | Board: FIR 1.52, matrix multiply 4.05; fixing the early issue of FSD takes the C matrix multiply 18.6 → 16.6; cache blocking takes the matrix multiply to 2.42 |
