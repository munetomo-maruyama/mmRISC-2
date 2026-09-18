//---------------------------------------------------------------------------
// TOP.sv
//
// mmRISC-2 FPGA top for Digilent Arty A7-100T (debug logic bring-up)
//
//   CPU_TOP ─ AXI4  (40bit) ─ AXI4_ADDR_NARROW ─ AXI4_RAM   64KiB @ 0x8000_0000
//           ─ AXI-L (40bit) ─ AXIL_ADDR_NARROW ─ AXIL_RAM    4KiB @ 0x1200_0000
//   JTAG / cJTAG on PMOD JA, OpenOCD accesses the RAMs through the debug
//   module (System Bus Access / Access Memory).
//
//   Clock : 100MHz (E3) -> MMCM -> sys_clk (SYS_CLK_MHZ, default 50MHz)
//   Reset : rst_dbg_n = power-on reset only (debug module)
//           rst_n     = power-on | RESET button | nSRST (PMOD JA8)
//           ndmreset from the debugger additionally resets the bus side
//
//   Switches : SW3 (A10) down=JTAG / up=cJTAG
//              SW2 (C10) down=authentication off / up=on (key AUTH_KEY)
//   LEDs     : LD4 halted, LD5 running, LD6 dmactive,
//              LD7 cJTAG online (cJTAG mode) / heartbeat (JTAG mode)
//
//   SIM=1 bypasses the MMCM (sys_clk = clk100 input) for simulation.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module TOP
    #(
        parameter int          SIM          = 0,
        parameter int          USE_BFM      = 0,       // simulation only
        parameter int          SYS_CLK_MHZ  = 50,       // 100 / 50 / 25 (MMCM)
        parameter logic [31:0] AUTH_KEY     = 32'hbeefcafe,
        parameter int          MEM_WORDS    = 8192,     // 64KiB
        parameter int          PERI_WORDS   = 512,      // 4KiB
        parameter int          SBA_TIMEOUT  = 1 << 20,
        parameter int          POR_BITS     = 16        // POR length 2^(POR_BITS-1) cycles
    )
    (
        input  logic       CLK100MHZ,     // E3
        input  logic       CPU_RESETN,    // C2 (RESET button, active low)
        input  logic       SW2,           // C10 : authentication enable
        input  logic       SW3,           // A10 : cJTAG enable
        output logic [7:4] LED,           // LD7 T10, LD6 T9, LD5 J5, LD4 H5

        input  logic       JA_TCK,        // JA1 G13 : TCK / TCKC
        input  logic       JA_TDI,        // JA2 B11 : TDI
        output wire        JA_TDO,        // JA3 A11 : TDO (tri-state output)
        inout  wire        JA_TMS,        // JA4 D12 : TMS / TMSC (bidirectional)
        input  logic       JA_TRSTN,      // JA7 D13 : nTRST
        input  logic       JA_SRSTN       // JA8 B18 : nSRST
    );

    //=================================================================
    // Clock
    //=================================================================
    logic sys_clk;
    logic locked;

    generate
        if (SIM != 0) begin : g_clk_sim
            assign sys_clk = CLK100MHZ;
            assign locked  = 1'b1;
        end else begin : g_clk_mmcm
            logic clk_fb, clk_out;
            // VCO = 100MHz * 10 = 1000MHz
            MMCME2_BASE
                #(
                    .CLKIN1_PERIOD    (10.0),
                    .DIVCLK_DIVIDE    (1),
                    .CLKFBOUT_MULT_F  (10.0),
                    .CLKOUT0_DIVIDE_F (1000.0 / SYS_CLK_MHZ)
                )
            u_mmcm
                (
                    .CLKIN1   (CLK100MHZ),
                    .CLKFBIN  (clk_fb),
                    .CLKFBOUT (clk_fb),
                    .CLKFBOUTB(),
                    .CLKOUT0  (clk_out),
                    .CLKOUT0B (),
                    .CLKOUT1  (), .CLKOUT1B (),
                    .CLKOUT2  (), .CLKOUT2B (),
                    .CLKOUT3  (), .CLKOUT3B (),
                    .CLKOUT4  (), .CLKOUT5  (), .CLKOUT6 (),
                    .LOCKED   (locked),
                    .PWRDWN   (1'b0),
                    .RST      (1'b0)
                );
            BUFG u_bufg (.I(clk_out), .O(sys_clk));
        end
    endgenerate

    //=================================================================
    // Resets
    //=================================================================
    // power-on reset : counts after MMCM lock (FPGA registers start at 0)
    logic [POR_BITS-1:0] por_cnt = '0;
    logic                por_done;
    assign por_done = por_cnt[POR_BITS-1];

    always_ff @(posedge sys_clk) begin
        if (!locked)
            por_cnt <= '0;
        else if (!por_done)
            por_cnt <= por_cnt + 1'b1;
    end

    logic rst_dbg_n;
    logic rst_n;
    logic rst_bus_n;
    logic ndmreset;

    assign rst_dbg_n = por_done;

    DBG_RST_SYNC u_rst_sys
        (.clk(sys_clk), .rst_in_n(por_done & CPU_RESETN & JA_SRSTN), .rst_out_n(rst_n));
    DBG_RST_SYNC u_rst_bus
        (.clk(sys_clk), .rst_in_n(rst_n & ~ndmreset), .rst_out_n(rst_bus_n));

    //=================================================================
    // Buses
    //=================================================================
    logic [3:0]    cpu_axi4_awid;
    logic [39:0]   cpu_axi4_awaddr;
    logic [7:0]    cpu_axi4_awlen;
    logic [2:0]    cpu_axi4_awsize;
    logic [1:0]    cpu_axi4_awburst;
    logic          cpu_axi4_awlock;
    logic [3:0]    cpu_axi4_awcache;
    logic [2:0]    cpu_axi4_awprot;
    logic [3:0]    cpu_axi4_awqos;
    logic          cpu_axi4_awvalid;
    logic          cpu_axi4_awready;
    logic [63:0]   cpu_axi4_wdata;
    logic [7:0]    cpu_axi4_wstrb;
    logic          cpu_axi4_wlast;
    logic          cpu_axi4_wvalid;
    logic          cpu_axi4_wready;
    logic [3:0]    cpu_axi4_bid;
    logic [1:0]    cpu_axi4_bresp;
    logic          cpu_axi4_bvalid;
    logic          cpu_axi4_bready;
    logic [3:0]    cpu_axi4_arid;
    logic [39:0]   cpu_axi4_araddr;
    logic [7:0]    cpu_axi4_arlen;
    logic [2:0]    cpu_axi4_arsize;
    logic [1:0]    cpu_axi4_arburst;
    logic          cpu_axi4_arlock;
    logic [3:0]    cpu_axi4_arcache;
    logic [2:0]    cpu_axi4_arprot;
    logic [3:0]    cpu_axi4_arqos;
    logic          cpu_axi4_arvalid;
    logic          cpu_axi4_arready;
    logic [3:0]    cpu_axi4_rid;
    logic [63:0]   cpu_axi4_rdata;
    logic [1:0]    cpu_axi4_rresp;
    logic          cpu_axi4_rlast;
    logic          cpu_axi4_rvalid;
    logic          cpu_axi4_rready;

    logic [39:0]   cpu_axil_awaddr;
    logic [2:0]    cpu_axil_awprot;
    logic          cpu_axil_awvalid;
    logic          cpu_axil_awready;
    logic [63:0]   cpu_axil_wdata;
    logic [7:0]    cpu_axil_wstrb;
    logic          cpu_axil_wvalid;
    logic          cpu_axil_wready;
    logic [1:0]    cpu_axil_bresp;
    logic          cpu_axil_bvalid;
    logic          cpu_axil_bready;
    logic [39:0]   cpu_axil_araddr;
    logic [2:0]    cpu_axil_arprot;
    logic          cpu_axil_arvalid;
    logic          cpu_axil_arready;
    logic [63:0]   cpu_axil_rdata;
    logic [1:0]    cpu_axil_rresp;
    logic          cpu_axil_rvalid;
    logic          cpu_axil_rready;

    wire  [3:0]    ram_axi4_awid;
    wire  [31:0]   ram_axi4_awaddr;
    wire  [7:0]    ram_axi4_awlen;
    wire  [2:0]    ram_axi4_awsize;
    wire  [1:0]    ram_axi4_awburst;
    wire           ram_axi4_awlock;
    wire  [3:0]    ram_axi4_awcache;
    wire  [2:0]    ram_axi4_awprot;
    wire  [3:0]    ram_axi4_awqos;
    wire           ram_axi4_awvalid;
    wire           ram_axi4_awready;
    wire  [63:0]   ram_axi4_wdata;
    wire  [7:0]    ram_axi4_wstrb;
    wire           ram_axi4_wlast;
    wire           ram_axi4_wvalid;
    wire           ram_axi4_wready;
    wire  [3:0]    ram_axi4_bid;
    wire  [1:0]    ram_axi4_bresp;
    wire           ram_axi4_bvalid;
    wire           ram_axi4_bready;
    wire  [3:0]    ram_axi4_arid;
    wire  [31:0]   ram_axi4_araddr;
    wire  [7:0]    ram_axi4_arlen;
    wire  [2:0]    ram_axi4_arsize;
    wire  [1:0]    ram_axi4_arburst;
    wire           ram_axi4_arlock;
    wire  [3:0]    ram_axi4_arcache;
    wire  [2:0]    ram_axi4_arprot;
    wire  [3:0]    ram_axi4_arqos;
    wire           ram_axi4_arvalid;
    wire           ram_axi4_arready;
    wire  [3:0]    ram_axi4_rid;
    wire  [63:0]   ram_axi4_rdata;
    wire  [1:0]    ram_axi4_rresp;
    wire           ram_axi4_rlast;
    wire           ram_axi4_rvalid;
    wire           ram_axi4_rready;

    wire  [31:0]   ram_axil_awaddr;
    wire  [2:0]    ram_axil_awprot;
    wire           ram_axil_awvalid;
    wire           ram_axil_awready;
    wire  [63:0]   ram_axil_wdata;
    wire  [7:0]    ram_axil_wstrb;
    wire           ram_axil_wvalid;
    wire           ram_axil_wready;
    wire  [1:0]    ram_axil_bresp;
    wire           ram_axil_bvalid;
    wire           ram_axil_bready;
    wire  [31:0]   ram_axil_araddr;
    wire  [2:0]    ram_axil_arprot;
    wire           ram_axil_arvalid;
    wire           ram_axil_arready;
    wire  [63:0]   ram_axil_rdata;
    wire  [1:0]    ram_axil_rresp;
    wire           ram_axil_rvalid;
    wire           ram_axil_rready;

    //=================================================================
    // CPU
    //=================================================================
    logic jtag_tms_o, jtag_tms_oe, jtag_tdo, jtag_tdo_oe;
    logic cjtag_online, dbg_halted, dbg_running, dbg_dmactive;

    CPU_TOP
        #(
            .SBA_TIMEOUT (SBA_TIMEOUT),
            .USE_BFM     (USE_BFM)
        )
    u_cpu_top
        (
            .clk          (sys_clk),
            .rst_n        (rst_n),
            .rst_dbg_n    (rst_dbg_n),
            .ndmreset     (ndmreset),
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
            .m_axil_rready   (cpu_axil_rready),
            .ext_irq      ('0),
            .jtag_tck     (JA_TCK),
            .jtag_tms_i   (JA_TMS),
            .jtag_tms_o   (jtag_tms_o),
            .jtag_tms_oe  (jtag_tms_oe),
            .jtag_tdi     (JA_TDI),
            .jtag_tdo     (jtag_tdo),
            .jtag_tdo_oe  (jtag_tdo_oe),
            .jtag_trst_n  (JA_TRSTN),
            .cjtag_en     (SW3),
            .cjtag_online (cjtag_online),
            .dbg_auth_en  (SW2),
            .dbg_auth_key (AUTH_KEY),
            .dbg_halted   (dbg_halted),
            .dbg_running  (dbg_running),
            .dbg_dmactive (dbg_dmactive)
        );

    //=================================================================
    // Pads
    //=================================================================
    assign JA_TDO = jtag_tdo_oe ? jtag_tdo   : 1'bz;
    assign JA_TMS = jtag_tms_oe ? jtag_tms_o : 1'bz;

    //=================================================================
    // Memory bus : 40-bit -> 32-bit, RAM 64KiB @ 0x8000_0000
    //=================================================================
    AXI4_ADDR_NARROW
        #(
            .ID_WIDTH     (4),
            .S_ADDR_WIDTH (40),
            .M_ADDR_WIDTH (32),
            .DATA_WIDTH   (64)
        )
    u_narrow_axi4
        (
            .clk              (sys_clk),
            .rst_n            (rst_bus_n),
            .s_awid          (cpu_axi4_awid),
            .s_awaddr        (cpu_axi4_awaddr),
            .s_awlen         (cpu_axi4_awlen),
            .s_awsize        (cpu_axi4_awsize),
            .s_awburst       (cpu_axi4_awburst),
            .s_awlock        (cpu_axi4_awlock),
            .s_awcache       (cpu_axi4_awcache),
            .s_awprot        (cpu_axi4_awprot),
            .s_awqos         (cpu_axi4_awqos),
            .s_awvalid       (cpu_axi4_awvalid),
            .s_awready       (cpu_axi4_awready),
            .s_wdata         (cpu_axi4_wdata),
            .s_wstrb         (cpu_axi4_wstrb),
            .s_wlast         (cpu_axi4_wlast),
            .s_wvalid        (cpu_axi4_wvalid),
            .s_wready        (cpu_axi4_wready),
            .s_bid           (cpu_axi4_bid),
            .s_bresp         (cpu_axi4_bresp),
            .s_bvalid        (cpu_axi4_bvalid),
            .s_bready        (cpu_axi4_bready),
            .s_arid          (cpu_axi4_arid),
            .s_araddr        (cpu_axi4_araddr),
            .s_arlen         (cpu_axi4_arlen),
            .s_arsize        (cpu_axi4_arsize),
            .s_arburst       (cpu_axi4_arburst),
            .s_arlock        (cpu_axi4_arlock),
            .s_arcache       (cpu_axi4_arcache),
            .s_arprot        (cpu_axi4_arprot),
            .s_arqos         (cpu_axi4_arqos),
            .s_arvalid       (cpu_axi4_arvalid),
            .s_arready       (cpu_axi4_arready),
            .s_rid           (cpu_axi4_rid),
            .s_rdata         (cpu_axi4_rdata),
            .s_rresp         (cpu_axi4_rresp),
            .s_rlast         (cpu_axi4_rlast),
            .s_rvalid        (cpu_axi4_rvalid),
            .s_rready        (cpu_axi4_rready),
            .m_awid          (ram_axi4_awid),
            .m_awaddr        (ram_axi4_awaddr),
            .m_awlen         (ram_axi4_awlen),
            .m_awsize        (ram_axi4_awsize),
            .m_awburst       (ram_axi4_awburst),
            .m_awlock        (ram_axi4_awlock),
            .m_awcache       (ram_axi4_awcache),
            .m_awprot        (ram_axi4_awprot),
            .m_awqos         (ram_axi4_awqos),
            .m_awvalid       (ram_axi4_awvalid),
            .m_awready       (ram_axi4_awready),
            .m_wdata         (ram_axi4_wdata),
            .m_wstrb         (ram_axi4_wstrb),
            .m_wlast         (ram_axi4_wlast),
            .m_wvalid        (ram_axi4_wvalid),
            .m_wready        (ram_axi4_wready),
            .m_bid           (ram_axi4_bid),
            .m_bresp         (ram_axi4_bresp),
            .m_bvalid        (ram_axi4_bvalid),
            .m_bready        (ram_axi4_bready),
            .m_arid          (ram_axi4_arid),
            .m_araddr        (ram_axi4_araddr),
            .m_arlen         (ram_axi4_arlen),
            .m_arsize        (ram_axi4_arsize),
            .m_arburst       (ram_axi4_arburst),
            .m_arlock        (ram_axi4_arlock),
            .m_arcache       (ram_axi4_arcache),
            .m_arprot        (ram_axi4_arprot),
            .m_arqos         (ram_axi4_arqos),
            .m_arvalid       (ram_axi4_arvalid),
            .m_arready       (ram_axi4_arready),
            .m_rid           (ram_axi4_rid),
            .m_rdata         (ram_axi4_rdata),
            .m_rresp         (ram_axi4_rresp),
            .m_rlast         (ram_axi4_rlast),
            .m_rvalid        (ram_axi4_rvalid),
            .m_rready        (ram_axi4_rready)
        );

    AXI4_RAM
        #(
            .ID_WIDTH   (4),
            .ADDR_WIDTH (32),
            .DEPTH      (MEM_WORDS),
            .BASE_ADDR  (32'h8000_0000)
        )
    u_ram_axi4
        (
            .clk              (sys_clk),
            .rst_n            (rst_bus_n),
            .awid            (ram_axi4_awid),
            .awaddr          (ram_axi4_awaddr),
            .awlen           (ram_axi4_awlen),
            .awsize          (ram_axi4_awsize),
            .awburst         (ram_axi4_awburst),
            .awlock          (ram_axi4_awlock),
            .awcache         (ram_axi4_awcache),
            .awprot          (ram_axi4_awprot),
            .awqos           (ram_axi4_awqos),
            .awvalid         (ram_axi4_awvalid),
            .awready         (ram_axi4_awready),
            .wdata           (ram_axi4_wdata),
            .wstrb           (ram_axi4_wstrb),
            .wlast           (ram_axi4_wlast),
            .wvalid          (ram_axi4_wvalid),
            .wready          (ram_axi4_wready),
            .bid             (ram_axi4_bid),
            .bresp           (ram_axi4_bresp),
            .bvalid          (ram_axi4_bvalid),
            .bready          (ram_axi4_bready),
            .arid            (ram_axi4_arid),
            .araddr          (ram_axi4_araddr),
            .arlen           (ram_axi4_arlen),
            .arsize          (ram_axi4_arsize),
            .arburst         (ram_axi4_arburst),
            .arlock          (ram_axi4_arlock),
            .arcache         (ram_axi4_arcache),
            .arprot          (ram_axi4_arprot),
            .arqos           (ram_axi4_arqos),
            .arvalid         (ram_axi4_arvalid),
            .arready         (ram_axi4_arready),
            .rid             (ram_axi4_rid),
            .rdata           (ram_axi4_rdata),
            .rresp           (ram_axi4_rresp),
            .rlast           (ram_axi4_rlast),
            .rvalid          (ram_axi4_rvalid),
            .rready          (ram_axi4_rready)
        );

    //=================================================================
    // Peripheral bus : 40-bit -> 32-bit, RAM 4KiB @ 0x1200_0000
    //=================================================================
    AXIL_ADDR_NARROW
        #(
            .S_ADDR_WIDTH (40),
            .M_ADDR_WIDTH (32),
            .DATA_WIDTH   (64)
        )
    u_narrow_axil
        (
            .clk              (sys_clk),
            .rst_n            (rst_bus_n),
            .s_awaddr        (cpu_axil_awaddr),
            .s_awprot        (cpu_axil_awprot),
            .s_awvalid       (cpu_axil_awvalid),
            .s_awready       (cpu_axil_awready),
            .s_wdata         (cpu_axil_wdata),
            .s_wstrb         (cpu_axil_wstrb),
            .s_wvalid        (cpu_axil_wvalid),
            .s_wready        (cpu_axil_wready),
            .s_bresp         (cpu_axil_bresp),
            .s_bvalid        (cpu_axil_bvalid),
            .s_bready        (cpu_axil_bready),
            .s_araddr        (cpu_axil_araddr),
            .s_arprot        (cpu_axil_arprot),
            .s_arvalid       (cpu_axil_arvalid),
            .s_arready       (cpu_axil_arready),
            .s_rdata         (cpu_axil_rdata),
            .s_rresp         (cpu_axil_rresp),
            .s_rvalid        (cpu_axil_rvalid),
            .s_rready        (cpu_axil_rready),
            .m_awaddr        (ram_axil_awaddr),
            .m_awprot        (ram_axil_awprot),
            .m_awvalid       (ram_axil_awvalid),
            .m_awready       (ram_axil_awready),
            .m_wdata         (ram_axil_wdata),
            .m_wstrb         (ram_axil_wstrb),
            .m_wvalid        (ram_axil_wvalid),
            .m_wready        (ram_axil_wready),
            .m_bresp         (ram_axil_bresp),
            .m_bvalid        (ram_axil_bvalid),
            .m_bready        (ram_axil_bready),
            .m_araddr        (ram_axil_araddr),
            .m_arprot        (ram_axil_arprot),
            .m_arvalid       (ram_axil_arvalid),
            .m_arready       (ram_axil_arready),
            .m_rdata         (ram_axil_rdata),
            .m_rresp         (ram_axil_rresp),
            .m_rvalid        (ram_axil_rvalid),
            .m_rready        (ram_axil_rready)
        );

    AXIL_RAM
        #(
            .ADDR_WIDTH (32),
            .DEPTH      (PERI_WORDS),
            .BASE_ADDR  (32'h1200_0000)
        )
    u_ram_axil
        (
            .clk              (sys_clk),
            .rst_n            (rst_bus_n),
            .awaddr          (ram_axil_awaddr),
            .awprot          (ram_axil_awprot),
            .awvalid         (ram_axil_awvalid),
            .awready         (ram_axil_awready),
            .wdata           (ram_axil_wdata),
            .wstrb           (ram_axil_wstrb),
            .wvalid          (ram_axil_wvalid),
            .wready          (ram_axil_wready),
            .bresp           (ram_axil_bresp),
            .bvalid          (ram_axil_bvalid),
            .bready          (ram_axil_bready),
            .araddr          (ram_axil_araddr),
            .arprot          (ram_axil_arprot),
            .arvalid         (ram_axil_arvalid),
            .arready         (ram_axil_arready),
            .rdata           (ram_axil_rdata),
            .rresp           (ram_axil_rresp),
            .rvalid          (ram_axil_rvalid),
            .rready          (ram_axil_rready)
        );

    //=================================================================
    // LEDs
    //=================================================================
    logic [24:0] hb_cnt = '0;
    always_ff @(posedge sys_clk) hb_cnt <= hb_cnt + 1'b1;

    assign LED[4] = dbg_halted;
    assign LED[5] = dbg_running;
    assign LED[6] = dbg_dmactive;
    assign LED[7] = SW3 ? cjtag_online : hb_cnt[24];

endmodule : TOP
