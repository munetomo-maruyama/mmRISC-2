//---------------------------------------------------------------------------
// CPU_CACHE.sv
//
// mmRISC-2 L1 cache subsystem : instruction cache + data cache + bus
// arbitration (RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md).
//
//   CPU ─ i_* ─> ICACHE ─┐
//                        ├─ BUS_ARB ─> memory bus AXI4 / peripheral bus AXI4-Lite
//   CPU ─ d_* ─┬> DCACHE ─┘   (s0 = data, s1 = instruction)
//   DBG ─ dbg_*┘  through CACHE_PORT_ARB (CPU first, see 4.7 of the spec)
//
// The data side has priority in the arbiter, so a fill for the CPU data
// stream is not delayed by instruction prefetching.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_CACHE
    #(
        parameter int          PADDR_WIDTH    = 40,
        parameter int          XLEN           = 64,
        parameter logic [39:0] MEM_BASE       = 40'h00_8000_0000,

        parameter int          IC_SETS        = 64,
        parameter int          IC_WAYS        = 4,
        parameter int          IC_BLOCK_BYTES = 64,
        parameter int          FETCH_WIDTH    = 64,

        parameter int          DC_SETS        = 64,
        parameter int          DC_WAYS        = 4,
        parameter int          DC_BLOCK_BYTES = 64,
        parameter int          NUM_MSHR       = 2,
        parameter int          NUM_WB         = 2,
        parameter int          ROB_DEPTH      = 8,

        parameter int          REPLACE_RANDOM = 0,
        parameter int          AXI4_ID_WIDTH  = 4,
        parameter logic [3:0]  AXI4_ID_IFILL  = 4'd2,
        parameter logic [3:0]  AXI4_ID_DFILL  = 4'd3,
        parameter logic [3:0]  AXI4_ID_DWB    = 4'd4
    )
    (
        input  logic                     clk,
        input  logic                     rst_n,

        // instruction side
        input  logic                     i_req_valid,
        output logic                     i_req_ready,
        input  logic [PADDR_WIDTH-1:0]   i_req_addr,
        output logic                     i_resp_valid,
        output logic [FETCH_WIDTH-1:0]   i_resp_data,
        output logic                     i_resp_error,
        input  logic                     i_flush_valid,
        output logic                     i_flush_done,
        input  logic                     i_kill,

        // data side
        input  logic                     d_req_valid,
        output logic                     d_req_ready,
        input  logic [PADDR_WIDTH-1:0]   d_req_addr,
        input  logic [1:0]               d_req_size,
        input  logic [3:0]               d_req_cmd,
        input  logic [XLEN-1:0]          d_req_wdata,
        output logic                     d_resp_valid,
        output logic [XLEN-1:0]          d_resp_data,
        output logic                     d_resp_error,

        // debug side : shares the data cache port with the CPU (CPU first).
        // Tie dbg_req_valid to 0 when the debug module is not connected.
        input  logic                     dbg_req_valid,
        output logic                     dbg_req_ready,
        input  logic [PADDR_WIDTH-1:0]   dbg_req_addr,
        input  logic [1:0]               dbg_req_size,
        input  logic [3:0]               dbg_req_cmd,
        input  logic [XLEN-1:0]          dbg_req_wdata,
        output logic                     dbg_resp_valid,
        output logic [XLEN-1:0]          dbg_resp_data,
        output logic                     dbg_resp_error,

        // memory bus : AXI4
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_awid,
        output logic [PADDR_WIDTH-1:0]   m_axi4_awaddr,
        output logic [7:0]               m_axi4_awlen,
        output logic [2:0]               m_axi4_awsize,
        output logic [1:0]               m_axi4_awburst,
        output logic                     m_axi4_awlock,
        output logic [3:0]               m_axi4_awcache,
        output logic [2:0]               m_axi4_awprot,
        output logic [3:0]               m_axi4_awqos,
        output logic                     m_axi4_awvalid,
        input  logic                     m_axi4_awready,
        output logic [63:0]              m_axi4_wdata,
        output logic [7:0]               m_axi4_wstrb,
        output logic                     m_axi4_wlast,
        output logic                     m_axi4_wvalid,
        input  logic                     m_axi4_wready,
        input  logic [AXI4_ID_WIDTH-1:0] m_axi4_bid,
        input  logic [1:0]               m_axi4_bresp,
        input  logic                     m_axi4_bvalid,
        output logic                     m_axi4_bready,
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_arid,
        output logic [PADDR_WIDTH-1:0]   m_axi4_araddr,
        output logic [7:0]               m_axi4_arlen,
        output logic [2:0]               m_axi4_arsize,
        output logic [1:0]               m_axi4_arburst,
        output logic                     m_axi4_arlock,
        output logic [3:0]               m_axi4_arcache,
        output logic [2:0]               m_axi4_arprot,
        output logic [3:0]               m_axi4_arqos,
        output logic                     m_axi4_arvalid,
        input  logic                     m_axi4_arready,
        input  logic [AXI4_ID_WIDTH-1:0] m_axi4_rid,
        input  logic [63:0]              m_axi4_rdata,
        input  logic [1:0]               m_axi4_rresp,
        input  logic                     m_axi4_rlast,
        input  logic                     m_axi4_rvalid,
        output logic                     m_axi4_rready,

        // peripheral bus : AXI4-Lite
        output logic [PADDR_WIDTH-1:0]   m_axil_awaddr,
        output logic [2:0]               m_axil_awprot,
        output logic                     m_axil_awvalid,
        input  logic                     m_axil_awready,
        output logic [63:0]              m_axil_wdata,
        output logic [7:0]               m_axil_wstrb,
        output logic                     m_axil_wvalid,
        input  logic                     m_axil_wready,
        input  logic [1:0]               m_axil_bresp,
        input  logic                     m_axil_bvalid,
        output logic                     m_axil_bready,
        output logic [PADDR_WIDTH-1:0]   m_axil_araddr,
        output logic [2:0]               m_axil_arprot,
        output logic                     m_axil_arvalid,
        input  logic                     m_axil_arready,
        input  logic [63:0]              m_axil_rdata,
        input  logic [1:0]               m_axil_rresp,
        input  logic                     m_axil_rvalid,
        output logic                     m_axil_rready
    );

    //=================================================================
    // Internal buses
    //=================================================================
    logic [AXI4_ID_WIDTH-1:0]    ic_axi4_awid;
    logic [PADDR_WIDTH-1:0]      ic_axi4_awaddr;
    logic [7:0]                  ic_axi4_awlen;
    logic [2:0]                  ic_axi4_awsize;
    logic [1:0]                  ic_axi4_awburst;
    logic                        ic_axi4_awlock;
    logic [3:0]                  ic_axi4_awcache;
    logic [2:0]                  ic_axi4_awprot;
    logic [3:0]                  ic_axi4_awqos;
    logic                        ic_axi4_awvalid;
    logic                        ic_axi4_awready;
    logic [63:0]                 ic_axi4_wdata;
    logic [7:0]                  ic_axi4_wstrb;
    logic                        ic_axi4_wlast;
    logic                        ic_axi4_wvalid;
    logic                        ic_axi4_wready;
    logic [AXI4_ID_WIDTH-1:0]    ic_axi4_bid;
    logic [1:0]                  ic_axi4_bresp;
    logic                        ic_axi4_bvalid;
    logic                        ic_axi4_bready;
    logic [AXI4_ID_WIDTH-1:0]    ic_axi4_arid;
    logic [PADDR_WIDTH-1:0]      ic_axi4_araddr;
    logic [7:0]                  ic_axi4_arlen;
    logic [2:0]                  ic_axi4_arsize;
    logic [1:0]                  ic_axi4_arburst;
    logic                        ic_axi4_arlock;
    logic [3:0]                  ic_axi4_arcache;
    logic [2:0]                  ic_axi4_arprot;
    logic [3:0]                  ic_axi4_arqos;
    logic                        ic_axi4_arvalid;
    logic                        ic_axi4_arready;
    logic [AXI4_ID_WIDTH-1:0]    ic_axi4_rid;
    logic [63:0]                 ic_axi4_rdata;
    logic [1:0]                  ic_axi4_rresp;
    logic                        ic_axi4_rlast;
    logic                        ic_axi4_rvalid;
    logic                        ic_axi4_rready;

    logic [AXI4_ID_WIDTH-1:0]    dc_axi4_awid;
    logic [PADDR_WIDTH-1:0]      dc_axi4_awaddr;
    logic [7:0]                  dc_axi4_awlen;
    logic [2:0]                  dc_axi4_awsize;
    logic [1:0]                  dc_axi4_awburst;
    logic                        dc_axi4_awlock;
    logic [3:0]                  dc_axi4_awcache;
    logic [2:0]                  dc_axi4_awprot;
    logic [3:0]                  dc_axi4_awqos;
    logic                        dc_axi4_awvalid;
    logic                        dc_axi4_awready;
    logic [63:0]                 dc_axi4_wdata;
    logic [7:0]                  dc_axi4_wstrb;
    logic                        dc_axi4_wlast;
    logic                        dc_axi4_wvalid;
    logic                        dc_axi4_wready;
    logic [AXI4_ID_WIDTH-1:0]    dc_axi4_bid;
    logic [1:0]                  dc_axi4_bresp;
    logic                        dc_axi4_bvalid;
    logic                        dc_axi4_bready;
    logic [AXI4_ID_WIDTH-1:0]    dc_axi4_arid;
    logic [PADDR_WIDTH-1:0]      dc_axi4_araddr;
    logic [7:0]                  dc_axi4_arlen;
    logic [2:0]                  dc_axi4_arsize;
    logic [1:0]                  dc_axi4_arburst;
    logic                        dc_axi4_arlock;
    logic [3:0]                  dc_axi4_arcache;
    logic [2:0]                  dc_axi4_arprot;
    logic [3:0]                  dc_axi4_arqos;
    logic                        dc_axi4_arvalid;
    logic                        dc_axi4_arready;
    logic [AXI4_ID_WIDTH-1:0]    dc_axi4_rid;
    logic [63:0]                 dc_axi4_rdata;
    logic [1:0]                  dc_axi4_rresp;
    logic                        dc_axi4_rlast;
    logic                        dc_axi4_rvalid;
    logic                        dc_axi4_rready;

    logic [PADDR_WIDTH-1:0]      ic_axil_awaddr;
    logic [2:0]                  ic_axil_awprot;
    logic                        ic_axil_awvalid;
    logic                        ic_axil_awready;
    logic [63:0]                 ic_axil_wdata;
    logic [7:0]                  ic_axil_wstrb;
    logic                        ic_axil_wvalid;
    logic                        ic_axil_wready;
    logic [1:0]                  ic_axil_bresp;
    logic                        ic_axil_bvalid;
    logic                        ic_axil_bready;
    logic [PADDR_WIDTH-1:0]      ic_axil_araddr;
    logic [2:0]                  ic_axil_arprot;
    logic                        ic_axil_arvalid;
    logic                        ic_axil_arready;
    logic [63:0]                 ic_axil_rdata;
    logic [1:0]                  ic_axil_rresp;
    logic                        ic_axil_rvalid;
    logic                        ic_axil_rready;

    logic [PADDR_WIDTH-1:0]      dc_axil_awaddr;
    logic [2:0]                  dc_axil_awprot;
    logic                        dc_axil_awvalid;
    logic                        dc_axil_awready;
    logic [63:0]                 dc_axil_wdata;
    logic [7:0]                  dc_axil_wstrb;
    logic                        dc_axil_wvalid;
    logic                        dc_axil_wready;
    logic [1:0]                  dc_axil_bresp;
    logic                        dc_axil_bvalid;
    logic                        dc_axil_bready;
    logic [PADDR_WIDTH-1:0]      dc_axil_araddr;
    logic [2:0]                  dc_axil_arprot;
    logic                        dc_axil_arvalid;
    logic                        dc_axil_arready;
    logic [63:0]                 dc_axil_rdata;
    logic [1:0]                  dc_axil_rresp;
    logic                        dc_axil_rvalid;
    logic                        dc_axil_rready;

    //=================================================================
    // Instruction cache (read only : the write channels are tied off)
    //=================================================================
    ICACHE
        #(
            .PADDR_WIDTH    (PADDR_WIDTH),
            .MEM_BASE       (MEM_BASE),
            .SETS           (IC_SETS),
            .WAYS           (IC_WAYS),
            .BLOCK_BYTES    (IC_BLOCK_BYTES),
            .FETCH_WIDTH    (FETCH_WIDTH),
            .REPLACE_RANDOM (REPLACE_RANDOM),
            .AXI4_ID_WIDTH  (AXI4_ID_WIDTH),
            .AXI4_ID        (AXI4_ID_IFILL)
        )
    u_icache
        (
            .clk            (clk),
            .rst_n          (rst_n),
            .i_req_valid    (i_req_valid),
            .i_req_ready    (i_req_ready),
            .i_req_addr     (i_req_addr),
            .i_resp_valid   (i_resp_valid),
            .i_resp_data    (i_resp_data),
            .i_resp_error   (i_resp_error),
            .i_flush_valid  (i_flush_valid),
            .i_flush_done   (i_flush_done),
            .i_kill         (i_kill),
            .m_axi4_arid    (ic_axi4_arid),
            .m_axi4_araddr  (ic_axi4_araddr),
            .m_axi4_arlen   (ic_axi4_arlen),
            .m_axi4_arsize  (ic_axi4_arsize),
            .m_axi4_arburst (ic_axi4_arburst),
            .m_axi4_arvalid (ic_axi4_arvalid),
            .m_axi4_arready (ic_axi4_arready),
            .m_axi4_rdata   (ic_axi4_rdata),
            .m_axi4_rresp   (ic_axi4_rresp),
            .m_axi4_rlast   (ic_axi4_rlast),
            .m_axi4_rvalid  (ic_axi4_rvalid),
            .m_axi4_rready  (ic_axi4_rready),
            .m_axil_araddr  (ic_axil_araddr),
            .m_axil_arvalid (ic_axil_arvalid),
            .m_axil_arready (ic_axil_arready),
            .m_axil_rdata   (ic_axil_rdata),
            .m_axil_rresp   (ic_axil_rresp),
            .m_axil_rvalid  (ic_axil_rvalid),
            .m_axil_rready  (ic_axil_rready)
        );

    // the instruction side never writes
    assign ic_axi4_awid    = '0;
    assign ic_axi4_awaddr  = '0;
    assign ic_axi4_awlen   = '0;
    assign ic_axi4_awsize  = '0;
    assign ic_axi4_awburst = '0;
    assign ic_axi4_awlock  = 1'b0;
    assign ic_axi4_awcache = '0;
    assign ic_axi4_awprot  = '0;
    assign ic_axi4_awqos   = '0;
    assign ic_axi4_awvalid = 1'b0;
    assign ic_axi4_wdata   = '0;
    assign ic_axi4_wstrb   = '0;
    assign ic_axi4_wlast   = 1'b0;
    assign ic_axi4_wvalid  = 1'b0;
    assign ic_axi4_bready  = 1'b0;
    assign ic_axi4_arlock  = 1'b0;
    assign ic_axi4_arcache = '0;
    assign ic_axi4_arprot  = '0;
    assign ic_axi4_arqos   = '0;
    assign ic_axil_awaddr  = '0;
    assign ic_axil_awprot  = '0;
    assign ic_axil_awvalid = 1'b0;
    assign ic_axil_wdata   = '0;
    assign ic_axil_wstrb   = '0;
    assign ic_axil_wvalid  = 1'b0;
    assign ic_axil_bready  = 1'b0;
    assign ic_axil_arprot  = '0;

    //=================================================================
    // Data cache port : CPU (priority) and debug module
    //=================================================================
    logic                   dc_req_valid, dc_req_ready;
    logic [PADDR_WIDTH-1:0] dc_req_addr;
    logic [1:0]             dc_req_size;
    logic [3:0]             dc_req_cmd;
    logic [XLEN-1:0]        dc_req_wdata;
    logic                   dc_resp_valid, dc_resp_error;
    logic [XLEN-1:0]        dc_resp_data;

    CACHE_PORT_ARB
        #(
            .PADDR_WIDTH   (PADDR_WIDTH),
            .XLEN          (XLEN),
            .DEPTH         (ROB_DEPTH)
        )
    u_port_arb
        (
            .clk            (clk),
            .rst_n          (rst_n),
            .s0_req_valid   (d_req_valid),
            .s0_req_ready   (d_req_ready),
            .s0_req_addr    (d_req_addr),
            .s0_req_size    (d_req_size),
            .s0_req_cmd     (d_req_cmd),
            .s0_req_wdata   (d_req_wdata),
            .s0_resp_valid  (d_resp_valid),
            .s0_resp_data   (d_resp_data),
            .s0_resp_error  (d_resp_error),
            .s1_req_valid   (dbg_req_valid),
            .s1_req_ready   (dbg_req_ready),
            .s1_req_addr    (dbg_req_addr),
            .s1_req_size    (dbg_req_size),
            .s1_req_cmd     (dbg_req_cmd),
            .s1_req_wdata   (dbg_req_wdata),
            .s1_resp_valid  (dbg_resp_valid),
            .s1_resp_data   (dbg_resp_data),
            .s1_resp_error  (dbg_resp_error),
            .m_req_valid    (dc_req_valid),
            .m_req_ready    (dc_req_ready),
            .m_req_addr     (dc_req_addr),
            .m_req_size     (dc_req_size),
            .m_req_cmd      (dc_req_cmd),
            .m_req_wdata    (dc_req_wdata),
            .m_resp_valid   (dc_resp_valid),
            .m_resp_data    (dc_resp_data),
            .m_resp_error   (dc_resp_error)
        );

    //=================================================================
    // Data cache
    //=================================================================
    DCACHE
        #(
            .PADDR_WIDTH    (PADDR_WIDTH),
            .XLEN           (XLEN),
            .MEM_BASE       (MEM_BASE),
            .SETS           (DC_SETS),
            .WAYS           (DC_WAYS),
            .BLOCK_BYTES    (DC_BLOCK_BYTES),
            .NUM_MSHR       (NUM_MSHR),
            .NUM_WB         (NUM_WB),
            .ROB_DEPTH      (ROB_DEPTH),
            .REPLACE_RANDOM (REPLACE_RANDOM),
            .AXI4_ID_WIDTH  (AXI4_ID_WIDTH),
            .AXI4_ID_FILL   (AXI4_ID_DFILL),
            .AXI4_ID_WB     (AXI4_ID_DWB)
        )
    u_dcache
        (
            .clk            (clk),
            .rst_n          (rst_n),
            .d_req_valid    (dc_req_valid),
            .d_req_ready    (dc_req_ready),
            .d_req_addr     (dc_req_addr),
            .d_req_size     (dc_req_size),
            .d_req_cmd      (dc_req_cmd),
            .d_req_wdata    (dc_req_wdata),
            .d_resp_valid   (dc_resp_valid),
            .d_resp_data    (dc_resp_data),
            .d_resp_error   (dc_resp_error),
            .m_axi4_awid    (dc_axi4_awid),
            .m_axi4_awaddr  (dc_axi4_awaddr),
            .m_axi4_awlen   (dc_axi4_awlen),
            .m_axi4_awsize  (dc_axi4_awsize),
            .m_axi4_awburst (dc_axi4_awburst),
            .m_axi4_awvalid (dc_axi4_awvalid),
            .m_axi4_awready (dc_axi4_awready),
            .m_axi4_wdata   (dc_axi4_wdata),
            .m_axi4_wstrb   (dc_axi4_wstrb),
            .m_axi4_wlast   (dc_axi4_wlast),
            .m_axi4_wvalid  (dc_axi4_wvalid),
            .m_axi4_wready  (dc_axi4_wready),
            .m_axi4_bresp   (dc_axi4_bresp),
            .m_axi4_bvalid  (dc_axi4_bvalid),
            .m_axi4_bready  (dc_axi4_bready),
            .m_axi4_arid    (dc_axi4_arid),
            .m_axi4_araddr  (dc_axi4_araddr),
            .m_axi4_arlen   (dc_axi4_arlen),
            .m_axi4_arsize  (dc_axi4_arsize),
            .m_axi4_arburst (dc_axi4_arburst),
            .m_axi4_arvalid (dc_axi4_arvalid),
            .m_axi4_arready (dc_axi4_arready),
            .m_axi4_rdata   (dc_axi4_rdata),
            .m_axi4_rresp   (dc_axi4_rresp),
            .m_axi4_rlast   (dc_axi4_rlast),
            .m_axi4_rvalid  (dc_axi4_rvalid),
            .m_axi4_rready  (dc_axi4_rready),
            .m_axil_awaddr  (dc_axil_awaddr),
            .m_axil_awvalid (dc_axil_awvalid),
            .m_axil_awready (dc_axil_awready),
            .m_axil_wdata   (dc_axil_wdata),
            .m_axil_wstrb   (dc_axil_wstrb),
            .m_axil_wvalid  (dc_axil_wvalid),
            .m_axil_wready  (dc_axil_wready),
            .m_axil_bresp   (dc_axil_bresp),
            .m_axil_bvalid  (dc_axil_bvalid),
            .m_axil_bready  (dc_axil_bready),
            .m_axil_araddr  (dc_axil_araddr),
            .m_axil_arvalid (dc_axil_arvalid),
            .m_axil_arready (dc_axil_arready),
            .m_axil_rdata   (dc_axil_rdata),
            .m_axil_rresp   (dc_axil_rresp),
            .m_axil_rvalid  (dc_axil_rvalid),
            .m_axil_rready  (dc_axil_rready)
        );

    assign dc_axi4_awlock  = 1'b0;
    assign dc_axi4_awcache = '0;
    assign dc_axi4_awprot  = '0;
    assign dc_axi4_awqos   = '0;
    assign dc_axi4_arlock  = 1'b0;
    assign dc_axi4_arcache = '0;
    assign dc_axi4_arprot  = '0;
    assign dc_axi4_arqos   = '0;
    assign dc_axil_awprot  = '0;
    assign dc_axil_arprot  = '0;

    //=================================================================
    // Arbitration : s0 = data (priority), s1 = instruction
    //=================================================================
    BUS_ARB
        #(
            .AXI4_ID_WIDTH   (AXI4_ID_WIDTH),
            .AXI4_ADDR_WIDTH (PADDR_WIDTH),
            .AXI4_DATA_WIDTH (64),
            .AXIL_ADDR_WIDTH (PADDR_WIDTH),
            .AXIL_DATA_WIDTH (64)
        )
    u_arb
        (
            .clk             (clk),
            .rst_n           (rst_n),
            .s0_axi4_awid    (dc_axi4_awid),
            .s0_axi4_awaddr  (dc_axi4_awaddr),
            .s0_axi4_awlen   (dc_axi4_awlen),
            .s0_axi4_awsize  (dc_axi4_awsize),
            .s0_axi4_awburst (dc_axi4_awburst),
            .s0_axi4_awlock  (dc_axi4_awlock),
            .s0_axi4_awcache (dc_axi4_awcache),
            .s0_axi4_awprot  (dc_axi4_awprot),
            .s0_axi4_awqos   (dc_axi4_awqos),
            .s0_axi4_awvalid (dc_axi4_awvalid),
            .s0_axi4_awready (dc_axi4_awready),
            .s0_axi4_wdata   (dc_axi4_wdata),
            .s0_axi4_wstrb   (dc_axi4_wstrb),
            .s0_axi4_wlast   (dc_axi4_wlast),
            .s0_axi4_wvalid  (dc_axi4_wvalid),
            .s0_axi4_wready  (dc_axi4_wready),
            .s0_axi4_bid     (dc_axi4_bid),
            .s0_axi4_bresp   (dc_axi4_bresp),
            .s0_axi4_bvalid  (dc_axi4_bvalid),
            .s0_axi4_bready  (dc_axi4_bready),
            .s0_axi4_arid    (dc_axi4_arid),
            .s0_axi4_araddr  (dc_axi4_araddr),
            .s0_axi4_arlen   (dc_axi4_arlen),
            .s0_axi4_arsize  (dc_axi4_arsize),
            .s0_axi4_arburst (dc_axi4_arburst),
            .s0_axi4_arlock  (dc_axi4_arlock),
            .s0_axi4_arcache (dc_axi4_arcache),
            .s0_axi4_arprot  (dc_axi4_arprot),
            .s0_axi4_arqos   (dc_axi4_arqos),
            .s0_axi4_arvalid (dc_axi4_arvalid),
            .s0_axi4_arready (dc_axi4_arready),
            .s0_axi4_rid     (dc_axi4_rid),
            .s0_axi4_rdata   (dc_axi4_rdata),
            .s0_axi4_rresp   (dc_axi4_rresp),
            .s0_axi4_rlast   (dc_axi4_rlast),
            .s0_axi4_rvalid  (dc_axi4_rvalid),
            .s0_axi4_rready  (dc_axi4_rready),
            .s1_axi4_awid    (ic_axi4_awid),
            .s1_axi4_awaddr  (ic_axi4_awaddr),
            .s1_axi4_awlen   (ic_axi4_awlen),
            .s1_axi4_awsize  (ic_axi4_awsize),
            .s1_axi4_awburst (ic_axi4_awburst),
            .s1_axi4_awlock  (ic_axi4_awlock),
            .s1_axi4_awcache (ic_axi4_awcache),
            .s1_axi4_awprot  (ic_axi4_awprot),
            .s1_axi4_awqos   (ic_axi4_awqos),
            .s1_axi4_awvalid (ic_axi4_awvalid),
            .s1_axi4_awready (ic_axi4_awready),
            .s1_axi4_wdata   (ic_axi4_wdata),
            .s1_axi4_wstrb   (ic_axi4_wstrb),
            .s1_axi4_wlast   (ic_axi4_wlast),
            .s1_axi4_wvalid  (ic_axi4_wvalid),
            .s1_axi4_wready  (ic_axi4_wready),
            .s1_axi4_bid     (ic_axi4_bid),
            .s1_axi4_bresp   (ic_axi4_bresp),
            .s1_axi4_bvalid  (ic_axi4_bvalid),
            .s1_axi4_bready  (ic_axi4_bready),
            .s1_axi4_arid    (ic_axi4_arid),
            .s1_axi4_araddr  (ic_axi4_araddr),
            .s1_axi4_arlen   (ic_axi4_arlen),
            .s1_axi4_arsize  (ic_axi4_arsize),
            .s1_axi4_arburst (ic_axi4_arburst),
            .s1_axi4_arlock  (ic_axi4_arlock),
            .s1_axi4_arcache (ic_axi4_arcache),
            .s1_axi4_arprot  (ic_axi4_arprot),
            .s1_axi4_arqos   (ic_axi4_arqos),
            .s1_axi4_arvalid (ic_axi4_arvalid),
            .s1_axi4_arready (ic_axi4_arready),
            .s1_axi4_rid     (ic_axi4_rid),
            .s1_axi4_rdata   (ic_axi4_rdata),
            .s1_axi4_rresp   (ic_axi4_rresp),
            .s1_axi4_rlast   (ic_axi4_rlast),
            .s1_axi4_rvalid  (ic_axi4_rvalid),
            .s1_axi4_rready  (ic_axi4_rready),
            .m_axi4_awid    (m_axi4_awid),
            .m_axi4_awaddr  (m_axi4_awaddr),
            .m_axi4_awlen   (m_axi4_awlen),
            .m_axi4_awsize  (m_axi4_awsize),
            .m_axi4_awburst (m_axi4_awburst),
            .m_axi4_awlock  (m_axi4_awlock),
            .m_axi4_awcache (m_axi4_awcache),
            .m_axi4_awprot  (m_axi4_awprot),
            .m_axi4_awqos   (m_axi4_awqos),
            .m_axi4_awvalid (m_axi4_awvalid),
            .m_axi4_awready (m_axi4_awready),
            .m_axi4_wdata   (m_axi4_wdata),
            .m_axi4_wstrb   (m_axi4_wstrb),
            .m_axi4_wlast   (m_axi4_wlast),
            .m_axi4_wvalid  (m_axi4_wvalid),
            .m_axi4_wready  (m_axi4_wready),
            .m_axi4_bid     (m_axi4_bid),
            .m_axi4_bresp   (m_axi4_bresp),
            .m_axi4_bvalid  (m_axi4_bvalid),
            .m_axi4_bready  (m_axi4_bready),
            .m_axi4_arid    (m_axi4_arid),
            .m_axi4_araddr  (m_axi4_araddr),
            .m_axi4_arlen   (m_axi4_arlen),
            .m_axi4_arsize  (m_axi4_arsize),
            .m_axi4_arburst (m_axi4_arburst),
            .m_axi4_arlock  (m_axi4_arlock),
            .m_axi4_arcache (m_axi4_arcache),
            .m_axi4_arprot  (m_axi4_arprot),
            .m_axi4_arqos   (m_axi4_arqos),
            .m_axi4_arvalid (m_axi4_arvalid),
            .m_axi4_arready (m_axi4_arready),
            .m_axi4_rid     (m_axi4_rid),
            .m_axi4_rdata   (m_axi4_rdata),
            .m_axi4_rresp   (m_axi4_rresp),
            .m_axi4_rlast   (m_axi4_rlast),
            .m_axi4_rvalid  (m_axi4_rvalid),
            .m_axi4_rready  (m_axi4_rready),
            .s0_axil_awaddr  (dc_axil_awaddr),
            .s0_axil_awprot  (dc_axil_awprot),
            .s0_axil_awvalid (dc_axil_awvalid),
            .s0_axil_awready (dc_axil_awready),
            .s0_axil_wdata   (dc_axil_wdata),
            .s0_axil_wstrb   (dc_axil_wstrb),
            .s0_axil_wvalid  (dc_axil_wvalid),
            .s0_axil_wready  (dc_axil_wready),
            .s0_axil_bresp   (dc_axil_bresp),
            .s0_axil_bvalid  (dc_axil_bvalid),
            .s0_axil_bready  (dc_axil_bready),
            .s0_axil_araddr  (dc_axil_araddr),
            .s0_axil_arprot  (dc_axil_arprot),
            .s0_axil_arvalid (dc_axil_arvalid),
            .s0_axil_arready (dc_axil_arready),
            .s0_axil_rdata   (dc_axil_rdata),
            .s0_axil_rresp   (dc_axil_rresp),
            .s0_axil_rvalid  (dc_axil_rvalid),
            .s0_axil_rready  (dc_axil_rready),
            .s1_axil_awaddr  (ic_axil_awaddr),
            .s1_axil_awprot  (ic_axil_awprot),
            .s1_axil_awvalid (ic_axil_awvalid),
            .s1_axil_awready (ic_axil_awready),
            .s1_axil_wdata   (ic_axil_wdata),
            .s1_axil_wstrb   (ic_axil_wstrb),
            .s1_axil_wvalid  (ic_axil_wvalid),
            .s1_axil_wready  (ic_axil_wready),
            .s1_axil_bresp   (ic_axil_bresp),
            .s1_axil_bvalid  (ic_axil_bvalid),
            .s1_axil_bready  (ic_axil_bready),
            .s1_axil_araddr  (ic_axil_araddr),
            .s1_axil_arprot  (ic_axil_arprot),
            .s1_axil_arvalid (ic_axil_arvalid),
            .s1_axil_arready (ic_axil_arready),
            .s1_axil_rdata   (ic_axil_rdata),
            .s1_axil_rresp   (ic_axil_rresp),
            .s1_axil_rvalid  (ic_axil_rvalid),
            .s1_axil_rready  (ic_axil_rready),
            .m_axil_awaddr  (m_axil_awaddr),
            .m_axil_awprot  (m_axil_awprot),
            .m_axil_awvalid (m_axil_awvalid),
            .m_axil_awready (m_axil_awready),
            .m_axil_wdata   (m_axil_wdata),
            .m_axil_wstrb   (m_axil_wstrb),
            .m_axil_wvalid  (m_axil_wvalid),
            .m_axil_wready  (m_axil_wready),
            .m_axil_bresp   (m_axil_bresp),
            .m_axil_bvalid  (m_axil_bvalid),
            .m_axil_bready  (m_axil_bready),
            .m_axil_araddr  (m_axil_araddr),
            .m_axil_arprot  (m_axil_arprot),
            .m_axil_arvalid (m_axil_arvalid),
            .m_axil_arready (m_axil_arready),
            .m_axil_rdata   (m_axil_rdata),
            .m_axil_rresp   (m_axil_rresp),
            .m_axil_rvalid  (m_axil_rvalid),
            .m_axil_rready  (m_axil_rready)
        );

endmodule : CPU_CACHE
