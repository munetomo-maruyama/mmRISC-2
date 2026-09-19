//---------------------------------------------------------------------------
// CPU_TOP.sv
//
// mmRISC-2 CPU Top-Level Module (skeleton)
//
// Target ISA   : RV64GC (RV64IMAFDC)
// MMU          : Sv39 (planned)
// CLINT        : internal
// PLIC         : internal
// Debug I/F    : RISC-V Debug Spec 1.0, JTAG / cJTAG (RTL/CPU/CPU_DBG)
//
// Bus interfaces (decided in docs/MMRISC_INTERFACE.md):
//   - Memory bus (DRAM / cache-fill)     : AXI4      (burst capable)
//   - Peripheral bus (MMIO)              : AXI4-Lite
//   - Address width for both buses       : 40 bit (physical address)
//     When integrated into a 32-bit SoC such as LiteX, connect [31:0]
//     through AXI4_ADDR_NARROW / AXIL_ADDR_NARROW (RTL/BUS), which return
//     DECERR when any of the upper bits [39:32] is non-zero.
//
// Current contents (CPU core not yet implemented):
//   CPU_DBG  : debug logic with a pseudo hart and a debug bus master
//   BUS_ARB  : arbitration of the debug bus master and the CPU
//   CPU_BFM  : temporary bus function model standing in for the CPU
//              (simulation only, USE_BFM=1)
//
// Resets:
//   rst_dbg_n : debug power-on reset (resets the debug module only)
//   rst_n     : system reset (CPU and bus side). ndmreset from the debug
//               module is also applied internally.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_TOP
    #(
        // Memory bus (AXI4)
        parameter int AXI4_ID_WIDTH     = 4,
        parameter int AXI4_ADDR_WIDTH   = 40,
        parameter int AXI4_DATA_WIDTH   = 64,

        // Peripheral bus (AXI4-Lite)
        parameter int AXIL_ADDR_WIDTH   = 40,
        parameter int AXIL_DATA_WIDTH   = 64,

        // External interrupt vector width (feeds internal PLIC)
        parameter int NUM_IRQ           = 32,

        // Identification
        parameter logic [31:0] IDCODE       = 32'h26d6d001,           // JTAG IDCODE
        parameter logic [63:0] MISA         = 64'h8000_0000_0014_112d, // RV64 IMAFDC + S/U
        parameter logic [31:0] MVENDORID    = 32'h0000_0000,
        parameter logic [63:0] MARCHID      = 64'h0000_0000_6d6d_3032, // "mm02"
        parameter logic [63:0] MIMPL        = 64'h0000_0000_0000_0001,
        parameter logic [63:0] MHARTID      = 64'h0,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000,

        // Address map : >= MEM_BASE -> memory bus, otherwise peripheral bus
        parameter logic [39:0] MEM_BASE     = 40'h00_8000_0000,

        // Debug bus master
        parameter logic [AXI4_ID_WIDTH-1:0] DBG_AXI4_ID = 1,
        parameter int          SBA_TIMEOUT  = 1 << 20,               // clk cycles

        // 1: instantiate the temporary BFM (simulation)
        parameter int          USE_BFM      = 1
    )
    (
        //-------------------------------------------------------------
        // Clock / Reset
        //-------------------------------------------------------------
        input  logic                        clk,
        input  logic                        rst_n,      // system reset, active-low, async
        input  logic                        rst_dbg_n,  // debug power-on reset, active-low, async
        output logic                        ndmreset,   // system reset request from the debugger

        //-------------------------------------------------------------
        // Memory Bus : AXI4 Master 
        //-------------------------------------------------------------
        // Write Address Channel
        output logic [AXI4_ID_WIDTH-1:0]    m_axi4_awid,
        output logic [AXI4_ADDR_WIDTH-1:0]  m_axi4_awaddr,
        output logic [7:0]                  m_axi4_awlen,
        output logic [2:0]                  m_axi4_awsize,
        output logic [1:0]                  m_axi4_awburst,
        output logic                        m_axi4_awlock,
        output logic [3:0]                  m_axi4_awcache,
        output logic [2:0]                  m_axi4_awprot,
        output logic [3:0]                  m_axi4_awqos,
        output logic                        m_axi4_awvalid,
        input  logic                        m_axi4_awready,

        // Write Data Channel
        output logic [AXI4_DATA_WIDTH-1:0]  m_axi4_wdata,
        output logic [AXI4_DATA_WIDTH/8-1:0] m_axi4_wstrb,
        output logic                        m_axi4_wlast,
        output logic                        m_axi4_wvalid,
        input  logic                        m_axi4_wready,

        // Write Response Channel
        input  logic [AXI4_ID_WIDTH-1:0]    m_axi4_bid,
        input  logic [1:0]                  m_axi4_bresp,
        input  logic                        m_axi4_bvalid,
        output logic                        m_axi4_bready,

        // Read Address Channel
        output logic [AXI4_ID_WIDTH-1:0]    m_axi4_arid,
        output logic [AXI4_ADDR_WIDTH-1:0]  m_axi4_araddr,
        output logic [7:0]                  m_axi4_arlen,
        output logic [2:0]                  m_axi4_arsize,
        output logic [1:0]                  m_axi4_arburst,
        output logic                        m_axi4_arlock,
        output logic [3:0]                  m_axi4_arcache,
        output logic [2:0]                  m_axi4_arprot,
        output logic [3:0]                  m_axi4_arqos,
        output logic                        m_axi4_arvalid,
        input  logic                        m_axi4_arready,

        // Read Data Channel
        input  logic [AXI4_ID_WIDTH-1:0]    m_axi4_rid,
        input  logic [AXI4_DATA_WIDTH-1:0]  m_axi4_rdata,
        input  logic [1:0]                  m_axi4_rresp,
        input  logic                        m_axi4_rlast,
        input  logic                        m_axi4_rvalid,
        output logic                        m_axi4_rready,

        //-------------------------------------------------------------
        // Peripheral Bus : AXI4-Lite Master 
        //-------------------------------------------------------------
        // Write Address Channel
        output logic [AXIL_ADDR_WIDTH-1:0]   m_axil_awaddr,
        output logic [2:0]                   m_axil_awprot,
        output logic                         m_axil_awvalid,
        input  logic                         m_axil_awready,

        // Write Data Channel
        output logic [AXIL_DATA_WIDTH-1:0]   m_axil_wdata,
        output logic [AXIL_DATA_WIDTH/8-1:0] m_axil_wstrb,
        output logic                         m_axil_wvalid,
        input  logic                         m_axil_wready,

        // Write Response Channel
        input  logic [1:0]                   m_axil_bresp,
        input  logic                         m_axil_bvalid,
        output logic                         m_axil_bready,

        // Read Address Channel
        output logic [AXIL_ADDR_WIDTH-1:0]   m_axil_araddr,
        output logic [2:0]                   m_axil_arprot,
        output logic                         m_axil_arvalid,
        input  logic                         m_axil_arready,

        // Read Data Channel
        input  logic [AXIL_DATA_WIDTH-1:0]   m_axil_rdata,
        input  logic [1:0]                   m_axil_rresp,
        input  logic                         m_axil_rvalid,
        output logic                         m_axil_rready,

        //-------------------------------------------------------------
        // External Interrupts (-> internal PLIC)
        //-------------------------------------------------------------
        input  logic [NUM_IRQ-1:0]          ext_irq,

        //-------------------------------------------------------------
        // Debug I/F : RISC-V Debug Spec 1.0, JTAG / cJTAG
        //-------------------------------------------------------------
        input  logic                        jtag_tck,     // TCK  / TCKC
        input  logic                        jtag_tms_i,   // TMS  / TMSC input
        output logic                        jtag_tms_o,   //        TMSC output
        output logic                        jtag_tms_oe,  //        TMSC output enable
        input  logic                        jtag_tdi,
        output logic                        jtag_tdo,
        output logic                        jtag_tdo_oe,
        input  logic                        jtag_trst_n,
        input  logic                        cjtag_en,     // 0: JTAG, 1: cJTAG
        output logic                        cjtag_online, // cJTAG OScan1 active

        // authentication (authdata)
        input  logic                        dbg_auth_en,  // 1: authentication required
        input  logic [31:0]                 dbg_auth_key,

        // status
        output logic                        dbg_halted,
        output logic                        dbg_running,
        output logic                        dbg_dmactive
    );

    //=================================================================
    // Internal buses
    //   dbg_* : debug bus master (DBG_BUSMST)
    //   cpu_* : CPU (currently the temporary BFM)
    //=================================================================

    logic [AXI4_ID_WIDTH-1:0]      dbg_axi4_awid;
    logic [AXI4_ADDR_WIDTH-1:0]    dbg_axi4_awaddr;
    logic [7:0]                    dbg_axi4_awlen;
    logic [2:0]                    dbg_axi4_awsize;
    logic [1:0]                    dbg_axi4_awburst;
    logic                          dbg_axi4_awlock;
    logic [3:0]                    dbg_axi4_awcache;
    logic [2:0]                    dbg_axi4_awprot;
    logic [3:0]                    dbg_axi4_awqos;
    logic                          dbg_axi4_awvalid;
    logic                          dbg_axi4_awready;
    logic [AXI4_DATA_WIDTH-1:0]    dbg_axi4_wdata;
    logic [AXI4_DATA_WIDTH/8-1:0]  dbg_axi4_wstrb;
    logic                          dbg_axi4_wlast;
    logic                          dbg_axi4_wvalid;
    logic                          dbg_axi4_wready;
    logic [AXI4_ID_WIDTH-1:0]      dbg_axi4_bid;
    logic [1:0]                    dbg_axi4_bresp;
    logic                          dbg_axi4_bvalid;
    logic                          dbg_axi4_bready;
    logic [AXI4_ID_WIDTH-1:0]      dbg_axi4_arid;
    logic [AXI4_ADDR_WIDTH-1:0]    dbg_axi4_araddr;
    logic [7:0]                    dbg_axi4_arlen;
    logic [2:0]                    dbg_axi4_arsize;
    logic [1:0]                    dbg_axi4_arburst;
    logic                          dbg_axi4_arlock;
    logic [3:0]                    dbg_axi4_arcache;
    logic [2:0]                    dbg_axi4_arprot;
    logic [3:0]                    dbg_axi4_arqos;
    logic                          dbg_axi4_arvalid;
    logic                          dbg_axi4_arready;
    logic [AXI4_ID_WIDTH-1:0]      dbg_axi4_rid;
    logic [AXI4_DATA_WIDTH-1:0]    dbg_axi4_rdata;
    logic [1:0]                    dbg_axi4_rresp;
    logic                          dbg_axi4_rlast;
    logic                          dbg_axi4_rvalid;
    logic                          dbg_axi4_rready;

    logic [AXIL_ADDR_WIDTH-1:0]    dbg_axil_awaddr;
    logic [2:0]                    dbg_axil_awprot;
    logic                          dbg_axil_awvalid;
    logic                          dbg_axil_awready;
    logic [AXIL_DATA_WIDTH-1:0]    dbg_axil_wdata;
    logic [AXIL_DATA_WIDTH/8-1:0]  dbg_axil_wstrb;
    logic                          dbg_axil_wvalid;
    logic                          dbg_axil_wready;
    logic [1:0]                    dbg_axil_bresp;
    logic                          dbg_axil_bvalid;
    logic                          dbg_axil_bready;
    logic [AXIL_ADDR_WIDTH-1:0]    dbg_axil_araddr;
    logic [2:0]                    dbg_axil_arprot;
    logic                          dbg_axil_arvalid;
    logic                          dbg_axil_arready;
    logic [AXIL_DATA_WIDTH-1:0]    dbg_axil_rdata;
    logic [1:0]                    dbg_axil_rresp;
    logic                          dbg_axil_rvalid;
    logic                          dbg_axil_rready;

    logic [AXI4_ID_WIDTH-1:0]      cpu_axi4_awid;
    logic [AXI4_ADDR_WIDTH-1:0]    cpu_axi4_awaddr;
    logic [7:0]                    cpu_axi4_awlen;
    logic [2:0]                    cpu_axi4_awsize;
    logic [1:0]                    cpu_axi4_awburst;
    logic                          cpu_axi4_awlock;
    logic [3:0]                    cpu_axi4_awcache;
    logic [2:0]                    cpu_axi4_awprot;
    logic [3:0]                    cpu_axi4_awqos;
    logic                          cpu_axi4_awvalid;
    logic                          cpu_axi4_awready;
    logic [AXI4_DATA_WIDTH-1:0]    cpu_axi4_wdata;
    logic [AXI4_DATA_WIDTH/8-1:0]  cpu_axi4_wstrb;
    logic                          cpu_axi4_wlast;
    logic                          cpu_axi4_wvalid;
    logic                          cpu_axi4_wready;
    logic [AXI4_ID_WIDTH-1:0]      cpu_axi4_bid;
    logic [1:0]                    cpu_axi4_bresp;
    logic                          cpu_axi4_bvalid;
    logic                          cpu_axi4_bready;
    logic [AXI4_ID_WIDTH-1:0]      cpu_axi4_arid;
    logic [AXI4_ADDR_WIDTH-1:0]    cpu_axi4_araddr;
    logic [7:0]                    cpu_axi4_arlen;
    logic [2:0]                    cpu_axi4_arsize;
    logic [1:0]                    cpu_axi4_arburst;
    logic                          cpu_axi4_arlock;
    logic [3:0]                    cpu_axi4_arcache;
    logic [2:0]                    cpu_axi4_arprot;
    logic [3:0]                    cpu_axi4_arqos;
    logic                          cpu_axi4_arvalid;
    logic                          cpu_axi4_arready;
    logic [AXI4_ID_WIDTH-1:0]      cpu_axi4_rid;
    logic [AXI4_DATA_WIDTH-1:0]    cpu_axi4_rdata;
    logic [1:0]                    cpu_axi4_rresp;
    logic                          cpu_axi4_rlast;
    logic                          cpu_axi4_rvalid;
    logic                          cpu_axi4_rready;

    logic [AXIL_ADDR_WIDTH-1:0]    cpu_axil_awaddr;
    logic [2:0]                    cpu_axil_awprot;
    logic                          cpu_axil_awvalid;
    logic                          cpu_axil_awready;
    logic [AXIL_DATA_WIDTH-1:0]    cpu_axil_wdata;
    logic [AXIL_DATA_WIDTH/8-1:0]  cpu_axil_wstrb;
    logic                          cpu_axil_wvalid;
    logic                          cpu_axil_wready;
    logic [1:0]                    cpu_axil_bresp;
    logic                          cpu_axil_bvalid;
    logic                          cpu_axil_bready;
    logic [AXIL_ADDR_WIDTH-1:0]    cpu_axil_araddr;
    logic [2:0]                    cpu_axil_arprot;
    logic                          cpu_axil_arvalid;
    logic                          cpu_axil_arready;
    logic [AXIL_DATA_WIDTH-1:0]    cpu_axil_rdata;
    logic [1:0]                    cpu_axil_rresp;
    logic                          cpu_axil_rvalid;
    logic                          cpu_axil_rready;

    logic rst_bus_n;   // system reset synchronized to clk, includes ndmreset

    //=================================================================
    // Debug logic (RISC-V Debug Spec 1.0, JTAG / cJTAG)
    //=================================================================
    CPU_DBG
        #(
            .AXI4_ID_WIDTH (AXI4_ID_WIDTH),
            .ADDR_WIDTH    (AXI4_ADDR_WIDTH),
            .IDCODE        (IDCODE),
            .MISA          (MISA),
            .MVENDORID     (MVENDORID),
            .MARCHID       (MARCHID),
            .MIMPL         (MIMPL),
            .MHARTID       (MHARTID),
            .RESET_VECTOR  (RESET_VECTOR),
            .MEM_BASE      (MEM_BASE),
            .DBG_AXI4_ID   (DBG_AXI4_ID),
            .SBA_TIMEOUT   (SBA_TIMEOUT)
        )
    u_cpu_dbg
        (
            .clk             (clk),
            .rst_dbg_n       (rst_dbg_n),
            .rst_n           (rst_n),
            .rst_bus_n       (rst_bus_n),
            .ndmreset        (ndmreset),
            .jtag_tck        (jtag_tck),
            .jtag_tms_i      (jtag_tms_i),
            .jtag_tms_o      (jtag_tms_o),
            .jtag_tms_oe     (jtag_tms_oe),
            .jtag_tdi        (jtag_tdi),
            .jtag_tdo        (jtag_tdo),
            .jtag_tdo_oe     (jtag_tdo_oe),
            .jtag_trst_n     (jtag_trst_n),
            .cjtag_en        (cjtag_en),
            .cjtag_online    (cjtag_online),
            .dbg_auth_en     (dbg_auth_en),
            .dbg_auth_key    (dbg_auth_key),
            .dbg_halted      (dbg_halted),
            .dbg_running     (dbg_running),
            .dbg_dmactive    (dbg_dmactive),

            .m_axi4_awid     (dbg_axi4_awid),
            .m_axi4_awaddr   (dbg_axi4_awaddr),
            .m_axi4_awlen    (dbg_axi4_awlen),
            .m_axi4_awsize   (dbg_axi4_awsize),
            .m_axi4_awburst  (dbg_axi4_awburst),
            .m_axi4_awlock   (dbg_axi4_awlock),
            .m_axi4_awcache  (dbg_axi4_awcache),
            .m_axi4_awprot   (dbg_axi4_awprot),
            .m_axi4_awqos    (dbg_axi4_awqos),
            .m_axi4_awvalid  (dbg_axi4_awvalid),
            .m_axi4_awready  (dbg_axi4_awready),
            .m_axi4_wdata    (dbg_axi4_wdata),
            .m_axi4_wstrb    (dbg_axi4_wstrb),
            .m_axi4_wlast    (dbg_axi4_wlast),
            .m_axi4_wvalid   (dbg_axi4_wvalid),
            .m_axi4_wready   (dbg_axi4_wready),
            .m_axi4_bid      (dbg_axi4_bid),
            .m_axi4_bresp    (dbg_axi4_bresp),
            .m_axi4_bvalid   (dbg_axi4_bvalid),
            .m_axi4_bready   (dbg_axi4_bready),
            .m_axi4_arid     (dbg_axi4_arid),
            .m_axi4_araddr   (dbg_axi4_araddr),
            .m_axi4_arlen    (dbg_axi4_arlen),
            .m_axi4_arsize   (dbg_axi4_arsize),
            .m_axi4_arburst  (dbg_axi4_arburst),
            .m_axi4_arlock   (dbg_axi4_arlock),
            .m_axi4_arcache  (dbg_axi4_arcache),
            .m_axi4_arprot   (dbg_axi4_arprot),
            .m_axi4_arqos    (dbg_axi4_arqos),
            .m_axi4_arvalid  (dbg_axi4_arvalid),
            .m_axi4_arready  (dbg_axi4_arready),
            .m_axi4_rid      (dbg_axi4_rid),
            .m_axi4_rdata    (dbg_axi4_rdata),
            .m_axi4_rresp    (dbg_axi4_rresp),
            .m_axi4_rlast    (dbg_axi4_rlast),
            .m_axi4_rvalid   (dbg_axi4_rvalid),
            .m_axi4_rready   (dbg_axi4_rready),
            .m_axil_awaddr   (dbg_axil_awaddr),
            .m_axil_awprot   (dbg_axil_awprot),
            .m_axil_awvalid  (dbg_axil_awvalid),
            .m_axil_awready  (dbg_axil_awready),
            .m_axil_wdata    (dbg_axil_wdata),
            .m_axil_wstrb    (dbg_axil_wstrb),
            .m_axil_wvalid   (dbg_axil_wvalid),
            .m_axil_wready   (dbg_axil_wready),
            .m_axil_bresp    (dbg_axil_bresp),
            .m_axil_bvalid   (dbg_axil_bvalid),
            .m_axil_bready   (dbg_axil_bready),
            .m_axil_araddr   (dbg_axil_araddr),
            .m_axil_arprot   (dbg_axil_arprot),
            .m_axil_arvalid  (dbg_axil_arvalid),
            .m_axil_arready  (dbg_axil_arready),
            .m_axil_rdata    (dbg_axil_rdata),
            .m_axil_rresp    (dbg_axil_rresp),
            .m_axil_rvalid   (dbg_axil_rvalid),
            .m_axil_rready   (dbg_axil_rready)
        );

    //=================================================================
    // Bus arbiter : s0 = debug (priority), s1 = CPU
    //=================================================================
    BUS_ARB
        #(
            .AXI4_ID_WIDTH   (AXI4_ID_WIDTH),
            .AXI4_ADDR_WIDTH (AXI4_ADDR_WIDTH),
            .AXI4_DATA_WIDTH (AXI4_DATA_WIDTH),
            .AXIL_ADDR_WIDTH (AXIL_ADDR_WIDTH),
            .AXIL_DATA_WIDTH (AXIL_DATA_WIDTH)
        )
    u_bus_arb
        (
            .clk             (clk),
            .rst_n           (rst_bus_n),

            .s0_axi4_awid    (dbg_axi4_awid),
            .s0_axi4_awaddr  (dbg_axi4_awaddr),
            .s0_axi4_awlen   (dbg_axi4_awlen),
            .s0_axi4_awsize  (dbg_axi4_awsize),
            .s0_axi4_awburst (dbg_axi4_awburst),
            .s0_axi4_awlock  (dbg_axi4_awlock),
            .s0_axi4_awcache (dbg_axi4_awcache),
            .s0_axi4_awprot  (dbg_axi4_awprot),
            .s0_axi4_awqos   (dbg_axi4_awqos),
            .s0_axi4_awvalid (dbg_axi4_awvalid),
            .s0_axi4_awready (dbg_axi4_awready),
            .s0_axi4_wdata   (dbg_axi4_wdata),
            .s0_axi4_wstrb   (dbg_axi4_wstrb),
            .s0_axi4_wlast   (dbg_axi4_wlast),
            .s0_axi4_wvalid  (dbg_axi4_wvalid),
            .s0_axi4_wready  (dbg_axi4_wready),
            .s0_axi4_bid     (dbg_axi4_bid),
            .s0_axi4_bresp   (dbg_axi4_bresp),
            .s0_axi4_bvalid  (dbg_axi4_bvalid),
            .s0_axi4_bready  (dbg_axi4_bready),
            .s0_axi4_arid    (dbg_axi4_arid),
            .s0_axi4_araddr  (dbg_axi4_araddr),
            .s0_axi4_arlen   (dbg_axi4_arlen),
            .s0_axi4_arsize  (dbg_axi4_arsize),
            .s0_axi4_arburst (dbg_axi4_arburst),
            .s0_axi4_arlock  (dbg_axi4_arlock),
            .s0_axi4_arcache (dbg_axi4_arcache),
            .s0_axi4_arprot  (dbg_axi4_arprot),
            .s0_axi4_arqos   (dbg_axi4_arqos),
            .s0_axi4_arvalid (dbg_axi4_arvalid),
            .s0_axi4_arready (dbg_axi4_arready),
            .s0_axi4_rid     (dbg_axi4_rid),
            .s0_axi4_rdata   (dbg_axi4_rdata),
            .s0_axi4_rresp   (dbg_axi4_rresp),
            .s0_axi4_rlast   (dbg_axi4_rlast),
            .s0_axi4_rvalid  (dbg_axi4_rvalid),
            .s0_axi4_rready  (dbg_axi4_rready),
            .s1_axi4_awid    (cpu_axi4_awid),
            .s1_axi4_awaddr  (cpu_axi4_awaddr),
            .s1_axi4_awlen   (cpu_axi4_awlen),
            .s1_axi4_awsize  (cpu_axi4_awsize),
            .s1_axi4_awburst (cpu_axi4_awburst),
            .s1_axi4_awlock  (cpu_axi4_awlock),
            .s1_axi4_awcache (cpu_axi4_awcache),
            .s1_axi4_awprot  (cpu_axi4_awprot),
            .s1_axi4_awqos   (cpu_axi4_awqos),
            .s1_axi4_awvalid (cpu_axi4_awvalid),
            .s1_axi4_awready (cpu_axi4_awready),
            .s1_axi4_wdata   (cpu_axi4_wdata),
            .s1_axi4_wstrb   (cpu_axi4_wstrb),
            .s1_axi4_wlast   (cpu_axi4_wlast),
            .s1_axi4_wvalid  (cpu_axi4_wvalid),
            .s1_axi4_wready  (cpu_axi4_wready),
            .s1_axi4_bid     (cpu_axi4_bid),
            .s1_axi4_bresp   (cpu_axi4_bresp),
            .s1_axi4_bvalid  (cpu_axi4_bvalid),
            .s1_axi4_bready  (cpu_axi4_bready),
            .s1_axi4_arid    (cpu_axi4_arid),
            .s1_axi4_araddr  (cpu_axi4_araddr),
            .s1_axi4_arlen   (cpu_axi4_arlen),
            .s1_axi4_arsize  (cpu_axi4_arsize),
            .s1_axi4_arburst (cpu_axi4_arburst),
            .s1_axi4_arlock  (cpu_axi4_arlock),
            .s1_axi4_arcache (cpu_axi4_arcache),
            .s1_axi4_arprot  (cpu_axi4_arprot),
            .s1_axi4_arqos   (cpu_axi4_arqos),
            .s1_axi4_arvalid (cpu_axi4_arvalid),
            .s1_axi4_arready (cpu_axi4_arready),
            .s1_axi4_rid     (cpu_axi4_rid),
            .s1_axi4_rdata   (cpu_axi4_rdata),
            .s1_axi4_rresp   (cpu_axi4_rresp),
            .s1_axi4_rlast   (cpu_axi4_rlast),
            .s1_axi4_rvalid  (cpu_axi4_rvalid),
            .s1_axi4_rready  (cpu_axi4_rready),
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
            .s0_axil_awaddr  (dbg_axil_awaddr),
            .s0_axil_awprot  (dbg_axil_awprot),
            .s0_axil_awvalid (dbg_axil_awvalid),
            .s0_axil_awready (dbg_axil_awready),
            .s0_axil_wdata   (dbg_axil_wdata),
            .s0_axil_wstrb   (dbg_axil_wstrb),
            .s0_axil_wvalid  (dbg_axil_wvalid),
            .s0_axil_wready  (dbg_axil_wready),
            .s0_axil_bresp   (dbg_axil_bresp),
            .s0_axil_bvalid  (dbg_axil_bvalid),
            .s0_axil_bready  (dbg_axil_bready),
            .s0_axil_araddr  (dbg_axil_araddr),
            .s0_axil_arprot  (dbg_axil_arprot),
            .s0_axil_arvalid (dbg_axil_arvalid),
            .s0_axil_arready (dbg_axil_arready),
            .s0_axil_rdata   (dbg_axil_rdata),
            .s0_axil_rresp   (dbg_axil_rresp),
            .s0_axil_rvalid  (dbg_axil_rvalid),
            .s0_axil_rready  (dbg_axil_rready),
            .s1_axil_awaddr  (cpu_axil_awaddr),
            .s1_axil_awprot  (cpu_axil_awprot),
            .s1_axil_awvalid (cpu_axil_awvalid),
            .s1_axil_awready (cpu_axil_awready),
            .s1_axil_wdata   (cpu_axil_wdata),
            .s1_axil_wstrb   (cpu_axil_wstrb),
            .s1_axil_wvalid  (cpu_axil_wvalid),
            .s1_axil_wready  (cpu_axil_wready),
            .s1_axil_bresp   (cpu_axil_bresp),
            .s1_axil_bvalid  (cpu_axil_bvalid),
            .s1_axil_bready  (cpu_axil_bready),
            .s1_axil_araddr  (cpu_axil_araddr),
            .s1_axil_arprot  (cpu_axil_arprot),
            .s1_axil_arvalid (cpu_axil_arvalid),
            .s1_axil_arready (cpu_axil_arready),
            .s1_axil_rdata   (cpu_axil_rdata),
            .s1_axil_rresp   (cpu_axil_rresp),
            .s1_axil_rvalid  (cpu_axil_rvalid),
            .s1_axil_rready  (cpu_axil_rready),
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
            .m_axil_rready   (m_axil_rready)
        );

    //=================================================================
    // Temporary Bus Function Model (simulation)
    //
    // Provisionally drives the memory / peripheral buses in place of the
    // real CPU logic (pipeline, MMU, cache, CLINT, PLIC). It is controlled
    // from the testbench through hierarchical references to its command
    // variables. Remove this instance once the CPU core is implemented.
    // USE_BFM=0 (FPGA) leaves the CPU side of the arbiter idle.
    //=================================================================
    generate
        if (USE_BFM != 0) begin : g_bfm
            CPU_BFM
                #(
                    .AXI4_ID_WIDTH   (AXI4_ID_WIDTH),
                    .AXI4_ADDR_WIDTH (AXI4_ADDR_WIDTH),
                    .AXI4_DATA_WIDTH (AXI4_DATA_WIDTH),
                    .AXIL_ADDR_WIDTH (AXIL_ADDR_WIDTH),
                    .AXIL_DATA_WIDTH (AXIL_DATA_WIDTH)
                )
            u_cpu_bfm
                (
                    .clk             (clk),
                    .rst_n           (rst_bus_n),

                    .m_axi4_awid     (cpu_axi4_awid),
                    .m_axi4_awaddr   (cpu_axi4_awaddr),
                    .m_axi4_awlen    (cpu_axi4_awlen),
                    .m_axi4_awsize   (cpu_axi4_awsize),
                    .m_axi4_awburst  (cpu_axi4_awburst),
                    .m_axi4_awlock   (cpu_axi4_awlock),
                    .m_axi4_awcache  (cpu_axi4_awcache),
                    .m_axi4_awprot   (cpu_axi4_awprot),
                    .m_axi4_awqos    (cpu_axi4_awqos),
                    .m_axi4_awvalid  (cpu_axi4_awvalid),
                    .m_axi4_awready  (cpu_axi4_awready),
                    .m_axi4_wdata    (cpu_axi4_wdata),
                    .m_axi4_wstrb    (cpu_axi4_wstrb),
                    .m_axi4_wlast    (cpu_axi4_wlast),
                    .m_axi4_wvalid   (cpu_axi4_wvalid),
                    .m_axi4_wready   (cpu_axi4_wready),
                    .m_axi4_bid      (cpu_axi4_bid),
                    .m_axi4_bresp    (cpu_axi4_bresp),
                    .m_axi4_bvalid   (cpu_axi4_bvalid),
                    .m_axi4_bready   (cpu_axi4_bready),
                    .m_axi4_arid     (cpu_axi4_arid),
                    .m_axi4_araddr   (cpu_axi4_araddr),
                    .m_axi4_arlen    (cpu_axi4_arlen),
                    .m_axi4_arsize   (cpu_axi4_arsize),
                    .m_axi4_arburst  (cpu_axi4_arburst),
                    .m_axi4_arlock   (cpu_axi4_arlock),
                    .m_axi4_arcache  (cpu_axi4_arcache),
                    .m_axi4_arprot   (cpu_axi4_arprot),
                    .m_axi4_arqos    (cpu_axi4_arqos),
                    .m_axi4_arvalid  (cpu_axi4_arvalid),
                    .m_axi4_arready  (cpu_axi4_arready),
                    .m_axi4_rid      (cpu_axi4_rid),
                    .m_axi4_rdata    (cpu_axi4_rdata),
                    .m_axi4_rresp    (cpu_axi4_rresp),
                    .m_axi4_rlast    (cpu_axi4_rlast),
                    .m_axi4_rvalid   (cpu_axi4_rvalid),
                    .m_axi4_rready   (cpu_axi4_rready),
                    .m_axil_awaddr   (cpu_axil_awaddr),
                    .m_axil_awprot   (cpu_axil_awprot),
                    .m_axil_awvalid  (cpu_axil_awvalid),
                    .m_axil_awready  (cpu_axil_awready),
                    .m_axil_wdata    (cpu_axil_wdata),
                    .m_axil_wstrb    (cpu_axil_wstrb),
                    .m_axil_wvalid   (cpu_axil_wvalid),
                    .m_axil_wready   (cpu_axil_wready),
                    .m_axil_bresp    (cpu_axil_bresp),
                    .m_axil_bvalid   (cpu_axil_bvalid),
                    .m_axil_bready   (cpu_axil_bready),
                    .m_axil_araddr   (cpu_axil_araddr),
                    .m_axil_arprot   (cpu_axil_arprot),
                    .m_axil_arvalid  (cpu_axil_arvalid),
                    .m_axil_arready  (cpu_axil_arready),
                    .m_axil_rdata    (cpu_axil_rdata),
                    .m_axil_rresp    (cpu_axil_rresp),
                    .m_axil_rvalid   (cpu_axil_rvalid),
                    .m_axil_rready   (cpu_axil_rready)
                );
        end else begin : g_no_bfm

            assign cpu_axi4_awid     = '0;
            assign cpu_axi4_awaddr   = '0;
            assign cpu_axi4_awlen    = '0;
            assign cpu_axi4_awsize   = '0;
            assign cpu_axi4_awburst  = '0;
            assign cpu_axi4_awlock   = '0;
            assign cpu_axi4_awcache  = '0;
            assign cpu_axi4_awprot   = '0;
            assign cpu_axi4_awqos    = '0;
            assign cpu_axi4_awvalid  = '0;
            assign cpu_axi4_wdata    = '0;
            assign cpu_axi4_wstrb    = '0;
            assign cpu_axi4_wlast    = '0;
            assign cpu_axi4_wvalid   = '0;
            assign cpu_axi4_bready   = '0;
            assign cpu_axi4_arid     = '0;
            assign cpu_axi4_araddr   = '0;
            assign cpu_axi4_arlen    = '0;
            assign cpu_axi4_arsize   = '0;
            assign cpu_axi4_arburst  = '0;
            assign cpu_axi4_arlock   = '0;
            assign cpu_axi4_arcache  = '0;
            assign cpu_axi4_arprot   = '0;
            assign cpu_axi4_arqos    = '0;
            assign cpu_axi4_arvalid  = '0;
            assign cpu_axi4_rready   = '0;
            assign cpu_axil_awaddr   = '0;
            assign cpu_axil_awprot   = '0;
            assign cpu_axil_awvalid  = '0;
            assign cpu_axil_wdata    = '0;
            assign cpu_axil_wstrb    = '0;
            assign cpu_axil_wvalid   = '0;
            assign cpu_axil_bready   = '0;
            assign cpu_axil_araddr   = '0;
            assign cpu_axil_arprot   = '0;
            assign cpu_axil_arvalid  = '0;
            assign cpu_axil_rready   = '0;
        end
    endgenerate

    //=================================================================
    // Not yet implemented
    //=================================================================
    // ext_irq : to the internal PLIC (CPU core phase)

endmodule : CPU_TOP
