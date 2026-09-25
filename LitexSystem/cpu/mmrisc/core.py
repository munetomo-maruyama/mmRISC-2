#
# mmRISC-2 core support for the LiteX SoC.
#
# The CPU is CPU_TOP of this repository: the pipeline, the L1 caches, the
# MMU, the CLINT, the PLIC and the JTAG debug module in one block. It
# presents two buses, which is what LiteX wants:
#
#   memory bus     AXI4       cache line bursts to LiteDRAM
#   peripheral bus AXI4-Lite  single beats, turned into Wishbone here
#   DMA bus        AXI4-Lite  a slave: the DMA masters of the SoC (the SD
#                             card) reach memory through the data cache,
#                             coherent with the CPU (CPU_DMA/DMA_CACHE)
#
# Everything below MEM_BASE leaves the caches on the peripheral bus, so the
# LiteX map falls out of a single boundary: the CSRs at 0x1200_0000 are
# uncached and main memory at 0x8000_0000 is cached.
#
# LiteX finds this file by itself: litex/soc/cores/cpu/__init__.py collects
# every directory holding a core.py, both in its own tree and in the
# working directory. Running the build from LitexSystem/cpu is enough, and
# the LiteX checkout stays untouched.
#

import os

from migen import *

from litex.gen import *

from litex.soc.interconnect import axi
from litex.soc.interconnect import wishbone

from litex.soc.integration.soc import SoCRegion

from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV64

# the root of this repository, from the real path of this file so that a
# symbolic link into the LiteX tree works as well
CPU_DIR  = os.path.dirname(os.path.realpath(__file__))
REPO_DIR = os.path.abspath(os.path.join(CPU_DIR, "..", "..", ".."))
RTL_DIR  = os.path.join(REPO_DIR, "RTL")

# The RTL in the order it has to be read. Vivado does not need it, but
# keeping one list means the simulation benches and the FPGA build cannot
# drift apart.
RTL_SOURCES = [
    "CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv",
    "CPU/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv",
    "CPU/CPU_DBG/DBG_DTM/DBG_DTM.sv",
    "CPU/CPU_DBG/DBG_DM/DBG_DM.sv",
    "CPU/CPU_DBG/DBG_HART_STUB/DBG_HART_STUB.sv",
    "CPU/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv",
    "CPU/CPU_DBG/CPU_DBG/CPU_DBG.sv",
    "CPU/CPU_DBG/DBG_CACHE/DBG_CACHE.sv",
    "CPU/CPU_CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv",
    "CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv",
    "CPU/CPU_CACHE/ICACHE/ICACHE.sv",
    "CPU/CPU_CACHE/DCACHE/DCACHE.sv",
    "CPU/CPU_CACHE/CACHE_PORT_ARB/CACHE_PORT_ARB.sv",
    "CPU/CPU_CACHE/CPU_CACHE/CPU_CACHE.sv",
    "CPU/CPU_MMU/MMU_PMP/MMU_PMP.sv",
    "CPU/CPU_MMU/MMU_TLB/MMU_TLB.sv",
    "CPU/CPU_MMU/MMU_PTW/MMU_PTW.sv",
    "CPU/CPU_MMU/CORE_MMU/CORE_MMU.sv",
    "CPU/CPU_CORE/CORE_DEC/CORE_DEC.sv",
    "CPU/CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv",
    "CPU/CPU_CORE/CORE_CSR/CORE_CSR.sv",
    "CPU/CPU_CORE/CORE_MDU/CORE_MDU.sv",
    "CPU/CPU_CORE/CORE_FRF/CORE_FRF.sv",
    "CPU/CPU_FPU/FPU_ROUND/FPU_ROUND.sv",
    "CPU/CPU_FPU/CORE_FPU/CORE_FPU.sv",
    "CPU/CPU_CORE/CORE_RF/CORE_RF.sv",
    "CPU/CPU_CORE/CORE_BTB/CORE_BTB.sv",
    "CPU/CPU_CORE/CORE_IFU/CORE_IFU.sv",
    "CPU/CPU_CORE/CORE_EXU/CORE_EXU.sv",
    "CPU/CPU_CORE/CORE_LSU/CORE_LSU.sv",
    "CPU/CPU_CORE/CPU_CORE/CPU_CORE.sv",
    "CPU/CPU_CLINT/CPU_CLINT.sv",
    "CPU/CPU_PLIC/CPU_PLIC.sv",
    "CPU/CPU_MMIO/CPU_MMIO.sv",
    "BUS/BUS_ARB/BUS_ARB.sv",
    "CPU/CPU_DMA/DMA_CACHE.sv",
    "CPU/CPU_BFM/CPU_BFM.sv",
    "CPU/CPU_TOP/CPU_TOP.sv",
]


class MMRISC(CPU):
    category             = "softcore"
    family               = "riscv"
    name                 = "mmrisc"
    human_name           = "mmRISC-2 (RV64GC)"
    variants             = ["standard"]
    data_width           = 64
    endianness           = "little"
    gcc_triple           = CPU_GCC_TRIPLE_RISCV64
    linker_output_format = "elf64-littleriscv"
    nop                  = "nop"

    # External interrupt lines of the PLIC.
    num_irq              = 32

    # mtime counts one step every CLINT_TICK_DIV cycles, so at 50 MHz this
    # gives the 500 kHz timebase the working Rocket build uses. The device
    # tree has to repeat the same number in timebase-frequency.
    clint_tick_div       = 100

    # The hardware has one boundary: everything below MEM_BASE is answered
    # on the peripheral bus and is never cached. That is stricter than what
    # is declared here, and deliberately so. LiteX refuses to place the ROM
    # in an IO region, so the ROM and the SRAM are declared cacheable even
    # though this CPU does not cache them; a flush of something that was
    # never cached costs a few cycles and nothing else. The declaration must
    # never go the other way -- calling a region cached that the hardware
    # does cache but LiteX thinks it does not would be a real bug.
    io_regions           = {0x1200_0000: 0x6e00_0000}  # Origin, Length.

    # The CLINT and the PLIC are inside the CPU, at the addresses the
    # privileged software expects; LiteX must not put anything there.
    @property
    def mem_map(self):
        return {
            "clint"    : 0x0200_0000,
            "plic"     : 0x0c00_0000,
            "rom"      : 0x1000_0000,
            "sram"     : 0x1100_0000,
            "csr"      : 0x1200_0000,
            "ethmac"   : 0x3000_0000,     # packet buffers, as in the Rocket build
            "main_ram" : 0x8000_0000,
        }

    @staticmethod
    def get_arch(variant="standard"):
        # the same shape as the Rocket wrapper uses, so the BIOS is built
        # with a -march string this toolchain is known to accept
        return "rv64i2p0_mafdc"

    @property
    def gcc_flags(self):
        flags =  "-mno-save-restore "
        flags += f"-march={self.get_arch(self.variant)} -mabi=lp64 "
        flags += "-D__mmrisc__ "
        flags += "-D__riscv_plic__ "
        flags += "-mcmodel=medany"
        return flags

    def __init__(self, platform, variant="standard"):
        self.platform  = platform
        self.variant   = variant

        self.reset     = Signal()
        # PLIC source s is driven by ext_irq[s] and source 0 does not exist,
        # so LiteX interrupt i becomes PLIC source i+1. That is the same
        # numbering the device tree of the Rocket build uses.
        self.interrupt = Signal(self.num_irq - 1)

        self.mem_axi    = mem_axi   = axi.AXIInterface(data_width=64, address_width=32, id_width=4)
        self.mmio_axil  = mmio_axil = axi.AXILiteInterface(data_width=64, address_width=32)
        self.mmio_wb    = mmio_wb   = wishbone.Interface(data_width=64,
                                          adr_width=32 - log2_int(64 // 8),
                                          addressing="word")

        self.memory_buses = [mem_axi]  # to LiteDRAM
        self.periph_buses = [mmio_wb]  # to the SoC bus

        # The DMA port. Declaring it makes LiteX put the DMA masters on it
        # instead of on the SoC bus, and define CPU_HAS_DMA_BUS, so the BIOS
        # skips its cache flushes after a transfer; Linux treats DMA as
        # coherent anyway. Without it the SD card wrote to memory behind the
        # data cache, and Linux read stale lines (docs/BRINGUP.md).
        self.dma_bus    = dma_axil  = axi.AXILiteInterface(data_width=64, address_width=32)

        # # #

        # CPU_TOP carries 40 bit addresses; LiteX works in 32. Every address
        # this SoC can produce is below 4 GB (the device tree puts memory at
        # 0x8000_0000), so the upper bits are always zero and dropping them
        # is safe. They are dropped here rather than in the RTL so that the
        # parameter keeps its natural value for other systems.
        awaddr_40 = Signal(40)
        araddr_40 = Signal(40)
        mmio_aw_40 = Signal(40)
        mmio_ar_40 = Signal(40)
        self.comb += [
            mem_axi.aw.addr.eq(awaddr_40),
            mem_axi.ar.addr.eq(araddr_40),
            mmio_axil.aw.addr.eq(mmio_aw_40),
            mmio_axil.ar.addr.eq(mmio_ar_40),
        ]

        self.cpu_params = dict(
            # Parameters.
            p_USE_BFM        = 0,
            p_NUM_IRQ        = self.num_irq,
            p_MEM_BASE       = self.mem_map["main_ram"],
            p_CLINT_BASE     = self.mem_map["clint"],
            p_PLIC_BASE      = self.mem_map["plic"],
            # mtime counts at a fixed rate; the device tree says the same
            # number in timebase-frequency.
            p_CLINT_TICK_DIV = self.clint_tick_div,

            # Clk / Rst.
            i_clk       = ClockSignal("sys"),
            i_rst_n     = ~(ResetSignal("sys") | self.reset),
            i_rst_dbg_n = ~(ResetSignal("sys") | self.reset),
            o_ndmreset  = Open(),

            # Interrupts: shifted up by one, PLIC source 0 does not exist.
            i_ext_irq = Cat(C(0, 1), self.interrupt),

            # Memory bus (AXI4).
            o_m_axi4_awid    = mem_axi.aw.id,
            o_m_axi4_awaddr  = awaddr_40,
            o_m_axi4_awlen   = mem_axi.aw.len,
            o_m_axi4_awsize  = mem_axi.aw.size,
            o_m_axi4_awburst = mem_axi.aw.burst,
            o_m_axi4_awlock  = mem_axi.aw.lock,
            o_m_axi4_awcache = mem_axi.aw.cache,
            o_m_axi4_awprot  = mem_axi.aw.prot,
            o_m_axi4_awqos   = mem_axi.aw.qos,
            o_m_axi4_awvalid = mem_axi.aw.valid,
            i_m_axi4_awready = mem_axi.aw.ready,

            o_m_axi4_wdata   = mem_axi.w.data,
            o_m_axi4_wstrb   = mem_axi.w.strb,
            o_m_axi4_wlast   = mem_axi.w.last,
            o_m_axi4_wvalid  = mem_axi.w.valid,
            i_m_axi4_wready  = mem_axi.w.ready,

            i_m_axi4_bid     = mem_axi.b.id,
            i_m_axi4_bresp   = mem_axi.b.resp,
            i_m_axi4_bvalid  = mem_axi.b.valid,
            o_m_axi4_bready  = mem_axi.b.ready,

            o_m_axi4_arid    = mem_axi.ar.id,
            o_m_axi4_araddr  = araddr_40,
            o_m_axi4_arlen   = mem_axi.ar.len,
            o_m_axi4_arsize  = mem_axi.ar.size,
            o_m_axi4_arburst = mem_axi.ar.burst,
            o_m_axi4_arlock  = mem_axi.ar.lock,
            o_m_axi4_arcache = mem_axi.ar.cache,
            o_m_axi4_arprot  = mem_axi.ar.prot,
            o_m_axi4_arqos   = mem_axi.ar.qos,
            o_m_axi4_arvalid = mem_axi.ar.valid,
            i_m_axi4_arready = mem_axi.ar.ready,

            i_m_axi4_rid     = mem_axi.r.id,
            i_m_axi4_rdata   = mem_axi.r.data,
            i_m_axi4_rresp   = mem_axi.r.resp,
            i_m_axi4_rlast   = mem_axi.r.last,
            i_m_axi4_rvalid  = mem_axi.r.valid,
            o_m_axi4_rready  = mem_axi.r.ready,

            # Peripheral bus (AXI4-Lite).
            o_m_axil_awaddr  = mmio_aw_40,
            o_m_axil_awprot  = mmio_axil.aw.prot,
            o_m_axil_awvalid = mmio_axil.aw.valid,
            i_m_axil_awready = mmio_axil.aw.ready,

            o_m_axil_wdata   = mmio_axil.w.data,
            o_m_axil_wstrb   = mmio_axil.w.strb,
            o_m_axil_wvalid  = mmio_axil.w.valid,
            i_m_axil_wready  = mmio_axil.w.ready,

            i_m_axil_bresp   = mmio_axil.b.resp,
            i_m_axil_bvalid  = mmio_axil.b.valid,
            o_m_axil_bready  = mmio_axil.b.ready,

            o_m_axil_araddr  = mmio_ar_40,
            o_m_axil_arprot  = mmio_axil.ar.prot,
            o_m_axil_arvalid = mmio_axil.ar.valid,
            i_m_axil_arready = mmio_axil.ar.ready,

            i_m_axil_rdata   = mmio_axil.r.data,
            i_m_axil_rresp   = mmio_axil.r.resp,
            i_m_axil_rvalid  = mmio_axil.r.valid,
            o_m_axil_rready  = mmio_axil.r.ready,

            # DMA bus (AXI4-Lite slave), 32 bit addresses made 40 bit.
            i_s_dma_awaddr   = Cat(dma_axil.aw.addr, C(0, 8)),
            i_s_dma_awvalid  = dma_axil.aw.valid,
            o_s_dma_awready  = dma_axil.aw.ready,
            i_s_dma_wdata    = dma_axil.w.data,
            i_s_dma_wstrb    = dma_axil.w.strb,
            i_s_dma_wvalid   = dma_axil.w.valid,
            o_s_dma_wready   = dma_axil.w.ready,
            o_s_dma_bresp    = dma_axil.b.resp,
            o_s_dma_bvalid   = dma_axil.b.valid,
            i_s_dma_bready   = dma_axil.b.ready,
            i_s_dma_araddr   = Cat(dma_axil.ar.addr, C(0, 8)),
            i_s_dma_arvalid  = dma_axil.ar.valid,
            o_s_dma_arready  = dma_axil.ar.ready,
            o_s_dma_rdata    = dma_axil.r.data,
            o_s_dma_rresp    = dma_axil.r.resp,
            o_s_dma_rvalid   = dma_axil.r.valid,
            i_s_dma_rready   = dma_axil.r.ready,

            # JTAG : not wired to pins yet (see docs/JTAG.md).
            i_jtag_tck     = 0,
            i_jtag_tms_i   = 0,
            o_jtag_tms_o   = Open(),
            o_jtag_tms_oe  = Open(),
            i_jtag_tdi     = 0,
            o_jtag_tdo     = Open(),
            o_jtag_tdo_oe  = Open(),
            i_jtag_trst_n  = 1,
            i_cjtag_en     = 0,
            o_cjtag_online = Open(),
            i_dbg_auth_en  = 0,
            i_dbg_auth_key = 0,
            o_dbg_halted   = Open(),
            o_dbg_running  = Open(),
            o_dbg_dmactive = Open(),
        )

        # The peripheral bus reaches the SoC as Wishbone.
        self.submodules += axi.AXILite2Wishbone(mmio_axil, mmio_wb, base_address=0)

        self.add_sources(platform)

    # the reset vector is a parameter, so LiteX may put it where it likes
    def set_reset_address(self, reset_address):
        self.reset_address = reset_address
        self.cpu_params.update(p_RESET_VECTOR=reset_address)

    @staticmethod
    def add_sources(platform):
        for src in RTL_SOURCES:
            platform.add_source(os.path.join(RTL_DIR, src))

    def add_soc_components(self, soc):
        # The regions the privileged software needs to see. The CLINT and
        # the PLIC are inside the CPU, so nothing of LiteX answers there;
        # they are declared only so the map and the device tree agree.
        soc.bus.add_region("opensbi", SoCRegion(
            origin=self.mem_map["main_ram"], size=0x20_0000, cached=True, linker=True))
        # cached=True for the same reason as the ROM above: these sit below
        # the IO region LiteX knows about, and the hardware does not cache
        # them whatever this says
        soc.bus.add_region("plic", SoCRegion(
            origin=soc.mem_map.get("plic"),  size=0x40_0000, cached=True, linker=True))
        soc.bus.add_region("clint", SoCRegion(
            origin=soc.mem_map.get("clint"), size=0x1_0000,  cached=True, linker=True))

        soc.add_config("CPU_COUNT", 1)
        soc.add_config("CPU_ISA",   self.get_arch(self.variant))
        soc.add_config("CPU_MMU",   "sv39")

        # What the caches and the TLBs really are (CPU_CACHE_SPEC.md 3,
        # CPU_CORE_SPEC.md 6), so the device tree does not have to guess.
        soc.add_config("CPU_DCACHE_SIZE",       64 * 4 * 64)
        soc.add_config("CPU_DCACHE_WAYS",       4)
        soc.add_config("CPU_DCACHE_BLOCK_SIZE", 64)
        soc.add_config("CPU_ICACHE_SIZE",       64 * 4 * 64)
        soc.add_config("CPU_ICACHE_WAYS",       4)
        soc.add_config("CPU_ICACHE_BLOCK_SIZE", 64)

        # fully associative, so the number of sets is one
        soc.add_config("CPU_DTLB_SIZE", 16)
        soc.add_config("CPU_DTLB_WAYS", 16)
        soc.add_config("CPU_ITLB_SIZE", 16)
        soc.add_config("CPU_ITLB_WAYS", 16)

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        self.specials += Instance("CPU_TOP", **self.cpu_params)
