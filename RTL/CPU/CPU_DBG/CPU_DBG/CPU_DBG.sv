//---------------------------------------------------------------------------
// CPU_DBG.sv
//
// mmRISC-2 debug logic top (RISC-V Debug Spec 1.0, JTAG / cJTAG)
//
//   DBG_CJTAG ─ DBG_DTM ─ DBG_CDC ─ DBG_DM ─┬─ DBG_HART_STUB (provisional)
//   [TCK domain]                [clk domain]  └─ DBG_BUSMST ─ AXI4 / AXI4-Lite
//
// Reset domains
//   rst_dbg_n : debug power-on reset. Resets DTM, CDC and DM.
//               Synchronized separately to TCK and clk.
//   jtag_trst_n: resets the TAP / DTM registers only.
//   rst_n     : system reset. Combined with ndmreset it resets the bus side
//               (rst_bus_n, also used by CPU_TOP for the arbiter / CPU) and
//               the hart. It never resets the DM.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_DBG
    #(
        parameter int          AXI4_ID_WIDTH  = 4,
        parameter int          ADDR_WIDTH     = 40,
        parameter logic [31:0] IDCODE         = 32'h26d6d001,
        parameter logic [63:0] MISA           = 64'h8000_0000_0014_112d,
        parameter logic [31:0] MVENDORID      = 32'h0000_0000,
        parameter logic [63:0] MARCHID        = 64'h0000_0000_6d6d_3032,
        parameter logic [63:0] MIMPL          = 64'h0000_0000_0000_0001,
        parameter logic [63:0] MHARTID        = 64'h0,
        parameter logic [63:0] RESET_VECTOR   = 64'h0000_0000_8000_0000,
        parameter logic [39:0] MEM_BASE       = 40'h00_8000_0000,
        parameter logic [AXI4_ID_WIDTH-1:0] DBG_AXI4_ID = 1,
        parameter int          SBA_TIMEOUT    = 1 << 20,
        // 1 : memory bus accesses of the debugger go through the data cache
        //     (CPU_CACHE_SPEC.md 4.7), 0 : straight to the memory bus
        parameter int          DBG_VIA_CACHE  = 1
    )
    (
        input  logic        clk,
        input  logic        rst_dbg_n,       // debug power-on reset
        input  logic        rst_n,           // system reset
        output logic        rst_bus_n,       // synchronized system reset (incl. ndmreset)
        output logic        ndmreset,

        // JTAG / cJTAG pins
        input  logic        jtag_tck,
        input  logic        jtag_tms_i,
        output logic        jtag_tms_o,
        output logic        jtag_tms_oe,
        input  logic        jtag_tdi,
        output logic        jtag_tdo,
        output logic        jtag_tdo_oe,
        input  logic        jtag_trst_n,
        input  logic        cjtag_en,
        output logic        cjtag_online,

        // authentication
        input  logic        dbg_auth_en,
        input  logic [31:0] dbg_auth_key,

        // status
        output logic        dbg_halted,
        output logic        dbg_running,
        output logic        dbg_dmactive,

        // memory bus : AXI4 master
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_awid,
        output logic [ADDR_WIDTH-1:0]    m_axi4_awaddr,
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
        output logic [ADDR_WIDTH-1:0]    m_axi4_araddr,
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

        // peripheral bus : AXI4-Lite master
        output logic [ADDR_WIDTH-1:0]    m_axil_awaddr,
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
        output logic [ADDR_WIDTH-1:0]    m_axil_araddr,
        output logic [2:0]               m_axil_arprot,
        output logic                     m_axil_arvalid,
        input  logic                     m_axil_arready,
        input  logic [63:0]              m_axil_rdata,
        input  logic [1:0]               m_axil_rresp,
        input  logic                     m_axil_rvalid,
        output logic                     m_axil_rready,

        //-------------------------------------------------------------
        // Data cache port (DBG_VIA_CACHE = 1). Leave dc_resp_valid low
        // and dc_req_ready high when the cache is not connected.
        //-------------------------------------------------------------
        output logic                     dc_req_valid,
        input  logic                     dc_req_ready,
        output logic [ADDR_WIDTH-1:0]    dc_req_addr,
        output logic [1:0]               dc_req_size,
        output logic [3:0]               dc_req_cmd,
        output logic [63:0]              dc_req_wdata,
        output logic [ADDR_WIDTH-1:0]    dc_req_paddr,
        input  logic                     dc_resp_valid,
        input  logic [63:0]              dc_resp_data,
        input  logic                     dc_resp_error,
        output logic                     dc_wrote        // pulse after a write
    );

    //=================================================================
    // Resets
    //=================================================================
    logic t_por_n;      // debug POR in TCK domain
    logic tap_rst_n;    // debug POR | TRST in TCK domain
    logic s_por_n;      // debug POR in clk domain
    logic hartreset;

    DBG_RST_SYNC u_rst_t_por (.clk(jtag_tck), .rst_in_n(rst_dbg_n),               .rst_out_n(t_por_n));
    DBG_RST_SYNC u_rst_tap   (.clk(jtag_tck), .rst_in_n(rst_dbg_n & jtag_trst_n), .rst_out_n(tap_rst_n));
    DBG_RST_SYNC u_rst_s_por (.clk(clk),      .rst_in_n(rst_dbg_n),               .rst_out_n(s_por_n));
    DBG_RST_SYNC u_rst_bus   (.clk(clk),      .rst_in_n(rst_n & ~ndmreset),       .rst_out_n(rst_bus_n));

    // bus reset view for the DM (level, clk domain)
    logic bus_in_reset;
    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b1)) u_sync_bus_rst
        (.clk(clk), .rst_n(s_por_n), .d(~rst_bus_n), .q(bus_in_reset));

    // hart reset (synchronous level)
    logic hart_rst;
    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b1)) u_sync_hart_rst
        (.clk(clk), .rst_n(s_por_n), .d(~rst_n | ndmreset | hartreset), .q(hart_rst));

    // authentication inputs
    logic        auth_en_s;
    logic [31:0] auth_key_s;
    DBG_SYNC #(.WIDTH(1),  .RESET_VAL(1'b1)) u_sync_auth_en
        (.clk(clk), .rst_n(s_por_n), .d(dbg_auth_en), .q(auth_en_s));
    DBG_SYNC #(.WIDTH(32), .RESET_VAL(32'd0)) u_sync_auth_key
        (.clk(clk), .rst_n(s_por_n), .d(dbg_auth_key), .q(auth_key_s));

    //=================================================================
    // cJTAG / JTAG front end
    //=================================================================
    logic tap_ce, tap_tms, tap_tdi, tap_hold;
    logic dtm_tdo, dtm_tdo_oe;

    DBG_CJTAG u_cjtag
        (
            .por_n      (rst_dbg_n),
            .cjtag_en   (cjtag_en),
            .tck        (jtag_tck),
            .tms_i      (jtag_tms_i),
            .tms_o      (jtag_tms_o),
            .tms_oe     (jtag_tms_oe),
            .tdi        (jtag_tdi),
            .tdo        (jtag_tdo),
            .tdo_oe     (jtag_tdo_oe),
            .t_rst_n    (t_por_n),
            .tap_ce     (tap_ce),
            .tap_tms    (tap_tms),
            .tap_tdi    (tap_tdi),
            .tap_hold   (tap_hold),
            .dtm_tdo    (dtm_tdo),
            .dtm_tdo_oe (dtm_tdo_oe),
            .online     (cjtag_online)
        );

    //=================================================================
    // DTM
    //=================================================================
    logic        t_start, t_wr, t_abort, t_busy, t_err;
    logic [6:0]  t_addr;
    logic [31:0] t_wdata, t_rdata;

    DBG_DTM #(.IDCODE(IDCODE), .ABITS(7)) u_dtm
        (
            .tck        (jtag_tck),
            .tap_rst_n  (tap_rst_n),
            .tap_ce     (tap_ce),
            .tap_tms    (tap_tms),
            .tap_tdi    (tap_tdi),
            .tap_hold   (tap_hold),
            .tdo        (dtm_tdo),
            .tdo_oe     (dtm_tdo_oe),
            .dmi_start  (t_start),
            .dmi_addr   (t_addr),
            .dmi_wr     (t_wr),
            .dmi_wdata  (t_wdata),
            .dmi_abort  (t_abort),
            .dmi_busy   (t_busy),
            .dmi_rdata  (t_rdata),
            .dmi_err    (t_err)
        );

    //=================================================================
    // CDC
    //=================================================================
    logic        dmi_req, dmi_wr, dmi_ack, dmi_err;
    logic [6:0]  dmi_addr;
    logic [31:0] dmi_wdata, dmi_rdata;

    DBG_CDC #(.ABITS(7)) u_cdc
        (
            .tck        (jtag_tck),
            .t_rst_n    (t_por_n),
            .t_start    (t_start),
            .t_addr     (t_addr),
            .t_wr       (t_wr),
            .t_wdata    (t_wdata),
            .t_abort    (t_abort),
            .t_busy     (t_busy),
            .t_rdata    (t_rdata),
            .t_err      (t_err),
            .clk        (clk),
            .s_rst_n    (s_por_n),
            .dmi_req    (dmi_req),
            .dmi_addr   (dmi_addr),
            .dmi_wr     (dmi_wr),
            .dmi_wdata  (dmi_wdata),
            .dmi_ack    (dmi_ack),
            .dmi_rdata  (dmi_rdata),
            .dmi_err    (dmi_err)
        );

    //=================================================================
    // DM
    //=================================================================
    logic        haltreq, resumereq, resethaltreq;
    logic        halted, running, resumed;
    logic        reg_req, reg_wr, reg_size64, reg_ack, reg_err;
    logic [15:0] reg_regno;
    logic [63:0] reg_wdata, reg_rdata;
    logic        bm_req, bm_wr, bm_ack;
    logic [ADDR_WIDTH-1:0] bm_addr;
    logic [1:0]  bm_size;
    logic [63:0] bm_wdata, bm_rdata;
    logic [2:0]  bm_err;

    // the request goes to the data cache (cacheable region) or to the bus
    // master (peripheral bus, and everything when DBG_VIA_CACHE = 0)
    logic        bm_to_cache, bm_req_cache, bm_req_bus;
    logic        cache_ack, bus_ack;
    logic [63:0] cache_rdata, bus_rdata;
    logic [2:0]  cache_err, bus_err;

    assign bm_to_cache  = (DBG_VIA_CACHE != 0) && (bm_addr >= MEM_BASE);
    assign bm_req_cache = bm_req &  bm_to_cache;
    assign bm_req_bus   = bm_req & ~bm_to_cache;
    assign bm_ack       = cache_ack | bus_ack;
    assign bm_rdata     = cache_ack ? cache_rdata : bus_rdata;
    assign bm_err       = cache_ack ? cache_err   : bus_err;

    DBG_DM #(.ADDR_WIDTH(ADDR_WIDTH)) u_dm
        (
            .clk               (clk),
            .rst_n             (s_por_n),
            .dmi_req           (dmi_req),
            .dmi_wr            (dmi_wr),
            .dmi_addr          (dmi_addr),
            .dmi_wdata         (dmi_wdata),
            .dmi_ack           (dmi_ack),
            .dmi_rdata         (dmi_rdata),
            .dmi_err           (dmi_err),
            .auth_en           (auth_en_s),
            .auth_key          (auth_key_s),
            .hart_haltreq      (haltreq),
            .hart_resumereq    (resumereq),
            .hart_resethaltreq (resethaltreq),
            .hart_hartreset    (hartreset),
            .hart_halted       (halted),
            .hart_running      (running),
            .hart_resumed      (resumed),
            .hart_in_reset     (hart_rst),
            .reg_req           (reg_req),
            .reg_wr            (reg_wr),
            .reg_regno         (reg_regno),
            .reg_size64        (reg_size64),
            .reg_wdata         (reg_wdata),
            .reg_ack           (reg_ack),
            .reg_rdata         (reg_rdata),
            .reg_err           (reg_err),
            .bm_req            (bm_req),
            .bm_wr             (bm_wr),
            .bm_addr           (bm_addr),
            .bm_size           (bm_size),
            .bm_wdata          (bm_wdata),
            .bm_ack            (bm_ack),
            .bm_rdata          (bm_rdata),
            .bm_err            (bm_err),
            .bus_in_reset      (bus_in_reset),
            .ndmreset          (ndmreset),
            .sys_in_reset      (bus_in_reset),
            .dmactive_o        (dbg_dmactive),
            .authenticated_o   ()
        );

    //=================================================================
    // Pseudo hart
    //=================================================================
    DBG_HART_STUB
        #(
            .MISA         (MISA),
            .MVENDORID    (MVENDORID),
            .MARCHID      (MARCHID),
            .MIMPL        (MIMPL),
            .MHARTID      (MHARTID),
            .RESET_VECTOR (RESET_VECTOR)
        )
    u_hart
        (
            .clk          (clk),
            .hart_rst     (hart_rst),
            .haltreq      (haltreq),
            .resumereq    (resumereq),
            .resethaltreq (resethaltreq),
            .halted       (halted),
            .running      (running),
            .resumed      (resumed),
            .reg_req      (reg_req),
            .reg_wr       (reg_wr),
            .reg_regno    (reg_regno),
            .reg_size64   (reg_size64),
            .reg_wdata    (reg_wdata),
            .reg_ack      (reg_ack),
            .reg_rdata    (reg_rdata),
            .reg_err      (reg_err)
        );

    assign dbg_halted  = halted;
    assign dbg_running = running;

    //=================================================================
    // Bus master
    //=================================================================
    DBG_BUSMST
        #(
            .AXI4_ID_WIDTH  (AXI4_ID_WIDTH),
            .ADDR_WIDTH     (ADDR_WIDTH),
            .AXI4_ID        (DBG_AXI4_ID),
            .MEM_BASE       (MEM_BASE),
            .TIMEOUT_CYCLES (SBA_TIMEOUT)
        )
    u_busmst
        (
            .clk            (clk),
            .rst_n          (rst_bus_n),
            .bm_req         (bm_req_bus),
            .bm_wr          (bm_wr),
            .bm_addr        (bm_addr),
            .bm_size        (bm_size),
            .bm_wdata       (bm_wdata),
            .bm_ack         (bus_ack),
            .bm_rdata       (bus_rdata),
            .bm_err         (bus_err),
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

    //=================================================================
    // Data cache port of the debugger (CPU_CACHE_SPEC.md 4.7)
    //=================================================================
    generate
        if (DBG_VIA_CACHE != 0) begin : g_dbg_cache
            DBG_CACHE
                #(
                    .ADDR_WIDTH     (ADDR_WIDTH),
                    .TIMEOUT_CYCLES (SBA_TIMEOUT)
                )
            u_dbg_cache
                (
                    .clk           (clk),
                    .rst_n         (rst_bus_n),
                    .bm_req        (bm_req_cache),
                    .bm_wr         (bm_wr),
                    .bm_addr       (bm_addr),
                    .bm_size       (bm_size),
                    .bm_wdata      (bm_wdata),
                    .bm_ack        (cache_ack),
                    .bm_rdata      (cache_rdata),
                    .bm_err        (cache_err),
                    .dc_req_valid  (dc_req_valid),
                    .dc_req_ready  (dc_req_ready),
                    .dc_req_addr   (dc_req_addr),
                    .dc_req_size   (dc_req_size),
                    .dc_req_cmd    (dc_req_cmd),
                    .dc_req_wdata  (dc_req_wdata),
                    .dc_req_paddr  (dc_req_paddr),
                    .dc_resp_valid (dc_resp_valid),
                    .dc_resp_data  (dc_resp_data),
                    .dc_resp_error (dc_resp_error),
                    .busy          (),
                    .wrote         (dc_wrote)
                );
        end else begin : g_no_dbg_cache
            assign cache_ack    = 1'b0;
            assign cache_rdata  = '0;
            assign cache_err    = 3'd0;
            assign dc_req_valid = 1'b0;
            assign dc_req_addr  = '0;
            assign dc_req_size  = 2'd0;
            assign dc_req_cmd   = 4'd0;
            assign dc_req_wdata = '0;
            assign dc_req_paddr = '0;
            assign dc_wrote     = 1'b0;
        end
    endgenerate

endmodule : CPU_DBG
