//---------------------------------------------------------------------------
// tb_SYS.sv
//
// The core running through the real caches (CPU_CORE_SPEC.md 12.9).
//
//   CPU_TOP with USE_BFM=0, so the CPU side of CPU_CACHE is driven by
//   CPU_CORE and not by the bus function model. The memory bus goes to an
//   AXI4 slave holding the program, the peripheral bus to an AXI4-Lite
//   slave; the CLINT and the PLIC are inside CPU_TOP and never reach it.
//
//   The same programs as SIM_CORE run here. What SIM_CORE cannot answer is
//   what a load really costs: its memory model answers in a fixed number of
//   cycles that has nothing to do with the cache. Here a load hits or
//   misses for real.
//
//   The word the program ends with is caught on the cache port rather than
//   on the bus, because a store to it sits in the data cache until
//   something writes it back.
//
//     +hex=<file>       program image, one 64 bit word per line
//     +name=<string>    name in the result line
//     +tohost=<hex>     address of the tohost word (default 0x8000_2000)
//     +maxcycles=<n>
//     +trace            retirement trace
//     +profile          where the cycles went
//     +stall            random stalls on both bus slaves
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_SYS;

    localparam int          SOC_ADDR_WIDTH = 40;
    localparam logic [39:0] MEM_BASE    = 40'h00_8000_0000;
    localparam int          MEM_WORDS   = 262144;             // 2 MiB
    localparam logic [39:0] PERIPH_BASE = 40'h00_1200_0000;

    logic clk = 1'b0;
    logic rst_n, rst_dbg_n;
    always #5 clk = ~clk;

    //=================================================================
    // buses
    //=================================================================
    logic [3:0]                     axi4_awid, axi4_arid, axi4_bid, axi4_rid;
    logic [SOC_ADDR_WIDTH-1:0]      axi4_awaddr, axi4_araddr;
    logic [7:0]                     axi4_awlen, axi4_arlen;
    logic [2:0]                     axi4_awsize, axi4_arsize;
    logic [1:0]                     axi4_awburst, axi4_arburst;
    logic                           axi4_awlock, axi4_arlock;
    logic [3:0]                     axi4_awcache, axi4_arcache;
    logic [2:0]                     axi4_awprot, axi4_arprot;
    logic [3:0]                     axi4_awqos, axi4_arqos;
    logic                           axi4_awvalid, axi4_awready;
    logic                           axi4_arvalid, axi4_arready;
    logic [63:0]                    axi4_wdata, axi4_rdata;
    logic [7:0]                     axi4_wstrb;
    logic                           axi4_wlast, axi4_wvalid, axi4_wready;
    logic [1:0]                     axi4_bresp, axi4_rresp;
    logic                           axi4_bvalid, axi4_bready;
    logic                           axi4_rlast, axi4_rvalid, axi4_rready;

    logic [SOC_ADDR_WIDTH-1:0]      axil_awaddr, axil_araddr;
    logic [2:0]                     axil_awprot, axil_arprot;
    logic                           axil_awvalid, axil_awready;
    logic                           axil_arvalid, axil_arready;
    logic [63:0]                    axil_wdata, axil_rdata;
    logic [7:0]                     axil_wstrb;
    logic                           axil_wvalid, axil_wready;
    logic [1:0]                     axil_bresp, axil_rresp;
    logic                           axil_bvalid, axil_bready;
    logic                           axil_rvalid, axil_rready;

    logic                           ndmreset;
    logic [31:0]                    ext_irq;

    //=================================================================
    // the CPU
    //=================================================================
    CPU_TOP
        #(
            .AXI4_ADDR_WIDTH (SOC_ADDR_WIDTH),
            .AXIL_ADDR_WIDTH (SOC_ADDR_WIDTH),
            .MEM_BASE        (MEM_BASE),
            .RESET_VECTOR    ({24'd0, MEM_BASE}),
            .NUM_IRQ         (32),
            .USE_BFM         (0)
        )
    u_cpu_top
        (
            .clk            (clk),
            .rst_n          (rst_n),
            .rst_dbg_n      (rst_dbg_n),
            .ndmreset       (ndmreset),
            .m_axi4_awid    (axi4_awid),
            .m_axi4_awaddr  (axi4_awaddr),
            .m_axi4_awlen   (axi4_awlen),
            .m_axi4_awsize  (axi4_awsize),
            .m_axi4_awburst (axi4_awburst),
            .m_axi4_awlock  (axi4_awlock),
            .m_axi4_awcache (axi4_awcache),
            .m_axi4_awprot  (axi4_awprot),
            .m_axi4_awqos   (axi4_awqos),
            .m_axi4_awvalid (axi4_awvalid),
            .m_axi4_awready (axi4_awready),
            .m_axi4_wdata   (axi4_wdata),
            .m_axi4_wstrb   (axi4_wstrb),
            .m_axi4_wlast   (axi4_wlast),
            .m_axi4_wvalid  (axi4_wvalid),
            .m_axi4_wready  (axi4_wready),
            .m_axi4_bid     (axi4_bid),
            .m_axi4_bresp   (axi4_bresp),
            .m_axi4_bvalid  (axi4_bvalid),
            .m_axi4_bready  (axi4_bready),
            .m_axi4_arid    (axi4_arid),
            .m_axi4_araddr  (axi4_araddr),
            .m_axi4_arlen   (axi4_arlen),
            .m_axi4_arsize  (axi4_arsize),
            .m_axi4_arburst (axi4_arburst),
            .m_axi4_arlock  (axi4_arlock),
            .m_axi4_arcache (axi4_arcache),
            .m_axi4_arprot  (axi4_arprot),
            .m_axi4_arqos   (axi4_arqos),
            .m_axi4_arvalid (axi4_arvalid),
            .m_axi4_arready (axi4_arready),
            .m_axi4_rid     (axi4_rid),
            .m_axi4_rdata   (axi4_rdata),
            .m_axi4_rresp   (axi4_rresp),
            .m_axi4_rlast   (axi4_rlast),
            .m_axi4_rvalid  (axi4_rvalid),
            .m_axi4_rready  (axi4_rready),
            .m_axil_awaddr  (axil_awaddr),
            .m_axil_awprot  (axil_awprot),
            .m_axil_awvalid (axil_awvalid),
            .m_axil_awready (axil_awready),
            .m_axil_wdata   (axil_wdata),
            .m_axil_wstrb   (axil_wstrb),
            .m_axil_wvalid  (axil_wvalid),
            .m_axil_wready  (axil_wready),
            .m_axil_bresp   (axil_bresp),
            .m_axil_bvalid  (axil_bvalid),
            .m_axil_bready  (axil_bready),
            .m_axil_araddr  (axil_araddr),
            .m_axil_arprot  (axil_arprot),
            .m_axil_arvalid (axil_arvalid),
            .m_axil_arready (axil_arready),
            .m_axil_rdata   (axil_rdata),
            .m_axil_rresp   (axil_rresp),
            .m_axil_rvalid  (axil_rvalid),
            .m_axil_rready  (axil_rready),
            .ext_irq        (ext_irq),
            .jtag_tck       (1'b0),
            .jtag_tms_i     (1'b0),
            .jtag_tms_o     (),
            .jtag_tms_oe    (),
            .jtag_tdi       (1'b0),
            .jtag_tdo       (),
            .jtag_tdo_oe    (),
            .jtag_trst_n    (1'b1),
            .cjtag_en       (1'b0),
            .cjtag_online   (),
            .dbg_auth_en    (1'b0),
            .dbg_auth_key   ('0),
            .dbg_halted     (),
            .dbg_running    (),
            .dbg_dmactive   ()
        );

    //=================================================================
    // the two slaves
    //=================================================================
    AXI4_SLAVE_MEM
        #(
            .ID_WIDTH   (4),
            .ADDR_WIDTH (SOC_ADDR_WIDTH),
            .DATA_WIDTH (64),
            .DEPTH      (MEM_WORDS),
            .BASE_ADDR  (MEM_BASE),
            .INIT_BASE  (64'd0)
        )
    u_mem
        (
            .clk (clk), .rst_n (rst_n),
            .awid (axi4_awid), .awaddr (axi4_awaddr), .awlen (axi4_awlen),
            .awsize (axi4_awsize), .awburst (axi4_awburst),
            .awlock (axi4_awlock), .awcache (axi4_awcache),
            .awprot (axi4_awprot), .awqos (axi4_awqos),
            .awvalid (axi4_awvalid), .awready (axi4_awready),
            .wdata (axi4_wdata), .wstrb (axi4_wstrb), .wlast (axi4_wlast),
            .wvalid (axi4_wvalid), .wready (axi4_wready),
            .bid (axi4_bid), .bresp (axi4_bresp),
            .bvalid (axi4_bvalid), .bready (axi4_bready),
            .arid (axi4_arid), .araddr (axi4_araddr), .arlen (axi4_arlen),
            .arsize (axi4_arsize), .arburst (axi4_arburst),
            .arlock (axi4_arlock), .arcache (axi4_arcache),
            .arprot (axi4_arprot), .arqos (axi4_arqos),
            .arvalid (axi4_arvalid), .arready (axi4_arready),
            .rid (axi4_rid), .rdata (axi4_rdata), .rresp (axi4_rresp),
            .rlast (axi4_rlast), .rvalid (axi4_rvalid), .rready (axi4_rready)
        );

    AXIL_PERIPH
        #(
            .ADDR_WIDTH (SOC_ADDR_WIDTH),
            .DATA_WIDTH (64),
            .DEPTH      (512),
            .BASE_ADDR  (PERIPH_BASE)
        )
    u_per
        (
            .clk (clk), .rst_n (rst_n),
            .awaddr (axil_awaddr), .awprot (axil_awprot),
            .awvalid (axil_awvalid), .awready (axil_awready),
            .wdata (axil_wdata), .wstrb (axil_wstrb),
            .wvalid (axil_wvalid), .wready (axil_wready),
            .bresp (axil_bresp), .bvalid (axil_bvalid), .bready (axil_bready),
            .araddr (axil_araddr), .arprot (axil_arprot),
            .arvalid (axil_arvalid), .arready (axil_arready),
            .rdata (axil_rdata), .rresp (axil_rresp),
            .rvalid (axil_rvalid), .rready (axil_rready)
        );

    //=================================================================
    // the program
    //=================================================================
    string       hex_file, test_name;
    logic [63:0] tohost_addr;
    int          max_cycles;

    // after a delay, because AXI4_SLAVE_MEM fills its array from an initial
    // block of its own and the order of two initial blocks is not defined
    initial begin
        #1;
        if (!$value$plusargs("hex=%s", hex_file))   hex_file  = "tests/t01_alu.hex";
        if (!$value$plusargs("name=%s", test_name)) test_name = hex_file;
        if (!$value$plusargs("tohost=%h", tohost_addr))
            tohost_addr = 64'h0000_0000_8000_2000;
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 2000000;
        for (int i = 0; i < MEM_WORDS; i++) u_mem.mem[i] = 64'd0;
        $readmemh(hex_file, u_mem.mem);
        u_mem.stall_en = $test$plusargs("stall");
        u_per.stall_en = $test$plusargs("stall");
    end

    //=================================================================
    // tohost, caught on the cache port
    //
    //   The address is virtual when the request is made and physical one
    //   cycle later, exactly as the cache takes it (CPU_CACHE_SPEC.md 5.6).
    //=================================================================
    logic [63:0] tohost;
    logic        s1_valid, s1_store;
    logic [63:0] s1_wdata;
    logic [SOC_ADDR_WIDTH-1:0] s1_vaddr;
    logic [SOC_ADDR_WIDTH-1:0] s1_addr;
    logic [7:0]  th_dev, th_cmd;

    assign s1_addr = {u_cpu_top.cpu_d_req_paddr[SOC_ADDR_WIDTH-1:12], s1_vaddr[11:0]};
    assign th_dev  = s1_wdata[63:56];
    assign th_cmd  = s1_wdata[55:48];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_store <= 1'b0;
            s1_wdata <= 64'd0;
            s1_vaddr <= '0;
            tohost   <= 64'd0;
        end else begin
            s1_valid <= u_cpu_top.cpu_d_req_valid & u_cpu_top.cpu_d_req_ready;
            if (u_cpu_top.cpu_d_req_valid & u_cpu_top.cpu_d_req_ready) begin
                s1_store <= (u_cpu_top.cpu_d_req_cmd == 4'd1);
                s1_wdata <= u_cpu_top.cpu_d_req_wdata;
                s1_vaddr <= u_cpu_top.cpu_d_req_addr;
            end
            if (s1_valid && s1_store &&
                ({24'd0, s1_addr} == tohost_addr) && (s1_wdata != 64'd0)) begin
                if (th_dev == 8'd0)                            tohost <= s1_wdata;
                else if ((th_dev == 8'd1) && (th_cmd == 8'd1)) $write("%c", s1_wdata[7:0]);
            end
        end
    end

    //=================================================================
    // retirement, and where the cycles went
    //=================================================================
    int cycle_count, n_retired;
    int p_dcache, p_unit, p_mmu, p_starve, p_serial, p_other;
    int n_dacc, n_ifetch;

`define CORE u_cpu_top.g_core.u_cpu_core

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if (u_cpu_top.cpu_d_req_valid & u_cpu_top.cpu_d_req_ready)
                n_dacc <= n_dacc + 1;
            if (u_cpu_top.cpu_i_req_valid & u_cpu_top.cpu_i_req_ready)
                n_ifetch <= n_ifetch + 1;
            if (`CORE.trace_valid) begin
                n_retired <= n_retired + 1;
                if ($test$plusargs("trace"))
                    $display("[%0t] %010h : %08h", $time,
                             `CORE.trace_pc, `CORE.trace_insn);
            end
            else if (`CORE.stall_ma)      p_dcache <= p_dcache + 1;
            else if ((`CORE.mdu_active & ~`CORE.mdu_done) |
                     (`CORE.fpu_active & ~`CORE.fpu_done))
                                          p_unit   <= p_unit   + 1;
            else if (`CORE.ex_mmu_wait)   p_mmu    <= p_mmu    + 1;
            else if (~`CORE.fq_valid)     p_starve <= p_starve + 1;
            else if (~`CORE.id_ready)     p_serial <= p_serial + 1;
            else                          p_other  <= p_other  + 1;
        end
    end

    task automatic report_profile;
        $display("");
        $display(" cycles %0d, retired %0d, CPI %0.2f",
                 cycle_count, n_retired, real'(cycle_count) / real'(n_retired));
        $display("   waiting for the data cache : %6d (%0.1f%%)",
                 p_dcache, 100.0 * real'(p_dcache) / real'(cycle_count));
        $display("   waiting for MDU or FPU     : %6d (%0.1f%%)",
                 p_unit,   100.0 * real'(p_unit)   / real'(cycle_count));
        $display("   waiting for a translation  : %6d (%0.1f%%)",
                 p_mmu,    100.0 * real'(p_mmu)    / real'(cycle_count));
        $display("   front end has nothing      : %6d (%0.1f%%)",
                 p_starve, 100.0 * real'(p_starve) / real'(cycle_count));
        $display("   serialising an instruction : %6d (%0.1f%%)",
                 p_serial, 100.0 * real'(p_serial) / real'(cycle_count));
        $display("   other bubbles              : %6d (%0.1f%%)",
                 p_other,  100.0 * real'(p_other)  / real'(cycle_count));
        $display("   %0d data accesses, %0.2f cycles of stall each",
                 n_dacc, real'(p_dcache) / real'(n_dacc));
        $display("   %0d fetch words", n_ifetch);
    endtask

    //=================================================================
    initial begin
        rst_n       = 1'b0;
        rst_dbg_n   = 1'b0;
        ext_irq     = 32'd0;
        cycle_count = 0;
        n_retired   = 0;
        p_dcache = 0; p_unit = 0; p_mmu = 0;
        p_starve = 0; p_serial = 0; p_other = 0;
        n_dacc = 0; n_ifetch = 0;
        repeat (20) @(posedge clk);
        rst_n     = 1'b1;
        rst_dbg_n = 1'b1;

        while ((tohost === 64'd0) && (cycle_count < max_cycles)) @(posedge clk);

        $display("");
        $display("==========================================================");
        if (tohost === 64'd0)
            $display(" %s : FAIL   (watchdog after %0d cycles, %0d retired)",
                     test_name, cycle_count, n_retired);
        else if (tohost == 64'd1)
            $display(" %s : PASS   (%0d instructions retired, %0d cycles)",
                     test_name, n_retired, cycle_count);
        else
            $display(" %s : FAIL   (check %0d, tohost=%016h)",
                     test_name, tohost >> 1, tohost);
        if ($test$plusargs("profile")) report_profile();
        $display("==========================================================");
        $finish;
    end

endmodule : tb_SYS
