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
// With +linux the BIOS is not run. The ROM holds a stub that jumps to
// OpenSBI at 0x8000_0000 (a0 = hart 0), and main memory is loaded the way
// the BIOS would have left it after an SD card boot:
//
//   +fw=<file>        fw_jump.bin as hex, at 0x8000_0000
//   +image=<file>     the kernel Image as hex, at 0x8020_0000
//   +initrd=<file>    an initramfs as hex, at 0x8200_0000 (make linux-initrd)
//   +sdimg=<file>     an SD card with that image (SD_MODEL, make linux-sd)
//   +pcmon=<n>        print the PC of the last retired instruction every
//                     n cycles, to follow the boot where it prints nothing
//   +utrace=<n>       from the first instruction retired in user mode on,
//                     every trap, and the first n user mode instructions
//
// The run ends at maxcycles, at "Kernel panic", or at "Waiting for root
// device" / "VFS: Unable to mount", which is as far as a boot can get
// without an SD card model; with an initramfs, at the prompt of the shell
// ("\n# ", make linux-initrd).
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
    // the 256 MiB of the Arty: Linux takes its memory from the top down
    localparam int          MEM_WORDS   = 32 * 1024 * 1024;   // 256 MiB
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

    // the SD card (SD_MODEL) on the DMA port
    logic [31:0] sd_awaddr, sd_araddr;
    logic        sd_awvalid, sd_awready, sd_wvalid, sd_wready, sd_bvalid, sd_bready;
    logic        sd_arvalid, sd_arready, sd_rvalid, sd_rready;
    logic [63:0] sd_wdata, sd_rdata;
    logic [7:0]  sd_wstrb;
    logic [1:0]  sd_bresp, sd_rresp;
    logic              sd_irq;
    logic              sd_wr0_en, sd_wr1_en;
    logic [5:0]        sd_wr0_idx, sd_wr1_idx;
    logic [31:0]       sd_wr0_dat, sd_wr1_dat;
    logic [64*32-1:0]  sd_regs;


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
            // as on the Arty (LitexSystem/cpu/mmrisc/core.py): mtime steps
            // every 100 cycles, the 500 kHz of timebase-frequency
            .CLINT_TICK_DIV  (100),
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
            // the DMA port : not used here
            .s_dma_awaddr   ({8'd0, sd_awaddr}),
            .s_dma_awvalid  (sd_awvalid),
            .s_dma_awready  (sd_awready),
            .s_dma_wdata    (sd_wdata),
            .s_dma_wstrb    (sd_wstrb),
            .s_dma_wvalid   (sd_wvalid),
            .s_dma_wready   (sd_wready),
            .s_dma_bresp    (sd_bresp),
            .s_dma_bvalid   (sd_bvalid),
            .s_dma_bready   (sd_bready),
            .s_dma_araddr   ({8'd0, sd_araddr}),
            .s_dma_arvalid  (sd_arvalid),
            .s_dma_arready  (sd_arready),
            .s_dma_rdata    (sd_rdata),
            .s_dma_rresp    (sd_rresp),
            .s_dma_rvalid   (sd_rvalid),
            .s_dma_rready   (sd_rready),
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
            .timer_irq (timer_irq),
            .sd_wr0_en (sd_wr0_en), .sd_wr0_idx (sd_wr0_idx), .sd_wr0_dat (sd_wr0_dat),
            .sd_wr1_en (sd_wr1_en), .sd_wr1_idx (sd_wr1_idx), .sd_wr1_dat (sd_wr1_dat),
            .sd_regs (sd_regs)
        );

    SD_MODEL u_sd
        (
            .clk (clk), .rst_n (rst_n),
            .wr0_en (sd_wr0_en), .wr0_idx (sd_wr0_idx), .wr0_dat (sd_wr0_dat),
            .wr1_en (sd_wr1_en), .wr1_idx (sd_wr1_idx), .wr1_dat (sd_wr1_dat),
            .regs (sd_regs),
            .irq (sd_irq),
            .m_awaddr (sd_awaddr), .m_awvalid (sd_awvalid), .m_awready (sd_awready),
            .m_wdata (sd_wdata), .m_wstrb (sd_wstrb), .m_wvalid (sd_wvalid), .m_wready (sd_wready),
            .m_bresp (sd_bresp), .m_bvalid (sd_bvalid), .m_bready (sd_bready),
            .m_araddr (sd_araddr), .m_arvalid (sd_arvalid), .m_arready (sd_arready),
            .m_rdata (sd_rdata), .m_rresp (sd_rresp), .m_rvalid (sd_rvalid), .m_rready (sd_rready)
        );

    // LiteX interrupt i is PLIC source i+1 (LitexSystem/cpu/mmrisc/core.py):
    // uart 0, timer0 1, ethmac 2 (not modelled), sdcard 3
    assign ext_irq = {27'd0, sd_irq, 1'b0, timer_irq, uart_irq, 1'b0};

    //=================================================================
    // what happens
    //=================================================================
    `define CORE u_cpu_top.g_core.u_cpu_core
    int  cycle_count, max_cycles, n_retired, n_traps, n_uart_int;
    string bios_file, fw_file, image_file, initrd_file;
    int    pcmon;
    bit    linux_mode;
    int    utrace, n_user;
    bit    in_user;

    // claims per PLIC source
    `define PLIC u_cpu_top.u_mmio.u_plic
    int n_claim [0:31];
    initial for (int i = 0; i < 32; i++) n_claim[i] = 0;
    always @(posedge clk)
        if (rst_n && `PLIC.claim_now)
            n_claim[`PLIC.best_id[`PLIC.ctx_ctl]] <= n_claim[`PLIC.best_id[`PLIC.ctx_ctl]] + 1;

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count <= cycle_count + 1;
            if ((pcmon > 0) && (cycle_count % pcmon == 0))
            begin
                $display("\n@@PC %0d %016h retired %0d", cycle_count, `CORE.trace_pc, n_retired);
                // who is asking for interrupts, and how the SD card stands
                $display("@@IRQ ext=%b plic_irq=%b pend=%b gw_ready=%b claims u/t/eth/sd=%0d/%0d/%0d/%0d mip=%h",
                         ext_irq[4:1], `PLIC.irq,
                         {`PLIC.pending[4], `PLIC.pending[3], `PLIC.pending[2], `PLIC.pending[1]},
                         {`PLIC.gw_ready[4], `PLIC.gw_ready[3], `PLIC.gw_ready[2], `PLIC.gw_ready[1]},
                         n_claim[1], n_claim[2], n_claim[3], n_claim[4], `CORE.u_csr.mip_val);
                $display("@@SD card=%0d cmd_done=%b data_done=%b ev_en=%b rf=%0d b2m %0d/%0d en=%b m2b %0d/%0d en=%b dma=%0d uart_en=%b",
                         u_sd.c_state, u_sd.cmd_done, u_sd.data_done, u_sd.ev_enable,
                         u_sd.rf_cnt, u_sd.b2m_offset, u_sd.b2m_length, u_sd.b2m_enable,
                         u_sd.m2b_offset, u_sd.m2b_length, u_sd.m2b_enable,
                         u_cpu_top.u_dma.state, u_per.uart_ev_enable);
                $fflush;
            end
            if (`CORE.trace_valid) begin
                n_retired <= n_retired + 1;
                if ($test$plusargs("trace"))
                    $display("[%0d] %010h : %08h", cycle_count, `CORE.trace_pc, `CORE.trace_insn);
                if ((utrace > 0) && (`CORE.trace_priv == 2'd0)) begin
                    in_user = 1'b1;
                    if (n_user < utrace)
                        $display("\n@@U [%0d] %010h : %08h", cycle_count, `CORE.trace_pc, `CORE.trace_insn);
                    n_user = n_user + 1;
                end
            end
            if (`CORE.trap_valid) begin
                n_traps <= n_traps + 1;
                if (`CORE.trap_is_int && (`CORE.trap_cause == 5'd11))
                    n_uart_int <= n_uart_int + 1;
                if ($test$plusargs("traps") || in_user)
                    $display("\n[%0d] TRAP int=%0b cause=%0d epc=%010h tval=%010h  uart_irq=%b meip=%b",
                             cycle_count, `CORE.trap_is_int, `CORE.trap_cause,
                             `CORE.trap_epc, `CORE.trap_tval, uart_irq,
                             u_cpu_top.irq_m_ext[0]);
            end
        end
    end

    // +dmalog : every request of the DMA port into the data cache, with the
    // address stage 1 of the cache works with, and every answer
    `define DC u_cpu_top.u_cpu_cache.u_dcache
    always @(posedge clk) begin
        if (rst_n && dmalog) begin
            if (u_cpu_top.u_dma.dc_req_valid && u_cpu_top.u_dma.dc_req_ready)
                $display("[%0d] DMA req  cmd=%0d addr=%010h size=%0d wdata=%016h",
                         cycle_count, u_cpu_top.u_dma.dc_req_cmd, u_cpu_top.u_dma.dc_req_addr,
                         u_cpu_top.u_dma.dc_req_size, u_cpu_top.u_dma.dc_req_wdata);
            if (u_cpu_top.u_dma.dc_resp_valid)
                $display("[%0d] DMA resp err=%b data=%016h",
                         cycle_count, u_cpu_top.u_dma.dc_resp_error, u_cpu_top.u_dma.dc_resp_data);
            if (`DC.d_req_valid && `DC.d_req_ready && (u_cpu_top.u_dma.state != 0))
                $display("[%0d] D$  req  cmd=%0d addr=%010h", cycle_count, `DC.d_req_cmd, `DC.d_req_addr);
        end
    end
    bit dmalog;
    initial dmalog = $test$plusargs("dmalog");

    initial begin
        #1;
        if (!$value$plusargs("bios=%s", bios_file)) bios_file = "bios.hex";
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 3000000;
        if (!$value$plusargs("pcmon=%d", pcmon)) pcmon = 0;
        if (!$value$plusargs("utrace=%d", utrace)) utrace = 0;
        in_user = 1'b0;
        n_user  = 0;
        linux_mode = $test$plusargs("linux");
        for (int i = 0; i < MEM_WORDS; i++) u_mem.mem[i] = 64'd0;
        for (int i = 0; i < 128 * 1024 / 8; i++) u_per.rom[i] = 64'd0;
        if (!linux_mode) begin
            $readmemh(bios_file, u_per.rom);
        end else begin
            if (!$value$plusargs("fw=%s", fw_file))       fw_file    = "fw_jump.hex";
            if (!$value$plusargs("image=%s", image_file)) image_file = "Image.hex";
            // addi t0,x0,1 ; slli t0,t0,31 ; addi a0,x0,0 ; addi a1,x0,0 ;
            // jalr x0,0(t0) ; nop
            u_per.rom[0] = 64'h01f29293_00100293;
            u_per.rom[1] = 64'h00000593_00000513;
            u_per.rom[2] = 64'h00000013_00028067;
            $readmemh(fw_file, u_mem.mem, 0);
            $readmemh(image_file, u_mem.mem, 32'h20_0000 / 8);
            if ($value$plusargs("initrd=%s", initrd_file))
                $readmemh(initrd_file, u_mem.mem, 32'h200_0000 / 8);
        end
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
        if (linux_mode) begin
            while ((cycle_count < max_cycles) &&
                   (u_per.tx_tail[8*12-1:0] != "Kernel panic") &&
                   (u_sd.present || (u_per.tx_tail[8*23-1:0] != "Waiting for root device")) &&
                   (u_per.tx_tail[8*20-1:0] != "VFS: Unable to mount") &&
                   (u_per.tx_tail[8*3-1:0]  != "\n# "))
                @(posedge clk);
            repeat (20000) @(posedge clk);     // the rest of the line
        end else begin
            while ((cycle_count < max_cycles) &&
                   (u_per.tx_tail[8*18-1:0] != "Initializing SDRAM"))
                @(posedge clk);
        end
        $display("");
        $display("==========================================================");
        if (linux_mode && (u_per.tx_tail[8*3-1:0] == "\n# "))
            $display(" LINUX RUN ENDED : the shell prompt");
        else if (linux_mode)
            $display(" LINUX RUN ENDED");
        else if ((u_per.tx_tail[8*18-1:0] == "Initializing SDRAM") && (n_uart_int > 0))
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
