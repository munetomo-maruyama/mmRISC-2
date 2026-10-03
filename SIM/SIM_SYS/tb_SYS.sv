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
//     +dtrace           every request and answer on the data port of the
//                       core, with the cycle and the stage it is issued from
//
//   A program may mark the part to profile: tohost = 0x0200_0000_0000_0000
//   (device 2, command 0) starts it -- every counter of the profile goes
//   back to zero -- and 0x0201_0000_0000_0000 (command 1) stops it.
//     +stall            random stalls on both bus slaves
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_SYS
    #(
        // Where the core starts. The default is main memory, which is
        // cached. Overriding it with the peripheral window (-GRESET_ADDR)
        // makes the core fetch its first instructions UNCACHED over
        // AXI4-Lite, which is what the LiteX BIOS does: it runs from a ROM
        // at 0x1000_0000, below MEM_BASE.
        parameter logic [39:0] RESET_ADDR = 40'h00_8000_0000,
        // for trying other sizes of the branch target buffer (-GBTB_ENTRIES)
        parameter int          BTB_ENTRIES = 256
    );

    localparam int          SOC_ADDR_WIDTH = 40;
    localparam logic [39:0] MEM_BASE    = 40'h00_8000_0000;
    localparam int          MEM_WORDS   = 262144;             // 2 MiB
    // the peripheral window sits where LiteX puts its ROM
    localparam logic [39:0] PERIPH_BASE = 40'h00_1000_0000;

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

    // the DMA port of CPU_TOP, driven by the DMA model below
    logic [SOC_ADDR_WIDTH-1:0]      dma_awaddr, dma_araddr;
    logic                           dma_awvalid, dma_awready, dma_wvalid, dma_wready;
    logic [63:0]                    dma_wdata, dma_rdata;
    logic [7:0]                     dma_wstrb;
    logic [1:0]                     dma_bresp, dma_rresp;
    logic                           dma_bvalid, dma_bready, dma_arvalid, dma_arready;
    logic                           dma_rvalid, dma_rready;
    logic [31:0]                    ext_irq;

    //=================================================================
    // the CPU
    //=================================================================
    CPU_TOP
        #(
            .AXI4_ADDR_WIDTH (SOC_ADDR_WIDTH),
            .AXIL_ADDR_WIDTH (SOC_ADDR_WIDTH),
            .MEM_BASE        (MEM_BASE),
            .RESET_VECTOR    ({24'd0, RESET_ADDR}),
            .NUM_IRQ         (32),
            .BTB_ENTRIES     (BTB_ENTRIES),
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
            .s_dma_awaddr   (dma_awaddr),
            .s_dma_awvalid  (dma_awvalid),
            .s_dma_awready  (dma_awready),
            .s_dma_wdata    (dma_wdata),
            .s_dma_wstrb    (dma_wstrb),
            .s_dma_wvalid   (dma_wvalid),
            .s_dma_wready   (dma_wready),
            .s_dma_bresp    (dma_bresp),
            .s_dma_bvalid   (dma_bvalid),
            .s_dma_bready   (dma_bready),
            .s_dma_araddr   (dma_araddr),
            .s_dma_arvalid  (dma_arvalid),
            .s_dma_arready  (dma_arready),
            .s_dma_rdata    (dma_rdata),
            .s_dma_rresp    (dma_rresp),
            .s_dma_rvalid   (dma_rvalid),
            .s_dma_rready   (dma_rready),
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
        // A boot stub in the uncached window, for the run that starts
        // there. Assembled from:
        //     li t0, 0x80000000   ; addiw t0,zero,1 + slli t0,t0,31
        //     jr t0
        // Two of the three are compressed, so the run also fetches RVC
        // parcels over AXI4-Lite.
        u_per.mem[0] = 64'h828202fe_0010029b;
        // the mailbox of the DMA model and the window it writes to
        for (int i = 256; i < 512; i++) u_per.mem[i] = 64'd0;
    end

    //=================================================================
    // a DMA master on the DMA port of CPU_TOP (CPU_DMA/DMA_CACHE)
    //
    //   A program talks to it through a mailbox in the peripheral memory,
    //   which the CPU does not cache (0x1000_0800, words 256..261):
    //
    //     256 cmd  : 1 read n double words from addr and compare them with
    //                  the pattern, 2 write the pattern, 3 write only bytes
    //                  2..5 of each double word (strobe 0x3C)
    //     257 addr, 258 n, 259 seed
    //     260 the number of double words a read found different
    //     261 done : written last, the program waits for it
    //
    //   pattern(seed, i) = seed + i * 0x9E3779B97F4A7C15
    //=================================================================
    localparam logic [63:0] DMA_K = 64'h9E37_79B9_7F4A_7C15;

    // The bus is driven on the falling edge with blocking assignments, so
    // that the RTL, which samples on the rising edge, never races with it.
    task automatic dma_write(input logic [SOC_ADDR_WIDTH-1:0] a,
                             input logic [63:0] d, input logic [7:0] st);
        bit aw_done, w_done;
        @(negedge clk);
        dma_awaddr = a; dma_awvalid = 1'b1;
        dma_wdata  = d; dma_wstrb   = st; dma_wvalid = 1'b1;
        dma_bready = 1'b1;
        aw_done = 1'b0; w_done = 1'b0;
        while (!(aw_done && w_done)) begin
            @(posedge clk);
            if (dma_awvalid && dma_awready) aw_done = 1'b1;
            if (dma_wvalid  && dma_wready)  w_done  = 1'b1;
            @(negedge clk);
            if (aw_done) dma_awvalid = 1'b0;
            if (w_done)  dma_wvalid  = 1'b0;
        end
        while (!dma_bvalid) @(negedge clk);
        @(posedge clk);          // the response is taken on this edge
        @(negedge clk);
    endtask

    task automatic dma_read(input logic [SOC_ADDR_WIDTH-1:0] a, output logic [63:0] d);
        @(negedge clk);
        dma_araddr = a; dma_arvalid = 1'b1; dma_rready = 1'b1;
        do @(posedge clk); while (!dma_arready);
        @(negedge clk);
        dma_arvalid = 1'b0;
        while (!dma_rvalid) @(negedge clk);
        d = dma_rdata;
        @(posedge clk);
        @(negedge clk);
    endtask

    initial begin
        dma_awaddr = '0; dma_awvalid = 1'b0; dma_wdata = 64'd0; dma_wstrb = 8'd0;
        dma_wvalid = 1'b0; dma_bready = 1'b1; dma_araddr = '0; dma_arvalid = 1'b0;
        dma_rready = 1'b1;
        forever begin
            @(posedge clk);
            if (rst_n && (u_per.mem[256] != 64'd0) && (u_per.mem[261] == 64'd0)) begin
                logic [63:0] cmd, addr, n, seed, got, want;
                int bad;
                cmd  = u_per.mem[256];
                addr = u_per.mem[257];
                n    = u_per.mem[258];
                seed = u_per.mem[259];
                bad  = 0;
                if ($test$plusargs("dmadbg"))
                    $display("[DMA] cmd %0d addr %h n %0d seed %h", cmd, addr, n, seed);
                for (int i = 0; i < int'(n); i++) begin
                    want = seed + 64'(i) * DMA_K;
                    case (cmd)
                        64'd1: begin
                            dma_read(SOC_ADDR_WIDTH'(addr + 64'(8 * i)), got);
                            if (got !== want) bad++;
                        end
                        64'd2: dma_write(SOC_ADDR_WIDTH'(addr + 64'(8 * i)), want, 8'hFF);
                        64'd3: dma_write(SOC_ADDR_WIDTH'(addr + 64'(8 * i)), want, 8'h3C);
                        default: ;
                    endcase
                end
                u_per.mem[260] = 64'(bad);
                u_per.mem[256] = 64'd0;
                u_per.mem[261] = 64'd1;
            end
        end
    end

    //=================================================================
    // reads of 0x1000_0F00 on the peripheral bus, counted into word 500
    // (0x1000_0FA0) : a program checks that a fetch the PMP refuses never
    // reaches the bus (d02_pmp_fetch)
    //=================================================================
    always @(posedge clk)
        if (rst_n && axil_arvalid && axil_arready &&
            ((axil_araddr & ~40'd7) == 40'h00_1000_0F00))
            u_per.mem[500] = u_per.mem[500] + 64'd1;

    //=================================================================
    // tohost, caught on the cache port
    //
    //   The address is virtual when the request is made and physical one
    //   cycle later, exactly as the cache takes it (CPU_CACHE_SPEC.md 5.6).
    //=================================================================
    logic [63:0] tohost;
    logic        prof_start, prof_stop;      // the markers, for one cycle
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
                else if ((th_dev == 8'd2) && (th_cmd == 8'd0)) prof_start = 1'b1;
                else if ((th_dev == 8'd2) && (th_cmd == 8'd1)) prof_stop  = 1'b1;
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

    //-----------------------------------------------------------------
    // The same cycles once more, counted where an instruction is issued
    // (ID -> EX) instead of where one retires. A cycle at the end of the
    // pipeline only sees what is there now: the bubbles a mispredicted
    // branch leaves behind arrive there later and look like nothing. At
    // the issue point every cycle either issues or has a reason not to.
    //-----------------------------------------------------------------
    int  prof_cycles, prof_retired;
    int  q_late, q_late_miss;
    int  q_lu_st, q_lu_addr, q_lu_br, q_lu_jalr, q_lu_mdu, q_lu_fp, q_lu_alu;
    int  q_issue, q_redirect, q_ma, q_mr, q_unit, q_lu, q_mmu,
         q_refill, q_fetch, q_serial, q_other;
    int  e_br, e_jal, e_jalr, e_mp_br, e_mp_jal, e_mp_jalr, e_mdu, e_trap;
    int  e_strad, e_mp_strad;     // 32 bit branch / jal whose upper half is in the next fetch word
    bit  after_redirect, prof_on, prof_marked;

    task automatic prof_clear;
        prof_cycles = 0; prof_retired = 0;
        q_issue = 0; q_redirect = 0; q_ma = 0; q_mr = 0; q_unit = 0;
        q_late = 0; q_late_miss = 0;
        q_lu_st = 0; q_lu_addr = 0; q_lu_br = 0; q_lu_jalr = 0; q_lu_mdu = 0; q_lu_fp = 0; q_lu_alu = 0;
        q_lu = 0; q_mmu = 0; q_refill = 0; q_fetch = 0; q_serial = 0;
        q_other = 0;
        e_br = 0; e_jal = 0; e_jalr = 0; e_mp_br = 0; e_mp_jal = 0;
        e_mp_jalr = 0; e_mdu = 0; e_trap = 0; e_strad = 0; e_mp_strad = 0;
        p_dcache = 0; p_unit = 0; p_mmu = 0; p_starve = 0; p_serial = 0;
        p_other = 0; n_dacc = 0; n_ifetch = 0;
    endtask

    initial begin
        prof_clear();
        prof_on        = 1'b1;
        prof_marked    = 1'b0;
        after_redirect = 1'b0;
        prof_start     = 1'b0;
        prof_stop      = 1'b0;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (prof_start) begin
                prof_clear();
                prof_on     = 1'b1;
                prof_marked = 1'b1;
                prof_start  = 1'b0;
            end
            if (prof_stop) begin
                prof_on   = 1'b0;
                prof_stop = 1'b0;
            end
            if (prof_on) begin
                prof_cycles++;
                if (`CORE.trace_valid) prof_retired++;
                if (`CORE.mr_late_go) q_late++;
                if (`CORE.kill_ex)    q_late_miss++;
                if (`CORE.id_issue)                    q_issue++;
                else if (`CORE.redirect_valid)         q_redirect++;
                else if (`CORE.stall_ex) begin
                    if (`CORE.stall_ma)                q_ma++;
                    else if ((`CORE.mdu_active & ~`CORE.mdu_done) |
                             (`CORE.fpu_active & ~`CORE.fpu_done))
                                                       q_unit++;
                    else if (`CORE.lu_hazard) begin
                        q_lu++;
                        // what waits: the data of a store only, an address,
                        // a branch or jump, a multiply / divide, FP, or the
                        // rest (integer ALU, CSR)
                        if (`CORE.lu_fp | `CORE.ex_is_fp)          q_lu_fp++;
                        else if (`CORE.ex_is_store &&
                                 (`CORE.mr_rd != `CORE.ex_rs1))    q_lu_st++;
                        else if (`CORE.ex_is_load | `CORE.ex_is_store)
                                                                   q_lu_addr++;
                        else if (`CORE.ex_is_ctrl) begin
                            q_lu_br++;
                            if (`CORE.ex_is_jalr) q_lu_jalr++;
                        end
                        else if (`CORE.ex_is_mdu)                  q_lu_mdu++;
                        else                                       q_lu_alu++;
                    end
                    else if (`CORE.ex_mmu_wait)        q_mmu++;
                    else                               q_mr++;
                end
                else if (~`CORE.fq_valid) begin
                    if (after_redirect)                q_refill++;
                    else                               q_fetch++;
                end
                else if (~`CORE.id_ready)              q_serial++;
                else                                   q_other++;

                if (`CORE.ex_ctrl_go) begin
                    if (`CORE.ex_is_branch) begin e_br++;   if (`CORE.ex_mispredict) e_mp_br++;   end
                    if (`CORE.ex_is_jal)    begin e_jal++;  if (`CORE.ex_mispredict) e_mp_jal++;  end
                    if (`CORE.ex_is_jalr)   begin e_jalr++; if (`CORE.ex_mispredict) e_mp_jalr++; end
                end
                // the buffer never predicts these (CPU_CORE_SPEC.md decision 34)
                if (`CORE.ex_ctrl_go && !`CORE.ex_is_rvc && (`CORE.ex_pc[2:1] == 2'b11) &&
                    (`CORE.ex_is_branch || `CORE.ex_is_jal)) begin
                    e_strad++;
                    if (`CORE.ex_mispredict) e_mp_strad++;
                end
                if (`CORE.mdu_start)  e_mdu++;
                if (`CORE.trap_taken) e_trap++;
            end
            // the front end refills from a redirect until the next issue
            if (`CORE.redirect_valid)  after_redirect = 1'b1;
            else if (`CORE.id_issue)   after_redirect = 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if (prof_on && u_cpu_top.cpu_d_req_valid && u_cpu_top.cpu_d_req_ready)
                n_dacc++;
            if (prof_on && u_cpu_top.cpu_i_req_valid && u_cpu_top.cpu_i_req_ready)
                n_ifetch++;
            if (`CORE.trace_valid) begin
                n_retired <= n_retired + 1;
                if ($test$plusargs("trace"))
                    $display("[%0t] %010h : %08h", $time,
                             `CORE.trace_pc, `CORE.trace_insn);
            end
            else if (!prof_on)            ;
            else if (`CORE.stall_ma)      p_dcache++;
            else if ((`CORE.mdu_active & ~`CORE.mdu_done) |
                     (`CORE.fpu_active & ~`CORE.fpu_done))
                                          p_unit++;
            else if (`CORE.ex_mmu_wait)   p_mmu++;
            else if (~`CORE.fq_valid)     p_starve++;
            else if (~`CORE.id_ready)     p_serial++;
            else                          p_other++;
        end
    end

    // +dtrace : the data port of the core, cycle by cycle
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("dtrace")) begin
            if (u_cpu_top.cpu_d_req_valid && u_cpu_top.cpu_d_req_ready)
                $display("[%0d] D REQ  cmd=%0d addr=%010h  (pc in MR %010h, in MA %010h)",
                         cycle_count, u_cpu_top.cpu_d_req_cmd, u_cpu_top.cpu_d_req_addr,
                         `CORE.mr_pc, `CORE.ma_pc);
            if (u_cpu_top.cc_d_resp_valid)
                $display("[%0d] D RESP data=%016h  (pc in MA %010h, stall_ma=%0d)",
                         cycle_count, u_cpu_top.cc_d_resp_data, `CORE.ma_pc, `CORE.stall_ma);
        end
    end

    function automatic string pct(input int n);
        return $sformatf("%9d (%5.1f%%)", n, 100.0 * real'(n) / real'(prof_cycles));
    endfunction

    task automatic report_profile;
        $display("");
        $display(" %s: cycles %0d, retired %0d, CPI %0.3f",
                 prof_marked ? "the marked part" : "the whole run",
                 prof_cycles, prof_retired, real'(prof_cycles) / real'(prof_retired));
        $display("");
        $display(" where an instruction retires (what the last stage sees)");
        $display("   retired                      : %s", pct(prof_retired));
        $display("   waiting for the data cache   : %s", pct(p_dcache));
        $display("   waiting for MDU or FPU       : %s", pct(p_unit));
        $display("   waiting for a translation    : %s", pct(p_mmu));
        $display("   front end has nothing        : %s", pct(p_starve));
        $display("   serialising an instruction   : %s", pct(p_serial));
        $display("   other bubbles                : %s", pct(p_other));
        $display("   %0d data accesses, %0.2f cycles of stall each, %0d fetch words",
                 n_dacc, real'(p_dcache) / real'(n_dacc), n_ifetch);
        $display("");
        $display(" where an instruction is issued (ID -> EX)");
        $display("   issued                       : %s", pct(q_issue));
        $display("   redirect (the cycle itself)  : %s", pct(q_redirect));
        $display("   refill after a redirect      : %s", pct(q_refill));
        $display("   front end empty otherwise    : %s", pct(q_fetch));
        $display("   EX held: MA waits for D$     : %s", pct(q_ma));
        $display("   EX held: MR waits for D$     : %s", pct(q_mr));
        $display("   EX held: load-use            : %s", pct(q_lu));
        $display("   branches resolved in MR (on a load): %0d, %0d of them guessed wrong",
                 q_late, q_late_miss);
        $display("     waiting: store data %0d, address %0d, branch/jump %0d (jalr %0d), ALU %0d, MDU %0d, FP %0d",
                 q_lu_st, q_lu_addr, q_lu_br, q_lu_jalr, q_lu_alu, q_lu_mdu, q_lu_fp);
        $display("   EX held: MDU or FPU          : %s", pct(q_unit));
        $display("   EX held: translation         : %s", pct(q_mmu));
        $display("   serialising (CSR, fence)     : %s", pct(q_serial));
        $display("   other                        : %s", pct(q_other));
        $display("");
        $display(" control transfers (mispredicted / executed)");
        $display("   branch %0d / %0d, jal %0d / %0d, jalr %0d / %0d",
                 e_mp_br, e_br, e_mp_jal, e_jal, e_mp_jalr, e_jalr);
        $display("   of the branches and jal: %0d / %0d at the end of a fetch word (32 bit at offset 6)",
                 e_mp_strad, e_strad);
        $display("   MDU operations %0d, traps %0d", e_mdu, e_trap);
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
