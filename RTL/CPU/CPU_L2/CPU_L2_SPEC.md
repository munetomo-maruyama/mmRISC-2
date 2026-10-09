# mmRISC-2 L2 cache design proposal

[日本語](CPU_L2_SPEC_J.md)

- Version: Rev-3 (2026-10-07). Done up to stage 4 (measurement on the board). The board results are at
  the end of section 1 and in section 15 of `LitexSystem/docs/BENCH.md`; the 120-minute stress test
  passes (round 17 of `BRINGUP.md`). What remains is comparing replacement policies (section 9)
- Scope: `RTL/CPU/CPU_L2/` (`CPU_L2.sv`, `L2_TAG_ARRAY.sv`; the data array is the L1's
  `CACHE_DATA_ARRAY`), `RTL/CPU/CPU_TOP/` (integration), `SIM/SIM_L2/` (verification on its own)
- Related: `RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md` (L1), section 14 of `LitexSystem/docs/BENCH.md`
  (motivation), E1 of `LitexSystem/docs/ROADMAP.md`

---

## 1. Purpose and expected effect

Counting Linux loads with the PMU on the board (section 14 of `BENCH.md`) shows that **kernel-heavy
loads spend 50 to 70 % of their cycles waiting for L1 misses**. I$ misses are 19 to 61 per 1000
instructions and D$ misses 15 to 31 (CoreMark: 0.49 and 0.16). The kernel's code and data do not fit in
the 16 KB L1.

One L1 miss costs 12 to 13 cycles with ideal memory (`CPU_CACHE_SPEC.md` 8.4, 64 B received in 8 beats)
and 30 to 50 cycles on the board (worked back from the PMU). The difference, **20 to 35 cycles, is the
round trip to LiteDRAM**, which becomes 2 to 3 cycles when the L2 hits.

Expected (assuming 60 to 80 % of L1 misses hit in the L2 and each gets about 20 cycles shorter; from the
numbers of section 14 of `BENCH.md`):

| Load | L1 misses / 1000 instructions | CPI | Cycles saved | Faster by |
|---|---|---|---|---|
| `tftp` | 93 | 4.80 | about 27 % | about 1.37× |
| `ext4read` / `sdread` | 65 to 70 | 4.0 to 4.5 | about 22 % | about 1.28× |
| `ls -lR` | 47 | 3.08 | about 21 % | about 1.27× |
| `forkexec` | 37 | 2.74 | about 19 % | about 1.23× |
| `gunzip` / `awk` | 4 to 5 | 1.4 to 1.7 | about 4 % | |
| `md5sum` (streaming reads) | 4 | 1.22 | 1 to 2 % | (prefetch would help; section 8) |
| CoreMark | 0.6 | 1.13 | almost 0 | |

The hit rate cannot be known until it is built and measured. Performance counter events for the L2 are
added to count it on the board (section 7).

**Measured (2026-10-07, section 15 of `BENCH.md`)**: better than expected. The L2 hit rate on
kernel-heavy loads is **85 to 95 %** (only `forkexec` 58 %), and one I$ miss went from 31 to 14 cycles.

| Load | Expected | Measured (ratio of CPI) | L2 hit rate |
|---|---|---|---|
| `tftp` | about 1.37× | **1.66×** | 90 % |
| `ext4read` / `sdread` | about 1.28× | **1.56 / 1.50×** | 95 / 85 % |
| `ls -lR` | about 1.27× | **1.46×** | 90 % |
| `forkexec` | about 1.23× | 1.21× | 58 % |
| `gunzip` / `awk` | about 4 % | 1.07 / 1.04× | 92 / 91 % |
| `md5sum` | 1 to 2 % | 1.07× | 71 % |
| CoreMark | almost 0 | +1.4 % | |

---

## 2. Where it sits and how it connects

```
  CPU_TOP
  ┌───────────────────────────────────────────────────────────────┐
  │ CPU_CORE ─ i_* / d_* ─ CPU_CACHE (I$ / D$ ─ BUS_ARB)          │
  │                               │ AXI4 64 bit (l1_axi4_*)       │
  │                               ▼                               │
  │                        CPU_L2 (g_l2.u_cpu_l2)                 │
  │                               │ (cc_axi4_*)                   │
  │   raw bus of the BFM ──▶ BUS_ARB (u_bus_arb_cpu)              │
  │   raw bus of debugger ─▶ BUS_ARB (u_bus_arb) ─────────────────┼─ m_axi4 → LiteX
  │                                                               │   AXIUpConverter (64→128)
  │ CPU_DBG ─ DBG_CACHE ─▶ second port of the D$                  │   → LiteDRAMAXI2Native
  │ DMA port ────────────▶ second port of the D$                  │   → LiteDRAM (DDR3 16 bit)
  │                        AXI4-Lite (peripherals, uncached) ─────┼─ m_axil (does not go through the L2)
  └───────────────────────────────────────────────────────────────┘
```

- It is inserted **right after the memory bus of `CPU_CACHE` (AXI4, 64 bits)**, as a block with one
  AXI4 slave and one AXI4 master (`g_l2` of `CPU_TOP`). The arbitration behind it (the raw bus of the
  simulation BFM, and the raw bus of the debugger when `DBG_VIA_CACHE = 0`) does not go through the L2.
  Both are paths that do not go through the L1 either, and like the L1 they are not coherent with the
  L2 (the board's configuration uses neither). Nothing changes in the core, the L1, `BUS_ARB` or the
  LiteX side (`core.py` only gained the RTL list and parameters).
- **Everything going to main memory passes through here**: I$ / D$ fills, D$ write-backs, the SD card's
  DMA (through the D$'s second port), the debugger's memory accesses (same). There is no other path that
  touches main memory (Ethernet's buffers are in the SoC's SRAM). So **the L2 is coherent by
  construction**. No cleanup (flush instructions, invalidation) is needed.
- LiteX's own L2 (`--l2-size`) is on the SoC bus side, and the CPU's memory bus does not go through it.
  It cannot be used (the note in `build_soc.sh`, `BRINGUP.md`).
- Parameters of `CPU_TOP`: `L2_SIZE` (default 256 KB; 0 connects straight through without an L2),
  `L2_WAYS` (4), `L2_REPLACE_RANDOM` (0). AXI IDs of the L2: fills and partial writes keep the L1's ID;
  writing out evictions uses `CACHE_AXI4_ID_DWB`, the same as the D$'s write-backs.
  - LiteX: `--cpu-l2-size` (default 262144, 0 for no L2; `core.py`). Not the same as LiteX's own
    `--l2-size 0`
  - `RTL/TOP/TOP.sv` (for bringing up the debug logic on the board, 64 KB RAM): `L2_SIZE` default 0
  - Simulation: SIM_SYS, SIM_BIOS and SIM_OCD have the L2 (SIM_SYS / SIM_BIOS can drop it with
    `-GL2_SIZE=0`). SIM_CPU has no L2 (for the tests of the BFM's raw bus and the backdoor checks of the
    memory behind the L1)

---

## 3. Design (proposal)

| Item | Proposal | Reason / alternative |
|---|---|---|
| Capacity | **256 KB** (a parameter; 128 KB also possible) | 94 block RAM tiles are free (section 5). The kernel's frequently used code and data are taken to be a few hundred KB, so on the large side. 128 KB if timing or placement is hard |
| Associativity | **4 ways** | Absorbs the uneven indexing of the L1 (4 ways, VIPT with 4 KB per way). 8 ways doubles tag compare and way select; direct mapped has many conflicts |
| Line | **64 B** (same as the L1) | One L1 fill = one L2 line. No splitting or joining of lines |
| Replacement | **Pseudo-LRU** (tree, WAYS−1 = 3 bits per set, LUT RAM). An invalid way is used first if there is one | The alternative is random (`REPLACE_RANDOM=1`, an 8-bit LFSR advanced at every miss). Random, if it is not much worse |
| Inclusion | **Non-inclusive** (what is in the L1 is not necessarily in the L2) | Inclusion would need a path to invalidate the L1 on L2 evictions. Coherence is not needed, for the reason of section 2 |
| Writes | **Write-back**. Whole-line writes (D$ write-backs) allocate without reading (written into the L2 and dirty, hit or miss). **Partial writes** (the debugger's write-through `STWTHR`) are **write-through, no allocate**: always written to memory, and the word is also updated in the L2 if present (not made dirty) | Only the debugger makes partial writes. With write-through, memory the debugger wrote survives even if the L2 is cleared ("RAM kept over ndmreset" of `SIM_OCD`; the same idea as `CPU_CACHE_SPEC.md` 4.7) |
| Requests at once | **One at a time** (in arrival order). The write-back of the evicted line goes into a **one-line eviction buffer**, so that the fill is done first | The overlap of the L1's 2 MSHRs and 2 write-back buffers becomes serial in the L2, but the core goes one instruction at a time in order, so little is lost. Hit-under-miss is an extension in section 8 |
| Memory side | AXI4 64 bits, bursts of 8 beats (as now) | No change on the LiteX side. 128 bits (LiteDRAM's width) is an extension in section 8 |
| Reset | The CPU's reset (system reset, `ndmreset`) **throws the contents away**. After reset, the valid bits of the tags are cleared over as many cycles as there are sets (1,024 for 256 KB), and requests wait meanwhile. The valid and dirty bits live in the same block RAM as the tag (as flip-flops they would be 1,024 × 4 × 2 = 8,192 of them with a 1,024-to-1 select; in exchange they cannot be cleared in one cycle, hence this clearing) | The same as the L1. Dirty lines are lost on reset, which is how the L1 is today. The debugger's writes are write-through and survive (above). The alternative is in section 9 |

---

## 4. Behavior

The L2 receives only 3 kinds of requests (that is how `CPU_CACHE` is built; AMO and LR / SC are done
inside the D$).

| Request | Who makes it | Hit | Miss |
|---|---|---|---|
| Line read (AR, 8 beats) | I$ / D$ fills | Returns 8 beats from the L2 | Chooses the line to replace. If dirty, to the eviction buffer. Reads 8 beats from memory and writes them into the L2 **while also returning them to the L1 as they arrive** (does not lengthen the fill's wait). The eviction buffer is written to memory afterwards |
| Line write (AW, 8 beats, all bytes enabled) | D$ write-backs | Overwrites the line, dirty | Chooses the line to replace (evicting if dirty), writes without reading, dirty |
| Partial write (AW, 1 beat, strobes) | The debugger's write-through | Writes to memory. Also updates that word in the L2 with the strobes (dirty or clean stays as it was) | Writes to memory only (no allocation) |
| Partial read (AR, INCR within the line, 1 to 8 beats) | (none today) | Returns only the requested beats | Fills the whole line and returns only the requested beats |

An AW burst of "8 beats from the start of the line" is a line write (the D$ always sends with all bytes
enabled); everything else is treated as a partial write.

**Order**. One at a time in arrival order (alternating when AR and AW come together). Requests that use
memory (read misses, partial writes) and requests that evict a dirty line **wait until the eviction
buffer is empty**. A line in the buffer is no longer in the array, so the next access to it always
misses, and memory is read after the write-out has finished. So a write-back and a read of the same line
never overtake each other. The "answer from the buffer" path of the proposal was not built (reading the
same line again right away is rare, and it would only add comparators and selects).

**Flow of a hit** (line read, 64 bits × 8):

| Cycle | |
|---|---|
| t | Accept the AR. Read the tag and data block RAMs by index (4 ways at once) |
| t+1 | Tag compare → select the way that hit (one register stage) |
| t+2 | Beat 1 (R). Then one beat a cycle, beat 8 (RLAST) at t+9 |

From the L1, this is today's miss (12 to 13 cycles with ideal memory) plus 2 cycles: 14 to 15 cycles. 15
to 35 cycles shorter than the 30 to 50 on the board.

**Flow of a miss**. Send the AR to memory, write the returning beats into the data RAM while passing them
to the L1, and write the tag last. The delay seen by the L1 is **+3 cycles** (accepting the AR, the tag
compare, the R FIFO; measured in `SIM_L2`: with memory's AR → R at 2 cycles, the L2's AR → first R is 5
cycles). 1 to 2 cycles more than the proposal's estimate (+1 to 2), but small next to the 20 to 35 cycles
a hit saves. When evicting a dirty line, the AR to memory is sent first and the 8 words are then copied
into the eviction buffer (8 cycles). That is hidden in memory's round trip (20 to 35 cycles on the board).

### 4.1 How it is built (`CPU_L2.sv`)

| Part | Contents |
|---|---|
| Main state machine | `M_INIT` (clearing) → `M_IDLE` (accepting; reads the tag, and for reads the first word too) → `M_CMP` (compare; on a hit sends beat 1 and reads word 2) → `M_RHIT` (a hit at one beat a cycle) / `M_WAIT` (waiting for the eviction buffer) / `M_VCOPY` (dirty line into the buffer) / `M_FILL` / `M_WLINE` / `M_PW_AW`, `M_PW_W`, `M_PW_B` (passing a partial write through) / `M_BRESP` |
| R FIFO | 4 entries, with an ID per beat. No new AR is accepted while beats of the previous read remain |
| Eviction buffer | One line (512 bits) and a separate state machine that writes it to memory (`D_AW` / `D_W` / `D_B`). ID `DRAIN_ID`. It does not compete for AW / W / B with the pass-through of partial writes (a partial write waits until the buffer is empty) |
| Arrays | Tags: `L2_TAG_ARRAY` ({valid, dirty, tag} in a block RAM per way). Data: `CACHE_DATA_ARRAY` (same as the L1, word granularity with strobes). Pseudo-LRU: LUT RAM (written in a process without reset) |
| PMU | `ev_read` (1 in the cycle an AR is accepted), `ev_miss` (1 in the cycle a read miss is found) |
| Parameters | `SIZE_BYTES` (256 KB), `WAYS` (4, a power of 2; 1 also allowed), `REPLACE_RANDOM` (0), `ADDR_WIDTH` (40), `ID_WIDTH` (4), `DRAIN_ID` (0) |

---

## 5. Resources and timing

The estimates (proposal) and the measurement of the L2 synthesized, placed and routed alone in Vivado
(2026-10-06, `FPGA/L2_OOC`, 256 KB, 4 ways, pseudo-LRU, out of context, 50 MHz).

| Resource | Estimate (256 KB) | **Measured alone** | Now (version of section 13 of `BENCH.md`) | Total (from the measurement) |
|---|---|---|---|---|
| Block RAM | Data 64 + tag 2 tiles | **68** (data 64, tag 4: one way of 1,024 × 26 bits is one RAMB36) | 40.5 | 108.5 / 135 (80 %) |
| LUT | 2,500 to 4,000 | **1,078** (plus 12 LUT RAMs for the pseudo-LRU) | 45,598 | 46,676 (73.6 %) |
| FF | 1,500 to 2,500 | **991** (including the eviction buffer's 512 and about 280 of the R FIFO) | 27,006 | 27,997 (22.1 %) |
| Slices | | **659** (in the whole design they are shared with the surrounding logic, so the increase is smaller) | 88.6 % | 92.8 % or less |
| DSP | 0 | 0 | 32 | |

LUTs were less than half of the estimate. The data way select (64 bits × 4 → 1) and both AXI sides were
smaller than expected, and the data array came out as 16 block RAMs per way, each 4 bits wide, side by
side, so no output select is needed.

- **Timing** (measured): register-to-register WNS **+5.977 ns** (20 ns period), overall WNS +3.953 ns
  with 30 % of the period as delay on both sides of the ports, WHS +0.161 ns. The worst path is in
  `M_CMP`: "tag block RAM output (2.45 ns) → tag compare (CARRY4) → `hit_any` → `cmp_iss` (reading the
  second word) → read enable of the 64 data array blocks", 7 logic levels, of the 13.5 ns 9.1 ns is
  routing (3.8 ns for the final enable, fanning out to 64 block RAMs). In the whole design the block
  RAMs spread over all columns of the die and this routing gets longer. If it runs short, making the
  read enable of `M_CMP` independent of the hit (reading on a miss too is fine) takes `hit_any` off this
  path.
- The L2 sits only on the memory bus and does not cross the core's worst path (EX's branch compare →
  IFU, section 31 of `TIMING.md`).
- **Slices**: 88.6 % now (`ROADMAP.md`). The L2 alone is 659 slices (4.2 % of the 15,850), so with it,
  92.8 % or less. This decides the room left for C2 (pipelining the FPU), so the budget of C2 is set
  after measuring the integrated version (section 10).

---

## 6. Coherence, reset and debug

- **DMA, the debugger, fence.i**: all go through the D$, so to the L2 they are ordinary fills and
  write-backs (`fence.i` writes back the D$'s dirty lines, and the I$ then fills from the L2. The L2 is
  shared by the I$ and the D$, so the new contents are seen).
- **The uncached region** (below `MEM_BASE`, AXI4-Lite) does not go through the L2.
- **`ndmreset` / `hartreset` (the debugger's CPU reset)**: throws the contents away, as in section 3.
  After OpenOCD's `reset halt`, the BIOS starts with an empty L2. The BIOS runs from ROM (`0x1000_0000`,
  below `MEM_BASE`), which does not go through the L2, and the clearing (1,024 cycles, about 20 µs at
  50 MHz) finishes before the BIOS uses main memory.
- **`reset halt` and the clearing** (learned in stage 3): the core halts when an instruction reaches ID,
  so in a configuration that starts from main memory (SIM_OCD, `RESET_VECTOR` = 0x8000_0000) the first
  instruction after reset is delayed by the clearing (1,024 cycles). OpenOCD's `reset halt` lowers
  haltreq right after releasing reset and reading dmstatus once, so it saw the hart running, halted it
  to write dcsr, and then let it go again. `CPU_L2` gained `ready` (clearing done), and the DM (1) holds
  a haltreq raised during reset until the hart halts, and (2) shows the hart as unavailable until then
  and during the clearing (`CPU_DBG_SPEC.md` 4.2). To the debugger it looks like "halted when it comes
  out of reset", which is what the specification's "halt right out of reset" means.
- **Power-up**: the same; clears, then accepts requests.

---

## 7. Performance counters

Two events were added to those of `CPU_CORE_SPEC.md` decision 69 (`HPM_EVENTS` 18 → 20). From the L2
through `CPU_TOP` to the core (`ev_l2_read` / `ev_l2_miss`, in the same form as the L1's `ev_ic_refill`
/ `ev_dc_refill`). 0 with `L2_SIZE = 0`.

| Number | Event | perf |
|---|---|---|
| 18 | Line reads from the L2 (L1 fills) | `LLC-loads` (mapped to cache event 0x10010 in the device tree's `pmu` node), `r12` |
| 19 | Of those, L2 misses | `LLC-load-misses` (0x10011), `r13` |

The LLC mapping was added to the device tree (`pmu` of `mmrisc_arty.dts`) and `fw_jump.bin` rebuilt.
`workload.sh` counts r12 / r13 in its fifth run, and the summary table gained columns L2 (reads per 1000
instructions) and L2m% (miss rate). Checks: section 4 of SIM_SYS `d04_pmu` (number of L1 fills = number
of L2 reads, the first 8 lines are 8 misses, a line evicted from the D$ hits in the L2; both 0 in a build
without the L2), SIM_BIOS `make linux-perf` (`perf stat -e LLC-loads,LLC-load-misses,r12,r13`).

---

## 8. Extensions that can be added later (not in this version)

| Extension | Effect | Size |
|---|---|---|
| Catching DMA writes | The SD card's DMA comes as the D$'s write-through, passes through the L2 to memory as partial writes, and waits for memory's answer each time. For a stream that writes whole lines, allocating the line, or answering early (a write buffer), should reduce the D$ wait of `sdread` / `ext4read` (30 to 39 %) (added 2026-10-07, section 15 of `BENCH.md`) | Medium |
| Next-line prefetch | Hides the misses of streaming reads (`md5sum`, the data of `ext4read`). Read the next line too on an L2 miss. It uses memory bandwidth, so whether it helps must be measured | Small to medium |
| Hit under miss | An I$ fill does not wait for a D$ miss | Medium |
| 128 bits on the memory side | Matches LiteDRAM's width and removes `AXIUpConverter` (4 beats a line). Needs a change in `core.py` | Medium |
| Overlapping L1 write-backs | Accept the L1's 2 write-back buffers side by side in the L2 | Medium |

---

## 9. Open questions

1. **Capacity**: start at 256 KB, 128 KB if placement or timing is hard. In block RAM alone 256 KB fits.
   → **Settled at 256 KB** (2026-10-07): it closed at WNS +0.159 ns and the L2 is not on the critical
   path (section 32 of `TIMING.md`). With a hit rate of 85 to 95 % there is no reason to shrink it. It
   stays a candidate for cutting if C2 runs out of placement room.
2. **Replacement**: decide between pseudo-LRU and random with `workload.sh` on the board (both are
   available as a parameter). → Not yet (pseudo-LRU hits 85 to 95 %, so no hurry).
3. **Whether the CPU's reset throws the contents away**: the proposal throws them away (like the L1).
   The alternative puts the L2's arrays outside `ndmreset` and resets only the AXI transactions. Dirty
   lines would not be lost, but AXI transactions cut off in the middle by the reset would need cleaning
   up. Little benefit for now.
4. **Whether one line of eviction buffer is enough**: whether the pattern of a D$ write-back followed by
   a fill (the "dirty eviction" of `CPU_CACHE_SPEC.md` 8.4) gets stuck, to be seen in SIM_SYS of stage 3
   (performance breakdown) and with the PMU on the board. Verification on its own only checked
   correctness (section 11). → On the board one I$ miss takes 14 cycles, close to the lower bound for a
   hit, and there is no sign of write-backs holding up fills. The D$ wait that remains in `sdread` /
   `ext4read` is thought to be because the SD's DMA writes pass through to memory as partial writes
   (section 15 of `BENCH.md`, not confirmed). The extension that catches whole lines is added to
   section 8.

---

## 10. Plan and decision points

| Stage | Contents | Decision |
|---|---|---|
| 1 | Decide this proposal | The open questions of section 9 |
| 2 | RTL of `CPU_L2`. Verification on its own in `SIM/SIM_L2`: random AXI4 requests (line reads and writes, partial writes, back pressure) against a reference model of a flat memory image. Parameter sweep of capacity and ways, bug injection | **Done (2026-10-06)**: all 11 sweep configurations PASS, all 31 mutations detected (section 11) |
| 3 | Integrate into `CPU_TOP` (`L2_SIZE`). SIM_SYS (home-made tests, riscv-tests, bug injection), a version of SIM_CACHE's mixed DMA tests with the L2, SIM_OCD (debugger, `ndmreset`), SIM_BIOS (BIOS, booting Linux, `linux-perf`) | **Done (2026-10-06)**: all existing regressions pass (section 12). The SIM_CACHE version with the L2 was not made (section 12) |
| 4 | Board: resources, WNS, booting Linux, `bench.sh` (CoreMark should not change), **before / after comparison of `workload.sh`**, L2 hit rate, 120 minutes of `stress.sh` | **Done (2026-10-07)**: WNS +0.159 ns, slices 91.4 %, block RAM 108.5 / 135. Kernel loads 1.2 to 1.7× (section 1). `stress.sh` 120 minutes PASS (2026-10-09, round 17 of `BRINGUP.md`) |
| 5 | Decide the LUT / slice budget left for C2 (pipelining the FPU). If short, capacity to 128 KB, or the cutting candidates in the C2 entry of `ROADMAP.md` | **Assessment (2026-10-07)**: LUTs suffice but slices would reach 95 to 99 %, and WNS is thin too. Deal first with the core's stall path (section 32 of `TIMING.md`), and pair the cutting candidates with a narrower scope (C2 of `ROADMAP.md`) |
| 6 | The extensions of section 8 if needed (prefetch first) | Only those that measurably help |

---

## 11. Verification on its own (`SIM/SIM_L2`)

`tb_L2.sv` puts a master playing the part of CPU_CACHE in front of `CPU_L2` and a memory model
(`SIM_CPU/AXI4_SLAVE_MEM.sv`) behind it. The reference is a flat image of the memory the master should
see: every beat read through the L2 is compared with it, and writes enter the image when their B
returns.

| Section | Contents |
|---|---|
| 1 Directed | A hit after a miss (number of memory ARs, number of PMU pulses). **Hit timing**: the first beat 2 cycles after the AR, the 8 beats following in 8 cycles (twice in a row). Printing the miss delay (section 4). A line write miss does not read memory. WAYS+1 dirty lines in one set (eviction and write-out). A partial write to a dirty line (the bytes are in memory and in the line). A short read within a line. A partial write to a line not in the L2 (no allocation). **Replacement**: filling an empty set in order evicts way 0 first (pseudo-LRU), evicting a clean line does not write memory. **Write-out stalled**: memory's AWREADY or WREADY held off for 40 cycles, and while a line is in the eviction buffer, a read of that line (replacing a clean line), a partial write to that line, and a line write replacing a dirty line all wait |
| 2 Random | Two read threads (IDs 2 and 3) and one write thread at the same time. Line reads, short reads within a line, line writes, partial writes with random strobes. Lines are chosen from "a window smaller than the L2", "conflicts among 4 sets" and "anywhere". Threads do not use the same line at the same time. RREADY / BREADY / WVALID random |
| 3 Random + memory stalls | The same, with the memory model's READY dropped at random and B / R delayed at random |
| 4 Read back | Read every line through the L2 and compare with the image |
| 5 Reset | Reset the L2, rewrite memory with a new pattern through the backdoor, and read every line **in reverse order** (the lines read last in 4 are still in the L2, so if the clearing did not work the old contents show) |

AXI protocol violations on the memory side (`protocol_err`) must be 0. A watchdog counter also turns a
hang into a failure. `AXI4_SLAVE_MEM` gained `w_hold` (holds WREADY) for the tests that stop a write-out
in the middle (default 0; the other verification environments are unchanged).

**Parameter sweep** (`./sweep.sh`): 256 KB 4 ways (production), the same with random replacement, 128 KB
8 ways, 512 KB 4 ways (memory twice the L2), 8 KB 4 ways (many evictions, 20,000 operations), the same
with random replacement, 4 KB direct mapped, 4 KB 2 ways, 16 KB 8 ways (memory 16 times the L2), and 8 KB
4 ways with 2 other seeds. **All 11 configurations PASS** (980,000 to 2,520,000 checks each).

**Bug injection** (`./bug_inject.sh`, 8 KB 4 ways): dropping a dirty line, not making a line write dirty
(hit / miss), making a fill dirty, not waiting for the eviction buffer (read miss / partial write / line
write replacing a dirty line / `M_WAIT`), wrong word, address or beat count of the write-out, declaring
the buffer empty in the middle of the write-out, not clearing after reset (2 kinds), the direction of
the pseudo-LRU, overflow of the R FIFO (hit / fill), accepting the next AR while beats remain in the
FIFO, not updating a line hit by a partial write / writing to another line on a miss / ignoring the
strobes, returning beats not asked for on a fill, RLAST, way select, index mix-up, treating a partial
write as a line write, the ID of R, the PMU miss, the word of beat 2, leaving the line invalid on a fill,
a dropped bit in the tag compare. **All 31 detected**.

What is not checked here: the upper bits of main memory addresses (the memory model is small, so the
upper tag bits do not change), error responses from memory (`fill_err`), the real sequence of requests
from the L1 (SIM_SYS of stage 3).

---

## 12. Verification of the integration (stage 3)

All existing regressions were run again with `CPU_TOP` with the L2 (256 KB, 4 ways) (2026-10-06).

| Environment | Contents | Result |
|---|---|---|
| SIM_SYS `make` / `make stall` / `make romboot` | 25 home-made tests and 4 programs for DMA, PMU and others (with back pressure, and a version starting from ROM) | All PASS. Also all PASS with `PARAMS=-GL2_SIZE=0` (no L2) |
| SIM_SYS `make riscv-tests` | riscv-tests | 133 PASS, 4 known failures (the same as without the L2) |
| SIM_SYS section 4 of `d04_pmu` | The L2 events (section 7) | PASS (with / without the L2) |
| SIM_SYS `./bug_inject.sh` | 16 (2 for the L2 events added) | All detected |
| SIM_CORE `make` / `stress` / `riscv-tests` | Core (`t32_pmu` changed to check events up to 19) | All PASS, riscv-tests 167 PASS |
| SIM_OCD `make` / `make auth` | OpenOCD (with the L2). Halt after `reset halt`, RAM across `ndmreset` | PASS (after the DM change; section 6) |
| SIM_DBG `make` / `./bug_inject.sh` | Debug logic (checking the DM change) | PASS / all detected |
| SIM_CPU `make` | Buses of CPU_TOP and the L1 (no L2; section 2) | PASS 46,718 checks |
| SIM_L2 | On its own (after adding `ready`) | PASS, all 31 mutations detected |
| SIM_BIOS `make check` / `make pmu-sbi` | LiteX BIOS / OpenSBI's PMU extension | PASS / PASS |
| SIM_BIOS `make linux-perf` | Boots Linux from the SD card model and uses `perf` on the LLC events | To the shell prompt (1.24 billion cycles, 560 million instructions). `perf stat` of `ls /`: LLC-loads 29,370 / LLC-load-misses 10,664 (r12 / r13 give the same counts; L2 hit rate about 64 %). The other `perf` items (fixed counters, 4 raw events, 133 samples of `perf record`) work as they did without the L2 |

**Speed in simulation**: SIM_SYS's memory model answers quickly (AR → R in a few cycles), so the L2 does
not make simulation faster. A miss costs +3 cycles, and each test starts with the 1,024 cycles of
clearing (about 1,060 cycles longer than without the L2). The effect is measured on the board (a memory
round trip of 30 to 50 cycles).

**Mutations left out of bug injection** (equivalent): accepting the next AR while beats remain in the
L2's R FIFO, and a wrong ID on the L2's fill. `BUS_ARB` of `CPU_CACHE` holds the read path until the last
R and routes answers by its grant, not by ID, so neither can happen behind the L1. SIM_L2 checks both
with its two readers (the note in `SIM_SYS/bug_inject.sh`).

**No SIM_CACHE version with the L2 was made**. Many tests of `tb_CACHE` check the memory behind the L1
through a backdoor (when write-backs are stalled, after a flush), and putting an L2 in between breaks the
premise of those checks. The flow of the L1 and L2 together is seen in SIM_SYS (programs, DMA) and
SIM_BIOS (booting Linux), and the fine cases of the L2 alone in SIM_L2.

