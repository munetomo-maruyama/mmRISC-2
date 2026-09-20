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
| REQP-1839 / REQP-1840 (RAMB36 / RAMB18 async control check) | The address pins of the cache arrays are driven by cache state machines that have an asynchronous reset, so a read or a write can be corrupted while the reset is being asserted. Harmless here: the same reset clears every valid bit of the tag array, so the caches start empty and nothing that was in the arrays is ever used again. |
| SYNTH-6 / SYNTH-15 (RAM output register / byte write enable) | RAM timing has large margin at 50MHz. |

### Utilization (2026-09-20 build, USE_BFM=0)

| Resource | Used | Available |
|---|---|---|
| Slice registers | 6960 | 126800 (5.5%) |
| Slice LUTs | 7693 | 63400 (12.1%) |
| Block RAM tiles | 23 | 135 (17%) |
| WNS / WHS | +4.387 ns / +0.014 ns (50MHz system clock) | |

The 23 block RAM tiles are 16 for the 64KiB memory bus RAM, 1 for the 4KiB
peripheral RAM, 4 RAMB36 for the data cache arrays (one per way, 512 x 64
bit) and 4 RAMB18 for the tag arrays. The instruction cache is optimized
away in this build: with `USE_BFM=0` nothing fetches instructions, and the
debugger uses the data cache only. It comes back (4 more RAMB36) when the
CPU core is added.

### Cache arrays must end up in block RAM

`build.tcl` prints the number of flip-flops and block RAM primitives right
after synthesis and stops if the design needs more than 100k flip-flops. The
cache data arrays are 2 x 4 x 512 x 64 bit: in block RAM they are 8 RAMB36,
in flip-flops they do not fit into the device (the 2026-09-20 build failed
that way with `[DRC UTLZ-1] FDRE over-utilized`, 138279 of 126800). Check that
the log contains `[Synth 8-3971] ... recognized as ... RAM template` for the
data and tag arrays of both caches.

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
load_image test.bin 0x80001000 bin      ; any binary file, see chapter 5
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

Replacement of the lines the debugger filled needs a block bigger than the
16KiB cache. There is no binary file in the repository: `openocd/cache_test.tcl`
generates one (`cache_test_image.bin`, 32KiB) and runs the whole sequence with
automatic checks, so the steps above do not have to be typed by hand:

```
openocd -f openocd/ft2232h_jtag.cfg  -f openocd/cache_test.tcl
openocd -f openocd/ft2232h_cjtag.cfg -f openocd/cache_test.tcl
```

It checks a single line (write miss, read miss, read hit, write hit), eight
lines in different sets, `load_image` / `verify_image` of 32KiB (which refills
every set twice), that the first lines still read back correctly afterwards,
that the values survive `reset halt` (debug writes are write through, so they
are in memory and not in a dirty line), and an access to the peripheral bus.
It prints `CACHE TEST RESULT : PASS` at the end and leaves OpenOCD running.

It starts with `reset halt` (which empties the caches) and writes every value
it checks, so it can be run again without power cycling the board. Note that
a reset does not clear the RAM: the values of an earlier run are still there.

Two messages during `verify_image` are expected as long as there is no CPU
core:

```
Error: No working memory available. Specify -work-area-phys to target.
Warn : not enough working area available(requested 1112)
```

OpenOCD would like to run a CRC routine on the target to compare the image;
that needs a hart that can execute code (this design has the pseudo hart with
`progbufsize=0`). It falls back to reading the data back over JTAG, which is
exactly the access path we want to check, and `verify_image` succeeds. Do not
configure a work area before the CPU core exists: OpenOCD would then try to
run the routine and fail.

Any file works for a manual `load_image`; for example
`head -c 32768 /dev/urandom > test.bin`.

Writes are write-through, so the value in memory is always the value the
debugger wrote, no matter whether the line was in the cache or not. Whether a
particular access was a hit or a miss cannot be seen from OpenOCD itself (only
the timing differs, and JTAG dominates that); the hit / miss behaviour of the
same sequences is checked in simulation against the tag array
(`SIM/SIM_DBG` section 15 and `SIM/SIM_CACHE` sections 13 and 14).
