# mmRISC-2 CPU core specification

[日本語](CPU_CORE_SPEC_J.md)

- Version: Rev-1 (2026-09-20), first edition (design plan)
- Last updated: 2026-10-06 (updated as the implementation goes; decisions in section 13, the latest is
  decision 69)
- Scope: `RTL/CPU/CPU_CORE/` (pipeline, CSRs, MMU), `RTL/CPU/CPU_TOP/` (integration)
- Related: `RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md` (L1 caches), `RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md` (debug
  logic)
- Follows: RISC-V Unprivileged ISA / Privileged Architecture / Debug Spec 1.0 (versions in "References" of
  the top `README.md`)

---

## 1. Purpose and scope

An **RV64GC + Sv39** core to run LiteX + Linux on the Arty A7-100T. The debug logic and the L1 caches are
implemented and verified, and this specification defines the CPU core itself that goes between them.

```
        CPU_TOP
  ┌──────────────────────────────────────────────┐
  │  CPU_CORE (this specification)                │
  │    front end ─ ITLB ─┐                        │
  │    back end  ─ DTLB ─┤                        │
  │    CSR / exceptions / CLINT                   │
  └───────────────────────────┼──────────────────┘
                              │ i_*/d_* (section 5)
                        CPU_CACHE ── BUS_ARB ── AXI4 / AXI4-Lite
                              ▲
                        CPU_DBG (hart control, memory access through the D$)
```

What this phase replaces: `CPU_BFM` (BFM), `DBG_HART_STUB` (stand-in hart), and `u_bus_arb_cpu` of
`CPU_TOP` (arbitration for the BFM's raw bus).

---

## 2. Instruction set

### 2.1 Implemented range (equivalent to Rocket's `linux` configuration)

| Item | Contents |
|---|---|
| Base | RV64I |
| Standard extensions | M (multiply / divide), A (AMO/LR-SC), F/D (single / double precision), C (compressed instructions) |
| Attached | Zicsr, Zifencei, Zicntr (`mcycle`/`minstret`), **Zihpm** (`hpmcounter3` to `6`, 2026-10, decision 69) |
| Performance counter interrupts | **Sscofpmf** (counter overflow interrupt LCOFI, `scountovf`, OF / MINH / SINH / UINH of `mhpmevent`, decision 69), **Smcntrpmf** (privilege-level filtering of `mcycle` / `minstret`, `mcyclecfg` / `minstretcfg`) |
| Privileged version | 1.12 (with `menvcfg` / `senvcfg` / `mcountinhibit`, OpenSBI sees 1.12; decision 66) |
| Timer | **Sstc** (`stimecmp`, 2026-10, decision 66) |
| Debug triggers | **Sdtrig** (4 `mcontrol` of type 2, 2026-10, decision 67). Hardware breakpoints and watchpoints |
| Conditional zero, hints | **Zicond** (`czero.eqz` / `czero.nez`), **Zihintpause** (PAUSE), **Zihintntl** (NTL.*) (2026-10, decision 68). No bits in `misa`; announced through the device tree |
| Bit manipulation | **Zba, Zbb** (2026-10, decision 65). No corresponding bits in `misa`; software learns of them through the device tree (`riscv,isa-extensions`) |
| Privilege | M / S / U, Sv39 (three-level page tables, 4KiB/2MiB/1GiB) |
| `misa` | `0x8000_0000_0014_112d` (= A,C,D,F,I,M,S,U; a parameter of CPU_TOP, read-only) |

### 2.2 What is kept ready to add later

| Candidate | What is done now |
|---|---|
| Zbs (the rest of B) | Zba / Zbb are implemented (2.1). Zbs (single-bit operations) can be added to the same ALU. Illegal instructions for now (`t28_bitmanip` checks the neighboring encodings) |
| V extension (vector) | Reserve the opcode `OP-V (0x57)` and `vset*`. Provide from the start an issue/completion interface that can handle **long latency, out-of-order completion** (the first user is FDIV/FSQRT) |
| Custom instructions | Pass `custom-0/1/2/3` (0x0B/0x2B/0x5B/0x7B) from the decoder to an **accelerator port** (section 9) |
| Zicbom and the like | The cache has `FLUSH`/`fence.i`, so add per-line operations to that |

The decoder's output is unified into one `uop` record (rs1/rs2/rd/imm/functional unit/exception), so that
adding functional units does not touch the pipeline control.

---

## 3. Pipeline

### 3.1 Measured values it rests on

| Path | Latency | Throughput |
|---|---|---|
| I$ hit | Request in cycle N → instruction visible at **N+2** | 1 fetch/cycle |
| D$ hit | Request in cycle N → data visible at **N+3** (including one ROB stage) | 1 access/cycle |
| I$ miss | 13 cycles | |
| D$ miss | 12 (fill) / 22 (dirty eviction) | |

Measured on the FPGA (Arty A7-100T, 2026-09-20), the D$ hit path (tag RAM → hit decision → `rob_data`, 12
logic levels) is 15.5 ns: **4.4 ns of margin at 50 MHz, not possible at 100 MHz**.

### 3.2 Structure (50 MHz target, 7 stages + fetch queue)

> It was first designed with 6 stages (EX doing the DTLB, PMP and the request), and M1 to M7 were built in
> that form. It did not reach 50 MHz on the FPGA, so an **MR stage** was added between EX and MA (12.10,
> decision 48). The figure below is the present form.

```
 IF1 : PC select / ITLB lookup / I$ index (virtual address)
 IF2 : I$ tag compare (physical tag from the ITLB), way select → into the fetch queue
 (FQ): fetch queue (4 to 8 entries, RVC alignment, decoupling)
 ID  : RVC expansion / decode / register read / hazard check
 EX  : ALU, branch decision, address generation (AGU) + DTLB lookup, MDU / FPU,
       request to the D$ (index by virtual address, 5.4)
 MR  : PMP check, exceptions decided, let the request go or take it back (passing the physical tag)
 MA  : answer from the D$ (a hit is visible in the cycle it arrives). Re-issuing cancelled requests.
       Commit point
 WB  : write-back / forwarding
```

- **The TLB lives in EX** (the AGU's add → TLB lookup in one cycle). PMP and the request were placed here
  at first too, but forwarding → add → TLB → PMP → exception → request took 27 ns in real routing, and from
  PMP on was split into MR. EX is about 13 ns, MR about 14 ns, by estimate.
- **Load-use is one bubble**: when the next instruction uses the value of a load, it waits in EX for the
  cycle the load is in MR, and is forwarded the answer when the load moves to MA (`lu_hazard`). +3.07 % on
  `t19_ldbench`. **Conditional branches do not wait, though** (decision 64, "late branches"): they go on to
  MR with their prediction and are resolved in MR against the load's answer. That was two thirds of the
  waits of CoreMark and nine tenths of those of Dhrystone.
- On the instruction side, the next fetch address (PC+4 or the BTB's predicted target) is known one cycle
  earlier, so **the ITLB lookup is brought forward**, and sequential fetch has no penalty.
- Branches: resolved in EX. The first version without a predictor took **3 cycles** for every taken branch
  (refilling IF1/IF2/ID). With a BTB + 2-bit predictor, only on mispredictions.

### 3.3 Aiming at 100 MHz (future)

| Long path | Measure |
|---|---|
| D$ hit (tag compare → way select → alignment, measured 15.5 ns) | Split way select into stages, or way prediction |
| EX (add + DTLB) | Put the DTLB in a stage of its own (+1 stage), or move to parallel VIPT (same number of stages) |

As preparation for moving to parallel VIPT, the cache interface is already split into **two addresses, one
for the index and one physical** (5.2).

---

## 4. Front end

### 4.1 Fetch queue (prefetch queue)

**Included.** Reasons:

1. The queue absorbs I$ misses (13 cycles) and back-end stalls, letting fetch run ahead.
2. **RVC**: with 16-bit instructions, instructions cross the 64-bit fetch boundary. A place to hold a stray
   halfword is needed, and the queue is the natural place.
3. A place for predecoding (RVC expansion, branch detection, future BTB updates).

| Item | Default |
|---|---|
| Depth | 4 entries (64-bit fetch word + PC), parameterized |
| Alignment | RVC expansion at the queue's exit. Instructions across a boundary are joined with the next entry |
| Flush | Discard everything on a branch redirect, exception, `fence.i` or debug halt |

Until a predictor is added, a depth of 4 is enough (taken branches throw it away every time). Room is left
to go to 8 after adding the BTB.

### 4.2 Branch prediction (`CORE_BTB`)

A BTB (direct mapped, 256 entries by default) + 2-bit saturating counters, gshare for the direction of
conditional branches (8192 entries, 12 bits of history), and a return address stack (8 entries), in IF1.
Redirects happen **only on mispredictions**.

**There are 2 ways of fixing a misprediction**.

- A misprediction of a **control transfer instruction** (branch, JAL, JALR) is fixed from EX. Control
  transfers use neither the MMU nor multi-cycle units, so for those instructions "EX advances" is the same
  as "MA is not stalled", and exceptions are complete with `ex_exc_pre`. Writing it that way takes address
  translation, PMP and the cache handshake off the path of the redirect (→ the whole front end)
  (section 13 of `LitexSystem/docs/TIMING.md`, decision 46).
- When **an instruction that is not a control transfer was predicted taken**, the instructions after it
  are **refetched** when it commits in MA (the same path as `fence.i`). The BTB is tagged by virtual address
  only and is cleared only by `fence.i` and `SFENCE.VMA`, so this happens when **switching ASIDs shows other
  code at the same address** (with ASIDs enabled, Linux rewrites `satp` without a fence). That instruction
  might be a load, and fixing it from EX would put the memory path on the redirect again, so it was moved to
  MA. One cycle slower than fixing from EX, but only in this case. Checked by `t18_asid`.

The key is that it is **fetch-block prediction**. When the fetch unit makes a request it knows only the
address of an 8-byte word, so an entry speaks not of an instruction but of a **word**: "this word has a
branch starting at parcel `off`, going to `target`". A word whose prediction hits is queued **with the
parcels after the branch thrown away**, and fetch continues from target.

| Field | Contents |
|---|---|
| valid / tag | Upper bits of the word address |
| off[1:0] | Position in the word of the branch's **first** parcel |
| is32 | A 32-bit branch (occupies parcels off and off+1) |
| target | Target |
| tail | A 32-bit branch that started in the last parcel of the previous word ends in parcel 0 of this word |
| call / ret | Call (JAL / JALR with rd ra / t0) / return (JALR with rd = x0 and rs1 ra / t0) |
| cond | Conditional branch. The direction comes from gshare's table |
| cnt[1:0] | Saturating counter (for jumps; not used for conditional branches). New entries start weakly taken (10) |

**Where it lives**. The table is written with one index and read with two, so it is written in **a form that
fits the fabric's distributed RAM** (one array without reset). Only valid is kept in flip-flops — reset and
flush drop all the bits at once, which memory cannot do. Nobody reads an entry whose valid is not set, so it
does not matter what the memory holds right after reset.

**When a prediction is not used**:

1. `off < next_start` — a branch **before** the position jumped into by a redirect. Using it would throw away
   the parcels of the instruction actually there.
2. A tail entry is used only when the word was reached **continuing from the previous word**
   (`seq_fetch`). Even if the jump lands at parcel 0, it is the start of a real instruction there, not the
   second half of a branch.

**32-bit branches across words** (first half at parcel 3, second half at parcel 0 of the next word).
Predicting in the starting word would trim away the second half. So a tail entry is made in **the next
word**, which is kept up to parcel 0 before jumping. Until 2026-09 these branches were not predicted, but in
C-extension code about a quarter of 32-bit branches fall in this position, and in CoreMark 54 % of the
mispredictions were these (`LitexSystem/docs/BENCH.md`).

**gshare** (decision 63). The direction of conditional branches comes from a table of 2-bit counters (PHT,
8192 entries, distributed RAM) indexed by the XOR of the word address and the global history.

- **The history is the directions of conditional branches that have their own entry in the BTB**, one bit
  each. The fetch side (`hist_s`) records the direction it predicted when it used that entry; the execute
  side (`hist_a`) records the actual direction when the BTB says "this word's entry belongs to this branch"
  (`upd_known`). Branches without an entry are invisible to both.
- An entry is made or changes owner only for a taken branch without an entry — a branch the fetch side
  could not predict — so a redirect always follows, what is behind it is thrown away, and `hist_a` is copied
  to `hist_s`. While predictions hit, the two agree. The same way of keeping it as the return address stack.
- The history is folded into the **upper bits** of the index. The lower bits are left to the word address,
  so that nearby branches do not collide through differences of history (the first version, which folded
  into the low bits, mispredicted more than the earlier BTB counters).
- The table is not reset (distributed RAM). The initial value is weakly taken (entries are made only for
  branches that have been taken, so leaning taken is natural).
- Putting only taken branches into the history (path history) was tried too, but loop back branches filled
  the history, and mispredictions went down only 6 %.

**Return address stack**. For an entry the BTB calls ret, the target comes from the top of the stack, not
from the table's target. There are 2 stacks:

| | Written when | Contents |
|---|---|---|
| Fetch side (speculative) | Push on a predicted call (the return address from `off` and `is32`), pop on a predicted ret | Used for prediction |
| Execute side | Push on a call that went through EX, pop on a ret | The stack of the correct path only |

At every redirect the execute side is copied to the fetch side (including that cycle's push). What a wrong
path pushed or popped disappears with the redirect that ends it. Beyond a depth of 8 the oldest entries are
overwritten, and EX fixes the mispredictions.

**Detecting misfetches**. Entries are made from branches that actually executed, but if a program jumps into
the middle of an instruction, **the same bytes are decoded on another boundary**. Then an instruction may
start at the cut, and its second half becomes a parcel at the predicted target — an instruction that exists
on neither path. The fetch unit watches for that one case only: **when the first parcel of a 32-bit
instruction was the last parcel of a trimmed word**. That is a misfetch, so it throws away the queue, stops
predicting and fetches the same address again.

It does not happen in correctly written programs (t17 **deliberately** jumps into the middle of an
instruction to cause it). The predictor itself is transparent, and EX always corrects a wrong prediction.

---

## 5. Memory interface

### 5.1 Connection to the caches

The ports of section 5 of `CPU_CACHE_SPEC.md` are used as they are. What the core drives:

- Instruction: `i_req_valid/ready/addr`, `i_resp_valid/data/error`, `i_flush_*`, `i_kill`
- Data: `d_req_valid/ready/addr/size/cmd/wdata`, `d_req_cancel`, `d_resp_valid/data/error`

### 5.2 Physical address ports (where the MMU plugs in)

`i_req_paddr` / `d_req_paddr` must be valid in **the cycle after the request is accepted** (the cycle that
request is in the cache's stage 1). The index and offset come from `*_req_addr`, the tag from
`*_req_paddr`.

| Method | How the core drives them |
|---|---|
| No MMU (then) | Give `*_req_addr` delayed by one cycle on `*_req_paddr` |
| Serial (this phase) | Look up the TLB in EX and give that physical address in the cycle after MA |
| Parallel VIPT (future) | Index by virtual address, the TLB output straight to `*_req_paddr` |

With parallel VIPT, **`SETS × BLOCK ≤ 4096`** (index + offset fit within a page). The default 64 sets × 64B =
4096 is exactly the limit; to add capacity, add ways.

### 5.3 The fences

| Instruction | Behavior | Implementation |
|---|---|---|
| `fence` | Issue nothing behind it until all accesses in front have finished | Only serialized in ID (below). Nothing goes to the D$ |
| `fence.i` | **First a `FLUSH` of the D$**, then `i_flush_valid` to the I$ (invalidate all lines) | Done (12.9) |
| `sfence.vma` | Invalidate the TLBs (ITLB/DTLB). No effect on the caches | Done |
| `FLUSH` | Write back + invalidate the whole cache (before reset, for debug) | Done |

`fence.i` goes out on the data port as `CMD_FLUSH`. MA waits for its answer, so **going on to invalidate the
I$ after the write-backs finish** is guaranteed by structure. Riding on a mechanism that is already there
breaks less easily than keeping the order with a separate state machine (decision 38).

`fence` (and likewise `fence.tso`, `pause`, and those with reserved fields set) only **waits in ID until the
pipeline is empty**, and sends nothing to the D$ (confirmed 2026-10, `t27_fence`). Why that suffices:

- Pipeline empty = every earlier instruction has committed in MA = their accesses have been answered. A
  cacheable store answers when it has been written to the D$ (after the fill on a miss), **an uncached store
  when the bus has returned its write response** (`U_B` of `DCACHE`). A write to I/O reaches the device
  before anything goes on.
- DMA (the SD card) goes through the D$'s second port (`CPU_CACHE_SPEC.md` 4.8). Values still in the D$ are
  seen as they are, and there is no need to wait for write-backs. No master reads or writes main memory
  without going through the D$ (Ethernet uses its own SRAM).
- There is one hart.

Without a fence, a load of the cacheable region can go out ahead of an uncached store that is waiting for
its answer (5.4; only loads of the cacheable region may be speculative). RVWMO allows that, and Linux puts a
`fence` where order is needed (`writel` / `readl` and so on). The testbench checks every time a FENCE leaves
ID that all earlier accesses have been answered (`os == drop` of the LSU).

If DMA that does not go through the D$ or a second hart comes in, issue `CMD_FENCE` by the same mechanism as
`fence.i` (wait for write-backs to complete, section 6 of `CPU_CACHE_SPEC.md`).

### 5.4 Issuing requests from EX (early issue, decisions 58 to 60)

The D$ takes its index from the virtual address and its tag from the physical address one cycle later
(5.2). So load / store requests are **issued right after EX adds up the address**. In the next cycle, with
the instruction in MR, MR decides whether to **let** the request **go** or **take it back** (`d_req_cancel`),
and if it goes, passes the physical address on `d_req_paddr`. Together with A1 (answering from stage 1), the
answer of a D$ hit is visible in the cycle the instruction reaches MA, so **MA does not wait**.

| Cycle | Instruction | D$ |
|---|---|---|
| t | EX: adds the address, looks up the DTLB, makes the request (`e_*`) | s0: reads the arrays by virtual address |
| t+1 | MR: PMP, exceptions decided, let go / take back (`e_go`) | s1: compares with the physical tag. A cancel disappears here |
| t+2 | MA: the answer is visible (hit) | |

**The condition for EX to make a request** (`lsu_e_valid`) uses only signals that settle early; it looks at
neither the translation result nor PMP: `ex_valid & ex_ls & ~ex_exc_r & ~ex_e_blocked & ~stall_ma &
~lu_hazard`. When EX made a request but could not advance (waiting for the walker), `ex_e_blocked` is set and
that instruction does not issue from EX again (it is taken back in MR and goes from MA).

**The condition for MR to let it go** (`lsu_e_go`):

| Condition | Reason |
|---|---|
| `mr_e_acc` | This instruction's request was accepted from EX in the previous cycle |
| `~mr_exc & ~flush` | Instructions with exceptions (translation, PMP, misaligned and so on) and instructions being thrown away do not go |
| `~(ma_valid & ma_mem & ~ma_issued)` | **Do not go if an earlier access has not gone yet**. The cache processes in the order received, so a young load would overtake an old store that was taken back and is going again from MA, and read the old value |
| `mr_spec_ok \| older_done` | **Things with side effects** (stores, AMO / LR / SC, loads of the uncached region) go only when the instruction in MA commits in this cycle (or MA is empty). If the instruction in front traps, this one never happened. Loads of the cacheable region (`mr_spec_ok`) may go speculatively |

`mr_spec_ok = (cmd == LOAD) & (paddr >= MEM_BASE)`. `MEM_BASE` is a parameter of the core, the start of main
memory (the cacheable region). Below it is I/O, some of which changes state just by being read (the PLIC's
claim and the like).

**Re-issuing from MA** (`m_*`). What did not go from EX (taken back, port busy, stopped in EX) goes once it
reaches MA (`lsu_m_valid = ma_valid & ma_mem & ~ma_issued`). No instruction in front of MA can trap any more,
so things with side effects can go as they are. MA's request has priority over EX's (it is older). The
`CMD_FLUSH` of `fence.i` also goes this way.

**Requests and answers in flight**. At most 3 are in flight at once (what MA waits for, MR's, and the one EX
issued in the previous cycle that MR is now deciding). Answers come in order and always belong to MA's
instruction (an answer for MR's instruction never comes before that of the instruction in MA in front of
it). The answers of requests that were in flight in MR at a flush are counted by `CORE_LSU` and thrown away
when they arrive (`drop`). A flush happens after waiting for MA's answer, so everything in flight after a
flush is to be thrown away.

**The contract of cancel** (`CPU_CACHE_SPEC.md` 5.2). A cancelled request leaves nothing in the D$ (no
arrays, dirty bits, reservation, refill or bus access). Its ROB slot stays used, "completes silently", and
when its turn comes an answer goes out with `d_resp_drop`. The port arbiter (`CACHE_PORT_ARB`) advances its
record of owners by one with that answer, but passes it to neither the core nor the walker. This way the
records of the ROB and the arbiter always agree with the number of requests.

**The page table walker** takes the port only when the LSU is empty and MR and MA have no accesses
(`lsu_idle & ~(mr_valid & mr_mem) & ~(ma_valid & ma_mem)`). While the walker holds it, `d_req_cancel` is 0
(the walker does not cancel).

**PMP left the stall net**. When requests were made in MR, the PMP result went into "can MR advance" → the
stall of the whole pipeline (the 9 worst paths of section 23 of `LitexSystem/docs/TIMING.md`). Now it acts
only through `e_go` → `d_req_cancel` → the D$'s s1.

---

## 6. MMU and protection (`RTL/CPU/CPU_MMU`)

`CORE_MMU` sits between the pipeline and the 2 cache ports. Each side passes a virtual address and gets back
a physical address, a fault, or "cannot go yet" (page table walk in progress).

### 6.1 Structure

| Block | Role |
|---|---|
| `MMU_PMP` | Physical memory protection. Combinational. One each for instructions and data |
| `MMU_TLB` | ITLB / DTLB. Fully associative, 8 entries by default (`ITLB_ENTRIES` / `DTLB_ENTRIES`) |
| `MMU_PTW` | One page table walker shared by the ITLB/DTLB. Reads through the D$ |
| `CORE_MMU` | Puts the above together, and arbitrates the D$ port between the LSU and the PTW |

### 6.2 Sv39

| Item | Contents |
|---|---|
| Scheme | Sv39, 4KiB / 2MiB / 1GiB pages |
| Entries | ITLB / DTLB both 8 by default. Fully associative, a superpage takes one entry |
| Permissions | `satp` (MODE/ASID/PPN), MPRV/MPP/SUM/MXR of `mstatus`, U/S/X/W/R/A/D |
| Exceptions | instruction/load/store page fault (12/13/15) |
| Invalidation | `sfence.vma`. rs1 is the address, rs2 the ASID; 0 means "all" for each |
| A/D bits | **No hardware update**. A=0 (or D=0 on a write) is a page fault left to the OS (Svade). Linux supports this |

### 6.3 Connection to the pipeline

On a TLB hit the translation is **combinational**, and the physical address comes out in the same cycle the
request is made. The caches **index by virtual address and take the tag from the physical address** ("parallel
VIPT" of 5.2). Index and offset fit within a page (`SETS × BLOCK ≤ 4096`), so the two agree in that range,
and nothing changes on the cache side.

- **Instruction side**: fetches are speculative, so a fault is not made an exception on the spot. It is
  written into the queue with the parcels, and the instruction that actually uses it makes it an exception in
  ID. A fetch with a translation fault does not go to the cache; the IFU makes the answer itself. No fetch
  goes out during a miss (a walk). **PMP comes one cycle later**, applied to the physical address the IFU
  holds to pass to the cache (`i_req_paddr`) (`i_chk_*`). If refused, `i_cancel` takes back only that request
  in the cycle the cache receives that address (the cache has not yet started either the array answer or a
  bus access). The request stays in the IFU's record (`pr_cancel`), and when it reaches the head the IFU
  queues an access fault parcel. With translation and PMP in the same cycle it was 20.8 ns in real routing
  and did not reach 50 MHz (section 18 of `LitexSystem/docs/TIMING.md`, decision 50).
- **Data side**: the TLB is looked up when the address comes out in EX; translation faults (page faults,
  access faults the walk left) become exceptions on the spot, and a miss stalls EX. **PMP is one cycle later
  in MR**, checking the physical address EX held through the `p_*` port (`p_fail`). The PMP checker was at
  first shared with the walker, but its entry multiplexer was on the MR → request path, so **the walker got a
  checker of its own** (decision 49). The walker takes the port only when no access is waiting in MR.

### 6.4 PMP

| Item | Contents |
|---|---|
| Entries | 8 are checked (`PMP_ENTRIES`; 0 removes the function). Software sees 16 CSRs (`PMP_CSRS`) |
| Modes | OFF / TOR / NA4 / NAPOT |
| Decision | **The lowest-numbered matching entry decides**. Whether it allows or refuses, that is the end |
| No match | M passes, S and U do not |
| Lock | With `L` set it cannot change until reset. M is bound by that entry too |
| Wide transfers | Look at the first and last bytes, and **refuse if they are not in the same entry**. What is looked at is the **naturally aligned block** of 2^size bytes containing `paddr` |

The privileged specification asks for PMP implemented with 0 / 16 / 64 entries, and says the CSRs of entries
not implemented **read zero rather than being illegal instructions**. So only 8 checkers are built, and
`pmpaddr8` to `pmpaddr15` and `pmpcfg2` remain as "read 0, ignore writes".

**The form of the lookup**. "The lowest-numbered match" is made per entry as "it matches and nothing below it
matches" (`first`). Each entry's "does it refuse this transfer" (`deny`) depends only on registers and is made
in advance, and the decision is the OR over the entries of "the lower end's `first`, and refuses, or is not
the upper end's `first`" (+ the rule for when neither end matches). Neither the winning entry's index nor a
cfg select is built. This decision is on the path from MR to the D$'s cancel, so its levels are directly the
cycle time (section 28 of `LitexSystem/docs/TIMING.md`; before that it had the form of a one-hot select `sel =
m & -m`, `sel_lo == sel_hi` and a cfg select).

**The form of the compares**. What is checked is the naturally aligned block of 2^size bytes containing
`paddr`. On the data side that is the access itself (misaligned accesses become misaligned exceptions before
reaching the MMU), and the PTW reads aligned 8 bytes too. On the instruction side, right after jumping to a
BTB prediction, `fetch_pc` may point into the middle of the 8 bytes being fetched, and still **the 8 bytes
being fetched themselves** are checked (it used to look up to `paddr + 7`, so jumping by prediction near the
end of an executable region could look at the next 8 bytes and refuse by mistake).

The aligned block is 1 word (1/2/4 bytes) or 2 words (8 bytes), so the word addresses of the two ends
**differ only in bit 0**. So:

- No add is needed to find the last byte (just set bit 0)
- One compare of bits 53:1 (`<` and `==`) per entry, shared by both ends
- The lower bound of TOR `pmpaddr[i-1] <= x` uses the negation of the previous entry's upper bound compare
  as it is
- NAPOT always has bit 0 of its mask set (8 bytes minimum), so both ends give the same answer

Comparators go from 4 per entry (both ends × upper and lower bounds) to 2 (`<` and `==`), and what each address
bit drives goes down by as much.

`pmpaddr` holds the address shifted right by 2 bits, so the smallest region is 4 bytes. The privilege of the
data side is `MPP` if `mstatus.MPRV` is set, otherwise the current privilege. Instruction fetch is not
affected by MPRV.

**Firmware that drops to S/U must write at least one entry** (as the p environment of riscv-tests sets
`pmpaddr0 = -1`, `pmpcfg0 = NAPOT|R|W|X`). In this project's tests, `INIT_PMP` of `tests/test.h` does this.

The MMU was added **after the core ran in M mode** (section 12).

---

## 7. Registers and CSRs

| Kind | Contents |
|---|---|
| GPR | x0-x31, 64 bits. 2 reads 1 write (on the FPGA 2 banks of distributed RAM or BRAM) |
| FPR | f0-f31, 64 bits (D extension). 3 reads 1 write, NaN-boxing (section 10) |
| CSR | M-mode: `mstatus/misa/mie/mtvec/mscratch/mepc/mcause/mtval/mip/mcycle/minstret/mhartid/mvendorid/marchid/mimpid` and others |
| | S-mode: `sstatus/sie/stvec/sscratch/sepc/scause/stval/sip/satp` |
| | Delegation: `medeleg/mideleg` |
| | Debug: `dcsr/dpc/dscratch0/1` (shared with the debug logic) |

The CSR file is table-driven from address to register, so adding an extension means adding rows. Accessing
an unimplemented CSR is an illegal instruction exception.

Implemented (`CORE_CSR`). Machine mode:

| Address | CSR | Note |
|---|---|---|
| 0x300 | `mstatus` | MIE/SIE/MPIE/SPIE/MPP/SPP/FS/MPRV/SUM/MXR/TVM/TW/TSR/UXL/SXL/SD |
| 0x301 | `misa` | MXL=2, IMAFDC + S + U. Writes ignored |
| 0x302 / 0x303 | `medeleg` / `mideleg` | Delegation. 11 (ECALL from M) and reserved numbers cannot be written. `mideleg` only the 3 of S (1 / 5 / 9) and counter overflow (13) |
| 0x304 / 0x344 | `mie` / `mip` | 3 each for M and S. M's pending bits are driven by the CLINT and PLIC. `mip.SEIP` reads as the OR of the software-writable bit and the PLIC's S line, but `csrrs` / `csrrc` write based only on the software bit (decision 51). `mip.STIP` is `time >= stimecmp` if `menvcfg.STCE` is set (read-only, decision 66), otherwise a bit software writes. Bit 13 is counter overflow (LCOFIE / LCOFIP, decision 69). LCOFIP is set by an overflow and cleared by software |
| 0x305 | `mtvec` | Modes 0 (direct) and 1 (vectored). Reserved modes are not taken |
| 0x306 | `mcounteren` | Whether S/U can read the counters. TM also acts on `stimecmp` |
| 0x30A | `menvcfg` | Only STCE (bit 63). The other fields are 0, as their extensions are not there (decision 66) |
| 0x320 | `mcountinhibit` | CY (bit 0), IR (bit 2), HPM3 to 6 (bits 3 to 6). Setting one stops that counter (decisions 66, 69) |
| 0x321 / 0x322 | `mcyclecfg` / `minstretcfg` | Smcntrpmf: bit 62 MINH, 61 SINH, 60 UINH. `mcycle` / `minstret` do not advance at the levels set (decision 69) |
| 0x323-0x33F | `mhpmevent3`-`31` | Only 3 to 6 are real: bit 63 OF, 62 MINH, 61 SINH, 60 UINH (Sscofpmf), the low 5 bits the event number (1 to 19, the table of decision 69). Writing a number that does not exist gives 0 (counts nothing). 7 to 31 read 0, writes ignored |
| 0xB03-0xB1F | `mhpmcounter3`-`31` | Only 3 to 6 are real (64 bits). 7 to 31 read 0, writes ignored |
| 0x340-0x343 | `mscratch` / `mepc` / `mcause` / `mtval` | `mepc` drops its low bit |
| 0x3A0 / 0x3A2 | `pmpcfg0` / `pmpcfg2` | PMP configuration, 8 entries per register |
| 0x3B0-0x3BF | `pmpaddr0`-`15` | PMP addresses |
| 0xB00 / 0xB02 | `mcycle` / `minstret` | Writable. A write has priority over that instruction's own increment |
| 0xC00 / 0xC01 / 0xC02 | `cycle` / `time` / `instret` | Read-only. `time` is the CLINT's `mtime` |
| 0xC03-0xC1F | `hpmcounter3`-`31` | Read-only windows on `mhpmcounter`. From outside M the corresponding bit of `mcounteren` (and from U also of `scounteren`) is needed |
| 0xF11-0xF14 | `mvendorid` / `marchid` / `mimpid` / `mhartid` | Read-only |

Supervisor mode:

| Address | CSR | Note |
|---|---|---|
| 0x100 | `sstatus` | `mstatus` seen through a mask. One real register |
| 0x104 / 0x144 | `sie` / `sip` | `mie`/`mip` masked by `mideleg`. Writable from `sip`: SSIP, and LCOFIP if delegated |
| 0xDA0 | `scountovf` | Read-only. The OF of counter N in bit N. From S only the counters allowed by `mcounteren` are seen (Sscofpmf) |
| 0x105 | `stvec` | The same 2 modes as `mtvec` |
| 0x106 | `scounteren` | Whether U can read the counters |
| 0x140-0x143 | `sscratch` / `sepc` / `scause` / `stval` | |
| 0x10A | `senvcfg` | Reads 0, writes ignored (no extensions with fields; decision 66) |
| 0x14D | `stimecmp` | Sstc. From S only when both `menvcfg.STCE` and `mcounteren.TM` are set. Reset value all ones (decision 66) |
| 0x180 | `satp` | MODE only bare (0) and Sv39 (8). Other writes are ignored |

Triggers (Sdtrig, decision 67; from M mode. The `tdata1` / `tdata2` of a trigger with `dmode` set can be
written only by the debugger):

| Address | CSR | Note |
|---|---|---|
| 0x7A0 | `tselect` | 0 to 3. Writes of larger values are ignored (the value does not change) |
| 0x7A1 | `tdata1` | Always type 2 (`mcontrol`). The implemented fields are dmode, hit, action (0 or 1), m, s, u, execute, store, load. maskmax, select, timing, sizelo, chain and match are fixed at 0 (exact address match, firing before the instruction). Writing a value other than type 2 makes all fields of the trigger 0. action 1 only when the debugger writes it together with dmode |
| 0x7A2 | `tdata2` | The address to compare (virtual address) |
| 0x7A3 | `tdata3` | 0 (no textra) |
| 0x7A4 | `tinfo` | 4 (type 2 only) |
| 0x7A5 | `tcontrol` | MTE (bit 3) and MPTE (bit 7). On a trap to M, MPTE ← MTE and MTE ← 0; on MRET, MTE ← MPTE |

Floating point: 0x001/0x002/0x003 = `fflags`/`frm`/`fcsr` (section 10). The debug CSRs
(`dcsr`/`dpc`/`dscratch0/1`) are visible only to the debugger (section 11).

**Whether an access is allowed** is decided by 3 conditions, each an illegal instruction exception:

1. The address is not implemented
2. Address bits [9:8] are above the current privilege (`rd_denied`)
3. A write to an address whose bits [11:10] are 11 (read-only)

In addition, `satp` is refused in S mode with `mstatus.TVM`, and `cycle`/`time`/`instret` when `mcounteren`
(from S) or `scounteren` (from U) does not allow them.

CSR instructions are **serialized**: issued after the pipeline is empty, and nothing follows until they
commit. This makes the values read from `minstret`/`mcycle` exact, and a CSR read in EX always sees the CSR
write just before it.

---

## 8. Exceptions and interrupts

- Traps are taken in **MA (the commit point)**. A store hands its data to the cache in EX, so a trap of the
  instruction right in front of it must be decided while the store is still in EX. Taking it in MA lets
  `trap_taken` stop the store's issue.
- Interrupts are attached to an instruction **at the hand-over from ID to EX**, and taken in MA. An
  instruction with an interrupt attached then performs neither a memory access nor a branch, so the
  interrupt is precise, with `mepc` pointing at that instruction. WFI is the one exception: the interrupt is
  attached not to WFI itself but to the next instruction (so that `mepc` points after the WFI).
- Priorities follow the privileged specification. The order when several conditions hold for one
  instruction: **instruction address misaligned → instruction access fault → instruction page fault →
  illegal instruction → breakpoint → load/store misaligned → access fault → page fault**
- The priorities among interrupts also follow the privileged specification: **M external → M software → M
  timer → S external → S software → S timer → counter overflow (LCOFI, 13, decision 69)**
- Interrupts: a built-in CLINT (`msip`/`mtime`/`mtimecmp`) (`RTL/CPU/CPU_CLINT`). External interrupts come
  from the PLIC (later). The register layout is the same as SiFive's CLINT, relative to the base address:

  | Offset | Register | Width |
  |---|---|---|
  | 0x0000 | `msip` | 32 bits (bit 0 is the software interrupt) |
  | 0x4000 | `mtimecmp` | 64 bits |
  | 0xBFF8 | `mtime` | 64 bits |

  `mtime` advances by 1 every `TICK_DIV` cycles (1 in simulation; on the board the clock is divided to a
  fixed frequency). The interrupt lines are `msip` and `mtime >= mtimecmp`.
- External interrupts come from the **PLIC** (`RTL/CPU/CPU_PLIC`). The register layout follows the RISC-V
  PLIC specification, relative to the base address:

  | Offset | Register |
  |---|---|
  | 0x000000 + 4*s | Priority of source s (s = 1 .. SOURCES) |
  | 0x001000 + 4*w | pending, read-only, 32 sources per word |
  | 0x002000 + 0x80*c + 4*w | enable of context c |
  | 0x200000 + 0x1000*c + 0 | threshold of context c |
  | 0x200000 + 0x1000*c + 4 | claim on read, complete on write |

  **A context is "hart × privilege level"**. With one hart, context 0 is M mode and context 1 is S mode —
  exactly the order Linux's device tree writes. Adding harts is one parameter (`CPU_CACHE_SPEC.md` 6.4).

  Source 0 does not exist (claim returns "nothing" as 0). The gateway is **level-triggered**: the line sets
  pending, claim clears it, and no new request goes out until complete. If the line is still up at complete,
  it becomes pending again.

  Priority 0 means "do not interrupt", but there is **no dedicated check for it**. The threshold is never
  below 0, so "greater than the threshold" covers it.
- Delegation: to S-mode through `medeleg`/`mideleg`. The delegation target is never above the current
  privilege, so the condition is "the delegation bit is set and the current mode is not M".
- **Instructions forbidden by privilege** (each an illegal instruction exception):

  | Instruction | Forbidden when |
  |---|---|
  | `MRET` | Not M |
  | `SRET` | U, or S with `mstatus.TSR` |
  | `SFENCE.VMA` | U, or S with `mstatus.TVM` |
  | `WFI` | Not M and `mstatus.TW` |

- The cause number of `ECALL` is decided by the current privilege (U=8, S=9, M=11).
- Debug: `ebreak` and halt requests from outside go into debug mode according to `dcsr`.

---

## 9. Extension ports

### 9.1 Accelerator port (custom instructions)

The decoder passes `custom-0/1/2/3` through. The equivalent of Rocket's RoCC.

| Signal | Contents |
|---|---|
| `acc_req_valid/ready` | Issue |
| `acc_req_funct7/rs1/rs2/rd`, `acc_req_xd/xs1/xs2` | Instruction fields and operands |
| `acc_resp_valid/rd/data` | Result (written back to a GPR) |
| `acc_busy` | Used to wait for completion at a `fence` |

Room is left to add a memory port for accelerators (a third port of the D$) in the future.

### 9.2 Vector extension

- Make the issue/completion interface handle **variable latency, out-of-order completion** (its first user is
  the FPU's FDIV/FSQRT, section 10).
- Vector loads/stores lack bandwidth on today's 64-bit D$ port, so widening the D$ port (128/256 bits) or
  adding ports is to be considered when implementing it.

---

## 10. Floating point unit (F/D)

### 10.1 Policy

> **Changed in M4**: the plan of Rev-1 was "loosely coupled + scoreboard", but at implementation it was
> changed to **waiting in EX** (like the MDU). The reasons, and the steps to go back to the original plan,
> are in 12.6. 10.1 below is a record of the original thinking.

The FPU is not embedded in the integer pipeline but connected as **an independent functional unit**, with
dependencies managed by a variable latency and a scoreboard of the FP registers.

This is possible because **RISC-V floating point operations do not trap**. IEEE exceptions (invalid
operation, divide by zero, overflow, underflow, inexact) only accumulate in `fflags` and raise no exception.
So **precise exceptions are not broken** even if FP instructions complete out of order with integer
instructions. Only the address exceptions of FLD/FSD can trap, and those go through the ordinary load/store
path (LSU).

### 10.2 Connection to the pipeline

```
  ID        EX          inside the FPU (variable stages)      WB
  ─────────────────────────────────────────────────────────────
  FP RF read ─> issue ─> [FADD/FMUL/FMA : 3 to 5 stages   ] ─> FP RF write
                      └> [FDIV/FSQRT   : iterative, not pipelined] ─┘
                      └> [compare/convert/sign : 1 to 2 stages] ─> to the integer WB (table of 10.2)
  FLD/FLW  : issued in ID → LSU (D$) → NaN-boxed and written to the FP RF
  FSD/FSW  : read the FP RF in ID/EX and pass it to the LSU as store data
```

| Destination of the result | Instructions | Connection |
|---|---|---|
| FP register | Arithmetic, conversion (int→fp), sign injection, FMIN/FMAX, FMV.W.X, FLD/FLW | The FPU writes directly on completion |
| Integer register | FEQ/FLT/FLE, FCLASS, FMV.X.W, conversion (fp→int) | Shares the integer WB port through a one-entry buffer. The integer side has priority; on a conflict the FPU waits a cycle |
| Memory | FSD/FSW | The LSU's store data source is selected between GPR/FPR |

### 10.3 Latency and resources (50 MHz, Artix-7)

`CORE_FPU` is a unit that takes one operation at a time and answers it, and EX stalls meanwhile (10.2). So
the table below gives **the cycles EX is occupied, not pipeline stages**, and they are spent whether or not
the following instruction refers to the destination.

| Operation | EX occupied | Sequence of states |
|---|---|---|
| Compare / FCLASS / sign injection / FMV / FCVT | 6 | IDLE → UNP → SEL → RND → PACK → DONE |
| FADD / FSUB / FMUL / FMA (4 kinds) | 10 | IDLE → UNP → PP → M1 → M2 → M3 → SEL → RND → PACK → DONE |
| FDIV | single 70 / double 134 | IDLE → UNP → DIV×N → SEL → RND → PACK → DONE |
| FSQRT | 70 | IDLE → UNP → SQRT×64 → SEL → RND → PACK → DONE |

FADD/FSUB also **go through the multiply datapath** (`a × 1.0 + b`), so they take the same 10 as FMUL.

**Where to cut**. The first version cut between "assembling the answer" and "rounding", but that was **cut in
the wrong place**. `sp_res` (the answer that does not go through rounding) by definition does not read the
rounder, so the rounder was never on that path. **Only** the assembling side was long, and what it held was

  operands → **unpacking** (leading zero count of subnormals + full-width shift)
  → conversion, compare, select → `sp_res`

with 90 levels and 15 to 17 ns of logic. So the place to cut is **right after unpacking**. Of the unpacking's
outputs, "what kind of value" (sign, 0, ∞, NaN, signalling) comes out of a few comparisons and is used
combinationally, and **only the exponents and significands are held in `S_UNP`**. That takes the leading zero
count and the shift off every later cone. The partial products were also split into `S_PP`, so that unpacking
→ DSP are not in the same cycle.

Splitting off rounding (`S_RND`) itself is kept. Adding the subnormal shift and the carry to `S_SEL`, which
has a 129-bit leading zero count and normalization shift, still does not fit. The **alignment (M2) and
add/subtract (M3)** of multiply-add are split for the same reason.

**The rounder itself is also 2 cycles** (`S_RND` → `S_PACK`). The one-cycle rounder had 78 levels (59 CARRY4):
exponent subtract → 128-bit subnormal shift → guard / sticky → a 128-bit-wide +1 → exponent adjust → bias add
→ packing, and it remained the worst path after synthesis once the core's paths were fixed (section 13 of
`LitexSystem/docs/TIMING.md`).

- Cycle 1: shift, truncation to the precision, whether to round up (`inc`).
- Cycle 2: +1 and packing. The width of the significand (53 bits) is enough for the +1.
- **The carry out is known before adding** (when all the kept bits are 1 and `inc` is set). So the exponent
  field and the overflow decision are made in cycle 1 for both "no carry / carry", and cycle 2 only selects.
  The second half has only the 53-bit +1 and multiplexers left.
- The unbounded-precision carry used for "tiny after rounding" has the same form and needs no adder.

The cost is +1 cycle per FP operation.

The operands and control (`op`/`fmt`/`rm`/`int_*`) are **copied into this unit's own flip-flops** in the
`start` cycle. EX holds its values during the operation, but it holds them through the pipeline's forwarding
multiplexers, so without the copy every path into the unit would start from the write-back registers.

**The copy is not bypassed**. A multiplexer that "uses the raw values only in the first cycle" costs twice.
First, `start` is not an early signal — the pipeline raises it only when the memory stage is not stalled,
which is decided by the D$'s answer — so the D$'s answer comes to the head of the unit's deepest cone.
Second, **timing analysis does not know the states of a state machine**, so it analyzes as real a path from
the raw operands in the `start` cycle to registers written only several states later. The first version made
WNS 11 ns worse this way.

The Arty A7-100T has 240 DSP48E1, of which 32 are used now, so there is room.

### 10.4 Register file

- 32 × 64 bits. Single precision is stored NaN-boxed (10.7).
- **3 reads 1 write** (FMA asks for rs1/rs2/rs3). On the FPGA, 3 mirrored copies of a 32×64-bit distributed
  RAM with the write going to all of them (about 200 LUTs).
- Reading for stores (FSD/FSW) shares one of the 3.

### 10.5 Hazards and control

| Item | Method |
|---|---|
| Dependencies | **No scoreboard for now**. The FPU sits in EX waiting for its answer, so nothing behind it advances, dependent or not, and neither WAW nor RAW can happen by structure. The scoreboard below is what is needed when the FPU is decoupled (M8 or later) and is not implemented yet |
| FDIV/FSQRT | No second one is issued while one runs |
| Accessing `fcsr` / `fflags` / `frm` | Waits until the FPU is empty (to keep the order of flag accumulation) |
| `mstatus.FS` | When 0, FP instructions are **illegal instruction exceptions**. Writing an FP register or fcsr makes it Dirty (needed for Linux's lazy FP context switching) |
| Rounding mode | The instruction's `rm` field. `rm=111` uses the `frm` CSR. Reserved values are illegal instruction exceptions |

### 10.6 Flushes and traps

When the pipeline is flushed by a branch misprediction or an exception:

- **Younger** FP instructions are killed by an epoch tag (the same mechanism as the fetch redirect).
- **Older** FP instructions are waited for before entering the exception handling, so as not to miss
  `fflags` and register writes.
- Interrupts likewise are accepted after the FPU is empty.

### 10.7 NaN-boxing and special values

- Single precision values are stored in 64-bit registers with the upper 32 bits all 1. FLW / FMV.W.X / the
  results of single precision operations are boxed.
- Using a value that is not boxed as a source of a single precision operation produces a **canonical NaN**.
- **Subnormals are handled fully in hardware** (not flushed to zero). This is where a home-made FPU breeds the
  most bugs, so the verification of 10.8 covers it.

### 10.8 Implementation order and verification

| Stage | Contents | Aim |
|---|---|---|
| F1 | FP RF, FLD/FLW/FSD/FSW, the FSGNJ family, FMV, FMIN/FMAX, compare, FCLASS, FCVT | Get the **infrastructure** working without the arithmetic (scoreboard, NaN-boxing, `mstatus.FS`, `fflags`, rounding modes) |
| F2 | FADD / FSUB / FMUL | |
| F3 | The 4 FMAs | Share the multiplier and adder of F2 |
| F4 | FDIV / FSQRT | Iterative unit |

Verification follows the existing way (reference model + bug injection).

| Means | Contents |
|---|---|
| `SIM/SIM_FPU` (new) | **Berkeley TestFloat / SoftFloat as the reference model**, comparing all combinations of the 5 rounding modes × special values (subnormal, ±0, ±inf, NaN, rounding boundaries) |
| riscv-tests | `rv64uf-p-*`, `rv64ud-p-*` |
| `SIM/SIM_CORE` | Scoreboard, `mstatus.FS`, kill/drain at flushes |
| Bug injection | Inject into rounding, flags, NaN-boxing and the handling of subnormals, and measure the detection rate |

### 10.9 Home-made or existing IP

| | Home-made (recommended) | Berkeley HardFloat | FPnew (ETH) |
|---|---|---|---|
| Language | SystemVerilog (this project's way) | Verilog generated from Chisel (used by Rocket) | SystemVerilog |
| License | — | BSD | SolderPad |
| Effort | Large (the details of IEEE-754) | Small | Small to medium |
| Control | Stages and area are ours to decide | Fixed | Many parameters |

This project's policy is "make it ourselves", so **home-made + TestFloat verification** is the first choice.
If the effort becomes a problem, the structure also allows partial adoption, such as replacing only F4
(FDIV/FSQRT) with existing IP.

### 10.10 Configuration without the FPU

The parameter `HAS_FPU` can remove the FPU, dropping the F/D bits of `misa` too (for area experiments on the
FPGA and early bring-up). But Linux's standard ABI is lp64d (hardware floating point), so a configuration
running Linux on the board needs the FPU.

### 10.11 The pipelined `FPU_PIPE` (ROADMAP C2)

> **The core from stage 2 on has the form of this section**. The "wait in EX" form of 10.2 to 10.5 and the
> table of `CORE_FPU` are kept as the record up to stage 1 (`CORE_FPU` remains as the reference that
> `SIM/SIM_FPU` and `FPGA/FPU_OOC` compare against).

For DSP-like use, add / subtract, multiply, multiply-add and conversions to and from integers flow **at one
a cycle when there are no register conflicts** (direction decided 2026-10-09; divide and square root may stay
long; what should be fast is to be written in assembler). In stage 1 the FPU alone was pipelined as
`RTL/CPU/CPU_FPU/FPU_PIPE`, and in stage 2 it replaced the core's `CORE_FPU` (10.11.2).

#### 10.11.1 Stage 1: the FPU alone

| Stage | Contents | State of `CORE_FPU` |
|---|---|---|
| P0 | Copy of the operands and control (the cycle after EX hands it over; where the core's MR is) | IDLE → UNP |
| P1 | Unpacking (kind of value, exponent, significand with its leading 1 aligned) | UNP |
| P2 | Multiply-add: partial products. Others: the answer, or what is handed to the rounder (the "bundle") | PP / SEL |
| P3 | Sum of the partial products (the bundle waits) | M1 |
| P4 | Alignment of the addend (the bundle waits) | M2 |
| P5 | Addition (the bundle waits) | M3 |
| P6 | Select: the normalized sum, the bundle, or the result of a divide / square root | SEL |
| P7 | First half of rounding (`FPU_ROUND`), second half of conversion to integer | RND |
| P8 | Second half of rounding, the answer | PACK |

- **The stages are the states of `CORE_FPU` themselves**. Each state already wrote registers of its own, so
  neither the cuts nor the paths change. The multiplier also produced all partial products in one cycle, so no
  DSPs are added.
- **The latency is 9 for everything** (except divide and square root). Every operation goes through the same
  number of stages, so answers come out one a cycle in the order accepted, and the order of writes is kept.
  Operations other than multiply-add make their answer in P2 and wait through P3 to P5 (the bundle). Special
  values of multiply-add (NaN, infinity, multiplication by 0) also go as bundles.
- **Divide and square root** keep `CORE_FPU`'s iterative engine. They leave the pipeline at P1 for the engine,
  and nothing new is accepted until the answer is out (`in_ready` is 0). By the time they finish the pipeline
  is empty, so they enter P6 and go through rounding. Divide and square root of special values do not use the
  engine and flow down the pipeline. The answer goes in after the operation has left P1 (can no longer be
  taken back).
- **The first 2 stages (P0, P1) move in step with the core's MR and MA**, sharing the hold (`hold0` /
  `hold1`) and take-back (`kill0` / `kill1`) with the core. From P2 on nothing is taken back, so they flow
  without stopping.
- Verification on its own in `SIM/SIM_FPU` (`make pipe`, `bug_inject_pipe.sh`). Resources and timing were
  compared with `CORE_FPU` in `FPGA/FPU_OOC` (2026-10-09, alone, 50 MHz): LUT 9,757 → 9,060, FF 2,008 → 2,631
  (and SRL 177), DSP unchanged at 16, slices +49, register-to-register WNS +3.43 → +3.76 ns. Pipelining itself
  was almost free; LUTs went down as the state machine's multiplexers disappeared.

#### 10.11.2 Stage 2: integration into the core

```
  ID          EX              MR    MA    WB
  ─────────────────────────────────────────────────────────────────
  read GPRs   hand the FP      P0    P1    (writes nothing)
  (wait for   op over ───────> P2 → … → P8 ─┬─> 2nd write port of the FRF (+ straight to EX)
   int results)                               └─> 2nd write port of the RF
```

- **Once an FP operation (an F/D instruction other than FLD/FSD) is handed to the FPU in EX, the main
  pipeline writes nothing for it**. The instruction itself goes on through MR, MA and WB and retires, but the
  answer is written 9 cycles later by the FPU straight into the second write port of a register file (integer
  answers to the RF, FP answers to the FRF). `fflags` are accumulated when the answer comes out too
  (`fflags_we = out_valid`). Answers come out in the order accepted, so the order of flags is kept too.
- **P0 and P1 stop and are taken back together with MR and MA**. MR and MA always stop together, so `hold0 =
  hold1 = stall_ma`. A trap, xRET, FENCE.I, SFENCE or refetch in MA empties MR (`kill0 = flush`). Only a trap
  takes back the instruction in MA itself (`kill1 = trap_taken`). From P2 on nothing is taken back, so they
  flow without stopping.
- **Pending bits** (`fp_pend[32]`, `gpr_pend[32]`). Set when handed to the FPU, cleared when the answer comes
  out or when taken back (MR's instruction by a flush, MA's by a trap).
  - FP sources **wait in EX**. In the cycle the answer comes out it goes from the last stage straight to EX
    (the first priority of forwarding). Dependent operations are 9 cycles apart.
  - Integer sources **wait in ID**. The answer is picked up through the write-first read of the register file
    (ID can read it in the cycle the answer comes out). This adds no input to the integer forwarding (the head
    of the longest path of the design), and an integer dependency such as FCVT.L.D → ADDI is one cycle longer
    than FP to FP, 10 cycles apart. The rd of the instruction in EX about to be handed to the FPU is also
    checked in ID.
  - **Writes wait too** (WAW). An FLD, an integer instruction or another FP operation that would write a
    register the FPU has not written yet waits. Only one writer per register is ever in flight, so an answer
    being written never later overwrites with an old value.
- **Divide and square root** make the next FP operation wait in EX while `in_ready` is 0 (`fp_wait`). Integer
  instructions without a dependency overtake and go on.
- **What waits for the pipeline to empty**. CSR instructions, xRET, SFENCE (serialized) and FENCE.I got "the
  FPU is empty" (`fpu_busy = 0`) added to their conditions. `fflags` finish accumulating before `fcsr` is read,
  and instructions that read FP registers do not miss answers. The debugger's register reads and writes
  (abstract commands) also wait for `fpu_busy = 0`.
- **The register files have 2 write ports** (`CORE_RF`, `CORE_FRF`): 2 banks of distributed RAM (A: the
  pipeline's WB, B: the FPU) and a 32-bit table telling which bank is newer (LVT, live value table). Reads go
  "B being written → A being written → the bank chosen by the LVT". The 2 ports never write the same register
  in the same cycle, thanks to the WAW waits. **Moving from the flip-flop version to the distributed RAM
  version** means the contents of the register files are not initialized at reset (only the LVT is reset; in
  simulation the RF starts at 0 and the FRF at positive qNaN). The FF versions were LUT 2,006 + FF 2,048 for
  `CORE_FRF` and LUT 1,319 + FF 2,048 for `CORE_RF`.
- The performance counters' "waiting for a unit" (`hpm_unit_wait`) is the MDU wait plus `fp_wait`.

**Verification**: `SIM/SIM_CORE/tests/t33_fpipe.S` (16 independent FMADD.D in under 40 cycles, dependent
chains and integer answers, FSD right behind, WAW with FLD, WAW on the integer side, FRFLAGS, taking back
behind a trap and FENCE.I, integer ⇄ double, behind a divide, the shadow of a late branch, right behind loads,
reads 1 to 5 instructions after an FLD). For FENCE.I, the FADD behind it is first rewritten into another
instruction by a store. What is taken back is the old FADD, which writes a different register from the
rewritten one, so forgetting to take it back shows in the values (if the same instruction simply flowed
twice, both would write the same value and nothing would show). Bug injection is M78, M88 and M341 to M358 of
`bug_inject.sh` (all 315 detected). t33 was added to SIM_SYS too (measurement 1 is done on the second round,
to exclude cache stalls).

`t11_fp` (SIM_SYS) got slightly slower, 2,815 → 2,829 cycles. This test is all dependent chains and
reading / writing `fcsr`, so the +1 cycle of integer answers and the wait for the FPU to empty before CSR
instructions show. What gets faster is where independent operations line up (10.11.3).

Found during the integration:

- At first, integer pending bits were not cleared until the cycle after the answer came out. The register
  file passes a write to a read in the same cycle, so ID may read in that cycle. Until fixed, integer
  dependencies were 11 cycles apart, +2 instead of the decided +1 (confirmed by the distance of FCVT.L.D →
  ADDI in t33).
- Taking back behind FENCE.I (`kill0`): if the instruction behind simply flows again as the same one,
  forgetting to take it back only writes the same value twice and cannot be seen. In t33 the instruction
  behind is rewritten.
- (Found with `micro` on the board) An FSD waiting in EX for an answer of the FPU issued to the D$ with stale
  data through the LSU's early issue from EX (`lsu_e_valid`), was taken back, and went again from MA. The
  answer was right, but 2 cycles late, and the C dgemm became slower than the previous version. `~fp_wait` was
  added to `lsu_e_valid` (section 16 of `LitexSystem/docs/BENCH.md`). Holes of this kind that only lose cycles
  are watched by the cycle bounds of SIM_SYS's `bench/fploop.c`.

#### 10.11.3 Expectations and what remains

Assembler kernels (`LitexSystem/software/bench/fpkern.S`) were written, and the cycles per multiply-add were
measured in simulation (`SIM/SIM_SYS/bench/fploop.c`, data sized to fit in the D$) (2026-10-09). On the board
`micro` runs the same kernels (`micro 50 fp`).

| Kernel | How it is built | Estimate | SIM_SYS | Limited by |
|---|---|---|---|---|
| dgemm 16×16, assembler | 4×4 of c held in registers, 8 FLDs and 16 FMADDs per k | about 2.1 | **2.18** | FLD and FMADD issuing only one at a time, moving the blocks in and out |
| dgemm 16×16, C (`-O2`) | Triple loop | about 16.6 | 15.67 | The chain of dependencies piling onto one sum (9 cycles) |
| FIR 8 taps, assembler | 8 coefficients, 8 outputs and a window of 8 inputs in registers, one FLD per 8 FMADDs | about 1.3 | **1.45** | Almost reaches one a cycle |
| Dot product, assembler | 8 sums, operands read 2 ahead | about 3.5 | 3.66 | 2 FLDs per multiply-add |

Measured before stage 1 (board, with the L2, C dgemm 64×64): 17.6. C with `-O3 -funroll-loops` is estimated at
about 6.7 (unrolling still leaves the dependency on the same sum).

What remains: resources and timing on the board (cutting logic (stage 0) is considered only if resources or
timing break down) and measuring with `micro`.

---

## 11. Connection to the debug logic

The core has the debug mode of the RISC-V Debug Spec 1.0. It is connected to the DM (`CPU_DBG`) by the
`dbg_*` ports (4.8 of `CPU_DBG_SPEC.md`); the pseudo hart `DBG_HART_STUB` is used only in the BFM
configuration.

| Function | Implementation |
|---|---|
| halt / resume / step | Debug mode. `dcsr` (xdebugver=4, ebreakm/s/u, cause, step, prv), `dpc` and `dscratch0/1` are in `CORE_CSR`. All four are visible only to the debugger; to programs they are CSRs that do not exist |
| Register access | Abstract Command (GPR/FPR/CSR). Accepted only while halted |
| Memory access | **Through the D$** (4.7 of `CPU_CACHE_SPEC.md`). Physical addresses only (aamvirtual=0). After a write `CPU_TOP` invalidates the I$, so software breakpoints (writing an EBREAK) work as they are |
| Program Buffer | None (`progbufsize=0`). When OpenOCD probes CSRs that do not exist (vlenb, mtopi) it tries the Program Buffer, prints one line of error and then decides they are absent. Harmless |
| Triggers (Sdtrig) | 4 of type 2 (decision 67). OpenOCD builds hardware breakpoints (`bp ... hw`, gdb's `hbreak`) and watchpoints (`wp`, gdb's `watch` / `rwatch`) from them. They stop before the instruction or before the access (dcsr.cause 2), and the store has not been done |
| Hart reset | `hartreset` / `ndmreset`. Resets the core, caches and bus side together. The caches become empty |

**Entering debug mode.** A halt puts a mark "stop before this instruction" on an instruction in ID, and the
mark flows down the pipeline by the same path as an interrupt (`id_exc_int=1`, cause = 16 + dcsr.cause; no
real interrupt is 16 or above). The commit point in MA empties the pipeline without executing that
instruction, and instead of trapping records `dpc`, `dcsr.cause` and `dcsr.prv`. `mepc` and `mcause` do not
change. After that ID issues nothing. Instructions ahead complete normally; if one of them traps, the mark is
dropped and put again on the first instruction of the handler.

| Reason | cause | Instruction marked |
|---|---|---|
| EBREAK (the one of `dcsr.ebreakm/s/u` for the current privilege level) | 1 | That EBREAK |
| haltreq | 3 | The next instruction to come to ID. When waiting in WFI, the WFI completes and the one after it is marked (spec 4.1; dpc is the one after the WFI) |
| step | 4 | After resume, only one instruction is issued, and the one after it is marked. If the first one traps, it stops at the head of the handler |
| resethaltreq | 5 | The first instruction after reset |

- No interrupts are taken during step (`dcsr.stepie=0` fixed). WFI completes as a NOP.
- resume redirects to `dpc` and sets the privilege level to `dcsr.prv` (clearing `mstatus.MPRV` if it is not
  M).
- When reasons overlap, the priority is resethaltreq > haltreq > step, as in the spec.

**Register access.** While halted the pipeline is empty and issues nothing, so no dedicated port was made;
the existing read ports are borrowed for a cycle (the first read port for GPR/FPR, the read address for
CSRs). Writes go through the write port in the next cycle. A 32-bit write keeps the upper 32 bits (read,
merge, write). CSRs that do not exist, writes to read-only CSRs and numbers out of range are errors (the DM
sets cmderr=3). When the debugger writes an FPR, `mstatus.FS` becomes Dirty.

**Verification.** `t23_debug` of `SIM/SIM_CORE` (a debugger in the test bench drives the signals instead of
the DM; checks halt, step, EBREAK, register reads and writes and their errors, halt during WFI, resume into U
mode, and debugger triggers (execute and load, U mode)), `t30_trig` (triggers that raise exceptions), bug
injection M211–M231 and M298–M314 (`SIM_CORE/bug_inject.sh`), and `SIM/SIM_OCD` (co-simulation of OpenOCD and
the RTL with the core as the hart, running halt, registers, step, software breakpoints, hardware breakpoints,
watchpoints (store, load) and reset halt).

---

## 12. Order of implementation and testing

| # | Contents | Verification |
|---|---|---|
| M1 | Pipeline skeleton (IF/ID/EX/MA/WB), a subset of RV64I, M-mode, physical addresses **(done, 12.3)** | 4 hand-written programs, back-pressure injection, 28 injected bugs |
| M2 | Full RV64I + Zicsr + traps + CLINT **(done, 12.4)** | riscv-tests rv64ui-p-*, rv64mi-p-* |
| M3 | M / A / C extensions (A already implemented on the cache side) **(done, 12.5)** | rv64um/ua/uc |
| M4 | F / D extensions (FPU, section 10) **(done, 12.6)** | rv64uf/ud, comparison with SoftFloat |
| M5 | S/U privilege + PMP + MMU (Sv39) **(done, 12.7)** | rv64si, the `v` environment of riscv-tests, home-made page table tests |
| M6 | PLIC, branch prediction, performance tuning **(done, 12.8)** | `tb_PLIC`, `t15_plic`, `t16_bench`, `t17_btb` |
| M7 | Joining the core and the caches **(done, 12.9)** → LiteX + booting Linux | `SIM/SIM_SYS`, the board |

### 12.1 How to proceed: build up from the pipeline skeleton

Comparing "build up from the decoder" and "build up from the skeleton + CSRs":

| | Decoder first | **Skeleton + CSRs first (adopted)** |
|---|---|---|
| Pros | Easy unit tests (exhaustive comparison of instruction word → fields). The uop definition settles early | A **working machine** early, and everything after can be verified end to end. The **joints** with the caches, debug and bus (the highest risk in this project) can be hit first |
| Cons | Nothing runs for a long time. A uop definition built up without fitting the pipeline means rework | Much scaffolding at first. The pipeline structure must be decided first (it is decided in this spec) |

In this project the surroundings (caches, debug, FPGA flow) are verified, and the remaining risk is in the
joints. So the **skeleton first** was taken, while the decoder was made from the start as "an independent
module + unit tests", adding tables for each extension (the best of both).

### 12.2 Verification environments

| Environment | Contents |
|---|---|
| `SIM/SIM_CORE` (new in M1, in use) | The core alone. Memory model of the cache ports, retire trace, back-pressure injection, bug injection |
| `SIM/SIM_FPU` | The FPU alone. Compared with Berkeley SoftFloat (10.8). `bug_inject.sh` targets the cuts between stages (registers across states) |
| `SIM/SIM_MMU` | PMP / TLB alone. Compared with an independent model written from the spec (section 6) |
| Timing check of bug injection | `t16_bench` must finish within `BENCH_LIMIT` cycles. **The predictor is transparent, so looking only at results, a broken prediction goes unnoticed** (12.8) |
| riscv-tests | The official tests of each extension. Both the `p` environment (physical) and the `v` environment (Sv39 + U mode) |
| `SIM/SIM_CPU` | CPU_TOP joined (caches + bus + debug), with a BFM on the CPU side |
| `SIM/SIM_SYS` | Runs **the real core behind the real caches**. The same programs as SIM_CORE. Bugs that depend on the presence of the caches can only be seen here (12.9) |
| `SIM/SIM_OCD` | OpenOCD co-simulation (run control, memory access) |
| Bug injection | Follows the existing way, injecting into decoding, hazards and exception priorities |

### 12.3 Implementation of M1 (done)

Structure:

| Module | Contents |
|---|---|
| `CORE_IFU` | PC, outstanding request FIFO (4), fetch queue (4), `i_kill` on redirects |
| `CORE_DEC` | Combinational RV64I decoder. Outputs the uop fields (`alu_op`/`a_sel`/`b_sel`/`word_op`/`br_op`/`mem_size` …) |
| `CORE_RF` | 32×64 bits, 2R1W, x0 is 0, a write in the same cycle is passed to the read (write-first). 2R2W from C2 stage 2 (10.11.2) |
| `CORE_EXU` | ALU (64/32-bit), branch conditions, link PC, branch target, memory address |
| `CORE_LSU` | Data cache port. One access at a time. Sign / zero extension of responses |
| `CPU_CORE` | ID/EX/MR/MA/WB pipeline registers, forwarding, stall control, trace |

Control between stages (the rules settled in M1; the current form with the MR stage added is in 12.10):

| Signal | Definition | Meaning |
|---|---|---|
| `stall_ma` | `ma_valid & ma_mem & ~lsu_resp_valid` | MA is waiting for the cache's response |
| `stall_ex` | `stall_ma \| (ex_is_mem & ~lsu_accept)` | EX cannot advance (waiting for a response, or the cache does not take the request) |
| EX→MA | Transferred on `ex_advance`; when `~ex_advance & ~stall_ma`, **MA is emptied** (bubble) | If EX cannot hand over but MA does not empty, it deadlocks |
| MA→WB | Transferred on `~stall_ma`; when `stall_ma`, **WB is emptied** (bubble) | So the same instruction does not retire twice |
| EX operands | While EX is stalled, **the forwarded values keep being captured** into `ex_rs1_data/ex_rs2_data` | During the stall MA/WB move on and the forwarding source disappears |

Forwarding has two paths, MA and WB. When MA has a load, it gives the cache's response `lsu_resp_data`
instead of `ma_result` (the address). EX can advance in the cycle `stall_ma` falls, that is, the cycle the
load's response is out, so this resolves load-use with one bubble.

**The forwarding source is chosen one cycle earlier and kept in flip-flops** (`fwd_a_ma / fwd_a_wb /
fwd_b_ma / fwd_b_wb`). What EX, MA and WB will hold next cycle is decided by the same signals that move the
pipeline registers (`ex_advance`, `stall_ma`, `flush`, `trap_taken`, `ex_exc`), so register numbers can be
compared in advance against **what they are about to hold**. The rules correspond one to one with the rules
of the pipeline registers, and changing one requires changing the other.

- MA: emptied on a trap/xRET; gets EX's instruction if EX advances (its write cancelled by an EX exception);
  otherwise stays (stall) or becomes a bubble
- WB: MA's instruction if MA is not stalled; cancelled by a trap in MA
- EX: the source registers of the instruction handed from ID, or of the one staying. The one staying has
  already captured the forwarded value into `ex_rs1_data`, and its source either stays or moves to WB holding
  the same value, so drawing it again gives the same answer

When this was introduced, a check comparing the old comparisons with the new flip-flops every cycle was put
in temporarily, and removed after agreement was confirmed on all SIM_CORE tests, all SIM_SYS tests and
riscv-tests (p 132, v 109).

Verification (`SIM/SIM_CORE`):

| Test | Contents |
|---|---|
| `t01_alu` | Immediate and register operations, shifts, LUI/AUIPC, 32-bit forms, signed/unsigned compares, the 5-bit shift amount of W forms |
| `t02_branch` | The 6 branches, JAL/JALR, loops, forward and backward jumps |
| `t03_ldst` | Loads/stores of all sizes, sign/zero extension, byte lanes, negative offsets |
| `t04_hazard` | EX→EX, MA→EX, load-use, store data, keeping operands during stalls, dependencies right after branches |

The test bench also checks:

- The rules of the cache ports (M1 has only one access at a time)
- That the same PC does not retire in 2 consecutive cycles (double retire detection)
- Back-pressure injection with `+istall=<n>` / `+dstall=<n>`, dropping `ready` of both ports in n% of cycles

`./bug_inject.sh` runs 28 injected bugs both with and without back pressure, and detects them all.

### 12.4 Implementation of M2 (done)

Added:

| Module | Contents |
|---|---|
| `CORE_CSR` | M-mode CSR file and trap state (the table of section 7) |
| `CPU_CLINT` | `msip` / `mtime` / `mtimecmp` (section 8) |
| `CORE_DEC` | Zicsr (CSRRW/S/C and the immediate forms), MRET, WFI |
| `CPU_CORE` | The commit point is in MA, and traps, MRET, CSR writes and `fence.i` are done there |

Rules around the commit point:

| Event | Condition |
|---|---|
| Trap | `ma_valid & ma_exc & ~stall_ma` |
| MRET | `ma_valid & ma_is_mret & ~stall_ma & ~trap_taken` |
| `fence.i` | Same. Issues the I$ invalidate-all and refetches from `ma_pc + 4` |
| CSR write | `ma_valid & ma_csr_wr & ~stall_ma & ~trap_taken` |
| Incrementing `minstret` | `ma_valid & ~stall_ma & ~trap_taken` |
| Issuing memory requests | `ex_is_mem & ~stall_ma & ~flush` (not issued if the instruction ahead traps) |

Where exceptions are detected:

| Stage | Exceptions |
|---|---|
| ID→EX | Interrupts (except WFI), instruction access fault, illegal instruction, ECALL, EBREAK |
| EX | Illegal CSR access, misaligned branch target, misaligned load/store address |
| MA | Load/store access fault (error response of the cache) |

Verification:

| Test | Contents |
|---|---|
| riscv-tests `rv64ui-p-*` | 53/54 PASS |
| riscv-tests `rv64mi-p-*` | 15/17 PASS |
| `t05_csr` | CSR instructions, WARL, accuracy of the counters, illegal accesses |
| `t06_irq` | CLINT timer, software and external interrupts, masking by `mie`/`mip`/`mstatus.MIE`, WFI, vectored mode |
| `t22_mip_seip` | While the PLIC's S line is up, `csrs`/`csrc mip` do not leak into the software SEIP, and when the line falls SEIP falls too |
| `t07_trap` | Bus access faults, misalignment, `mtval`/`mepc`, suppression of instructions behind a trap |

Known failures (all tests that require unimplemented features):

| Test | Reason |
|---|---|
| `rv64ui-p-ma_data` | Requires misaligned accesses to be executed in hardware. This core traps, as the spec allows (`rv64mi-p-ma_addr` checks the trap side and PASSes) |
| `rv64mi-p-breakpoint` | Needs the debug triggers (`tselect`/`tdata*`). To be handled when joining the debug logic (2026-10, PASS with decision 67) |
| `rv64mi-p-pmpaddr` | Needs PMP. Implemented in M5, which adds S/U modes |

Bug injection grew to 50 kinds, all detected with and without back pressure.

Not done (needed at integration):

- A wrapper putting `CPU_CLINT` on the peripheral bus (AXI4-Lite) and its inclusion in `CPU_TOP`
- PMP (M5), debug triggers

### 12.5 Implementation of M3 (done)

| Extension | Implementation |
|---|---|
| M | `CORE_MDU`. Sits beside EX, and EX waits. Multiplies: MUL / MULW wait 1 cycle and the MULH family 2 (decision 61; originally 3). Divides do 1 bit a cycle, skipping in one cycle the leading steps where the quotient is known to be 0 (decision 62; originally always 32 or 64 cycles) |
| A | The decoder only maps `mem_cmd` to the cache's commands. Read-modify-write and the reservation are on the cache side (already implemented) |
| C | `CORE_DECOMP` (16-bit → 32-bit) and rebuilding `CORE_IFU` around parcels |

**Multiplier**: 128 bits are assembled from 4 unsigned 32×32 partial products (a form that fits the FPGA's
DSPs), and the sign is fixed afterwards by subtraction.

```
a * b (signed) = ua * ub - (a < 0 ? ub << 64 : 0) - (b < 0 ? ua << 64 : 0)
```

**Divider**: restoring. Division by zero and the only overflow (-2^63 ÷ -1) are answered without iterating.
The 32-bit forms shift the dividend to the top and run 32 times.

**C extension and fetch**: instructions do not sit on 4-byte boundaries and cross 64-bit fetch words, so the
fetch queue **holds parcels (16 bits), not instructions**.

| Mechanism | Contents |
|---|---|
| `head_pc` | The address of the parcel at the head of the queue. Parcels are pushed in order and dropped all at once, so entries need no address of their own |
| `push_pc` | The address of the next parcel to push. On a redirect into the middle of a word, this decides how many parcels before it are dropped |
| Head decision | If `p0[1:0] != 11` it is a 16-bit instruction, otherwise 2 parcels are needed |

Since IALIGN becomes 16, `mepc` drops only bit 0, and misaligned branch target exceptions can no longer
happen (because JALR drops bit 0).

Verification:

| Test | Contents |
|---|---|
| riscv-tests `rv64um-p-*` | 13/13 PASS |
| riscv-tests `rv64ua-p-*` | 19/19 PASS (`amocas` is Zacas and out of scope) |
| riscv-tests `rv64uc-p-rvc` | PASS |
| `t08_rvc` | Meaning of compressed instructions, 32-bit instructions across word boundaries, branches into the middle of a word, C.EBREAK, `mtval` of illegal compressed instructions |
| `t09_muldiv` | Signs of multiply and divide, division by zero, overflow, 32-bit forms |
| `t10_atomic` | LR/SC (success, failure, reservation broken by a store in between), all AMOs in 32/64 bits, misalignment |

riscv-tests are all **built with C**, so the instruction stream itself mixes 16-bit and 32-bit instructions
and the fetch path is always exercised.

Bug injection is 76 kinds, all detected with and without back pressure.

### 12.6 Implementation of M4 (done)

| Module | Contents |
|---|---|
| `CPU_FPU/FPU_ROUND` | Normalization, rounding, packing. **Everything that is rounded goes through here** |
| `CPU_FPU/CORE_FPU` | All F/D operations |
| `CORE_FRF` | FP register file (32×64, 3R1W) |
| `CORE_DEC` / `CORE_DECOMP` | F/D instructions, C.FLD/C.FSD/C.FLDSP/C.FSDSP |
| `CORE_CSR` | `fflags`/`frm`/`fcsr`, `mstatus.FS` and `SD` |

**The connection was changed**: the plan was loose coupling with a scoreboard, but it became **waiting in
EX**. Reasons:

- In a single-issue in-order core, the instruction right after an FP instruction usually depends on its
  result. Loose coupling only gains when independent integer instructions follow, so the gain is small.
- A scoreboard + kill/drain at flushes + epoch tags (10.6) breed more bugs than the FPU itself. The judgment
  was that **the most dangerous part is not the arithmetic but the control**.
- The same form already works and is verified in the MDU.
- Loose coupling is a matter for `CPU_CORE` and can be done **later without touching the FPU's datapath**. To
  go back, add four things: (1) a busy bit per FP register, (2) arbitration of the FRF write port at
  completion, (3) epochs at flushes, (4) draining on `fcsr` accesses.

**Arithmetic units**

| Unit | Method | Cycles |
|---|---|---|
| FADD/FSUB/FMUL/the 4 FMAs | **One multiply-add datapath**. Computes `a*b+c` exactly in a common 128-bit frame, **rounding once** | 4 |
| FDIV | Restoring. 128 bits for double, 64 bits for single | 64 to 128 |
| FSQRT | Restoring (square root at 2 bits per iteration) | 64 |
| Compare, classify, sign, move, convert | Combinational + 1 stage | 1 |

Multiply-add was made one datapath not to save effort but **because that is the definition of fused**.
Separating the adder and the multiplier would round twice and not be an FMA. FADD goes through the same path
as `a*1.0+c`, and FMUL as having no addend.

The quotient of a divide must be produced **down to the rounding position of the deepest subnormal** (up to
54 extra bits for double). That is why the rounder's input is 128 bits. For the square root, the result is
always normal even when the input is subnormal (the root of the smallest subnormal is 2^-537), so 64 bits are
enough.

**Verification**: compared with **Berkeley SoftFloat (RISCV specialization)** in `SIM/SIM_FPU`. 450,000
checks by default, about 4.94 million with `make long`. All operations × both precisions × the 5 rounding
modes × exhaustive special values + random. All result bits and all 5 exception flag bits.

Bugs the reference model found (none of them noticeable with hand-written tests):

| Symptom | Cause |
|---|---|
| Subnormal values off by a factor of 2 | The exponent after normalization was off by 1 (`(1-bias)-sh` versus `-bias-sh`) |
| `flt` is 1 on equal values | The inversion by sign was applied even when the significands were equal |
| FSGNJ/FMIN on values that are not NaN-boxed | Missed that everything other than move instructions must give a canonical NaN |
| UF not raised when rounding reaches the smallest normal | Tininess was decided on **the packed exponent**. Correctly it is decided on the result of rounding under the assumption of "an unbounded exponent range" |

**Bugs found when joining the core** (detected by riscv-tests):

| Symptom | Cause |
|---|---|
| `fmul` right after `flw` gives a canonical NaN | **While MA waited for the cache's response, the FPU started computing with stale operands**. The MDU had the same hole, latent since M3 |
| An FP instruction right after `csrs mstatus, FS` is illegal | The decoder reads `mstatus.FS` and `frm`, so serialization after CSR writes was needed (restored what had been removed as "redundant" during the SMP preparation) |
| `c.fld` is illegal | Compressed instructions treated as reserved before D was implemented had not been enabled |

**riscv-tests**: `rv64uf` 11/11, `rv64ud` 12/12. 124 PASS overall.

**A pitfall from the simulator**: calling a **task with output arguments** from `always @(*)` makes Icarus
Verilog put those outputs into the sensitivity list as well, and the block keeps waking itself. The whole
core became about 1000 times slower, a few seconds per cycle. Only the call of `unpack` has an explicit
sensitivity list to avoid this (the task reads only 2 inputs, so the explicit list is exact). The same kind of
constraint as avoiding `always_comb` in the caches.

**Not done**: the `HAS_FPU` parameter (10.10) is not in yet. The divider stays radix-2, taking 128 cycles for
one double. Both when they become needed.

---

### 12.7 Implementation of M5 (done)

S/U privilege, PMP, Sv39 MMU. Done in 3 steps, each committed after passing the regressions.

**Step 1: privilege modes** (`CORE_CSR` / `CORE_DEC` / `CPU_CORE`)

The privilege level is kept in `CORE_CSR`, **because everything that changes it (traps, MRET, SRET) is
decided there**. The pipeline only reads it.

- `mstatus` got the S-side fields and the trap bits (MPRV/SUM/MXR/TVM/TW/TSR). `sstatus` is **the same
  register seen through a mask**, not a copy
- `medeleg`/`mideleg`. Delegated only when "the bit is set and the origin is not M". The target is never
  above the origin
- Interrupts are "unconditional at levels below one's own, and at one's own level subject to that level's
  global enable bit". **In U mode, S interrupts come in even if `sstatus.SIE` is 0** (SIE only stops them at
  its own level)
- `SRET` and `SFENCE.VMA` were added to the decoder. `SFENCE.VMA`, like `fence.i`, refetches after commit
  (because it changes translations the front end has already used)

Two expected values of riscv-tests were reversed: `mstatus.MPP` is no longer fixed at 3, and `satp` now
exists.

**Step 2: PMP** (`RTL/CPU/CPU_MMU/MMU_PMP` and `CORE_MMU`)

`CORE_MMU` was first made **as a container**, with every address the pipeline uses going through it (at this
point the translation was the identity). So adding the TLB and the walker in step 3 needed hardly any change
on the `CPU_CORE` side.

The fetch unit was rebuilt for the instruction side. **Fetching is speculative, so a fault must not become an
exception where it is found**. It is written into the queue alongside the parcels, and the instruction that
actually uses it raises the exception in ID. Faulting fetches are not sent to the cache. The fault code was
2 bits from the start, so the page faults of step 3 did not need a rewrite.

**Step 3: Sv39** (`MMU_TLB` / `MMU_PTW`, `CORE_MMU` extended)

- The TLB is fully associative and **keeps the permission bits as read, checking them at every lookup**.
  Privilege, SUM and MXR change without invalidating anything, so checking at write time would go stale
- The walker borrows the D$ port. **It starts only when nothing is in flight in the LSU**, and holds the port
  until it finishes. While it holds it, the data side is told "cannot issue this cycle". No access could be
  issued anyway, and this way the PMP checker can be turned over to the walker too
- A/D are not updated by hardware (6.2)

**Bugs found when joining the core**:

| Symptom | Cause |
|---|---|
| `rv64ui-v-st_ld` / `rv64uc-v-rvc` loop forever | For **a 32-bit instruction crossing a page boundary** where only the second page faults, `stval` was given the instruction's start address (the first page). The OS cannot fix the right page and the same exception repeats. `mepc` is the start of the instruction, but `stval` must be **the side that faulted** |

**Verification**:

| Environment | Contents |
|---|---|
| `SIM/SIM_MMU/tb_PMP` | 500,000 cases matched against an independent model written from the spec in byte ranges |
| `t12_priv` | Walks M → S → U. U mode, the T bits and delegated interrupts, which rv64si does not touch |
| `t13_pmp` | The 3 permissions, the lower-numbered entry winning, locking, MPRV |
| `t14_mmu` | 3 levels with hand-written page tables, 1G/2M superpages, all permission bits, `sfence.vma` |
| **riscv-tests `v` environment** | **109 tests**. Sets up Sv39 in S mode, runs in U mode and allocates pages on demand. Every instruction goes through translation and the page tables are walked thousands of times |
| riscv-tests `p` environment | 132 tests (`rv64si` 7/7, including `rv64mi-p-pmpaddr`) |

For the `v` environment, `CORE_MEM_MODEL` came to **respond by physical address**. Until then it ignored
`*_req_paddr` and answered by virtual address, so once the MMU was in, data could no longer be found. The
test bench also interprets the HTIF console (the top byte of `tohost` is the device number).

Bug injection (125 kinds) also includes one test of the `v` environment. The home-made tests all run on one 1G
page, so **the ITLB never misses**, and the path where the pipeline and the page table walker contend for the
D$ port does not move. Only the `v` environment tests, mapped in 4KiB units, step on it.

**Not done**: the debug logic's Access Memory does not yet go through the same translation as the hart
(section 11).

---

### 12.8 Implementation of M6 (done)

PLIC and branch prediction.

**Step 1: PLIC** (`RTL/CPU/CPU_PLIC`)

As in the table of section 8. It is built **per context (hart × privilege)**. A register that raises the
source lines was added to the test bench, and the memory model relays the PLIC region, so a program can go
round "raise a line → external interrupt → claim → complete" (`t15_plic`).

Bug injection did work twice. First it exposed **dead logic in the RTL**: no mutation of the dedicated check
for priority 0 could be detected, and on inspection "greater than the threshold" already covered it since the
threshold cannot go below 0. It was removed. Second, it brought out 4 cases that the unit bench (`tb_PLIC`)
watches but the core tests did not. They were added to `t15_plic`, so that neither test leans on the other.

**Step 2: branch prediction** (`CORE_BTB` and `CORE_IFU`, 4.2)

`t16_bench` is a load for measuring, made of 3 loops of 1000 iterations each.

| | No prediction | With prediction | Ratio |
|---|---|---|---|
| Always-taken backward branch | 12003 | 7016 | 1.71 |
| A call and return every time | 26002 | 9527 | **2.73** |
| Branch decided by an LFSR | 25994 | 16925 | 1.54 |
| Total | 64087 | 33556 | **1.91** |

`t14_mmu` also went 23399 → 14159 cycles. **One taken control transfer cost about 6 cycles**, and becomes 0
when predicted. Call and return gain most because the BTB predicts `ret` (JALR) too when there is only one
caller.

**What verification revealed**: the predictor is **transparent**, so mutations that degrade prediction do not
change results — EX always corrects them. 9 of 18 were "not detected". So **a timing check was added to bug
injection**: `t16_bench` must finish within `BENCH_LIMIT` cycles. That catches the 3 that break prediction.
The remaining 6 (tag compare, deciding which branch in the word, counter hysteresis) are buried in a few
percent on a load of this size, so they were removed from the campaign and written with reasons at the head
of `bug_inject.sh`. A benchmark with a code footprint larger than the BTB is needed, but that is work for the
stage of **tuning** the predictor.

**A bug Icarus found**: the BTB update was written directly into the instance's ports as
`.btb_upd_pc (ex_pc)`, and since `ex_pc` and others were declared below it, **Icarus made a 1-bit implicit
wire** and the address was silently truncated. Verilator lets it through. The same form was hit in M4 too, so
it was changed to the form **never write signals declared below an instance directly into its ports** (declare
a dedicated wire above and `assign` it).

**Change in the test bench**: the check "if the same PC retires in 2 consecutive cycles it is a double
retire" falsely fires with prediction on **a branch to itself** (used by t06 to wait for interrupts). Control
transfer instructions were excluded from it.

**Step 3: measuring** (`make profile`)

Every cycle where nothing reached write-back is assigned to one reason, so the breakdown adds up to the
total.

| | t16_bench | t14_mmu | t09_muldiv |
|---|---|---|---|
| CPI | 1.34 | 2.10 | 5.04 |
| Waiting for the D$ | 0.0% | **33.4%** | 0.0% |
| Waiting for the MDU / FPU | 0.0% | 0.0% | **71.9%** |
| Waiting for translation | 0.0% | 2.0% | 0.0% |
| Front end empty | 8.9% | 2.0% | 0.7% |
| Serialization | 0.0% | 2.0% | 0.3% |
| Other bubbles | 16.3% | 13.0% | 7.3% |

The front end was dealt with by the predictor. The remaining mountain is **waiting for the D$**, but that is
**a number of SIM_CORE's memory model, not of the design**. The model answers 4 cycles after accepting a
request, and `CORE_LSU` has only one access in flight, so MA waits all of it on every load. Changing only the
model's latency:

| Load response | t03_ldst | CPI |
|---|---|---|
| 4 cycles | 385 | 1.91 |
| 2 cycles | 303 | 1.51 |
| 1 cycle | 261 | 1.30 |

On the other hand **the real D$ hits at one access per cycle** (the performance table of
`CPU_CACHE_SPEC.md`). So the 33% of SIM_CORE is an artifact of the model, and **the real load-use cost cannot
be measured until the core and caches are joined**. Where we are against "2 cycles on a hit (1 bubble)" of
decision 8 waits for that join. The first job of M7.

Note that the current `stall_ma` **stops MA for the full latency of a load even when the next instruction
does not use the result**. If this matters after joining, loads will be decoupled and a scoreboard of the
destination registers will stop only at the point of use.

---

### 12.9 M7 step 1: joining the core and the caches (done)

`CPU_TOP` carries the real core with `USE_BFM=0`. `CPU_MMIO` was put on the peripheral bus, with the CLINT
and PLIC on it. Below `MEM_BASE` accesses already bypassed the caches to AXI4-Lite, so these two sit on that
flow and the rest goes out. The debugger touches them the same way.

`SIM/SIM_SYS` is the new verification environment. It runs the same programs as SIM_CORE through the real
caches and AXI memory.

**Measured load-use** (the number decision 37 was waiting for):

| | SIM_CORE (model) | SIM_SYS (real) |
|---|---|---|
| D$ wait in t03_ldst | 32.0% | **17.5%** |
| D$ wait in t14_mmu | 33.4% | **31.6%** |
| CPI of t16_bench | 1.34 | **1.16** |
| MA stall per access | —— | **1.62 to 2.69 cycles** |

So **half** of SIM_CORE's 33% was an artifact of the model. 1.6 cycles on real hits, 2.7 cycles for t14 with
misses. Against the target of decision 8, "2 cycles on a hit (1 bubble)", the load-use distance is about 2.6
cycles. The share a load-decoupling change could win is at most about 1.4× in t14, and **whether that is big
enough to be worth changing the pipeline is to be judged separately**.

**A bug the join found**:

| Symptom | Cause |
|---|---|
| `rv64ui-p-fence_i` fails | **`fence.i` did not write back the D$**. 5.3 requires it, but the core only invalidated the I$. The I$ was dropped before the write-back, so the refetch read old bytes from memory |

Nobody noticed from M1 to M6 because **SIM_CORE's memory model answers both ports from one flat array**.
There is neither an I$ to invalidate nor a dirty line to write back, so forgetting either passes everything.
The fix is to **issue `fence.i` on the data port**: the decoder puts `CMD_FLUSH` on it, and MA waits for its
response before going on to invalidate the I$. The order is guaranteed by structure.

`SIM/SIM_SYS/bug_inject.sh` has **only mutations that cannot be seen unless the caches are real** (5 kinds,
all detected). The head of the SIM_CORE one also notes that this kind cannot be seen there.

**Not connected**: the debug logic still points to `DBG_HART_STUB` and is not connected to halt / resume /
step of the real hart (section 11).

---

### 12.10 Changes for FPGA timing

The history and numbers are in `LitexSystem/docs/TIMING.md`. Only what remains on the core side is written
here.

| Change | Cycles | Check |
|---|---|---|
| Choose the forwarding source one cycle earlier (decision 44) | Unchanged | Compared every cycle with the old comparisons |
| Compare PMP on aligned blocks (decision 45) | Unchanged | `tb_PMP` (misaligned addresses added) |
| Split mispredict correction into EX / MA (decision 46) | Unchanged for control transfers. +1 for mispredicts on non-control-transfer instructions | **`t18_asid`** (new) |
| Make the rounder 2 cycles (decision 47) | +1 per FP operation | SIM_FPU (4.93 million cases against SoftFloat) |
| **Add the MR stage** (decision 48) | Load-use +1, traps and serializing instructions one stage further | Forwarding selection compared every cycle, 7 mutations added |
| A dedicated PMP checker for the walker (decision 49) | Unchanged | **`t20_ptw_pmp`** (new; until then the walker's PMP check was covered by no test) |
| Instruction-side PMP one cycle later (decision 50) | +1 for the response of a fetch denied by PMP | "Denial delegated to S" added to `t13_pmp`, 6 mutations |

**The MR stage**. Placed between EX and MA, it takes PMP checks, settling exceptions and requests to the D$.

> The table below is from when requests were issued from MR. Now requests are issued from EX, and MR only
> decides whether to let them through or cancel them (5.4, decision 58). `stall_mr` became the same as
> `stall_ma`.

| Signal | Definition | Meaning |
|---|---|---|
| `mr_is_mem` | `mr_valid & mr_mem & ~mr_exc` | MR issues an access (`mr_exc` is the exception from EX + PMP) |
| `lsu_req_valid` | `mr_is_mem & ~stall_ma & ~flush` | Not issued when the instruction ahead traps |
| `stall_mr` | `stall_ma \| (mr_is_mem & ~lsu_accept & ~flush)` | The cache does not accept |
| `lu_hazard` | EX reads the rd of a load in MR (including LR/SC/AMO and FP loads) | Stops EX for one cycle and puts a bubble in MR |
| `stall_ex` | `stall_mr \| ex_mmu_wait \| lu_hazard \| waiting for MDU / FPU` | |
| EX→MR / MR→MA | Hand over when advancing; a bubble when unable to hand over but the one behind empties; hold when stopped | Just one more stage of the EX→MA rule |

- **Three forwarding sources** (youngest first: MR → MA → WB). MR forwards only values computed in EX; a
  load's answer is not in MR yet. As in decision 44, the selection is in flip-flops decided one cycle earlier
  (6 of them, such as `fwd_a_mr`). At introduction they were again compared every cycle with the old
  comparisons, and removed after confirming 0 mismatches on all tests (including back-pressure injection),
  SIM_SYS and riscv-tests p / v.
- **Starting the MDU / FPU** waits for `~lu_hazard` in addition to `~stall_ma` (when an operand is a load in
  MR).
- **Branch redirects** do not wait for "EX advances", but are issued once in the first cycle the operands are
  ready (`~stall_ma & ~lu_hazard`) (`ex_ctrl_done` stops repeats). Whether EX advances depends on MR's cache
  acceptance, that is on PMP, and that must not be put on the redirect → IFU path. The BTB update uses the
  same condition.
- **The walker** takes the port only when no access is waiting in MR.
- `mdu_active` / `fpu_active` look at `ex_exc_pre` (MDU / FPU instructions do not go through translation, so
  the meaning is the same, and the DTLB is taken off EX's stall).

Measured: `t19_ldbench` of SIM_SYS went 93641 → 96515 (+2874, **+3.07 %**), almost matching the 2872
estimated from the trace. `t16_bench` +8; `t05_csr` / `t07_trap` / `t12_priv`, full of serializing
instructions and traps, +15.5 % / +12.5 % / +17.0 % (most of their instructions are CSRs and traps, so real
loads see far less).

**`t18_asid`**. Two page tables map the same virtual page to different physical pages. Three branches are put
in the ASID 1 page for the BTB to learn, and after switching to ASID 2 without a fence, the same addresses
hold an add, a load and a divide (which occupies EX for long). The BTB says "taken, to +8", so a core that
skips the instruction at +4 fails the check. The three places are 0x40 apart so they fall into different BTB
entries (at first they were 0x100 apart, and the 1st and 3rd fought for the same entry, so the 1st was not
predicted). RTL with the refetch disabled was confirmed to fail at check 3. None of the existing 17 tests ever
causes this case.

**`t19_ldbench`**. `t16_bench` **executes not a single load**, so it cannot measure the cost of load-use. So a
load written in C at -O2 was added (list walking, array sums, string scanning, insertion sort). A rule to
compile a `.c` of the same name as a test's `.S` together was added to the Makefile, and `.sbss` / `.sdata`
and `__bss_start` / `__bss_end` were added to the linker script.

Breakdown in SIM_SYS (real caches): 9784 loads (19.2 %) in 51014 instructions, **2872 where the very next
instruction uses the value**, 5216 where only the one 2 later does. Using it in the very next instruction
**makes no bubble** now (2473 cases with retire interval 1). The plan to add 1 to load-use makes each of these
cost a cycle, so it is estimated at **about +3 % on this load** (2872 / 93641).

## 13. Decisions

| # | Item | Decision |
|---|---|---|
| 1 | Instruction set | RV64GC + Zicsr/Zifencei, M/S/U, Sv39 (equivalent to Rocket's `linux`) |
| 2 | Extensibility | Table-driven decoder, custom instructions through the accelerator port, vectors accepted with variable-latency completion |
| 3 | Pipeline | 6 stages (IF1/IF2/ID/EX/MA/WB) + fetch queue, target 50MHz. **Later 7 stages with MR added** (decision 48) |
| 4 | TLB position | Serial. The DTLB lives in EX (same stage count as the parallel scheme), the ITLB is moved earlier |
| 5 | Parallel VIPT | A future option. The cache-side interface is already split (`*_req_paddr`) |
| 6 | Fetch queue | Implemented (4 entries by default). RVC alignment is done here too |
| 7 | Branch prediction | Static not-taken at first, BTB + 2-bit in M6 |
| 8 | Load-use | Target 2 cycles (1 bubble) on a D$ hit with the ROB bypass |
| 9 | How to proceed | Pipeline skeleton first. The decoder is an independent module + unit tests |
| 10 | When the MMU comes | After the M-mode core works (M5). No change on the cache side |
| 11 | FPU connection | An independent unit + a scoreboard of FP registers. FP operations do not trap, so out-of-order completion is fine |
| 12 | FPU latency | FADD/FMUL 3 stages, FMA 4 to 5 stages, FDIV/FSQRT iterative and not pipelined |
| 13 | Subnormals | Full hardware support (no flush-to-zero) |
| 14 | FPU verification | `SIM/SIM_FPU` with Berkeley TestFloat / SoftFloat as the reference model + riscv-tests |
| 15 | Commit point | MA. Stores are issued in EX, so a trap must be decided in MA to be able to stop the store |
| 16 | Where interrupts are attached | ID→EX. Decided before the instruction executes anything, so `mepc` is exact. With WFI, attached to the next instruction |
| 17 | CSR instructions | Serialized (issued into an empty pipeline, nothing follows until it commits) |
| 18 | Misaligned accesses | Not executed in hardware but trapped (the spec allows it; `rv64ui-p-ma_data` may fail) |
| 19 | Multiplier / divider | Not pipelined, beside EX. Multiply 3 cycles, divide 32/64 cycles. Put on DSPs with 4 partial products (multiply shortened by decision 61) |
| 20 | Fetch queue | Because of the C extension, in parcels (16 bits) instead of instructions. The head address is tracked by one counter |
| 21 | FPU connection | **Wait in EX** (like the MDU). Loose coupling + scoreboard can be added later on the `CPU_CORE` side only. The judgment that control bugs are scarier than the arithmetic (12.6). **Moved to loose coupling in C2** (10.11.2) |
| 22 | Multiply-add | FADD/FSUB/FMUL/FMA on **one datapath**, to round once (the definition of fused) |
| 23 | Rounding | Gathered into one `FPU_ROUND`. Input is a 128-bit significand + sticky, wide enough to reach the deepest subnormal of a divide |
| 24 | FPU verification | Berkeley SoftFloat (RISCV specialization) as the reference model through DPI. No home-made reference model |
| 25 | Preparing for SMP | Cache side: section 6 of `CPU_CACHE_SPEC.md`. Core side: the `HART_ID` parameter (implemented), making `CPU_CLINT` multi-hart, designing the PLIC per context, extending debug `hartsel`. Remote versions of `fence.i` / `sfence.vma` are software's job (IPI/SBI), no hardware needed |
| 26 | Where the privilege level lives | `CORE_CSR`. Traps, MRET and SRET are decided there, so putting it elsewhere scatters the state over 2 places |
| 27 | A/D bits | **Not updated by hardware** (Svade). A=0 / D=0 on a write become page faults left to the OS. Both Linux and the `v` environment of riscv-tests support this scheme |
| 28 | PTW port | Borrows the D$ port. A dedicated port would add arbitration on the cache side. It starts only when the LSU is empty and holds the port until done, so two never enter at once |
| 29 | When permissions are checked | At every TLB lookup. Privilege, SUM and MXR change without invalidation, so a result checked at write time goes stale |
| 30 | Fetch faults | Not an exception on the spot, but queued with the parcels and raised in ID. Fetching is speculative and may be dropped unused |
| 31 | PLIC unit | Built **per context (hart × privilege)**. Even one hart has 2, M and S. Adding harts later is one parameter |
| 32 | PLIC threshold | Applied **to claim as well**, not only to the interrupt line, so there is no state in which something not presented can be claimed |
| 33 | Unit of branch prediction | **The fetch block** (8-byte word). Instruction boundaries are unknown in IF1, so an entry says to a word "there is a branch from parcel off" |
| 34 | What prediction misses | "Branches before the entry point" and "32-bit branches whose second half is in the next word" are **not predicted**. Both would drop parcels that must not be dropped |
| 35 | Misfetch | For programs that jump into the middle of an instruction, the IFU detects trimming that lands inside an instruction and refetches. It does not happen in correct programs, but when it does, no nonexistent instruction is executed |
| 36 | How to measure performance | Assign cycles to "the reason nothing came out" (`make profile`). The breakdown adds up to the total, so what to fix is decided uniquely |
| 37 | When to evaluate load-use | **After joining the core and the caches**. SIM_CORE's memory model is an artifact with latency 4, while the real D$ hits at 1 cycle/access. The design is not changed on the model's numbers |
| 38 | Order of `fence.i` | **Issued on the data port as `CMD_FLUSH`**. MA waits for its response, so the structure guarantees the D$ write-back finishes before the I$ is invalidated |
| 39 | Coverage of the verification environments | SIM_CORE's memory model answers both ports from one array, so **bugs that depend on the very presence of the caches are invisible in principle**. SIM_SYS holds that kind |
| 40 | Where tables live | **What is looked up associatively in flops, what is indexed in memory**. TLB and PMP compare all entries at once so only flops will do, but the BTB is direct-mapped and fits in distributed RAM. A 64-entry BTB took 3474 LUT / 8000 FF in flops; in RAM it is an order of magnitude smaller |
| 41 | How to write "the lowest match wins" | **1-hot selection (`m & -m`)**. Written as `for (i = N-1; i >= 0; i--)` it becomes a chain of multiplexers as deep as the table, and since TLB and PMP are both on EX's address path, that becomes the cycle time itself |
| 42 | Where to cut the FPU's stages | **Right after unpacking**. What is long is "assembling the answer", with unpacking (leading zero detection of subnormals + full-width shift) at its head. The rounder is not on the `sp_res` path, so the first cut "select \| round" **missed**. 4 cycles more per operation, but FP hardly appears in Linux boot, so it is worth paying. Decoupling (scoreboard) does not change the stage count, so it does not help this problem |
| 43 | FPU operands | **Copied into its own flip-flops in the `start` cycle, with no bypass**. EX holds the values, but where it holds them is the output of the forwarding multiplexers. A bypass multiplexer would (1) put `start`, a late signal depending on the D$'s answer through `stall_ma`, at the head of the deepest cone, and (2) make timing analysis, which does not know the states, analyze nonexistent paths (raw operands → the whole selection → registers several states later). The first version worsened WNS by 11 ns this way |
| 44 | Choosing the forwarding source | **Decided one cycle earlier and kept in flip-flops**. The forwarding multiplexer is at the head of the longest path of the design (load/store address → DTLB → PMP → exception → redirect), 64 bits wide with select lines of fo=197. With register number comparisons in front, the comparison levels and the wiring of `ma_rd` sit directly on the path (4.5 ns of 5.46 ns was routing). The cycle count does not change |
| 45 | PMP comparison | **Check the naturally aligned block containing `paddr`, sharing the comparison of bits 53:1 at both ends**. Both ends of an aligned block differ only in bit 0 of the word address, so the addition of the last byte disappears and comparators go from 4 to 2 per entry. Instruction-side fetch addresses can point into the middle of 8 bytes at a predicted target, but this way the check is on the 8 bytes actually fetched |
| 46 | How mispredicts are corrected | **Control transfers from EX on `~stall_ma`, others refetched from MA**. If the redirect looks at `ex_advance` and `ex_exc`, TLB → PMP → exception → stall decision → redirect → IFU → I$ become one path (the last 4.3 ns of the 29.5 ns worst path after routing). Control transfers need neither, and mispredicts on non-control-transfer instructions (ASID switches) are rare, so one extra cycle is fine. The BTB update uses the same condition |
| 47 | Stages of the rounder | **2 cycles** (shift and round-up decision / +1 and packing). The carry is known before adding, so exponent and overflow are made for both cases in the first half. +1 cycle per FP instruction |
| 48 | Splitting EX | **Cut after the DTLB, putting PMP, exceptions and requests in the MR stage**. Forwarding → add → DTLB → PMP → exception → request / stall decision was 27.2 ns after routing (TIMING.md 15), with two endpoints `ex_advance` and `lsu_req_valid`, so small tricks would not shrink it. The cost is load-use +1, measured +3.07 % on load-heavy C. The alternative of adding kill to the cache without adding a stage (parallel VIPT) costs nothing, but touches the verified caches and needs handling of the side effects of I/O reads. To be judged by measurement once Linux runs |
| 49 | PMP of the walker | **A dedicated checker**. Sharing with the data side puts the input multiplexer (1.03 ns after routing) on the MR → cache request path, which was 0.22 ns short. Costs the LUTs of one PMP |
| 50 | Instruction-side PMP | **Applied one cycle later, in the cycle the cache receives the physical address; on denial, `i_cancel` cancels only that request**. ITLB → PMP → the IFU's response decision was 20.8 ns after routing. The cache is not yet on the bus in that cycle, so a denied fetch never reaches memory or I/O. Denial is detected only for "the request just issued" (if the held address is stale, cancels continue after a fault delegated to S and fetching stops; checked by `t13_pmp`) |
| 51 | Reading and writing `mip` | **The base value of `csrrs` / `csrrc` is, for `mip.SEIP` only, the software bit rather than the read value (OR with the PLIC line)** (`rmw_data` of `CORE_CSR`, as in the `mip` section of the privileged spec). Using the read value as base, a read-modify-write while the PLIC raises an S interrupt copies the line's value into the software bit, and SEIP stays up after the PLIC drops it. OpenSBI runs `csrc mip, STIP` on every M timer interrupt, so on the Arty Linux kept receiving S external interrupts with "nothing there when fetched" (5th round of `LitexSystem/docs/BRINGUP.md`, `t22_mip_seip`) |
| 52 | Entering debug mode | **Put the same mark as an interrupt in ID, and enter debug mode at the commit point instead of trapping** (section 11). The interrupt path already guarantees "stop at the exact pc without executing the instruction, after all earlier instructions finish", so no separate path is made for a halt of the same nature. The mark is told apart by bit 4 of the cause |
| 53 | Register access during halt | **Borrow the existing read and write ports**. During halt issue stops and the pipeline is empty, so there is no conflict. Smaller than adding dedicated ports or a Program Buffer, and verification can use the register file's own paths as they are |
| 54 | Mask of the sticky bit | **Build "i < n" as bitwise comparisons side by side**. `(1 << n) - 1` is a subtraction as wide as the target, and put 16 to 32 levels of CARRY4 on the FPU's longest path (section 22 of `LitexSystem/docs/TIMING.md`). Floating point → integer conversion is split into S_SEL and S_RND, with the range check done on the value before +1 (same cycle count) |
| 55 | tval of loads / stores | **If no earlier exception, choose its own address regardless of the kind of exception**. For misalignment, page fault and access fault alike tval is the address, so the DTLB's answer (fault or not) can be taken off the select signal. The path forwarding → address → DTLB → fault → select disappears |
| 56 | Predicting branches across words | **Put a tail entry in the next word and use it only when fetched sequentially**. Predicting at the starting word makes trimming drop the second half. It is not used when jumped into because there the real start of an instruction is. The tail uses the same one-per-word slot as normal entries |
| 57 | Return address stack | **Two, a fetch side (speculative) and an execute side, with the execute side copied on redirects**. Smaller than a checkpoint per branch, and the effect of the wrong path disappears at the redirect. The BTB became 256 entries (distributed RAM, about +750 LUT). With 64, more than half of Dhrystone's function returns were evicted by other entries |
| 58 | Stage that issues load / store requests | **Issued in EX, let through or cancelled in MR**. The D$ indexes by virtual address, so it can issue in EX. Issuing in MR makes even a hit wait one cycle in MA (after A1). Cancelling is the same idea as the I$'s `i_cancel`: the request vanishes without trace in the D$'s s1. Writing the load result later (A3) was not taken because it cannot make bus errors precise exceptions and does not help stores (`PLAN_LOAD_LATENCY.md`) |
| 59 | Which accesses may be issued speculatively | **Only loads to the cached region (`MEM_BASE` and above)**. Stores, AMO / LR / SC and I/O loads wait for the cycle the instruction in MA commits (or MA is empty), and if they miss it they are issued from MA. Some I/O loads change state just by reading (such as the PLIC's claim) |
| 60 | Cleaning up cancelled requests | **The D$ uses a ROB slot and outputs the response with `d_resp_drop`**. Rather than compacting the ROB, keeping the number of responses always equal to the number of requests needs no change to the arbiter's owner records or the core's counting. Answers of instructions dropped by a flush are counted and discarded by the core's LSU (the D$ does not know) |
| 61 | Multiply latency | **MUL / MULW answer in the cycle after start (EX waits 1), the MULH family in 2**. The lower 64 bits are the sum of 3 partial products, which the sign correction does not reach. The correction is added beside the partial products in the start cycle (`corr`), and the MULH family subtracts it in the cycle after the 128-bit sum. The answer goes combinationally into MR's register, without forwarding in the same cycle. CoreMark's MDU wait went 3 → 1 cycle per operation (+4.6 %). `SIM_CORE/tb_MDU.sv` compares values and cycle counts with a reference model |
| 62 | Early exit of division | **In the cycle after start (`S_DIVN`), skip with one shift the steps where the quotient bits are known to be 0**: the leading zeros of the dividend, and then the number of bits of the divisor − 1 steps (while the partial remainder is shorter than the divisor). About bits(dividend) − bits(divisor) + 1 steps remain, and except for division by 0 and overflow the answer comes in 2 + the remaining steps. The same idea as Rocket's `divEarlyOut`. Normalization is not put in the start cycle so as not to stack forwarding → sign → leading zeros → shift in one cycle. Dhrystone's MDU wait went 17,195 → 2,529 cycles (+6.2 %). `tb_MDU` checks the cycle counts against the formula |
| 63 | Conditional branch prediction | **gshare (PHT 8192 × 2 bits, 12 bits of history)**. The history is the directions of conditional branches with entries in the BTB (4.2). The fetch side and execute side can count the same thing, and divergence is fixed on redirects. Table size and history length were swept with CoreMark in `SIM_SYS`: 1024 entries help little due to conflicts (mispredicts −8 to 10 %), 4096 gives −33 %, 8192 −42 %, 16384 the same as 8192. CoreMark +2.3 %, Dhrystone +1.7 % (simulation) |
| 64 | Conditional branches on a load's value (late branches) | **Not waited for in EX, but advanced to MR on the prediction and resolved in MR**. In MR the load is in MA and its response comes in the `~stall_ma` cycle (the same cycle MR advances), so the same comparison as EX is done there, once. On a mispredict MR redirects and discards the (younger) instruction in EX (`kill_ex`: stops EX's valid, what was handed to MR, and the MDU / FPU; like `flush`, not put into `ex_advance`). BTB and history updates also from MR. While a late branch is in MR, control transfers in EX wait one cycle (to keep updates and redirects in order; the form without waiting was measured too, but lost updates increased mispredicts and CoreMark was 0.3 % slower). A mispredict costs one cycle more than one in EX, but late branches mispredict 1.7 %. Of the load-use waits, those for addresses (pointer chasing) and ALU remain. CoreMark +3.2 %, Dhrystone +5.2 % (simulation) |
| 65 | Bit manipulation (Zba / Zbb) | **Added to EX's ALU** (the pipeline shape does not change). Zba only changes rs1 in front of the adder and the left shifter (`a_uw`: zero extension of the lower 32 bits, `a_shift`: 1 to 3 bits left). Zbb widens `alu_op` to 5 bits and adds operations (andn / orn / xnor, min / max, rol / ror, clz / ctz / cpop and their W forms, sext.b / sext.h / zext.h, orc.b, rev8). Branch comparison, targets and access addresses do not go through the ALU, so those paths do not change. CoreMark built with `-march=..._zba_zbb` has 11 % fewer instructions and gains +11.2 % (simulation, 2.85 CoreMark/MHz). When Linux learns of Zbb from the device tree it switches to the Zbb versions of string functions at boot. `t28_bitmanip` compared with a Python model (`tools/gen_t28.py`), riscv-tests `rv64uzba` / `rv64uzbb` |
| 66 | S-mode timer (Sstc) | **Add `stimecmp`, and when `menvcfg.STCE` is set make `mip.STIP` equal `time >= stimecmp` (a register one cycle late)**. Linux writes `stimecmp` itself instead of calling SBI (an ECALL to OpenSBI, which writes `mtimecmp` in M mode and raises STIP) on every timer. OpenSBI looks for Sstc only on harts of privileged spec 1.12, and decides 1.12 by the presence of `menvcfg` (1.12) and `mcountinhibit` (1.11), so those two and `senvcfg` were added too (fields only for the extensions implemented: `menvcfg` has STCE, `mcountinhibit` CY / IR, `senvcfg` none). `stimecmp` from S only when both STCE and `mcounteren.TM` are set. `t29_sstc`, mutations M289 to M297 |
| 67 | Debug triggers (Sdtrig) | **4 of type 2 (`mcontrol`), exact address match only, firing before the instruction / access (timing 0)**. Registers in `CORE_CSR`, matching in `CPU_CORE`. Execute triggers compare with `fq_pc` in ID and mark the instruction like an interrupt (priority after interrupts, before the instruction's own exceptions). Load / store triggers **compare with `mr_vaddr` (a register computed in EX) in MR and go into MR's exceptions**. Putting them in EX's exceptions would put 4 64-bit comparisons on the path before the DTLB and cache request (TIMING.md 30), so that was avoided. MR's exceptions cancel the D$ access issued early (the same path as a PMP failure), so a store that fires is not written. Per privileged spec 3.1.15, data breakpoints come before misalignment, page fault and access fault of the same access, so MR replaces the exception EX found for that access (`mr_exc_mem`). A mark of which trigger (`id_trig` → `ex_trig_r` → `mr_trig` → `ma_trig`) is carried, and **hit is set when trapping (or halting) at the commit point** (not on discarded paths). Action 0 is a breakpoint exception (cause 3, mtval the address), action 1 is debug mode (dcsr.cause 2). Action 1 only when the debugger writes it together with dmode. In M mode action 0 fires only when `tcontrol.MTE` is set, and a trap to M clears MTE, so it does not fire inside the handler. There is no range matching (NAPOT of match 1, comparisons of 2 to 5), so OpenOCD substitutes a match on the start address for range watchpoints (with a warning). If needed, match 1 can be added just by applying a mask made from tdata2 before the comparison. `t30_trig`, `t23_debug` 5, `rv64mi-p-breakpoint`, `SIM_OCD` (OpenOCD hw breakpoints and watchpoints), mutations M298 to M314 |
| 68 | Zicond and Zihintpause / Zihintntl | **Zicond only adds 2 operations to EX's ALU** (`czero.eqz`: 0 if rs2 is 0, otherwise rs1; `czero.nez` the opposite). It adds only one 64-bit zero test of rs2 and does not go through the branch / address paths. **PAUSE was already executed as FENCE (pred=W, succ=0)** (5.3, `t27_fence`), so it was put in the device tree without changing hardware. Like FENCE it waits in ID for the pipeline to empty, so one round of a spin loop gets a little slower waiting for memory accesses to complete, which fits the intent of the hint (free the pipeline while waiting). Linux uses PAUSE in `cpu_relax()` when Zihintpause is present. NTL.* are ADD with rd=x0 (C.NTL.* are C.ADD with rd=x0), already executed as instructions that do nothing. GCC 13.2 accepts `_zicond` but does not generate `czero` (if-conversion uses it from GCC 14), so it does not help the current benchmarks. `t31_zicond`, riscv-tests `rv64uzicond`, mutations M315 to M319 |
| 69 | Performance counters (Zihpm, Sscofpmf) | **4 counters `mhpmcounter3` to `6` (the `HPM_COUNTERS` parameter of `CORE_CSR`), 19 events (18 and 19 added for the L2 on 2026-10-06), Sscofpmf overflow interrupts and per-level exclusion**. The core passes `CORE_CSR` one bit per event telling whether it happened this cycle (`hpm_ev`), and `CORE_CSR` counts one cycle late (event sources are deep in the pipeline or in the caches, so they are registered once before the selection and the 64-bit add; the level at the time is registered with them to apply MINH / SINH / UINH). CSR instructions are serialized, so the difference of two reads is exact regardless of the delay. Event numbers: 1 cycles, 2 retired instructions, 3 retired loads, 4 retired stores, 5 conditional branches (resolved in EX and late branches resolved in MR), 6 mispredicted branches and jumps, 7 I$ misses (line fills), 8 D$ misses (same, including DMA), 9 ITLB misses (page table walks), 10 DTLB misses (same), 11 cycles waiting for the D$, 12 cycles with the front end empty, 13 load-use cycles, 14 cycles waiting for the MDU / FPU, 15 exceptions, 16 interrupts, 17 cycles with the back end stuck, 18 reads to the L2 (number of L1 fills; cycles where `CPU_L2` accepted AR), 19 of those, L2 misses (both 18 and 19 are 0 in the `L2_SIZE = 0` configuration; section 7 of `CPU_L2_SPEC.md`, `LLC-loads` / `LLC-load-misses` of `perf`). 11 to 13 and 17 are, like the test bench's profiler, "the reason one cycle was lost at the issue point (ID→EX)", one reason per cycle. 5 and 6 are counted in EX / MR, so branches on paths later discarded may slip in slightly. Overflow: when a counter wraps from all 1s to 0, OF is set, and LCOFIP (`mip` bit 13) is raised only when OF goes from 0 to 1. It can be delegated to S with `mideleg`, and S clears it through `sip`. **Smcntrpmf** was added too (MINH / SINH / UINH of `mcyclecfg` / `minstretcfg`). With Sscofpmf but no Smcntrpmf, OpenSBI does not let Linux use the fixed counters (`cycle` / `instret`) that cannot exclude levels, so `cycles` / `instructions` of `perf` were `<not supported>`. Linux uses the counters through OpenSBI's SBI PMU extension. The device tree also lists `cycles` / `instructions` as mapped to the fixed counters only (so that OpenSBI answers "present" to SBI 3.0 event info, which Linux asks at boot). Also OpenSBI (v1.9 series, upstream the same) has a bug where a stop with RESET on a counter that is already stopped does not release it, and Linux's `riscv_pmu_del()` releases with "stop, then stop with RESET", so one counter was lost every time a `perf` event ended (raw events `<not counted>`, 0 samples from `perf record`). Fixed by `LitexSystem/software/boot/opensbi_patches/0001`, which `build_opensbi.sh` applies to its copy. Which events can be counted on which counters is told to OpenSBI by the device tree's `pmu` node (`riscv,event-to-mhpmevent` and so on). `t32_pmu` (SIM_CORE / SIM_SYS), `d04_pmu` (SIM_SYS: cache and TLB events, L2 reads and misses), `make pmu-sbi` (SIM_BIOS: checks OpenSBI's SBI PMU extension called the way Linux calls it; fails with an unpatched OpenSBI), `make linux-perf` (SIM_BIOS: `perf` on Linux; `cycles` / `instructions` and 4 raw events counted together 100 % of the time, and `perf record` takes samples by overflow interrupts), mutations M320 to M340 (SIM_CORE), M13 to M18 (SIM_SYS) |
