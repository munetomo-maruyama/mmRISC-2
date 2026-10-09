# mmRISC-2 provisional debug logic specification

[日本語](CPU_DBG_SPEC_J.md)

- Version: Rev-2 (2026-09-17), with the implementation and verification results (section 10)
  - 2026-09-19: `RTL/CPU_DBG/` moved to `RTL/CPU/CPU_DBG/` (because it is instantiated under CPU_TOP)
  - 2026-09-19: debug accesses to the memory bus now go through the L1 data cache (`DBG_CACHE`,
    `CPU_CACHE_SPEC.md` 4.7). The peripheral bus stays connected directly to `DBG_BUSMST`
  - 2026-10-06: a haltreq raised during reset is held by the DM until the hart halts, and the hart is
    shown as unavailable until then (4.2). The clearing of the L2 cache after reset delayed the first
    instruction, and OpenOCD's `reset halt` missed the halt
- Specification followed: **The RISC-V Debug Specification Version 1.0, Revised 2025-02-21: Ratified**
  ("References" of the top `README.md`). Section numbers below are those of that specification.
- Scope: `RTL/CPU/CPU_DBG/` (debug logic), `RTL/CPU/CPU_TOP/` (integration), `RTL/TOP/` (FPGA top)
- The decisions are collected in section 9.

---

## 1. Purpose and scope

The CPU itself (pipeline, MMU, caches, CLINT/PLIC) is not implemented yet. In this phase, **debug logic
that, seen from JTAG, behaves as if an RV64GC hart and its resources existed** is built, and access from
OpenOCD over JTAG is confirmed in simulation and on an FPGA (Arty A7-100T).

| Item | This phase |
|---|---|
| JTAG DTM (6.1) | **Full implementation** (CDC included; used as it is after the CPU is implemented) |
| Debug Module registers (3.14) | **Full implementation** |
| System Bus Access (3.10) | **Full implementation** (accesses the real memory bus / peripheral bus) |
| Abstract Command: Access Register (3.7.1.1) | **Full implementation**: GPR/FPR/CSR of CPU_CORE (`CPU_CORE_SPEC.md` 11). In the BFM configuration, a stand-in hart |
| Abstract Command: Access Memory (3.7.1.3) | **Full implementation** (uses the same bus master as SBA) |
| Halt / resume / step / reset of the hart | **Full implementation**: debug mode of CPU_CORE. In the BFM configuration, a stand-in hart |
| Core debug CSRs (dcsr/dpc/dscratch, 4.9) | **Full implementation**: CORE_CSR (visible only to the debugger). In the BFM configuration, a stand-in hart |
| Program Buffer (3.8) | Not implemented (progbufsize=0) |
| Trigger Module / Sdtrig (chapter 5) | **Implemented in CPU_CORE** (4 of type 2, `CPU_CORE_SPEC.md` decision 67). Nothing needed on the DM side (trigger CSRs are read and written with Access Register). Not in the stand-in hart of the BFM configuration |
| Quick Access (3.7.1.2) | Not implemented (cmderr=2) |
| cJTAG (IEEE 1149.7 OScan1) | **Full implementation** (switchable with JTAG, section 7 and 3.6) |
| Authentication (authdata, 3.12) | **Full implementation** (enable / disable and the key are inputs from outside CPU_TOP, 4.7) |

The hart is the CPU itself (`CPU_CORE`). The signals between the DM and the hart (`hart_*`, 4.8) are
ports of `CPU_DBG`, and `CPU_TOP` connects them to the core. The stand-in hart `DBG_HART_STUB` is used
only in the configuration with a BFM in place of the core (`USE_BFM=1`, `HART_STUB=1`). The DTM, the DM
registers, SBA and Access Memory are used as they were built in the stand-in hart days.

---

## 2. Block structure

```
                       CPU_TOP
  ┌──────────────────────────────────────────────────────────────────────┐
  │  CPU_DBG                                                             │
  │  ┌──────────────┐ DMI req/resp  ┌─────────────────────────────────┐ │
  │  │ DBG_DTM      │  (CDC:       │ DBG_DM                          │ │
  │  │  JTAG TAP    │  4-phase     │  DM registers / Abstract Command│ │
  │  │  IR/DR       │  handshake)  │  SBA control / hart (hart_*)    │ │
  │  │ [TCK domain] │◀────────────▶│ [system clock domain]           │ │
  │  └──────────────┘              └──────┬───────────────┬──────────┘ │
  │                                        │ halt/resume   │ bus req    │
  │                                ┌───────▼───────┐ ┌─────▼────────┐  │
  │                                │ CPU_CORE      │ │ DBG_BUSMST   │  │
  │                                │ (DBG_HART_STUB│ │ SBA/AccessMem│  │
  │                                │ in the BFM    │ │ bus master   │  │
  │                                │ configuration)│ └─────┬────────┘  │
  │                                └───────────────┘       │           │
  │  CPU_BFM (for simulation, existing) ──┐                │           │
  │                                        ▼                ▼           │
  │                                   ┌──────────────────────────┐      │
  │                                   │ BUS_ARB (2 masters → bus)│      │
  │                                   │ + address decode         │      │
  │                                   └───────┬──────────┬───────┘      │
  └───────────────────────────────────────────┼──────────┼──────────────┘
                                   memory bus AXI4   peripheral bus AXI4-Lite
```

| Module | Location | Contents |
|---|---|---|
| `CPU_DBG` | `RTL/CPU/CPU_DBG/CPU_DBG/` | Wrapper of the below |
| `DBG_CJTAG` | `RTL/CPU/CPU_DBG/DBG_CJTAG/` | cJTAG (OScan1) receiver. Passes through in JTAG mode |
| `DBG_DTM` | `RTL/CPU/CPU_DBG/DBG_DTM/` | JTAG TAP, IDCODE/dtmcs/dmi/BYPASS, CDC sending side |
| `DBG_CDC` | `RTL/CPU/CPU_DBG/DBG_CDC/` | Synchronizers, 4-phase handshake, reset synchronizers |
| `DBG_DM` | `RTL/CPU/CPU_DBG/DBG_DM/` | DM registers, Abstract Command, SBA control |
| `DBG_BUSMST` | `RTL/CPU/CPU_DBG/DBG_BUSMST/` | Bus master for SBA / Access Memory (AXI4/AXI4-Lite) |
| `DBG_HART_STUB` | `RTL/CPU/CPU_DBG/DBG_HART_STUB/` | Stand-in hart. Used only in the BFM configuration (`HART_STUB=1`) |
| `DBG_CACHE` | `RTL/CPU/CPU_DBG/DBG_CACHE/` | Routes memory bus accesses through the data cache (`DBG_VIA_CACHE=1`, default) |
| `BUS_ARB` | `RTL/BUS/BUS_ARB/` | Arbitration between the BFM and the debug bus master, routing to the memory bus / peripheral bus |


---

## 3. JTAG DTM (6.1)

### 3.1 TAP

- The 16-state TAP controller of IEEE 1149.1. Reset by both TRST (asynchronous, active low) and
  Test-Logic-Reset (TMS=1 × 5).
- **IR length 5 bits**, IR = `0x01` (IDCODE) at TAP reset. Capture-IR loads `0b00001`.
- TDO updates on the falling edge of TCK. Outside Shift-IR / Shift-DR, `jtag_tdo_en=0` (the pin is
  Hi-Z on the FPGA).

| IR | Register | Length | Contents |
|---|---|---|---|
| `0x00` | BYPASS | 1 | |
| `0x01` | IDCODE | 32 | `0x26d6d001` (3.2) |
| `0x10` | dtmcs | 32 | 3.3 |
| `0x11` | dmi | 41 (abits=7) | 3.4 |
| Others | BYPASS | 1 | Unimplemented instructions are BYPASS (6.1.2) |

### 3.2 IDCODE (decided)

| Field | Proposed value | Note |
|---|---|---|
| Version [31:28] | `0x2` | mmRISC-2 |
| PartNumber [27:12] | `0x6d6d` ("mm") | Same as mmRISC-1 |
| ManufId [11:1] | `0x000` | No JEDEC ID (non-commercial). Same as mmRISC-1 |
| [0] | `1` | |
| **IDCODE** | **`0x26d6d001`** | mmRISC-1 is `0x16d6d001` |

### 3.3 dtmcs

| Field | Value |
|---|---|
| version | 1 (0.13/1.0) |
| abits | 7 |
| idle | `1` (see 3.5) |
| dmistat | Alias of op |
| dmireset (W1) | Clears the sticky errors of op (2/3) and errinfo. Does not affect a DMI transaction in progress |
| dtmhardreset (W1) | Initializes the sticky op / errinfo and cancels requests not yet sent to the DM. A request already sent to the DM returns busy until it completes (3.5) |
| errinfo | Implemented. reset=4 (unknown). busy is not an error, so it stays 4. 3 on an error from the DM (op=2) |

### 3.4 dmi

- `{address[6:0], data[31:0], op[1:0]}`
- Update-DR: with op=1 (read) / 2 (write), no sticky error and the previous transaction complete, a DMI
  request starts. If the previous transaction is not complete, op becomes **3 (busy, sticky)** and the
  request is dropped.
- Capture-DR: if complete, the result goes into data with op=0 (success). If not, op=3 (busy, sticky).
- op=0 (nop) does nothing. op=3 (reserved) is treated as nop.

### 3.5 CDC (TCK ⇔ system clock) [key requirement]

**The frequency and phase relationship between TCK and the system clock is arbitrary** (TCK may be
faster, slower, or stopped).

Method: **bundled data + 4-phase handshake (req/ack)**

```
 TCK domain (DTM)                          system clock domain (DM)
 ─────────────────                         ────────────────────────
 req_data  (addr, wdata, op) ──── held ───▶ (not synchronized: stable during req)
 req  ──▶ [2FF sync] ──▶ req_s             executed once on the rising edge of req_s
 ack_s ◀── [2FF sync] ◀── ack              done → resp_data fixed → ack=1
 resp_data (rdata, err) ◀── held ───        (stable during ack)
 req=0 (after seeing ack_s=1)               ack=0 after seeing req_s=0
 next req only after seeing ack_s=0
```

- Data (address, write data, read data) are **not synchronized**; the handshake signals guarantee the
  period they are stable (bundled data). Only the 1-bit control lines req/ack go through 2-stage FF
  synchronizers. No multi-bit value is synchronized directly, so corruption by skew between bits cannot
  happen in principle.
- Each domain **advances only on the edges of its own clock**. Even with TCK stopped, the DM side
  completes its work and holds ack, and the completion is detected when TCK resumes. Conversely, when the
  system clock is slow, the DTM returns op=busy and the debugger adds Run-Test/Idle and retries (as 6.1.5
  prescribes).
- **Interruption by dtmhardreset / TRST / Test-Logic-Reset**: the DTM side drops req and **issues no new
  req until it sees ack_s=0**. The DM side completes the operation in progress before dropping ack (bus
  transactions are not broken in the middle).
- **Asynchronous resets**: the TCK domain's reset is "asserted asynchronously, released synchronously
  to TCK", the DM domain's "asserted asynchronously, released synchronously to the system clock". Even
  if only one domain is reset, the handshake rules above keep the other from hanging.
- The synchronizer FFs get `(* ASYNC_REG = "TRUE" *)`, and the Vivado constraints make TCK and the system
  clock `set_clock_groups -asynchronous`.
- `idle` hint: when the system clock is fast enough, one Run-Test/Idle cycle between Update-DR and
  Capture-DR is enough for ack to reach the TCK side, so it is `1`. It is only a hint; correctness is
  guaranteed by the busy answer and the debugger's retries (OpenOCD increases idle automatically when it
  gets busy).

### 3.6 cJTAG (IEEE 1149.7 OScan1)

**Policy**: TCK is not made with a gate. The TAP is clocked directly by the physical pin TCKC, and a clock
enable lets only one of the 3 phases of OScan1 advance it. The system clock is not used at all (to meet
the requirement of an arbitrary clock ratio).

| Item | Specification |
|---|---|
| Mode select | `cjtag_en` input (0: JTAG, 1: cJTAG). Two-stage synchronized into the TCKC domain; a change resets the cJTAG state and the TAP |
| Shared pins | TCK ⇔ TCKC, TMS ⇔ TMSC (bidirectional). In cJTAG TDI is unused and TDO is Hi-Z |
| Escape detection | By the number r of TMSC rising edges while TCKC is high: r≥4 reset (offline + TAP reset), r=3 select (wait for activation), r=2 deselect (offline), r≤1 ignored |
| Implementation of the escape count | A **Gray-code counter** clocked by TMSC rising edges (+1 only while TCKC is high). Snapshots are taken on TCKC rising / falling edges and the difference is evaluated on the next TCKC rising edge. The value changes one bit at a time, so even if TMSC and TCKC edges coincide in normal operation and go metastable, the error stays within ±1 and is not mistaken for an escape (r≥2) |
| Activation | Right after a select escape, OAC, EC and CP are received LSB first on 12 TCKC rising edges. `0x08C` (OAC=1100, EC=1000, CP=0000) enters OScan1; anything else goes offline |
| OScan1 | 3 phases per TAP cycle: phase 0 TMSC=nTDI, phase 1 TMSC=TMS (both taken on the TCKC rising edge), in phase 2 the target outputs TDO, and the TAP advances one step on that TCKC rising edge |
| TMSC output | Driven only while TCKC is low in phase 2, released on the TCKC rising edge (the pin's keeper holds the value after release) |
| Offline | The TAP is held in Test-Logic-Reset |
| OpenOCD | Compatible with `ftdi oscan1_mode on` (the `cjtag_reset_online_activate` sequence of riscv-openocd 928f2b374: reset escape 8 edges → 3 pulses → select escape 6 edges → OAC/EC/CP) |

---

## 4. Debug Module (chapter 3, 3.14)

### 4.1 Basic parameters

| Item | Value | Reason |
|---|---|---|
| dmstatus.version | 3 (1.0) | |
| Number of harts | **1** (only hartsel=0 exists) | [proposal] |
| HARTSELLEN | 1 bit implemented (hartsel=1 is nonexistent) | For OpenOCD's detection of the number of harts |
| hasel / hart array mask | Not implemented (hasel fixed at 0) | |
| datacount | **4** | Access Memory on RV64 needs arg0 (64 bits) + arg1 (64 bits) = data0..3 (table 2) |
| progbufsize / impebreak | 0 / 0 | No Program Buffer |
| abstractauto | Implemented (autoexecdata[3:0]) | Speeds up OpenOCD's consecutive memory accesses |
| confstrptr | Not implemented (confstrptrvalid=0, reads 0) | |
| nextdm | 0 | |
| hartinfo | 0 (not implemented) | Not needed without a Program Buffer |
| haltsum0 | Implemented | |
| authdata / authenticated | Implemented (4.7) | |
| hasresethaltreq | 1 (setresethaltreq/clrresethaltreq implemented) | For OpenOCD's `reset halt` |
| hartreset | Implemented (same scope as ndmreset: core, caches, bus side) | There is one hart, and resetting only the core while leaving the caches and bus side would strand requests in flight |
| ndmreset | Implemented (output to the system as a port, 6.2) | |
| keepalive / ackunavail / stickyunavail | Not implemented (0) | |
| relaxedpriv | Fixed at 0 | |

### 4.2 How reset works (3.2, 3.14.2)

- **The DM is reset only by power-on reset and dmactive**. A system reset (ndmreset or an external reset
  button) does not reset the DM (the specification: "there should be no mechanism to reset the DM other
  than dmactive"). So CPU_TOP gets **a power-on reset input dedicated to the debug logic** (6.2).
- While ndmreset=1, CPU_TOP raises its `ndmreset` output, and the FPGA top resets the peripherals, the
  memory and the CPU itself (in the future). `dmstatus.ndmresetpending` is implemented.
- The hart (CPU_CORE; a stand-in hart in the BFM configuration) is reset by ndmreset, hartreset and the
  system reset, and havereset is set (cleared by ackhavereset). If resethaltreq is set, after reset is
  released it becomes halted (cause=5) before the first instruction.
- **Halt right out of reset** (2026-10-06). The specification says that if haltreq is set during reset,
  the hart halts right as it comes out of reset, and OpenOCD's `reset halt` (riscv-openocd
  0.12.0+dev) relies on that and lowers haltreq right after releasing reset and reading dmstatus once.
  This core halts when an instruction reaches ID, so it cannot halt until the first instruction arrives.
  The L2 cache (`CPU_L2_SPEC.md`) clears its tags after reset (1,024 cycles), so the first instruction
  is delayed by that much, and OpenOCD saw the hart running, halted it to write dcsr, and then let it go
  again. So the DM:
  - holds a haltreq raised during reset (`hart_in_reset`, or `hart_not_ready` = the L2 clearing)
    (`reset_halt_hold`) and keeps the haltreq to the hart up until the hart halts. dmactive=0 drops it
  - shows the hart as **unavailable** (not running) while holding and during the L2 clearing. havereset
    is set only by a real reset (`hart_in_reset`)

  To the debugger it looks like "halted when it comes out of reset". dcsr.cause is 3 (haltreq).

### 4.3 Abstract Command

| cmdtype | Support |
|---|---|
| 0 Access Register | Supported (4.4) |
| 1 Quick Access | cmderr=2 |
| 2 Access Memory | Supported (4.5) |
| Others | cmderr=2 |

Common rules: writing command/abstractcs/abstractauto/data while busy → cmderr=1 (only when cmderr=0).
While cmderr≠0 no new command starts.

### 4.4 Access Register

With CPU_CORE as the hart, what can be read and written is the GPRs (`0x1000`–`0x101f`), the FPRs
(`0x1020`–`0x103f`) and every CSR in `CORE_CSR` (`0x0000`–`0x0fff`, including `dcsr`/`dpc`/`dscratch0/1`).
A CSR that does not exist, a write to a read-only CSR and a regno out of range are all cmderr=3. A 32-bit
write keeps the upper half. While the hart runs, the DM gives cmderr=4 (the core also answers with an
error). The table below is for the stand-in hart.

| Condition | Result |
|---|---|
| The hart is running | cmderr=4 (halt/resume) |
| postexec=1 | cmderr=2 |
| aarsize other than 2 (32 bits) / 3 (64 bits) | cmderr=2 |
| aarsize wider than the register (64 bits to a 32-bit CSR, etc.) | **Not an error** (upper bits read 0). OpenOCD reads dcsr and others at XLEN width during examine without knowing the register width, and on cmderr=2 it disables abstract access to all CSRs |
| A regno that does not exist | **cmderr=3 (exception)** (required by 3.7.1.1) |
| transfer=0 | Does nothing (only postincrement takes effect) |
| aarpostincrement | Supported |

Registers of the stand-in hart (readable and writable, they only hold values):

| Number | Register | Note |
|---|---|---|
| `0x1000` | x0 | Reads 0, writes ignored |
| `0x1001`–`0x101f` | x1–x31 | 64 bits |
| `0x1020`–`0x103f` | f0–f31 | 64 bits (to have F/D set in misa) |
| `0x0001`–`0x0003` | fflags / frm / fcsr | The aliasing of fcsr is implemented |
| `0x0300` | mstatus | WARL: holds only the writable bits such as SD/FS/MPP |
| `0x0301` | misa | `0x800000000014112d` (RV64 IMAFDCSU) |
| `0x0302`,`0x0303` | medeleg / mideleg | |
| `0x0304`,`0x0344` | mie / mip | |
| `0x0305` | mtvec | |
| `0x0306` | mcounteren | |
| `0x0340`–`0x0343` | mscratch / mepc / mcause / mtval | |
| `0x0100`,`0x0105`,`0x0140`–`0x0143`,`0x0180` | sstatus (alias of mstatus) / stvec / sscratch / sepc / scause / stval / satp | |
| `0x0F11`–`0x0F15` | mvendorid / marchid / mimpl / mhartid / mconfigptr | Read-only. 0 / 0x6d6d3032 / 0x00000001 / 0 / 0 |
| `0x07B0` | dcsr | debugver=4, prv (WARL: 0/1/3), step, ebreakm/s/u, cause (RO) |
| `0x07B1` | dpc | |
| `0x07B2`,`0x07B3` | dscratch0 / dscratch1 | |
| `0x07A0`–`0x07A5` | tselect and the like | Not in the stand-in hart: cmderr=3 (OpenOCD concludes there are 0 triggers). The real core has them |
| Anything else | | cmderr=3 |

### 4.5 Access Memory

- Only aamvirtual=0 (1 is cmderr=2). aamsize 0–3 (8/16/32/64 bits), 4 is cmderr=2. aampostincrement
  supported.
- **Works even while the hart is running** (the real CPU is meant to use the same bus path).
- Bus errors (SLVERR/DECERR), timeouts, misaligned addresses and addresses over 40 bits → cmderr=5
  (bus).

### 4.6 System Bus Access (3.10, 3.14.22–30)

| Item | Value |
|---|---|
| sbversion | 1 |
| sbasize | **40** (the CPU's physical address width) → sbaddress0/1 implemented |
| sbaccess8/16/32/64 | 1 / 1 / 1 / 1 (128 is 0) |
| sbdata0/1 | Implemented (for 64-bit accesses) |
| sbreadonaddr / sbreadondata / sbautoincrement | Implemented |
| sbbusyerror / sbbusy | Implemented |
| sberror | 1: timeout / bus reset, 2: DECERR, 7: SLVERR, 4: unsupported size, 3: address not aligned to the access size |
| Timeout | A parameter (default 2^20 system clock cycles) |

### 4.7 Authentication (3.12)

| Input | Contents |
|---|---|
| `dbg_auth_en` | 1: authentication required, 0: not required (authenticated=1). Two-stage synchronized to the system clock |
| `dbg_auth_key[31:0]` | The key. authenticated=1 when the value written to authdata matches |

- While not authenticated: all DM registers read 0 and ignore writes. The exceptions are dmstatus's
  authenticated/authbusy/version, dmcontrol.dmactive and authdata (the required exceptions of 3.12).
  Nothing acts outside the DM: no halt request, ndmreset, SBA and the like.
- dmactive=0 returns authenticated to 0 (re-authentication needed). authbusy is always 0.
- authdata reads 0.
- From OpenOCD, authenticate with `riscv authdata_write 0xbeefcafe` (same as mmRISC-1).

### 4.8 Signals to the hart (`hart_*`)

Ports of `CPU_DBG`. With `HART_STUB=0`, `CPU_TOP` connects them to the `dbg_*` of `CPU_CORE`. All
synchronous to the system clock.

| Signal | Direction | Contents |
|---|---|---|
| `hart_haltreq` | DM→hart | dmcontrol.haltreq (level) |
| `hart_resumereq` | DM→hart | resumereq (1-cycle pulse) |
| `hart_resethaltreq` | DM→hart | Halt when reset is released (level; the hart looks at it once right after release) |
| `hart_halted` / `hart_running` | hart→DM | State |
| `hart_resumed` | hart→DM | Pulse in the cycle it resumed (resumeack) |
| `hart_reg_req` | DM→hart | Register access request (pulse), with `hart_reg_wr` / `regno[15:0]` / `size64` / `wdata[63:0]` |
| `hart_reg_ack` | hart→DM | Answer (pulse). `hart_reg_rdata[63:0]`, `hart_reg_err` (→ cmderr=3) |

The hart's reset is `rst_bus_n` of `CPU_TOP` (system reset, ndmreset, hartreset), and the DM sees its
synchronized version as `hart_in_reset`. `hart_not_ready` (an input of `CPU_DBG`) means reset is released
but the hart cannot run yet (the L2 clearing, `ready` of `CPU_L2` is 0), and the DM shows the hart as
unavailable meanwhile (4.2).

---

## 5. Bus master and routing for SBA / Access Memory

### 5.1 Bus selection by address [proposal]

A parameter of CPU_TOP, on the premise that the CPU itself uses the same rule.

| Address (40 bits) | Goes to |
|---|---|
| `0x00_8000_0000` and above | Memory bus (AXI4) |
| `0x00_0000_0000` – `0x00_7FFF_FFFF` | Peripheral bus (AXI4-Lite) |

This matches LiteX's layout (main_ram=`0x8000_0000`, ROM/SRAM/CSR=`0x1000_0000` to `0x1200_0000`). The
CLINT (`0x0200_0000`) / PLIC (`0x0C00_0000`) are to be inside the CPU, but not being implemented in this
phase they go out to the peripheral bus.

### 5.2 Representation on AXI (the paths verified so far are used as they are)

| Bus | 8/16/32-bit access | 64-bit access |
|---|---|---|
| Memory bus AXI4 | **Narrow single transfers with AxSIZE=0/1/2** (WSTRB generated from the address) | AxSIZE=3 |
| Peripheral bus AXI4-Lite | Lanes chosen by WSTRB; reads extract the lane | WSTRB=0xFF |

- AXI ID **1** is used, to be told apart from the BFM (ID=0).
- The lane position within the 64-bit data is given by the low 3 bits of the address (little-endian).

### 5.3 BUS_ARB

- Masters: CPU_BFM (for simulation), DBG_BUSMST. Later the CPU itself joins.
- Fixed priority (debug first) with **per-transaction locking** (no switching from accepting AW/AR until
  B / the last R completes). Read and write are arbitrated independently on each of the memory bus and
  the peripheral bus.

---

## 6. Integration into CPU_TOP

### 6.1 Instances

`CPU_DBG` and `BUS_ARB` are added in `CPU_TOP`. The existing `CPU_BFM` stays as one master of BUS_ARB
(it does nothing on the FPGA).

### 6.2 Added ports [proposal]

| Port | Direction | Contents |
|---|---|---|
| `rst_dbg_n` | in | **Power-on reset for the debug logic** (4.2). Separate from the system reset `rst_n` |
| `ndmreset` | out | System reset request from the DM. The FPGA top uses it to reset the peripherals and memory |
| `jtag_tck` | in | TCK (JTAG) / TCKC (cJTAG) |
| `jtag_tms_i` | in | TMS (JTAG) / TMSC input (cJTAG). The existing `jtag_tms`, renamed |
| `jtag_tms_o` / `jtag_tms_oe` | out | TMSC output and enable (cJTAG) |
| `jtag_tdi` | in | TDI |
| `jtag_tdo` / `jtag_tdo_oe` | out | TDO and enable |
| `jtag_trst_n` | in | TRST |
| `cjtag_en` | in | 0: JTAG, 1: cJTAG |
| `cjtag_online` | out | cJTAG is in OScan1 operation (for an LED) |
| `dbg_auth_en` | in | Authentication enable / disable (4.7) |
| `dbg_auth_key[31:0]` | in | Authentication key (4.7) |
| `dbg_halted` / `dbg_running` / `dbg_dmactive` | out | For status display (LEDs, provisional) |

The CPU's identification values (IDCODE, mvendorid, marchid, mimpl, misa, mhartid) are parameters of
CPU_TOP, with this specification's decided values as defaults.

---

## 7. FPGA top (`RTL/TOP/TOP.sv`, Arty A7-100T)

### 7.1 Structure

```
 clk100 (E3) ─▶ MMCM ─▶ sys_clk (50 MHz by default, a parameter)
 cpu_reset_n (C2) ─┐
 MMCM locked ──────┼─▶ POR generation ─▶ rst_dbg_n (for the DM: POR only)
 ndmreset ─────────┘                  └─▶ rst_n    (system: POR | button | ndmreset)

 CPU_TOP ─ AXI4 ─▶ AXI4_ADDR_NARROW ─▶ AXI4_RAM   64KiB  @ 0x8000_0000 (BRAM)
         ─ AXI-L ▶ AXIL_ADDR_NARROW ─▶ AXIL_RAM    4KiB  @ 0x1200_0000 (BRAM / distributed RAM)
 JTAG pins (PMOD) ─▶ CPU_TOP
 LED ◀─ dbg_halted / dbg_running / dmactive / heartbeat
```

- Upper bits `[39:32]≠0` get DECERR from the existing ADDR_NARROW (sberror=2 can be checked from
  OpenOCD).
- Outside the RAM (within 32-bit addresses) also returns DECERR (to check accesses to unused areas).
- The memories are new synthesizable modules `RTL/BUS/AXI4_RAM` and `RTL/BUS/AXIL_RAM` (the simulation
  models are not synthesizable).

### 7.2 Pin assignment (decided)

An FT2232H (Dual RS232) connected directly to PMOD JA (JTAG), or an external cJTAG adapter connected to
PMOD JA (cJTAG).

| Signal (JTAG / cJTAG) | PMOD JA | FPGA pin | Note |
|---|---|---|---|
| TCK / TCKC | JA1 | G13 | Clock input, pull-up |
| TDI / – | JA2 | B11 | Pull-up |
| TDO / – | JA3 | A11 | Tri-state output, pull-up |
| TMS / TMSC | JA4 | D12 | Bidirectional, **no pull-up** (KEEPER) |
| GND | JA5 | – | |
| VCC 3.3V | JA6 | – | |
| nTRST | JA7 | D13 | Pull-up |
| nSRST | JA8 | B18 | Pull-up, system reset input |

| Board part | Use |
|---|---|
| SW3 (A10) | Down: JTAG, up: cJTAG |
| SW2 (C10) | Down: authentication off, up: authentication on (key `0xbeefcafe`) |
| RESET button (C2) | System reset (does not reset the DM) |
| LD4 (H5) | Hart halted |
| LD5 (J5) | Hart running |
| LD6 (T9) | dmactive |
| LD7 (T10) | cJTAG online (in JTAG mode, a heartbeat of sys_clk) |

- TCK/TCKC and TMSC are used as clocks from general-purpose I/O pins, so they get `CLOCK_DEDICATED_ROUTE
  FALSE`, are defined with `create_clock`, and are `set_clock_groups -asynchronous` with the system clock
  and each other.
- The build files (XDC, Vivado TCL, Windows batch) are in `FPGA/ARTY_A7_100T/`.

### 7.3 Build

As with LitexRocket, the TCL and XDC for Vivado are generated on the Linux side and synthesized with
Vivado 2025.1 on the Windows side.

---

## 8. Verification plan

| Directory | Contents |
|---|---|
| `SIM/SIM_CPU` | Existing tests (regression after adding BUS_ARB) |
| `SIM/SIM_DBG` | Functional verification of the debug logic (new) |

Items checked by `SIM/SIM_DBG`:

1. **TAP/IR/DR with a JTAG BFM**: IDCODE, BYPASS, unimplemented IR, TLR/TRST
2. **dtmcs / dmi**: op success / busy / sticky, dmireset, dtmhardreset, errinfo
3. **CDC robustness**: sweep the ratio of TCK period to system clock period widely (e.g. TCK/sys = 1/50 to
   50), randomize the phase, stop TCK for long periods, TCK with jitter. In all cases the DMI read and
   write results are correct, busy is returned correctly, and retries succeed
4. **Robustness to interruption**: dtmhardreset / TRST / TLR during a DMI operation, dmactive=0 during an
   operation, reset of only one domain
5. **DM registers**: dmactive, each bit of dmstatus, hartsel existence,
   haltreq/resumereq/step/hartreset/ndmreset/resethaltreq/ackhavereset
6. **Abstract Command**: Access Register (all GPR/FPR/CSR, cmderr=3 for a nonexistent number, cmderr=4
   when running, cmderr=2 for a bad aarsize), postincrement, abstractauto, cmderr=1 for writes while busy
7. **SBA / Access Memory**: 8/16/32/64 bits × memory bus / peripheral bus, autoincrement,
   readonaddr/readondata, DECERR / timeout, sbbusyerror, concurrent access with the BFM (BUS_ARB)
8. **Authentication**: reads of 0, ignored writes and the exception registers while not authenticated,
   a wrong key, the right key, relocking by dmactive=0
9. **cJTAG**: the same activation sequence as OpenOCD, the main items of 1 to 7 over OScan1, escapes
   during operation (reset / deselect) and reactivation, the worst timing with TMSC changing at the same
   time as the TCKC falling edge, switching modes JTAG ⇔ cJTAG
10. **Co-simulation with OpenOCD**: with Verilator + OpenOCD's `remote_bitbang` driver, **connect the real
    OpenOCD to the RTL simulation** and run `init`→`halt`→`reg`→`mdw/mww`→`resume`→`reset halt` (checking
    compatibility with OpenOCD before going to the FPGA)
11. **Deliberate bug injection** to confirm the verification is effective (as before)

FPGA check (Arty A7-100T): the same operations as 8 from OpenOCD, plus writing and checking memory with
`load_image`/`verify_image`.

---

## 9. Decisions

| # | Item | Decision |
|---|---|---|
| 1 | IDCODE / mvendorid / marchid / mimpl / mhartid | `0x26d6d001` / 0 / `0x6d6d3032` ("mm02") / `0x00000001` / 0 |
| 2 | JTAG adapter | FT2232H (Dual RS232) connected to PMOD JA |
| 3 | cJTAG | Implemented together with JTAG, switched by SW3, the TCK/TMS of PMOD JA shared as TCKC/TMSC, conversion by an external adapter |
| 4 | Authentication | Implemented. Enable / disable and the key are external inputs of CPU_TOP. On the FPGA switched by SW2, key `0xbeefcafe` |
| 5 | misa | `0x800000000014112d` (RV64 IMAFDC + S/U) |
| 6 | Bus selection rule | `0x8000_0000` and above to the memory bus |
| 7 | System clock of the FPGA | 50 MHz from the MMCM (changeable by parameter) |
| 8 | Directories | `RTL/CPU/CPU_DBG`, the FPGA build in `FPGA/ARTY_A7_100T` |

---

## 10. Implementation results (added in Rev-2)

### 10.1 Files

| Kind | Files |
|---|---|
| Debug logic | `RTL/CPU/CPU_DBG/{DBG_CDC,DBG_CJTAG,DBG_DTM,DBG_DM,DBG_HART_STUB,DBG_BUSMST,CPU_DBG}/*.sv` |
| Buses | `RTL/BUS/BUS_ARB/BUS_ARB.sv`, `RTL/BUS/AXI4_RAM/AXI4_RAM.sv`, `RTL/BUS/AXIL_RAM/AXIL_RAM.sv` |
| CPU | `RTL/CPU/CPU_TOP/CPU_TOP.sv` (ports added, parameter `USE_BFM`) |
| FPGA top | `RTL/TOP/TOP.sv` (`SIM=1` bypasses the MMCM) |
| FPGA build | `FPGA/ARTY_A7_100T/{TOP.xdc,build.tcl,build.bat,README.md,openocd/*.cfg}` |
| Verification | `SIM/SIM_DBG` (functional), `SIM/SIM_OCD` (with OpenOCD), `SIM/SIM_CPU` (regression) |

### 10.2 Decisions and changes made during implementation

- **CDC (DBG_CDC)**:
  - The handshake state is reset only by the debug POR. TRST/TLR/dtmhardreset cancel only requests not
    yet sent, and requests already sent are completed. So, after an interruption, an old answer can never
    be mistaken for the answer to a new request.
  - Capture-DR takes in directly an answer completed on that TCK edge. This satisfies idle=1.
- **Reset of the TCK domain**: TCK is not running at power-on, so the FFs of the reset synchronizer get an
  initial value of 0 (the FPGA's INIT), so that they start in the reset state even without a reset edge.
  The cJTAG escape counter also gets an initial value (only differences of the count are used, so the
  value itself is arbitrary).
- **In-flight tracking in the DM**: register accesses to the hart and requests to the bus master are
  tracked with in-flight flags that survive dmactive=0. If the hart or the bus is reset, the request
  completes with an error (cmderr=4/5, sberror=1).
- **Timeout of DBG_BUSMST**: at the timeout it returns sberror=1 (cmderr=5). The AXI transaction itself is
  waited out in the background (drain), and new requests arriving meanwhile return an error at once.
- **Reset of the hart stub**: a synchronous reset of `rst_n | ndmreset | hartreset` through a 2-FF
  synchronizer, so that the DM observes the state on the same clock.
- **Fix of the ADDR_NARROW bridges**:
  - The old implementation held W until the AW handshake completed, which deadlocked with a slave that
    waits for both AW and W (the new AXIL_RAM). That breaks the AXI rule "a master must not wait for
    READY before asserting VALID".
  - After the fix, W is also transferred while an AWVALID whose address is decoded (in range) is out. A
    state W_PASS_AW was added for the case where W completes first.
  - The property that W does not leak to the slave on DECERR is kept. The SIM_CPU regression PASSes.
- **Module name TOP**: Verilator uses `TOP` as its internal root scope name, so `TOP` cannot be linted or
  simulated directly as the top module. Instantiating it under a testbench works.
- **Working around limits of Verilator 5.020 / Icarus 12**:
  - Inlining functions containing loops gave an internal error, so the Gray-code conversion became a
    macro.
  - Icarus needs a cast for the ternary operator on enums, so the TAP states are localparams.
  - The testbenches use neither break nor array literals.

### 10.3 Verification results

| Verification | Result |
|---|---|
| `SIM/SIM_DBG` Verilator (`make`) | PASS 3010 checks (about 40 seconds) |
| `SIM/SIM_DBG` Icarus (`make iverilog`) | PASS 3030 checks (about 1 minute) |
| `SIM/SIM_DBG` bug injection (`make bug`) | All 15 detected |
| `SIM/SIM_OCD` with OpenOCD (`make`, `make auth`) | PASS / PASS |
| `SIM/SIM_CPU` regression (after the bridge fix) | Verilator PASS 47351 / Icarus PASS 45815 |

The 14 items of **SIM_DBG**:
1. TAP / IR / IDCODE / BYPASS / TRST
2. dtmcs
3. DM registers
4. DMI busy / sticky / dmireset
5. CDC sweep:
   - TCK period / system clock period = 0.02, 0.05, 0.13, 0.333, 0.5, 0.97, 1.0, 1.03, 2.9, 7.3, 20, 50.
     Some with ±40 % jitter.
   - 1/400 and 1000.
   - Random phase, TCK stopped.
6. Interrupting requests with dtmhardreset / TRST / TLR; the DM survives a system reset
7. Run control: halt / resume / step / ndmreset / resethaltreq / hartreset
8. Access Register: GPR/FPR/CSR, WARL, cmderr 2/3/4, postincrement, autoexec
9. Access Memory: both buses × 8/16/32/64 bits, block writes, the various errors
10. SBA: both buses × 8/16/32/64 bits, autoincrement, readonaddr/readondata
11. Bus errors:
    - DECERR. A write to an upper address does not turn into a RAM write.
    - Misaligned addresses, sbaccess, sbbusyerror, cmderr=1 while busy.
    - Timeout and recovery after it, interruption by ndmreset.
12. Concurrent access by CPU_BFM and the debug bus master
13. Authentication
14. cJTAG:
    - Activation, OScan1 accesses, ratio sweep, the worst TMSC edge.
    - Deselect / reset escapes, wrong activation code, return to JTAG, no TMSC contention.

Bugs **bug injection** confirmed to be detected:
- CDC:
  - raising req without waiting for ack to fall
  - not reporting a pending request as busy
  - taking in the answer one handshake late
- DTM:
  - ignoring busy at Capture-DR
  - dmireset not clearing the sticky op
- DM:
  - no autoexec on reading data
  - bypassing authentication
  - wrong size of sbautoincrement
- BUSMST:
  - WSTRB not shifted to the lane
  - no timeout
- HART: dpc does not advance on step
- cJTAG:
  - driving TMSC while TCKC is high
  - ignoring the deselect escape
- Bridge: the old W holding (deadlock with AXIL_RAM)
- BUS_ARB: releasing the write grant early

Note: the bridge bug "the W of a DECERR write leaks into the RAM" cannot be observed in this system. The
RAM here does not accept W unless it has accepted the corresponding AW.

**With OpenOCD** (riscv-openocd 0.12.0+dev-03026-g928f2b374, remote_bitbang):
- examine recognized XLEN=64 and misa=0x800000000014112d.
- All of the following worked as expected:
  - halt, reg (a0, s11, ft0, misa, marchid, pc)
  - mww/mwd/mwh/mwb and read_memory (both buses), a block transfer of 256 words, load_image / verify_image
    of 4 KiB
  - step (pc+4), resume, reset halt (pc=0x80000000, RAM kept)
- With authentication, after the unauthenticated error, re-examine succeeded with `riscv authdata_write
  0xbeefcafe`.
- With progbufsize=0, OpenOCD logs "Unable to insert program into progbuf" a few times, but falls back to
  Abstract Command / SBA and works.

### 10.4 Mechanisms for simulation only

- `sim_stall` of `AXI4_RAM` / `AXIL_RAM` (`ifndef SYNTHESIS`): the testbench stops AWREADY/ARREADY to
  create busy and timeouts.
  - In Verilator a net that was forced and released can keep its value after the release, so this method
    is used instead of force.
- `USE_BFM` of `CPU_TOP`: 1 in simulation (CPU_BFM is used for the concurrent access tests), 0 on the
  FPGA.

### 10.5 FPGA results (Arty A7-100T, 2026-09-17)

**Vivado 2025.1**
- Timing: WNS +8.382 ns, WHS +0.038 ns, all constraints met.
- CRITICAL WARNING: 0.
- Only the expected warnings remain (`FPGA/ARTY_A7_100T/README.md`).

**OpenOCD configuration**
- riscv-openocd 0.12.0+dev-03026-g928f2b374, with an FT2232H.
- `riscv set_enable_virt2phys off` (until the MMU is implemented).

| Item | JTAG | cJTAG |
|---|---|---|
| IDCODE detection, examine (XLEN=64, misa) | OK | OK |
| Reads and writes on the peripheral bus / memory bus (mww/mwd/mdw/mdd) | OK | OK |
| halt / resume / step (pc+4) | OK | OK |
| reg reads and writes (a0, misa, pc) | OK | OK |
| reset halt (pc=0x80000000, RAM contents kept) | OK | OK |
| Going online / activating again when OpenOCD restarts | − | OK |
| Authentication (SW2 up) | OK | OK |

Authentication in detail:
- Unauthenticated at start-up (dmstatus=0x3).
- `authdata_write 0xbeefcafe` in the cfg authenticates, and re-examine succeeds.
- Writing a wrong key returns to unauthenticated; writing the right key again re-authenticates and access
  returns.
- Started with a cfg that writes no key, `mdd` is refused with "Target not examined yet". Writing the
  right key gives access.

`Unable to insert program into progbuf` from OpenOCD is harmless (because progbufsize=0):
- Twice during examine.
- When listing triggers at the first resume / step (stand-in hart only; tselect gives cmderr=3).

### 10.6 FPGA check procedure

See `FPGA/ARTY_A7_100T/README.md` (`build.bat` on the Windows side → Hardware Manager → OpenOCD).
