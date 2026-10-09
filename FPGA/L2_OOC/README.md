# Out-of-context synthesis of the L2 cache alone

[日本語](README_J.md)

Synthesizes, places and routes `RTL/CPU/CPU_L2` alone in Vivado to see its resources and timing. The
purpose was to check the estimates of section 5 of the design proposal before integrating the cache
into `CPU_TOP` (stage 3 of section 10 of `CPU_L2_SPEC.md`).

## 1. Running it (Windows, Vivado 2025.1)

In this directory (over the shared folder):

```
synth_l2.bat                     256 KB, 4 ways, pseudo-LRU, 50 MHz, through place and route
synth_l2.bat 131072              128 KB
synth_l2.bat 262144 4 1          random replacement
synth_l2.bat 262144 4 0 12.5     at 80 MHz (to see the margin)
synth_l2.bat 262144 4 0 20 0     synthesis only
```

The arguments are, in order: capacity (bytes), number of ways, replacement (1 = random), clock period
(ns), place and route (1 / 0). The results go to `output/L2_<KB>K_<ways>w[_rnd]/`.

| File | Contents |
|---|---|
| `summary.txt` | The numbers in brief (LUT, FF, block RAM, LUT RAM, WNS, register-to-register WNS, WHS, slices) |
| `utilization_synth.rpt` / `utilization.rpt` | Resources per module (after synthesis / after routing) |
| `ram_utilization.rpt` | Whether each array became block RAM or LUT RAM |
| `timing_summary.rpt`, `timing_paths.rpt`, `timing_reg2reg.rpt` | Timing after routing (the last one only register to register) |

## 2. How the constraints are set

On its own the cache has no pins for its AXI ports. Both sides of each port get 30 % of the period as
input and output delay (a rough estimate of the logic on the `CPU_CACHE` side and on the LiteX side).
Paths that go straight from an input to an output (AXI READY / VALID, part of the W of a write) are left
with 40 % of the period. **The real values after integration are decided by the full synthesis of
stage 3**, so here the register-to-register WNS (`timing_reg2reg.rpt`) is what to look at.

## 3. Expectations (section 5 of `CPU_L2_SPEC.md`) and what to check

| Item | Expected (256 KB, 4 ways) | What to check |
|---|---|---|
| Data array | 64 RAMB36 (one way is 8,192 words × 64 bits = 16) | That it became block RAM, in `ram_utilization.rpt`. The script stops when there are more than 20,000 FFs (the array became flip-flops) |
| Tag array | 4 RAMB36 (one way 1,024 × 26 bits). More than the "2 tiles" of the proposal | Same |
| Pseudo-LRU | LUT RAM (1,024 × 3 bits) | That the LUT RAM count in `summary.txt` is not 0 (0 means it became flip-flops) |
| LUT | 2,500 to 4,000 | |
| FF | 1,500 to 2,500 (including the 512 of the eviction buffer and about 280 of the R FIFO) | |
| WNS (50 MHz) | Positive | If there is a slow path, where it is (`timing_reg2reg.rpt`). The candidate is block RAM output → tag compare → way select → R FIFO (`M_CMP`) |

The whole design (the version of section 13 of `BENCH.md`) uses 40.5 / 135 block RAM tiles, 45,598 LUTs
(71.9 %) and 88.6 % of the slices. With the L2 it was expected to reach about 109 / 135 tiles. Slices
of a design on its own do not simply add to the whole (in the full design it shares slices with the
logic around it), so treat that number as a guide only.

## 4. Results (2026-10-06, Vivado 2025.1, 256 KB, 4 ways, pseudo-LRU, 50 MHz)

```
L2_256K_4w  (period 20.0 ns, I/O delay 6.0 ns each side)
after synthesis: 1078 LUT, 991 FF, RAMB36 68, RAMB18 0 (tag 4, data 64 primitives), LUT RAM cells 12
after routing: WNS 3.953 ns (register to register 5.977 ns), WHS 0.161 ns, 659 slices
```

All arrays became block RAM (data 64, tag 4) and the pseudo-LRU became LUT RAM. LUTs and FFs are less
than half of the estimate. The worst register-to-register path is tag read → tag compare → hit → read
enable of the 64 data array blocks (13.5 ns, of which 9.1 ns is routing). How to read this: section 5 of
`CPU_L2_SPEC.md`.

