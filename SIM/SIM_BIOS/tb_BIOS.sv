//---------------------------------------------------------------------------
// tb_BIOS.sv
//
// The LiteX BIOS of the Arty build (LitexSystem/build/software/bios) on
// CPU_TOP, with the real caches, main memory on AXI4 and the part of the
// LiteX SoC the BIOS needs on AXI4-Lite (LITEX_PERIPH): ROM, SRAM, ctrl,
// timer0 and the UART, whose interrupt goes to PLIC source 1 exactly as in
// the generated SoC (ext_irq = {interrupts, 1'b0}).
//
//   +bios=<file>      BIOS image, one 64 bit word per line
//   +maxcycles=<n>    how long to run (default 3000000)
//   +uart_cycles=<n>  cycles per character of the UART (default 4340,
//                     115200 baud at 50 MHz)
//
// PASS when the BIOS has printed "Initializing SDRAM" (it has come through
// the banner and the whole SoC report) and at least one UART interrupt was
// taken on the way, which is what the BIOS needs as soon as the 16 entry
// FIFO of the UART fills. On the Arty the first build stopped after 16
// characters because no interrupt ever came (TIMING.md 20). The SDRAM
// training that follows is not modelled here and fails.
//   +trace            retirement trace
//   +traps            every trap, with the interrupt lines
//
// Everything the UART sends is printed. Every trap is reported, with the
// state of the interrupt lines, so that a BIOS that stops talking can be
// told apart from one that never gets its UART interrupt.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_BIOS
    #(
        // Where the core starts. The default is main memory, which is
        // cached. Overriding it with the peripheral window (-GRESET_ADDR)
        // makes the core fetch its first instructions UNCACHED over
        // AXI4-Lite, which is what the LiteX BIOS does: it runs from a ROM
        // at 0x1000_0000, below MEM_BASE.
        parameter logic [39:0] RESET_ADDR = 40'h00_1000_0000
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
    // main memory and the LiteX side
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

    logic uart_irq, timer_irq;

    LITEX_PERIPH #(.ADDR_WIDTH (SOC_ADDR_WIDTH)) u_per
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
            .rvalid (axil_rvalid), .rready (axil_rready),
            .uart_irq (uart_irq),
            .timer_irq (timer_irq)
        );

    // LiteX interrupt i is PLIC source i+1 (LitexSystem/cpu/mmrisc/core.py)
    assign ext_irq = {28'd0, 1'b0, timer_irq, uart_irq, 1'b0};

    //=================================================================
    // what happens
    //=================================================================
    `define CORE u_cpu_top.g_core.u_cpu_core
    int  cycle_count, max_cycles, n_retired, n_traps, n_uart_int;
    string bios_file;

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if (`CORE.trace_valid) begin
                n_retired <= n_retired + 1;
                if ($test$plusargs("trace"))
                    $display("[%0d] %010h : %08h", cycle_count, `CORE.trace_pc, `CORE.trace_insn);
            end
            if (`CORE.trap_valid) begin
                n_traps <= n_traps + 1;
                if (`CORE.trap_is_int && (`CORE.trap_cause == 5'd11))
                    n_uart_int <= n_uart_int + 1;
                if ($test$plusargs("traps"))
                    $display("\n[%0d] TRAP int=%0b cause=%0d epc=%010h tval=%010h  uart_irq=%b meip=%b",
                             cycle_count, `CORE.trap_is_int, `CORE.trap_cause,
                             `CORE.trap_epc, `CORE.trap_tval, uart_irq,
                             u_cpu_top.irq_m_ext[0]);
            end
        end
    end

    initial begin
        #1;
        if (!$value$plusargs("bios=%s", bios_file)) bios_file = "bios.hex";
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 3000000;
        for (int i = 0; i < MEM_WORDS; i++) u_mem.mem[i] = 64'd0;
        for (int i = 0; i < 128 * 1024 / 8; i++) u_per.rom[i] = 64'd0;
        $readmemh(bios_file, u_per.rom);
    end

    initial begin
        rst_n       = 1'b0;
        rst_dbg_n   = 1'b0;
        cycle_count = 0;
        n_retired   = 0;
        n_traps     = 0;
        n_uart_int  = 0;
        repeat (20) @(posedge clk);
        rst_n     = 1'b1;
        rst_dbg_n = 1'b1;
        while ((cycle_count < max_cycles) &&
               (u_per.tx_tail[8*18-1:0] != "Initializing SDRAM"))
            @(posedge clk);
        $display("");
        $display("==========================================================");
        if ((u_per.tx_tail[8*18-1:0] == "Initializing SDRAM") && (n_uart_int > 0))
            $display(" BIOS TEST RESULT : PASS   (%0d cycles, %0d UART interrupts)",
                     cycle_count, n_uart_int);
        else
            $display(" BIOS TEST RESULT : FAIL   (%0d cycles, %0d UART interrupts)",
                     cycle_count, n_uart_int);
        $display(" %0d cycles, %0d retired, %0d traps, pc of the last retired %010h",
                 cycle_count, n_retired, n_traps, `CORE.trace_pc);
        $display(" uart_irq=%b meip(PLIC)=%b  uart ev_enable=%b tx_count=%0d",
                 uart_irq, u_cpu_top.irq_m_ext[0], u_per.uart_ev_enable, u_per.tx_count);
        $display(" PLIC: prio[1]=%0d pending[1]=%b gw_ready[1]=%b enable[0][1]=%b threshold[0]=%0d irq=%b",
                 u_cpu_top.u_mmio.u_plic.prio[1], u_cpu_top.u_mmio.u_plic.pending[1],
                 u_cpu_top.u_mmio.u_plic.gw_ready[1], u_cpu_top.u_mmio.u_plic.enable[0][1],
                 u_cpu_top.u_mmio.u_plic.threshold[0], u_cpu_top.u_mmio.u_plic.irq);
        $display(" mie=%h mip=%h mstatus.MIE=%b", `CORE.u_csr.mie_val, `CORE.u_csr.mip_val, `CORE.u_csr.mstatus_mie);
        $display("==========================================================");
        $finish;
    end

endmodule : tb_BIOS
