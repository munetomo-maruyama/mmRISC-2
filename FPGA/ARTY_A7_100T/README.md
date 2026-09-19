# mmRISC-2 debug logic bring-up on Arty A7-100T

Design: `RTL/TOP/TOP.sv`. It contains CPU_TOP (debug logic + pseudo hart + L1 caches), a 64KiB RAM on the memory bus at 0x8000_0000 and a 4KiB RAM on the peripheral bus at 0x1200_0000.

Since the L1 caches were added, **memory bus accesses of the debugger go through the data cache** (`RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md` 4.7): a read allocates the line (the next read of that line hits), a write goes through to memory without allocating, and the instruction cache is invalidated after a debug write. Accesses to the peripheral bus still go straight to the bus master.

## 1. Build (Windows, Vivado 2025.1)

In this directory (via the shared folder):

```
build.bat
```

This runs `vivado -mode batch -source build.tcl` and writes to `output/`:

| File | Contents |
|---|---|
| `TOP.bit` | bitstream (Hardware Manager, volatile) |
| `TOP.bin` | SPI flash image (Configuration Memory Device `s25fl128sxxxxxx0-spi-x1_x2_x4`) |
| `timing_summary.rpt`, `cdc.rpt` (with details), `clock_interaction.rpt`, `utilization.rpt`, `methodology.rpt` | reports |

Things to check after the build:
- `timing_summary.rpt`: no setup/hold violations on `clk100` and its generated clock.
- `clock_interaction.rpt` / `cdc.rpt`: `jtag_tck`, `jtag_tmsc` and the system clock are "Asynchronous Groups". Crossings go only through the `ASYNC_REG` 2-FF synchronizers (req/ack, reset, mode and auth inputs) or through handshake-stable bundled data (DMI address/data). CDC warnings on the bundled data are expected.

### Expected warnings (reviewed, acceptable)

| Report / message | Reason |
|---|---|
| PLCK-12, Place 30-574 (TCK IBUF -> BUFG not dedicated) | PMOD JA1 (G13) is not a clock-capable pin; allowed by `CLOCK_DEDICATED_ROUTE FALSE` (TOP_impl.xdc). TCK is at most a few MHz. |
| CKLD-2 (JA_TMS drives clock pins without BUFG) | TMSC clocks the 5-bit Gray escape counter directly (by design, no BUFG needed). |
| TIMING-9 and Critical CDC rows (jtag_tmsc, jtag_tck, clk_out) | Intentional crossings: Gray counter snapshots, TMS/TDI pin data, bundled DMI data held by the req/ack handshake, and asynchronous reset assertion. Check `cdc.rpt` (-details) that the unsafe endpoints are only of these kinds. |
| LUTAR-1 (LUT drives async reset) | Reset combinations (POR & button & nSRST, POR & nTRST, rst_n & ~ndmreset) in front of the reset synchronizers; assertion is asynchronous by design. |
| SYNTH-6 / SYNTH-15 (RAM output register / byte write enable) | RAM timing has large margin at 50MHz. |

## 2. Board settings

| Part | Setting |
|---|---|
| SW3 | down: 4-wire JTAG, up: 2-wire cJTAG |
| SW2 | down: authentication off, up: on (key `0xbeefcafe`) |
| RESET button | system reset (the debug module keeps its state) |
| LD4 / LD5 / LD6 | hart halted / running / dmactive |
| LD7 | cJTAG online (SW3 up), heartbeat (SW3 down) |

## 3. Wiring (PMOD JA)

| FT2232H (channel A) | PMOD JA | Signal |
|---|---|---|
| ADBUS0 | JA1 (G13) | TCK / TCKC (FPGA pull-up) |
| ADBUS1 | JA2 (B11) | TDI (FPGA pull-up) |
| ADBUS2 | JA3 (A11) | TDO (FPGA pull-up) |
| ADBUS3 | JA4 (D12) | TMS / TMSC (no pull-up, bus keeper) |
| ACBUS0 | JA7 (D13) | nTRST (FPGA pull-up) |
| ACBUS1 | JA8 (B18) | nSRST (FPGA pull-up) |
| GND | JA5 | GND |

For cJTAG, connect JA1/JA4/GND through the external 4-wire to 2-wire adapter.

## 4. OpenOCD

```
openocd -f openocd/ft2232h_jtag.cfg      # SW3 down
openocd -f openocd/ft2232h_cjtag.cfg     # SW3 up (riscv-openocd, ftdi oscan1_mode)
```

The configs issue `riscv authdata_write 0xbeefcafe` after `init`; this has no effect when SW2 is down. Example session (`telnet localhost 4444`):

```
halt
reg a0 0x0123456789abcdef
reg
mww 0x80000000 0xdeadbeef
mdw 0x80000000
mwd 0x12000000 0x1122334455667788
mdd 0x12000000
load_image test.bin 0x80001000 bin
verify_image test.bin 0x80001000 bin
step
resume
reset halt
```

Expected behaviour:
- `halt` / `resume` / `step` / `reset halt` switch LD4/LD5.
- `step` advances pc by 4.
- `reset halt` sets pc to 0x80000000.
- RAM contents survive `reset`.
- Access to 0x1_0000_0000 and above, or outside the two RAMs, returns a bus error.

The same OpenOCD sequence was run against the RTL in simulation (`SIM/SIM_OCD`).

## 5. Memory access through the data cache

The D$ is 16KiB (64 sets x 4 ways x 64 byte), so a 64 byte line covers 16 words
of `mdw`. The sequence below walks through miss, hit, write hit, write miss and
a replacement; every step must return the value that was written.

```
halt
mww 0x80001000 0x11111111      ; write miss  : straight to memory, no line allocated
mdw 0x80001000                 ; read miss   : fills the line -> 0x11111111
mdw 0x80001000                 ; read hit    : same line
mdw 0x80001004                 ; read hit    : next word of the same line
mww 0x80001004 0x22222222      ; write hit   : cache and memory are updated
mdw 0x80001004                 ; read hit    -> 0x22222222
mdw 0x80001040                 ; read miss   : next line
mdw 0x80009000                 ; read miss   : far away line
mdw 0x80001000 16              ; one miss and 15 hits (one line)
mdw 0x80001000 256             ; 16 lines : 16 misses, 240 hits
```

Replacement and write-back of the lines the debugger filled:

```
mww 0x80000000 0xA5A5A5A5
mdw 0x80000000                 ; fills the line
load_image test.bin 0x80002000 bin      ; 32KiB of data = every set is refilled twice
verify_image test.bin 0x80002000 bin    ; read back through the cache
mdw 0x80000000                 ; the line was replaced: miss again -> 0xA5A5A5A5
```

Writes are write-through, so the value in memory is always the value the
debugger wrote, no matter whether the line was in the cache or not. Whether a
particular access was a hit or a miss cannot be seen from OpenOCD itself (only
the timing differs, and JTAG dominates that); the hit / miss behaviour of the
same sequences is checked in simulation against the tag array
(`SIM/SIM_DBG` section 15 and `SIM/SIM_CACHE` sections 13 and 14).
