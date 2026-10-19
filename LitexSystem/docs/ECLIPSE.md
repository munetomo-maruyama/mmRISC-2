# Bare-metal programs with Eclipse (JTAG / cJTAG)

[日本語](ECLIPSE_J.md)

This document takes someone who has the mmRISC-2 board but nothing else installed from an empty PC to stepping
through a C program running on the board: the tools, where things are in the repository, building, loading over
JTAG (or 2-wire cJTAG) and debugging in Eclipse. It works on Ubuntu (x86_64 or arm64) and on Windows; the same
project files serve both.

A bare-metal program here is a C program that runs alone on the CPU in machine mode, without Linux: it has the
whole 256 MB of DRAM, the UART (printf), the LEDs, the timer and the interrupts to itself. It is loaded into the
DRAM by the debugger, so nothing is written to the SD card or to the FPGA's flash.

## 1. What you need

**Hardware**

| | |
|---|---|
| Board | Digilent Arty A7-100T with the mmRISC-2 bitstream (`LitexSystem/README.md`, `FPGA/ARTY_A7_100T/README.md`) |
| JTAG adapter | An FT2232H module (channel A) wired to PMOD JA (section 3 of `FPGA/ARTY_A7_100T/README.md`, section 1 of `JTAG.md`) |
| For cJTAG (optional) | The 4-wire to 2-wire adapter of section 1 of `JTAG.md` |
| Serial | The board's own USB port (the LiteX UART, 115200 baud) and a terminal program |

**Software** (all free; versions this document was checked with)

| Tool | Ubuntu | Windows |
|---|---|---|
| Eclipse IDE for Embedded C/C++ Developers (Eclipse Embedded CDT) | 2023-06 or later, `linux-gtk-x86_64` or `-aarch64` | 2023-06 or later, `win32-x86_64` |
| xPack GNU RISC-V Embedded GCC (`riscv-none-elf-gcc`) | 15.2.0-1, `linux-x64` or `linux-arm64` | 15.2.0-1, `win32-x64` |
| OpenOCD, 4-wire JTAG | riscv-openocd built from source, or xPack OpenOCD 0.12.0-7 | xPack OpenOCD 0.12.0-7 |
| OpenOCD, 2-wire cJTAG | **riscv-openocd** built from source (it has `ftdi oscan1_mode`; xPack OpenOCD does not) | riscv-openocd built with MSYS2 |
| make, rm (Eclipse's managed build) | in the system | xPack Windows Build Tools |
| Python 3 | in the system | only to make new projects (section 8) |

Eclipse comes from https://www.eclipse.org/downloads/packages/ ("Eclipse IDE for Embedded C/C++ Developers"); the
xPack tools from https://xpack-dev-tools.github.io/ (each has a release page on GitHub with the archive and its
`.sha` checksum). None needs installing with administrator rights: unpack each archive where you like.

**Why this toolchain**: the DRAM starts at 0x8000_0000 (2 GB), and the C library has to be built with
`-mcmodel=medany` to be linked there. xPack's newlib is; the newlib of a default riscv-gnu-toolchain build is
`medlow` and fails to link with "relocation truncated to fit: R_RISCV_HI20".

## 2. Where things are

```
mmRISC-2/
├── LitexSystem/
│   ├── docs/ECLIPSE.md                    this document
│   └── software/baremetal/
│       ├── common/                        shared by every program
│       │   ├── mmrisc.h                   addresses of the SoC (UART, LEDs, CLINT), CSR helpers
│       │   ├── crt0.S                     start-up: _start, the trap entry
│       │   ├── syscalls.c                 what newlib needs (printf to the UART, malloc, exit)
│       │   ├── link.ld                    everything in DRAM from 0x8000_0000
│       │   ├── common.mk                  the rules of the command-line build
│       │   └── load.gdb                   the command-line debugger's steps
│       ├── hello/                         first program: printf, mcycle, LEDs
│       ├── timer_irq/                     an interrupt (the CLINT's timer) handled in C
│       │     each with main.c, Makefile, and the Eclipse files:
│       │     .project, .cproject, "<name> Debug JTAG.launch", "<name> Debug cJTAG.launch"
│       └── eclipse_project.py             writes the Eclipse files of a new program
└── FPGA/ARTY_A7_100T/openocd/
    ├── ft2232h_jtag.cfg                   OpenOCD, 4-wire JTAG
    └── ft2232h_cjtag.cfg                  OpenOCD, 2-wire cJTAG
```

Keep the repository as it is: the launch configurations find the OpenOCD configurations by the path
`<project>/../../../../FPGA/ARTY_A7_100T/openocd/`, and the projects link `../common`. The projects are used in
place (not copied into the Eclipse workspace).

## 3. Installing the tools

### Ubuntu

```bash
mkdir -p ~/tools && cd ~/tools
tar xzf xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz       # or -linux-arm64
tar xzf eclipse-embedcpp-2023-06-R-linux-gtk-x86_64.tar.gz       # or -aarch64
```

OpenOCD: for 4-wire JTAG, xPack OpenOCD unpacked the same way is enough. For cJTAG build riscv-openocd
(https://github.com/riscv-collab/riscv-openocd: `./bootstrap && ./configure --enable-ftdi && make && sudo make
install`, which puts it in `/usr/local/bin/openocd`). It does 4-wire JTAG too.

USB access to the adapter without root: copy `contrib/60-openocd.rules` of the OpenOCD sources (or the one in
xPack OpenOCD's `contrib/`) to `/etc/udev/rules.d/`, then `sudo udevadm control --reload` and plug the adapter
in again. On a virtual machine, pass the FT2232H (and the board's USB, for the serial console) through to it.

### Windows

1. Unpack `xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64.zip`, `xpack-openocd-0.12.0-7-win32-x64.zip` and
   `xpack-windows-build-tools-<version>-win32-x64.zip`, for example under `C:\tools\`.
2. Unpack `eclipse-embedcpp-2023-06-R-win32-x86_64.zip` and start `eclipse.exe`.
3. The FT2232H's channel A needs the WinUSB driver for OpenOCD: run Zadig (https://zadig.akeo.ie/),
   Options > List All Devices, choose the adapter's **Interface 0** (channel A) and install WinUSB. Leave the
   board's own USB serial port with its FTDI driver (it is the COM port of the console).
4. A terminal program for the COM port of the board (Tera Term and the like), 115200 baud.

For cJTAG on Windows, riscv-openocd has to be built (MSYS2 with mingw-w64, the same `bootstrap` / `configure` /
`make`); 4-wire JTAG works with xPack OpenOCD as it is.

## 4. Preparing the board

1. Program the bitstream (Vivado's Hardware Manager, or the flash) as for Linux.
2. **Take the SD card out and unplug Ethernet**, then press RESET. The LiteX BIOS finds nothing to boot and stops
   at its prompt `litex>`. It has set up the DRAM by then, which is what the program needs.
3. Open the serial terminal on the board's USB port (115200 baud). The BIOS prompt shows there, and later the
   program's output.
4. Switches: **SW3 down** for 4-wire JTAG (up for cJTAG), **SW2 down** (no authentication; with it up the
   OpenOCD configurations send the key, section 3 of `JTAG.md`).
5. Connect the JTAG adapter.

The program is loaded without resetting the CPU: a reset would start the BIOS again from its first instruction,
before the DRAM is ready. The launch configurations and `load.gdb` therefore only halt the CPU, wherever the BIOS
is, load the program and start it at `_start`.

## 5. Setting up Eclipse (once)

1. Start Eclipse and choose a workspace **outside the repository** (for example `~/mmRISC-2_ws`); it only
   keeps Eclipse's own settings.
2. Window > Preferences > MCU:
   - **Global RISC-V Toolchains Paths**: Default toolchain `xPack GNU RISC-V Embedded GCC`, Toolchain folder the
     `bin` folder of xPack GCC (for example `/home/<you>/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin`,
     `C:\tools\xpack-riscv-none-elf-gcc-15.2.0-1\bin`).
   - **Global OpenOCD Path**: Executable `openocd` (`openocd.exe` on Windows), Folder the one that holds it
     (`/usr/local/bin` for riscv-openocd, or xPack OpenOCD's `bin`).
   - Windows only, **Global Build Tools Path**: the `bin` folder of xPack Windows Build Tools.
3. File > Import > General > **Existing Projects into Workspace** > Next. Root directory:
   `<repository>/LitexSystem/software/baremetal`. Tick `hello` and `timer_irq`, **leave "Copy projects into
   workspace" unticked**, Finish.

The projects are "managed builds" of Eclipse Embedded CDT with the "RISC-V Cross GCC" toolchain: Eclipse makes
its own makefiles in `Debug/` or `Release/`. Their settings (Project > Properties > C/C++ Build > Settings) are
already right: `rv64imafdc` + `_zicsr_zifencei_zba_zbb_zbs`, ABI `lp64d`, code model `medany`, the include path
and the linker script `../common/link.ld`, `-nostartfiles`, `libm`. Debug is `-O0` (for stepping), Release
`-O2`.

## 6. Building

Select the project, Project > Build Project (or the hammer). The Console ends with

```
Invoking: GNU RISC-V Cross Print Size
riscv-none-elf-size --format=berkeley "hello.elf"
   text	   data	    bss	    dec	    hex	filename
  35220	   2928	    712	  38860	   97cc	hello.elf
Finished building: hello.siz
```

`Debug/hello.elf` is what the debugger loads; `hello.lst` is its listing with the source.

## 7. Debugging

1. Run > Debug Configurations… > **GDB OpenOCD Debugging** > `hello Debug JTAG` (or `hello Debug cJTAG` with SW3
   up) > Debug. The first time Eclipse asks to switch to the Debug perspective: yes.
2. Eclipse starts OpenOCD (its Console shows `Examined RISC-V core` and `Listening on port 3333`), starts gdb,
   halts the CPU, loads the program, sets pc to `_start` and runs to **the first line of `main`**, where it
   stops.
3. From there:

| Action | What happens |
|---|---|
| F6 (Step Over) | One line; the serial terminal shows `Hello from mmRISC-2 ...` |
| F5 (Step Into) on `count_primes(...)` | Into the function |
| Double-click in the left margin of a line, F8 (Resume) | Stops at that breakpoint |
| Variables / Expressions views | Local variables; add `led_count` in Expressions and it follows the LEDs |
| Registers view, Memory view (`0x80000000`), Disassembly | Registers (CSRs included), memory, instructions |
| F8 with no breakpoint | Runs to the end; `exit` stops at an `ebreak` in `_exit` |
| Ctrl+F2 (Terminate) | Ends the session (OpenOCD and gdb stop) |

What the two programs print (`hello` built as Debug, `-O0`):

```
Hello from mmRISC-2 (bare metal, machine mode)
  misa    800000000014112d
  mhartid 0
  primes up to 20000: 2262
  11663566 cycles, 5197272 instructions, CPI 2.244, 233272 us
done
```

```
timer_irq: the CLINT every 100 ms
  5 interrupts
  10 interrupts
  15 interrupts
  20 interrupts
done
```

`hello` also counts from 0 to 15 on LD4 to LD7, `timer_irq` every 100 ms. In `timer_irq`, a breakpoint in
`trap_handler()` stops in the interrupt; `mcause` is `0x8000000000000007` (machine timer interrupt).

Breakpoints: software breakpoints (any number) work on the DRAM; there are 4 hardware triggers for hardware
breakpoints and watchpoints, and a watchpoint stops only on an access to the first address of the variable
(section 3 of `JTAG.md`).

To run a program again, Terminate and start the same configuration again (the BIOS need not be at its prompt any
more: the CPU is halted wherever it is, and the DRAM stays set up until RESET).

## 8. A program of your own

```bash
cd <repository>/LitexSystem/software/baremetal
mkdir myprog
cp hello/main.c hello/Makefile myprog/
sed -i 's/^TARGET := hello/TARGET := myprog/' myprog/Makefile
python3 eclipse_project.py myprog      # .project, .cproject, the two .launch for "myprog"
```

Then File > Import > Existing Projects into Workspace as in section 5. Further `.c` / `.S` files put in the
project folder are built by Eclipse with no change; for the command line add them to `SRCS` in the Makefile.

What `common/` gives a program:

- `printf` / `puts` / `getchar` on the UART (newlib, with `long long` and floating point), `malloc` (the heap
  runs from the end of the program to 64 KB below the top of the DRAM, where the stack is)
- `mmrisc.h`: `LEDS_OUT`, the UART's registers, `CLINT_MTIME` / `CLINT_MTIMECMP`, `csr_read()` / `csr_write()` /
  `csr_set()` / `csr_clear()`, `mmrisc_cycle()`, `mmrisc_mtime()` (500 kHz), `mmrisc_delay_us()`
- `trap_handler(mcause, mepc, mtval)`: called for every trap, with the integer registers a C function may use
  saved. Define it in the program (as `timer_irq` does) to take interrupts; the default reports an exception
  and stops. An exception handler that returns has to move `mepc` on itself.
- The FPU is on (`mstatus.FS`), interrupts are off until the program turns them on, and `.bss` is cleared.

## 9. Without Eclipse

The same programs build and run from the command line:

```bash
export PATH=<xpack-gcc>/bin:$PATH
cd <repository>/LitexSystem/software/baremetal/hello
make OPT=0                      # out/hello.elf (OPT=2 by default)
```

```bash
openocd -f <repository>/FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg        # in a second terminal
```

```bash
riscv-none-elf-gdb -x ../common/load.gdb out/hello.elf
```

`load.gdb` connects to OpenOCD, halts the CPU, loads, sets pc to `_start` and runs to `main`; then gdb's own
commands (`next`, `step`, `break`, `print`, `continue`, ...). `make hex` also writes `out/hello.hex`, which
`SIM/SIM_BIOS` can run in simulation with the whole SoC: `./obj_dir/Vtb_BIOS +linux +fw=<.hex> +image=<any hex>`
(the ROM jumps to 0x8000_0000; the UART's output goes to the simulator's log).

## 10. When it does not work

| Symptom | Cause, what to do |
|---|---|
| `relocation truncated to fit: R_RISCV_HI20` when linking | A toolchain whose newlib is `medlow`: use xPack GCC (section 1) |
| Eclipse: "Program riscv-none-elf-gcc not found in PATH" | Global RISC-V Toolchains Paths (section 5) not set, or set for another toolchain name |
| OpenOCD: `unable to open ftdi device` | The adapter is not seen: USB passed to the VM? udev rule (Ubuntu), WinUSB on Interface 0 (Windows). The configurations look for the description `Dual RS232` and 0403:6010; change `ftdi device_desc` if your module says otherwise |
| OpenOCD: `invalid command name "ftdi oscan1_mode"` | cJTAG with an OpenOCD without it: use riscv-openocd |
| OpenOCD: `dmstatus=0x3`, `examination failed` | SW2 is up and the key was not accepted (section 3 of `JTAG.md`) |
| The program loads but prints nothing, or stops in a trap at once | The DRAM was not set up: the board was not through the BIOS (section 4), or the launch configuration was changed to reset the CPU. Press RESET, wait for `litex>`, debug again |
| It stops at an `ebreak` in `_exit` | The program ended (`return` from `main`, or `exit()`) |
| Linux was running on the board | It is stopped by the debugger and its memory overwritten; press RESET afterwards (with the SD card in, Linux boots again) |

## 11. How it works

- The program runs in machine mode at the start of the DRAM: `link.ld` places `_start` (`.text.init`) at
  0x8000_0000, then the code and data; the stack is the top 64 KB below 0x9000_0000. The LiteX BIOS runs from
  the ROM (0x1000_0000) with its data in the SRAM (0x1100_0000), so it uses none of the DRAM.
- `crt0.S` turns interrupts off, sets `mtvec` to its trap entry, `gp`, `sp`, the FPU, clears `.bss` and calls
  `main()`; `exit()` ends at an `ebreak`, where the debugger (OpenOCD sets `dcsr.ebreakm`) halts.
- The debugger writes the program through the debug module's system bus access, which goes through the data
  cache; the core invalidates the instruction cache when it does, so no `fence.i` is needed (section 3 of
  `JTAG.md`).
- The launch configurations: no reset (`doFirstReset` / `doSecondReset` off), load the image and symbols of the
  project's `Debug/<name>.elf`, `set $pc = _start`, stop at `main`, gdb `${cross_prefix}gdb` (the global
  toolchain path), OpenOCD `${openocd_path}/${openocd_executable}` (the global OpenOCD path) with
  `-f "${project_loc}/../../../../FPGA/ARTY_A7_100T/openocd/ft2232h_[c]jtag.cfg"`. `eclipse_project.py` writes
  them and the project files for a program folder.
