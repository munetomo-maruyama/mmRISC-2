# Out-of-context synthesis of the FPU alone

[日本語](README_J.md)

Synthesizes, places and routes one FPU of `RTL/CPU/CPU_FPU` alone in Vivado to see its resources and
timing. The purpose is to compare the pipelined `FPU_PIPE` (ROADMAP C2, `CPU_CORE_SPEC.md` 10.11) with
`CORE_FPU`, the one the core used at the time, under the same conditions, and so learn the price of
pipelining.

## Running it (Windows, Vivado 2025.1)

```
synth_fpu.bat                 FPU_PIPE, 50 MHz, through place and route
synth_fpu.bat CORE_FPU        the earlier FPU, for comparison
synth_fpu.bat FPU_PIPE 15     at 66 MHz (to see the margin)
```

The arguments are, in order: top (`FPU_PIPE` / `CORE_FPU`), clock period (ns), place and route
(1 / 0). The results are in `output/<top>/summary.txt` (LUT, FF, DSP, LUT RAM, WNS, register-to-register
WNS, WHS, slices).

Both sides of each port get 30 % of the period as input / output delay (the same idea as
`FPGA/L2_OOC`). In the core the operands come through the forwarding multiplexers of EX, so the input
side is the tight one. Both FPUs copy their operands in the first cycle, so the register-to-register
WNS (`timing_reg2reg.rpt`) is the margin of the FPU itself.

## What to look at

- **How LUTs and FFs grow**: the control and the waiting answers ("bundles") each stage carries. FFs
  were expected to grow but LUTs not by much (the logic of each stage is that of a `CORE_FPU` state).
  The whole design was at 91.4 % of the slices (section 32 of `TIMING.md`), so what grows here is the
  budget of the integration
- **DSP**: should not change (`CORE_FPU` also produced all partial products in one cycle)
- **Register-to-register WNS**: should be about the same as `CORE_FPU` (the stage boundaries are the
  state boundaries)

## Results (2026-10-09, Vivado 2025.1, 50 MHz)

| | `CORE_FPU` (earlier) | `FPU_PIPE` (pipelined) | Difference |
|---|---|---|---|
| LUT | 9,757 | **9,060** | −697 |
| FF | 2,008 | 2,631 | +623 |
| LUT RAM / SRL | 0 | 177 | The delay of the waiting answers (bundles) became SRLs |
| DSP | 16 | 16 | Same |
| Slices | 2,260 | 2,309 | **+49** |
| Register-to-register WNS | +3.427 ns | **+3.758 ns** | +0.33 ns |
| Overall WNS / WHS | +2.722 / +0.124 ns | +3.758 / +0.036 ns | |

**Pipelining came almost for free.** LUTs went down (the multiplexers of the state machine, which chose
per state what to write into each register, disappeared), FFs grew by the control of each stage, and
Vivado packed the answers waiting in P3 to P5 into SRLs (shift registers built from LUTs). Slices +49.
In both the worst path is the first half of the rounding (`q_rexp` → the round-up decision of
`FPU_ROUND`), and its logic went from 23 levels down to 17.

Seen from the whole design (91.4 % of the slices, 1,369 left), the growth of the FPU itself is
negligible. The budget of stage 2 is decided on the core side (the pending bits, the passing of
results, the second write port of the FP register file).

