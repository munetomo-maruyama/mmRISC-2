# mmRISC-2 L1 cache specification

[日本語](CPU_CACHE_SPEC_J.md)

- Version: Rev-2 (2026-09-19), revised to match the implementation (the design plan of Rev-1 and the
  implementation specification merged)
- Last updated: 2026-10-05 (early issue from EX and cancel, 2-cycle hits, performance counter events)
- Scope: `RTL/CPU/CPU_CACHE/` (L1 instruction / data caches), `SIM/SIM_CACHE` (verification),
  `RTL/CPU/CPU_TOP/` (integration)
- The defaults are equivalent to the L1 of LiteX + Rocket `LitexConfig_linux_1_1`. Number of sets,
  number of ways, block size, and instruction / data separately are parameterized.
- Related: `RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md` (debug logic)

The main changes from Rev-1 (design plan) are collected in section 10.

---

## 1. Purpose and scope

The CPU core (pipeline) and the MMU are implemented in the next phase. In this phase **the L1
instruction cache and the L1 data cache** are built, connected to the memory bus (AXI4) and the
peripheral bus (AXI4-Lite), and verified with the testbench's CPU BFM.

| Item | This phase |
|---|---|
| L1 instruction cache (I$) | **Implemented** |
| L1 data cache (D$) | **Implemented** |
| Uncached access path | **Implemented** (below `MEM_BASE` passes straight through to the peripheral bus) |
| AMO / LR-SC (A extension) | **Implemented** (handled inside the D$) |
| `FENCE` / `FLUSH` / `fence.i` | **Implemented** (operations on the whole cache) |
| Per-line flush / invalidate | Not implemented (added when needed) |
| MMU (Sv39) / TLB | Next phase. This phase takes physical addresses directly |
| Debug accesses through the cache | **Implemented** (4.7). On the memory bus side the debugger also goes through the D$ |
| L2 cache | Not implemented (to be considered after the CPU block is complete; 512 KiB does not fit in the BRAM of the Arty A7-100T) |
| Cache management instructions such as Zicbom | Not implemented (future) |
| ECC / parity | Not implemented |

---

## 2. Position and block structure

### 2.1 Before the CPU core (the BFM configuration)

```
            CPU core (not implemented; the CPU BFM of SIM_CACHE for now)
              │ instruction fetch       │ load/store/AMO
              ▼                         ▼
        ┌───────────┐            ┌───────────┐
        │  ICACHE   │            │  DCACHE   │
        └─────┬─────┘            └─────┬─────┘
              │ AXI4 (fill)            │ AXI4 (fill / writeback)
              └──────────┬─────────────┘
                    BUS_ARB (2 masters)
                         │ memory bus AXI4        peripheral bus AXI4-Lite
                         ▼                        ▼ (uncached)
                    ports of CPU_TOP
```

### 2.2 After the CPU core and MMU are implemented (now)

```
                          CPU_TOP
  ┌────────────────────────────────────────────────────────────────────────┐
  │  CPU core                                                              │
  │   instruction fetch ─┐                 ┌── load/store, AMO             │
  │                      ▼                 ▼                               │
  │            ┌──────────┐          ┌──────────┐                          │
  │            │ ITLB     │          │ DTLB     │  ← MMU (next phase)       │
  │            └────┬─────┘          └────┬─────┘                          │
  │                 │ physical address    │ physical address               │
  │            ┌────▼─────┐          ┌────▼─────┐                          │
  │            │  ICACHE  │          │  DCACHE  │ ← debug accesses also     │
  │            └────┬─────┘          └────┬─────┘   go through here (4.7)  │
  │                 │ fill                │ fill / write-back / uncached   │
  │            ┌────▼─────────────────────▼─────┐                          │
  │            │ BUS_ARB                        │                          │
  │            └────┬──────────────────────┬────┘                          │
  └─────────────────┼──────────────────────┼───────────────────────────────┘
             memory bus AXI4         peripheral bus AXI4-Lite
```

- The caches are indexed and compared with **physical addresses** (PIPT). After the MMU is implemented,
  the physical address the TLB produces is simply passed in, with no change on the cache side.
- The address width follows the CPU's setting (`PADDR_WIDTH`, default 40). The tag width is what remains
  after the index and offset.

### 2.3 Modules

| Module | Location | Contents |
|---|---|---|
| `CPU_CACHE` | `RTL/CPU/CPU_CACHE/CPU_CACHE/` | I$ + D$ + `BUS_ARB`. Combines the AXI4 into one |
| `ICACHE` | `RTL/CPU/CPU_CACHE/ICACHE/` | Instruction cache |
| `DCACHE` | `RTL/CPU/CPU_CACHE/DCACHE/` | Data cache (MSHR, write-back, AMO/LR-SC) |
| `CACHE_TAG_ARRAY` | `RTL/CPU/CPU_CACHE/CACHE_TAG_ARRAY/` | Tag + valid + dirty. All ways read in parallel |
| `CACHE_DATA_ARRAY` | `RTL/CPU/CPU_CACHE/CACHE_DATA_ARRAY/` | Data. In 64-bit units, with byte enables |
| `CACHE_PORT_ARB` | `RTL/CPU/CPU_CACHE/CACHE_PORT_ARB/` | Shares the CPU port of the D$ between the CPU (priority) and debug |

The arrays assume block RAM inference on the FPGA (synchronous read, one cycle later). The tag and data
arrays are initialized to 0 with `initial` (as FPGA block RAM is).

The combinational logic of `ICACHE` / `DCACHE` is written with `always @(*)`, not `always_comb`. Icarus
Verilog restarts an `always_comb` at every assignment to a variable referenced with a variable index, so
the combinational network loops forever at the same time step. `always @(*)` is re-evaluated only when a
value changes, and synthesizes to the same thing.

---

## 3. Parameters

### 3.1 Common

| Parameter | Default | Contents |
|---|---|---|
| `PADDR_WIDTH` | 40 | Width of the physical address received from the CPU. Matches `AXI4_ADDR_WIDTH` of CPU_TOP |
| `XLEN` | 64 | Data width. The same as the AXI4 data width |
| `MEM_BASE` | `0x00_8000_0000` | At and above: cached (memory bus). Below: uncached (peripheral bus) |
| `AXI4_ID_WIDTH` | 4 | ID width of the memory bus |

### 3.2 ICACHE

| Parameter | Default | Contents |
|---|---|---|
| `SETS` | 64 | Number of sets (power of 2) |
| `WAYS` | 4 | Number of ways (power of 2). 1 is direct mapped |
| `BLOCK_BYTES` | 64 | Block size (power of 2, 8 or more) |
| `FETCH_WIDTH` | 64 | Fetch width returned to the CPU (bits). Extracting RV64GC's compressed instructions is the CPU's job |
| `AXI4_ID` | 2 | AXI ID used for fills |

The default is 64 × 4 × 64B = **16 KiB** (the same as Rocket `linux`).

### 3.3 DCACHE

| Parameter | Default | Contents |
|---|---|---|
| `SETS` | 64 | Number of sets |
| `WAYS` | 4 | Number of ways |
| `BLOCK_BYTES` | 64 | Block size |
| `NUM_MSHR` | 2 | Number of outstanding misses held (1 or more) |
| `NUM_WB` | 2 | Number of write-back buffer entries |
| `AXI4_ID_FILL` | 3 | AXI ID used for fills |
| `AXI4_ID_WB` | 4 | AXI ID used for write-backs |

The default is 64 × 4 × 64B = **16 KiB**.

### 3.4 Methods (common, not parameters)

| Item | Method |
|---|---|
| Index / tag | Physical address (PIPT) |
| Replacement | Pseudo-LRU (tree). `REPLACE_RANDOM=1` switches to an LFSR random |
| Write policy | Write-back + write-allocate (DCACHE) |
| Fill burst | AXI4 INCR, `ARSIZE=3` (8 bytes), `ARLEN = BLOCK_BYTES/8-1`, from the start of the block |
| Early answer | Returned to the CPU as soon as the beat of the requested word arrives (the remaining beats are stored in the background) |
| Write-back | The whole block in an INCR burst. `AWLEN = BLOCK_BYTES/8-1` |
| Errors | If a fill / write-back gets SLVERR/DECERR, the line is not cached and an error answer goes to the CPU |

### 3.5 Parameter constraints

1. `SETS`, `WAYS` and `BLOCK_BYTES` are powers of 2.
2. `BLOCK_BYTES` is a multiple of 8 (= `XLEN/8`). The default 64B = 8 beats.
3. `NUM_MSHR >= 1`, `NUM_WB >= 1`.
4. `PADDR_WIDTH` has the same value as `AXI4_ADDR_WIDTH` of `CPU_TOP`.
5. **`SETS × BLOCK_BYTES <= 4096`** (= page size), enforced by an assertion. As long as indexing uses the
   physical address (serial TLB) there are no aliases, so in principle it is not needed, but it becomes
   essential with parallel VIPT (5.6) and SMP (6.4.7), and the default sits exactly at the limit and would
   break silently, so it is treated as a constraint from the start.

### 3.6 Address decomposition

```
  PADDR_WIDTH-1                    IDX_MSB        OFS_MSB         0
 ┌──────────────────────────────┬──────────────┬─────────────────┐
 │            tag               │    index     │ offset in block │
 └──────────────────────────────┴──────────────┴─────────────────┘
   TAG_BITS = PADDR_WIDTH         IDX_BITS        OFS_BITS
              - IDX_BITS - OFS_BITS = $clog2(SETS)  = $clog2(BLOCK_BYTES)
```

With the defaults OFS_BITS = 6, IDX_BITS = 6, **TAG_BITS = 40 - 6 - 6 = 28**. One tag array entry = tag
(28) + valid (1) [+ dirty (1): D$ only]. Changing `PADDR_WIDTH` makes the tag width follow
automatically.

---

## 4. Behavior

### 4.1 Cached region

| Address | Handling |
|---|---|
| `MEM_BASE` and above | Cached. Memory bus (AXI4) |
| Below `MEM_BASE` | Uncached. Passes straight through to the peripheral bus (AXI4-Lite) |

- Uncached accesses do not look at the arrays and go out to the peripheral bus at their own width (the
  same lane rules as the existing debug bus master).
- The I$ too reads below `MEM_BASE` from the peripheral bus without the arrays (to run LiteX's ROM).
- If a PMA (Physical Memory Attributes) table is added in the future, the structure allows simply
  replacing this check.

### 4.2 Reads

1. Look up the tag array and the data array by index, and compare the physical tag with all ways.
2. **Hit**: return the data of that way.
3. **Miss**: allocate one MSHR and issue a refill request.
   - AXI4: `ARBURST=INCR`, `ARSIZE=3`, `ARLEN = BLOCK_BYTES/8 - 1`, `ARADDR` = start of the block.
   - When the requested word arrives, answer the waiting request first (early restart).
   - When the whole block has arrived, update the data array and the tag array.

### 4.3 Writes (D$, write-back + write-allocate)

1. **Hit**: update only the bytes concerned in the data array and set dirty.
2. **Miss**: write-allocate. The store data is merged into the beats of the fill as they are written.
   - **Answered when accepted** (since 2026-10-10, M1 of `LitexSystem/docs/ROADMAP.md`): a store miss
     below `STORE_ACK_LIMIT` (4 GiB) is answered at once, like a hit; the core does not wait for the fill.
     Memory there (LiteDRAM through the L2) never answers a read with an error, so there is nothing to
     report. At and above it (the bridges give DECERR to bits 39:32 set) the answer waits for the fill as
     before, so that a bus error stays a precise access fault.
   - Each MSHR keeps **a word and its byte enables for every word of the line**; later stores to a line
     being filled join it there (instead of waiting for the fill, as when an MSHR held one store and
     locked the line) as long as the beat of their word has not been written. Loads that join the fill get
     their word with those bytes merged in. A store does not join behind a load of its word that is still
     waiting (the load must not see it); it waits for the fill and runs again as a hit. The lock is now
     only for AMO / LR / SC, which wait for the line and run again.
   - A FENCE (and `fence.i`, which flushes) waits until every MSHR is empty, so it still orders the stores
     answered early.
3. **Eviction**: if the victim is dirty, move the whole block to the write-back buffer and write it out
   on AXI4.
   - `AWBURST=INCR`, `AWSIZE=3`, `AWLEN = BLOCK_BYTES/8 - 1`, `WSTRB` all bytes enabled.
   - The write-back proceeds in parallel with the refill.
   - **The fill is asked for first** (since 2026-10-10, M5 of `LitexSystem/docs/ROADMAP.md`): the read
     address of the new line goes out in the same cycle the copy of the victim into the write-back
     buffer starts (one word a cycle through the read port of the data array, `c_state` of `DCACHE`).
     The fill writes its beats through the write port into the victim's way, so a beat is taken
     (`m_axi4_rready`) only once the copy has read that word in an earlier cycle, and the last beat (which
     ends the MSHR) only in the cycle the victim is pushed. The first beat comes two cycles after the
     address at the earliest, so the copy is always ahead and the hold never acts with the L2 or the
     memory models here. Until then the victim was copied out first (about 11 cycles) and the read address
     went out after it.
4. **Order with lines being written back**: entries of the write-back queue and single writes of
   `STWTHR` stay marked "memory is still old" until their B response returns. The read and write
   channels of AXI4 have no order between them, so:
   - A fill of that line (a CPU miss, a read from the second port) waits for the same line in the queue
     and single writes to complete before sending its AR (`f_ar_block`, state `F_ARW`). Without waiting,
     rereading a line just evicted fills it with the old contents.
   - A single write of `STWTHR` is not sent while the same line is in the write-back queue (`sw_wait_wb`;
     the write engine sends the queue first). Sent first, it would be overwritten by the write-back of the
     old line coming after it. This happens when DMA writes to a page the CPU has just evicted.
5. **Array outputs for a request waiting in stage 1**: a request in stage 1 decides with the tag and data
   outputs it read. If those outputs later stop being its own, `s1_data_ok` is dropped and it reads again
   (`s1_reread`). The conditions for dropping are the following; the last two were found later
   (SIM_CACHE 17).
   - Another function used the data read port (`array_rd_busy`), the last beat of a fill
   - **All the while the flush walk runs** (`fl_busy`). The walk reads the tags one set at a time, so a
     request accepted in the cycle FLUSH left stage 1 compared its tag against the tags of other sets.
     With the same tag bits it became a false hit and returned another line's data (the access right after
     `fence.i`).
   - **A write to its own set arrived by forwarding but it could not finish in that cycle**. The tag and
     data forwarding (`tfwd_*`, `fwd_*`) carries only the write of the immediately preceding cycle, so from
     the next cycle it is no longer visible. When a miss in the same set read the tags in the cycle a store
     hit made the line dirty and then waited for an MSHR, one cycle later the line looked clean, and the
     store was lost on eviction. A store hit writes tag and data at the same time, so either of these 2
     conditions alone works (mutation M28 removes both).
   These were why Linux's user space could not start from the SD card on the Arty board
   (`LitexSystem/docs/BRINGUP.md`). Both could have happened with the CPU alone, but they showed up once
   the DMA port sent many second-port fills and `STWTHR`s.

### 4.4 Miss handling (non-blocking, MSHR)

- During a miss, hit accesses to **other lines** are still accepted (hit under miss, miss under miss).
- **A later miss to the same line merges into the MSHR**, with only one bus request. If the beat of the
  word concerned has already passed, it waits for the fill to complete and runs again.
- If all MSHRs are full, the write-back buffer is full, or it hits a way being evicted or filled, the
  request waits.
- Answers are returned **in request order** (aligned by the ROB).

### 4.5 AMO / LR-SC

- Handled inside the D$. The target address is assumed to be in the cached region.
- **AMO**: on a hit, read → operate → write indivisibly and set dirty. On a miss, write-allocate first and
  then execute.
- **AMO addresses are assumed naturally aligned** (word or doubleword; the core raises an exception for
  misaligned ones first). So the lanes are just "upper half or whole, by bit 2 of the address", without
  going through the byte shifter.
- **An AMO hit stays in stage 1 for 2 cycles**. The first cycle takes the old value into a register, the
  second computes from it and writes. When hit decision → way select → operation → write to the data RAM
  were in one cycle, this was the borderline of 50 MHz on the FPGA (sections 17 and 24 of
  `LitexSystem/docs/TIMING.md`). If the arrays are read again in between (`s1_data_ok` drops), the old
  value is taken again too.
- **LR/SC**: one reservation register (by block of physical address). See 5.4.
- AMO / LR-SC to the uncached region are not supported (error answer).

### 4.6 Flush and invalidation

| Operation | Target | Contents |
|---|---|---|
| `FENCE` | D$ | Waits for outstanding bus accesses to complete |
| `FLUSH` | D$ | Writes back all dirty lines and invalidates. Answers after the last write-back has reached memory |
| `i_flush_valid` (`fence.i`) | I$ | Invalidates all lines (1 cycle). Completion is returned with `i_flush_done` |

- If `fence.i` comes in the middle of a fill, that fill does not make its line valid.
- Right after reset, all lines start invalid.
- Per-line operations (`INVAL_LINE` / `FLUSH_LINE`) are not implemented for now.

### 4.7 Coherence of debug accesses (implemented)

Memory bus accesses of the debug logic (SBA / Access Memory) **go through the D$**. The peripheral bus
(below `MEM_BASE`) is accessed directly from `DBG_BUSMST` as before.

| Kind | Behavior |
|---|---|
| Debug read | An ordinary load (`LOAD`). On a miss the line is brought in (the next read hits), and dirty values the CPU wrote are seen as they are |
| Debug write | **Write-through, no allocate** (`STWTHR`). Always written to memory. If the line is in the cache, that word is updated too, but not made dirty |
| Outside the cached region | Directly from `DBG_BUSMST` to the peripheral bus (AXI4-Lite) |

- With write-through writes, **memory is always up to date**. The I$ never reads an old version of an
  instruction the debugger wrote, and looking at memory from outside (or through the testbench's backdoor)
  gives the same values.
- After a debug write, CPU_TOP **invalidates all lines of the I$** (executing `fence.i` on behalf of the
  debugger). A breakpoint instruction written from OpenOCD leaves no old instruction in the I$.
- The CPU port of the D$ is shared through `CACHE_PORT_ARB`. The CPU has priority, but a debug request
  that has waited 32 cycles always goes through at the next arbitration (no starvation).
- Path: `DBG_DM` → `DBG_CACHE` (`RTL/CPU/CPU_DBG/DBG_CACHE/`) → `CACHE_PORT_ARB` → `DCACHE`. `DBG_CACHE`
  takes the same handshake as `DBG_BUSMST`, and returns an error on timeout if the cache does not answer.
- The parameter `DBG_VIA_CACHE = 0` of `CPU_TOP` / `CPU_DBG` returns to the old configuration with the
  debug master directly on the bus.

---

### 4.8 Coherence of DMA (implemented)

The SoC's DMA master (LiteX's SD card) touches memory through the data cache via the **DMA port** of
CPU_TOP (AXI4-Lite slave, 64 bits, `s_dma_*`) (`RTL/CPU/CPU_DMA/DMA_CACHE.sv`). The entry is the same
second port as debug, and `CACHE_PORT_ARB` inside CPU_TOP combines debug (priority) and DMA into one (DMA
does not starve, thanks to `STARVE_CYCLES`).

| DMA operation | Command to the cache | Meaning |
|---|---|---|
| Write | `CMD_STWTHR` | Write-through, no allocate. Always reaches memory, and if the CPU holds the line it is updated in the cache too (not made dirty) |
| Read | `CMD_LOAD` (doubleword) | Returns the value of a line the CPU made dirty. A miss fills the line |

- A write whose strobes are not a single naturally aligned byte / halfword / word / doubleword is split
  from the low end into naturally aligned pieces sent in order.
- Below `MEM_BASE` the cache passes straight through to the peripheral bus, so DMA to the LiteX BIOS's
  SRAM goes the same way.
- Unlike debug writes, **the instruction cache is not invalidated** (software that wrote code by DMA
  issues `fence.i` itself).

Without this, the SD card would rewrite memory behind the CPU's data cache, and Linux (which assumes DMA
is coherent) would read stale lines. In LiteX it is declared as the CPU's `dma_bus`, and the DMA masters
attach there (`CONFIG_CPU_HAS_DMA_BUS`).

Verified by SIM_SYS's `progs/d01_dma` (driving the bench's DMA model through a mailbox): DMA reading a
dirty line, DMA writing to a clean line in the cache, DMA writing only bytes 2..5 of a dirty line and
being merged (before and after the write-back), reads and writes to a window outside the cached region.

## 5. CPU-side interface

All synchronous, `valid` / `ready` handshakes. Answers are returned **in request order**.

### 5.1 ICACHE

| Signal | Direction | Contents |
|---|---|---|
| `i_req_valid` / `i_req_ready` | in / out | Fetch request |
| `i_req_addr[PADDR_WIDTH-1:0]` | in | Fetch address (on a `FETCH_WIDTH/8`-byte boundary). The index and offset come from here |
| `i_req_paddr[PADDR_WIDTH-1:0]` | in | Physical address. Used for the tag compare and the fill. See 5.6 |
| `i_resp_valid` | out | Answer |
| `i_resp_data[FETCH_WIDTH-1:0]` | out | Fetch data |
| `i_resp_error` | out | Bus error |
| `i_flush_valid` / `i_flush_done` | in / out | Invalidate all lines (`fence.i`) |
| `i_kill` | in | Throw away outstanding requests (on a branch misprediction). The fill completes but no answer is returned. `i_req_ready` does not look at `i_kill` / `i_cancel` (a new request in the cycle a miss is thrown away waits a cycle; the core makes no request in that cycle) |
| `i_cancel` | in | Throws away **only the request in stage 1** (the request in the cycle `i_req_paddr` is passed). Neither the array answer nor the bus access starts. Earlier requests are not affected. The core uses it for fetches refused by PMP (`CPU_CORE_SPEC.md` 6.3) |

### 5.2 DCACHE

| Signal | Direction | Contents |
|---|---|---|
| `d_req_valid` / `d_req_ready` | in / out | Request |
| `d_req_addr[PADDR_WIDTH-1:0]` | in | Address (must be aligned to the access size) |
| `d_req_size[1:0]` | in | 0: 1 byte, 1: 2 bytes, 2: 4 bytes, 3: 8 bytes |
| `d_req_cmd[3:0]` | in | Table of 5.3 |
| `d_req_wdata[XLEN-1:0]` | in | Write / AMO data (right-aligned) |
| `d_req_paddr[PADDR_WIDTH-1:0]` | in | Physical address. Used for the tag compare, fill, write-back and uncached accesses. See 5.6 |
| `d_req_cancel` | in | **Cancels the request in stage 1** (valid in the cycle `d_req_paddr` is passed). Touches none of the arrays, dirty bits, reservation, MSHRs or bus. Has no effect on a request waiting in stage 1 (one that has already received its physical address). The core uses it in MR to take back requests issued early from EX (`CPU_CORE_SPEC.md` 5.4) |
| `d_resp_valid` | out | Answer |
| `d_resp_drop` | out | This answer belongs to a cancelled request. Its order is the same as the other answers, and the data is meaningless. `CACHE_PORT_ARB` only advances its record of owners and passes it to neither side |
| `d_resp_data[XLEN-1:0]` | out | Read data (right-aligned, zero-extended). For SC, 0: success, 1: failure |
| `d_resp_error` | out | Bus error, or an unsupported operation |

Sign extension is done on the CPU side.

### 5.3 Commands

| Value | Name | Contents |
|---|---|---|
| 0 | `LOAD` | Read |
| 1 | `STORE` | Write |
| 2 | `LR` | Load Reserved. Sets a reservation |
| 3 | `SC` | Store Conditional. Returns 0 on success, 1 on failure |
| 4–12 | `AMOSWAP`,`AMOADD`,`AMOXOR`,`AMOAND`,`AMOOR`,`AMOMIN`,`AMOMAX`,`AMOMINU`,`AMOMAXU` | 32/64 bits only (`d_req_size` 2 or 3) |
| 13 | `FENCE` | Waits for outstanding bus accesses to complete |
| 14 | `FLUSH` | Writes back all lines and invalidates |
| 15 | `STWTHR` | Write-through, no allocate (for the debug port, 4.7) |

### 5.4 LR/SC rules

- The unit of reservation is the block (`BLOCK_BYTES`). One reservation register, for one hart.
- The reservation is cleared:
  - when an SC executes (success or failure)
  - by a `STORE` / `AMO` / `STWTHR` to the same block (through this cache port)
  - when the reserved line is replaced or invalidated
  - by `FLUSH` and reset
- An SC succeeds only when its address is in the same block as the reservation and the reservation is
  valid.
- **The range a reservation protects is the same as the coherence range of 6.1**. Writes by external AXI4
  masters are not seen. How the clearing conditions change with SMP: see 6.3.

### 5.5 Uncached region (below `MEM_BASE`)

- `LOAD` / `STORE` go to the peripheral bus (AXI4-Lite) without the arrays.
- **The address goes out at byte granularity** (not rounded to 8 bytes). The data is placed in the 64-bit
  lane, and `WSTRB` tells which lane. Slaves made of 32-bit registers (the built-in PLIC, CLINT) decide
  "which half" by bit 2 of the address. Rounding drops writes to the +4 register, and a read meant for +0
  cannot be told from a read of +4 (the PLIC's claim has side effects). The LiteX BIOS stopped on the board
  because of this (section 20 of `LitexSystem/docs/TIMING.md`). LiteX's AXI-Lite → Wishbone conversion
  drops the low 3 bits, so nothing changes outside.
- `LR` / `SC` / `AMO` are not supported. `d_resp_error` is returned.
- The ICACHE too reads below `MEM_BASE` from the peripheral bus.

### 5.6 Physical address ports (where the MMU plugs in)

The index and the offset in the block come from `*_req_addr`, **the tag from `*_req_paddr`**. So after the
MMU is implemented, either

- **serial**: look up the TLB, then make the request (the same value on both), or
- **parallel (VIPT)**: start indexing with the virtual address and pass the TLB's output as the tag in the
  next cycle

connects without changing the cache.

| Rule | Contents |
|---|---|
| Timing | `*_req_paddr` must be valid in **the cycle after** the request is accepted (the cycle it is in stage 1). From then on the cache holds it, so it may change |
| Connection without an MMU | Give `*_req_addr` delayed by one cycle (`CPU_BFM` and `SIM_CACHE` do this) |
| Cacheability check | The comparison with `MEM_BASE` uses the **physical address** |
| Constraint of parallel VIPT | Index + offset fit within a page = **`SETS × BLOCK ≤ 4096`**. The default 64 × 64B is exactly at the limit |

Verification: section 15 of `SIM_CACHE` goes through a pseudo MMU whose request address and physical
address **have different tags**, and checks that loads / stores / AMO / LR-SC / instruction fetches and
write-backs act on the right physical address (bug injections M19 / M20).

### 5.7 Bus side

`CPU_CACHE` combines the AXI4 of the I$ / D$ into one with `BUS_ARB` and connects it to the AXI4 /
AXI4-Lite master ports of `CPU_TOP`. The debug logic enters the same arbitration.

**Events for the performance counters (2026-10).** `ev_ic_refill` / `ev_dc_refill` (out) are 1 in the
cycle an AXI4 read request with which the I$ / D$ fills a line is accepted (`arvalid & arready`). `CPU_TOP`
passes them to the core, and they become events 7 (I$ miss) and 8 (D$ miss) of the core's performance
counters (`CPU_CORE_SPEC.md` decision 69). D$ line fills include those of DMA.

For the memory waits (`CPU_CORE_SPEC.md` decision 71) it also gives: `ev_dc_miss`, the D$ is handling a miss
(an MSHR in use; `ev_miss` of `DCACHE`); `ev_dc_vic_copy`, the D$ is copying the dirty victim of a miss out
(`c_state` of `DCACHE`; since M5 alongside the fill, 4.3); `ev_fills_1` / `ev_fills_2`,
one / two or more line fills of the I$ and D$ outstanding (from `arvalid` to the last beat). `BUS_ARB` keeps a
read until its last beat, so two fills are never under way together; a second one waits with `arvalid` up.

### 5.8 Mapping for the CPU core (reference)

The CPU core's signal names are to map as follows: `if_req_*` → `i_req_*`, `ls_req_*` → `d_req_*`, and
`ls_resp_sc_fail` is expressed by 0/1 of `d_resp_data`. After the MMU is implemented, `*_addr` gets the
physical address from the TLB instead of the virtual address.

---

## 6. Coherence and memory attributes

This section makes clear what is guaranteed now and what is not, and leaves guidance for putting this
core + cache into an SMP SoC in the future. 6.1 to 6.3 are the present specification, 6.4 design guidance
for the future (not implemented yet).

### 6.1 The coherence range now

**The set of masters that go through this cache port** is exactly the coherence range.

| Master | In range | Path |
|---|---|---|
| CPU core | ○ | `d_req_*` (`CACHE_PORT_ARB` s0) |
| Debugger | ○ | `DBG_CACHE` → `CACHE_PORT_ARB` s1. Writes are `STWTHR` (4.7) |
| External AXI4 masters (DMA, other harts) | **×** | Directly on the memory bus. Not visible to the D$ |

The important thing is that **this is not a weakness peculiar to LR/SC**. Where a master outside the
range has written, an ordinary `LOAD` also returns stale values. The strength of LR/SC matches exactly the
coherence range of the memory system as a whole.

`LR`/`SC`/`AMO` to the uncached region (below `MEM_BASE`) return an access fault (5.5). They never
silently return a wrong answer.

### 6.2 Memory attributes

Today the split is into 2 kinds by one comparison with `MEM_BASE`. In the future it generalizes to a
region table.

| Attribute | Meaning | Now |
|---|---|---|
| `WB` | Write-back + write-allocate | `MEM_BASE` and above |
| `WT` | Write-through + write-allocate. **No dirty lines exist** | Not implemented. The `STWTHR` mechanism can be used |
| `UC` | Uncached. Directly to the peripheral bus (AXI4-Lite) | Below `MEM_BASE` |

| Attribute | `LOAD`/`STORE` | `LR`/`SC`/`AMO` | Cost of invalidation |
|---|---|---|---|
| `WB` | Arrays | Allowed | A write-back is needed if dirty |
| `WT` | Arrays + write-through | Allowed | **Just drop valid** |
| `UC` | Straight to the bus | Not allowed (error) | Not relevant |

The point of `WT` is **cheap invalidation**, nothing else. When told from outside "drop this line", `WB`
needs the dirty write-back path and waiting for completion, while `WT` only drops the valid bit. It pays off
together with the probes of 6.4.

A future region table (proposal):

```
parameter int          NUM_REGION  = 2,
parameter logic [63:0] REGION_BASE [0:NUM_REGION-1],
parameter logic [63:0] REGION_MASK [0:NUM_REGION-1],
parameter logic [1:0]  REGION_ATTR [0:NUM_REGION-1]   // 0:UC 1:WT 2:WB
```

An address matching no region is `UC` (matching the present behavior).

### 6.3 Reservation (LR/SC) rules

A reservation is `res_valid` + the address of the reserved block. **The clearing conditions differ between
non-coherent and coherent**, so both are written down.

| What clears it | Non-coherent (now) | Coherent (future) |
|---|---|---|
| The SC itself (success or failure) | ○ | ○ |
| `STORE`/`AMO`/`STWTHR` of the own hart to the same block | ○ | ○ |
| `FLUSH`, reset | ○ | ○ |
| **Replacement of the reserved block (capacity eviction)** | **○** | **× (does not clear)** |
| **Invalidation / downgrade by a probe** | — | **○** |

Today "clear on eviction" is **needed**. If, after an eviction, something outside rewrote the block and
it was read back with other contents while the reservation stayed alive, the SC would succeed.

When coherent, this rule becomes **harmful instead**. Another hart's write always brings a probe, so there
is no need to use eviction as the trigger; and keeping capacity eviction as a trigger can make an SC fail
forever when ping-ponging with another hart. The RISC-V specification **requires forward progress** of a
constrained LR/SC sequence (at most 16 instructions, no other memory accesses), so that would violate the
specification.

So in the coherent version **the reservation is decoupled from the line being present**. `res_addr` is
held independently and managed regardless of whether the line is present. If the line is not there at the
time of the SC, it is just fetched again (if another hart writes meanwhile, a probe comes).

### 6.4 Guide to SMP

Design guidance for using it in an SoC with several cores in the future. The bus and protocol are the
SoC's decisions and are not fixed here, but the structure that **fits whichever is chosen** is decided
first.

#### 6.4.1 What is needed and what is not

| Item | Needed for SMP | Reason |
|---|---|---|
| D$ coherence (probes) | **Needed** | The premise of Linux SMP |
| LR/SC tied to probes, with forward progress | **Needed** | 6.3, required by the specification |
| Exclusive ownership condition for AMO | **Needed** | 6.4.6 |
| Arbitration of array accesses | **Needed** | 6.4.3. The most expensive to add later |
| I$ coherence | Not needed | RISC-V does not require it. Software does it with `fence.i` + IPI (SBI) |
| TLB shootdown mechanism | Not needed | `sfence.vma` is local. Remote ones are IPIs |
| Ordering control of a store buffer | Not needed for now | RVWMO is met as long as the core waits for each access to complete. The implementation of `FENCE` is reviewed only when that is relaxed for performance |

#### 6.4.2 External port (probe channel)

AXI4 has no channel to carry probes. One of ACE / TileLink-C / CHI will be chosen, but **the form of the
port on the D$ side can be common**.

| Signal | Direction | Contents |
|---|---|---|
| `pb_valid` / `pb_ready` | in / out | Probe request |
| `pb_addr` | in | Physical address (block boundary) |
| `pb_param` | in | Requested transition. 0 = invalidate (toN), 1 = downgrade to shared (toB) |
| `pr_valid` / `pr_ready` | out / in | Probe answer |
| `pr_param` | out | State before the transition, whether data comes with it |
| `pr_data` | out | Write-back data when it was dirty (per beat) |

With `HAS_COHERENCE = 0` they are tied off as `pb_ready = 1`, `pr_valid = 0`, and the logic drops out of
synthesis. The single-hart build is exactly what it is now.

**Mandatory requirement on the protocol**: the bus must be able to advance fill answers without waiting
for probe answers (`pr_*`). TileLink-C (independent B/C/D channels) and ACE both meet it. Without it, the
deadlock avoidance of 6.4.4 cannot be built.

#### 6.4.3 Arbitration of array accesses and duplicated tags

With probes, the arrays get more requesters.

| Array | Requesters now | Added with probes |
|---|---|---|
| Tag read | Pipeline s0, flush walk | + probe hit check |
| Tag write | Fill completion, s1 (setting dirty), flush | + probe valid/dirty update |
| Data read | Pipeline s0, victim write-back | + probe write-back |
| Data write | Fill, s1 store | — |

Tags and data are both 1R1W (7.1), so as they are they conflict. Two measures.

**(1) Duplicate snoop tags**

Put a second `CACHE_TAG_ARRAY` and **write it at the same time with exactly the same signals as the main
one**. Its read port is dedicated to probes. Then the probe hit check never stops the pipeline.

The cost with the defaults is `SETS × WAYS × TAG_BITS = 64 × 4 × 28 ≈ 7 kbit`, fitting in LUTRAM or one
block RAM. valid/dirty are flip-flops (7.1), so they need no duplicate and can be read combinationally as
they are.

**(2) Gather the requesters**

Collect the accesses to the arrays into `*_req_*` signals per requester and **one arbiter**, with this
priority:

| Priority | Requester | Reason |
|---|---|---|
| 1 | Probe | Forward progress. On a conflict, stop the pipeline for a cycle |
| 2 | Fill completion | Stopping it blocks the bus |
| 3 | Flush walk | It keeps its own progress |
| 4 | Pipeline s0/s1 | May be stopped (rides the existing mechanism of waiting with `s1_can_retire`) |

**This (2) is the part that costs the most if postponed**. Even without implementing probes themselves,
with the requesters organized into named signals and one arbiter in place, adding probes is just one more
row. If instead the pipeline keeps grabbing the array ports directly, DCACHE would have to be almost
rewritten.

**Implemented (DCACHE.sv)**: each of the 4 array ports (tag read / write, data read / write) has the form
"`*_req` signals per requester + one arbiter", with the priority table above placed as a comment at the
head of each port. Adding probes is one row in the table and one step in the arbiter. A slot in the
write-back queue is left free under the name `WB_CPU_LIMIT` (now `NUM_WB`, `NUM_WB - 1` in the coherent
version). The duplicated tags only need the `tag_wr_*` bundle wired up as it is.

#### 6.4.4 Avoiding deadlock between probes and misses

The easiest place to get wrong in an SMP cache.

```
the line a probe hits → its fill is in progress in an MSHR
completion of the fill → waits for the bus's answer
the bus                → waits for the probe's answer
```

It goes round in a circle. Keeping the following 3 rules keeps it from closing.

1. **Reserve resources for probe answers in advance.**
   Require `NUM_WB >= 2` and reserve one of them for probes. CPU-side write-backs can use only up to
   `NUM_WB - 1`. Then a probe can always make progress even when the write-back queue is full of CPU
   requests.

2. **A probe to a line in progress is handled after the fill completes.**
   Hold one probe in a register, and if the MSHR of the target line is in progress, hold it pending. The
   hold lasts at most one fill, and by the mandatory requirement of 6.4.2 (the bus advances fill answers
   independently of probe answers) the fill always completes.

3. **Add probe pending to `s1_can_retire`.**
   The pipeline side does not touch a line whose probe is being handled. The same idea as the existing
   `ms_locked` / `s1_wait_fill` suffices.

#### 6.4.5 Forward progress of LR/SC

Besides "decouple the reservation from presence" of 6.3, a **probe lockout** is needed.

- For `LOCKOUT_CYCLES` (about 64 by default) after an `LR` executes, **delay the answer to probes of the
  reserved block**.
- Only delay: **always answer within the limit**. Not answering is not an option (it deadlocks).
- Then a constrained sequence (16 instructions or fewer) can run through at least once, avoiding the
  state where two harts keep taking it from each other and both keep failing their SC.

Without a lockout, when 2 harts compete for the same lock, each one's probe immediately breaks the
other's reservation, and both can fail forever.

#### 6.4.6 The condition for AMO atomicity

Today's `AMO` is a one-cycle read-modify-write in s1 (4.5). One cycle makes it locally atomic, but SMP adds
one condition.

> **An AMO or SC may execute only while the block is held exclusively (M).**

A hit in shared (S) must not execute. `s1_can_retire` gets "M state if `s1_is_amo | s1_is_sc`". On a hit in
S, ownership (upgrade) is requested and it runs again.

Today it is non-coherent, so presence = exclusive ownership, and it holds trivially. **What holds
trivially is what gets broken later, so it is written down as a condition.**

#### 6.4.7 The VIPT constraint

`SETS × BLOCK_BYTES <= 4096` (= page size). The default `64 × 64 = 4096` is exactly at the limit, and
increasing the parameters breaks it silently.

SMP + Sv39 presumes a configuration that looks up the TLB and the cache in parallel (5.6), so this
equation is essentially required. **It is enforced by an assertion as the constraint of 3.5.**

#### 6.4.8 System side (outside the cache)

| Block | What SMP needs |
|---|---|
| `CPU_CLINT` | Support `NUM_HARTS`. `msip` = `0x0000 + 4 × hart`, `mtimecmp` = `0x4000 + 8 × hart`, `mtime` shared by all harts at `0xBFF8` |
| PLIC (implemented in M6) | Designed **per context from the start** (hart × privilege). Adding it later is painful |
| `DBG_DM` | Width of `hartsel`, `hasel`, `haltsum`, halt/resume per hart |
| Boot | Hart 0 boots, the others wait for an IPI in `WFI`. The present `WFI` (waking on `mip & mie`) works as it is |
| `mhartid` | Given by the `HART_ID` parameter of `CPU_CORE` (implemented) |

#### 6.4.9 Order of work

| Stage | Contents | When |
|---|---|---|
| 1 | The VIPT constraint assertion, multi-hart `CPU_CLINT` | **Done** (2026-09-20) |
| 2 | Arbitration of array accesses, room for duplicated tags and a `wb` entry for probes | **Done** (2026-09-20) |
| 3 | Memory attributes as a region table (adding `WT`) | When DMA comes in |
| 4 | Dealing with non-coherent DMA | Zicbom (`cbo.inval`/`clean`/`flush`). Only making the existing `FLUSH` mechanism per line; no bus changes needed, and Linux already supports it |
| 5 | Probe channel and coherence protocol | When an SMP SoC is built. Together with choosing the bus |

---

## 7. Physical implementation estimate (Arty A7-100T)

| Use | Configuration | BRAM |
|---|---|---|
| I$ data | 4 ways × 4KiB | 4 tiles (one RAMB36 per way) |
| I$ tags | 64 × (4 × 29bit) | 1 tile (or LUTRAM) |
| D$ data | 4 ways × 4KiB | 4 tiles |
| D$ tags | 64 × (4 × 30bit) | 1 tile |
| Total | | **about 10 tiles** (of 135) |

Rocket `linux`'s L1 measures 12 tiles (RAMB36×8 + RAMB18×8), so the same scale. Increasing capacity (8
ways 32KiB × 2) would be about 20 tiles, which fits too.

### 7.1 Make sure the arrays are inferred as block RAM

The data array is **a separate array per way**, written with enables decoded from the way (`generate` +
`(* ram_style = "block" *)`).

```systemverilog
for (gw = 0; gw < WAYS; gw++) begin : g_way
    (* ram_style = "block" *) logic [63:0] mem [0:WORDS-1];
    always_ff @(posedge clk)
        for (int b = 0; b < 8; b++)
            if (wr_en && wr_strb[b] && (int'(wr_way) == gw))
                mem[wr_addr][8*b +: 8] <= wr_data[8*b +: 8];
    always_ff @(posedge clk) if (rd_en) rd_w <= mem[rd_addr];
    assign rd_data[gw*64 +: 64] = rd_w;
end
```

Writing a two-dimensional array with the way as a variable index, like `mem[wr_way][wr_addr]`, makes
Vivado not recognize it as RAM, and the whole array becomes flip-flops. The build of 2026-09-20 came to
**138,279 FFs (the Artix-7 100T has 126,800)** this way, and `place_design` stopped with DRC UTLZ-1.

Check that the following line appears in the synthesis log for both the I$ and the D$.

```
INFO: [Synth 8-3971] The signal "..._reg" was recognized as a ... RAM template.
```

`build.tcl` prints the FF count and the block RAM count right after synthesis and stops with an error if
FFs exceed 100k (so as not to go on to a DRC error whose cause is unclear).

A guide for the default configuration: data arrays 8 × RAMB36 (512×64bit = 32Kb per way), tag arrays 4 ×
RAMB18, test RAM 17 tiles, a little under 30 tiles in total / 135.

### 7.2 Measured (2026-09-20, Arty A7-100T, `USE_BFM=0`)

| Item | Used | Total |
|---|---|---|
| Slice Registers | 6,960 | 126,800 (5.5%) |
| Slice LUTs | 7,693 | 63,400 (12.1%) |
| Block RAM tiles | 23 | 135 (17%) |
| WNS / WHS | +4.387ns / +0.014ns (system clock 50MHz) | |

Block RAM breakdown: memory bus RAM 16 + peripheral RAM 1 + D$ data 4×RAMB36 + tags 4×RAMB18. **The I$
disappears in synthesis in this build** (with `USE_BFM=0` nothing fetches instructions, and the debugger
uses only the D$). Adding the CPU core adds 4 RAMB36.

The longest path is D$ tag RAM output → hit decision → `rob_data` (12 levels), with 4.4 ns of margin at
50 MHz.

### 7.3 Reset and cache contents

The array addresses come from the cache's state machines (asynchronous reset), so Vivado reports
`REQP-1839/1840` (RAMB async control check). It points out that array reads and writes may be corrupted
**while reset is asserted**, but the same reset clears all the valid bits of the tags, so corrupted
contents are never used.

`ndmreset` and system reset empty the caches. Debugger writes are write-through and stay in memory
(SIM_OCD's "RAM kept over ndmreset" checks this), but with the CPU core in place, software must `FLUSH`
if it wants dirty lines written back before a reset.

---

## 8. Verification (`SIM/SIM_CACHE`)

| Part | Contents |
|---|---|
| CPU BFM | Issues instruction fetches / loads / stores / AMO / LR / SC / FENCE / FLUSH |
| Reference model | A memory image without caches. Computes the expected values and compares |
| AXI4 slave model | Bursts, delays, random stalls, error responses |
| AXI4-Lite slave model | For the uncached region |

### 8.1 How to run

| Command | Contents |
|---|---|
| `make run` | Runs all 12 sections with the default configuration (Verilator) |
| `make wave` | Runs with `+vcd` and writes `tb_CACHE.vcd` |
| `make iverilog` | Runs the same tests on Icarus Verilog (about 90 seconds) |
| `make perf` | Throughput of consecutive hits / consecutive misses (8.4) |
| `make wave-perf` | The same as 4 VCDs + GTKWave formats (8.4) |
| `make lint` | Verilator lint |
| `./sweep.sh` | Runs 18 parameter configurations in parallel |
| `./bug_inject.sh` | Injects 18 bugs one at a time and checks that they are detected |

`make run PLUSARGS="+from=4 +to=6"` narrows the sections. `+ops=<n>` changes the number of random
operations (default 4000). `+hb=<cycles>` prints progress (Icarus takes time).

### 8.2 Test sections

| # | Contents |
|---|---|
| 1 | Miss / hit / store |
| 2 | Byte lanes (1/2/4/8 bytes × all offsets) |
| 3 | Replacement, write-back of dirty lines, the relation between FLUSH completion and write-back completion |
| 4 | All AMOs (32bit / 64bit, boundary values of signed comparisons) |
| 5 | LR / SC (other address, replacement, intervening store, FLUSH) |
| 6 | FENCE / FLUSH / `fence.i` (`fence.i` during a fill, a pulse input included) |
| 7 | Uncached region (peripheral bus), error answers of AMO/LR/SC |
| 8 | Bus error (DECERR) and recovery after it |
| 9 | MSHRs (consecutive misses to other lines, merging later misses to the same line) |
| 10 | The I$ alone and concurrent I$/D$ accesses |
| 11 | Random comparison with the reference model |
| 12 | Comparison of every word of the final memory image |
| 13 | Write-through (`STWTHR`): miss / hit / dirty line / byte lanes / during a fill |
| 14 | Debug port (`CACHE_PORT_ARB`): miss → hit, sharing with the CPU and coherence |
| 15 | VIPT: index by virtual address, tag compare by physical address (pseudo MMU) |
| 16 | Order with the write-back queue: CPU misses and second-port reads to a line in the queue, `STWTHR` to a line behind the queue, a fill of a line during `STWTHR`. `aw_hold` of the memory model stops AWREADY to make write-backs really wait |
| 17 | CPU and DMA (second port) at the same time, at random: the CPU does loads / stores of every size / AMO / LR/SC / FENCE / FLUSH, the DMA does `STWTHR` and reads. Three times as many lines as ways are placed in 4 sets, causing evictions, fills and write-backs all the time. The CPU uses the even words of each line and the DMA the odd words, so they never conflict on the same word and the reference model stays exact, while always meeting on the same lines. Memory drops ready at random and sometimes stops the write address with `aw_hold`. 20000 operations by default (`+mops=<n>`) |
| 18 | Whether a request waiting in stage 1 remembers a forwarded write: an AMO right after a store held in the middle of a fill (the distance from the fill varied from 0 to 24 cycles), a miss in the same set waiting for an MSHR right after a store hit |
| 19 | Cancel (`d_req_cancel`): cancelling a store hit / miss / AMO / LR / SC / uncached load and store, and checking that nothing happened (a later load reads the old value, no fill, bus access or reservation, no reservation even from an LR that hits, the reservation survives a cancelled SC, a store to a clean line does not set dirty). Then 25 % of the requests of a random test of 3000 operations are cancelled, and finally every word of the memory image is compared |

Requests are fed from a FIFO every cycle. So array reads and writes in the same cycle (forwarding) and
MSHR conflicts really happen.

### 8.3 Results (2026-09-19)

- Default configuration: **PASS** (8817 checks, Verilator)
- The same tests also **PASS** on Icarus Verilog (the random sequence differs, so the content of the
  random tests differs from Verilator)
- Parameter sweep, 18 configurations: **all PASS** (all kept within the constraint `SETS × BLOCK_BYTES <=
  4096` (3.5); to go larger, add ways, not sets)

| # | Configuration | # | Configuration |
|---|---|---|---|
| C1 | Default (like Rocket linux) | C10 | MSHR 1 |
| C2 | D$ direct mapped (1 way) | C11 | MSHR 4 |
| C3 | D$ 2 ways | C12 | MSHR 4 / write-back buffer 1 |
| C4 | D$ 8 ways | C13 | Replacement = random |
| C5 | D$ 16 sets | C14 | I$ direct mapped, 16 sets |
| C6 | D$ 256 sets | C15 | I$ 8 ways |
| C7 | Block 16B | C16 | Small D$ (16 sets × 1 way × 16B) |
| C8 | Block 32B | C17 | Large D$ (256 sets × 8 ways × 128B) |
| C9 | Block 128B | C18 | Different configurations for the I$ and D$ |

- 18 bug injections: **all detected** (`bug_inject.sh`)
- 2026-09-24, section 16 (order with the write-back queue) added: default configuration **PASS** (9381
  checks), 18 sweep configurations **all PASS**. With the RTL before the fix all 4 items of 16 fail. Bug
  injections M23 to M25 added (a fill does not wait for the queue / a fill does not wait for single writes
  / a single write overtakes the queue), **all detected**
- 2026-09-26, sections 17 and 18 added. 17 found 2 real bugs (item 5 of 4.3 above) and 1 testbench bug (it
  wrote the queue of expected values even when full, overwriting old expected values in long sequences
  without SC's `d_drain`). After the fixes, the default configuration PASSes, the 18 sweep configurations
  PASS, and 17 PASSes with 24 seeds × 50000 operations (1.2 million operations). Bug injections M27 (a
  request during the walk) and M28 (forgetting the forwarding) added, all detected

Real bugs found by the sweep (fixed):

| Symptom | Cause |
|---|---|
| Store data lost in the 1-way configuration | Accesses to a way being evicted or filled were not made to wait (`hit_busy`) |
| Same | The tag array had no write forwarding, and a reference in the same cycle missed the dirty bit (`tfwd_*`) |
| Same | A reread whose read port was taken by a write-back was treated as having its data ready |
| Answers corrupted with MSHR 1 | With a 1-bit queue pointer it did not wrap at the end of the array (`ms_next` / `wb_next`) |
| No bus error reported on a store miss | The store completed without waiting for the MSHR |
| The SC decision differs from the reference model (testbench side) | The result of SC varies, so the reference memory was updated at answer time, and later requests' expected values were computed from a stale memory image |
| The 1-way configuration errors on Icarus | `rr_way[WAYS-2:0]` for round robin does not exist with WAYS=1 → branch with `generate` |

### 8.4 Approximate performance (throughput)

`tb_CACHE_perf.svh` of `SIM/SIM_CACHE` produces the waveforms and cycle counts of consecutive hits and
consecutive misses (`make perf` for numbers, `make wave-perf` for waveforms). With random stalls of the
AXI4 slave model disabled and the default configuration (64 sets × 4 ways × 64B, MSHR 2, write-back buffer
2), the measurements are:

| Pattern | Accesses | Steady cycles / access |
|---|---|---|
| Consecutive I$ hits | 32 fetches | **1.00** |
| Consecutive I$ misses (one line at a time) | 8 lines | **13.0** |
| Consecutive D$ load hits | 32 loads | **1.00** |
| Consecutive D$ store hits | 32 stores | **1.00** |
| Consecutive D$ load misses (fill only) | 8 lines | **12.0** |
| Consecutive D$ store misses (fill + write-allocate) | 8 lines | **10.6** (12.0 before 2026-10-10; the fills, one at a time, are the limit) |
| Consecutive D$ misses (dirty eviction = write-back + fill) | 8 lines | **12.7** (22.0 before 2026-10-10) |

- Hits are **one access every cycle** for both the I$ and the D$, loads and stores alike; array reads and
  writes in the same cycle are resolved by forwarding.
- **The answer of a D$ hit comes 2 cycles after the request** (with the request cycle as t, decided in
  stage 1 at t+1, `d_resp_valid` at t+2), only when that hit is the oldest request (the head of the ROB).
  With an unfinished request in front, it goes through the ROB in order, 3 cycles or more. Until
  2026-10-02 it always went through the ROB in 3 cycles, and the core waited 2 cycles in MA at every hit
  (A1 of `RTL/CPU/CPU_CORE/PLAN_LOAD_LATENCY.md`).
- The 12 to 13 cycles of a miss are **a burst of 8 beats** for 64B plus a few cycles of AR and tag update.
  The requested word is returned when it arrives (early restart), so the answer itself comes earlier.
- An eviction of a dirty line costs about the same as a clean miss: the victim is copied into the write-back
  buffer while the fill is on its way (4.3), and the write-back itself goes out on the write channel
  after it. Until 2026-10-10 the copy came first and a dirty eviction took 22 cycles.
- "Steady" is from the first answer in the burst to the last, divided by (number of accesses − 1). The
  total cycles include the pipeline start-up.

The waveforms are written as 4 files, each with a GTKWave format file.

| File | Contents |
|---|---|
| `tb_CACHE_ihit.vcd` / `.gtkw` | Consecutive I$ hits |
| `tb_CACHE_imiss.vcd` / `.gtkw` | Consecutive I$ misses |
| `tb_CACHE_dhit.vcd` / `.gtkw` | Consecutive D$ hits (loads → stores) |
| `tb_CACHE_dmiss.vcd` / `.gtkw` | Consecutive D$ misses (fill → write-allocate → eviction) |

`.gtkw` is generated by `gen_gtkw.py`. Signals are grouped as "CPU side", "Stage 1 (hit decision)",
"Arrays", "MSHR / fill", "Write-back", "ROB", "AXI4", "BUS_ARB" ..., and state machines are shown by name
(`gtkw_filter/*.txt`). The times in `tb_CACHE_*.marks` written by the testbench become markers, so you can
jump to the start of each burst at once.

```
cd SIM/SIM_CACHE
make perf            # numbers only
make wave-perf       # 4 VCDs + .gtkw
make gtkwave-dmiss   # open in GTKWave (ihit / imiss / dhit / dmiss)
```

### 8.5 Checked on the FPGA (2026-09-20, Arty A7-100T board)

`FPGA/ARTY_A7_100T/openocd/cache_test.tcl` run from OpenOCD over JTAG: **CACHE TEST RESULT : PASS**. What
was checked:

| # | Contents |
|---|---|
| 1 | One line: write miss → read miss (allocating the line) → read hit → hit on another word in the same line → write hit |
| 2 | 8 lines in different sets |
| 3 | `load_image` / `verify_image` of 32KiB (every set replaced twice over). Then reading the addresses of 1. and 2. again gives the right values |
| 4 | Memory values remain after `reset halt` (proof that debug writes are write-through) |
| 5 | Accesses to the peripheral bus (uncached) |

Running it repeatedly with the power on also PASSes (`reset halt` empties the caches, but the RAM keeps its
contents).

`No working memory available` / `not enough working area` from `verify_image` is expected. OpenOCD tries
to run a CRC routine on the target, but the debug module has no Program Buffer (`progbufsize=0`), so it
cannot make the hart run code. It falls back to reading all data back over JTAG. That is still so with the
CPU core connected, so do not configure a work area.

After the CPU core is implemented, the coherence between accesses from the core and from the debugger
(4.7) is to be checked on the board too.

---

## 9. Decisions

| # | Item | Decision |
|---|---|---|
| 1 | Default configuration | Equivalent to Rocket `linux` (I$ / D$ both 16KiB = 64 sets × 4 ways × 64B) |
| 2 | Parameterization | Number of sets, number of ways and block size can be set separately for the I$ / D$ |
| 3 | Address width | Follows the CPU's setting (`PADDR_WIDTH`, default 40) |
| 4 | Indexing | PIPT (no alias constraint even after the MMU) |
| 5 | I$ fetch width | 64 bits |
| 6 | D$ MSHRs | 2 by default, parameterized |
| 7 | Uncached region | Below `MEM_BASE` to the peripheral bus (AXI4-Lite). AMO/LR/SC not supported |
| 7b | Address ports | Separated into `*_req_addr` for the index and `*_req_paddr` for the tag. Either serial or parallel VIPT can connect |
| 8 | Replacement | Pseudo-LRU (default). Switches to random by parameter |
| 9 | Writes | Write-back + write-allocate |
| 10 | Debug coherence | The debugger's memory bus accesses go through the D$. Reads allocate; writes are write-through, no allocate; the I$ is invalidated after a write |
| 11 | L2 cache | Not implemented in this phase |
| 12 | Coherence range | Up to the masters that go through this cache port (core + debugger). External AXI4 masters are not seen. LR/SC and ordinary accesses have the same range (6.1) |
| 13 | Preparing for SMP | The probe channel itself and the protocol are not built. **Only the arbitration of array accesses and the VIPT constraint are done first** (6.4.3, 6.4.7), because those are the most expensive to add later |
| 14 | Non-coherent DMA | Dealt with by Zicbom (`cbo.inval`/`clean`/`flush`), not a snoop bus. Only making the existing `FLUSH` mechanism per line; no bus changes and no new Linux support needed (6.4.9) |
| 15 | Reservation and presence | When non-coherent, "clear on eviction" is **needed**; when coherent, it **changes** to "do not clear on eviction" (6.3). For forward progress |
| 16 | Cancelling requests | **Accepted only in stage 1, and the ROB slot stays used and completes silently** (`d_resp_drop`). Nothing writes to the arrays or the bus until the physical address is received, so a cancel is just "do nothing in s1". Returning the slot would put the ROB numbering and the arbiter's owner FIFO out of step, so it is not returned. `d_req_ready` does not look at the cancel (`s1_can_go`; the cancel comes from the core's PMP and is late). Everything but hits (misses, uncached, fence, flush, write-through) acts from the second cycle of stage 1 and does not look at the cancel, and even for hits the cancel stops only the ROB's silent completion, the valid of the fast answer, the reservation and the write enable of the data array (section 28 of `LitexSystem/docs/TIMING.md`) |

---

## 10. Changes from Rev-1 (design plan)

| Item | Rev-1 plan | Rev-2 (implementation) | Reason |
|---|---|---|---|
| Indexing | VIPT (constraint `SETS × BLOCK_BYTES <= 4096`) | **PIPT** | The MMU is in the next phase, and the caches receive physical addresses. PIPT has no alias constraint and allows any number of sets |
| Module split | `CPU_ICACHE` / `CPU_DCACHE` / `CPU_CACHE_ARRAY` / `CPU_CACHE_MSHR` / `CPU_CACHE_BUS` | `ICACHE` / `DCACHE` / `CACHE_TAG_ARRAY` / `CACHE_DATA_ARRAY` / `CPU_CACHE` | The MSHRs and the bus control are tightly coupled with the D$'s state machine, and splitting them makes it harder to read. The arrays differ in role between tags and data, so they were split |
| Default D$ MSHRs | 4 | **2** | Enough for a Rocket-sized design. Can be increased by parameter |
| I$ MSHRs | 2 | 1 (one miss at a time) | Instruction fetch is sequential, and with early answers the practical difference is small |
| AXI4 IDs | A separate ID per MSHR for the D$ | Separate IDs for fill and write-back (3 / 4), 2 for the I$ | Getting ordering from the same ID is simpler, and identifying the MSHR from internal state suffices |
| Default replacement | RANDOM | **Pseudo-LRU** (random by parameter) | The one with the better hit rate became the default |
| Flush operations | Whole + per line | Whole only (`FENCE` / `FLUSH` / `fence.i`) | Per line is to be added later together with Zicbom |
| Debug through the cache | This phase (on a hit, update the line and make it dirty) | This phase (writes are **write-through**) | Left dirty, memory would be stale and I$ fills and values seen from outside would differ. Write-through keeps coherence while still showing the effect of hits / misses |
| Location | `RTL/CPU/CPU_CACHE/` | Same (what was once placed in `RTL/CPU/CPU_CACHE/` was merged) | Because it is instantiated under `CPU_TOP` |
