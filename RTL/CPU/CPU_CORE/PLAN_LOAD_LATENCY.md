# Removing the waits of loads / stores (design proposal, 2026-10-02)

[日本語](PLAN_LOAD_LATENCY_J.md)

Progress: **A1 implemented** (2026-10-02, section 5), **A2 implemented** (2026-10-02, section 6).
What was decided is in `CPU_CORE_SPEC.md` 5.4 (decisions 58 to 60) and `CPU_CACHE_SPEC.md` 5.2
(decision 16).

Improvement candidate A of `LitexSystem/docs/BENCH.md`. A document for comparing approaches before
deciding; what is decided moves to `CPU_CORE_SPEC.md` and `CPU_CACHE_SPEC.md`.

## 1. What happens now

With `+dtrace` of `SIM/SIM_SYS`, the cycles of request and response of a load that hits in the D$ were
observed (the loop of `bench/ldloop.c`):

```
[57932] D REQ  cmd=0 addr=0080006000  (pc in MR 0080000af4)    ← request in MR
[57935] D RESP data=0505050505050505  (pc in MA 0080000af4)    ← 3 cycles later
```

| Cycle | Core | D$ |
|---|---|---|
| t | The load is in MR. It makes the request | s0: starts reading the arrays (index from the virtual address) |
| t+1 | The load is in MA. **Waits** | s1: tag compare (physical address), hit → writes the response into the ROB |
| t+2 | **Waits** in MA | The head of the ROB completes → response to the register |
| t+3 | The response is visible. MA moves on | |

Even on a hit MA waits 2 cycles, and every instruction behind stops meanwhile. That is 2 cycles for
every load and store: 23.6 % of the total cycles of CoreMark and 33.8 % of Dhrystone (section 1 of
`BENCH.md`; the profiler's "1.1 cycles per data access" is counted at the last stage, counted at the
issue point it is 2.0).

At the same time, 9 of the worst timing paths start from the PMP decision of whether MR may make the
request and run into the stall signal of the whole pipeline (section 23 of `TIMING.md`, WNS +0.002 ns).
Changing where the request is made moves both of these together.

## 2. Approaches

### A1. Answer from the D$ one cycle earlier (3 → 2)

When s1 finds a hit, instead of writing the ROB and taking it out the next cycle, **write the response
register straight from the result of s1**. Only when the ROB holds no older unfinished request (this
request is the head). Otherwise go through the ROB as before.

| Item | Contents |
|---|---|
| Effect | MA's wait goes from 2 to 1 cycle. CoreMark about +12 %, Dhrystone about +20 % (estimated) |
| Change | Only the response part of `DCACHE`. The core's protocol does not change |
| Timing | The new path is s1's hit decision → response register. The same depth as the present write into the ROB |
| Risk | Small to medium. Getting the order of responses wrong (the comparison with the head of the ROB) swaps their order |
| Verification | Add to `SIM_CACHE` (60,263 checks, 28 mutations) hits with and without an earlier request in the ROB |

### A2. Make the request from EX (index from the virtual address, physical address in MR)

The D$ **takes the index from the virtual address and receives the physical address (the tag) one cycle
later** (`CPU_CACHE_SPEC.md` 5.6), so the request can be made in EX.

| Cycle | Core | D$ |
|---|---|---|
| t | The load is in EX. Adds up the address and makes the request. Also looks up the DTLB | s0 |
| t+1 | MR. The answer of the DTLB (physical address) and PMP | s1: tag compare. If MR says "this should not have been sent", it is **taken back** |
| t+2 | MA. Together with A1 the response is visible here → **no wait** | |

What is taken back: DTLB misses / page faults, misalignment, PMP refusals, flushes by a trap. The same
idea as the `i_cancel` the I$ uses for PMP refusals, brought to the D$ (a store writes in s1, so that
write is stopped, and on a miss the start of the fill). What is taken back for a DTLB miss is sent again
from MR after the page table walk (the present path stays as a fallback).

| Item | Contents |
|---|---|
| Effect | With A1, MA's wait becomes almost 0. CoreMark up to +31 %, Dhrystone up to +51 % (A1 included) |
| Timing | **PMP leaves the stall net** (it acts only on cancel and exceptions). Instead, EX's add → D$ index → array address becomes a new path |
| Change | The core's LSU (the stage that makes requests, tracking requests in flight, throwing away the responses of cancelled requests), cancel in s1 of `DCACHE`, `CACHE_PORT_ARB` (passing the cancel through) |
| Risk | Large. The conventions of the memory pipeline change. A request made from EX may be answered while EX is still stopped (a place to hold one response is needed). The page table walker competes for the D$ port |
| Verification | Cancel tests in `SIM_CACHE` (stores, misses, AMO, LR/SC), tests in `SIM_CORE` where a flush, a DTLB miss or a PMP refusal happens behind a request, mutations in both. The v environment of riscv-tests, booting Linux |

### A3 (for comparison). Write the result of a load later

Commit the load in MA without waiting for the answer, and write the answer into the register file 1 to 2
cycles later (a scoreboard stops dependent instructions).

Why not: bus errors (of I/O loads) could no longer be reported as precise exceptions. It does nothing
for stores (which also wait 2 cycles every time). It adds forwarding paths and makes the longest
forwarding path now (second in section 23 of `TIMING.md`) longer still.

## 3. Proposed way forward

1. **A1 first**. It is closed inside the cache and does not change the core's conventions. Measure its
   effect, then go to A2
2. **A2**. A rework of the memory pipeline. PMP leaves the stall net, so timing margin should come back
   as well
3. After that, candidates for what remains:

| Candidate | Estimate |
|---|---|
| Conditional branch prediction with history (gshare or the like) | CoreMark +2 to 4 % |
| Multiply from 3 down to 2 cycles or less | about 3 % |
| The 1 cycle of load-use | about 3 % (A2 changes its shape, so measure again after it) |

The estimates assume that the stalls in the profile of the simulation (`SIM/SIM_SYS`, `make bench`)
disappear entirely. With A1 + A2 CoreMark goes from 1.76 to about 2.3 /MHz (simulation), which by the
numbers reaches the level of Rocket.

## 4. Decisions requested

- Is the order A1 → A2 fine?
- Putting a cancel in s1 of the D$ in A2 (touching a cache that has been verified)

## 5. Results of A1 (2026-10-02)

In stage 1 of `DCACHE`, a hit that is the head of the ROB is answered from there (`s1_fast`).

| | Before | After | |
|---|---|---|---|
| Hit request → response | 3 cycles | **2 cycles** | Checked with `+dtrace` |
| MA wait / access | 2 | 1 | |
| CoreMark (simulation) | 5,684,843 cycles | 4,998,815 | **+13.7 %, 2.00 CoreMark/MHz** |
| Dhrystone (simulation) | 396,032 | 324,545 | **+22 %** |

Verification: SIM_CACHE (60,222 checks), all 31 mutations detected (3 new: answering from stage 1 even
when not the head, SC result inverted, missing byte alignment of loads), SIM_SYS (with / without back
pressure), SIM_OCD, SIM_DBG, BIOS, Linux boot from the SD model.

Board: 1.667 → **1.895 CoreMark/MHz** (+13.7 %), 0.849 → **1.024 DMIPS/MHz** (+20.6 %), WNS
+0.052 ns. As the simulation predicted.

## 6. Results of A2 (2026-10-02)

The request is made from EX, and MR lets it go (`e_go`) or takes it back (`d_req_cancel`). What was
taken back, and what could not leave EX, is sent again from MA. The D$ takes the cancel in s1, completes
the ROB slot silently and answers with `d_resp_drop`. Details in `CPU_CORE_SPEC.md` 5.4.

| | After A1 | After A2 | |
|---|---|---|---|
| MA wait / access | 1 | **0** (hit) | D$ wait 0.0 % in the profiler |
| CoreMark (simulation) | 4,998,815 cycles | 4,312,829 | **+15.9 %, 2.32 CoreMark/MHz** |
| Dhrystone (simulation) | 324,545 | 253,069 | **+28 %** |

A1 + A2 give CoreMark +32 % and Dhrystone +56 %. As estimated in section 3 (CoreMark 1.76 → about 2.3
/MHz).

What the design settled (changes from section 2):

- **Only loads of the cacheable region are sent speculatively**. Stores, AMO / LR / SC and I/O loads go
  only in the cycle the instruction in MA commits (or when MA is empty). Some I/O, like the claim of the
  PLIC, changes state just by being read
- **Nothing goes before the accesses in front of it have gone**. In the first version a young load
  overtook an old store that had been taken back and was going again from MA, and `t03` / `t04` / `t10`
  / `t14` failed
- On a DTLB miss, instead of "sending again from MR", the request of the instruction stopped in EX is
  taken back in MR and sent from MA (`ex_e_blocked`). The resend path was reduced to the single one from
  MA
- The answers of instructions thrown away by a flush are counted and thrown away by the core's LSU
  (`drop`), not by the D$

Verification:

| Environment | Contents | Result |
|---|---|---|
| SIM_CACHE | Section 19 (cancel: store hit / miss, AMO, LR / SC, I/O, 25 % of 3000 random operations) | 64,736 checks PASS, mutations M32 to M36 (5 new) all detected |
| SIM_CORE | New `t25_lsu` (a load behind a store that was taken back, answers in flight at a trap, a PLIC claim behind a trap, a store the handler skips), a store on a wrong path added to `t18_asid`, an invariant that detects answers nobody waits for | 25 tests PASS (Verilator, Icarus), back pressure, mutations M240 to M251 (M249 removed as equivalent) plus 7 existing mutations whose place moved, updated, all detected |
| riscv-tests | p / v | 132 / 109 PASS (known failures only) |
| SIM_SYS | All tests, with back pressure | PASS |
| SIM_DBG / SIM_OCD / BIOS | | PASS |
| Linux | Boot from the SD model (SIM_BIOS `make linux-sd`) | Boots to the shell prompt |

Timing: PMP left MR's "may it go on", and acts only through `e_go` → `d_req_cancel` → s1 of the D$.
Instead, EX's add → D$ index is a new path. WNS after place and route is +0.004 ns (+0.052 ns after A1).

Board: 1.895 → **2.211 CoreMark/MHz** (+16.7 %), 1.024 → **1.297 DMIPS/MHz** (+26.7 %). The loops of
`micro` with loads now take the same 4.4 cycles as the loop without loads.
