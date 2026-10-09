# mmRISC-2 / LiteX bring-up procedure and status

[日本語](BRINGUP_J.md)

Last updated: 2026-09-25

## What has been confirmed so far

Keep the boundary clear: **what was confirmed in simulation** and **what has not been confirmed on the
board yet** are different things.

| | Status |
|---|---|
| Generating the SoC (RTL + BIOS) | **Works**. `scripts/build_soc.sh` |
| Memory map matches the Rocket configuration | **Confirmed** (csr.json compared) |
| Interrupt numbers match the Rocket configuration | **Confirmed** (`*_interrupt_read` of soc.h) |
| Core + real caches + AXI | **Confirmed**. `SIM/SIM_SYS`, 15 home-made tests + 132 riscv-tests |
| **Instruction fetch from outside the cache** | **Confirmed**. `make romboot` (below) |
| **The LiteX BIOS itself (with interrupts)** | **Confirmed**. `SIM/SIM_BIOS` (2026-09-24, added after the board stopped) |
| Bitstream | **Works**. Timing closes at 50 MHz (`TIMING.md`) |
| Does the BIOS come up on the board | **Confirmed** (2026-09-24) |
| Does Linux boot on the board | **Confirmed** (2026-09-25, WNS 0.013 ns; with Ethernet 2026-09-26, WNS 0.131 ns, up to DHCP, ping and TFTP netboot). From the SD card's ext4 to the BusyBox prompt. `cat /proc/cpuinfo` and `uname -a` work. Open: one WARNING of `kernel/bpf/memalloc.c:186` during boot (below) |

## Why uncached fetch was dealt with first

LiteX's BIOS **runs from ROM at 0x1000_0000**. mmRISC-2's caches divide at `MEM_BASE` (= 0x8000_0000):
**below it, accesses are uncached AXI4-Lite**. So the BIOS's instruction fetches all go through the
uncached path.

`SIM_CACHE` covers this path for the cache alone, but **it had never been exercised from the core**.
Chasing "not even the BIOS banner appears" without JTAG after burning a bitstream would be painful, so it
was walked through in simulation first.

`make romboot` of `SIM/SIM_SYS` puts the reset vector in the uncached window and jumps to the main body
from a small stub placed there (`li t0,0x80000000; jr t0`, two of them compressed instructions). All 15
pass.

## Where the board first stopped (2026-09-24)

With the first bitstream, the terminal showed only `        __` (the first 16 characters of the banner)
and stopped. **The CPU was running**: it fetched the BIOS from ROM, ran C and wrote to the UART. What
stopped was interrupts:

- The BIOS's UART is interrupt-driven. The first 16 characters go straight into the UART's TX FIFO; after
  that they pile up in a ring buffer that the interrupt handler sends out.
- No interrupt ever came. The priority of source 1 of the PLIC stayed 0.
- The cause was that uncached accesses of the D$ **rounded the AXI-Lite address to 8 bytes**. The
  built-in PLIC decides which half of a 32-bit register is meant by bit 2 of the address, so a write to
  `0x0C00_0004` became "a write to the lower half with no strobes set" and was dropped. Reads likewise:
  meaning to read claim (+4), it read threshold (+0).

SIM_CORE's memory model passed byte addresses, so it did not show, and SIM_SYS / SIM_CPU tied the
external interrupt to 0. **The real BIOS had never been run with interrupts**. `SIM/SIM_BIOS` puts the
real `bios.bin` on CPU_TOP and models LiteX's UART (16-entry FIFO, level events) to fill that gap. It
was confirmed that the RTL before the fix stopped at the same 16 characters, and then it was fixed.

## Round 2: stopped at `Booting from boot.json...` (2026-09-24)

The BIOS came up all the way: SDRAM calibration (m0 / m1 both b01), memtest, memspeed (write 37.7 / read
41.6 MiB/s), the boot menu. It stopped in the middle of loading from the SD card.

### 1. The SD card PMOD goes on **JD**

LiteX's Arty platform puts the SD card PMOD on `pmodd` (**JD**, `D4 D3 F4 F3 E2 D2 H2 G2`). The XDC of
this build and the Rocket build use the same pins. **Plugged into JA, nothing is connected to the SD
controller**.

### 2. The L2 cache was removed (`--l2-size 0`)

mmRISC-2 has a dedicated memory bus to LiteDRAM and no DMA port. With that combination LiteX connects
the SoC bus (= the SD card's DMA) to LiteDRAM **through an 8 KiB write-back L2** (`connect_main_bus_to_dram`
of `soc.py`). The CPU does not go through that L2, so:

- The last few KiB of data loaded from the SD card into DRAM (OpenSBI, the kernel) can remain in the L2
- The BIOS's `flush_l2_cache()` is implemented as "read main memory with the CPU to push the L2 out",
  which does nothing for mmRISC-2, which does not go through the L2

Rocket has a coherent DMA port (`dma_bus`) and does not have this problem. `--l2-size 0` was added to
`scripts/build_soc.sh`. The memory map does not change (the only difference in `csr.csv` is that
`config_l2_size` disappeared).

## Round 3: up to OpenSBI, and the kernel prints nothing (2026-09-24)

With the PMOD moved to JD, it loaded `Image` (15 MB) and `fw_jump.bin` from `boot.json`, and OpenSBI
v1.9 started and printed all its platform information. It stopped right after OpenSBI jumped to the
S-mode kernel (0x8020_0000), without a single line of `earlycon` output.

Cause: **the procedure of turning the MMU on by writing satp from S mode**. Linux's `head.S`
(`relocate_enable_mmu`) puts in stvec the **virtual** address of "the instruction after the satp
write", writes satp, and moves to virtual addresses through the page fault of the next instruction's
fetch (the physical address it is running at is not in the new table). mmRISC-2's CSR writes are
serialized, but **the instructions behind had entered the fetch queue before the write (without
translation)**, so they ran on at physical addresses without faulting, and when another fetch faulted
later, the target of stvec was not mapped either, and it went round silently.

The MMU tests until then wrote satp in M mode and entered S with `mret`. `mret` refetches, so this order
had never been exercised.

Fix: **a write to satp or a PMP CSR refetches what is behind it at commit** (the same path as fence.i /
SFENCE.VMA). `t21_satp` tests exactly this procedure (the first version passed by accident because the
failure branch itself faulted and returned to stvec; fixed by counting "how many times it came to that
label").

### Booting Linux confirmed in simulation (`SIM/SIM_BIOS`, `make linux`)

With `+linux` the BIOS is not run; a small stub in ROM jumps to OpenSBI. Main memory (256 MiB; Linux
takes from the top, so all of it is needed) gets `fw_jump.bin` at 0x8000_0000 and the Rocket
configuration's `Image` (the same kernel) at 0x8020_0000. `+pcmon=<n>` prints the PC every n cycles,
which `System.map` turns into function names. The CLINT divider is 100, as on the board (leaving it at 1
makes time run 100 times faster and timer interrupts come 100 times as often).

With the satp fix in the RTL:

```
OpenSBI v1.9 ... → Linux version 7.2.0-rc2 ... → earlycon
riscv-plic: interrupt-controller@c000000: mapped 4 interrupts
LiteX SoC Controller driver initialized
12003800.serial: ttyLXU0 ... is a liteuart
litex-mmc 12002000.mmc: LiteX MMC controller initialized.
cpu0: scalar unaligned word access speed is 0.01x byte access speed (slow)
Waiting for root device /dev/mmcblk0p2...
```

233 million cycles (about 4.7 seconds at 50 MHz). **The kernel gets all the way to where it needs the SD
card**. The SD commands time out because the bench has no SD card model. Misaligned accesses are emulated
by OpenSBI (slow, as expected).

### A DMA port was added (2026-09-24, plan A)

A DMA port (AXI4-Lite slave) was added to CPU_TOP so that the SD card's DMA goes through the data cache
(`CPU_CACHE_SPEC.md` 4.8). It is declared as `dma_bus` in `core.py`, so LiteX connects the SD card's
`block2mem` / `mem2block` there and defines `CONFIG_CPU_HAS_DMA_BUS`. The memory map does not change. No
change on the Linux side or in the device tree either (DMA is coherent by default).

During verification, it turned out that the SIM_SYS bug injection campaign **was broken**. It ran all of
SIM_CORE's tests, and of those `t06_irq` and `t15_plic` fail on this bench whatever the RTL, so **every
mutation was counted as "detected"**. Fixed to run only the tests of `make run-all`, 4 turned out to be
really undetected:

- The I$ ignoring `i_cancel` (a refused fetch goes out on the bus): the result does not change, so the
  bench counts reads on the peripheral bus and `progs/d02_pmp_fetch` checks there are 0
- fence.i invalidating the I$ before the write-back finishes: `progs/d03_fencei` (rewrites code in set
  63, whose write-back arrives last, and makes the whole cache dirty before fence.i)
- The remaining 2 affect neither the result nor safety (removed, with the reasons in the header)

`t13_pmp` also gained a refused fetch to a line not in the I$.

### A problem expected ahead: Linux's SD driver and DMA coherence (solved, above)

The BIOS calls `fence.i` (D$ write-back + invalidate) after DMA, so it has no problem. **Linux does
not**. LiteX's `litex_mmc` driver allocates its DMA buffers with `dma_alloc_coherent` and assumes the
hardware keeps them coherent. mmRISC-2's D$ does not know about DMA writes, so reading the root file
system from the SD card is likely to read stale cache contents. On Rocket, `dma_bus` solved this. The
fix (adding a DMA port through the D$ to CPU_TOP, or the like) was to be decided after seeing the kernel
boot. Booting with an initramfs first was the safe way.

## Round 4: ext4 on the SD card mounted, stopped at `Run /sbin/init` (2026-09-24)

With the bitstream with the DMA port (WNS 0.008 ns), the kernel recognized the SD card, mounted ext4 and
got as far as `Run /sbin/init`. However:

- It **sometimes stopped** after `clk: Disabling unused clocks` (while mounting ext4 and recovering the
  journal)
- It **always stopped** after `Run /sbin/init ... TERM=linux`

### User space itself runs in simulation

With `make linux-initrd` of `SIM/SIM_BIOS`, the same BusyBox set as the SD card's second partition
(`~/mmlitex_build/initrd_bb`) was passed as an initramfs and `/init` (= busybox) was started. The sysinit
of inittab (mounting proc / devtmpfs / tmpfs / sysfs, `busybox --install -s`) ran, it reached ash's `# `
prompt, and then waited for input in `arch_cpu_idle`. The same with the UART at the board's speed
(`+uart_cycles=4340`, FIFO filling up and sending by TX interrupt). `+utrace=<n>` shows every trap after
entering user mode (page faults, ecall, timer).

So U mode, system calls, page faults and interrupt-driven tty output work. The difference from the board
is that the executable's pages come **from the SD card by DMA**.

### Cause: the D$'s write-back queue and the order of fills / single writes of the same line

The D$ queues evicted dirty lines in the write-back queue, and the write engine sends them to AXI4 in
order. While a line is in the queue, memory is still old. Then:

1. **A fill of the same line** sent its AR right away and read the old line (the CPU rereading a line it
   just evicted, a DMA read coming to the same line).
2. **A DMA write (`STWTHR`)**: the write engine gave single writes priority over the queue, so the DMA's
   data reached memory first, and the old line from the queue then overwrote it.
3. A fill of the same line could also overtake an `STWTHR` on the bus.

Linux's `litex_mmc` DMAs straight into pages of the page cache. Those pages were used for something else
just before, and dirty lines often remain in the CPU's D$. When eviction and DMA overlap, part of the
page keeps old contents. If busybox's code is garbled, user space does not proceed; if writes during
journal recovery (`mem2block` reads from the D$) are garbled, ext4 stops.

Fix: a fill does not send its AR until the write-back of the same line and single writes have received
their B response (`f_ar_block`, state `F_ARW`), and a single write is not sent while the same line is in
the queue (`sw_wait_wb`). `CPU_CACHE_SPEC.md` 4.3.

Section 16 of `SIM/SIM_CACHE` stops the memory model's AWREADY (`aw_hold`) to make write-backs really
wait, and reproduces all 4 cases (all failed before the fix). Bug injections M23 to M25 are all
detected. Existing simulations did not find it because the memory model accepts writes immediately, so
nothing stayed in the queue. On the board, LiteDRAM and DRAM refresh make writes wait, and AXI4 does not
forbid reads from overtaking writes.

### Distrust the contents of the SD card

In the configuration before the fix, journal recovery may have written stale data to the SD card. Before
the next try, check on the PC

```bash
sudo e2fsck -f /dev/sdX2
cmp /media/<user>/rootfs/bin/busybox ~/mmlitex_build/initramfs/bin/busybox
```

and reinstall the contents of the second partition if broken.

## Round 5: still stopped at the same 2 places after fixing the D$ order (2026-09-25)

With the WNS 0.103 ns bitstream the symptoms were the same. Typing keys while stopped got no echo, and
waiting minutes produced no RCU stall detection either. Either the CPU had stopped or interrupts never
came: a hardware problem.

### An SD card model was made (`SIM/SIM_BIOS/SD_MODEL.sv`, `make linux-sd`)

An imitation of LiteSDCard at register level (core / phy, block2mem / mem2block DMA, events and
interrupts) connected to an SDHC card holding a disk image. The DMA enters the CPU's DMA port in the same
form as LiteX's Wishbone2AXILite (32 bits at a time, strobes 0x0F / 0xF0 on a doubleword address).
`sdcard.img` has the same layout as the board's card (MBR, the BusyBox set and `sbin/init` in the ext4 of
the second partition) and boots with the same `fw_jump.bin` as the board (`root=/dev/mmcblk0p2`).
`+sdlog` shows the SD commands, `+dmalog` the requests of the DMA port, `+pcmon` the interrupt lines, the
PLIC's claim counts and the SD state.

With it **both stops of the board were reproduced in simulation**, and there were two causes.

### Cause 1: a D$ fill answered a DMA write (hangs after `clk: Disabling unused clocks`)

`STWTHR` (a DMA write) set `rob_wait` in the ROB, but `rob_mshr` kept the value of the previous owner of
that ROB slot. A fill answers requests "with `rob_wait` set and `rob_mshr` itself", so the CPU's fill
answered the DMA write before it had been written to memory. When the real answer came later, it
"completed" another request now using that slot. In simulation the D$ never answered the DMA again, and
the CPU stopped making cache requests too. The same as "no echo" on the board.

Now `STWTHR` is answered only by the write engine (`rob_wait` is only for requests waiting for a fill).
SIM_CACHE 16(e) and mutation M26.

### Cause 2: `mip.SEIP` stays set (stops after `Run /sbin/init`)

With 1 fixed, it got as far as mounting ext4, and then came an interrupt storm. The PLIC was not
signalling anything, but `mip.SEIP` stayed 1, and the kernel kept taking S external interrupts and
returning with claim 0.

The read value of `mip.SEIP` is "the bit software can write OR the PLIC's S line", but `csrrs` / `csrrc`
wrote based on that read value, so a read-modify-write while the PLIC was signalling S copied the line's
value into the software bit. OpenSBI executes `csrc mip, STIP` at every M timer interrupt, so the moment
an SD card interrupt and the timer coincided, SEIP got stuck. The privileged spec says "only the software
bit is used for read-modify-write". Fixed in `rmw_data` of `CORE_CSR` (`CPU_CORE_SPEC.md` decision 51,
`t22_mip_seip`, mutation M210).

That it stopped "always" while starting user space, when SD interrupts are frequent, and "sometimes"
while mounting, is explained by how often the timer and SD interrupts coincide.

### Result

`make linux-sd` mounts ext4 from the SD card and gets to `/sbin/init` → BusyBox's `# ` prompt. The
regressions (SIM_CORE, SIM_SYS, SIM_CPU, 132 riscv-tests, SIM_CACHE and its 18 sweep configurations) all
PASS.

## Round 6: the Linux prompt on the board (2026-09-25)

With the bitstream containing the 2 fixes of round 5 (WNS 0.013 ns), the board went from the SD card's
ext4 to `/sbin/init` → BusyBox's `# `, and `cat /proc/cpuinfo` (`rv64imafdc_...`, `mmu: sv39`) and
`uname -a` worked.

- `mount: mounting devtmpfs on /dev failed: Device or resource busy` is harmless. The kernel had already
  mounted `/dev`, and inittab is only trying to mount it again.
- **Open**: right after reading the partition table, `kernel/bpf/memalloc.c:186`
  (`WARN_ON_ONCE(local_inc_return(&c->active) != 1)`) appeared once. Atomically adding 1 to a per-CPU
  counter that should be 0 did not give 1, which points at AMOs or memory coherence. It never appeared in
  simulation. Its frequency to be checked on the board, while adding a random test that mixes the DMA
  port with the CPU's AMOs and misses to SIM_CACHE to look for it.

## Round 7: two more from a random test mixing DMA and the CPU (2026-09-26)

The WARNING of round 6 (`kernel/bpf/memalloc.c:186`) did not appear after rebooting. A bug that happens
only with rare timing cannot be chased on the board, so a test that runs the CPU and the DMA (second
port) at random on the same lines at the same time was added to SIM_CACHE (section 17).

It found 2 D$ bugs that occur even without DMA (`CPU_CACHE_SPEC.md` 4.3, item 5):

- **The access right after `fence.i` returned the data of another line**. While the flush walk was
  reading tags, a request waiting in stage 1 compared against the tags of other sets. Linux issues
  `fence.i` every time it maps an executable page.
- **A store disappeared**. In the cycle a store hit made a line dirty, if a miss in the same set read the
  tags and waited for an MSHR, one cycle later the forwarding was gone and the line looked clean, so it
  was evicted without being written back.

Both show up as "a counter that should be 0 is not 0" or "a stale value", so they are a plausible
explanation of the WARNING of round 6. To be confirmed with a fixed bitstream.

The testbench had a bug too (it wrote the queue of expected values even when full). After fixing it,
section 17 PASSed with 24 seeds × 50000 operations.

## Round 8: adding Ethernet (2026-09-26)

With the fixes of round 7 (WNS 0.046 ns), the WARNING no longer appeared however many times it was
rebooted, and writes to the SD card persisted. Ethernet could not be used for another reason: the SoC had
no Ethernet (the `build_soc.sh` inherited from the Rocket configuration had no `--with-ethernet`). The
kernel's LiteEth driver and BusyBox's `udhcpc` were there from the start.

- `--with-ethernet --eth-dhcp --remote-ip` were added to `build_soc.sh`. The BIOS gets an IP by DHCP and
  can netboot by TFTP (`eth_dhcp`, `eth_remote_ip`, `netboot`).
- `ethmac` = 0x3000_0000 in the `mem_map` of `core.py` (same as Rocket). The packet buffer is below
  MEM_BASE, so the D$ does not cache it.
- ethmac / ethphy came in at the start of the CSR space, so the CSRs of the SD card, timer0 and UART
  moved back by 0x1000 each, and the interrupts became ethmac 2 and SD card 3 (PLIC 3 and 4). The device
  tree was matched (`earlycon`, `riscv,ndev = 4`, the Ethernet node) and `fw_jump.bin` rebuilt. **Use
  the bitstream and `fw_jump.bin` as a pair**.
- LITEX_PERIPH of SIM_BIOS: the CSR offsets became named constants, moved to the new layout. The BIOS
  resets the PHY at start-up and waits 2 × 200 ms, so the limit of `make check` became 60 million cycles.
  There is no model of the Ethernet itself (its CSRs return 0).
- The procedure and how to check it: "Ethernet" in `software/boot/README.md`. The script with which
  `udhcpc` sets the address in Linux was put in `software/rootfs/`.
- Board (WNS 0.131 ns): `eth0` appears, `udhcpc` gets an address by DHCP, and `ping` reaches the router
  and a PC on the LAN. This BusyBox's `udhcpc` has an empty default script, so `-s
  /usr/share/udhcpc/default.script` is needed. `ping` is the simple version (no options).
- The BIOS's TFTP netboot was also confirmed on the board (`eth_dhcp` → `eth_remote_ip` → `netboot`
  fetching Image and fw_jump.bin, through OpenSBI → Linux → DHCP). The first failure was the TFTP
  server's firewall having UDP port 69 closed.

## Round 9: stress test on the board (2026-09-28)

`software/rootfs/root/stress.sh` for 30 minutes on the board: **PASS**. Ethernet (fetching 15 MB by TFTP
in 1024-byte blocks and checking the md5), the SD card (writing 2 MB, dropping the page cache and reading
it back) and RAM (64 MB) ran at the same time.

| Job | Rounds | NG |
|---|---|---|
| net | 8 (about 120 MB) | 0 |
| sd | 80 (about 160 MB) | 0 |
| mem | 11 (about 700 MB) | 0 |

No kernel warnings during the run, and the 10-minute reports never stopped. TFTP with the 3 in parallel
ran at about 70 KB/s (about 3.5 minutes for 15 MB). Hours-long tests not yet done.

## Round 10: the SD card's contents into the repository, a proper shutdown (2026-09-29)

- What had been added to the root of the SD card (inittab, `sbin/init`, the udhcpc script, `stress.sh`)
  was put in `software/rootfs/` and is now written by `scripts/sd_rootfs.sh`.
- `poweroff` did not work. BusyBox's init waits for the `sysinit` lines to finish in order and handles
  poweroff / reboot (signals) only after that, but the shell was started from a `sysinit` line (as in the
  Rocket configuration's initramfs). The shell became `respawn`, and `sync` and `umount -a -r` were added
  for shutdown. `poweroff` and `reboot` work on the board, and ext4's `recovery complete` no longer
  appears at the next boot.
- `Malformed early option 'console'` in the boot log (`console=liteuart` also matched the early console
  setting) and `Falling back to deprecated "riscv,isa"` were removed. The device tree lists only the ISA
  actually implemented (Zicntr yes, Zihpm no).
- On the way the SD card's ext4 got corrupted (block bitmap checksum mismatches and the like). The PC's
  log showed that the USB card reader through Parallels had disconnected in the middle of a write
  (`Synchronize Cache(10) failed`, reconnecting with a new SCSI number). Repaired with `e2fsck` and
  `fsck.vfat`. Before removing the card: `udisksctl unmount` and `udisksctl power-off`.

## Round 11: JTAG / cJTAG debug (2026-09-30 to 10-01)

- The target of the debug module was changed from the stand-in hart to the real core (debug mode,
  section 11 of `CPU_CORE_SPEC.md`). JTAG / cJTAG are brought out on PMOD JA. Pinout, switches and
  OpenOCD configuration are the same as `FPGA/ARTY_A7_100T` (`docs/JTAG.md`).
- The first synthesis had WNS -0.034 ns. The 3 failing paths were known paths that do not go through
  the debug logic: placement noise. With physical optimization after placement and after routing,
  +0.040 ns (section 21 of `docs/TIMING.md`).
- Board: `scripts/jtag_check.tcl` PASSed in all 4 combinations of 4-wire JTAG / 2-wire cJTAG × without /
  with authentication. Halting while Linux ran stopped inside the S-mode kernel (`satp` enabled), and
  step (pc+2 on compressed instructions, branches), reading and writing registers and reading CSRs over
  the system bus worked. A wrong key gave `examination failed` (dmstatus=0x3), and writing the right key
  let examine pass right away.

## Round 12: timing margin of the FPU (2026-10-01)

- The masks of the FPU's sticky bit were made without a carry chain, and the floating point → integer
  conversion was split into 2 cycles. The DTLB was taken out of the select of the load / store tval. WNS
  after place and route +0.040 → **+0.205 ns** (section 22 of `docs/TIMING.md`).
- Board: Linux boots to the shell, `stress.sh` for 10 minutes (net 3, sd 27, mem 4 rounds) PASS, no
  kernel warnings.

## Procedure

### 1. Generate the SoC (Linux VM)

```bash
cd LitexSystem
./scripts/build_soc.sh
```

Verilog, XDC and tcl in `build/gateware/`, the BIOS in `build/software/bios/`. The paths to this
repository in the tcl are rewritten **relative to the gateware directory** (because the drive letter of
the shared folder changes on the Windows side).

### 2. Bitstream (Windows VM)

Open `build/gateware/` and run `build_digilent_arty.bat`. The procedure is confirmed with Vivado 2025.1
(proven with the Rocket configuration).

**What to look at**: LUT utilization and timing. The Rocket configuration had LUT 56 % and WNS +0.409 ns
at 50 MHz. mmRISC-2 has an FPU and an MMU, so this cannot be known until it is actually built.

### 3. Device tree and OpenSBI

`software/mmrisc_arty.dts` is the Rocket one with only the CPU node changed. The changes are the ISA
string, 8 TLB entries, 8 PMP regions and removal of the debug triggers (TLB and PMP were 16 at first,
reduced to 8 to fit the FPGA; section 7 of `docs/TIMING.md`).

`timebase-frequency = <500000>` **must go together with the hardware's `CLINT_TICK_DIV` = 100**
(50 MHz / 100 = 500 kHz). Changing only one of them puts Linux's time off.

OpenSBI **embeds** the DTB in `fw_jump.bin`, so always rebuild after changing the DTS:

```bash
cd <opensbi>
make PLATFORM=generic CROSS_COMPILE=riscv64-unknown-linux-gnu- \
     FW_FDT_PATH=<...>/mmrisc_arty.dtb FW_JUMP_FDT_ADDR=0x82400000
```

### 4. SD card

`Image` / `fw_jump.bin` / `boot.json` on the first partition (FAT16), the root file system on the second
partition (ext4). All 3 are in `software/boot/` (since 2026-10 `Image` too is our own, with the perf
settings added), and the first partition is written from the Mac (round 15, `software/boot/README.md`).

## Where to look when the board gets stuck

Suspect in this order.

1. **No BIOS banner** — uncached fetch or the reset vector. `romboot` passes, so the RTL side is less
   likely, but XDC or clock problems are another matter.
2. **The BIOS comes up but `sdcardboot` fails** — the traps hit with the Rocket configuration apply as
   they are. Read "SD card boot troubleshooting record" in `LitexRocket/docs/BUILD_STATUS.md` first. Read
   raw sectors with `sdcard_read <block>` and compare with `dd` on the PC.
3. **OpenSBI comes up but Linux does not proceed** — suspect a mismatch between the device tree and the
   real hardware, especially `timebase-frequency`, the PLIC's `riscv,ndev` and interrupt numbers.
4. **Never reaches user space** — the MMU. The virtual memory environment of riscv-tests in `SIM_CORE`
   (109 tests) passes, so Sv39 itself works, but the board's amount of memory and its combination with
   the caches are another matter.

## Not connected yet

- (Resolved 2026-09-30) JTAG is brought out on PMOD JA, and the debug module is connected to the core.
  halt / resume / step / registers / memory work (`docs/JTAG.md`, section 11 of `CPU_CORE_SPEC.md`).

## Round 13: Linux cannot read the SD card — SD I/O timing (2026-10-03)

With the version that removed the PMP → D$ cancel path (section 28 of `TIMING.md`, WNS +0.661 ns), Linux
could not mount the root file system and panicked. The same at every reset.

```
litex-mmc 12003000.mmc: Data xfer (cmd 18) error, status -84     ← CRC error on data
litex-mmc 12003000.mmc: Command (cmd 12) error, status -110      ← timeouts from then on
...
VFS: Cannot open root device "/dev/mmcblk0p2"
```

The CPU was running (the kernel got through initializing the drivers, and the panic was "cannot open
the root"). What failed was the **CRC of the SD data lines**, while LiteX's BIOS could read Image and
fw_jump.bin from the same card (the BIOS uses a slow clock, Linux a fast one).

What was checked:

- LiteSDCard stops the SD clock when the receiving side is blocked (`stop` of `SDPHYDATAR`), so a DMA
  write taking one cycle longer (the D$'s write-through from the second cycle) cannot drop data. In
  earlier versions too the DMA was slower than the SD and the clock was being stopped.
- **The SD pins had no timing constraints, and the PHY's registers were not in the I/O blocks** (after
  placement, OLOGIC 45 = DDR3's OSERDES, ILOGIC 21 = ISERDES 16 + IDDR 5; all of the SD's FDCEs in the
  fabric). When the card's data is captured depended on placement, and was not checked either.

LiteX builds the SD PHY from ordinary flip-flops (the FDCEs of `XilinxSDRTristateImpl`) and puts neither
an `IOB` attribute nor input / output delay constraints on them. So the XDC generated by `build_soc.sh`
now gets

```
set_property IOB TRUE [get_ports {sdcard_clk sdcard_cmd {sdcard_data[*]}}]
```

(putting the output, output-enable and input registers of clock, command and data into the I/O blocks).
The capture timing is then the same in every version.

**Result**: the version synthesized again with the constraint (same RTL, WNS +0.681 ns) boots Linux, and
`bench.sh` passes. After placement OLOGIC went 45 → 51 (`OUTFF_Register` 6 = clock, command and 4 data;
`TFF_Register` 5 = output enables of command and 4 data): the output side went into the I/O blocks.

**Correction (2026-10-03)**: this first said "the input side did not go in", which was wrong. LiteX
takes the SD inputs with `IDDR` (`DDR_CLK_EDGE = SAME_EDGE`, `sys_clk`), and `IDDR` is the input logic
of the I/O block (ILOGIC) itself. The 5 `IFF_IDDR_Register` of the utilization are the SD's command and 4
data lines, not Ethernet (these 5 are the only `IDDR` in the generated Verilog), and were in the I/O
blocks from the start. So now all SD registers are in the I/O blocks:

| | Registers in the I/O block | Signals |
|---|---|---|
| Input | `IDDR` 5 (from before) | cmd, data[3:0] |
| Output | `OUTFF` 6 (since round 13) | clk, cmd, data[3:0] |
| Output enable | `TFF` 5 (since round 13) | cmd, data[3:0] |

The timing with the card no longer depends on placement. What had broken, then, was the output side
(especially the flip-flop that makes the clock, and the skew of the data and command outputs).

Ethernet (MII, a 25 MHz clock from the PHY) also has no input / output delay constraints and its
registers are in the fabric, but the window is wide against a 40 ns period, and no version has had a
problem so far. If the same symptom shows on Ethernet, add `IOB` in the same way.

## Round 14: long stress test after the performance work (2026-10-03)

The performance work (sections 4 to 10 of `BENCH.md`: branch prediction, the D$'s 2-cycle answer, issuing
loads and stores from EX, multiply and divide, gshare, late branches, the timing work of sections 24 to
30 of `TIMING.md`) changed the memory pipeline, branch prediction and the D$ a lot, so `stress.sh` ran
for 120 minutes on its last version (WNS +0.121 ns, 2.429 CoreMark/MHz).

```
=== stress result (iterations, ok, ng) ===
mem 58 58 0
net 33 33 0
sd  405 405 0
=== new kernel messages that look like trouble ===
(none)
=== PASS ===
```

- mem: writing and checking 64 MiB, 58 times (D$ and DRAM)
- net: fetching the 15 MB Image by TFTP and checking the md5, 33 times (Ethernet, interrupts)
- sd: writing 2 MB to the SD card, reading it back and checking, 405 times (SD DMA, the D$'s second port)

The 3 ran at the same time, with a load average around 3. NG 0, and no kernel warnings.

## Round 15: the triggers / Zicond / PMU version, and the vanishing SD card contents (2026-10-05)

The version with Sdtrig, Zicond and the PMU (`CPU_CORE_SPEC.md` decisions 67 to 69; WNS +0.452 ns). It
got stuck putting the new `fw_jump.bin` (a device tree declaring the extensions, OpenSBI's patch) and a
kernel `Image` with the settings for `perf` onto the SD card.

**1. The FAT became read-only.** `cp` gave `Read-only file system`. The kernel had found a FAT error and
remounted with `errors=remount-ro`. What was broken was `.fseventsd`, made by macOS (reading it gave
Input/output error).

**2. Written files disappeared.** The FAT was remade and the 3 files written with matching md5s, but
after reinserting the card they were gone, and macOS's `.Spotlight-V100` was there instead. The FAT time
stamps showed the order (Linux shows FAT times as UTC, so subtract 9 hours): macOS mounts the card
(21:20) → handed to the VM and written (21:23) → the VM lets go and the card returns to the Mac → macOS
writes back the old FAT and root directory from when it mounted (21:25). The same happened 3 times, and
once the write-back corrupted the directory. The card and partitions were fine; the cause was macOS's
stale mount. **The first partition is written from the Mac** from now on (`software/boot/README.md`).

**3. With FAT32 the BIOS does not find the files.** Remaking it with `mkfs.vfat` without `-F 16` gave
FAT32 at 512 MB, and the BIOS said `cannot open boot.json (FatFs error 4)`. Make it FAT16 as the procedure
says ("Making a new card" in `software/boot/README.md`).

**Result**: written from the Mac, it booted. OpenSBI showed `sscofpmf, zihpm, smcntrpmf, sdtrig`, `MHPM
Info: 4 (0x78)`, `Debug Triggers: 4`, and Linux `riscv-pmu-sbi: 16 firmware and 6 hardware counters`.
The benchmarks were the same as the previous version, and `perf stat` / `perf record` worked (section 13
of `BENCH.md`).

## Round 16: long stress test of the triggers / Zicond / PMU version (2026-10-06)

B4 (data triggers entering MR's exception path) and B5 (wiring of CSRs and performance events) changed
things, so the same `stress.sh` as round 14 ran for 120 minutes on the version of round 15 (WNS
+0.452 ns).

```
=== stress result (iterations, ok, ng) ===
mem 60 60 0
net 32 32 0
sd  424 424 0
=== new kernel messages that look like trouble ===
(none)
=== PASS ===
```

The 3 ran at the same time, with a load average around 3. NG 0, and no kernel warnings. The counts are
about the same as round 14 (58 / 33 / 405).

## Round 17: long stress test of the L2 cache version (2026-10-09)

The version with the L2 cache (`RTL/CPU/CPU_L2`, 256 KB, section 15 of `BENCH.md`, WNS +0.159 ns), which
also changed how the debug module handles halt after reset (`CPU_DBG_SPEC.md` 4.2). The boot went with
the same log as round 15 (OpenSBI's ISA extensions, `riscv-pmu-sbi: 16 firmware and 6 hardware
counters`, the SD card's ext4 mounted without recovery), and `stress.sh` ran for 120 minutes.

```
=== stress result (iterations, ok, ng) ===
mem 77 77 0
net 37 37 0
sd  503 503 0
=== new kernel messages that look like trouble ===
(none)
=== PASS ===
```

The load average was around 3, as in round 16, NG 0, and no kernel warnings. In the same 120 minutes it
did more rounds than round 16 (60 / 32 / 424): mem +28 %, net +16 %, sd +19 %. All are jobs that go
through the kernel a lot (checking files, TFTP, SD reads and writes), and the effect of the L2 (section
15 of `BENCH.md`) shows directly in the counts. The L2 is write-back and both DMA (SD, Ethernet) and CPU
writes go through it, but 2 hours of checking found no mismatch.

