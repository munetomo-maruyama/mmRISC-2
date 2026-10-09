# SIM_FPU — verification of the FPU alone

[日本語](README_J.md)

Checks `RTL/CPU/CPU_FPU` against **Berkeley SoftFloat** (RISC-V specialization).
The specification is section 10 of [`../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md).

What goes wrong in floating point is rounding and special values, so there is no home-made reference
model: SoftFloat, which the RISC-V specification itself points to, is used as it is. Choosing the RISCV
specialization brings in RISC-V's conventions as they are: the canonical NaN, the NaN propagation rules,
and **tininess detected after rounding**.

## Usage

| Command | What it does |
|---|---|
| `make` | Compares all operations with the default vectors |
| `make long` | Runs 40 times the random vectors |
| `make OPS=0,1,2 run` | Only the given operations (the numbers are the `FOP_*` of `CORE_FPU`) |
| `make lint` | Verilator lint |
| `./bug_inject.sh` | Bug injection, aimed at the stage boundaries (below) |
| `./bug_inject.sh <string>` | Only those whose name contains the string |

Plusargs: `+ops=<list>` `+rand=<n>` `+seed=<n>` `+verbose`

## Preparing SoftFloat

It is not in the repository. Build it once.

```
git clone https://github.com/ucb-bar/berkeley-softfloat-3 ~/RISCV/berkeley-softfloat-3
cd ~/RISCV/berkeley-softfloat-3/build
cp -r Linux-x86_64-GCC Linux-aarch64-RISCV-GCC          # to suit the machine you use
sed -i 's/^SPECIALIZE_TYPE ?= .*/SPECIALIZE_TYPE ?= RISCV/' Linux-aarch64-RISCV-GCC/Makefile
make -C Linux-aarch64-RISCV-GCC
```

To use another location: `make SOFTFLOAT=... SF_BUILD=...`.

## What is compared

- All operations (arithmetic, FMA, divide, square root, compare, convert, sign injection, classify,
  move)
- Single and double precision
- **All 5 rounding modes** (RNE / RTZ / RDN / RUP / RMM)
- The bit pattern of the result and **all 5 bits of the exception flags**

The pool of operands is chosen to hit the places where floating point breaks.

| Kind | Examples |
|---|---|
| Zero | ±0 |
| Subnormal | Smallest, largest, in between |
| Normal boundaries | Smallest normal, largest normal, ±1 ulp from them |
| Rounding boundaries | 1±1 ulp, 2^52, 2^53, 2^23, 2^24 |
| Ties (round to nearest even) | 0.5, ±1.5, 2.5, −2.5, 2^23 − 0.5 |
| Edges of the integer ranges | 2^31, 2^63, 2^31 − 0.5, 2^32 − 0.5, −2^31 − 0.5 (out of range only after rounding up) |
| Infinity | ±inf |
| NaN | Canonical, signalling (both signs) |
| Single precision not NaN-boxed | Upper half 0 or any value |

All pairs of these (40×40), with random bit patterns on top.

About 580,000 checks with `make`, about 10 times that with `make long`.

**The sticky bit of the square root** (added 2026-10-09): of the 64-bit root of a double precision
square root, only 11 bits remain below the precision, and for values where those 11 bits are all 0
(inexact only through the remainder) or only the guard bit (a tie decided by the remainder), the sticky
bit made from the remainder decides the answer. The values of the pool do not hit that, so 8 values
found by search (`sqrt_hard`, roots computed with Python's `math.isqrt`) are run in all rounding modes.
The quotient of a divide has 75 bits below the precision (40 for single), which are never all 0, so
the divide does not need this.

## Bug injection

34 mutations, including the sticky masks and 9 on the split of the floating point → integer
conversion into 2 cycles (section 22 of `LitexSystem/docs/TIMING.md`).

`CORE_FPU` is a unit that takes one operation at a time and answers it, and the answer comes out through
registers that span several cycles: the copy of the operands, the result of the alignment, the input of
the rounder. **A register written in one state and read in another** does not trip lint when it is
wired to the wrong place, and is hard to notice in a waveform. Those are what is broken, one place at a
time, to confirm that the comparison with SoftFloat fails.

```
./bug_inject.sh
```

Each mutation copies the RTL to a work directory, applies one `sed` and runs the comparison. **A FAIL
means "detected".** `NOT APPLIED` means the RTL changed and the `sed` pattern no longer matches, so fix
the mutation.

Not listed:

- Always bypassing the copy of the operands (`u_a = a`). EX holds its values during the operation and so
  does the bench, so the copy and the raw value are the same. The copy is there **for the clock, not for
  the answer**, so as long as only the answer is looked at it cannot be detected.

## The pipelined `FPU_PIPE` (ROADMAP C2, 2026-10-09)

`RTL/CPU/CPU_FPU/FPU_PIPE` cuts the same operations as `CORE_FPU` into stages and takes one operation
every cycle (`CPU_CORE_SPEC.md` 10.11). The core has used it since 2026-10-09 (how it works and what it
measures: `RTL/CPU/CPU_FPU/README.md`).

| Command | What it does |
|---|---|
| `make pipe` | `tb_FPU_PIPE`: the 3 phases below (about 700,000 checks, 10 seconds) |
| `make pipe-long` | The same with `+rand=4000 +ops2=2000000` |
| `./bug_inject_pipe.sh` | Bug injection, 28 mutations (below) |

`tb_FPU_PIPE` sends **one operation every cycle** and compares the answers with SoftFloat in the order
they come back.

1. The same pool as `tb_FPU` (all operations, both precisions, 5 rounding modes, all pairs and random)
   and the hard square root values, with no gaps. It also checks that every operation except divide and
   square root (those that use the engine) **has its answer exactly 9 cycles after it is accepted**,
   that is, that one operation a cycle flows through.
2. Random operations of every kind, mixed with what the core does: gaps between offers, holding the
   first 2 stages (`hold0`, and `hold1` together with `hold0`), taking them back (`kill0`, and `kill1`
   together with `kill0`), and now and then holding for 60 to 200 cycles (MA stopped by a long D$
   miss). A taken-back operation must not produce an answer, and the rest must come out in order. It
   also checks that no operation is taken back after its answer is out.
3. A divide or square root is held in P1 for 300 cycles (the engine finishes meanwhile), then moved on
   or taken back. A taken-back one must not produce an answer, and the unit must accept normally after
   it.

`./bug_inject_pipe.sh` aims at what the pipeline added, not at the arithmetic: holding and taking back
the first 2 stages, the divide / square root engine (blocking new offers, when the answer goes in,
taking it back), and the control passed from stage to stage (tag, rounding mode, rounding precision,
exponent and addend of FMA). All 28 are detected. Those left out because they are equivalent (starting
the engine while still in P0, not stopping the engine when taken back in P1) have their reasons in the
notes of the script.

