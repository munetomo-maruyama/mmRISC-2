# Analysis of Arty A7-100T synthesis results (from the first bitstream)

[日本語](TIMING_J.md)

Subject: `LitexSystem/build/gateware/`, Vivado 2025.1 run of 2026-09-21
Device: xc7a100tcsg324-1 / system clock 50 MHz (`main_clkout0`, period 20 ns)

---

## 1. Conclusion

The bitstream `digilent_arty.bit` was generated. Routing completed (all 69719 routable nets fully
routed, 0 routing errors), DRC has nothing critical, and hold has margin (WHS +0.034 ns, 0 violations).

But **setup fails badly**.

| Item | Value |
|---|---|
| WNS | **-20.442 ns** (the real path is 40.44 ns against the required 20 ns) |
| TNS | -262585.312 ns |
| Failing endpoints | **17702 / 67415 (26%)** |
| Achievable frequency | **about 24.7 MHz** |

As it is, it does not run at 50 MHz. Below, the causes are narrowed down step by step.

---

## 2. Area — compared with Rocket

| Item | Rocket (reference) | mmRISC-2 | Verdict |
|---|---|---|---|
| Slice LUT | 56.16 % | **75.37 %** (47786) | +19 pt |
| Slice (occupied) | — | **97.02 %** (15378/15850) | Nearly full |
| Slice Register | — | 24.11 % (30573) | Room |
| Block RAM | 26.30 % | 32.59 % (44) | Acceptable |
| DSP | 6.25 % | 13.33 % (32) | Acceptable |
| Power | — | 0.861 W / Tj 28.9 ℃ | No problem |

97 % slice occupancy leaves the placer no room to move, and is the main reason routing delays swell
(route is 74 % of the worst path).

### LUTs by hierarchy (after placement)

| Hierarchy | LUT | FF | Note |
|---|---|---|---|
| CPU_TOP | 43903 | 26683 | |
| └ CPU_CORE | 34582 | 21427 | |
| 　├ u_lsu | 9301 | 32 | ※ Really 126 lines. The FPU's output stage is absorbed by cross-boundary optimization |
| 　├ u_csr | 6585 | 1786 | The registers of 16 PMP entries and a huge CSR mux |
| 　├ u_mmu | 6484 | 3315 | itlb 2675 / dtlb 2198 / ptw 1063 |
| 　├ u_ifu | 5725 | 9352 | of which **u_btb 3474 LUT / 8000 FF** |
| 　├ u_fpu | 3008 | 952 | of which u_round 1358 |
| 　├ u_frf | 1861 | 2048 | |
| 　├ u_mdu | 1117 | 729 | |
| 　└ u_rf | 1184 | 1984 | |
| └ u_cpu_cache | 7239 | 4765 | dcache 6501 / icache 711 |
| └ u_mmio | 1896 | 475 | clint 321 / plic 259 |

The BTB holds 64 entries × 125 bits all in flip-flops, so it takes 8000 FFs and 3474 LUTs (64-way
comparators and muxes).

---

## 3. Narrowing down the cause — not congestion but "logic depth"

The decisive evidence is **the timing right after synthesis (before placement)**.

| Stage | WNS | Failing endpoints |
|---|---|---|
| After synthesis (`_timing_synth.rpt`) | **-16.276 ns** | 13635 |
| After place and route (`_timing.rpt`) | -20.442 ns | 17702 |

It is already -16.3 ns before placement. Place and route added only 4.2 ns. So **the 97 % congestion is a
secondary aggravation; the essence is that the logic is too deep**. Cutting area alone will not reach
50 MHz.

---

## 4. There are 2 worst paths

### (A) The FPU's one-cycle operations — the worst path after synthesis

```
wb_rd_reg[0]  →  u_fpu/result_reg[54]
  36.113 ns  (logic 15.596 ns / route 20.517 ns)
  90 levels  (CARRY4=59, LUT6=18, ...)
```

`S_IDLE` of `CORE_FPU.sv` executes `result <= res_comb` directly for every operation except multiply and
divide. `res_comb` goes through

  operand inputs → unpack / special value checks → `shr_jam` alignment
  → 128-bit add → `lzc129` leading zero count → 129-bit variable shift normalization
  → `FPU_ROUND` (subnormal shift + rounding + carry)

**all in one cycle**. And its entry is not a register but the forwarding mux from WB. Logic alone is
15.6 ns, using up 78 % of the 20 ns period. It would not make it even with zero routing.

### (B) EX → DTLB → PMP → D$ — the worst path after place and route

```
g_core.u_cpu_core/ex_rs1_reg[4]  →  u_cpu_cache/u_dcache/rob_data_reg[0][18]/CE
  40.257 ns  (logic 10.369 ns / route 29.888 ns)
  52 levels  (CARRY4=23, LUT6=18, ...)
```

**9 of the worst 10** after place and route have this shape, all starting at `ex_rs1_reg[4]`. The path is

  EX register → address add in `u_exu` (`ex_a_fwd1` has a fanout of 103)
  → `vpn_match`/`hit` of `u_mmu/u_dtlb` → `u_pmp_d/match_one`
  → `d_pmp_fail` → exception cause → write enable of the D$'s ROB

exactly the **"address add → TLB lookup → PMP check → cache control" one-cycle chain** anticipated at
design time. Logic is 10.4 ns, routing 29.9 ns. By logic alone it would just fit at 50 MHz, but routing
under 97 % congestion kills it.

---

## 5. Proposed measures

| # | Contents | Expected effect | Size |
|---|---|---|---|
| 1 | FPU: do not write `result` directly from `S_IDLE`. Add `S_OP` to take the operands into registers, and register `rnd_sig/rnd_exp` to send `FPU_ROUND` to the next cycle (FP operations +1 to 2 cycles) | (A) to about 1/3 | Small to medium |
| 2 | BTB 64 → 16 entries | -2600 LUT / -6000 FF, and fewer levels in the 64-way comparators | Tiny (parameter) |
| 3 | I/D TLB 16 → 8, PMP 16 → 8 (the DTS follows) | about -3000 LUT, and shorter TLB/PMP stages of (B) | Small (parameters + DTS) |
| 4 | Move the D-side address translation to MA (EX only adds the address; TLB + PMP + cache request in the next stage) | Fixes (B) at the root | Large (pipeline restructuring) |
| 5 | Lower `--sys-clk-freq` | Immediate, but LiteDRAM on the Arty has sys4x = 4×sys, so 25 MHz would make the DDR3 200 MT/s, below the specification's minimum. Putting only the CPU in a separate domain needs CDC | Medium to large |

### Recommended order

1. **Measures 2 + 3** first (parameter changes only). Bring slice occupancy from 97 % down into the 80s to
   stop the runaway of routing delays. Confirm with the SIM_CORE / SIM_SYS regressions that functions are
   unaffected.
2. **Measure 1** to split the FPU. Measure how far the post-synthesis WNS comes back.
3. When only (B) remains, decide whether measure 4 is needed. Its logic is 10.4 ns, so depending on the
   routing after the congestion is resolved, it may fit at 50 MHz without measure 4.

Running synthesis alone at each step and looking at the WNS of `_timing_synth.rpt` judges the effect
without waiting for place and route.


---

## 6. What stage 1 did (2026-09-23)

### Changes made

| Target | Change | Aim |
|---|---|---|
| `CORE_BTB` | Kept 64 entries but **moved to distributed RAM**. Only valid in flip-flops | Area (3474 LUT + 8000 FF → expected a few hundred LUTs + 64 FFs). Prediction performance unchanged |
| `MMU_TLB` | 16 → **8 entries**, one-hot selection on lookup | Area + levels of path (B) |
| `MMU_PMP` | 16 → **8 entries**, one-hot selection, NAPOT masks shared at the edges, the redundant `hit_lo != hit_hi` removed | Area + levels of path (B) |
| `CORE_CSR` | New `PMP_CSRS = 16`. Checks use 8, the CSRs show 16 and read zero | Conformance to the privileged specification (0/16/64 entries) |
| `mmrisc_arty.dts` | `d/i-tlb-size` 8, `riscv,pmpregions` 8 | Matching the implementation |

**The BTB was not shrunk**. The original plan was 64 → 16, but a direct-mapped table with one write and two
reads fits the fabric's distributed RAM as it is. That saves more than shrinking, and without losing the
reach of the predictor.

### Verification

| Item | Result |
|---|---|
| SIM_CORE (17 tests) | PASS |
| SIM_SYS (12 tests) | PASS |
| Icarus (4-valued) | PASS — the X of uninitialized RAM leaks nowhere |
| riscv-tests | 132 passed / only known failures |
| SIM_MMU PMP bug injection | **19 detected / 0 missed / 0 not applied** |
| Verilator lint | Warnings 57 → 56 |

The cycle counts **match exactly for every test** except +9 for t14_mmu (14159 → 14168, more walks with 8
TLB entries). In particular t17_btb 931 and t16_bench 33556 did not move by a single cycle, which is the
proof that moving the BTB to RAM did not change a single prediction (the predictor is transparent, so a
difference in behavior shows in the cycle count, not in the answer).

Bug injection gave one **design finding**. Making PMP one-hot makes `sel_lo != sel_hi` include the case
where "only one end matches", so the line `hit_lo != hit_hi` became dead. It was noticed because the
mutation targeting it was no longer detected; the line was removed and the mutation replaced with one of
another form.

### Next

Run **synthesis only** in Vivado and look at the WNS of `_timing_synth.rpt` and the LUT / slices of
`_utilization_synth.rpt`. What to judge by:

- Whether slice occupancy fell into the 80s (whether the runaway of routing delays stops)
- How far the post-synthesis WNS came back from -16.3 ns — the FPU of path (A) has not been touched, so
  **it is not expected to come back much**. The real point is how many logic levels of path (B) (EX →
  DTLB → PMP → D$) were removed, seen in the `Logic Levels` of the worst paths.

Go on to stage 2 (splitting the FPU) after seeing that.


---

## 7. Synthesis results of stage 1 (2026-09-23)

Routing is still in progress (`digilent_arty_timing.rpt` is the previous one). Synthesis and placement are
done, so compare **like stages with like**.

### Area — the congestion is gone

After placement (place vs place):

| Item | Before stage 1 | After stage 1 | Rocket |
|---|---|---|---|
| Slice LUT | 47786 (75.37 %) | **40016 (63.12 %)** | 56.16 % |
| **Slice occupied** | **97.02 %** | **73.61 %** | ― |
| Slice Register | 30573 (24.11 %) | **20695 (16.32 %)** | ― |
| Distributed RAM (LUT) | 302 | 549 | ― |
| Block RAM | 44 (32.59 %) | 44 (32.59 %) | 26.30 % |
| DSP | 32 (13.33 %) | 32 (13.33 %) | 6.25 % |

**Slice occupancy 97 % → 73.6 %**. The placer has room to move again. That was the main purpose of stage 1.

### By hierarchy (after placement)

| Hierarchy | Before LUT / FF | After LUT / FF |
|---|---|---|
| `u_btb` | 3474 / 8000 | **414 (logic 167 + RAM 247) / 64** |
| `u_csr` | 6585 / 1786 | 3317 / 1306 |
| `u_mmu` | 6484 / 3315 | 5034 / 1785 |
| 　`u_dtlb` | 2198 / 1556 | 1125 / 779 |
| 　`u_itlb` | 2675 / 1508 | 1081 / 755 |
| 　`u_pmp_d` / `u_pmp_i` | (absorbed into `u_csr`, not visible) | 1018 / 985 |
| 　`u_ptw` | 1063 / 130 | 428 / 130 |
| `u_lsu` | 9301 / 32 | 8173 / 32 |
| `u_fpu` | 3008 / 952 | 4294 / 952 |
| `u_dcache` | 6501 / 4274 | 6611 / 4309 |

The BTB **became an order of magnitude smaller, as predicted** (-3060 LUT, -7936 FF). The total reduction
of 9878 flip-flops agrees within 1 % with the estimate of 9946: BTB 7936 + TLB 1530 + PMP registers 480.

That `u_fpu` grew and `u_lsu` shrank is not a move of content: **the attribution of cross-boundary
optimization went back**, that is all (their sum is almost unchanged, 12309 → 12467). This confirms the
reading that the 9301 LUTs attached to the 126-line `CORE_LSU` last time were the FPU's output stage
absorbed.

### Timing — TNS to 1/3, WNS stays

After synthesis (synth vs synth):

| Item | Before stage 1 | After stage 1 |
|---|---|---|
| WNS | -16.276 ns | **-16.439 ns** |
| TNS | -121911 ns | **-39779 ns** (-67 %) |
| Failing endpoints | 13635 / 90725 (15.0 %) | **5821 / 63111 (9.2 %)** |
| Average per failing path | -8.94 ns | **-6.83 ns** |

**WNS not moving is as planned**. The untouched path (A) (FPU) is still the worst path:

```
CPU_TOP/g_core.u_cpu_core/ma_rd_reg[3]  →  u_fpu/result_reg[54]
  36.276 ns  (logic 15.237 ns / route 21.039 ns)
  86 levels  (CARRY4=56, LUT6=18, ...)
```

Almost identical to the previous 36.113 ns / 90 levels; only the start point moved from `wb_rd` to
`ma_rd`. The wall of **15.2 ns of logic alone** has not moved.

On the other hand, **TNS fell to 1/3 and the number of failing paths to 43 %**, which means making the
priority chains of the TLB and PMP one-hot helped across the board. The path (B) family can be taken to
have left the list of failures in large numbers.

### Judgement at this point

- The purpose of stage 1 (resolving the congestion) is **achieved**.
- What blocks 50 MHz is now **almost the FPU alone**.
- The new number of levels of path (B) (EX → DTLB → PMP → D$) is to be checked in the
  `digilent_arty_timing.rpt` once routing finishes. It no longer appears among the worst paths after
  synthesis, so it is surely fewer than 52.

Next is stage 2 (splitting the FPU). If the 15.2 ns of logic can be split in 3, each stage is a little over
5 ns, which with the routing at 73 % occupancy should fit in 20 ns.


---

## 8. Place-and-route results of stage 1

| Item | Before stage 1 | After stage 1 |
|---|---|---|
| WNS | -20.442 ns | **-16.786 ns** |
| TNS | -262585 ns | **-81165 ns** (-69 %) |
| Failing endpoints | 17702 / 90675 (19.5 %) | **7903 / 63179 (12.5 %)** |
| **Delay added by routing** (synth → route) | +4.17 ns | **+0.35 ns** |
| Achievable frequency | 24.7 MHz | **27.2 MHz** |
| Slice occupied | 97.02 % | 73.61 % |

Routing completed (all 56084 nets), 0 routing errors, nothing critical in DRC, hold +0.053 ns with 0
violations, power 0.826 W.

The delay added by routing falling from **4.17 ns to 0.35 ns** is the direct evidence that the congestion is
gone.

And **all of the worst 10 paths end in the FPU**. Path (B) (EX → DTLB → PMP → D$) has left the top.

It also turned out the FPU has **two** long paths.

```
ma_rd_reg[3] → u_fpu/result_reg[*]   36.7 ns  97 levels CARRY4=74  logic 17.0 ns
wb_rd_reg[0] → u_fpu/sum_r_reg[*]    36.7 ns  89 levels CARRY4=62  logic 14.1 ns
```

The latter is `S_M2` (alignment `shr_jam` → 129-bit compare → add/subtract), the former the `res_comb` of
`S_A3` / `S_IDLE` (leading zero count → 129-bit normalization shift → select → round).

---

## 9. What stage 2 did (2026-09-23)

### Changes made (`CORE_FPU.sv`)

| # | Change | Aim |
|---|---|---|
| 1 | Copy the operands into **the unit's own flip-flops** in the `start` cycle. Bypass the raw values only in the first cycle | Take the forwarding multiplexers and the unpacking (leading zero count + barrel shift) off the head of every path |
| 2 | Split `S_A3` into **`S_SEL` (assembling the answer) and `S_RND` (rounding)**. Register the input of the rounder | Split the 17.0 ns of logic in 2 |
| 3 | Split `S_M2` into **`S_M2` (alignment) and `S_M3` (add/subtract)** | Split the 14.1 ns of logic in 2 |
| 4 | `S_M3` **builds "sum", "difference" and "reversed difference" side by side and selects**, instead of compare → subtract in series | 129-bit carry chains from 2 in series to 1 |

### Cycle cost

| Operation | Before | After |
|---|---|---|
| Compare / FCLASS / sign injection / FMV / FCVT | 2 | **4** |
| FADD / FSUB / FMUL / FMA | 5 | **7** |
| FDIV / FSQRT | N+3 | **N+4** |

`t11_fp` goes 1390 → 1553 cycles (+11.7 %). **Nothing else moves by a single cycle** (`t16_bench` stays at
33556 — this bench does not use FP).

### Verification

| Item | Result |
|---|---|
| SoftFloat comparison (default) | PASS 450240 checks — the same count as before the change |
| SoftFloat comparison (`+rand=20000`) | **PASS 4935240 checks** |
| SIM_CORE / SIM_SYS | PASS |
| riscv-tests | 132 passed / only known failures |
| **SIM_FPU bug injection (new)** | **17 detected / 0 missed / 0 not applied** |

`SIM_FPU/bug_inject.sh` was made new this time. **A register written in one state and read in another**
does not trip lint when wired to the wrong place and is hard to spot in a waveform, so the seams the split
created are broken one at a time to confirm that the SoftFloat comparison fails.

### Next

Run Vivado and check:

- **How far the post-synthesis WNS came back from -16.4 ns**. The FPU's 17.0 ns / 14.1 ns of logic were
  each split in 2, so falling to around 8 ns would be on target.
- **Where the new worst path is**. With the FPU out of the way, path (B) (EX → DTLB → PMP → D$) should come
  back, and only here can it be seen how far stage 1 reduced its levels.

The RTL is referenced from `digilent_arty.tcl` by relative path, so **regenerating LiteX is not needed**;
just run Vivado.

Note that stage 1 changed the DTS (TLB 8, PMP 8), so **`mmrisc_arty.dtb` must be rebuilt before booting
Linux** (see `docs/BRINGUP.md`).


---

## 10. Synthesis results of stage 2 — worse (2026-09-23)

| Item | After stage 1 | After stage 2 |
|---|---|---|
| Post-synthesis WNS | -16.439 ns | **-26.021 ns** |
| Post-place-and-route WNS | -16.786 ns | **-28.141 ns** |
| Post-place-and-route TNS | -81165 ns | -126869 ns |
| Slice occupied | 73.61 % | 79.02 % |
| Slice LUT | 40016 | 39804 |

Routing, DRC and hold are all clean, and area is about flat. **It is already worse at synthesis**, so this
is a design problem, not place and route.

### Cause 1 — cut in the wrong place

Stage 2 split the tail into "assembling the answer" and "rounding". But `sp_res` (the answer that does not
go through rounding) **by definition does not read the rounder** — as the RTL's comment warns, "reading the
rounder's output would make a combinational loop". So **the rounder was never on that path**.

Only the assembling side was long, and at its head was the **unpacking** (64-bit leading zero count of
subnormals + full-width shift). Registering a/b/c took the forwarding multiplexers off the head, but the
unpacking and the selection were still in one cycle.

```
Worst after synthesis, after stage 2:
  ex_rs1_reg[4] → u_fpu/q_sp_res_reg[32]   96 levels / logic 17.6 ns
Worst after synthesis, after stage 1 (for comparison):
  wb_rd_reg[0]  → u_fpu/result_reg[54]     90 levels / logic 15.6 ns
```

Almost the same number of levels. **What was meant to be split was not split.**

### Cause 2 — the bypass multiplexer

Putting `u_a = start ? a : q_a` hurt twice.

1. **`start` is not an early signal**. The pipeline raises it only when the memory stage is not stalled,
   which is decided by the D$'s answer. That signal came to the select of the multiplexer at the head of
   the unit's deepest cone. That is why the worst path after place and route **started from the D$'s
   answer**: `u_lsu/size_r_reg → lsu_resp_data → q_a → …`.
2. **Timing analysis does not know the states of a state machine**. It analyzed as real the path from the
   raw operands in the `start` cycle (S_IDLE) to `q_sp_res`, which is written only in `S_SEL`, several
   states later.

### What was put in instead

| # | Change |
|---|---|
| 1 | **The bypass removed**. `S_IDLE` only takes the copies of the operands and control (`op`/`fmt`/`rm`/`int_*`), and what was done in the `start` cycle moved to a new `S_UNP` |
| 2 | **Split the unpacking**. "What kind of value" (sign, 0, ∞, NaN, signalling) is a few comparisons and stays combinational; **only the exponents and significands are held in `S_UNP`**. The leading zero count and the full-width shift leave every later cone |
| 3 | **Partial products separated into `S_PP`**, so that unpacking → DSP multiply are not in the same cycle |
| 4 | The splits of rounding (`S_RND`) and alignment/add-subtract (`M2`/`M3`) **are kept**. A 129-bit leading zero count + normalization shift plus rounding still would not fit |

### Cycle cost

| Operation | Original | Stage 2 | After the redo |
|---|---|---|---|
| Compare / FCLASS / sign injection / FMV / FCVT | 2 | 4 | **5** |
| FADD / FSUB / FMUL / FMA | 5 | 7 | **9** |
| FDIV / FSQRT | N+3 | N+4 | **N+5** |

`t11_fp` 1390 → **1655** cycles (+19 %). **Nothing else moves by a single cycle** (`t16_bench` stays at
33556).

### Verification

| Item | Result |
|---|---|
| SoftFloat comparison (`+rand=20000`) | **PASS 4935240 checks** |
| SIM_CORE / SIM_SYS | PASS |
| riscv-tests | 132 passed / only known failures |
| SIM_FPU bug injection | **20 detected / 0 missed / 0 not applied** (3 added for the new registers) |

### Lessons

**Do not believe "the stage was split" until synthesis confirms it.** The seam meant to be split may carry
no delay at all. This time the RTL's comment itself said "the rounder is not on the path of `sp_res`", and
that was overlooked and split.

**When putting a bypass in a unit with a state machine, remember that timing analysis does not know the
states.** It creates paths that do not exist, and they become the worst paths.


---

## 11. Place-and-route results of stage 2 (the redo), and the next options (2026-09-23)

### Results

| Item | After stage 1 | Stage 2 (failed version) | After the redo |
|---|---|---|---|
| Post-synthesis WNS | -16.439 ns | -26.021 ns | **-7.448 ns** |
| Post-place-and-route WNS | -16.786 ns | -28.141 ns | **-14.049 ns** |
| Post-place-and-route TNS | -81165 ns | -126869 ns | **-64293 ns** |
| Failing endpoints | 7903 / 63179 | 8913 / 64806 | **5826 / 65430** |
| Slice LUT | 40016 (63.1 %) | 39804 (62.8 %) | **38923 (61.4 %)** |
| Achievable frequency | 27.2 MHz | 21.0 MHz | **29.4 MHz** |

Routing completed, 0 routing errors, nothing critical in DRC, hold +0.022 ns with 0 violations.

The synthesis estimate (-7.448) and the real routing (-14.049) are **6.6 ns apart**. In stage 1 they
differed by only 0.35 ns, so this family **depends strongly on routing**.

### Breakdown of the worst path by section (real routing)

All of the worst 10 are the same family `ma_rd_reg[1] → u_ifu/pq_*`. Against 9.47 ns of logic, **routing is
24.5 ns (72 %)**.

| Section | Delay | Contents |
|---|---|---|
| Forwarding mux | **5.46 ns** | `ma_rd` → match compare → `ex_a_fwd` (4.5 ns of it routing, including a fo=197 net) |
| Address add | 2.87 ns | 64-bit CARRY4 chain |
| DTLB | **6.49 ns** | vpn_match → sel → ppn (5.8 ns of it routing) |
| PMP | **10.27 ns** | The add `a_hi = paddr + size` + the CARRY4 chain of the TOR compare |
| Exception | 2.89 ns | `d_pmp_fail` → `d_tr_fault` |
| Redirect → IFU | **6.00 ns** | The flush net of fo=1127 → the whole parcel queue |
| **Total** | **33.99 ns** | Required 20 ns → **14.05 ns to cut** |

Because the FPU was always worse, **this path has never been optimized**. 5.46 ns in the forwarding mux and
10.27 ns in PMP are numbers with room left to cut.

### Options

#### Option 1 — shave in detail (cycle counts unchanged, no performance cost)

| | Contents | Expected |
|---|---|---|
| 1a | **Precompute the forwarding match**. Do the `ma_rd == ex_rs1` compare in ID and give EX only the match bits. Of the 5.46 ns, the compare and the long routing go away, leaving only the multiplexer | 2 to 3 ns |
| 1b | **`last_byte` of PMP**. `paddr + size` → `paddr \| mask`. Accesses are always naturally aligned (misaligned ones trap before reaching the MMU, the instruction side is 8-byte aligned, the PTW is 8-byte aligned too), so no carry can happen. One 54-bit carry chain goes away | 2 to 3 ns |
| 1c | **The TOR compare of PMP**: the two `a >= prev && a < this` merged into one subtraction + borrow | 1 to 2 ns |

5 to 8 ns in total → 26 to 29 ns. **Not 50 MHz, but 35 MHz.**

For 1b, tb_PMP also generates misaligned addresses, so the "aligned" assumption would have to be made
explicit by a parameter with the bench following it (`MMU_PMP` loses generality).

#### Option 2 — register the redirect (the IFU reacts one cycle later)

The 6.00 ns at the end (the fo=1127 flush net → the whole parcel queue) is cut. **The price is +1 cycle at
every misprediction, trap and fence** (misprediction penalty 3 → 4). Measurable with `t16_bench` and
`t14_mmu`.

With option 1, 11 to 14 ns → 20 to 23 ns. **Whether it just reaches 50 MHz.**

#### Option 3 — PMP in a stage of its own (pipeline +1 stage)

First half (forwarding + add + TLB) 14.8 ns / second half (PMP + exception + cache request) 19.2 ns. Both fit
in 20 ns, but the second half is tight, so it presumes option 1 too. **The price is a load-use bubble of 2 →
3.** No additional cost for stores, no replay mechanism, no change to the caches.

Note that the specification's first plan of section 3, "TLB in a stage of its own", **alone is not enough**
— the second half keeps TLB + PMP + tail at 22.8 ns. If cut, cut **before PMP**.

#### Option 4 — parallel VIPT (the specification's second plan, cycle counts unchanged)

The caches are already designed to receive `req_paddr` in "the cycle after acceptance" (`CPU_CACHE_SPEC.md`
5.6 / 7b), so the index goes out in EX and the physical tag arrives in the next cycle. **No cycle cost**,
but the caches need a kill input and a replay mechanism for TLB misses. Touching verified caches is the
biggest risk, and it is the most work of the 4 options.

#### Option 5 — lower the clock (**not recommended**)

At 30 MHz the present bitstream would already work (0.75 ns to go). But **LiteDRAM is structurally fixed
at sys4x = 4×sys** — the PLL has VCO 1600 MHz, CLKOUT0 /32 = 50 MHz (sys), CLKOUT2/3 /8 = 200 MHz (sys4x /
sys4x_dqs), CLKOUT4 /8 = 200 MHz (idelay, a fixed value IDELAYCTRL requires). Lowering sys lowers the DDR3
clock in proportion; today's 200 MHz (DDR3-400) is already below the JEDEC minimum of 303 MHz, and 30 MHz
would take it down to 120 MHz. The DLL is likely not to lock.

Putting only the CPU in a separate domain and leaving the SoC/DRAM at 50 MHz is possible, but means writing
the bus CDC ourselves, heavier than options 3 or 4.

### Decision

**Do all of option 1, synthesize again, and decide between options 2 and 3 with those numbers.**

1. Option 1 has no performance cost, and 5 to 8 ns is big enough to change the decision "add a stage or
   not" itself.
2. This path has never been optimized, so there is room left to cut.
3. Measuring before adding stages fits this project's way, as with the predictor and load-use (decisions
   36 and 37).

If option 1 reaches 35 MHz, **getting Linux through once at that point** becomes a realistic option too
(DDR3 at 140 MHz; that also needs experiment, but is more likely than 30 MHz). Once it boots, later
optimization can proceed on measurements.

## 12. Doing option 1 (2026-09-23)

As decided in section 11, the 3 items that do not change cycle counts were put in. **Waiting for
resynthesis**.

### 1a — decide the forwarding source one cycle earlier (`CPU_CORE.sv`)

The select of the `ex_a_fwd` / `ex_b_fwd` multiplexers was replaced by 4 flip-flops (`fwd_a_ma / fwd_a_wb /
fwd_b_ma / fwd_b_wb`) instead of compares like `ma_rd == ex_rs1`. Which instructions EX, MA and WB hold in
the next cycle is decided by the same signals that move the pipeline registers, so the compares against
those are done in advance and only the answers are saved. The head of the path becomes "flip-flop → 64-bit
multiplexer", and the routing of `ma_rd` and the 5-bit compare disappear.

The inputs (the flip-flops' D) take `ex_advance` and `ex_exc`, but both are signals already going into the
enables and D of the EX/MA pipeline registers, and make no new long path.

### 1b + 1c — the PMP add and compare (`MMU_PMP.sv`)

What is checked was redefined as "the naturally aligned block of 2^size bytes containing `paddr`". Its two
ends differ only in bit 0 of the word address, so:

- The 64-bit add `last_byte = paddr + size` is gone (just set bit 0)
- One `<` and one `==` of bits 53:1 per entry, shared by both ends
- The lower bound of TOR uses the negation of the previous entry's upper bound compare

Comparators go from 4 per entry to 2, from 32 to 16 for 8 entries. Each address bit also drives half as
many places, which should help a path with 72 % routing more than the level count suggests.

**Correction of a premise of section 11**: "the instruction side is 8-byte aligned" was wrong. Right after
jumping to a BTB prediction, `fetch_pc = btb_target`, which points into the middle of 8 bytes. The old RTL
checked from there to `+7`, so jumping by prediction near the end of an executable region could look at
**the next 8 bytes** and refuse by mistake (a latent bug; in Linux the regions are large and aligned, so it
would hardly ever show). The new definition checks exactly the 8 bytes being fetched, so this is fixed at
the same time. The idea of switching the alignment assumption by parameter became unnecessary with this
definition.

### Verification

| Item | Result |
|---|---|
| SIM_MMU `make pmp` / `long` / `iverilog` | PASS (200,000 / 2,000,000 / 20,000 cases) |
| SIM_MMU bug injection | **21 / 21 detected** (9 retargeted, 2 added) |
| SIM_CORE `run-all` / `iverilog` | All 17 PASS, **all cycle counts unchanged** (t16_bench 33556) |
| SIM_SYS `run-all` | All PASS, cycle counts unchanged (t16_bench 29147) |
| riscv-tests p / v | 132 / 109 passed, only known failures |
| SIM_CORE bug injection | **154 / 155 detected**. The undetected one is the known M175 (BTB quality; reason in the header) |

When 1a was introduced, a check **comparing the old compares with the new flip-flops every cycle** was put in
temporarily, and after confirming 0 mismatches over all of the SIM_CORE, SIM_SYS and riscv-tests runs above,
it was taken out. That the check works was confirmed by mismatches appearing with a version whose select was
broken.

SIM_CORE's mutations: 18 / 19 were retargeted to the new form, and 4 that break the rules of the next
state were added (188 looking at the next instruction's sources during a stall, 189 forgetting a load
waiting in MA, 190 forwarding a write to x0, 192 not looking at whether MA has an instruction). "The
select from WB does not look at MA's stall" **cannot be detected in principle**, because a stalled MA keeps
its instruction and MA's select is always set and wins. It was removed with the reason in the header.

M174 (a BTB mutation that was NOT DETECTED before) was **detected** this time. The cause was not the RTL:
the hex of the virtual memory test `rv64ui-v-add` the campaign runs existed because `make riscv-tests-v`
had been run. Removing that test made M174 undetected again, which was confirmed. The header now states
this condition.

### Found in the verification environment — Verilator merges `$urandom` ifs

Mixing misaligned addresses into tb_PMP **passed even with the old RTL**. Looking into it, every case made
misaligned overlapped a case that inverted the upper bits, giving addresses far from every region. The
cause is that **Verilator 5.020 merges two `if`s in a row whose conditions read the same into one**
(ignoring the side effect of `$urandom()`). Two consecutive lines of `if ($urandom() % 8 == 0)` meant the
second draw did not happen and gave the same answer as the first. A small reproduction confirmed that
`x & y` was exactly equal to `x` (1/8 if independent).

Fixed by drawing into variables first and using them in the `if`s, and confirmed that the old RTL now
shows mismatches (the bench works). All benches under SIM were scanned to confirm there is **no other**
place where `$urandom` `if`s reading the same stand close together.

### Next

1. Resynthesize (only the RTL changed, so no LiteX regeneration needed)
2. Take the path breakdown again in the same form as the table of section 11, and decide between options 2
   / 3

## 13. Place-and-route results of option 1 (2026-09-23)

### Results

| Item | Before option 1 (section 11) | After option 1 |
|---|---|---|
| Post-synthesis WNS | -7.448 ns | **-5.597 ns** (the worst is the FPU's rounder, below) |
| Post-place-and-route WNS | -14.049 ns | **-10.018 ns** |
| Post-place-and-route TNS | -64293 ns | **-43442 ns** |
| Failing endpoints | 5826 / 65430 | 5630 / 65436 |
| Slice LUT | 38923 (61.4 %) | **36881 (58.2 %)** |
| Slice | — | 11187 (70.6 %) |
| Achievable frequency | 29.4 MHz | **33.3 MHz** |

0 routing errors, hold +0.026 ns with 0 violations. 4.03 ns shorter, but still 10 ns short.

### Breakdown of the worst path by section (real routing)

All of the worst 10 are `u_lsu/signed_r_reg → u_ifu/*`, `u_icache/u_tag`. **The start point changed**:
with the `ma_rd` compare gone, the next longest path, "shape the load's answer and forward it to EX's
address", came to the front. Logic 6.81 ns, **routing 22.70 ns (77 %)**, 34 levels.

| Section | Section 11 | Now | Contents |
|---|---|---|---|
| Start → forwarding mux | 5.46 | **4.32** | Now the sign extension of the load answer → `ex_a_fwd` |
| Address add | 2.87 | 2.09 | |
| DTLB | 6.49 | 6.34 | vpn_match → sel → ppn / level |
| PMP compare | 10.27 | **4.43** | Up to the CARRY4 chains of `up_eq` / `up_lt` |
| Second half of PMP + exception + stall decision | 2.89 | 6.04 | sel → perm → fail → `d_tr_fault` → `ex_exc` → `ex_is_mem` |
| `ex_advance` net | — | 2.01 | fo=1144 (enables of all EX/MA registers) |
| Redirect → IFU → I$ | 6.00 | 4.28 | `redirect_valid` → IFU → read enable of the I$ tag RAM |
| **Total** | **33.99** | **29.51** | Required 20 ns → **10.02 ns to cut** |

(The section boundaries are approximate, since optimization mangles the cell names. PMP and exception
together went 13.16 → 10.47 ns, the biggest reduction of option 1.)

### The second wall — the FPU's rounder

The worst path after synthesis is the FPU's `q_rnd_exp → result` (78 levels, CARRY4 = 59); it is only
invisible because the place-and-route report shows the top 10. Fixing the core's path brings it out next.
The single cycle of S_RND holds everything: exponent subtract → 128-bit right shift → guard / sticky →
**a 128-bit-wide +1** (the significand is at most 53 bits) → exponent adjust → bias add → packing.

### What has not been measured — the cost of load-use

`t16_bench` **executes not a single load** (li / addi / branches and 4 `sd`). `t14_mmu` has 16 loads in
6738 instructions (0.2 %). So "t16_bench's cycle count did not change" says nothing about the cost of
options that add to load-use. Before deciding on option 3, a load-heavy benchmark is needed (list walks,
array processing and the like written in C, the ordinary code a compiler produces).

### Options (revised)

| | Contents | Expected | Cycle cost |
|---|---|---|---|
| A | **Take the branch redirect off the memory path**. `redirect_valid` looks at `ex_advance` and `ex_exc`, but branches do not look up the MMU, so for a branch `ex_advance` is the same as `~stall_ma` (`mdu_active` / `fpu_active` are set only while EX holds that instruction). For exceptions `ex_exc_pre` is enough too. The handling of "a load/store predicted to be a branch" from a false BTB hit needs thought | The 4.28 ns at the end goes away, and the end point becomes the `ex_advance` net. WNS ≈ -6 | **None** |
| B | **Option 3: cut a stage after the DTLB**. First half (forwarding + add + DTLB) 12.75 ns, second half (PMP + exception + request + redirect) 16.76 ns, both within 20 ns. Combined with A the second half is shorter still | WNS ≥ 0 expected | **Load-use +1**. Cannot be measured with the present tests |
| C | **Split the FPU's rounding into 2 states**, narrowing the +1 to 54 bits | Removes the -5.6 ns of synthesis | +1 per FP arithmetic instruction |
| D | Option 4 (parallel VIPT + kill) | The equivalent of B with no cycle cost | None, but touches the caches, the most work |

Neither A nor C alone reaches 0. **50 MHz needs B (or D)**.

## 14. A (separating the redirect) and C (two-stage rounder), and a load-heavy bench (2026-09-23)

As "the recommended way" of section 13 said, A, with no cycle cost, and C, which only affects FP, were put
in, and a bench was made to measure the cost of B (option 3). **Waiting for resynthesis**.

### A — two ways of fixing a wrong prediction (`CPU_CORE.sv`, decision 46)

- A misprediction of a **control transfer** (branch, JAL, JALR) is fixed from EX as before, but the
  conditions became `ex_advance` → `~stall_ma` and `ex_exc` → `ex_exc_pre`. Control transfers use neither
  the MMU nor the MDU/FPU, so for those instructions this substitution is **exactly the same**
  (`mdu_active` / `fpu_active` are set only while EX holds that instruction). The update condition of the
  BTB got the same form (its write enable was also on a long path).
- When an **instruction that is not a control transfer was predicted taken**, it is no longer fixed in
  EX; when it commits in MA, everything behind it is refetched (the same path as `fence.i` / `SFENCE.VMA`,
  `refetch_taken`). This happens when an ASID switch shows different code at the same virtual address, and
  that instruction may be a load. Fixing it in EX would put the memory path on the redirect again. Only in
  this case is it a cycle slower.

This should take **the 4.28 ns of redirect → IFU → I$ off the worst path**. The end point becomes the
`ex_advance` net (enables of all EX/MA registers, fo=1144), estimated WNS ≈ -6 ns.

None of the existing 17 tests ever caused "a misprediction of an instruction that is not a control
transfer" (counting refetches over all tests gave 0). So **`t18_asid`** was added: two page tables map the
same virtual page to different physical pages, a branch is taught to the BTB under ASID 1, and after
switching to ASID 2 without a fence, the same place holds an add, a load and a divide. It was confirmed to
fail with RTL that does not refetch. The first version did not have its first case predicted because of a
collision in the BTB index (bits 8:3), which was noticed by counting 4 refetches.

### C — a 2-cycle rounder (`FPU_ROUND.sv` / `CORE_FPU.sv`, decision 47)

Cycle 1: exponent subtract → subnormal shift → guard / sticky → round-up decision. Cycle 2: +1 (53 bits)
and packing. A carry out is known before adding, when "all the kept bits are 1 and it rounds up", so the
exponent field and the overflow decision are made for both cases in cycle 1, and cycle 2 only selects. The
unbounded-precision carry of the tininess decision took the same form, and its adder went away. The +1
that was 128 bits wide became 53 bits.

+1 cycle per FP operation (`t11_fp` 1655 → 1739, SIM_SYS 1683 → 1762).

### A load-heavy bench `t19_ldbench`

-O2 C: list walks, array sums, string scans, insertion sort. 51014 instructions and 93641 cycles on SIM_SYS
(real caches).

| | Count |
|---|---|
| Loads | 9784 (19.2 %) |
| The next instruction uses the value | **2872** |
| Only the one after next uses it | 5216 |
| Bubble today when the next instruction uses it | **None** (2473 cases with retirement interval 1) |

Option 3 (cut after the DTLB) adds 1 to load-use, so the 2872 cases used by the next instruction get one
cycle later each. **About +3 % on this load** (+3.5 % excluding the preparation waiting for divides). This
fills the "not measured" of sections 11 / 13.

### Verification

| Item | Result |
|---|---|
| SIM_CORE / Icarus | All 19 PASS. Only `t11_fp` changed (+84) |
| SIM_SYS | All 17 PASS. Only `t11_fp` changed (+79) |
| riscv-tests p / v | 132 / 109 passed, only known failures |
| SIM_FPU | 450,000 / 4.93 million cases PASS, bug injection **25 / 25** (5 added at the seams) |
| SIM_CORE bug injection | **157 / 158** (the undetected one is the known M175). 3 refetch mutations added |
| SIM_SYS bug injection | 5 / 5 |

## 15. Place-and-route results of A + C, and the next step (2026-09-23)

### Results

| Item | Section 13 (after option 1) | Now (A + C) |
|---|---|---|
| Post-synthesis WNS | -5.597 ns | **-4.712 ns** |
| Post-place-and-route WNS | -10.018 ns | **-7.255 ns** |
| Post-place-and-route TNS | -43442 ns | **-26097 ns** |
| Failing endpoints | 5630 | **4981** |
| Slice LUT | 36881 (58.2 %) | 37229 (58.7 %) |
| Achievable frequency | 33.3 MHz | **36.1 MHz** |

0 routing errors, hold +0.024 ns. **The FPU's rounder left the top** (the worst after synthesis is also
the core's path). As expected, the tail redirect → IFU went away, and the end point became the
`ex_advance` net.

### Breakdown of the worst path by section (real routing)

The start point moved one step further back, to the D$'s answer register (`d_resp_data_reg`), and the end
point is the D of `fwd_a_ma`. The rest of the top 10 are of the same depth, ending at the enables of the
D$'s `rob_*` (through `lsu_req_valid`) and the MDU's operands (through `ex_advance`). Logic 6.52 ns,
**routing 20.72 ns (76 %)**, 31 levels.

| Section | Delay |
|---|---|
| D$ answer → shaping → forwarding → `ex_a_fwd` | 4.18 |
| Address add | 2.13 |
| DTLB | 6.77 |
| PMP compare | 4.15 |
| Second half of PMP + exception + stall decision → `ex_advance` / `lsu_req_valid` | 8.05 |
| `ex_advance` → end point | 1.96 |
| **Total** | **27.24** (7.26 to cut) |

What remains is the structure itself: **deciding "may a memory request go out in this cycle" puts
forwarding → add → TLB → PMP → exception in one cycle**. There are two end points, `ex_advance` (all EX/MA
registers) and `lsu_req_valid` (the cache's input), so removing only one does not move WNS (for example,
taking the exception out of the stall decision with "stall even with an exception" leaves the request side
at the same depth).

### Next step

| | Contents | Expected | Cycle cost | Work and risk |
|---|---|---|---|---|
| **B (option 3)** | **Cut a stage after the DTLB**. EX = forwarding + add + DTLB (13.1 ns), new stage = PMP + exception + request + stall decision (14.2 ns) | 5 to 7 ns of margin in both halves | **Load-use +1: about +3 % on `t19_ldbench`**. Traps are later by MA being one stage further (negligible) | Closed within the core. The contract of the cache's input (paddr in the cycle after acceptance) stays. One more forwarding source |
| D (option 4) | No new stage; the request goes out in EX without waiting for PMP, and a kill is passed in the next cycle (the same cycle paddr is passed). PMP and exceptions to MA | About the same | **None** | Adds a kill to verified caches. Reads of the uncached region (I/O) have side effects, so the kill must be guaranteed to arrive before they reach the bus. Sharing with AMO / LR/SC / PTW is involved too |

### Proposal

**Put in B.** Reasons:

1. The cost was measured: +3 % on load-heavy C. Smaller for the Linux boot as a whole.
2. From the measured sections, both halves have 5 ns or more of margin. The most certain prospect of
   reaching 50 MHz.
3. The caches are not touched. The benefit of D (3 %) can be judged by measurement once Linux runs. Going
   from B to D is "absorb the new stage's PMP into MA", so the work of B is not wasted.

Caution: only the top 10 are visible, so after fixing this family **another family that was hidden** may
show (whether all 4981 failing endpoints are of this family is unknown).

## 16. Doing B — the MR stage (2026-09-23)

As section 15 proposed, a stage was cut after the DTLB. **Waiting for resynthesis**.

### Shape

```
 EX : forwarding → ALU / branch / address add → DTLB (up to translation faults), MDU / FPU
 MR : PMP (the physical address EX held) → exception decided → request to the D$ / stall decision
 MA : waiting for the answer, commit point (unchanged)
```

Estimated with the measured sections of section 15: EX is forwarding 4.18 + add 2.13 + DTLB 6.77 ≈ 13.1
ns, MR is PMP 4.15 + exception, request and stall 8.05 + net 1.96 ≈ 14.2 ns (both register to register,
routing included).

What was watched for timing:

- **The branch redirect does not wait for EX to advance**. Whether EX advances depends on MR's cache
  acceptance, that is, on PMP, and waiting for it would make PMP → redirect → IFU → I$ one path again
  (estimated over 18 ns). It is issued once, in the first cycle the operands are ready (`~stall_ma &
  ~lu_hazard`), and `ex_ctrl_done` stops repeats. The BTB update has the same condition.
- **The MDU / FPU `active` use `ex_exc_pre`** (not looking at translation faults). The meaning is the
  same, and it makes no DTLB → stall path.
- **The load-use decision `lu_hazard` compares MR and EX registers with each other**, so it is short.
- **The forwarding source select for all 3 sources is flip-flops decided one cycle earlier** (an
  extension of decision 44).

### Cost (measured)

| | Before | MR stage | Difference |
|---|---|---|---|
| SIM_SYS `t19_ldbench` | 93641 | 96515 | **+2874 (+3.07 %)**. Almost exactly the trace's estimate of 2872 |
| SIM_SYS `t16_bench` | 29147 | 29155 | +8 |
| SIM_SYS `t14_mmu` | 13866 | 13963 | +0.7 % |
| SIM_SYS `t05_csr` / `t07_trap` / `t12_priv` | | | +15.5 / +12.5 / +17.0 % (serialization and traps are one stage further away; tests of only CSRs and traps) |

### Verification

| Item | Result |
|---|---|
| SIM_CORE all 19 (normal + 40 % back pressure) / Icarus | PASS |
| SIM_SYS all 17 | PASS |
| riscv-tests p / v | 132 / 109 passed, only known failures |
| Checking the forwarding select (temporary) | 0 mismatches over all the runs above |
| SIM_CORE bug injection | **162 / 163** (the undetected one is the known M175). 13 retargeted, 7 added (2 of them unobservable, removed with the reasons in the header) |
| SIM_SYS bug injection | 5 / 5 (1 retargeted) |

### Next

1. Resynthesize (only the RTL changed, so no LiteX regeneration needed)
2. If WNS ≥ 0, go to booting BIOS → Linux with the bitstream (do not forget to regenerate
   `mmrisc_arty.dtb`; stage 1 changed the numbers of TLB / PMP entries)
3. If negative, take the next hidden family again in the same form as sections 11 / 13 / 15

## 17. Place-and-route results of the MR stage — 0.23 ns to go (2026-09-23)

### Results

| Item | Section 15 (A + C) | Now (MR stage) |
|---|---|---|
| Post-synthesis WNS | -4.712 ns | **-0.345 ns** |
| Post-place-and-route WNS | -7.255 ns | **-0.227 ns** |
| Post-place-and-route TNS | -26097 ns | **-3.607 ns** |
| Failing endpoints | 4981 | **43** |
| Slice LUT | 37229 (58.7 %) | 37772 (59.6 %) |
| Slice | 11513 (72.6 %) | 12061 (76.1 %) |

0 routing errors, hold +0.051 ns. **Splitting the core's EX → MR worked**. Two families remain.

### Family 1: the D$'s AMO (-0.227 ns, 26 levels, CARRY4 = 10)

Tag RAM → hit decision (tag forwarding included) → way select → merge of write forwarding → `extract` (8
byte positions + sign / zero extension) → `amo_calc` (64-bit add / compare) → `align_wdata` (shift to the
byte position) → write data of the data RAM. AMO read, operate and write in one cycle. It was invisible so
far because the core was blocked first.

### Family 2: MR → request to the D$ (-0.224 ns, 18 levels, 80 % routing)

`mr_paddr` → the multiplexer at the PMP's entry (shared with the walker, 1.03 ns) → compare → second half
of PMP + exception → request → port arbitration → enable of the D$'s `rob_data`. 5 ns longer than the
estimate of 14.2 ns in section 16: the shared multiplexer and the request input inside the D$ had not been
counted.

### What was fixed (neither changes cycle counts)

1. **AMO lanes made 2:1** (`DCACHE.sv`). Only naturally aligned words or doublewords reach the cache as
   AMOs (misaligned ones trap in the core first), so `extract` shrinks to "upper half or whole by bit 2 of
   the address" and `align_wdata` to "shift by 0 or 32 bits". Two byte shifters become two 2:1
   multiplexers. The cache bench had tried 32-bit AMOs only at the +4 position, so a check at the +0
   position, reading the whole doubleword at that time (the upper half not broken), was added. Two
   mutations (ignoring bit 2) were confirmed to fail it and put into the campaign.
2. **A PMP checker of its own for the walker** (`CORE_MMU.sv`). The multiplexer at the entry of MR's
   checker goes away. One more checker's worth of LUTs. Found on the way: **the walker's PMP check was
   covered by no test** (all tests pass with it disabled). **`t20_ptw_pmp`** was added: the lowest-level
   page table is placed in a PMP region S cannot read, and loads, stores and fetches each get an access
   fault (5 / 7 / 1), while opening the PMP (+ SFENCE.VMA) lets the same load through.

### Verification

| Item | Result |
|---|---|
| SIM_CORE all 20 / Icarus / SIM_SYS all 18 | PASS, cycle counts unchanged |
| riscv-tests p / v | 132 / 109 passed |
| SIM_CACHE | PASS (9291 checks) |
| SIM_CORE bug injection | **164 / 165** (the undetected one is the known M175). 2 mutations of the walker's PMP added |
| SIM_CACHE bug injection | **22 / 22** (2 mutations of AMO lanes added) |
| SIM_SYS bug injection | 5 / 5 |

### Next

1. Resynthesize. Both families should get 1 ns or more shorter, so WNS ≥ 0 is expected
2. If it passes, rebuild `mmrisc_arty.dtb` and go to booting BIOS → Linux with the bitstream

## 18. Results of section 17 — a hidden instruction-side path (2026-09-23)

### Results

| Item | Section 17 (MR stage) | Now (AMO lanes + walker's own PMP) |
|---|---|---|
| Post-synthesis WNS | -0.345 ns | -0.337 ns (1 endpoint) |
| Post-place-and-route WNS | -0.227 ns | **-0.924 ns** |
| Failing endpoints | 43 | 1317 |
| Slice LUT | 37772 (59.6 %) | 37792 (59.6 %) |

The two families fixed in section 17 (the D$'s AMO, MR → request) left the top. Instead, **an
instruction-side family that had been hidden** showed. Placement changed and routing got longer, so WNS is
a worse number than last time.

### Worst path (real routing 20.79 ns, 75 % routing)

`u_ifu/fetch_pc` → ITLB (vpn match → sel → ppn / level, 8.1 ns) → instruction-side PMP (the CARRY4 chain of
the compare + second half, 8.6 ns) → fault → the IFU's "send to the cache or answer itself" → write into the
parcel queue (4.0 ns).

The same shape the data side had before the MR stage — **translation and PMP in the same cycle**. The
address comes from a register (`fetch_pc`), which makes it shorter, so it had not come to the surface.

### What was fixed — the instruction-side PMP one cycle later (practically no cycle cost)

- IF1 looks only at translation faults (ITLB page faults, access faults the walk left).
- PMP is applied to the physical address `i_req_paddr` that the IFU holds to pass to the cache. That is the
  cycle the cache compares tags in stage 1, and the cache **has not yet started either the array answer or a
  bus access**.
- On a refusal, a new pin **`i_cancel`** cancels only the request in stage 1 (the I$ treats it like
  `i_kill`; SIM_CORE's memory model removes just that request from its queue of answers). No new request
  goes out in that cycle.
- The cancelled request stays in the IFU's record (`pr_cancel`), and when it reaches the head the IFU
  queues an access fault parcel. The order of answers is kept.

The only cost is that the answer of a fetch refused by PMP is one cycle later (`t13_pmp` +2). Other cycle
counts do not change.

Path estimates: IF1 is ITLB 8.1 + fault + IFU 4.0 ≈ 14 ns, IF2 is `i_req_paddr` → PMP 8.6 → cancel → I$ /
IFU ≈ 13 ns.

### Found in verification

The mutation "use the refusal decision also in cycles without a request just issued" was not detected by
the existing tests. It would be a real bug: cancels continue with an old address and new requests never go
out. Every refused fetch in the existing tests trapped to M, and M is not bound by unlocked entries, so it
resolved itself when the privilege changed. `t13_pmp` gained "an instruction access fault **delegated to
S**". After the trap it is still S, so the fetch from `stvec` starts with the same entry still applying. It
was confirmed to fail with that mutation.

The two on the cache side (the I$ not looking at `i_cancel`, making a new request in the cycle of the
cancel) are invisible to the memory model, so they went into the SIM_SYS campaign (both detected).

### Verification

| Item | Result |
|---|---|
| SIM_CORE all 20 (normal + back pressure) / Icarus / SIM_SYS all 18 | PASS |
| riscv-tests p / v | 132 / 109 passed |
| SIM_CACHE / SIM_CPU | PASS (9291 / 46718 checks) |
| SIM_CORE bug injection | **168 / 169** (the undetected one is the known M175). 5 I-side mutations added, 1 retargeted |
| SIM_CACHE bug injection | 22 / 22 (1 retargeted) |
| SIM_SYS bug injection | **7 / 7** (2 mutations of the I$ cancel added) |

### Next

1. Resynthesize
2. If WNS ≥ 0, rebuild `mmrisc_arty.dtb` and go to booting BIOS → Linux

## 19. Timing met at 50 MHz (2026-09-24)

| Item | Value |
|---|---|
| Post-place-and-route WNS | **0.000 ns** ("All user specified timing constraints are met") |
| TNS / failing endpoints | 0 / 0 (of 67076) |
| Hold | +0.026 ns, 0 violations |
| Routing errors | 0 |
| Slice LUT | 37840 (59.7 %) |
| Slice Register | 21998 (17.4 %) |
| Slice | 12132 (76.5 %) |
| Block RAM Tile | 44 (32.6 %) |
| Post-synthesis estimate | -0.345 ns (shortened by place and route) |

The bitstream `build/gateware/digilent_arty.bit` came out.

### Zero margin

Every path within 0.06 ns is **the FPU's assembling of the answer** (`a_exp` → `q_sp_res`, `S_SEL`). What
was -0.345 ns in the synthesis estimate fit at 0 after place and route. The next time the RTL changes, it
is likely to swing negative again. Two measures for that: move the conversions (integer ↔ floating point)
inside `S_SEL` into a state of their own (+1 for some FP instructions), or raise the effort level of
Vivado's place and route (no cycle cost, longer builds). First, run it on the board and give priority to
booting Linux.

### The road so far

| Section | Change | Post-place-and-route WNS | Cycle cost |
|---|---|---|---|
| 3 | First full synthesis | -20.442 | ― |
| 7 to 8 | BTB in distributed RAM, TLB / PMP to 8 entries | -16.786 | None |
| 9 to 11 | Cut the FPU right after unpacking | -14.049 | FP operations +4 |
| 12 to 13 | Forwarding select precomputed, PMP on aligned blocks | -10.018 | None |
| 14 to 15 | Branch redirect off the memory path, 2-stage rounder | -7.255 | FP operations +1 |
| 16 to 17 | **MR stage** (cut after the DTLB) | -0.227 | Load-use +1 (`t19_ldbench` +3.07 %) |
| 18 | AMO lanes, walker's own PMP | -0.924 (the instruction side showed) | None |
| 19 | **Instruction-side PMP one cycle later** | **0.000 (met)** | +1 only for fetches refused by PMP |

### Toward the board

The DTS had TLB / PMP changed to 8 in section 7, so `mmrisc_arty.dtb` and `software/boot/fw_jump.bin` were
rebuilt with `scripts/build_opensbi.sh` (the script confirmed that the embedded tree is mmRISC-2's, with
`d-tlb-size` / `i-tlb-size` / `riscv,pmpregions` all 8).

The procedure is in `software/boot/README.md` and `docs/BRINGUP.md`:

1. Program the bitstream and check the LiteX BIOS banner on the serial port at 115200 bps
2. Replace `fw_jump.bin` on the SD card's FAT partition (`Image` and `boot.json` stay those of the Rocket
   configuration)
3. `sdcardboot` at `litex>`

## 20. Board: stopped at 16 characters of the banner — interrupts did not come (2026-09-24)

Programming the timing-met version (section 19) printed only `        __` on the terminal. That is the
**beginning** of the LiteX banner; the CPU had fetched the BIOS from ROM, run C and written to the UART.

### Cause

- The BIOS's UART is interrupt-driven (`UART_INTERRUPT`). The first 16 characters go straight into the TX
  FIFO; after that they pile up in a ring buffer that the interrupt handler sends out. Newline + `\e[1m` +
  `        __` + a space = exactly 16 characters.
- Interrupts did not come. **The priority of source 1 of the PLIC stayed 0** (priority 0 means "never
  interrupt").
- The D$ sent uncached loads / stores to AXI-Lite with **the address rounded to 8 bytes**. The built-in PLIC
  decides which half of a 32-bit register is meant by bit 2 of the address, so a write to `0x0C00_0004` (the
  priority of source 1) had bit 2 as 0 and was dropped looking at the strobes of the lower half. Reads
  likewise: rounding makes a read of claim (+4) indistinguishable from a read of threshold (+0) (claim has
  side effects).

### Why it was not seen before

| Environment | Reason |
|---|---|
| SIM_CORE (`t15_plic`) | The memory model passed byte addresses to the PLIC |
| SIM_SYS / SIM_CPU | The external interrupt line was tied to 0. No test used the PLIC through CPU_TOP |
| `make romboot` | A small stub that looks only at uncached fetch |

**The real BIOS had never been run with interrupts.**

### Reproduction and fix

`SIM/SIM_BIOS` was made: CPU_TOP + real caches + the real `bios.bin`, and on the peripheral side ROM / SRAM
/ ctrl / timer0 and LiteX's UART (as `uart.py`: 16-entry FIFO, the TX event a level of "not full", the
interrupt pending & enable). With the UART at the board's speed (4340 cycles per character), **it stopped at
the same 16 characters as the board** (`prio[1]=0`, 0 traps). With a fast UART the FIFO does not fill and no
interrupt is needed, so at first it did not reproduce.

The fix is 2 lines of the D$: send uncached addresses **at byte granularity** (`DCACHE.sv`,
`CPU_CACHE_SPEC.md` 5.5). That is legal for AXI4-Lite, and the data lanes are given by the strobes as
before. LiteX's AXI-Lite → Wishbone conversion drops the low 3 bits, so the SoC outside is not affected.
SIM_BIOS after the fix: banner, SoC information, up to `Initializing SDRAM` (the DDR calibration after that
is not modelled and fails).

`make check` (SIM_BIOS) became a regression test: with a UART of 2000 cycles per character, PASS if it
reaches `Initializing SDRAM` and has taken at least one UART interrupt (749 of them, 2.98 million cycles, 5
seconds of real time). Confirmed to FAIL with the rounded address back.

### Verification

| Item | Result |
|---|---|
| SIM_BIOS `make check` | PASS (FAIL before the fix) |
| SIM_CACHE / SIM_SYS (+ romboot) / SIM_CPU | PASS |

The change to the D$ is only the input of a register on the uncached path and should not affect timing.
But as section 19 said, the FPU's `S_SEL` has zero margin, so resynthesis may swing negative.

## 21. -0.034 ns with JTAG added — placement noise (2026-09-30)

Resynthesizing with debug mode (section 11 of `CPU_CORE_SPEC.md`) and JTAG on PMOD JA added gave a
post-place-and-route WNS of **-0.034 ns** (3 endpoints, TNS -0.083 ns). On the board both Linux and JTAG
work.

| Slack | Start → end | Family |
|---|---|---|
| -0.034 ns | `u_csr/pmpaddr` → PMP → `mr_pmp_fail` → D$ tag read (`rd_valid`) | MR stage's PMP → request (sections 16 and 17) |
| -0.026 ns | `u_fpu/u_op` → `u_fpu/al_st` | FPU (the zero-margin family of section 19) |
| -0.023 ns | `fwd_a_ma` → `mr_exc_tval_r` | Forwarding → address → MR |

All 3 **do not go through the debug logic**: known, unrelated paths, each failing by a few tens of ps. WNS
so far also moved within this range at every change, +0.013 to +0.131 ns. It is noise from placement
changing as logic grows; a problem of having no margin, not of the design.

Dealt with on the flow side: `--vivado-post-place-phys-opt-directive AggressiveExplore` and
`--vivado-post-route-phys-opt-directive AggressiveExplore` were added to `build_soc.sh` (physical
optimization after placement and after routing; replicating drivers and rerouting usually win back tens to
hundreds of ps). Several minutes more of run time. If that is not enough, cut the path itself (PMP → D$
request).

Result (2026-10-01): post-place-and-route WNS **+0.040 ns** (MET). The RTL is the same; the flow change
alone brought it back. The margin is still only tens of ps, so the same noise can happen the next time
logic is added.

## 22. Getting margin in the FPU (2026-10-01)

Of the worst 10 paths of the version of section 21 (+0.040 ns), 5 were in the FPU.

| Slack | Path | Levels |
|---|---|---|
| +0.040 ns | `u_fpu/a_exp` → `q_sp_res` (floating point → integer conversion) | 54 (CARRY4 37) |
| +0.117 ns | `u_fpu/a_exp` → `al_st` (the sticky of the multiply-add alignment) | 56 (CARRY4 41) |

Both made the sticky bit with `|(v & ((1 << n) - 1))`. `(1 << n) - 1` is a subtraction as wide as v (64 /
128 bits), putting 16 / 32 levels of CARRY4 straight into the middle of the path. The conversion also had
the rounding +1, a range compare and a negation (~v + 1) in series after it.

### Changes

1. **Make the sticky masks with comparisons**. Each bit of the mask is "i < n", just 128 comparisons of 7
   bits (2 levels of LUTs) side by side. No carry chain. In 3 places: `shr_jam` (alignment), the
   conversion, and the denormalizing shift of `FPU_ROUND`.
2. **Split the floating point → integer conversion into 2 cycles**. S_SEL makes and holds the integer
   part, guard and sticky; S_RND does the rounding, range check and negation. S_RND is the first cycle of
   the rounder, and the conversion does not use the rounder, so **the cycle count does not grow**. The range
   check uses the value before +1 (v > lim, or v == lim and rounding up), and the negation, as "~v + 1, or ~v
   when rounding up", runs side by side with the adder. The shift amount 63 − a_exp became the 6-bit
   inversion ~a_exp[5:0].
3. On the way, the runner-up that is not the FPU (+0.055 ns, forwarding → address → DTLB → fault → `ex_exc`
   → the select of `mr_exc_tval_r`) was removed too. For a load / store without an earlier exception, tval is
   its own address whatever the exception, so the address is selected without waiting for the DTLB's answer
   (`CPU_CORE_SPEC.md` decision 55).

### Verification

| Item | Result |
|---|---|
| SIM_FPU (SoftFloat comparison) | PASS, 579000 checks (`make long`, 5064000 checks, PASS too) |
| SIM_BIOS `make linux-sd` | Linux boots from the SD model to the shell |
| SIM_FPU bug injection | All 33 detected (9 new: mask boundaries, the conversion split, range check before +1) |
| SIM_CORE all tests, back pressure, Icarus, riscv-tests (p 132 / v 109) | PASS |
| SIM_CORE bug injection M232 (tval) | Detected |
| SIM_SYS / SIM_BIOS | PASS |

tb_FPU's operands gained ties of x.5 (1.5, 2.5, −2.5 and so on) and values 0.5 below the limits of 32-bit
integers (2^31 − 0.5, 2^32 − 0.5, −2^31 − 0.5). Ties of round-to-nearest-even and values that "go out of
range only when rounded up" almost never come from random numbers, and the new mutations of the conversion
were being missed. No mutation is placed on the mask boundary of `FPU_ROUND`'s denormalizing shift: the bits
lost are 74 places or more below guard, and every bit left there also goes into sticky, so whichever way the
boundary bit is counted, the result does not change (for the same reason a mutation "throw away the lost
bits" was not observable in this FPU's operations either).

### Remaining paths

The next limit is **PMP → D$ request** (+0.043 ns). `pmpaddr` → PMP compare → `mr_exc` → `lsu_req_valid` →
D$ port arbitration (`CACHE_PORT_ARB` looks at the CPU's valid to decide whether to pass it or the DMA /
debugger) → the address and read enable of the D$'s tag / data RAM. The RAM address waits for the PMP's
decision. Removing it needs a change on the cache side so that the arbitration and the RAM's read enable do
not depend on valid (not started).

### Result (2026-10-01)

Post-place-and-route WNS **+0.205 ns** (MET, +0.165 ns from the +0.040 ns of section 21). WHS +0.050 ns. The
FPU left the worst 10. LUT 39233 (61.9 %), FF 24740 (19.5 %), BRAM 40.5.

| Slack | Path |
|---|---|
| +0.205 ns | `ex_rs1_data` → `fwd_b_ma` (forwarding source select, decision 44) |
| +0.251 ns | `pmpaddr` → PMP → write enable of the D$'s ROB (`rob_data` CE) |
| +0.254 ns | `pmpaddr` → PMP → MDU state |

What remains is the two families, forwarding and PMP → D$ / MDU. The measure for PMP → D$ (separating the
arbitration and the RAM read from valid) is held off now that there is 0.2 ns of margin. The next time logic
is added and it swings negative, cut here first.

## 23. The larger branch predictor: +0.002 ns (2026-10-02)

BTB 256 entries + return address stack (`CPU_CORE_SPEC.md` decisions 56 and 57). LUT 41,655 (65.7 %).
Post-place-and-route WNS **+0.002 ns** (MET). 9 of the worst 10 start at `u_csr/pmpaddr` and go through the
PMP compare → `mr_exc` → `lsu_req_valid` → **the stall net** (`stall_mr` → `stall_ex` → `ex_advance` /
`id_advance`) to the fetch queue's `pq_count`, `ex_valid`, the MDU / FPU state and the D$'s tag read. The
remaining one is `u_lsu/size_r` → MDU state (the same net). The BTB and IF1 do not appear at the top.

The PMP decision being wired directly into stopping / advancing the whole pipeline is the structural
limit. Shortening load latency (A of `LitexSystem/docs/BENCH.md`) by issuing the request to the D$ from EX
would make PMP act only on cancelling the request and on exceptions, taking it out of the stall net
(`RTL/CPU/CPU_CORE/PLAN_LOAD_LATENCY.md`).


## 24. The version of A2 (loads and stores issued from EX): +0.004 ns, and the work on it (2026-10-02)

The version with A2 (section 6 of `RTL/CPU/CPU_CORE/PLAN_LOAD_LATENCY.md`) has a post-place-and-route WNS of
**+0.004 ns** (MET). PMP left the stall net, but the worst 10 were **3 separate families**.

| Family | Path | Slack |
|---|---|---|
| 1 | D$ answer register → forwarding from MA → the add of `jalr`'s target in EX → compare with the predicted target → **redirect** → the IFU's request condition (`req_want`) → the MMU's instruction-side answer (which looked at `i_req`) → `use_pred` → write enable of the return address stack (64 bits × 8) | +0.004 ns (4 paths) |
| 2 | D$ tag → hit → way select → **AMO operation** → write data of the data array (a path since section 17) | +0.008 ns |
| 3 | `pmpaddr` → PMP compare → `lsu_e_go` → `d_req_cancel` → the D$'s cancel → `d_req_ready` → accepting the request → write enable of the ROB data | +0.008 ns |

In family 1 the problem is not the redirect itself, but that **the redirect went through 6 levels of logic
inside the IFU** before reaching the write enable. In the cycle of a redirect the IFU's state takes the
redirect branch, so `use_pred` and `push_req` need not look at the redirect.

The work (cycle counts unchanged except for AMO):

| Family | Change | Equivalence |
|---|---|---|
| 1 | Remove the redirect from the IFU's `req_want` / `use_pred` / `push_req` / `local_resp`, keeping it only in the signals that go out (`tr_req`, `i_req_valid`, `i_cancel`) | In the cycle of a redirect the state takes the redirect branch, so the same |
| 1 | The MMU's instruction-side answers (`i_ready` / `i_fault`) do not look at `i_req` | The IFU uses the answers only combined with its own request |
| 1 | The I$'s `i_req_ready` does not look at `i_kill` / `i_cancel` | The core makes no request in a kill / cancel cycle. A request arriving in the cycle a miss is killed just waits one cycle |
| 2 | **AMO hits in 2 cycles**: cycle 1 takes the old value into a register (`amo_old_r`), cycle 2 computes from it and writes | +1 cycle per AMO. If the arrays are read again in between (`s1_data_ok` drops), the old value is taken again too |
| 3 | The D$'s `d_req_ready` does not look at the cancel (`s1_can_go`). A cancelled request leaves stage 1 in that cycle, but whether to accept the request behind is decided without knowing about the cancel | Only when the cancelled request would have waited anyway (a miss with no free MSHR and so on) does the one behind wait one cycle |

A report that shows only the top 10 does not tell how many paths stand behind them.
`LitexSystem/scripts/timing_paths.tcl` (`timing_paths.bat`) opens the `digilent_arty_route.dcp` the build
left and lists the worst path for each end point of the CPU clock, 300 of them (no resynthesis, 1 to 2
minutes).

Verification: SIM_CACHE (64,853 checks), SIM_CORE (25 tests, with back pressure, Icarus), riscv-tests p 132 /
v 109, SIM_SYS (with / without back pressure), SIM_DBG, SIM_OCD, BIOS, Linux boot from the SD model. The
cycle counts of CoreMark / Dhrystone do not change (no AMO in the timed parts). The mutations: 2 new
(SIM_CACHE M37: an AMO writes in cycle 1, SIM_SYS M12: a fetch goes out in the cycle of a redirect) and 9
existing ones whose lines changed (SIM_CACHE M2 / M13 / M33, SIM_CORE M205 / M207 / M208, SIM_SYS M4 / M5),
all detected. SIM_SYS M4 had stopped matching since A2 and was fixed here. A mutation that removes retaking
the AMO's value is equivalent (the only one that writes that word in between is stage 1 itself), so it is
not listed, with the reason in `SIM/SIM_CACHE/bug_inject.sh`.

**Result (2026-10-03)**: post-place-and-route WNS **+0.346 ns** (MET, +0.342 from +0.004). Linux boots on
the board, CoreMark 2.213 /MHz, Dhrystone 1.298 DMIPS/MHz (the same as the previous version).

The breakdown of the worst 300 end points of the CPU clock seen with `timing_paths.tcl` (+0.346 to
+0.929 ns):

| Start → end | Paths | Worst |
|---|---|---|
| `pmpaddr` → write enable of the D$'s tag array (dirty bit) | 16 | +0.346 |
| `pmpaddr` → the D$'s data array (write data / enable) | 174 | +0.372 |
| `pmpaddr` → the D$'s MSHR store data, ROB data, `m_axil_*`, write-back tags | 104 | +0.606 and up |
| Others (the debugger's register number → I$ / IFU, D$ → the IFU's queue) | 6 | +0.745 and up |

Families 1 and 2 left the top 300. What remains is the single family **PMP → cancel → the writes of a store
in stage 1**. A store writes the arrays in stage 1, so the cancel cannot be removed from the write enables.
The next time margin is needed, either issue only stores (accesses with side effects) after waiting for the
PMP result (not from EX but in the cycle after MR), or do the PMP decision when filling the TLB and keep it
in the TLB (Rocket's way).

## 25. The version with the shorter multiply: +0.162 ns (2026-10-03)

`CPU_CORE_SPEC.md` decision 61 (the answer of MUL / MULW combinationally from the partial product registers
to MR). Post-place-and-route WNS **+0.162 ns** (MET). The multiplier's paths are not in the worst 300
(+0.162 to +0.698 ns). The breakdown is the same families as section 24: PMP → cancel → the D$'s stage 1
writes (ROB data, MSHR store data, data array, `m_axil_awaddr` and so on) 255 paths, D$ answer → forwarding
→ redirect → IFU (`head_pc` / `pq_*`) 57 paths, D$ answer → MDU start 1 path. The difference from the
+0.346 ns of section 24 is within placement noise.

## 26. The version with early termination of divide: +0.525 ns (2026-10-03)

`CPU_CORE_SPEC.md` decision 62 (the leading zeros → shift placed independently in the cycle after the
start). Post-place-and-route WNS **+0.525 ns** (MET, the largest so far). The worst 300 (+0.525 to
+1.039 ns) are, except for one, **all PMP → cancel → the D$'s stage 1 writes** (data array 196 paths, MSHR
store data, write-back tags and lines, forwarded data). Neither the divider nor the multiplier is there.
The family D$ answer → redirect → IFU (57 paths in section 25) also left the 300.

## 27. The gshare version: +0.094 ns (2026-10-03)

`CPU_CORE_SPEC.md` decision 63 (PHT 8192 × 2 bits, distributed RAM). LUT 42,323 (66.8 %, of which
distributed RAM 1,844). Post-place-and-route WNS **+0.094 ns** (MET). The worst 300 (+0.094 to +0.734 ns)
are **all** PMP → cancel → the D$'s stage 1 writes (write-back tags, data array, MSHR lines, valid / dirty
of the tag array and so on). gshare's table lookup (fetch address → PHT → direction → next fetch address)
is not there. It fell from the +0.525 ns of section 26 because more LUTs crowded the placement around the
D$; the shape of the path is the same.

This family is now the only limiter. The next time something is added and margin runs short, remove it
with one of the 2 measures of section 24 (issue only stores after waiting for the PMP result, keep the PMP
decision in the TLB).

## 28. Removing the PMP → cancel → D$ family (2026-10-03)

The worst 300 of section 27 all went from `pmpaddr` through the PMP compare (about 11 ns) → `mr_pmp_fail` →
`lsu_e_go` → `d_req_cancel` → the D$'s `s1_kill` into the write enables of almost everything the D$'s stage
1 writes (allocating an MSHR, write-back tags, valid / dirty of the tag array, write data of the data
array, forwarded data). About 5 ns and 6 levels of logic inside the D$ alone.

Two measures. Neither changes the behavior (a cancelled request leaves nothing behind,
`CPU_CACHE_SPEC.md` decision 16).

**D$: narrow what the cancel reaches down to a few flip-flops**

| Target | Change |
|---|---|
| Everything but hits (allocating an MSHR for a miss / joining a fill, uncached, fence, flush, write-through) | Acts **from the second cycle of stage 1** (waits while `s1_first`). The cancel comes only in the first cycle, so this logic does not look at it. A miss is one cycle later, small next to the 30 or so cycles of a fill (CoreMark +4 cycles) |
| ROB data of a hit, the AMO's old value, the data of the fast answer | Written regardless of the cancel (the slot of a cancelled request is thrown away silently) |
| What looks at the cancel on a hit | Only the ROB's silent, the valid of the fast answer, the reservation (LR / SC) and the write enable of the data array |
| The tag write of a store hit | Written regardless of the cancel. Tag and valid are the same values as before, and dirty writes its old value when cancelled (only the value, not the write enable, depends on the cancel) |
| Write data of the data array | Chosen only by whether it is an AMO (looking at neither hit nor cancel) |

**PMP: do not select the winning entry's configuration**

It made the lowest match one-hot (one adder), compared the one-hot of both ends, selected the winning
entry's cfg and then decided the permission. Whether each entry "refuses this access" depends only on
registers, so it is made in advance, and what remains is ORing over the entries "the lowest match of the
lower end, and refuses, or is not the lowest match of the upper end". The priority among matches is taken
by a NOR of the lower matches instead of an adder.

Verification: SIM_MMU's PMP (200,000 cases, all 21 mutations detected; the 9 whose lines changed were
rewritten), SIM_CACHE (section 19 gained cancelling an LR that hits, the reservation surviving a cancelled
SC, and a cancelled store to a clean line not setting dirty), all regressions, Linux boot.

**Result**: post-place-and-route WNS **+0.661 ns** (+0.57 ns from the +0.094 ns of section 27). **+0.681 ns**
with the version that put the SD's I/O into the I/O blocks (round 13 of `BRINGUP.md`). The worst 300 of this
version (+0.681 to +1.390 ns) have not a single path from PMP. At the top are D$ answer → forwarding →
redirect → the IFU's queue (`pq_*`) and the I$, and the debugger's `dra_state` → IFU.

## 29. The late-branch version: +0.301 ns, and how the BTB's update source is chosen (2026-10-03)

The version with late branches (`CPU_CORE_SPEC.md` decision 64) has a post-place-and-route WNS of
**+0.301 ns** (MET). 289 of the worst 300 were one new family:

`owner` of `CACHE_PORT_ARB` → valid of the answer → `stall_ma` → `mr_late_go` → **the select of the BTB's
update source (MR or EX)** → update address → read of the BTB's array (`RAMD64E`) → tag compare → write
enable (19 levels).

While a late branch is in MR, control transfers in EX wait, so selecting the update source with
`mr_late_pend` (a late branch in MR), which comes from a register, is the same. Only the write enable
(`mr_late_go` of `btb_upd_valid`) waits for the cache's answer now. By the same logic, the answer leaves the
address and the array read. The remaining 11 are shapes from before, like D$ answer → forwarding → IFU
(`head_pc`).

**Result**: WNS **+0.306 ns** with the resynthesized version (Linux boots on the board, CoreMark 2.429 /MHz,
Dhrystone 1.451 DMIPS/MHz). The BTB family left the worst 300, but the margin did not grow: another family
was above it (section 30).

## 30. A path made by the check of an exception that cannot happen (2026-10-03)

The worst 300 after the work of section 29 (+0.306 to +1.080 ns) almost all start at `ma_signed` (the
select of the sign extension of a load in MA) and go through forwarding from MA → **EX's branch compare**
(7 levels of CARRY4) → ... → the MMU's page table walker → `CACHE_PORT_ARB` → acceptance of the D$'s
request → ROB (24 levels).

On the way was EX's exception check `take_branch && target_pc[0]` (instruction address misaligned). With the
C extension, instructions are 2-byte aligned, and the targets of branches and jumps are never odd (JALR
drops bit 0, the offsets of branches and JAL are even, and the PC is even). This check can never be true,
but synthesis does not know the PC is even, so it put the branch compare's result into `ex_exc_pre`.
`ex_exc_pre` acts on the DTLB's request (`d_tr_req`) → walker → D$ request, and on the forwarding select
(`nx_mr_wr` → `fwd_a_mr`). The check was removed (no behavior change; all regressions pass, riscv-tests'
`ma_fetch` included). What remains is branch compare → redirect → IFU (`head_pc`, +0.70 ns), which is the
real path.

**Result**: post-place-and-route WNS **+0.121 ns** (MET). Linux boots on the board, CoreMark 2.429 /MHz,
Dhrystone 1.451 DMIPS/MHz (unchanged). Since section 24 WNS swings between +0.1 and +0.7 ns (even with paths
of the same shape, it depends on where the optimization of place and route stops). The performance work was
brought to a close here (`ROADMAP.md`).

## 31. The ISA extension versions (Zba/Zbb, Sstc, Sdtrig/Zicond/PMU): +0.381 to +0.491 ns (2026-10-04 to 05)

Three versions after the performance work (sections 24 to 30) that added instructions and CSRs. None needed
timing work.

| Version | WNS | LUT |
|---|---|---|
| Zba / Zbb (`CPU_CORE_SPEC.md` decision 65, EX's ALU) | +0.491 ns | |
| Sstc (decision 66, CSR) | +0.381 ns | |
| Sdtrig, Zicond, PMU (decisions 67 to 69) | **+0.452 ns** | 45,598 (71.9 %, +2.7 thousand) |

Trigger matching is placed in MR, avoiding EX's DTLB and D$ request paths (decision 67), and the
performance counters count events after first registering them (decision 69), so neither is on the
critical path.

The worst paths of the last version (the head of the 300 of `timing_paths.tcl`):

- **+0.452 ns**: `ma_size` (size of the load in MA) → extracting the load's value → forwarding → EX's branch
  compare → redirect → IFU (`pq_head`, `head_pc`). The real path left at the end of section 30.
- **+0.458 ns**: `dbg_regno_q` (the debugger's register number) → CSR read address → `csr_exists` (deciding
  whether a CSR exists) → EX's exception (illegal CSR instruction) → `lsu_e_valid` → D$ request → tag read.
  More CSRs for triggers and performance counters made the `csr_exists` decision deeper. **A path in form
  only**: CSR instructions do no memory access, so the illegal-instruction check of a CSR never affects the
  request of a load or store (when the debugger reads a CSR, nothing is being issued). As in section 30,
  making the exception used for load / store requests one that does not include the CSR check would remove
  it. A candidate for when margin is needed.
- `pmpaddr` → the D$'s ROB (what remains of the family removed in section 28).

## 32. The L2 cache version: +0.159 ns (2026-10-07)

The version with `RTL/CPU/CPU_L2` (256 KB, `CPU_L2_SPEC.md`) between the L1 and LiteDRAM.

| | Without the L2 (section 31) | With the L2 | Difference |
|---|---|---|---|
| WNS | +0.452 ns | **+0.159 ns** | −0.29 ns |
| LUT | 45,598 (71.9 %) | 46,957 (74.1 %) | +1,359 (1,078 for the L2 alone) |
| FF | 27,006 | 28,019 (22.1 %) | +1,013 |
| Slices | 88.6 % | **91.4 %** (14,481 / 15,850) | +2.8 points |
| Block RAM | 40.5 | **108.5 / 135** (80.4 %) | +68 |

**The L2 is not on the critical path**: none of the 300 of `timing_paths.tcl` goes through the L2
(register to register +5.98 ns for the L2 alone, `FPGA/L2_OOC`). The top 40 of the 300 all start at
`ma_mem`:

- **+0.159 ns** (23 logic levels, 74 % routing): `ma_mem` (whether MA's instruction is a memory
  instruction) → select of forwarding from MA → EX's operand → address add (`mr_vaddr`, 6 levels of CARRY4)
  → DTLB tag compare (CARRY4) → decision whether to walk the page table (`ptw_vpn_r`) → the LSU's stall →
  clock enables of FPU / IFU state (`FSM_sequential_state`, `tg_data`). The same family "forwarding from MA
  → EX" as the head of section 31 (`ma_size` → forwarding → branch compare → IFU), with the destination
  moved to the DTLB and the stall wiring.

Slices rose to 91 %, placement got crowded, and the longer routing of the same logic (about 0.3 ns) showed
in WNS. The L2's arrays (68 tiles) use most of the block RAM columns of the die, and the logic around the
core was pushed together.

**Candidates for the next work** (before adding logic as in C2):

1. **Separate EX's stall from the DTLB compare**: a DTLB miss only needs to be known in MR (walking the page
   table starts from the next cycle), and there is no need to make a stall in the same cycle from EX's
   compare result. Registering the DTLB compare result would stop this family at "forwarding → add → DTLB
   compare". How far it can be delayed (cancelling the D$ request when the stall comes one cycle later)
   needs study.
2. **Duplicate `ma_mem`**: reduce the fanout of the first level (`wb_data[63]_i_4`, 72). A small measure
   whose effect depends on placement.


## 33. The version with the pipelined FPU (C2 stage 2): +0.286 ns (2026-10-09)

The version with the core's `CORE_FPU` replaced by `FPU_PIPE` and the register files as 2 banks of
distributed RAM + LVT (`CPU_CORE_SPEC.md` 10.11.2).

| | L2 version (section 32) | FPU_PIPE version | Difference |
|---|---|---|---|
| WNS | +0.159 ns | **+0.286 ns** | +0.13 ns |
| LUT | 46,957 (74.1 %) | 46,121 (72.75 %), of which LUT RAM 2,441 | −836 |
| FF | 28,019 (22.1 %) | 24,730 (19.5 %) | −3,289 |
| Slices | 91.4 % (14,481) | **89.0 %** (14,104 / 15,850) | −377 |
| Block RAM | 108.5 | 108.5 | 0 |
| DSP | 32 | 32 | 0 |

**Logic was added, yet it got smaller**. The −3,289 FFs are the two register files that were made of FFs
(4,096 FFs and the read multiplexers) becoming distributed RAM, minus the FPU's pipeline registers (+623 on
its own) and the scoreboards (64 bits). LUTs also went down, by the FPU itself, whose state machine
multiplexers disappeared (−697 on its own, `FPGA/FPU_OOC`), and by the read multiplexers of the register
files. Stage 0 (cutting logic) is not needed.

**The FPU is not on the critical path**: of the 300 (+0.286 to +1.112 ns), only 1 ends in the FPU
(+0.810 ns, `ma_signed` → … → the divide's `ds_busy`, a path where MA's stall acts on `hold`). The start
points of the 300 are mostly the D$ (`s1_addr`), the `ma_signed` / `ma_mem` family and `pmpaddr`:

- **+0.286 ns** (29 logic levels, 13 CARRY4, 71 % routing): `pmpaddr` → PMP range compare (CARRY4 chain) →
  MA's exception cause → MA's exception → the LSU's count of outstanding accesses (`os`) → the D$'s
  `s1_valid` → write of the D$'s reorder buffer for reads (`rob_data`).
- **+0.303 ns** (23 logic levels): the same "forwarding from MA → EX's address add → DTLB compare → stall →
  IFU (`pq_head`)" as the head of section 32.

The candidates of section 32 (separating EX's stall from the DTLB compare, duplicating `ma_mem`) remain
valid as they are.

## 34. The version with the FSD early issue fixed: +0.113 ns (2026-10-09)

The version of section 33 with one term `~fp_wait` added to the LSU's early issue from EX (`lsu_e_valid`)
(section 16 of `BENCH.md`).

| | Section 33 | This version |
|---|---|---|
| WNS | +0.286 ns | **+0.113 ns** |
| LUT | 46,121 (72.75 %) | 44,833 (70.7 %) |
| FF | 24,730 | 24,712 |
| Slices | 89.0 % | **86.2 %** (13,664) |

The logic change is one AND term, so LUTs going down by 1,288 and slices by 440 are synthesis and placement
noise. WNS is thought to have moved within that noise too (the 300th path is +0.975 ns, a little lower
overall than the +1.112 ns of section 33).

**The worst path is not the term that was fixed**:

- **+0.113 ns** (24 logic levels, 6 CARRY4): `dbg_regno_q` (the register number of the debugger's abstract
  command) → select of the CSR file's read address (`dbg_csr_sel ? dbg_regno_q : ex_csr_addr`) → the check
  of whether the CSR exists and is permitted (CARRY4 of range compares) → EX's exception → stall → the FPU's
  P0 and the divide's `ds_busy`.
- +0.402 / +0.477 ns also start there and go to the D$'s `rob_data` and the IFU's `pq_head`.

The check of the CSR's existence and permission is an EX path that has been there all along; the debugger's
number is only the other input of its read address multiplexer. The debugger reads CSRs only while halted
(the pipeline empty), so **building EX's exception check from `ex_csr_addr` alone** (with a separate check
for the debugger) would take this start point off the path entirely. It is MET now, so the work is held
off, as a candidate for the next time margin is needed (alongside the 2 candidates of section 32).

## 35. EX's CSR checks separated from the debugger's number (T1): +0.048 ns (2026-10-10)

The version with T1 of `ROADMAP.md` (`CPU_CORE_SPEC.md` decision 70): the CSR checks of EX are made from
`ex_csr_addr` alone, and the debugger's number goes only to the read data.

| | Section 34 | This version |
|---|---|---|
| WNS | +0.113 ns | **+0.048 ns** |
| WHS | | +0.024 ns |
| LUT | 44,833 (70.7 %) | 45,530 (71.8 %) |
| FF | 24,712 | 24,709 |
| Slices | 86.2 % (13,664) | 85.5 % (13,558) |
| Path no. 300 | +0.975 ns | +0.588 ns |

**The aim was reached**: no path from `dbg_regno_q` is left among the 300 (in section 34 it was the 1st,
+0.402 and +0.477). The number of WNS went down anyway, and the reason is placement, not the change:

- The change only takes logic away from the paths it touched; it adds none to the others. The paths now at
  the top are families seen before (below), and they did not get longer logic.
- The whole distribution went down: the 300th path is +0.588 ns against +0.975 ns. The same logic got about
  0.1 to 0.4 ns longer routing. In section 34 a change of one AND term moved WNS by −0.17 ns; at 85 % slices
  the swing of placement is about ±0.2 ns.

So WNS is now set by the paths that were just behind the debugger's, and they are all within the swing:

| Slack | Path | Of the 300 |
|---|---|---|
| **+0.048 ns** (24 levels, CARRY4 10, 77 % routing) | `d_resp_data` (the D$'s answer, forwarded from MA) → EX's operand → address add (`mr_vaddr`) → DTLB compare → `ex_advance` (fo=1,556) → the fetch queue's `pq_count` | 4 (+13 to `head_pc`) |
| +0.108 ns (27 levels, CARRY4 14) | `pmpaddr` → data-side PMP compare → `mr_pmp_fail` → cancel of the request issued early (`lsu_e_go` → `d_req_cancel`) → the D$'s s1 → ROB write enable (`rob_data` CE) | **276** |

- The first is candidate 1 of section 32 (T2 of `ROADMAP.md`: separate EX's stall from the DTLB compare).
- The second is the family of section 22, now going through the cancel of decision 58. The PMP compare
  (14 levels of CARRY4) is followed by the cancel and the D$'s ROB in the same cycle. It is 276 of the 300
  because each ROB bit is a separate endpoint, and the logic is one path.

**What it means**: T1 removed one family; the margin left is about one swing of placement. Before adding
logic around the LSU and the D$ (M1 store buffer, M2 Zicbop), one of the two families above should be cut.
Candidates:

1. **T2** (the first family): see section 32.
2. **The PMP check of the data side one cycle earlier** (the second family): the PMP compare's input is
   `mr_paddr`, a register, but the compare itself is 14 levels of CARRY4. Registering the comparisons of
   `pmpaddr` against the address range (or comparing in EX against the DTLB's answer and registering the
   result) would leave only the selection by priority in MR.

## 36. The version with the memory wait events (M0): +0.717 ns (2026-10-10)

M0 of `ROADMAP.md` (`CPU_CORE_SPEC.md` decision 71): five PMU events, two small fill counters in
`CPU_CACHE` and two status outputs of `DCACHE`. All of it is registered once in `CORE_CSR` before it is
counted, so it adds nothing to any path of the pipeline.

| | Section 35 | This version |
|---|---|---|
| WNS | +0.048 ns | **+0.717 ns** |
| WHS | +0.024 ns | +0.012 ns |
| LUT | 45,530 (71.8 %) | 44,631 (70.4 %) |
| Slices | 85.5 % (13,558) | 87.2 % (13,816) |

The change cannot shorten a path, so the +0.67 ns is placement, in the other direction from section 35:
the swing at 85 to 87 % slices is larger than the ±0.2 ns assumed there. The worst path is the family of
T2 again: `ma_is_load` (forwarding from MA) → EX's operand → address add (`mr_vaddr`, CARRY4) → DTLB compare →
`ex_advance` (fo=1,524) → `fpu_in_valid` → `fp_pend` (23 levels, 72 % routing, +0.717 ns); next, the same start
to the fetch queue's `pq_head`. The PMP → D$ ROB family of section 35 is no longer among the first.

With 0.7 ns of margin, T4 and T2 are no longer urgent; they stay the first candidates for the next time
added logic takes the margin away.
