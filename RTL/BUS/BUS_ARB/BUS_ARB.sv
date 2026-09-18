//---------------------------------------------------------------------------
// BUS_ARB.sv
//
// 2-master arbiter for the mmRISC-2 memory bus (AXI4) and peripheral bus
// (AXI4-Lite).
//
//   s0 : debug bus master (DBG_BUSMST)  -- higher priority
//   s1 : CPU (currently CPU_BFM)
//   m  : CPU_TOP bus port
//
//   - Transaction lock: a grant is taken when a master raises AWVALID or
//     WVALID (write) / ARVALID (read) and is held until the B handshake
//     (write) / the last R handshake (read). The grant is registered, so the
//     first handshake happens one cycle after the request.
//   - Read and write paths, and the AXI4 and AXI4-Lite buses, are arbitrated
//     independently. Fixed priority: s0 first.
//   - AXI IDs are passed through unchanged (masters use distinct IDs).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module BUS_ARB
    #(
        parameter int AXI4_ID_WIDTH   = 4,
        parameter int AXI4_ADDR_WIDTH = 40,
        parameter int AXI4_DATA_WIDTH = 64,
        parameter int AXIL_ADDR_WIDTH = 40,
        parameter int AXIL_DATA_WIDTH = 64
    )
    (
        input  logic clk,
        input  logic rst_n,

        //=============================================================
        // AXI4 slave port 0 (debug)
        //=============================================================
        input  logic [AXI4_ID_WIDTH-1:0]     s0_axi4_awid,
        input  logic [AXI4_ADDR_WIDTH-1:0]   s0_axi4_awaddr,
        input  logic [7:0]                   s0_axi4_awlen,
        input  logic [2:0]                   s0_axi4_awsize,
        input  logic [1:0]                   s0_axi4_awburst,
        input  logic                         s0_axi4_awlock,
        input  logic [3:0]                   s0_axi4_awcache,
        input  logic [2:0]                   s0_axi4_awprot,
        input  logic [3:0]                   s0_axi4_awqos,
        input  logic                         s0_axi4_awvalid,
        output logic                         s0_axi4_awready,
        input  logic [AXI4_DATA_WIDTH-1:0]   s0_axi4_wdata,
        input  logic [AXI4_DATA_WIDTH/8-1:0] s0_axi4_wstrb,
        input  logic                         s0_axi4_wlast,
        input  logic                         s0_axi4_wvalid,
        output logic                         s0_axi4_wready,
        output logic [AXI4_ID_WIDTH-1:0]     s0_axi4_bid,
        output logic [1:0]                   s0_axi4_bresp,
        output logic                         s0_axi4_bvalid,
        input  logic                         s0_axi4_bready,
        input  logic [AXI4_ID_WIDTH-1:0]     s0_axi4_arid,
        input  logic [AXI4_ADDR_WIDTH-1:0]   s0_axi4_araddr,
        input  logic [7:0]                   s0_axi4_arlen,
        input  logic [2:0]                   s0_axi4_arsize,
        input  logic [1:0]                   s0_axi4_arburst,
        input  logic                         s0_axi4_arlock,
        input  logic [3:0]                   s0_axi4_arcache,
        input  logic [2:0]                   s0_axi4_arprot,
        input  logic [3:0]                   s0_axi4_arqos,
        input  logic                         s0_axi4_arvalid,
        output logic                         s0_axi4_arready,
        output logic [AXI4_ID_WIDTH-1:0]     s0_axi4_rid,
        output logic [AXI4_DATA_WIDTH-1:0]   s0_axi4_rdata,
        output logic [1:0]                   s0_axi4_rresp,
        output logic                         s0_axi4_rlast,
        output logic                         s0_axi4_rvalid,
        input  logic                         s0_axi4_rready,

        //=============================================================
        // AXI4 slave port 1 (CPU)
        //=============================================================
        input  logic [AXI4_ID_WIDTH-1:0]     s1_axi4_awid,
        input  logic [AXI4_ADDR_WIDTH-1:0]   s1_axi4_awaddr,
        input  logic [7:0]                   s1_axi4_awlen,
        input  logic [2:0]                   s1_axi4_awsize,
        input  logic [1:0]                   s1_axi4_awburst,
        input  logic                         s1_axi4_awlock,
        input  logic [3:0]                   s1_axi4_awcache,
        input  logic [2:0]                   s1_axi4_awprot,
        input  logic [3:0]                   s1_axi4_awqos,
        input  logic                         s1_axi4_awvalid,
        output logic                         s1_axi4_awready,
        input  logic [AXI4_DATA_WIDTH-1:0]   s1_axi4_wdata,
        input  logic [AXI4_DATA_WIDTH/8-1:0] s1_axi4_wstrb,
        input  logic                         s1_axi4_wlast,
        input  logic                         s1_axi4_wvalid,
        output logic                         s1_axi4_wready,
        output logic [AXI4_ID_WIDTH-1:0]     s1_axi4_bid,
        output logic [1:0]                   s1_axi4_bresp,
        output logic                         s1_axi4_bvalid,
        input  logic                         s1_axi4_bready,
        input  logic [AXI4_ID_WIDTH-1:0]     s1_axi4_arid,
        input  logic [AXI4_ADDR_WIDTH-1:0]   s1_axi4_araddr,
        input  logic [7:0]                   s1_axi4_arlen,
        input  logic [2:0]                   s1_axi4_arsize,
        input  logic [1:0]                   s1_axi4_arburst,
        input  logic                         s1_axi4_arlock,
        input  logic [3:0]                   s1_axi4_arcache,
        input  logic [2:0]                   s1_axi4_arprot,
        input  logic [3:0]                   s1_axi4_arqos,
        input  logic                         s1_axi4_arvalid,
        output logic                         s1_axi4_arready,
        output logic [AXI4_ID_WIDTH-1:0]     s1_axi4_rid,
        output logic [AXI4_DATA_WIDTH-1:0]   s1_axi4_rdata,
        output logic [1:0]                   s1_axi4_rresp,
        output logic                         s1_axi4_rlast,
        output logic                         s1_axi4_rvalid,
        input  logic                         s1_axi4_rready,

        //=============================================================
        // AXI4 master port
        //=============================================================
        output logic [AXI4_ID_WIDTH-1:0]     m_axi4_awid,
        output logic [AXI4_ADDR_WIDTH-1:0]   m_axi4_awaddr,
        output logic [7:0]                   m_axi4_awlen,
        output logic [2:0]                   m_axi4_awsize,
        output logic [1:0]                   m_axi4_awburst,
        output logic                         m_axi4_awlock,
        output logic [3:0]                   m_axi4_awcache,
        output logic [2:0]                   m_axi4_awprot,
        output logic [3:0]                   m_axi4_awqos,
        output logic                         m_axi4_awvalid,
        input  logic                         m_axi4_awready,
        output logic [AXI4_DATA_WIDTH-1:0]   m_axi4_wdata,
        output logic [AXI4_DATA_WIDTH/8-1:0] m_axi4_wstrb,
        output logic                         m_axi4_wlast,
        output logic                         m_axi4_wvalid,
        input  logic                         m_axi4_wready,
        input  logic [AXI4_ID_WIDTH-1:0]     m_axi4_bid,
        input  logic [1:0]                   m_axi4_bresp,
        input  logic                         m_axi4_bvalid,
        output logic                         m_axi4_bready,
        output logic [AXI4_ID_WIDTH-1:0]     m_axi4_arid,
        output logic [AXI4_ADDR_WIDTH-1:0]   m_axi4_araddr,
        output logic [7:0]                   m_axi4_arlen,
        output logic [2:0]                   m_axi4_arsize,
        output logic [1:0]                   m_axi4_arburst,
        output logic                         m_axi4_arlock,
        output logic [3:0]                   m_axi4_arcache,
        output logic [2:0]                   m_axi4_arprot,
        output logic [3:0]                   m_axi4_arqos,
        output logic                         m_axi4_arvalid,
        input  logic                         m_axi4_arready,
        input  logic [AXI4_ID_WIDTH-1:0]     m_axi4_rid,
        input  logic [AXI4_DATA_WIDTH-1:0]   m_axi4_rdata,
        input  logic [1:0]                   m_axi4_rresp,
        input  logic                         m_axi4_rlast,
        input  logic                         m_axi4_rvalid,
        output logic                         m_axi4_rready,

        //=============================================================
        // AXI4-Lite slave port 0 (debug)
        //=============================================================
        input  logic [AXIL_ADDR_WIDTH-1:0]   s0_axil_awaddr,
        input  logic [2:0]                   s0_axil_awprot,
        input  logic                         s0_axil_awvalid,
        output logic                         s0_axil_awready,
        input  logic [AXIL_DATA_WIDTH-1:0]   s0_axil_wdata,
        input  logic [AXIL_DATA_WIDTH/8-1:0] s0_axil_wstrb,
        input  logic                         s0_axil_wvalid,
        output logic                         s0_axil_wready,
        output logic [1:0]                   s0_axil_bresp,
        output logic                         s0_axil_bvalid,
        input  logic                         s0_axil_bready,
        input  logic [AXIL_ADDR_WIDTH-1:0]   s0_axil_araddr,
        input  logic [2:0]                   s0_axil_arprot,
        input  logic                         s0_axil_arvalid,
        output logic                         s0_axil_arready,
        output logic [AXIL_DATA_WIDTH-1:0]   s0_axil_rdata,
        output logic [1:0]                   s0_axil_rresp,
        output logic                         s0_axil_rvalid,
        input  logic                         s0_axil_rready,

        //=============================================================
        // AXI4-Lite slave port 1 (CPU)
        //=============================================================
        input  logic [AXIL_ADDR_WIDTH-1:0]   s1_axil_awaddr,
        input  logic [2:0]                   s1_axil_awprot,
        input  logic                         s1_axil_awvalid,
        output logic                         s1_axil_awready,
        input  logic [AXIL_DATA_WIDTH-1:0]   s1_axil_wdata,
        input  logic [AXIL_DATA_WIDTH/8-1:0] s1_axil_wstrb,
        input  logic                         s1_axil_wvalid,
        output logic                         s1_axil_wready,
        output logic [1:0]                   s1_axil_bresp,
        output logic                         s1_axil_bvalid,
        input  logic                         s1_axil_bready,
        input  logic [AXIL_ADDR_WIDTH-1:0]   s1_axil_araddr,
        input  logic [2:0]                   s1_axil_arprot,
        input  logic                         s1_axil_arvalid,
        output logic                         s1_axil_arready,
        output logic [AXIL_DATA_WIDTH-1:0]   s1_axil_rdata,
        output logic [1:0]                   s1_axil_rresp,
        output logic                         s1_axil_rvalid,
        input  logic                         s1_axil_rready,

        //=============================================================
        // AXI4-Lite master port
        //=============================================================
        output logic [AXIL_ADDR_WIDTH-1:0]   m_axil_awaddr,
        output logic [2:0]                   m_axil_awprot,
        output logic                         m_axil_awvalid,
        input  logic                         m_axil_awready,
        output logic [AXIL_DATA_WIDTH-1:0]   m_axil_wdata,
        output logic [AXIL_DATA_WIDTH/8-1:0] m_axil_wstrb,
        output logic                         m_axil_wvalid,
        input  logic                         m_axil_wready,
        input  logic [1:0]                   m_axil_bresp,
        input  logic                         m_axil_bvalid,
        output logic                         m_axil_bready,
        output logic [AXIL_ADDR_WIDTH-1:0]   m_axil_araddr,
        output logic [2:0]                   m_axil_arprot,
        output logic                         m_axil_arvalid,
        input  logic                         m_axil_arready,
        input  logic [AXIL_DATA_WIDTH-1:0]   m_axil_rdata,
        input  logic [1:0]                   m_axil_rresp,
        input  logic                         m_axil_rvalid,
        output logic                         m_axil_rready
    );

    //=================================================================
    // Grant state
    //=================================================================
    // *_act : a grant is active, *_g1 : granted master is s1 (else s0)
    logic x4w_act, x4w_g1;   // AXI4 write
    logic x4r_act, x4r_g1;   // AXI4 read
    logic xlw_act, xlw_g1;   // AXI4-Lite write
    logic xlr_act, xlr_g1;   // AXI4-Lite read

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x4w_act <= 1'b0; x4w_g1 <= 1'b0;
            x4r_act <= 1'b0; x4r_g1 <= 1'b0;
            xlw_act <= 1'b0; xlw_g1 <= 1'b0;
            xlr_act <= 1'b0; xlr_g1 <= 1'b0;
        end else begin
            // AXI4 write
            if (!x4w_act) begin
                if (s0_axi4_awvalid | s0_axi4_wvalid) begin
                    x4w_act <= 1'b1; x4w_g1 <= 1'b0;
                end else if (s1_axi4_awvalid | s1_axi4_wvalid) begin
                    x4w_act <= 1'b1; x4w_g1 <= 1'b1;
                end
            end else if (m_axi4_bvalid & m_axi4_bready) begin
                x4w_act <= 1'b0;
            end
            // AXI4 read
            if (!x4r_act) begin
                if (s0_axi4_arvalid) begin
                    x4r_act <= 1'b1; x4r_g1 <= 1'b0;
                end else if (s1_axi4_arvalid) begin
                    x4r_act <= 1'b1; x4r_g1 <= 1'b1;
                end
            end else if (m_axi4_rvalid & m_axi4_rready & m_axi4_rlast) begin
                x4r_act <= 1'b0;
            end
            // AXI4-Lite write
            if (!xlw_act) begin
                if (s0_axil_awvalid | s0_axil_wvalid) begin
                    xlw_act <= 1'b1; xlw_g1 <= 1'b0;
                end else if (s1_axil_awvalid | s1_axil_wvalid) begin
                    xlw_act <= 1'b1; xlw_g1 <= 1'b1;
                end
            end else if (m_axil_bvalid & m_axil_bready) begin
                xlw_act <= 1'b0;
            end
            // AXI4-Lite read
            if (!xlr_act) begin
                if (s0_axil_arvalid) begin
                    xlr_act <= 1'b1; xlr_g1 <= 1'b0;
                end else if (s1_axil_arvalid) begin
                    xlr_act <= 1'b1; xlr_g1 <= 1'b1;
                end
            end else if (m_axil_rvalid & m_axil_rready) begin
                xlr_act <= 1'b0;
            end
        end
    end

    logic x4w_s0, x4w_s1, x4r_s0, x4r_s1;
    logic xlw_s0, xlw_s1, xlr_s0, xlr_s1;
    assign x4w_s0 = x4w_act & ~x4w_g1;
    assign x4w_s1 = x4w_act &  x4w_g1;
    assign x4r_s0 = x4r_act & ~x4r_g1;
    assign x4r_s1 = x4r_act &  x4r_g1;
    assign xlw_s0 = xlw_act & ~xlw_g1;
    assign xlw_s1 = xlw_act &  xlw_g1;
    assign xlr_s0 = xlr_act & ~xlr_g1;
    assign xlr_s1 = xlr_act &  xlr_g1;

    //=================================================================
    // AXI4 write path
    //=================================================================
    assign m_axi4_awid     = x4w_g1 ? s1_axi4_awid    : s0_axi4_awid;
    assign m_axi4_awaddr   = x4w_g1 ? s1_axi4_awaddr  : s0_axi4_awaddr;
    assign m_axi4_awlen    = x4w_g1 ? s1_axi4_awlen   : s0_axi4_awlen;
    assign m_axi4_awsize   = x4w_g1 ? s1_axi4_awsize  : s0_axi4_awsize;
    assign m_axi4_awburst  = x4w_g1 ? s1_axi4_awburst : s0_axi4_awburst;
    assign m_axi4_awlock   = x4w_g1 ? s1_axi4_awlock  : s0_axi4_awlock;
    assign m_axi4_awcache  = x4w_g1 ? s1_axi4_awcache : s0_axi4_awcache;
    assign m_axi4_awprot   = x4w_g1 ? s1_axi4_awprot  : s0_axi4_awprot;
    assign m_axi4_awqos    = x4w_g1 ? s1_axi4_awqos   : s0_axi4_awqos;
    assign m_axi4_awvalid  = (x4w_s0 & s0_axi4_awvalid) | (x4w_s1 & s1_axi4_awvalid);
    assign m_axi4_wdata    = x4w_g1 ? s1_axi4_wdata   : s0_axi4_wdata;
    assign m_axi4_wstrb    = x4w_g1 ? s1_axi4_wstrb   : s0_axi4_wstrb;
    assign m_axi4_wlast    = x4w_g1 ? s1_axi4_wlast   : s0_axi4_wlast;
    assign m_axi4_wvalid   = (x4w_s0 & s0_axi4_wvalid) | (x4w_s1 & s1_axi4_wvalid);
    assign m_axi4_bready   = (x4w_s0 & s0_axi4_bready) | (x4w_s1 & s1_axi4_bready);

    assign s0_axi4_awready = x4w_s0 & m_axi4_awready;
    assign s1_axi4_awready = x4w_s1 & m_axi4_awready;
    assign s0_axi4_wready  = x4w_s0 & m_axi4_wready;
    assign s1_axi4_wready  = x4w_s1 & m_axi4_wready;
    assign s0_axi4_bid     = m_axi4_bid;
    assign s1_axi4_bid     = m_axi4_bid;
    assign s0_axi4_bresp   = m_axi4_bresp;
    assign s1_axi4_bresp   = m_axi4_bresp;
    assign s0_axi4_bvalid  = x4w_s0 & m_axi4_bvalid;
    assign s1_axi4_bvalid  = x4w_s1 & m_axi4_bvalid;

    //=================================================================
    // AXI4 read path
    //=================================================================
    assign m_axi4_arid     = x4r_g1 ? s1_axi4_arid    : s0_axi4_arid;
    assign m_axi4_araddr   = x4r_g1 ? s1_axi4_araddr  : s0_axi4_araddr;
    assign m_axi4_arlen    = x4r_g1 ? s1_axi4_arlen   : s0_axi4_arlen;
    assign m_axi4_arsize   = x4r_g1 ? s1_axi4_arsize  : s0_axi4_arsize;
    assign m_axi4_arburst  = x4r_g1 ? s1_axi4_arburst : s0_axi4_arburst;
    assign m_axi4_arlock   = x4r_g1 ? s1_axi4_arlock  : s0_axi4_arlock;
    assign m_axi4_arcache  = x4r_g1 ? s1_axi4_arcache : s0_axi4_arcache;
    assign m_axi4_arprot   = x4r_g1 ? s1_axi4_arprot  : s0_axi4_arprot;
    assign m_axi4_arqos    = x4r_g1 ? s1_axi4_arqos   : s0_axi4_arqos;
    assign m_axi4_arvalid  = (x4r_s0 & s0_axi4_arvalid) | (x4r_s1 & s1_axi4_arvalid);
    assign m_axi4_rready   = (x4r_s0 & s0_axi4_rready)  | (x4r_s1 & s1_axi4_rready);

    assign s0_axi4_arready = x4r_s0 & m_axi4_arready;
    assign s1_axi4_arready = x4r_s1 & m_axi4_arready;
    assign s0_axi4_rid     = m_axi4_rid;
    assign s1_axi4_rid     = m_axi4_rid;
    assign s0_axi4_rdata   = m_axi4_rdata;
    assign s1_axi4_rdata   = m_axi4_rdata;
    assign s0_axi4_rresp   = m_axi4_rresp;
    assign s1_axi4_rresp   = m_axi4_rresp;
    assign s0_axi4_rlast   = m_axi4_rlast;
    assign s1_axi4_rlast   = m_axi4_rlast;
    assign s0_axi4_rvalid  = x4r_s0 & m_axi4_rvalid;
    assign s1_axi4_rvalid  = x4r_s1 & m_axi4_rvalid;

    //=================================================================
    // AXI4-Lite write path
    //=================================================================
    assign m_axil_awaddr   = xlw_g1 ? s1_axil_awaddr : s0_axil_awaddr;
    assign m_axil_awprot   = xlw_g1 ? s1_axil_awprot : s0_axil_awprot;
    assign m_axil_awvalid  = (xlw_s0 & s0_axil_awvalid) | (xlw_s1 & s1_axil_awvalid);
    assign m_axil_wdata    = xlw_g1 ? s1_axil_wdata  : s0_axil_wdata;
    assign m_axil_wstrb    = xlw_g1 ? s1_axil_wstrb  : s0_axil_wstrb;
    assign m_axil_wvalid   = (xlw_s0 & s0_axil_wvalid) | (xlw_s1 & s1_axil_wvalid);
    assign m_axil_bready   = (xlw_s0 & s0_axil_bready) | (xlw_s1 & s1_axil_bready);

    assign s0_axil_awready = xlw_s0 & m_axil_awready;
    assign s1_axil_awready = xlw_s1 & m_axil_awready;
    assign s0_axil_wready  = xlw_s0 & m_axil_wready;
    assign s1_axil_wready  = xlw_s1 & m_axil_wready;
    assign s0_axil_bresp   = m_axil_bresp;
    assign s1_axil_bresp   = m_axil_bresp;
    assign s0_axil_bvalid  = xlw_s0 & m_axil_bvalid;
    assign s1_axil_bvalid  = xlw_s1 & m_axil_bvalid;

    //=================================================================
    // AXI4-Lite read path
    //=================================================================
    assign m_axil_araddr   = xlr_g1 ? s1_axil_araddr : s0_axil_araddr;
    assign m_axil_arprot   = xlr_g1 ? s1_axil_arprot : s0_axil_arprot;
    assign m_axil_arvalid  = (xlr_s0 & s0_axil_arvalid) | (xlr_s1 & s1_axil_arvalid);
    assign m_axil_rready   = (xlr_s0 & s0_axil_rready)  | (xlr_s1 & s1_axil_rready);

    assign s0_axil_arready = xlr_s0 & m_axil_arready;
    assign s1_axil_arready = xlr_s1 & m_axil_arready;
    assign s0_axil_rdata   = m_axil_rdata;
    assign s1_axil_rdata   = m_axil_rdata;
    assign s0_axil_rresp   = m_axil_rresp;
    assign s1_axil_rresp   = m_axil_rresp;
    assign s0_axil_rvalid  = xlr_s0 & m_axil_rvalid;
    assign s1_axil_rvalid  = xlr_s1 & m_axil_rvalid;

endmodule : BUS_ARB
