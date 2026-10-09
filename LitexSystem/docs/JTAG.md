# JTAG / cJTAG debugging (LiteX SoC)

[日本語](JTAG_J.md)

The debug module of mmRISC-2 (`RTL/CPU/CPU_DBG`, RISC-V Debug Spec 1.0) is brought out on PMOD JA of
the Arty, and OpenOCD handles halt / step / registers / memory through it. The pinout, switches and
OpenOCD configuration are **the same** as `FPGA/ARTY_A7_100T` (`RTL/TOP/TOP.sv`, `TOP.xdc`), which was
used to bring up the debug logic, so the same cable and the same `.cfg` work as they are.

## 1. Pins and switches

| PMOD JA | FPGA pin | Signal | FPGA side |
|---|---|---|---|
| JA1 | G13 | TCK / TCKC | Pull-up. A clock on a general-purpose pin |
| JA2 | B11 | TDI | Pull-up |
| JA3 | A11 | TDO | Pull-up. Driven only while shifting |
| JA4 | D12 | TMS / TMSC | Keeper (in cJTAG the host and the target drive it in turn) |
| JA7 | D13 | nTRST | Pull-up. Reset of the TAP |
| JA8 | B18 | nSRST | Pull-up. Reset of the **CPU** (below) |
| JA5 / JA11 | — | GND | |

| Switch | Down | Up |
|---|---|---|
| SW3 (A10) | 4-wire JTAG | 2-wire cJTAG (OScan1) |
| SW2 (C10) | No authentication | Authentication (key `0xbeefcafe`) |

The status is shown on the RGB LEDs (LiteX's LED chaser uses LD4 to LD7, and the device tree and
`fw_jump.bin` assume the location of its CSR, so it is not moved). They are too bright, so they are lit
at a 1/16 duty.

| LED | Color | Meaning |
|---|---|---|
| LD0 | Red / green | Hart halted / running |
| LD1 | Blue | dmactive (the debugger has enabled the DM) |
| LD2 | Green | cJTAG online (when SW3 is up) |

The implementation is `add_jtag` in `cpu/mmrisc/core.py`. Passing `--cpu-jtag none` to `build_soc.sh`
returns to tie-offs. The constraints (`build/gateware/digilent_arty.xdc` and `.tcl`) are the same as
`TOP.xdc` / `TOP_impl.xdc`:

- `create_clock` of 100 ns on TCK and TMSC, asynchronous to sys and to each other (`set_clock_groups`)
- Neither is a dedicated clock pin, so `CLOCK_DEDICATED_ROUTE FALSE` (on the output net of the buffer
  after synthesis; `pre_placement_commands`)
- nTRST / nSRST / SW2 / SW3 / TDI / TMS / TDO are false paths

## 2. Reset

| What | What it resets |
|---|---|
| The board's RESET button, LiteX's system reset | The whole SoC (the debug module too) |
| nSRST (JA8), `ndmreset`, `hartreset` | **Only the CPU** (core, caches, buses inside the CPU). The debug module and LiteX's peripherals keep running |

OpenOCD's `reset` uses nSRST (`reset_config trst_and_srst`). The CPU starts the BIOS again from the head
of the ROM. With `reset halt` it stops before the first instruction of the BIOS.

## 3. OpenOCD

The wiring is in section 3 of `FPGA/ARTY_A7_100T/README.md` (channel A of the FT2232H). The FT2232H is
passed through over USB to the Ubuntu VM.

```bash
cd LitexSystem
# 4-wire JTAG (SW3 down)
openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg  -f scripts/jtag_check.tcl
# 2-wire cJTAG (SW3 up, through an external 4-wire → 2-wire adapter)
openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_cjtag.cfg -f scripts/jtag_check.tcl
```

`scripts/jtag_check.tcl` is a check that can be run whatever the CPU is doing (at the BIOS prompt or at
the Linux shell). It halts and prints pc, dcsr, mstatus and satp, checks misa and dcsr.xdebugver, reads
the SoC's identification string (CSR space 0x1200_2000) over the system bus, writes a0 and restores it,
steps 3 instructions and resumes. It does not write memory. At the end it prints `JTAG CHECK RESULT :
PASS`. OpenOCD stays running, so you can go on with `telnet localhost 4444`.

```
halt
reg                                   ; all registers
reg pc
mdw 0x12002000 8                      ; identification string (32 bits per character)
mdd 0x80000000 4                      ; memory (read through the D$, so the CPU's values are seen)
step
resume
reset halt                            ; reset only the CPU and stop before the BIOS
resume
```

### Things to know

- **Memory addresses are physical**. The configuration has `riscv set_enable_virt2phys off`, so `mdw` on
  a Linux kernel virtual address reads nothing. Read physical addresses (memory starts at 0x8000_0000),
  or `riscv set_enable_virt2phys on` while halted (OpenOCD walks the page tables).
- **Breakpoints**. `bp <addr> 4` writes an EBREAK (a software breakpoint). The write goes into the D$ and
  `CPU_TOP` invalidates the I$, so it takes effect as it is. `bp <addr> 4 hw` (gdb's `hbreak`) uses a
  trigger (Sdtrig, 4 of them) and does not rewrite the instruction (it can be put in ROM, or where you
  do not want to write). OpenOCD prints `Found 4 triggers` when it connects.
- **Watchpoints** (`wp <addr> <len> r|w|a`, gdb's `watch` / `rwatch` / `awatch`). They stop before the
  access, and a store has not been written yet (on resume OpenOCD removes the trigger, steps one
  instruction and puts it back). Triggers match **exact addresses only**, so they stop only on accesses
  to the first address of the range (OpenOCD warns `Could not set a trigger that will match a whole
  address range`). For an 8-byte variable, an `ld` / `sd` of its first address stops, an `sb` to a byte
  in the middle does not. There are 4 triggers, counted together with hardware breakpoints.
- **There is no Program Buffer** (`progbufsize=0`). On connecting and before the first step, two lines
  of `Unable to insert program into progbuf` are printed. That is OpenOCD trying the Program Buffer while
  looking for CSRs this core does not have (vlenb, mtopi), and does no harm.
- Interrupts are not taken while stepping (`dcsr.stepie=0`). Halting in Linux's idle (WFI) stops at the
  instruction after the WFI. `mtime` keeps running while halted, so timer interrupts come in a bunch
  right after resume.
- With authentication (SW2 up), the configuration runs `riscv authdata_write 0xbeefcafe` after `init`
  (next section).

### Checking authentication

Raise SW2 **before** starting OpenOCD (OpenOCD resets the DM when it connects, and that clears the
authentication). The key can be replaced with the environment variable `AUTH_KEY`.

| Step | Expected result |
|---|---|
| 1. SW2 up, `AUTH_KEY=0x12345678 openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg` (wrong key) | `Debugger is not authenticated to target Debug Module. (dmstatus=0x3)`, `examination failed`. `halt` in telnet only says `Target not examined yet`, nothing happens, and LD0 stays green (running) |
| 2. Then `riscv authdata_write 0xbeefcafe` in telnet | `authdata_write resulted in successful authentication`, `Examined RISC-V core`. From then on `halt` / `reg` / `mdw` work |
| 3. SW2 up, `openocd ... -f scripts/jtag_check.tcl` without `AUTH_KEY` | The configuration writes the right key, `JTAG CHECK RESULT : PASS` |
| 4. SW2 down, `AUTH_KEY=none` (no key written) | No authentication needed, so `examine` passes as it is |

While not authenticated, the DM reads 0 for everything except authenticated / version of `dmstatus` and
`authdata`, and performs no halt request, ndmreset or system bus access at all (`CPU_DBG_SPEC.md` 4.7).
dmstatus=0x3 is version=3 (Debug Spec 1.0) with authenticated=0.

## 4. Verification

| Environment | Contents |
|---|---|
| `SIM/SIM_CORE` `t23_debug` | The core alone. The testbench's debugger drives the core's `dbg_*` directly. Mutations M211–M231 |
| `SIM/SIM_OCD` | Co-simulation of `RTL/TOP/TOP.sv` (the real core as the hart) with OpenOCD. Halt, GPR/FPR/CSR, memory (memory bus and peripheral bus), load_image, step, software breakpoints, hardware breakpoints, watchpoints (store and load), reset halt. Also with authentication |
| `SIM/SIM_DBG` | The debug logic itself (TAP, DTM, DM, cJTAG, SBA), 3026 checks |
| Board | `scripts/jtag_check.tcl` (above). PASS in all 4 combinations of JTAG / cJTAG × without / with authentication, and rejection of a wrong key checked (2026-10-01) |
| Board | Hardware breakpoints and write / read watchpoints on a running Linux kernel with gdb (section 5 below, 2026-10-06) |

## 5. Putting triggers in the kernel with gdb (2026-10-06, board)

Triggers (Sdtrig, 4 of them, `CPU_CORE_SPEC.md` decision 67) match virtual addresses, so they can be put
on functions and variables of a running Linux kernel as they are. The kernel has no KASLR, so the
addresses are fixed. Give gdb the `vmlinux` of the same build as the `Image` on the SD card (with
symbols, without DWARF).

```bash
cd LitexSystem
openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg        # terminal 1
riscv64-unknown-linux-gnu-gdb <kernel build>/vmlinux             # terminal 2
```

```
(gdb) set pagination off
(gdb) target extended-remote localhost:3333
(gdb) monitor riscv set_enable_virt2phys on      ; to read memory at kernel virtual addresses
(gdb) hbreak __riscv_sys_newuname                ; stops when uname is typed on the board
(gdb) continue
(gdb) x/4i $pc                                   ; the instructions are not rewritten
(gdb) delete
(gdb) watch *(long *)&jiffies_64                 ; stops at every timer interrupt (10 ms)
(gdb) continue
(gdb) delete
(gdb) rwatch *(long *)&jiffies_64
(gdb) continue
(gdb) delete
(gdb) continue
```

Results:

- `hbreak`: `uname -a` stops at `__riscv_sys_newuname+12` (gdb places it after the prologue), and
  `x/4i` shows the original instruction (`jal __do_sys_newuname`). The instruction was not rewritten
- `watch`: inside `do_timer`, `jiffies_64` goes up by 1 at each stop (4294956787 → 788 → 789 → 790). The
  trigger stops before the store, and OpenOCD steps that store before reporting to gdb, so the pc shown
  is the one after the store (`do_timer+…930`)
- `rwatch`: stops in functions that read `jiffies_64`: `calc_global_load`, `update_process_times`,
  `calc_global_load_tick`, `do_timer`

Things to know:

- `vmlinux` has no DWARF, so give variables a type (`*(long *)&jiffies_64`). There are no line numbers
  or backtraces
- Triggers match exactly only, so a watchpoint stops on accesses to the first address of the variable
  (the 8-byte `jiffies_64` is read and written 8 bytes at a time, so that is fine)
- `hbreak` / `watch` / `rwatch` together: up to 4
- OpenOCD counts the triggers the first time it uses one, not at start-up
- Typing `interrupt` while stopped leaves an interrupt request behind, and the next stop (even at a
  watchpoint) is reported as `SIGINT`. The place it stopped is right
- Staying stopped for more than 20 seconds can make Linux warn of an RCU stall after resuming

