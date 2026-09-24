//---------------------------------------------------------------------------
// tb_CPU_TOP.sv
//
// Top-level testbench for the mmRISC-2 CPU (CPU_TOP).
//
// Topology (mimics the integration into a 32-bit SoC such as LiteX):
//
//   CPU_TOP --40bit AXI4------> AXI4_ADDR_NARROW --32bit--> AXI4_SLAVE_MEM  @ 0x8000_0000
//           --40bit AXI4-Lite-> AXIL_ADDR_NARROW --32bit--> AXIL_SLAVE_MEM  @ 0x1200_0000
//
//   The ADDR_NARROW bridges pass a transaction through when the upper
//   address bits [39:32] are zero, and return DECERR otherwise.
//
//   - 100MHz clock generation, power-on reset generation
//   - Both memories are initialised with a value that increments with the
//     word address, with a different base per bus so that a transaction
//     landing on the wrong bus is immediately visible.
//
// The CPU core does not exist yet, so the buses are driven by CPU_BFM,
// a temporary bus function model instantiated inside CPU_TOP. This
// testbench controls it through hierarchical references to its command
// variables (u_cpu_top.g_bfm.u_cpu_bfm.cmd_*).
//
// Test items
//   1-6  : basic single / short-burst access on both buses
//   7    : AXI4 burst length sweep 1..256 beats, random data
//   8    : AXI4 256-beat bursts at 4KB page edges
//   9    : AXI4 burst length sweep with random READY/VALID stalls
//   10   : AXI4-Lite 256 consecutive single-beat accesses
//   11   : same as 10 with random READY/VALID stalls
//   12   : self-test of the AXI4 4KB-crossing protocol checker
//   13   : AXI4      upper address bits [39:32], walking one -> DECERR
//   14   : AXI4      bursts (2/16/256 beats) with upper bits -> DECERR
//   15   : AXI4-Lite upper address bits [39:32], walking one -> DECERR
//   16   : interleaved DECERR / normal accesses on both buses with stalls
//   17   : AXI4      8/16/32-bit lanes by AxSIZE, lane by lane
//   18   : AXI4      8/16/32-bit lanes by WSTRB (AxSIZE=64bit), WSTRB=0
//   19   : AXI4      write width x read width matrix (8..64bit), by AxSIZE
//   20   : AXI4      write width x read width matrix (8..64bit), by WSTRB
//   21   : AXI4      narrow INCR bursts (8/16/32-bit beats, up to 256 beats,
//                    word-crossing and unaligned start)
//   22   : same as 21 with random READY/VALID stalls
//   23   : AXI4      random width / lane / strobe regression with stalls
//   24   : AXI4-Lite 8/16/32-bit lanes by WSTRB, lane by lane, WSTRB=0
//   25   : AXI4-Lite write width x read width matrix (8..64bit)
//   26   : AXI4-Lite random strobe / lane regression with stalls
//
// Checks performed on every transaction
//   - the address seen on the CPU_TOP port equals the commanded 40-bit
//     address (all upper bits are really carried out of CPU_TOP), and for
//     AXI4 the AxSIZE equals the commanded operand width
//   - data lanes outside the written lanes carry random garbage, so a write
//     to a wrong lane always shows up in a later read
//   - RLAST is asserted on, and only on, the final R beat
//   - every read is compared against shadow memories mirroring all writes
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_CPU_TOP;

    //-----------------------------------------------------------------
    // Parameters
    //-----------------------------------------------------------------
    localparam int AXI4_ID_WIDTH   = 4;
    localparam int AXI4_ADDR_WIDTH = 40;               // CPU side
    localparam int AXI4_DATA_WIDTH = 64;
    localparam int AXIL_ADDR_WIDTH = 40;               // CPU side
    localparam int AXIL_DATA_WIDTH = 64;
    localparam int SOC_ADDR_WIDTH  = 32;               // SoC side (LiteX)
    localparam int NUM_IRQ         = 32;

    localparam int MEM_DEPTH  = 32768;                 // words per memory (256KiB = 64 x 4KB pages)
    localparam int PAGE_WORDS = 512;                   // words per 4KB page (64bit word)

    localparam logic [39:0] MEM_BASE    = 40'h00_8000_0000;   // memory bus     (AXI4)
    localparam logic [39:0] PERIPH_BASE = 40'h00_1200_0000;   // peripheral bus (AXI4-Lite)

    // Initial data base value of each memory (content = base + word index)
    localparam logic [63:0] MEM_INIT_BASE    = 64'h0000_0000_0000_0000;
    localparam logic [63:0] PERIPH_INIT_BASE = 64'h1111_0000_0000_0000;

    // Clock : 100MHz
    localparam real CLK_PERIOD = 10.0;                 // ns

    // BFM command encoding
    localparam bit CMD_RD  = 1'b0;
    localparam bit CMD_WR  = 1'b1;
    localparam bit BUS_MEM = 1'b0;
    localparam bit BUS_PER = 1'b1;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    // AXI4 AxSIZE codes (operand width)
    localparam logic [2:0] SIZE_8  = 3'd0;
    localparam logic [2:0] SIZE_16 = 3'd1;
    localparam logic [2:0] SIZE_32 = 3'd2;
    localparam logic [2:0] SIZE_64 = 3'd3;

    //-----------------------------------------------------------------
    // Clock and Reset
    //-----------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2.0) clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        $display("[%0t] Reset released", $time);
    end

    //-----------------------------------------------------------------
    // CPU side : Memory Bus (AXI4, 40-bit address)
    //-----------------------------------------------------------------
    logic [AXI4_ID_WIDTH-1:0]     m_axi4_awid;
    logic [AXI4_ADDR_WIDTH-1:0]   m_axi4_awaddr;
    logic [7:0]                   m_axi4_awlen;
    logic [2:0]                   m_axi4_awsize;
    logic [1:0]                   m_axi4_awburst;
    logic                         m_axi4_awlock;
    logic [3:0]                   m_axi4_awcache;
    logic [2:0]                   m_axi4_awprot;
    logic [3:0]                   m_axi4_awqos;
    logic                         m_axi4_awvalid;
    logic                         m_axi4_awready;

    logic [AXI4_DATA_WIDTH-1:0]   m_axi4_wdata;
    logic [AXI4_DATA_WIDTH/8-1:0] m_axi4_wstrb;
    logic                         m_axi4_wlast;
    logic                         m_axi4_wvalid;
    logic                         m_axi4_wready;

    logic [AXI4_ID_WIDTH-1:0]     m_axi4_bid;
    logic [1:0]                   m_axi4_bresp;
    logic                         m_axi4_bvalid;
    logic                         m_axi4_bready;

    logic [AXI4_ID_WIDTH-1:0]     m_axi4_arid;
    logic [AXI4_ADDR_WIDTH-1:0]   m_axi4_araddr;
    logic [7:0]                   m_axi4_arlen;
    logic [2:0]                   m_axi4_arsize;
    logic [1:0]                   m_axi4_arburst;
    logic                         m_axi4_arlock;
    logic [3:0]                   m_axi4_arcache;
    logic [2:0]                   m_axi4_arprot;
    logic [3:0]                   m_axi4_arqos;
    logic                         m_axi4_arvalid;
    logic                         m_axi4_arready;

    logic [AXI4_ID_WIDTH-1:0]     m_axi4_rid;
    logic [AXI4_DATA_WIDTH-1:0]   m_axi4_rdata;
    logic [1:0]                   m_axi4_rresp;
    logic                         m_axi4_rlast;
    logic                         m_axi4_rvalid;
    logic                         m_axi4_rready;

    //-----------------------------------------------------------------
    // CPU side : Peripheral Bus (AXI4-Lite, 40-bit address)
    //-----------------------------------------------------------------
    logic [AXIL_ADDR_WIDTH-1:0]   m_axil_awaddr;
    logic [2:0]                   m_axil_awprot;
    logic                         m_axil_awvalid;
    logic                         m_axil_awready;

    logic [AXIL_DATA_WIDTH-1:0]   m_axil_wdata;
    logic [AXIL_DATA_WIDTH/8-1:0] m_axil_wstrb;
    logic                         m_axil_wvalid;
    logic                         m_axil_wready;

    logic [1:0]                   m_axil_bresp;
    logic                         m_axil_bvalid;
    logic                         m_axil_bready;

    logic [AXIL_ADDR_WIDTH-1:0]   m_axil_araddr;
    logic [2:0]                   m_axil_arprot;
    logic                         m_axil_arvalid;
    logic                         m_axil_arready;

    logic [AXIL_DATA_WIDTH-1:0]   m_axil_rdata;
    logic [1:0]                   m_axil_rresp;
    logic                         m_axil_rvalid;
    logic                         m_axil_rready;

    //-----------------------------------------------------------------
    // SoC side : Memory Bus (AXI4, 32-bit address)
    //-----------------------------------------------------------------
    logic [AXI4_ID_WIDTH-1:0]     mem_axi4_awid;
    logic [SOC_ADDR_WIDTH-1:0]    mem_axi4_awaddr;
    logic [7:0]                   mem_axi4_awlen;
    logic [2:0]                   mem_axi4_awsize;
    logic [1:0]                   mem_axi4_awburst;
    logic                         mem_axi4_awlock;
    logic [3:0]                   mem_axi4_awcache;
    logic [2:0]                   mem_axi4_awprot;
    logic [3:0]                   mem_axi4_awqos;
    logic                         mem_axi4_awvalid;
    logic                         mem_axi4_awready;

    logic [AXI4_DATA_WIDTH-1:0]   mem_axi4_wdata;
    logic [AXI4_DATA_WIDTH/8-1:0] mem_axi4_wstrb;
    logic                         mem_axi4_wlast;
    logic                         mem_axi4_wvalid;
    logic                         mem_axi4_wready;

    logic [AXI4_ID_WIDTH-1:0]     mem_axi4_bid;
    logic [1:0]                   mem_axi4_bresp;
    logic                         mem_axi4_bvalid;
    logic                         mem_axi4_bready;

    logic [AXI4_ID_WIDTH-1:0]     mem_axi4_arid;
    logic [SOC_ADDR_WIDTH-1:0]    mem_axi4_araddr;
    logic [7:0]                   mem_axi4_arlen;
    logic [2:0]                   mem_axi4_arsize;
    logic [1:0]                   mem_axi4_arburst;
    logic                         mem_axi4_arlock;
    logic [3:0]                   mem_axi4_arcache;
    logic [2:0]                   mem_axi4_arprot;
    logic [3:0]                   mem_axi4_arqos;
    logic                         mem_axi4_arvalid;
    logic                         mem_axi4_arready;

    logic [AXI4_ID_WIDTH-1:0]     mem_axi4_rid;
    logic [AXI4_DATA_WIDTH-1:0]   mem_axi4_rdata;
    logic [1:0]                   mem_axi4_rresp;
    logic                         mem_axi4_rlast;
    logic                         mem_axi4_rvalid;
    logic                         mem_axi4_rready;

    //-----------------------------------------------------------------
    // SoC side : Peripheral Bus (AXI4-Lite, 32-bit address)
    //-----------------------------------------------------------------
    logic [SOC_ADDR_WIDTH-1:0]    per_axil_awaddr;
    logic [2:0]                   per_axil_awprot;
    logic                         per_axil_awvalid;
    logic                         per_axil_awready;

    logic [AXIL_DATA_WIDTH-1:0]   per_axil_wdata;
    logic [AXIL_DATA_WIDTH/8-1:0] per_axil_wstrb;
    logic                         per_axil_wvalid;
    logic                         per_axil_wready;

    logic [1:0]                   per_axil_bresp;
    logic                         per_axil_bvalid;
    logic                         per_axil_bready;

    logic [SOC_ADDR_WIDTH-1:0]    per_axil_araddr;
    logic [2:0]                   per_axil_arprot;
    logic                         per_axil_arvalid;
    logic                         per_axil_arready;

    logic [AXIL_DATA_WIDTH-1:0]   per_axil_rdata;
    logic [1:0]                   per_axil_rresp;
    logic                         per_axil_rvalid;
    logic                         per_axil_rready;

    //-----------------------------------------------------------------
    // Other CPU_TOP signals
    //-----------------------------------------------------------------
    logic [NUM_IRQ-1:0] ext_irq;
    logic               jtag_tck;
    logic               jtag_tms_i;
    logic               jtag_tms_o;
    logic               jtag_tms_oe;
    logic               jtag_tdi;
    logic               jtag_tdo;
    logic               jtag_tdo_oe;
    logic               jtag_trst_n;
    logic               cjtag_online;
    logic               ndmreset;
    logic               dbg_halted;
    logic               dbg_running;
    logic               dbg_dmactive;

    // The debug logic is verified in SIM/SIM_DBG; here JTAG is left idle.
    initial begin
        ext_irq     = '0;
        jtag_tck    = 1'b0;
        jtag_tms_i  = 1'b1;
        jtag_tdi    = 1'b0;
        jtag_trst_n = 1'b0;
    end

    //-----------------------------------------------------------------
    // DUT : CPU_TOP
    //-----------------------------------------------------------------
    CPU_TOP
        #(
            .AXI4_ID_WIDTH   (AXI4_ID_WIDTH),
            .AXI4_ADDR_WIDTH (AXI4_ADDR_WIDTH),
            .AXI4_DATA_WIDTH (AXI4_DATA_WIDTH),
            .AXIL_ADDR_WIDTH (AXIL_ADDR_WIDTH),
            .AXIL_DATA_WIDTH (AXIL_DATA_WIDTH),
            .NUM_IRQ         (NUM_IRQ)
        )
    u_cpu_top
        (
            .clk             (clk),
            .rst_n           (rst_n),
            .rst_dbg_n       (rst_n),
            .ndmreset        (ndmreset),

            .m_axi4_awid     (m_axi4_awid),
            .m_axi4_awaddr   (m_axi4_awaddr),
            .m_axi4_awlen    (m_axi4_awlen),
            .m_axi4_awsize   (m_axi4_awsize),
            .m_axi4_awburst  (m_axi4_awburst),
            .m_axi4_awlock   (m_axi4_awlock),
            .m_axi4_awcache  (m_axi4_awcache),
            .m_axi4_awprot   (m_axi4_awprot),
            .m_axi4_awqos    (m_axi4_awqos),
            .m_axi4_awvalid  (m_axi4_awvalid),
            .m_axi4_awready  (m_axi4_awready),

            .m_axi4_wdata    (m_axi4_wdata),
            .m_axi4_wstrb    (m_axi4_wstrb),
            .m_axi4_wlast    (m_axi4_wlast),
            .m_axi4_wvalid   (m_axi4_wvalid),
            .m_axi4_wready   (m_axi4_wready),

            .m_axi4_bid      (m_axi4_bid),
            .m_axi4_bresp    (m_axi4_bresp),
            .m_axi4_bvalid   (m_axi4_bvalid),
            .m_axi4_bready   (m_axi4_bready),

            .m_axi4_arid     (m_axi4_arid),
            .m_axi4_araddr   (m_axi4_araddr),
            .m_axi4_arlen    (m_axi4_arlen),
            .m_axi4_arsize   (m_axi4_arsize),
            .m_axi4_arburst  (m_axi4_arburst),
            .m_axi4_arlock   (m_axi4_arlock),
            .m_axi4_arcache  (m_axi4_arcache),
            .m_axi4_arprot   (m_axi4_arprot),
            .m_axi4_arqos    (m_axi4_arqos),
            .m_axi4_arvalid  (m_axi4_arvalid),
            .m_axi4_arready  (m_axi4_arready),

            .m_axi4_rid      (m_axi4_rid),
            .m_axi4_rdata    (m_axi4_rdata),
            .m_axi4_rresp    (m_axi4_rresp),
            .m_axi4_rlast    (m_axi4_rlast),
            .m_axi4_rvalid   (m_axi4_rvalid),
            .m_axi4_rready   (m_axi4_rready),

            .m_axil_awaddr   (m_axil_awaddr),
            .m_axil_awprot   (m_axil_awprot),
            .m_axil_awvalid  (m_axil_awvalid),
            .m_axil_awready  (m_axil_awready),

            .m_axil_wdata    (m_axil_wdata),
            .m_axil_wstrb    (m_axil_wstrb),
            .m_axil_wvalid   (m_axil_wvalid),
            .m_axil_wready   (m_axil_wready),

            .m_axil_bresp    (m_axil_bresp),
            .m_axil_bvalid   (m_axil_bvalid),
            .m_axil_bready   (m_axil_bready),

            .m_axil_araddr   (m_axil_araddr),
            .m_axil_arprot   (m_axil_arprot),
            .m_axil_arvalid  (m_axil_arvalid),
            .m_axil_arready  (m_axil_arready),

            .m_axil_rdata    (m_axil_rdata),
            .m_axil_rresp    (m_axil_rresp),
            .m_axil_rvalid   (m_axil_rvalid),
            .m_axil_rready   (m_axil_rready),

            // the DMA port : not used here
            .s_dma_awaddr   ('0),
            .s_dma_awvalid  (1'b0),
            .s_dma_awready  (),
            .s_dma_wdata    (64'd0),
            .s_dma_wstrb    (8'd0),
            .s_dma_wvalid   (1'b0),
            .s_dma_wready   (),
            .s_dma_bresp    (),
            .s_dma_bvalid   (),
            .s_dma_bready   (1'b1),
            .s_dma_araddr   ('0),
            .s_dma_arvalid  (1'b0),
            .s_dma_arready  (),
            .s_dma_rdata    (),
            .s_dma_rresp    (),
            .s_dma_rvalid   (),
            .s_dma_rready   (1'b1),
            .ext_irq         (ext_irq),

            .jtag_tck        (jtag_tck),
            .jtag_tms_i      (jtag_tms_i),
            .jtag_tms_o      (jtag_tms_o),
            .jtag_tms_oe     (jtag_tms_oe),
            .jtag_tdi        (jtag_tdi),
            .jtag_tdo        (jtag_tdo),
            .jtag_tdo_oe     (jtag_tdo_oe),
            .jtag_trst_n     (jtag_trst_n),
            .cjtag_en        (1'b0),
            .cjtag_online    (cjtag_online),
            .dbg_auth_en     (1'b0),
            .dbg_auth_key    (32'hbeefcafe),
            .dbg_halted      (dbg_halted),
            .dbg_running     (dbg_running),
            .dbg_dmactive    (dbg_dmactive)
        );

    //-----------------------------------------------------------------
    // Address narrowing bridge : Memory Bus (40-bit -> 32-bit)
    //-----------------------------------------------------------------
    AXI4_ADDR_NARROW
        #(
            .ID_WIDTH     (AXI4_ID_WIDTH),
            .S_ADDR_WIDTH (AXI4_ADDR_WIDTH),
            .M_ADDR_WIDTH (SOC_ADDR_WIDTH),
            .DATA_WIDTH   (AXI4_DATA_WIDTH)
        )
    u_narrow_axi4
        (
            .clk       (clk),
            .rst_n     (rst_n),

            .s_awid    (m_axi4_awid),
            .s_awaddr  (m_axi4_awaddr),
            .s_awlen   (m_axi4_awlen),
            .s_awsize  (m_axi4_awsize),
            .s_awburst (m_axi4_awburst),
            .s_awlock  (m_axi4_awlock),
            .s_awcache (m_axi4_awcache),
            .s_awprot  (m_axi4_awprot),
            .s_awqos   (m_axi4_awqos),
            .s_awvalid (m_axi4_awvalid),
            .s_awready (m_axi4_awready),
            .s_wdata   (m_axi4_wdata),
            .s_wstrb   (m_axi4_wstrb),
            .s_wlast   (m_axi4_wlast),
            .s_wvalid  (m_axi4_wvalid),
            .s_wready  (m_axi4_wready),
            .s_bid     (m_axi4_bid),
            .s_bresp   (m_axi4_bresp),
            .s_bvalid  (m_axi4_bvalid),
            .s_bready  (m_axi4_bready),
            .s_arid    (m_axi4_arid),
            .s_araddr  (m_axi4_araddr),
            .s_arlen   (m_axi4_arlen),
            .s_arsize  (m_axi4_arsize),
            .s_arburst (m_axi4_arburst),
            .s_arlock  (m_axi4_arlock),
            .s_arcache (m_axi4_arcache),
            .s_arprot  (m_axi4_arprot),
            .s_arqos   (m_axi4_arqos),
            .s_arvalid (m_axi4_arvalid),
            .s_arready (m_axi4_arready),
            .s_rid     (m_axi4_rid),
            .s_rdata   (m_axi4_rdata),
            .s_rresp   (m_axi4_rresp),
            .s_rlast   (m_axi4_rlast),
            .s_rvalid  (m_axi4_rvalid),
            .s_rready  (m_axi4_rready),

            .m_awid    (mem_axi4_awid),
            .m_awaddr  (mem_axi4_awaddr),
            .m_awlen   (mem_axi4_awlen),
            .m_awsize  (mem_axi4_awsize),
            .m_awburst (mem_axi4_awburst),
            .m_awlock  (mem_axi4_awlock),
            .m_awcache (mem_axi4_awcache),
            .m_awprot  (mem_axi4_awprot),
            .m_awqos   (mem_axi4_awqos),
            .m_awvalid (mem_axi4_awvalid),
            .m_awready (mem_axi4_awready),
            .m_wdata   (mem_axi4_wdata),
            .m_wstrb   (mem_axi4_wstrb),
            .m_wlast   (mem_axi4_wlast),
            .m_wvalid  (mem_axi4_wvalid),
            .m_wready  (mem_axi4_wready),
            .m_bid     (mem_axi4_bid),
            .m_bresp   (mem_axi4_bresp),
            .m_bvalid  (mem_axi4_bvalid),
            .m_bready  (mem_axi4_bready),
            .m_arid    (mem_axi4_arid),
            .m_araddr  (mem_axi4_araddr),
            .m_arlen   (mem_axi4_arlen),
            .m_arsize  (mem_axi4_arsize),
            .m_arburst (mem_axi4_arburst),
            .m_arlock  (mem_axi4_arlock),
            .m_arcache (mem_axi4_arcache),
            .m_arprot  (mem_axi4_arprot),
            .m_arqos   (mem_axi4_arqos),
            .m_arvalid (mem_axi4_arvalid),
            .m_arready (mem_axi4_arready),
            .m_rid     (mem_axi4_rid),
            .m_rdata   (mem_axi4_rdata),
            .m_rresp   (mem_axi4_rresp),
            .m_rlast   (mem_axi4_rlast),
            .m_rvalid  (mem_axi4_rvalid),
            .m_rready  (mem_axi4_rready)
        );

    //-----------------------------------------------------------------
    // Address narrowing bridge : Peripheral Bus (40-bit -> 32-bit)
    //-----------------------------------------------------------------
    AXIL_ADDR_NARROW
        #(
            .S_ADDR_WIDTH (AXIL_ADDR_WIDTH),
            .M_ADDR_WIDTH (SOC_ADDR_WIDTH),
            .DATA_WIDTH   (AXIL_DATA_WIDTH)
        )
    u_narrow_axil
        (
            .clk       (clk),
            .rst_n     (rst_n),

            .s_awaddr  (m_axil_awaddr),
            .s_awprot  (m_axil_awprot),
            .s_awvalid (m_axil_awvalid),
            .s_awready (m_axil_awready),
            .s_wdata   (m_axil_wdata),
            .s_wstrb   (m_axil_wstrb),
            .s_wvalid  (m_axil_wvalid),
            .s_wready  (m_axil_wready),
            .s_bresp   (m_axil_bresp),
            .s_bvalid  (m_axil_bvalid),
            .s_bready  (m_axil_bready),
            .s_araddr  (m_axil_araddr),
            .s_arprot  (m_axil_arprot),
            .s_arvalid (m_axil_arvalid),
            .s_arready (m_axil_arready),
            .s_rdata   (m_axil_rdata),
            .s_rresp   (m_axil_rresp),
            .s_rvalid  (m_axil_rvalid),
            .s_rready  (m_axil_rready),

            .m_awaddr  (per_axil_awaddr),
            .m_awprot  (per_axil_awprot),
            .m_awvalid (per_axil_awvalid),
            .m_awready (per_axil_awready),
            .m_wdata   (per_axil_wdata),
            .m_wstrb   (per_axil_wstrb),
            .m_wvalid  (per_axil_wvalid),
            .m_wready  (per_axil_wready),
            .m_bresp   (per_axil_bresp),
            .m_bvalid  (per_axil_bvalid),
            .m_bready  (per_axil_bready),
            .m_araddr  (per_axil_araddr),
            .m_arprot  (per_axil_arprot),
            .m_arvalid (per_axil_arvalid),
            .m_arready (per_axil_arready),
            .m_rdata   (per_axil_rdata),
            .m_rresp   (per_axil_rresp),
            .m_rvalid  (per_axil_rvalid),
            .m_rready  (per_axil_rready)
        );

    //-----------------------------------------------------------------
    // Slave Memory : Memory Bus (AXI4, 32-bit address)
    //-----------------------------------------------------------------
    AXI4_SLAVE_MEM
        #(
            .ID_WIDTH   (AXI4_ID_WIDTH),
            .ADDR_WIDTH (SOC_ADDR_WIDTH),
            .DATA_WIDTH (AXI4_DATA_WIDTH),
            .DEPTH      (MEM_DEPTH),
            .BASE_ADDR  (MEM_BASE[SOC_ADDR_WIDTH-1:0]),
            .INIT_BASE  (MEM_INIT_BASE)
        )
    u_mem_axi4
        (
            .clk     (clk),
            .rst_n   (rst_n),

            .awid    (mem_axi4_awid),
            .awaddr  (mem_axi4_awaddr),
            .awlen   (mem_axi4_awlen),
            .awsize  (mem_axi4_awsize),
            .awburst (mem_axi4_awburst),
            .awlock  (mem_axi4_awlock),
            .awcache (mem_axi4_awcache),
            .awprot  (mem_axi4_awprot),
            .awqos   (mem_axi4_awqos),
            .awvalid (mem_axi4_awvalid),
            .awready (mem_axi4_awready),

            .wdata   (mem_axi4_wdata),
            .wstrb   (mem_axi4_wstrb),
            .wlast   (mem_axi4_wlast),
            .wvalid  (mem_axi4_wvalid),
            .wready  (mem_axi4_wready),

            .bid     (mem_axi4_bid),
            .bresp   (mem_axi4_bresp),
            .bvalid  (mem_axi4_bvalid),
            .bready  (mem_axi4_bready),

            .arid    (mem_axi4_arid),
            .araddr  (mem_axi4_araddr),
            .arlen   (mem_axi4_arlen),
            .arsize  (mem_axi4_arsize),
            .arburst (mem_axi4_arburst),
            .arlock  (mem_axi4_arlock),
            .arcache (mem_axi4_arcache),
            .arprot  (mem_axi4_arprot),
            .arqos   (mem_axi4_arqos),
            .arvalid (mem_axi4_arvalid),
            .arready (mem_axi4_arready),

            .rid     (mem_axi4_rid),
            .rdata   (mem_axi4_rdata),
            .rresp   (mem_axi4_rresp),
            .rlast   (mem_axi4_rlast),
            .rvalid  (mem_axi4_rvalid),
            .rready  (mem_axi4_rready)
        );

    //-----------------------------------------------------------------
    // Slave Memory : Peripheral Bus (AXI4-Lite, 32-bit address)
    //-----------------------------------------------------------------
    AXIL_SLAVE_MEM
        #(
            .ADDR_WIDTH (SOC_ADDR_WIDTH),
            .DATA_WIDTH (AXIL_DATA_WIDTH),
            .DEPTH      (MEM_DEPTH),
            .BASE_ADDR  (PERIPH_BASE[SOC_ADDR_WIDTH-1:0]),
            .INIT_BASE  (PERIPH_INIT_BASE)
        )
    u_mem_axil
        (
            .clk     (clk),
            .rst_n   (rst_n),

            .awaddr  (per_axil_awaddr),
            .awprot  (per_axil_awprot),
            .awvalid (per_axil_awvalid),
            .awready (per_axil_awready),

            .wdata   (per_axil_wdata),
            .wstrb   (per_axil_wstrb),
            .wvalid  (per_axil_wvalid),
            .wready  (per_axil_wready),

            .bresp   (per_axil_bresp),
            .bvalid  (per_axil_bvalid),
            .bready  (per_axil_bready),

            .araddr  (per_axil_araddr),
            .arprot  (per_axil_arprot),
            .arvalid (per_axil_arvalid),
            .arready (per_axil_arready),

            .rdata   (per_axil_rdata),
            .rresp   (per_axil_rresp),
            .rvalid  (per_axil_rvalid),
            .rready  (per_axil_rready)
        );

    //-----------------------------------------------------------------
    // Bus monitors at the CPU_TOP ports (40-bit side)
    //-----------------------------------------------------------------
    wire mon4_aw_hs = m_axi4_awvalid & m_axi4_awready;
    wire mon4_w_hs  = m_axi4_wvalid  & m_axi4_wready;
    wire mon4_ar_hs = m_axi4_arvalid & m_axi4_arready;
    wire mon4_r_hs  = m_axi4_rvalid  & m_axi4_rready;
    wire monl_aw_hs = m_axil_awvalid & m_axil_awready;
    wire monl_ar_hs = m_axil_arvalid & m_axil_arready;

    logic [39:0] mon4_awaddr;       // address of the last AXI4 AW handshake
    logic [39:0] mon4_araddr;       // address of the last AXI4 AR handshake
    logic [7:0]  mon4_arlen;
    logic [2:0]  mon4_awsize;       // AWSIZE of the last AXI4 AW handshake
    logic [2:0]  mon4_arsize;       // ARSIZE of the last AXI4 AR handshake
    int          mon4_w_beats;      // W beats since the last AW handshake
    int          mon4_r_beats;      // R beats since the last AR handshake
    int          mon4_r_decerr;     // R beats with DECERR since the last AR handshake
    int          mon4_rlast_err;    // RLAST position errors (whole run)
    logic [39:0] monl_awaddr;       // address of the last AXI4-Lite AW handshake
    logic [39:0] monl_araddr;       // address of the last AXI4-Lite AR handshake

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mon4_awaddr    <= '0;
            mon4_araddr    <= '0;
            mon4_arlen     <= 8'd0;
            mon4_awsize    <= 3'd0;
            mon4_arsize    <= 3'd0;
            mon4_w_beats   <= 0;
            mon4_r_beats   <= 0;
            mon4_r_decerr  <= 0;
            mon4_rlast_err <= 0;
            monl_awaddr    <= '0;
            monl_araddr    <= '0;
        end
        else begin
            if (mon4_aw_hs) begin
                mon4_awaddr <= m_axi4_awaddr;
                mon4_awsize <= m_axi4_awsize;
            end
            mon4_w_beats <= (mon4_aw_hs ? 0 : mon4_w_beats) + (mon4_w_hs ? 1 : 0);

            if (mon4_ar_hs) begin
                mon4_araddr <= m_axi4_araddr;
                mon4_arlen  <= m_axi4_arlen;
                mon4_arsize <= m_axi4_arsize;
            end
            mon4_r_beats  <= (mon4_ar_hs ? 0 : mon4_r_beats)  + (mon4_r_hs ? 1 : 0);
            mon4_r_decerr <= (mon4_ar_hs ? 0 : mon4_r_decerr) +
                             ((mon4_r_hs && (m_axi4_rresp == RESP_DECERR)) ? 1 : 0);
            if (mon4_r_hs && (m_axi4_rlast != (mon4_r_beats == int'(mon4_arlen)))) begin
                mon4_rlast_err <= mon4_rlast_err + 1;
                $display("[%0t] [AXI4 MONITOR] RLAST=%0d on beat %0d of arlen=%0d",
                         $time, m_axi4_rlast, mon4_r_beats, mon4_arlen);
            end

            if (monl_aw_hs) monl_awaddr <= m_axil_awaddr;
            if (monl_ar_hs) monl_araddr <= m_axil_araddr;
        end
    end

    //-----------------------------------------------------------------
    // Test control
    //-----------------------------------------------------------------
    int error_count = 0;
    // The number of checks is not a figure to compare across RTL changes.
    // Three sections draw their stimulus at random (16, 23 and 26, the ones
    // "with stalls"), and the stall injection of the slave models draws from
    // the same global generator, so anything that shifts the timing by a
    // cycle reshuffles the draws and changes how many beats get compared.
    // What has to stay at zero is error_count.
    int check_count = 0;

    // A single BFM transaction taking longer than this is reported as hung
    localparam int BFM_TIMEOUT_CYCLES = 20000;

    //=================================================================
    // L1 cache ports of the BFM (CPU_CACHE inside CPU_TOP)
    //=================================================================
    localparam logic [3:0] CC_LOAD  = 4'd0;
    localparam logic [3:0] CC_STORE = 4'd1;
    localparam logic [3:0] CC_FLUSH = 4'd14;

    task automatic cache_exec(input logic [3:0] cmd, input logic [39:0] addr,
                              input logic [1:0] size, input logic [63:0] wdata,
                              output logic [63:0] rdata, output bit err);
        @(posedge clk);
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_cmd   = cmd;
        u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_addr  = addr;
        u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_size  = size;
        u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_wdata = wdata;
        u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_valid = 1'b1;
        for (int t = 0; u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_done !== 1'b1; t++) begin
            if (t >= BFM_TIMEOUT_CYCLES) begin
                error_count++;
                $display("[%0t] [FAIL] data cache access hung : cmd=%0d addr=0x%010h",
                         $time, cmd, addr);
                report_and_finish();
            end
            @(posedge clk);
        end
        rdata = u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_rdata;
        err   = u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_err;
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_valid = 1'b0;
        // the BFM clears dc_cmd_done only after dc_cmd_valid has gone low
        while (u_cpu_top.g_bfm.u_cpu_bfm.dc_cmd_done !== 1'b0) @(posedge clk);
    endtask

    task automatic cache_store(input logic [39:0] addr, input logic [1:0] size,
                               input logic [63:0] wdata);
        logic [63:0] r;
        bit          e;
        cache_exec(CC_STORE, addr, size, wdata, r, e);
        check_count++;
        if (e) begin
            error_count++;
            $display("[%0t] [FAIL] data cache store error @0x%010h", $time, addr);
        end
    endtask

    task automatic cache_load_check(input string name, input logic [39:0] addr,
                                    input logic [1:0] size, input logic [63:0] expected);
        logic [63:0] r;
        bit          e;
        cache_exec(CC_LOAD, addr, size, 64'd0, r, e);
        check_count++;
        if (e || (r !== expected)) begin
            error_count++;
            $display("[%0t] [FAIL] %s @0x%010h : expected=0x%016h actual=0x%016h err=%b",
                     $time, name, addr, expected, r, e);
        end
    endtask

    task automatic cache_flush;
        logic [63:0] r;
        bit          e;
        cache_exec(CC_FLUSH, MEM_BASE, 2'd3, 64'd0, r, e);
        check_count++;
        if (e) begin
            error_count++;
            $display("[%0t] [FAIL] data cache flush error", $time);
        end
    endtask

    task automatic fetch_check(input string name, input logic [39:0] addr,
                               input logic [63:0] expected);
        @(posedge clk);
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_addr  = addr;
        u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_valid = 1'b1;
        for (int t = 0; u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_done !== 1'b1; t++) begin
            if (t >= BFM_TIMEOUT_CYCLES) begin
                error_count++;
                $display("[%0t] [FAIL] instruction fetch hung @0x%010h", $time, addr);
                report_and_finish();
            end
            @(posedge clk);
        end
        check_count++;
        if (u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_err ||
            (u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_rdata !== expected)) begin
            error_count++;
            $display("[%0t] [FAIL] %s @0x%010h : expected=0x%016h actual=0x%016h err=%b",
                     $time, name, addr, expected,
                     u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_rdata,
                     u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_err);
        end
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_valid = 1'b0;
        while (u_cpu_top.g_bfm.u_cpu_bfm.ic_cmd_done !== 1'b0) @(posedge clk);
    endtask

    task automatic fence_i;
        @(posedge clk);
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.ic_flush_req = 1'b1;
        for (int t = 0; u_cpu_top.g_bfm.u_cpu_bfm.ic_flush_ack !== 1'b1; t++) begin
            if (t >= BFM_TIMEOUT_CYCLES) begin
                error_count++;
                $display("[%0t] [FAIL] fence.i hung", $time);
                report_and_finish();
            end
            @(posedge clk);
        end
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.ic_flush_req = 1'b0;
        @(posedge clk);
    endtask

    task automatic report_and_finish;
        $display("");
        $display("==========================================================");
        if (error_count == 0)
            $display(" RESULT : PASS   (%0d checks)", check_count);
        else
            $display(" RESULT : FAIL   (%0d errors / %0d checks)", error_count, check_count);
        $display("==========================================================");
        $display("");
        $finish;
    endtask

    // Issue one BFM transaction, wait for completion, and check that the
    // full 40-bit address (and for AXI4 the AxSIZE) really appeared on the
    // CPU_TOP port.
    //   size  : AXI4 AxSIZE (3 = 64-bit full width). Ignored on AXI4-Lite.
    //   wstrb : WSTRB for a full-width AXI4 write, or any AXI4-Lite write.
    //           For a narrow AXI4 write the BFM derives WSTRB from the
    //           beat address, as a real master does.
    task automatic bfm_exec_x
        (
            input bit          we,
            input bit          bus,
            input logic [39:0] addr,
            input logic [7:0]  len,
            input logic [63:0] wdata,
            input logic [2:0]  size,
            input logic [7:0]  wstrb
        );
        logic [39:0] port_addr;
        logic [2:0]  port_size;

        @(posedge clk);
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_we    = we;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_bus   = bus;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_addr  = addr;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_len   = len;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wdata = wdata;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_size  = size;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wstrb = wstrb;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_valid = 1'b1;

        for (int t = 0; u_cpu_top.g_bfm.u_cpu_bfm.cmd_done !== 1'b1; t++) begin
            if (t >= BFM_TIMEOUT_CYCLES) begin
                error_count++;
                $display("[%0t] [FAIL] BFM transaction hung : %s %s addr=0x%010h len=%0d (state=%0d)",
                         $time,
                         (we  == CMD_WR ) ? "WRITE" : "READ",
                         (bus == BUS_MEM) ? "AXI4" : "AXI-Lite",
                         addr, len, u_cpu_top.g_bfm.u_cpu_bfm.state);
                report_and_finish();
            end
            @(posedge clk);
        end

        if (bus == BUS_MEM) port_addr = (we == CMD_WR) ? mon4_awaddr : mon4_araddr;
        else                port_addr = (we == CMD_WR) ? monl_awaddr : monl_araddr;
        check_count++;
        if (port_addr !== addr) begin
            error_count++;
            $display("[%0t] [FAIL] address on CPU_TOP port : %s %s expected=0x%010h actual=0x%010h",
                     $time,
                     (we  == CMD_WR ) ? "WRITE" : "READ",
                     (bus == BUS_MEM) ? "AXI4" : "AXI-Lite",
                     addr, port_addr);
        end
        if (bus == BUS_MEM) begin
            port_size = (we == CMD_WR) ? mon4_awsize : mon4_arsize;
            check_count++;
            if (port_size !== size) begin
                error_count++;
                $display("[%0t] [FAIL] AxSIZE on CPU_TOP port : %s AXI4 addr=0x%010h expected=%0d actual=%0d",
                         $time, (we == CMD_WR) ? "WRITE" : "READ", addr, size, port_size);
            end
        end

        @(posedge clk);
        #1;
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_valid = 1'b0;
        wait (u_cpu_top.g_bfm.u_cpu_bfm.cmd_done === 1'b0);
    endtask

    // Full-width transaction (64-bit AxSIZE, all WSTRB lanes)
    task automatic bfm_exec
        (
            input bit          we,
            input bit          bus,
            input logic [39:0] addr,
            input logic [7:0]  len,
            input logic [63:0] wdata
        );
        bfm_exec_x(we, bus, addr, len, wdata, SIZE_64, 8'hFF);
    endtask

    //-----------------------------------------------------------------
    // Shadow memories : expected content of each slave memory.
    // Every write that reaches a memory is mirrored here, so any read
    // can be checked regardless of the order of the tests.
    //-----------------------------------------------------------------
    logic [63:0] shadow_mem [0:MEM_DEPTH-1];   // memory bus     (AXI4)
    logic [63:0] shadow_per [0:MEM_DEPTH-1];   // peripheral bus (AXI4-Lite)

    initial begin
        for (int i = 0; i < MEM_DEPTH; i++) begin
            shadow_mem[i] = MEM_INIT_BASE    + 64'(i);
            shadow_per[i] = PERIPH_INIT_BASE + 64'(i);
        end
    end

    // Word index inside a memory (the address must have [39:32] == 0)
    function automatic int word_index(input bit bus, input logic [39:0] addr);
        word_index = int'((addr - ((bus == BUS_MEM) ? MEM_BASE : PERIPH_BASE)) >> 3);
    endfunction

    // Write with incrementing data (cmd_wdata, +1 per beat)
    task automatic bus_write
        (input bit bus, input logic [39:0] addr, input logic [7:0] len, input logic [63:0] wdata);
        int w;
        bfm_exec(CMD_WR, bus, addr, len, wdata);
        w = word_index(bus, addr);
        for (int i = 0; i <= int'(len); i++) begin
            if (bus == BUS_MEM) shadow_mem[w + i] = wdata + 64'(i);
            else                shadow_per[w + i] = wdata + 64'(i);
        end
    endtask

    task automatic bus_read
        (input bit bus, input logic [39:0] addr, input logic [7:0] len);
        bfm_exec(CMD_RD, bus, addr, len, 64'd0);
    endtask

    task automatic check64
        (input string name, input logic [63:0] expected, input logic [63:0] actual);
        check_count++;
        if (actual !== expected) begin
            error_count++;
            $display("[%0t] [FAIL] %-40s expected=0x%016h actual=0x%016h",
                     $time, name, expected, actual);
        end
        else begin
            $display("[%0t] [ OK ] %-40s value=0x%016h", $time, name, actual);
        end
    endtask

    task automatic check_resp(input string name, input logic [1:0] resp);
        check_count++;
        if (resp !== RESP_OKAY) begin
            error_count++;
            $display("[%0t] [FAIL] %-40s response=0b%02b (expected OKAY)", $time, name, resp);
        end
    endtask

    task automatic check_decerr(input string name, input logic [1:0] resp);
        check_count++;
        if (resp !== RESP_DECERR) begin
            error_count++;
            $display("[%0t] [FAIL] %-40s response=0b%02b (expected DECERR)", $time, name, resp);
        end
    endtask

    task automatic check_int(input string name, input int expected, input int actual);
        check_count++;
        if (actual != expected) begin
            error_count++;
            $display("[%0t] [FAIL] %-40s expected=%0d actual=%0d", $time, name, expected, actual);
        end
    endtask

    // Quiet check : prints only on mismatch (used for per-beat checks)
    task automatic check64_q
        (input string name, input int idx, input logic [63:0] expected, input logic [63:0] actual);
        check_count++;
        if (actual !== expected) begin
            error_count++;
            $display("[%0t] [FAIL] %s [%0d] expected=0x%016h actual=0x%016h",
                     $time, name, idx, expected, actual);
        end
    endtask

    // Single-word read, compared against the shadow memory
    task automatic read_check_shadow(input string name, input bit bus, input int widx);
        logic [39:0] a;
        logic [63:0] exp;
        a   = ((bus == BUS_MEM) ? MEM_BASE : PERIPH_BASE) + 40'(widx * 8);
        exp = (bus == BUS_MEM) ? shadow_mem[widx] : shadow_per[widx];
        bus_read(bus, a, 8'd0);
        check_resp(name, u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check64_q(name, widx, exp, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata);
    endtask

    logic [63:0] exp_buf [0:255];

    //-----------------------------------------------------------------
    // Long burst test (memory bus, AXI4)
    //   - random data per beat
    //   - one INCR burst write of nbeats, then one INCR burst read back
    //   - every beat is compared, and the words just before and just
    //     after the burst are checked to be untouched
    //-----------------------------------------------------------------
    task automatic axi4_burst_rw_test(input logic [39:0] addr, input int nbeats, input bit verbose);
        int w;
        int err0;
        err0 = error_count;
        w    = word_index(BUS_MEM, addr);

        for (int i = 0; i < nbeats; i++) begin
            exp_buf[i] = {$urandom, $urandom};
            u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf[i] = exp_buf[i];
        end

        // burst write
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf_en = 1'b1;
        bfm_exec(CMD_WR, BUS_MEM, addr, 8'(nbeats - 1), 64'd0);
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf_en = 1'b0;
        check_resp("AXI4 burst write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        for (int i = 0; i < nbeats; i++) shadow_mem[w + i] = exp_buf[i];

        // burst read back
        bfm_exec(CMD_RD, BUS_MEM, addr, 8'(nbeats - 1), 64'd0);
        check_resp("AXI4 burst read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        for (int i = 0; i < nbeats; i++) begin
            check64_q("AXI4 burst beat", i, exp_buf[i], u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[i]);
        end

        // neighbours must be untouched
        if (w > 0)                   read_check_shadow("AXI4 word before burst", BUS_MEM, w - 1);
        if (w + nbeats < MEM_DEPTH)  read_check_shadow("AXI4 word after burst",  BUS_MEM, w + nbeats);

        if (verbose || (error_count != err0))
            $display("[%0t] [%s] AXI4 burst %3d beats @0x%010h (page %0d offset 0x%03h)",
                     $time, (error_count == err0) ? " OK " : "FAIL",
                     nbeats, addr, w / PAGE_WORDS, 12'((w % PAGE_WORDS) * 8));
    endtask

    //-----------------------------------------------------------------
    // Upper address bit test (memory bus, AXI4)
    //   The address lo_addr with [39:32] replaced by 'upper' (non-zero)
    //   must be terminated with DECERR by the narrowing bridge:
    //   - burst write : every W beat consumed, BRESP = DECERR
    //   - burst read  : exactly nbeats R beats, all DECERR, RDATA = 0
    //   - the memory at lo_addr (what plain truncation would hit) must be
    //     left untouched
    //-----------------------------------------------------------------
    task automatic axi4_decerr_burst_test
        (input logic [39:0] lo_addr, input logic [7:0] upper, input int nbeats, input bit verbose);
        logic [39:0] hi_addr;
        int w;
        int err0;
        err0    = error_count;
        hi_addr = {upper, lo_addr[31:0]};
        w       = word_index(BUS_MEM, lo_addr);

        // write random data that differs from the memory content
        for (int i = 0; i < nbeats; i++) begin
            u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf[i] = ~shadow_mem[w + i] ^ 64'({$urandom} & 32'h00FF_FFFF);
        end
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf_en = 1'b1;
        bfm_exec(CMD_WR, BUS_MEM, hi_addr, 8'(nbeats - 1), 64'd0);
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf_en = 1'b0;
        check_decerr("AXI4 upper-bit write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check_int   ("AXI4 upper-bit write W beats consumed", nbeats, mon4_w_beats);

        bfm_exec(CMD_RD, BUS_MEM, hi_addr, 8'(nbeats - 1), 64'd0);
        check_decerr("AXI4 upper-bit read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check_int   ("AXI4 upper-bit read R beats",        nbeats, mon4_r_beats);
        check_int   ("AXI4 upper-bit read DECERR beats",   nbeats, mon4_r_decerr);
        for (int i = 0; i < nbeats; i++) begin
            check64_q("AXI4 upper-bit read data", i, 64'd0, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[i]);
        end

        // the aliased low address range must be untouched
        bfm_exec(CMD_RD, BUS_MEM, lo_addr, 8'(nbeats - 1), 64'd0);
        check_resp("AXI4 aliased range read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        for (int i = 0; i < nbeats; i++) begin
            check64_q("AXI4 aliased range untouched", i, shadow_mem[w + i], u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[i]);
        end

        if (verbose || (error_count != err0))
            $display("[%0t] [%s] AXI4 %3d beats @0x%010h -> DECERR, alias @0x%010h untouched",
                     $time, (error_count == err0) ? " OK " : "FAIL", nbeats, hi_addr, lo_addr);
    endtask

    //-----------------------------------------------------------------
    // Long sequential access test (peripheral bus, AXI4-Lite)
    //   AXI4-Lite has no burst, so nwords consecutive single-beat writes
    //   with random data are issued, then all words are read back.
    //-----------------------------------------------------------------
    task automatic axil_seq_rw_test(input logic [39:0] addr, input int nwords);
        int w;
        int err0;
        err0 = error_count;
        w    = word_index(BUS_PER, addr);

        for (int i = 0; i < nwords; i++) begin
            exp_buf[i] = {$urandom, $urandom};
            bfm_exec(CMD_WR, BUS_PER, addr + 40'(i * 8), 8'd0, exp_buf[i]);
            check_resp("AXI-Lite write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
            shadow_per[w + i] = exp_buf[i];
        end

        for (int i = 0; i < nwords; i++) begin
            bus_read(BUS_PER, addr + 40'(i * 8), 8'd0);
            check_resp("AXI-Lite read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
            check64_q("AXI-Lite sequential word", i, exp_buf[i], u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata);
        end

        if (w > 0)                   read_check_shadow("AXI-Lite word before", BUS_PER, w - 1);
        if (w + nwords < MEM_DEPTH)  read_check_shadow("AXI-Lite word after",  BUS_PER, w + nwords);

        $display("[%0t] [%s] AXI-Lite %3d consecutive words @0x%010h",
                 $time, (error_count == err0) ? " OK " : "FAIL", nwords, addr);
    endtask

    //-----------------------------------------------------------------
    // Upper address bit test (peripheral bus, AXI4-Lite)
    //-----------------------------------------------------------------
    task automatic axil_decerr_test
        (input logic [39:0] lo_addr, input logic [7:0] upper, input bit verbose);
        logic [39:0] hi_addr;
        int w;
        int err0;
        err0    = error_count;
        hi_addr = {upper, lo_addr[31:0]};
        w       = word_index(BUS_PER, lo_addr);

        bfm_exec(CMD_WR, BUS_PER, hi_addr, 8'd0, ~shadow_per[w]);
        check_decerr("AXI-Lite upper-bit write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);

        bfm_exec(CMD_RD, BUS_PER, hi_addr, 8'd0, 64'd0);
        check_decerr("AXI-Lite upper-bit read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check64_q("AXI-Lite upper-bit read data", 0, 64'd0, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata);

        read_check_shadow("AXI-Lite aliased word untouched", BUS_PER, w);

        if (verbose || (error_count != err0))
            $display("[%0t] [%s] AXI-Lite @0x%010h -> DECERR, alias @0x%010h untouched",
                     $time, (error_count == err0) ? " OK " : "FAIL", hi_addr, lo_addr);
    endtask

    //-----------------------------------------------------------------
    // Operand width (lane) helpers
    //
    //   size  : 0=8bit 1=16bit 2=32bit 3=64bit, lanes are little endian
    //           (lane 0 = least significant byte), as in RISC-V
    //   Write data lanes outside the written lanes are always filled with
    //   random garbage, so a write to a wrong lane is always visible.
    //-----------------------------------------------------------------
    function automatic string wname(input int size);
        case (size)
            0: wname = " 8bit";
            1: wname = "16bit";
            2: wname = "32bit";
            default: wname = "64bit";
        endcase
    endfunction

    // Lanes covered by a beat of 'size' at byte offset 'off' in its word.
    // (Written independently of the BFM so that a wrong WSTRB is caught.)
    function automatic logic [7:0] size_lanes(input int size, input int off);
        int nb;
        int base;
        logic [7:0] m;
        nb   = 1 << size;
        base = off - (off % nb);
        m    = '0;
        for (int b = 0; b < 8; b++) begin
            if ((b >= off) && (b < base + nb)) m[b] = 1'b1;
        end
        size_lanes = m;
    endfunction

    function automatic logic [63:0] lane_mask64(input logic [7:0] lanes);
        logic [63:0] m;
        for (int b = 0; b < 8; b++) m[8*b +: 8] = {8{lanes[b]}};
        lane_mask64 = m;
    endfunction

    function automatic logic [63:0] rnd64();
        rnd64 = {$urandom, $urandom};
    endfunction

    // Mirror a write of 'lanes' of 'busval' into word 'widx'
    task automatic shadow_apply(input bit bus, input int widx,
                                input logic [7:0] lanes, input logic [63:0] busval);
        logic [63:0] m;
        m = lane_mask64(lanes);
        if (bus == BUS_MEM) shadow_mem[widx] = (shadow_mem[widx] & ~m) | (busval & m);
        else                shadow_per[widx] = (shadow_per[widx] & ~m) | (busval & m);
    endtask

    // Single-beat write.
    //   AXI4      : size < 3 -> narrow transfer, lanes derived from addr
    //               size = 3 -> full width, lanes = ustrb
    //   AXI4-Lite : size ignored, lanes = ustrb
    task automatic lane_write(input bit bus, input logic [39:0] addr, input int size,
                              input logic [7:0] ustrb, input logic [63:0] busval);
        logic [7:0] lanes;
        bfm_exec_x(CMD_WR, bus, addr, 8'd0, busval, 3'(size), ustrb);
        check_resp("lane write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        if ((bus == BUS_PER) || (size == 3)) lanes = ustrb;
        else                                 lanes = size_lanes(size, int'(addr[2:0]));
        shadow_apply(bus, word_index(bus, addr), lanes, busval);
    endtask

    // Single-beat read ('size' is the AXI4 ARSIZE, ignored on AXI4-Lite),
    // comparing only 'lanes' of the returned word against the shadow.
    task automatic lane_read_check(input string name, input bit bus, input logic [39:0] addr,
                                   input int size, input logic [7:0] lanes);
        logic [63:0] m;
        logic [63:0] exp;
        logic [63:0] act;
        int w;
        bfm_exec_x(CMD_RD, bus, addr, 8'd0, 64'd0, 3'(size), 8'hFF);
        check_resp(name, u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        w   = word_index(bus, addr);
        m   = lane_mask64(lanes);
        exp = ((bus == BUS_MEM) ? shadow_mem[w] : shadow_per[w]) & m;
        act = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata & m;
        check_count++;
        if (act !== exp) begin
            error_count++;
            $display("[%0t] [FAIL] %s : addr=0x%010h size=%s lanes=0b%08b expected=0x%016h actual=0x%016h",
                     $time, name, addr, wname(size), lanes, exp, act);
        end
    endtask

    //-----------------------------------------------------------------
    // Narrow INCR burst (AXI4)
    //   nbeats beats of (1 << size) bytes from addr, random garbage in all
    //   lanes of every beat. addr need not be aligned to the size: as in AXI,
    //   the first beat then covers only the lanes up to the next boundary and
    //   the following beats are aligned. Read back with the same size (lanes compared per
    //   beat), then with a 64-bit burst over every word touched, and the words
    //   just before / after are checked to be untouched.
    //-----------------------------------------------------------------
    task automatic axi4_narrow_burst_test(input logic [39:0] addr, input int size,
                                          input int nbeats, input bit verbose);
        int nb;
        int w0;
        int w1;
        int err0;
        logic [39:0] a;
        logic [39:0] abase;
        logic [7:0]  lanes;
        logic [63:0] m;
        err0  = error_count;
        nb    = 1 << size;
        abase = addr & ~40'(nb - 1);
        w0    = word_index(BUS_MEM, addr);
        w1    = word_index(BUS_MEM, abase + 40'(nbeats * nb - 1));

        for (int i = 0; i < nbeats; i++) begin
            u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf[i] = rnd64();
        end
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf_en = 1'b1;
        bfm_exec_x(CMD_WR, BUS_MEM, addr, 8'(nbeats - 1), 64'd0, 3'(size), 8'($urandom));
        u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf_en = 1'b0;
        check_resp("AXI4 narrow burst write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        for (int i = 0; i < nbeats; i++) begin
            a     = (i == 0) ? addr : (abase + 40'(i * nb));
            lanes = size_lanes(size, int'(a[2:0]));
            shadow_apply(BUS_MEM, word_index(BUS_MEM, a), lanes, u_cpu_top.g_bfm.u_cpu_bfm.cmd_wbuf[i]);
        end

        // same-size burst read
        bfm_exec_x(CMD_RD, BUS_MEM, addr, 8'(nbeats - 1), 64'd0, 3'(size), 8'hFF);
        check_resp("AXI4 narrow burst read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        for (int i = 0; i < nbeats; i++) begin
            a = (i == 0) ? addr : (abase + 40'(i * nb));
            m = lane_mask64(size_lanes(size, int'(a[2:0])));
            check64_q("AXI4 narrow burst read beat", i,
                      shadow_mem[word_index(BUS_MEM, a)] & m,
                      u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[i] & m);
        end

        // 64-bit burst read over the touched words
        bfm_exec(CMD_RD, BUS_MEM, MEM_BASE + 40'(w0 * 8), 8'(w1 - w0), 64'd0);
        check_resp("AXI4 64bit read over narrow burst resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        for (int i = 0; i <= w1 - w0; i++) begin
            check64_q("AXI4 64bit word over narrow burst", w0 + i,
                      shadow_mem[w0 + i], u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[i]);
        end
        if (w0 > 0)              read_check_shadow("AXI4 word before narrow burst", BUS_MEM, w0 - 1);
        if (w1 + 1 < MEM_DEPTH)  read_check_shadow("AXI4 word after narrow burst",  BUS_MEM, w1 + 1);

        if (verbose || (error_count != err0))
            $display("[%0t] [%s] AXI4 narrow burst %s x %3d beats @0x%010h (words %0d..%0d)",
                     $time, (error_count == err0) ? " OK " : "FAIL",
                     wname(size), nbeats, addr, w0, w1);
    endtask

    //-----------------------------------------------------------------
    // Write a whole word with 'wsize' operands, then read it back with
    // 'rsize' operands (every lane group of each width).
    //   AXI4      : wsize/rsize are AxSIZE (narrow transfers), or
    //               use_strb=1 -> 64-bit AxSIZE with WSTRB lanes only
    //   AXI4-Lite : always WSTRB lanes; a read is always 64-bit and the
    //               lanes of the read width are compared
    //-----------------------------------------------------------------
    task automatic width_matrix_test(input bit bus, input logic [39:0] waddr,
                                     input int wsize, input int rsize,
                                     input bit use_strb, input bit verbose);
        int nbw;
        int nbr;
        int err0;
        logic [7:0] lanes;
        err0 = error_count;
        nbw  = 1 << wsize;
        nbr  = 1 << rsize;

        // write the word lane group by lane group
        for (int off = 0; off < 8; off += nbw) begin
            lanes = size_lanes(wsize, off);
            if ((bus == BUS_PER) || use_strb)
                lane_write(bus, waddr, 3, lanes, rnd64());
            else
                lane_write(bus, waddr + 40'(off), wsize, 8'($urandom), rnd64());
        end

        // read it back lane group by lane group
        for (int off = 0; off < 8; off += nbr) begin
            lanes = size_lanes(rsize, off);
            if ((bus == BUS_PER) || use_strb)
                lane_read_check("width matrix read", bus, waddr, 3, lanes);
            else
                lane_read_check("width matrix read", bus, waddr + 40'(off), rsize, lanes);
        end

        if (verbose || (error_count != err0))
            $display("[%0t] [%s] %s %s write x%0d -> %s read x%0d @0x%010h",
                     $time, (error_count == err0) ? " OK " : "FAIL",
                     (bus == BUS_MEM) ? (use_strb ? "AXI4(WSTRB) " : "AXI4(AxSIZE)") : "AXI-Lite    ",
                     wname(wsize), 8 / nbw, wname(rsize), 8 / nbr, waddr);
    endtask

    // Address of (page, offset) on the memory bus
    function automatic logic [39:0] mem_addr(input int page, input int offset);
        mem_addr = MEM_BASE + 40'(page * 4096 + offset);
    endfunction

    // Burst lengths used by the sweep tests
    // (a function rather than an array literal, for Icarus Verilog compatibility)
    localparam int NUM_BURST_LEN = 16;

    function automatic int burst_len(input int i);
        case (i)
            0 : burst_len = 1;     1 : burst_len = 2;
            2 : burst_len = 3;     3 : burst_len = 4;
            4 : burst_len = 7;     5 : burst_len = 8;
            6 : burst_len = 15;    7 : burst_len = 16;
            8 : burst_len = 31;    9 : burst_len = 32;
            10: burst_len = 63;    11: burst_len = 64;
            12: burst_len = 127;   13: burst_len = 128;
            14: burst_len = 255;   default: burst_len = 256;
        endcase
    endfunction

    // Protocol violations deliberately provoked by the testbench
    int protocol_err_expected = 0;
    int perr0;
    int err_mark;
    int nb;
    logic [7:0] upper;
    logic [39:0] base_a;
    int sz;
    int off;
    int nbeats;
    int maxb;
    int op;

    //-----------------------------------------------------------------
    // Test sequence
    //-----------------------------------------------------------------
    logic [63:0] rd;

    initial begin
        wait (rst_n === 1'b1);
        repeat (5) @(posedge clk);

        $display("");
        $display("==========================================================");
        $display(" CPU_TOP bus verification (BFM <-> slave memories)");
        $display("==========================================================");

        //---------------------------------------------------------
        $display("");
        $display("--- 1. Memory Bus (AXI4) : single read of initial data ---");
        //---------------------------------------------------------
        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0000, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check_resp("AXI4 single read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check64("AXI4 read word[0]", MEM_INIT_BASE + 64'd0, rd);

        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0010, 8'd0);   // word index 2
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI4 read word[2]", MEM_INIT_BASE + 64'd2, rd);

        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0080, 8'd0);   // word index 16
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI4 read word[16]", MEM_INIT_BASE + 64'd16, rd);

        //---------------------------------------------------------
        $display("");
        $display("--- 2. Memory Bus (AXI4) : single write / read back ---");
        //---------------------------------------------------------
        bus_write(BUS_MEM, MEM_BASE + 40'h0000_0020, 8'd0, 64'hA5A5_5A5A_DEAD_BEEF);
        check_resp("AXI4 single write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);

        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0020, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI4 write/read-back word[4]", 64'hA5A5_5A5A_DEAD_BEEF, rd);

        // neighbouring word must be untouched
        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0028, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI4 neighbour word[5] intact", MEM_INIT_BASE + 64'd5, rd);

        //---------------------------------------------------------
        $display("");
        $display("--- 3. Memory Bus (AXI4) : burst write / burst read ---");
        //---------------------------------------------------------
        // 4-beat INCR burst starting at word index 32 (0x100)
        bus_write(BUS_MEM, MEM_BASE + 40'h0000_0100, 8'd3, 64'h0000_1000_0000_0000);
        check_resp("AXI4 burst write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);

        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0100, 8'd3);
        check_resp("AXI4 burst read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check64("AXI4 burst beat[0]", 64'h0000_1000_0000_0000, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[0]);
        check64("AXI4 burst beat[1]", 64'h0000_1000_0000_0001, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[1]);
        check64("AXI4 burst beat[2]", 64'h0000_1000_0000_0002, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[2]);
        check64("AXI4 burst beat[3]", 64'h0000_1000_0000_0003, u_cpu_top.g_bfm.u_cpu_bfm.cmd_rbuf[3]);

        // word right after the burst must be untouched
        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0120, 8'd0);   // word index 36
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI4 word[36] after burst intact", MEM_INIT_BASE + 64'd36, rd);

        //---------------------------------------------------------
        $display("");
        $display("--- 4. Peripheral Bus (AXI4-Lite) : read of initial data ---");
        //---------------------------------------------------------
        bus_read(BUS_PER, PERIPH_BASE + 40'h0000_0000, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check_resp("AXI-Lite read resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
        check64("AXI-Lite read word[0]", PERIPH_INIT_BASE + 64'd0, rd);

        bus_read(BUS_PER, PERIPH_BASE + 40'h0000_0008, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI-Lite read word[1]", PERIPH_INIT_BASE + 64'd1, rd);

        bus_read(BUS_PER, PERIPH_BASE + 40'h0000_0100, 8'd0);   // word index 32
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI-Lite read word[32]", PERIPH_INIT_BASE + 64'd32, rd);

        //---------------------------------------------------------
        $display("");
        $display("--- 5. Peripheral Bus (AXI4-Lite) : write / read back ---");
        //---------------------------------------------------------
        bus_write(BUS_PER, PERIPH_BASE + 40'h0000_0010, 8'd0, 64'h5A5A_A5A5_CAFE_F00D);
        check_resp("AXI-Lite write resp", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);

        bus_read(BUS_PER, PERIPH_BASE + 40'h0000_0010, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI-Lite write/read-back word[2]", 64'h5A5A_A5A5_CAFE_F00D, rd);

        bus_read(BUS_PER, PERIPH_BASE + 40'h0000_0018, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI-Lite neighbour word[3] intact", PERIPH_INIT_BASE + 64'd3, rd);

        //---------------------------------------------------------
        $display("");
        $display("--- 6. Cross check : the two buses are independent ---");
        //---------------------------------------------------------
        // Same word offset on both buses must return different (per-bus) data
        bus_read(BUS_MEM, MEM_BASE + 40'h0000_0008, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI4 word[1] (memory bus)", MEM_INIT_BASE + 64'd1, rd);

        bus_read(BUS_PER, PERIPH_BASE + 40'h0000_0008, 8'd0);
        rd = u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata;
        check64("AXI-Lite word[1] (peripheral bus)", PERIPH_INIT_BASE + 64'd1, rd);

        //---------------------------------------------------------
        $display("");
        $display("--- 7. Memory Bus (AXI4) : burst length sweep 1..256, random data ---");
        //---------------------------------------------------------
        // One burst per 4KB page (pages 1-16), starting at page offset 0x100
        for (int i = 0; i < NUM_BURST_LEN; i++) begin
            axi4_burst_rw_test(mem_addr(1 + i, 12'h100), burst_len(i), 1'b1);
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 8. Memory Bus (AXI4) : 256-beat bursts at 4KB page edges ---");
        //---------------------------------------------------------
        // Largest legal start in a page : offset 0x800 (256 x 8 = 0x800 bytes)
        // -> the burst ends exactly on the last word of the page, and the
        //    'word after' check reads the first word of the next page.
        axi4_burst_rw_test(mem_addr(20, 12'h800), 256, 1'b1);
        // Start exactly on a page boundary
        // -> the 'word before' check reads the last word of the previous page.
        axi4_burst_rw_test(mem_addr(22, 12'h000), 256, 1'b1);
        // Back-to-back maximum bursts filling a whole page
        axi4_burst_rw_test(mem_addr(24, 12'h000), 256, 1'b1);
        axi4_burst_rw_test(mem_addr(24, 12'h800), 256, 1'b1);

        //---------------------------------------------------------
        $display("");
        $display("--- 9. Memory Bus (AXI4) : burst length sweep with READY/VALID stalls ---");
        //---------------------------------------------------------
        u_mem_axi4.stall_en = 1'b1;
        for (int i = 0; i < NUM_BURST_LEN; i++) begin
            axi4_burst_rw_test(mem_addr(33 + i, 12'h100), burst_len(i), 1'b1);
        end
        axi4_burst_rw_test(mem_addr(50, 12'h800), 256, 1'b1);
        u_mem_axi4.stall_en = 1'b0;

        //---------------------------------------------------------
        $display("");
        $display("--- 10. Peripheral Bus (AXI4-Lite) : 256 consecutive words ---");
        //---------------------------------------------------------
        // AXI4-Lite has no burst; long sequential single-beat access instead.
        axil_seq_rw_test(PERIPH_BASE + 40'h0000_2000, 256);

        //---------------------------------------------------------
        $display("");
        $display("--- 11. Peripheral Bus (AXI4-Lite) : 256 consecutive words with stalls ---");
        //---------------------------------------------------------
        u_mem_axil.stall_en = 1'b1;
        axil_seq_rw_test(PERIPH_BASE + 40'h0000_4000, 256);
        u_mem_axil.stall_en = 1'b0;

        //---------------------------------------------------------
        $display("");
        $display("--- 12. Protocol checker self-test (illegal 4KB crossing) ---");
        //---------------------------------------------------------
        // A read-only 2-beat burst from the last word of page 25 crosses
        // into page 26. The slave must flag exactly one violation. (Reads
        // are used so that memory contents stay consistent.)
        perr0 = u_mem_axi4.protocol_err;
        bus_read(BUS_MEM, mem_addr(25, 12'hFF8), 8'd1);
        repeat (2) @(posedge clk);
        protocol_err_expected = protocol_err_expected + 1;
        check_count++;
        if (u_mem_axi4.protocol_err != perr0 + 1) begin
            error_count++;
            $display("[%0t] [FAIL] protocol checker did not flag the 4KB crossing", $time);
        end
        else begin
            $display("[%0t] [ OK ] protocol checker flagged the illegal 4KB crossing", $time);
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 13. Memory Bus (AXI4) : upper address bits [39:32], walking one ---");
        //---------------------------------------------------------
        // Each upper bit alone must lead to DECERR and must not alias onto
        // the memory selected by [31:0]. The port-address check inside
        // bfm_exec proves that every single bit leaves CPU_TOP.
        for (int b = 0; b < 8; b++) begin
            axi4_decerr_burst_test(mem_addr(52, 12'h320), 8'(1 << b), 1, 1'b1);
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 14. Memory Bus (AXI4) : bursts with upper address bits ---");
        //---------------------------------------------------------
        axi4_decerr_burst_test(mem_addr(54, 12'h100), 8'h80,   2, 1'b1);
        axi4_decerr_burst_test(mem_addr(56, 12'h100), 8'h5A,  16, 1'b1);
        axi4_decerr_burst_test(mem_addr(58, 12'h800), 8'hFF, 256, 1'b1);

        //---------------------------------------------------------
        $display("");
        $display("--- 15. Peripheral Bus (AXI4-Lite) : upper address bits [39:32], walking one ---");
        //---------------------------------------------------------
        for (int b = 0; b < 8; b++) begin
            axil_decerr_test(PERIPH_BASE + 40'h0000_5320, 8'(1 << b), 1'b1);
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 16. Interleaved DECERR / normal access on both buses with stalls ---");
        //---------------------------------------------------------
        // The bridges must return to normal pass-through right after
        // terminating an erroneous transaction, also while the slaves
        // insert random READY/VALID stalls.
        u_mem_axi4.stall_en = 1'b1;
        u_mem_axil.stall_en = 1'b1;
        err_mark = error_count;
        for (int k = 0; k < 32; k++) begin
            nb    = 1 + int'($urandom % 16);
            upper = 8'(($urandom % 255) + 1);                 // 1..255, never zero
            axi4_decerr_burst_test(mem_addr(60 + (k % 4), 12'h100), upper, nb, 1'b0);
            axi4_burst_rw_test    (mem_addr(60 + (k % 4), 12'h100), nb, 1'b0);
            axil_decerr_test(PERIPH_BASE + 40'h0000_6000 + 40'(k * 8), upper, 1'b0);
            bus_write(BUS_PER, PERIPH_BASE + 40'h0000_6000 + 40'(k * 8), 8'd0, {$urandom, $urandom});
            check_resp("AXI-Lite write after DECERR", u_cpu_top.g_bfm.u_cpu_bfm.cmd_resp);
            read_check_shadow("AXI-Lite read after DECERR", BUS_PER, word_index(BUS_PER, PERIPH_BASE + 40'h0000_6000) + k);
        end
        u_mem_axi4.stall_en = 1'b0;
        u_mem_axil.stall_en = 1'b0;
        $display("[%0t] [%s] 32 rounds of DECERR / normal access interleaved on both buses",
                 $time, (error_count == err_mark) ? " OK " : "FAIL");

        //---------------------------------------------------------
        $display("");
        $display("--- 17. Memory Bus (AXI4) : 8/16/32-bit lanes by AxSIZE, lane by lane ---");
        //---------------------------------------------------------
        // Every lane group of each width is written with a narrow transfer
        // (garbage in the other lanes of WDATA), read back at the same width,
        // and the whole word is read at 64 bits to prove the other lanes kept
        // their value.
        for (sz = 0; sz < 3; sz++) begin
            err_mark = error_count;
            base_a   = mem_addr(17, 8 * sz);
            lane_write(BUS_MEM, base_a, 3, 8'hFF, rnd64());
            for (off = 0; off < 8; off += (1 << sz)) begin
                lane_write(BUS_MEM, base_a + 40'(off), sz, 8'($urandom), rnd64());
                lane_read_check("AXI4 same-width read", BUS_MEM, base_a + 40'(off), sz, size_lanes(sz, off));
                lane_read_check("AXI4 64bit read, other lanes intact", BUS_MEM, base_a, 3, 8'hFF);
            end
            $display("[%0t] [%s] AXI4 AxSIZE=%s : %0d lanes written, read at the same width, other lanes intact",
                     $time, (error_count == err_mark) ? " OK " : "FAIL", wname(sz), 8 >> sz);
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 18. Memory Bus (AXI4) : 8/16/32-bit lanes by WSTRB (AxSIZE=64bit) ---");
        //---------------------------------------------------------
        for (sz = 0; sz < 3; sz++) begin
            err_mark = error_count;
            base_a   = mem_addr(18, 8 * sz);
            lane_write(BUS_MEM, base_a, 3, 8'hFF, rnd64());
            for (off = 0; off < 8; off += (1 << sz)) begin
                lane_write(BUS_MEM, base_a, 3, size_lanes(sz, off), rnd64());
                lane_read_check("AXI4 64bit read after WSTRB write", BUS_MEM, base_a, 3, 8'hFF);
            end
            $display("[%0t] [%s] AXI4 WSTRB %s lanes : %0d lanes written, whole word checked each time",
                     $time, (error_count == err_mark) ? " OK " : "FAIL", wname(sz), 8 >> sz);
        end
        // A write with no strobe at all must not change the word
        err_mark = error_count;
        base_a   = mem_addr(18, 8 * 3);
        lane_write(BUS_MEM, base_a, 3, 8'hFF, rnd64());
        lane_write(BUS_MEM, base_a, 3, 8'h00, rnd64());
        lane_read_check("AXI4 64bit read after WSTRB=0 write", BUS_MEM, base_a, 3, 8'hFF);
        $display("[%0t] [%s] AXI4 WSTRB=0x00 write leaves the word unchanged",
                 $time, (error_count == err_mark) ? " OK " : "FAIL");

        //---------------------------------------------------------
        $display("");
        $display("--- 19. Memory Bus (AXI4) : write width x read width, by AxSIZE ---");
        //---------------------------------------------------------
        // Whole word written with 8/16/32/64-bit operands, read back with
        // 8/16/32/64-bit operands (narrow -> wide, wide -> narrow, equal).
        for (int ws = 0; ws < 4; ws++) begin
            for (int rs = 0; rs < 4; rs++) begin
                width_matrix_test(BUS_MEM, mem_addr(19, 8 * (ws * 4 + rs)), ws, rs, 1'b0, 1'b1);
            end
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 20. Memory Bus (AXI4) : write width x read width, by WSTRB (AxSIZE=64bit) ---");
        //---------------------------------------------------------
        for (int ws = 0; ws < 4; ws++) begin
            for (int rs = 0; rs < 4; rs++) begin
                width_matrix_test(BUS_MEM, mem_addr(21, 8 * (ws * 4 + rs)), ws, rs, 1'b1, 1'b1);
            end
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 21. Memory Bus (AXI4) : narrow INCR bursts (8/16/32-bit beats) ---");
        //---------------------------------------------------------
        for (sz = 0; sz < 3; sz++) begin
            nb = 1 << sz;
            // exactly one word
            axi4_narrow_burst_test(mem_addr(26 + sz, 12'h100), sz, 8 / nb, 1'b1);
            // starts on the second lane group, crosses into the next word
            axi4_narrow_burst_test(mem_addr(26 + sz, 12'h200 + nb), sz, 8 / nb + 1, 1'b1);
            // start address not aligned to the size (partial first beat)
            if (sz > 0)
                axi4_narrow_burst_test(mem_addr(26 + sz, 12'h301), sz, 5, 1'b1);
            // longest burst (256 beats)
            axi4_narrow_burst_test(mem_addr(26 + sz, 12'h400), sz, 256, 1'b1);
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 22. Memory Bus (AXI4) : narrow INCR bursts with READY/VALID stalls ---");
        //---------------------------------------------------------
        u_mem_axi4.stall_en = 1'b1;
        for (sz = 0; sz < 3; sz++) begin
            nb = 1 << sz;
            axi4_narrow_burst_test(mem_addr(29 + sz, 12'h100), sz, 8 / nb, 1'b1);
            axi4_narrow_burst_test(mem_addr(29 + sz, 12'h200 + nb), sz, 8 / nb + 1, 1'b1);
            if (sz > 0)
                axi4_narrow_burst_test(mem_addr(29 + sz, 12'h301), sz, 5, 1'b1);
            axi4_narrow_burst_test(mem_addr(29 + sz, 12'h400), sz, 256, 1'b1);
        end
        u_mem_axi4.stall_en = 1'b0;

        //---------------------------------------------------------
        $display("");
        $display("--- 23. Memory Bus (AXI4) : random width / lane / strobe regression with stalls ---");
        //---------------------------------------------------------
        // 2000 random operations on a 16-word window: single writes and reads
        // of random width at random (also unaligned) addresses, 64-bit writes
        // with random WSTRB (including 0x00), and narrow bursts. Every read is
        // checked against the shadow memory.
        u_mem_axi4.stall_en = 1'b1;
        err_mark = error_count;
        base_a   = mem_addr(32, 12'h000);
        for (int k = 0; k < 2000; k++) begin
            op  = int'($urandom % 4);
            sz  = int'($urandom % 4);
            off = int'($urandom % 128);
            case (op)
                0: begin
                    if (sz == 3) lane_write(BUS_MEM, base_a + 40'(off - off % 8), 3, 8'($urandom), rnd64());
                    else         lane_write(BUS_MEM, base_a + 40'(off), sz, 8'($urandom), rnd64());
                end
                1: begin
                    if (sz == 3) lane_read_check("AXI4 random read", BUS_MEM, base_a + 40'(off - off % 8), 3, 8'hFF);
                    else         lane_read_check("AXI4 random read", BUS_MEM, base_a + 40'(off), sz, size_lanes(sz, off % 8));
                end
                default: begin
                    sz     = int'($urandom % 3);
                    nb     = 1 << sz;
                    maxb   = (128 - (off - off % nb)) / nb;
                    if (maxb > 16) maxb = 16;
                    nbeats = 1 + int'($urandom % maxb);
                    axi4_narrow_burst_test(base_a + 40'(off), sz, nbeats, 1'b0);
                end
            endcase
        end
        for (int i = 0; i < 16; i++) begin
            read_check_shadow("AXI4 random window final sweep", BUS_MEM, word_index(BUS_MEM, base_a) + i);
        end
        u_mem_axi4.stall_en = 1'b0;
        $display("[%0t] [%s] 2000 random mixed-width AXI4 operations",
                 $time, (error_count == err_mark) ? " OK " : "FAIL");

        //---------------------------------------------------------
        $display("");
        $display("--- 24. Peripheral Bus (AXI4-Lite) : 8/16/32-bit lanes by WSTRB, lane by lane ---");
        //---------------------------------------------------------
        for (sz = 0; sz < 3; sz++) begin
            err_mark = error_count;
            base_a   = PERIPH_BASE + 40'h0000_7000 + 40'(8 * sz);
            lane_write(BUS_PER, base_a, 3, 8'hFF, rnd64());
            for (off = 0; off < 8; off += (1 << sz)) begin
                lane_write(BUS_PER, base_a, 3, size_lanes(sz, off), rnd64());
                lane_read_check("AXI-Lite read after WSTRB write", BUS_PER, base_a, 3, 8'hFF);
            end
            $display("[%0t] [%s] AXI-Lite WSTRB %s lanes : %0d lanes written, whole word checked each time",
                     $time, (error_count == err_mark) ? " OK " : "FAIL", wname(sz), 8 >> sz);
        end
        err_mark = error_count;
        base_a   = PERIPH_BASE + 40'h0000_7000 + 40'(8 * 3);
        lane_write(BUS_PER, base_a, 3, 8'hFF, rnd64());
        lane_write(BUS_PER, base_a, 3, 8'h00, rnd64());
        lane_read_check("AXI-Lite read after WSTRB=0 write", BUS_PER, base_a, 3, 8'hFF);
        $display("[%0t] [%s] AXI-Lite WSTRB=0x00 write leaves the word unchanged",
                 $time, (error_count == err_mark) ? " OK " : "FAIL");

        //---------------------------------------------------------
        $display("");
        $display("--- 25. Peripheral Bus (AXI4-Lite) : write width x read width ---");
        //---------------------------------------------------------
        // AXI4-Lite has no AxSIZE: writes use WSTRB lanes, every read returns
        // the whole word and the lanes of the read width are compared.
        for (int ws = 0; ws < 4; ws++) begin
            for (int rs = 0; rs < 4; rs++) begin
                width_matrix_test(BUS_PER, PERIPH_BASE + 40'h0000_8000 + 40'(8 * (ws * 4 + rs)), ws, rs, 1'b1, 1'b1);
            end
        end

        //---------------------------------------------------------
        $display("");
        $display("--- 26. Peripheral Bus (AXI4-Lite) : random strobe / lane regression with stalls ---");
        //---------------------------------------------------------
        u_mem_axil.stall_en = 1'b1;
        err_mark = error_count;
        base_a   = PERIPH_BASE + 40'h0000_9000;
        for (int k = 0; k < 1000; k++) begin
            off = 8 * int'($urandom % 16);
            if ($urandom % 2) lane_write(BUS_PER, base_a + 40'(off), 3, 8'($urandom), rnd64());
            else              lane_read_check("AXI-Lite random read", BUS_PER, base_a + 40'(off), 3, 8'($urandom));
        end
        for (int i = 0; i < 16; i++) begin
            read_check_shadow("AXI-Lite random window final sweep", BUS_PER, word_index(BUS_PER, base_a) + i);
        end
        u_mem_axil.stall_en = 1'b0;
        $display("[%0t] [%s] 1000 random strobe / lane AXI-Lite operations",
                 $time, (error_count == err_mark) ? " OK " : "FAIL");

        //---------------------------------------------------------
        $display("");
        $display("--- 27. L1 caches in CPU_TOP : CPU side through CPU_CACHE ---");
        //---------------------------------------------------------
        err_mark = error_count;
        begin
            logic [39:0] ca;
            logic [63:0] rd;
            bit          er;
            ca = MEM_BASE + 40'h0001_0000;      // window used only here

            // store / load through the data cache (miss, then hit)
            for (int i = 0; i < 8; i++)
                cache_store(ca + 40'(8*i), 2'd3, 64'hC0DE_0000_0000_0000 + 64'(i));
            for (int i = 0; i < 8; i++)
                cache_load_check("data cache load", ca + 40'(8*i), 2'd3,
                                 64'hC0DE_0000_0000_0000 + 64'(i));

            // byte / half / word accesses
            cache_store(ca + 40'h80, 2'd0, 64'h00000000000000A5);
            cache_store(ca + 40'h82, 2'd1, 64'h000000000000BEEF);
            cache_store(ca + 40'h84, 2'd2, 64'h0000000012345678);
            cache_load_check("data cache byte",  ca + 40'h80, 2'd0, 64'h00000000000000A5);
            cache_load_check("data cache half",  ca + 40'h82, 2'd1, 64'h000000000000BEEF);
            cache_load_check("data cache word",  ca + 40'h84, 2'd2, 64'h0000000012345678);

            // the dirty lines reach memory only after a flush: read them back
            // over the raw bus of the BFM (the other master of the arbiter)
            cache_flush();
            for (int i = 0; i < 8; i++) begin
                bfm_exec(CMD_RD, BUS_MEM, ca + 40'(8*i), 8'd0, 64'd0);
                check_count++;
                if (u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata !==
                    (64'hC0DE_0000_0000_0000 + 64'(i))) begin
                    error_count++;
                    $display("[%0t] [FAIL] flushed line in memory @0x%010h : 0x%016h",
                             $time, ca + 40'(8*i), u_cpu_top.g_bfm.u_cpu_bfm.cmd_rdata);
                end
            end

            // uncached access (peripheral bus) through the same port
            cache_store(PERIPH_BASE + 40'h0000_A000, 2'd3, 64'h1122_3344_5566_7788);
            cache_load_check("uncached load through the cache port",
                             PERIPH_BASE + 40'h0000_A000, 2'd3, 64'h1122_3344_5566_7788);

            // instruction fetch : the I$ must see what the D$ wrote back
            cache_store(ca + 40'h200, 2'd3, 64'h0000_0000_1000_0001);
            cache_flush();
            fence_i();
            fetch_check("instruction fetch", ca + 40'h200, 64'h0000_0000_1000_0001);
            fetch_check("instruction fetch (hit)", ca + 40'h200, 64'h0000_0000_1000_0001);
            // self modifying: write, flush, fence.i, fetch again
            cache_store(ca + 40'h200, 2'd3, 64'h0000_0000_2000_0002);
            cache_flush();
            fence_i();
            fetch_check("instruction fetch after fence.i", ca + 40'h200,
                        64'h0000_0000_2000_0002);

            // bus error through the cache port
            cache_exec(CC_LOAD, 40'h01_0000_0000, 2'd3, 64'd0, rd, er);
            check_count++;
            if (!er) begin
                error_count++;
                $display("[%0t] [FAIL] no error for an unmapped cache load", $time);
            end
        end
        $display("[%0t] [%s] data cache, instruction cache and fence.i through CPU_CACHE",
                 $time, (error_count == err_mark) ? " OK " : "FAIL");

        //---------------------------------------------------------
        // Whole-run checks
        //---------------------------------------------------------
        repeat (10) @(posedge clk);
        check_count++;
        if (u_mem_axi4.protocol_err != protocol_err_expected) begin
            error_count++;
            $display("[%0t] [FAIL] unexpected AXI4 protocol violations : %0d (expected %0d)",
                     $time, u_mem_axi4.protocol_err, protocol_err_expected);
        end
        check_int("AXI4 RLAST position errors (whole run)", 0, mon4_rlast_err);

        report_and_finish();
    end

    //-----------------------------------------------------------------
    // Watchdog
    //-----------------------------------------------------------------
    initial begin
        #10_000_000;   // 10s
        $display("");
        $display("[%0t] [FAIL] simulation TIMEOUT", $time);
        $display("==========================================================");
        $display(" RESULT : FAIL   (timeout)");
        $display("==========================================================");
        $finish;
    end

    //-----------------------------------------------------------------
    // Waveform dump
    //-----------------------------------------------------------------
`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_CPU_TOP.vcd");
        $dumpvars(0, tb_CPU_TOP);
    end
`endif

endmodule
