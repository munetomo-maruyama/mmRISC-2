//---------------------------------------------------------------------------
// tb_CACHE.sv
//
// Verification environment for the mmRISC-2 L1 caches (RTL/CPU/CPU_CACHE).
//
//   tb_CACHE ── CPU BFM (instruction fetch / load / store / AMO / LR / SC)
//            ── reference model (cache-less memory image + expected results)
//            ── CPU_CACHE (DUT)
//                 ├─ AXI4      -> AXI4_ADDR_NARROW -> AXI4_SLAVE_MEM  @0x8000_0000
//                 └─ AXI4-Lite -> AXIL_ADDR_NARROW -> AXIL_SLAVE_MEM  @0x1200_0000
//
// The bridges give the same DECERR behaviour as the real system for
// addresses whose upper bits [39:32] are not zero.
//
// Requests are pushed without waiting for the response (so that misses can
// overlap and the MSHRs are exercised). Expected results are computed in
// program order at push time and compared when the response arrives.
//
// Test items: see tb_CACHE_tests.svh
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_CACHE;

    //=================================================================
    // Configuration (overridable with -G on the command line)
    //=================================================================
    parameter int PADDR_WIDTH   = 40;
    parameter int XLEN          = 64;

    parameter int IC_SETS       = 64;
    parameter int IC_WAYS       = 4;
    parameter int IC_BLOCK      = 64;
    parameter int FETCH_WIDTH   = 64;

    parameter int DC_SETS       = 64;
    parameter int DC_WAYS       = 4;
    parameter int DC_BLOCK      = 64;
    parameter int NUM_MSHR      = 2;
    parameter int NUM_WB        = 2;
    parameter int REPLACE_RANDOM = 0;

    // cacheable / uncached windows (enlarged by the parameter sweep so that
    // the test addresses of big cache geometries still fit)
    parameter int MEM_WORDS  = 8192;     // 64KiB cacheable window
    parameter int PERI_WORDS = 512;      // 4KiB uncached window

    localparam logic [PADDR_WIDTH-1:0] MEM_BASE  = 40'h00_8000_0000;
    localparam logic [PADDR_WIDTH-1:0] PERI_BASE = 40'h00_1200_0000;
    localparam logic [63:0] MEM_INIT  = 64'h0000_0000_0000_0000;
    localparam logic [63:0] PERI_INIT = 64'h1111_0000_0000_0000;

    // commands (RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md 3.3)
    localparam logic [3:0] CMD_LOAD     = 4'd0;
    localparam logic [3:0] CMD_STORE    = 4'd1;
    localparam logic [3:0] CMD_LR       = 4'd2;
    localparam logic [3:0] CMD_SC       = 4'd3;
    localparam logic [3:0] CMD_AMOSWAP  = 4'd4;
    localparam logic [3:0] CMD_AMOADD   = 4'd5;
    localparam logic [3:0] CMD_AMOXOR   = 4'd6;
    localparam logic [3:0] CMD_AMOAND   = 4'd7;
    localparam logic [3:0] CMD_AMOOR    = 4'd8;
    localparam logic [3:0] CMD_AMOMIN   = 4'd9;
    localparam logic [3:0] CMD_AMOMAX   = 4'd10;
    localparam logic [3:0] CMD_AMOMINU  = 4'd11;
    localparam logic [3:0] CMD_AMOMAXU  = 4'd12;
    localparam logic [3:0] CMD_FENCE    = 4'd13;
    localparam logic [3:0] CMD_FLUSH    = 4'd14;
    localparam logic [3:0] CMD_STWTHR   = 4'd15;   // write through, no allocate

    //=================================================================
    // Clock / reset
    //=================================================================
    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    always #10 clk = ~clk;      // 50MHz

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    //=================================================================
    // DUT ports
    //=================================================================
    logic                    i_req_valid, i_req_ready;
    logic [PADDR_WIDTH-1:0]  i_req_addr;
    logic                    i_resp_valid, i_resp_error;
    logic [FETCH_WIDTH-1:0]  i_resp_data;
    logic                    i_flush_valid, i_flush_done;
    logic                    i_kill;
    logic [PADDR_WIDTH-1:0]  i_req_paddr;     // physical address, one cycle later

    logic                    d_req_valid, d_req_ready;
    logic [PADDR_WIDTH-1:0]  d_req_addr;
    logic [1:0]              d_req_size;
    logic [3:0]              d_req_cmd;
    logic [XLEN-1:0]         d_req_wdata;
    logic                    d_resp_valid, d_resp_error;
    logic [XLEN-1:0]         d_resp_data;
    logic [PADDR_WIDTH-1:0]  d_req_paddr;     // physical address, one cycle later

    // second port of the data cache (debug module in CPU_TOP)
    logic                    dbg_req_valid, dbg_req_ready;
    logic [PADDR_WIDTH-1:0]  dbg_req_addr;
    logic [1:0]              dbg_req_size;
    logic [3:0]              dbg_req_cmd;
    logic [XLEN-1:0]         dbg_req_wdata;
    logic                    dbg_resp_valid, dbg_resp_error;
    logic [XLEN-1:0]         dbg_resp_data;
    logic [PADDR_WIDTH-1:0]  dbg_req_paddr;

    // AXI4 (memory bus, 40bit)
    logic [3:0]              m_axi4_awid;
    logic [PADDR_WIDTH-1:0]  m_axi4_awaddr;
    logic [7:0]              m_axi4_awlen;
    logic [2:0]              m_axi4_awsize;
    logic [1:0]              m_axi4_awburst;
    logic                    m_axi4_awlock;
    logic [3:0]              m_axi4_awcache;
    logic [2:0]              m_axi4_awprot;
    logic [3:0]              m_axi4_awqos;
    logic                    m_axi4_awvalid, m_axi4_awready;
    logic [63:0]             m_axi4_wdata;
    logic [7:0]              m_axi4_wstrb;
    logic                    m_axi4_wlast, m_axi4_wvalid, m_axi4_wready;
    logic [3:0]              m_axi4_bid;
    logic [1:0]              m_axi4_bresp;
    logic                    m_axi4_bvalid, m_axi4_bready;
    logic [3:0]              m_axi4_arid;
    logic [PADDR_WIDTH-1:0]  m_axi4_araddr;
    logic [7:0]              m_axi4_arlen;
    logic [2:0]              m_axi4_arsize;
    logic [1:0]              m_axi4_arburst;
    logic                    m_axi4_arlock;
    logic [3:0]              m_axi4_arcache;
    logic [2:0]              m_axi4_arprot;
    logic [3:0]              m_axi4_arqos;
    logic                    m_axi4_arvalid, m_axi4_arready;
    logic [3:0]              m_axi4_rid;
    logic [63:0]             m_axi4_rdata;
    logic [1:0]              m_axi4_rresp;
    logic                    m_axi4_rlast, m_axi4_rvalid, m_axi4_rready;

    // AXI4-Lite (peripheral bus, 40bit)
    logic [PADDR_WIDTH-1:0]  m_axil_awaddr;
    logic [2:0]              m_axil_awprot;
    logic                    m_axil_awvalid, m_axil_awready;
    logic [63:0]             m_axil_wdata;
    logic [7:0]              m_axil_wstrb;
    logic                    m_axil_wvalid, m_axil_wready;
    logic [1:0]              m_axil_bresp;
    logic                    m_axil_bvalid, m_axil_bready;
    logic [PADDR_WIDTH-1:0]  m_axil_araddr;
    logic [2:0]              m_axil_arprot;
    logic                    m_axil_arvalid, m_axil_arready;
    logic [63:0]             m_axil_rdata;
    logic [1:0]              m_axil_rresp;
    logic                    m_axil_rvalid, m_axil_rready;

    //=================================================================
    // Fake MMU
    //
    // The tests work with physical addresses. With xlate_en set, the driver
    // sends a different *virtual* address on the request port and the real
    // one on the physical address port, so the cache has to take the index
    // from the virtual address and the tag from the physical one (VIPT).
    // The two differ in the tag only, the page offset is the same, which is
    // what the index needs (only valid while SETS * BLOCK <= 4096).
    //=================================================================
    localparam logic [PADDR_WIDTH-1:0] XL_VBASE = MEM_BASE + 40'h0010_0000;
    localparam logic [PADDR_WIDTH-1:0] XL_PBASE = MEM_BASE + 40'h0000_2000;
    localparam int                     XL_SIZE  = 4096;

    bit xlate_en = 1'b0;

    // physical -> virtual (what the CPU would put on the request port)
    function automatic logic [PADDR_WIDTH-1:0] to_virt(input logic [PADDR_WIDTH-1:0] pa);
        if (xlate_en && (pa >= XL_PBASE) && (pa < XL_PBASE + PADDR_WIDTH'(XL_SIZE)))
            return pa - XL_PBASE + XL_VBASE;
        else
            return pa;
    endfunction

    // the physical address of a request is presented one cycle after it was
    // accepted (CPU_CACHE_SPEC.md 5.2)
    logic [PADDR_WIDTH-1:0] d_req_pa_cur, i_req_pa_cur;

    always @(posedge clk) begin
        if (!rst_n) begin
            i_req_paddr   <= '0;
            d_req_paddr   <= '0;
            dbg_req_paddr <= '0;
        end else begin
            if (i_req_valid   && i_req_ready)   i_req_paddr   <= i_req_pa_cur;
            if (d_req_valid   && d_req_ready)   d_req_paddr   <= d_req_pa_cur;
            if (dbg_req_valid && dbg_req_ready) dbg_req_paddr <= dbg_req_addr;
        end
    end

    //=================================================================
    // DUT
    //=================================================================
    CPU_CACHE
        #(
            .PADDR_WIDTH    (PADDR_WIDTH),
            .XLEN           (XLEN),
            .MEM_BASE       (MEM_BASE),
            .IC_SETS        (IC_SETS),
            .IC_WAYS        (IC_WAYS),
            .IC_BLOCK_BYTES (IC_BLOCK),
            .FETCH_WIDTH    (FETCH_WIDTH),
            .DC_SETS        (DC_SETS),
            .DC_WAYS        (DC_WAYS),
            .DC_BLOCK_BYTES (DC_BLOCK),
            .NUM_MSHR       (NUM_MSHR),
            .NUM_WB         (NUM_WB),
            .REPLACE_RANDOM (REPLACE_RANDOM)
        )
    u_cache
        (
            .clk            (clk),
            .rst_n          (rst_n),

            .i_req_valid    (i_req_valid),
            .i_req_ready    (i_req_ready),
            .i_req_addr     (i_req_addr),
            .i_req_paddr    (i_req_paddr),
            .i_resp_valid   (i_resp_valid),
            .i_resp_data    (i_resp_data),
            .i_resp_error   (i_resp_error),
            .i_flush_valid  (i_flush_valid),
            .i_flush_done   (i_flush_done),
            .i_kill         (i_kill),

            .d_req_valid    (d_req_valid),
            .d_req_ready    (d_req_ready),
            .d_req_addr     (d_req_addr),
            .d_req_size     (d_req_size),
            .d_req_cmd      (d_req_cmd),
            .d_req_wdata    (d_req_wdata),
            .d_req_paddr    (d_req_paddr),
            .d_resp_valid   (d_resp_valid),
            .d_resp_data    (d_resp_data),
            .d_resp_error   (d_resp_error),
            .dbg_req_valid  (dbg_req_valid),
            .dbg_req_ready  (dbg_req_ready),
            .dbg_req_addr   (dbg_req_addr),
            .dbg_req_size   (dbg_req_size),
            .dbg_req_cmd    (dbg_req_cmd),
            .dbg_req_wdata  (dbg_req_wdata),
            .dbg_req_paddr  (dbg_req_paddr),
            .dbg_resp_valid (dbg_resp_valid),
            .dbg_resp_data  (dbg_resp_data),
            .dbg_resp_error (dbg_resp_error),

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
    // Memory subsystem (same bridges as the real system)
    //=================================================================
    logic [3:0]  mem_awid, mem_bid, mem_arid, mem_rid;
    logic [31:0] mem_awaddr, mem_araddr;
    logic [7:0]  mem_awlen, mem_arlen;
    logic [2:0]  mem_awsize, mem_arsize, mem_awprot, mem_arprot;
    logic [1:0]  mem_awburst, mem_arburst, mem_bresp, mem_rresp;
    logic        mem_awlock, mem_arlock, mem_awvalid, mem_awready;
    logic [3:0]  mem_awcache, mem_awqos, mem_arcache, mem_arqos;
    logic [63:0] mem_wdata, mem_rdata;
    logic [7:0]  mem_wstrb;
    logic        mem_wlast, mem_wvalid, mem_wready;
    logic        mem_bvalid, mem_bready, mem_arvalid, mem_arready;
    logic        mem_rlast, mem_rvalid, mem_rready;

    AXI4_ADDR_NARROW
        #(.ID_WIDTH(4), .S_ADDR_WIDTH(PADDR_WIDTH), .M_ADDR_WIDTH(32), .DATA_WIDTH(64))
    u_narrow_axi4
        (
            .clk(clk), .rst_n(rst_n),
            .s_awid(m_axi4_awid), .s_awaddr(m_axi4_awaddr), .s_awlen(m_axi4_awlen),
            .s_awsize(m_axi4_awsize), .s_awburst(m_axi4_awburst), .s_awlock(m_axi4_awlock),
            .s_awcache(m_axi4_awcache), .s_awprot(m_axi4_awprot), .s_awqos(m_axi4_awqos),
            .s_awvalid(m_axi4_awvalid), .s_awready(m_axi4_awready),
            .s_wdata(m_axi4_wdata), .s_wstrb(m_axi4_wstrb), .s_wlast(m_axi4_wlast),
            .s_wvalid(m_axi4_wvalid), .s_wready(m_axi4_wready),
            .s_bid(m_axi4_bid), .s_bresp(m_axi4_bresp), .s_bvalid(m_axi4_bvalid), .s_bready(m_axi4_bready),
            .s_arid(m_axi4_arid), .s_araddr(m_axi4_araddr), .s_arlen(m_axi4_arlen),
            .s_arsize(m_axi4_arsize), .s_arburst(m_axi4_arburst), .s_arlock(m_axi4_arlock),
            .s_arcache(m_axi4_arcache), .s_arprot(m_axi4_arprot), .s_arqos(m_axi4_arqos),
            .s_arvalid(m_axi4_arvalid), .s_arready(m_axi4_arready),
            .s_rid(m_axi4_rid), .s_rdata(m_axi4_rdata), .s_rresp(m_axi4_rresp),
            .s_rlast(m_axi4_rlast), .s_rvalid(m_axi4_rvalid), .s_rready(m_axi4_rready),
            .m_awid(mem_awid), .m_awaddr(mem_awaddr), .m_awlen(mem_awlen),
            .m_awsize(mem_awsize), .m_awburst(mem_awburst), .m_awlock(mem_awlock),
            .m_awcache(mem_awcache), .m_awprot(mem_awprot), .m_awqos(mem_awqos),
            .m_awvalid(mem_awvalid), .m_awready(mem_awready),
            .m_wdata(mem_wdata), .m_wstrb(mem_wstrb), .m_wlast(mem_wlast),
            .m_wvalid(mem_wvalid), .m_wready(mem_wready),
            .m_bid(mem_bid), .m_bresp(mem_bresp), .m_bvalid(mem_bvalid), .m_bready(mem_bready),
            .m_arid(mem_arid), .m_araddr(mem_araddr), .m_arlen(mem_arlen),
            .m_arsize(mem_arsize), .m_arburst(mem_arburst), .m_arlock(mem_arlock),
            .m_arcache(mem_arcache), .m_arprot(mem_arprot), .m_arqos(mem_arqos),
            .m_arvalid(mem_arvalid), .m_arready(mem_arready),
            .m_rid(mem_rid), .m_rdata(mem_rdata), .m_rresp(mem_rresp),
            .m_rlast(mem_rlast), .m_rvalid(mem_rvalid), .m_rready(mem_rready)
        );

    AXI4_SLAVE_MEM
        #(.ID_WIDTH(4), .ADDR_WIDTH(32), .DATA_WIDTH(64), .DEPTH(MEM_WORDS),
          .BASE_ADDR(32'h8000_0000), .INIT_BASE(MEM_INIT))
    u_mem
        (
            .clk(clk), .rst_n(rst_n),
            .awid(mem_awid), .awaddr(mem_awaddr), .awlen(mem_awlen), .awsize(mem_awsize),
            .awburst(mem_awburst), .awlock(mem_awlock), .awcache(mem_awcache),
            .awprot(mem_awprot), .awqos(mem_awqos), .awvalid(mem_awvalid), .awready(mem_awready),
            .wdata(mem_wdata), .wstrb(mem_wstrb), .wlast(mem_wlast),
            .wvalid(mem_wvalid), .wready(mem_wready),
            .bid(mem_bid), .bresp(mem_bresp), .bvalid(mem_bvalid), .bready(mem_bready),
            .arid(mem_arid), .araddr(mem_araddr), .arlen(mem_arlen), .arsize(mem_arsize),
            .arburst(mem_arburst), .arlock(mem_arlock), .arcache(mem_arcache),
            .arprot(mem_arprot), .arqos(mem_arqos), .arvalid(mem_arvalid), .arready(mem_arready),
            .rid(mem_rid), .rdata(mem_rdata), .rresp(mem_rresp), .rlast(mem_rlast),
            .rvalid(mem_rvalid), .rready(mem_rready)
        );

    logic [31:0] per_awaddr, per_araddr;
    logic [2:0]  per_awprot, per_arprot;
    logic        per_awvalid, per_awready, per_wvalid, per_wready;
    logic [63:0] per_wdata, per_rdata;
    logic [7:0]  per_wstrb;
    logic [1:0]  per_bresp, per_rresp;
    logic        per_bvalid, per_bready, per_arvalid, per_arready, per_rvalid, per_rready;

    AXIL_ADDR_NARROW
        #(.S_ADDR_WIDTH(PADDR_WIDTH), .M_ADDR_WIDTH(32), .DATA_WIDTH(64))
    u_narrow_axil
        (
            .clk(clk), .rst_n(rst_n),
            .s_awaddr(m_axil_awaddr), .s_awprot(m_axil_awprot),
            .s_awvalid(m_axil_awvalid), .s_awready(m_axil_awready),
            .s_wdata(m_axil_wdata), .s_wstrb(m_axil_wstrb),
            .s_wvalid(m_axil_wvalid), .s_wready(m_axil_wready),
            .s_bresp(m_axil_bresp), .s_bvalid(m_axil_bvalid), .s_bready(m_axil_bready),
            .s_araddr(m_axil_araddr), .s_arprot(m_axil_arprot),
            .s_arvalid(m_axil_arvalid), .s_arready(m_axil_arready),
            .s_rdata(m_axil_rdata), .s_rresp(m_axil_rresp),
            .s_rvalid(m_axil_rvalid), .s_rready(m_axil_rready),
            .m_awaddr(per_awaddr), .m_awprot(per_awprot),
            .m_awvalid(per_awvalid), .m_awready(per_awready),
            .m_wdata(per_wdata), .m_wstrb(per_wstrb),
            .m_wvalid(per_wvalid), .m_wready(per_wready),
            .m_bresp(per_bresp), .m_bvalid(per_bvalid), .m_bready(per_bready),
            .m_araddr(per_araddr), .m_arprot(per_arprot),
            .m_arvalid(per_arvalid), .m_arready(per_arready),
            .m_rdata(per_rdata), .m_rresp(per_rresp),
            .m_rvalid(per_rvalid), .m_rready(per_rready)
        );

    AXIL_SLAVE_MEM
        #(.ADDR_WIDTH(32), .DATA_WIDTH(64), .DEPTH(PERI_WORDS),
          .BASE_ADDR(32'h1200_0000), .INIT_BASE(PERI_INIT))
    u_peri
        (
            .clk(clk), .rst_n(rst_n),
            .awaddr(per_awaddr), .awprot(per_awprot), .awvalid(per_awvalid), .awready(per_awready),
            .wdata(per_wdata), .wstrb(per_wstrb), .wvalid(per_wvalid), .wready(per_wready),
            .bresp(per_bresp), .bvalid(per_bvalid), .bready(per_bready),
            .araddr(per_araddr), .arprot(per_arprot), .arvalid(per_arvalid), .arready(per_arready),
            .rdata(per_rdata), .rresp(per_rresp), .rvalid(per_rvalid), .rready(per_rready)
        );

`ifdef DUMP_VCD
    initial begin
        string vcd_name;
        if (!$value$plusargs("vcd=%s", vcd_name)) vcd_name = "tb_CACHE.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_CACHE);
    end
`endif

    //=================================================================
    // Result bookkeeping
    //=================================================================
    // free running cycle counter (throughput measurement, 7. in the spec)
    int unsigned cyc = 0;
    always @(posedge clk) if (rst_n) cyc <= cyc + 1;

    int n_check = 0;
    int n_error = 0;

    task automatic check(input string name, input bit cond);
        n_check++;
        if (!cond) begin
            n_error++;
            $display("[%0t] [FAIL] %s", $time, name);
        end
    endtask

    task automatic check64(input string name, input logic [63:0] exp, input logic [63:0] act);
        n_check++;
        if (act !== exp) begin
            n_error++;
            $display("[%0t] [FAIL] %s : expected=0x%016h actual=0x%016h", $time, name, exp, act);
        end
    endtask

    task automatic section(input string name);
        $display("");
        $display("--- %s ---", name);
    endtask

    task automatic ok(input string name);
        $display("[%0t] [ OK ] %s", $time, name);
    endtask

    //=================================================================
    // Reference model : memory image without caches
    //
    //   ref_mem  : cacheable window  (MEM_BASE  + 8*i)
    //   ref_peri : uncached window   (PERI_BASE + 8*i)
    //   Updated in program order when a request is pushed, so the expected
    //   response can be computed at that moment.
    //=================================================================
    logic [63:0] ref_mem  [0:MEM_WORDS-1];
    logic [63:0] ref_peri [0:PERI_WORDS-1];

    // reservation (LR/SC)
    logic                   res_valid;
    logic [PADDR_WIDTH-1:0] res_addr;

    task automatic ref_init();
        for (int i = 0; i < MEM_WORDS;  i++) ref_mem[i]  = MEM_INIT  + 64'(i);
        for (int i = 0; i < PERI_WORDS; i++) ref_peri[i] = PERI_INIT + 64'(i);
        res_valid = 1'b0;
        res_addr  = '0;
    endtask

    function automatic bit is_cacheable(input logic [PADDR_WIDTH-1:0] a);
        return (a >= MEM_BASE);
    endfunction

    function automatic int ref_index(input logic [PADDR_WIDTH-1:0] a);
        if (is_cacheable(a)) return int'((a - MEM_BASE) >> 3);
        else                 return int'((a - PERI_BASE) >> 3);
    endfunction

    function automatic logic [63:0] ref_read_word(input logic [PADDR_WIDTH-1:0] a);
        if (is_cacheable(a)) return ref_mem[ref_index(a)];
        else                 return ref_peri[ref_index(a)];
    endfunction

    task automatic ref_write_word(input logic [PADDR_WIDTH-1:0] a, input logic [63:0] v);
        if (is_cacheable(a)) ref_mem[ref_index(a)]  = v;
        else                 ref_peri[ref_index(a)] = v;
    endtask

    // byte lane mask of an access
    function automatic logic [7:0] lane_mask(input logic [PADDR_WIDTH-1:0] a, input logic [1:0] size);
        logic [7:0] m;
        m = 8'h00;
        for (int b = 0; b < (1 << size); b++) m[int'(a[2:0]) + b] = 1'b1;
        return m;
    endfunction

    // data of an access, right aligned and zero extended
    function automatic logic [63:0] extract(input logic [63:0] word,
                                            input logic [PADDR_WIDTH-1:0] a,
                                            input logic [1:0] size);
        logic [63:0] v;
        v = word >> (8 * int'(a[2:0]));
        case (size)
            2'd0: return v & 64'h0000_0000_0000_00FF;
            2'd1: return v & 64'h0000_0000_0000_FFFF;
            2'd2: return v & 64'h0000_0000_FFFF_FFFF;
            default: return v;
        endcase
    endfunction

    function automatic logic [63:0] merge(input logic [63:0] word,
                                          input logic [PADDR_WIDTH-1:0] a,
                                          input logic [1:0] size,
                                          input logic [63:0] wdata);
        logic [63:0] r;
        logic [7:0]  m;
        r = word;
        m = lane_mask(a, size);
        for (int b = 0; b < 8; b++)
            if (m[b]) r[8*b +: 8] = wdata[8*(b - int'(a[2:0])) +: 8];
        return r;
    endfunction

    // AMO result (value written back to memory)
    function automatic logic [63:0] amo_calc(input logic [3:0] cmd, input logic [1:0] size,
                                             input logic [63:0] old_v, input logic [63:0] src);
        logic signed [63:0] so, ss;
        logic [63:0] o, s;
        if (size == 2'd2) begin
            o  = {32'd0, old_v[31:0]};
            s  = {32'd0, src[31:0]};
            so = 64'(signed'(old_v[31:0]));
            ss = 64'(signed'(src[31:0]));
        end else begin
            o  = old_v;
            s  = src;
            so = signed'(old_v);
            ss = signed'(src);
        end
        case (cmd)
            CMD_AMOSWAP: return s;
            CMD_AMOADD:  return o + s;
            CMD_AMOXOR:  return o ^ s;
            CMD_AMOAND:  return o & s;
            CMD_AMOOR:   return o | s;
            CMD_AMOMIN:  return (so < ss) ? o : s;
            CMD_AMOMAX:  return (so < ss) ? s : o;
            CMD_AMOMINU: return (o  < s)  ? o : s;
            CMD_AMOMAXU: return (o  < s)  ? s : o;
            default:     return o;
        endcase
    endfunction

    //=================================================================
    // Expectation queues (in-order responses)
    //=================================================================
    localparam int QDEPTH = 1024;

    // data side
    logic [63:0]            dq_data  [0:QDEPTH-1];
    bit                     dq_err   [0:QDEPTH-1];
    bit                     dq_check [0:QDEPTH-1];   // 0: result is adaptive (SC)
    bit                     dq_is_sc [0:QDEPTH-1];
    logic [PADDR_WIDTH-1:0] dq_addr  [0:QDEPTH-1];
    logic [1:0]             dq_size  [0:QDEPTH-1];
    logic [63:0]            dq_wdata [0:QDEPTH-1];
    string                  dq_name  [0:QDEPTH-1];
    int dq_wr = 0, dq_rd = 0;

    // instruction side
    logic [FETCH_WIDTH-1:0] iq_data  [0:QDEPTH-1];
    bit                     iq_err   [0:QDEPTH-1];
    string                  iq_name  [0:QDEPTH-1];
    int iq_wr = 0, iq_rd = 0;

    int n_d_resp = 0;
    int n_i_resp = 0;

    //=================================================================
    // Request FIFOs and drivers
    //   The tests enqueue requests; these processes drive the interfaces and
    //   can issue one request per cycle, so back-to-back accesses (and the
    //   array read/write hazards they create) are exercised.
    //=================================================================
    logic [3:0]             rq_cmd   [0:QDEPTH-1];
    logic [PADDR_WIDTH-1:0] rq_addr  [0:QDEPTH-1];
    logic [1:0]             rq_size  [0:QDEPTH-1];
    logic [63:0]            rq_wdata [0:QDEPTH-1];
    int rq_wr = 0, rq_rd = 0;

    logic [PADDR_WIDTH-1:0] iq_addr_f [0:QDEPTH-1];
    int iq_wr_f = 0, iq_rd_f = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            d_req_valid <= 1'b0;
        end else if (!d_req_valid || d_req_ready) begin
            if (rq_rd != rq_wr) begin
                d_req_valid <= 1'b1;
                d_req_cmd   <= rq_cmd[rq_rd];
                d_req_addr  <= to_virt(rq_addr[rq_rd]);
                d_req_pa_cur<= rq_addr[rq_rd];
                d_req_size  <= rq_size[rq_rd];
                d_req_wdata <= rq_wdata[rq_rd];
                rq_rd       <= (rq_rd + 1) % QDEPTH;
            end else begin
                d_req_valid <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            i_req_valid <= 1'b0;
        end else if (!i_req_valid || i_req_ready) begin
            if (iq_rd_f != iq_wr_f) begin
                i_req_valid <= 1'b1;
                i_req_addr  <= to_virt(iq_addr_f[iq_rd_f]);
                i_req_pa_cur<= iq_addr_f[iq_rd_f];
                iq_rd_f     <= (iq_rd_f + 1) % QDEPTH;
            end else begin
                i_req_valid <= 1'b0;
            end
        end
    end

    task automatic rq_put(input logic [3:0] cmd, input logic [PADDR_WIDTH-1:0] addr,
                          input logic [1:0] size, input logic [63:0] wdata);
        while (((rq_wr + 1) % QDEPTH) == rq_rd) @(posedge clk);
        rq_cmd[rq_wr]   = cmd;
        rq_addr[rq_wr]  = addr;
        rq_size[rq_wr]  = size;
        rq_wdata[rq_wr] = wdata;
        rq_wr           = (rq_wr + 1) % QDEPTH;
    endtask

    task automatic iq_put(input logic [PADDR_WIDTH-1:0] addr);
        while (((iq_wr_f + 1) % QDEPTH) == iq_rd_f) @(posedge clk);
        iq_addr_f[iq_wr_f] = addr;
        iq_wr_f            = (iq_wr_f + 1) % QDEPTH;
    endtask

    //=================================================================
    // CPU BFM : data side
    //=================================================================
    task automatic d_push(input string name, input logic [3:0] cmd,
                          input logic [PADDR_WIDTH-1:0] addr, input logic [1:0] size,
                          input logic [63:0] wdata);
        logic [63:0] word, newword, exp;
        bit          err, adaptive, sc_ok;
        err      = 1'b0;
        adaptive = 1'b0;
        exp      = 64'd0;
        sc_ok    = 1'b0;

        //-------------------------------------------------------------
        // expected result, computed in program order
        //-------------------------------------------------------------
        case (cmd)
            CMD_FENCE, CMD_FLUSH: begin
                if (cmd == CMD_FLUSH) res_valid = 1'b0;
            end
            CMD_LOAD: begin
                word = ref_read_word(addr);
                exp  = extract(word, addr, size);
            end
            CMD_STORE, CMD_STWTHR: begin
                word = ref_read_word(addr);
                ref_write_word(addr, merge(word, addr, size, wdata));
                if (res_valid && (res_addr >> $clog2(DC_BLOCK)) == (addr >> $clog2(DC_BLOCK)))
                    res_valid = 1'b0;
            end
            CMD_LR: begin
                if (!is_cacheable(addr)) begin
                    err = 1'b1;
                end else begin
                    word      = ref_read_word(addr);
                    exp       = extract(word, addr, size);
                    res_valid = 1'b1;
                    res_addr  = addr;
                end
            end
            CMD_SC: begin
                if (!is_cacheable(addr)) begin
                    err = 1'b1;
                end else begin
                    // the cache may also have dropped the reservation because
                    // of a replacement, so the result is adaptive: the
                    // checker uses the DUT answer and verifies memory
                    sc_ok    = res_valid &&
                               ((res_addr >> $clog2(DC_BLOCK)) == (addr >> $clog2(DC_BLOCK)));
                    adaptive = 1'b1;
                    exp      = sc_ok ? 64'd0 : 64'd1;
                    res_valid = 1'b0;
                end
            end
            default: begin   // AMO
                if (!is_cacheable(addr)) begin
                    err = 1'b1;
                end else begin
                    word    = ref_read_word(addr);
                    exp     = extract(word, addr, size);
                    newword = merge(word, addr, size,
                                    amo_calc(cmd, size, extract(word, addr, size), wdata));
                    ref_write_word(addr, newword);
                    if (res_valid && (res_addr >> $clog2(DC_BLOCK)) == (addr >> $clog2(DC_BLOCK)))
                        res_valid = 1'b0;
                end
            end
        endcase

        //-------------------------------------------------------------
        // queue the expectation and drive the request
        //-------------------------------------------------------------
        dq_data[dq_wr]  = exp;
        dq_err[dq_wr]   = err;
        dq_check[dq_wr] = ~adaptive;
        dq_is_sc[dq_wr] = (cmd == CMD_SC);
        dq_addr[dq_wr]  = addr;
        dq_size[dq_wr]  = size;
        dq_wdata[dq_wr] = wdata;
        dq_name[dq_wr]  = name;
        dq_wr           = (dq_wr + 1) % QDEPTH;

        rq_put(cmd, addr, size, wdata);

        // The result of an SC is adaptive: the reference memory is updated by
        // the response checker, not here. Wait for that update before the next
        // request is pushed, otherwise a later access would compute its
        // expected value from a reference memory that does not yet contain the
        // store of this SC.
        if (cmd == CMD_SC) d_drain();
    endtask

    // convenience wrappers
    task automatic d_load (input string n, input logic [PADDR_WIDTH-1:0] a, input logic [1:0] s);
        d_push(n, CMD_LOAD, a, s, 64'd0);
    endtask
    task automatic d_store(input string n, input logic [PADDR_WIDTH-1:0] a, input logic [1:0] s,
                           input logic [63:0] v);
        d_push(n, CMD_STORE, a, s, v);
    endtask
    //=================================================================
    // CPU BFM : debug side (second port of the data cache)
    //   One access at a time, the way the debug module issues them.
    //=================================================================
    task automatic dbg_exec(input string name, input logic [3:0] cmd,
                            input logic [PADDR_WIDTH-1:0] addr, input logic [1:0] size,
                            input logic [63:0] wdata, input logic [63:0] exp,
                            input bit exp_err, input bit check_data);
        int guard;
        @(negedge clk);
        dbg_req_valid = 1'b1;
        dbg_req_cmd   = cmd;
        dbg_req_addr  = addr;
        dbg_req_size  = size;
        dbg_req_wdata = wdata;
        guard = 0;
        do begin
            @(posedge clk);
            guard++;
            if (guard > 100_000) begin
                check({name, " : debug request accepted"}, 1'b0);
                $finish;
            end
        end while (!dbg_req_ready);
        @(negedge clk);
        dbg_req_valid = 1'b0;
        guard = 0;
        while (!dbg_resp_valid) begin
            @(posedge clk);
            guard++;
            if (guard > 100_000) begin
                check({name, " : debug response"}, 1'b0);
                $finish;
            end
        end
        check({name, " : error flag"}, dbg_resp_error === exp_err);
        if (check_data && !exp_err) check64(name, exp, dbg_resp_data);
        @(negedge clk);
    endtask

    task automatic dbg_load(input string n, input logic [PADDR_WIDTH-1:0] a,
                            input logic [1:0] sz);
        logic [63:0] w;
        w = ref_read_word(a);
        dbg_exec(n, CMD_LOAD, a, sz, 64'd0, extract(w, a, sz), 1'b0, 1'b1);
    endtask
    task automatic dbg_store(input string n, input logic [PADDR_WIDTH-1:0] a,
                             input logic [1:0] sz, input logic [63:0] v);
        logic [63:0] w;
        w = ref_read_word(a);
        ref_write_word(a, merge(w, a, sz, v));
        if (res_valid && (res_addr >> $clog2(DC_BLOCK)) == (a >> $clog2(DC_BLOCK)))
            res_valid = 1'b0;
        dbg_exec(n, CMD_STWTHR, a, sz, v, 64'd0, 1'b0, 1'b0);
    endtask

    task automatic d_stwthr(input string n, input logic [PADDR_WIDTH-1:0] a, input logic [1:0] s,
                            input logic [63:0] v);
        d_push(n, CMD_STWTHR, a, s, v);
    endtask
    task automatic d_fence(input string n);
        d_push(n, CMD_FENCE, MEM_BASE, 2'd3, 64'd0);
    endtask
    task automatic d_flush(input string n);
        d_push(n, CMD_FLUSH, MEM_BASE, 2'd3, 64'd0);
    endtask

    // wait until every data response has arrived
    task automatic d_drain();
        int guard;
        guard = 0;
        while ((dq_rd != dq_wr) || (rq_rd != rq_wr)) begin
            @(posedge clk);
            guard++;
            if (guard > 2_000_000) begin
                check("data response timeout", 1'b0);
                $finish;
            end
        end
    endtask

    // request that is expected to fail on the bus (address outside the
    // memory map). The reference memory is not touched.
    task automatic d_push_err(input string name, input logic [3:0] cmd,
                              input logic [PADDR_WIDTH-1:0] addr, input logic [1:0] size,
                              input logic [63:0] wdata);
        dq_data[dq_wr]  = 64'd0;
        dq_err[dq_wr]   = 1'b1;
        dq_check[dq_wr] = 1'b1;
        dq_is_sc[dq_wr] = 1'b0;
        dq_addr[dq_wr]  = addr;
        dq_size[dq_wr]  = size;
        dq_wdata[dq_wr] = wdata;
        dq_name[dq_wr]  = name;
        dq_wr           = (dq_wr + 1) % QDEPTH;

        rq_put(cmd, addr, size, wdata);
    endtask

    //=================================================================
    // CPU BFM : instruction side
    //=================================================================
    task automatic i_push(input string name, input logic [PADDR_WIDTH-1:0] addr);
        logic [63:0] word;
        word           = ref_read_word(addr);
        iq_data[iq_wr] = word[FETCH_WIDTH-1:0];   // FETCH_WIDTH=64 : whole word
        iq_err[iq_wr]  = 1'b0;
        iq_name[iq_wr] = name;
        iq_wr          = (iq_wr + 1) % QDEPTH;

        iq_put(addr);
    endtask

    task automatic i_push_err(input string name, input logic [PADDR_WIDTH-1:0] addr);
        iq_data[iq_wr] = '0;
        iq_err[iq_wr]  = 1'b1;
        iq_name[iq_wr] = name;
        iq_wr          = (iq_wr + 1) % QDEPTH;

        iq_put(addr);
    endtask

    task automatic i_drain();
        int guard;
        guard = 0;
        while ((iq_rd != iq_wr) || (iq_rd_f != iq_wr_f)) begin
            @(posedge clk);
            guard++;
            if (guard > 2_000_000) begin
                check("instruction response timeout", 1'b0);
                $finish;
            end
        end
    endtask

    task automatic i_flush_all();
        i_flush_start();
        i_flush_wait();
    endtask

    // assert fence.i without waiting (it may overlap a line fill)
    task automatic i_flush_start();
        @(negedge clk);
        i_flush_valid = 1'b1;
    endtask

    // fence.i asserted for a few cycles only, without waiting for
    // i_flush_done: a fill started before the pulse must not validate its line
    // progress heartbeat, +hb=<cycles> (an Icarus run takes a long time)
    initial begin : heartbeat
        int hb;
        if ($value$plusargs("hb=%d", hb) && (hb > 0)) begin
            forever begin
                repeat (hb) @(posedge clk);
                $display("[%0t] ... %0d checks, %0d errors", $time, n_check, n_error);
            end
        end
    end

    task automatic i_flush_pulse(input int cycles);
        @(negedge clk);
        i_flush_valid = 1'b1;
        repeat (cycles) @(posedge clk);
        @(negedge clk);
        i_flush_valid = 1'b0;
    endtask
    // wait for the first data beat of an instruction fill
    task automatic i_wait_fill();
        int guard;
        guard = 0;
        while (u_cache.u_icache.m_axi4_rvalid !== 1'b1) begin
            @(posedge clk);
            guard++;
            if (guard > 10_000) begin
                check("instruction fill did not start", 1'b0);
                $finish;
            end
        end
    endtask
    task automatic i_flush_wait();
        @(posedge clk);
        while (i_flush_done !== 1'b1) @(posedge clk);
        @(negedge clk);
        i_flush_valid = 1'b0;
    endtask

    //=================================================================
    // Response checkers
    //=================================================================
    always @(posedge clk) begin
        if (rst_n && d_resp_valid) begin
            n_d_resp++;
            if (dq_rd == dq_wr) begin
                check("unexpected data response", 1'b0);
            end else begin
                if (dq_err[dq_rd]) begin
                    check({dq_name[dq_rd], " : expected error response"}, d_resp_error === 1'b1);
                end else begin
                    check({dq_name[dq_rd], " : no error expected"}, d_resp_error === 1'b0);
                    if (dq_check[dq_rd]) begin
                        check64(dq_name[dq_rd], dq_data[dq_rd], d_resp_data);
                    end else if (dq_is_sc[dq_rd]) begin
                        // adaptive SC: follow the DUT and keep the reference in step
                        check({dq_name[dq_rd], " : SC result is 0 or 1"},
                              (d_resp_data === 64'd0) || (d_resp_data === 64'd1));
                        if (d_resp_data === 64'd0) begin
                            ref_write_word(dq_addr[dq_rd],
                                           merge(ref_read_word(dq_addr[dq_rd]), dq_addr[dq_rd],
                                                 dq_size[dq_rd], dq_wdata[dq_rd]));
                            if (dq_data[dq_rd] !== 64'd0)
                                check({dq_name[dq_rd], " : SC succeeded without reservation"}, 1'b0);
                        end
                    end
                end
                dq_rd = (dq_rd + 1) % QDEPTH;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && i_resp_valid) begin
            n_i_resp++;
            if (iq_rd == iq_wr) begin
                check("unexpected instruction response", 1'b0);
            end else begin
                check({iq_name[iq_rd], " : no error expected"}, i_resp_error === iq_err[iq_rd]);
                if (!iq_err[iq_rd])
                    check64(iq_name[iq_rd], iq_data[iq_rd], i_resp_data);
                iq_rd = (iq_rd + 1) % QDEPTH;
            end
        end
    end

    //=================================================================
    // Backdoor check of the whole memory image (after FLUSH)
    //=================================================================
    // whitebox: is the line holding `addr` valid in the data cache?
    localparam int DC_OFF_BITS = $clog2(DC_BLOCK);
    localparam int DC_IDX_BITS = $clog2(DC_SETS);
    localparam int DC_TAG_BITS = PADDR_WIDTH - DC_IDX_BITS - DC_OFF_BITS;

    function automatic bit dc_line_present(input logic [PADDR_WIDTH-1:0] addr);
        int idx;
        logic [DC_TAG_BITS-1:0] tag;
        idx = int'(addr[DC_OFF_BITS +: DC_IDX_BITS]);
        tag = addr[PADDR_WIDTH-1 -: DC_TAG_BITS];
        for (int w = 0; w < DC_WAYS; w++)
            if (u_cache.u_dcache.u_tag.valid_bit[idx*DC_WAYS + w] &&
                (u_cache.u_dcache.u_tag.tag_mem[idx*DC_WAYS + w] == tag))
                return 1'b1;
        return 1'b0;
    endfunction

    // compare one word of the memory model with the reference
    task automatic check_mem_word(input string name, input logic [PADDR_WIDTH-1:0] addr);
        int i;
        i = ref_index(addr);
        check64({name, " (memory)"}, ref_mem[i], u_mem.mem[i]);
    endtask

    task automatic check_memory(input string name);
        int bad;
        bad = 0;
        for (int i = 0; i < MEM_WORDS; i++) begin
            if (u_mem.mem[i] !== ref_mem[i]) begin
                if (bad < 5)
                    $display("[%0t] [FAIL] %s : mem[0x%08h] expected=0x%016h actual=0x%016h",
                             $time, name, MEM_BASE + 8*i, ref_mem[i], u_mem.mem[i]);
                bad++;
            end
        end
        n_check++;
        if (bad != 0) begin
            n_error++;
            $display("[%0t] [FAIL] %s : %0d words differ", $time, name, bad);
        end
    endtask

    //=================================================================
    // Tests
    //=================================================================
    `include "tb_CACHE_perf.svh"
    `include "tb_CACHE_tests.svh"
`ifdef PROBE
    `include "probe.svh"
`endif

    //=================================================================
    // Watchdog
    //=================================================================
    initial begin
        #(64'd2_000_000_000);
        $display("[%0t] [FAIL] watchdog timeout", $time);
        $finish;
    end

endmodule : tb_CACHE
