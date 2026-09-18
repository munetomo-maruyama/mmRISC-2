//---------------------------------------------------------------------------
// CPU_BFM.sv
//
// mmRISC-2 : Temporary Bus Function Model (BFM) placed inside CPU_TOP.
//
// This module provisionally replaces the real CPU logic (pipeline / MMU /
// cache / CLINT / PLIC). It issues AXI4 (memory bus) and AXI4-Lite
// (peripheral bus) transactions on request, so that the bus interfaces of
// CPU_TOP can be verified before the CPU core itself exists.
//
// The command interface below is NOT a set of module ports: it is a group of
// variables driven from the testbench through hierarchical references (XMR),
// e.g.  tb_CPU_TOP.u_cpu_top.u_cpu_bfm.cmd_addr = 40'h00_8000_0000;
// This keeps the port list of CPU_TOP clean (no simulation-only ports).
//
// Command handshake (4-phase):
//   1. TB sets cmd_we / cmd_bus / cmd_addr / cmd_len / cmd_wdata
//      (or cmd_wbuf[] with cmd_wbuf_en=1 for per-beat AXI4 data)
//      and cmd_size / cmd_wstrb for narrow accesses, then cmd_valid=1
//   2. BFM runs the transaction, then raises cmd_done=1
//   3. TB reads cmd_rdata / cmd_rbuf[] / cmd_resp, then clears cmd_valid=0
//   4. BFM clears cmd_done=0 and returns to idle
//
// NOTE: This file is temporary and will be removed once the real CPU core
//       is implemented.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_BFM
    #(
        parameter int AXI4_ID_WIDTH     = 4,
        parameter int AXI4_ADDR_WIDTH   = 40,
        parameter int AXI4_DATA_WIDTH   = 64,
        parameter int AXIL_ADDR_WIDTH   = 40,
        parameter int AXIL_DATA_WIDTH   = 64
    )
    (
        input  logic                         clk,
        input  logic                         rst_n,

        //-------------------------------------------------------------
        // Memory Bus : AXI4 Master
        //-------------------------------------------------------------
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

        //-------------------------------------------------------------
        // Peripheral Bus : AXI4-Lite Master
        //-------------------------------------------------------------
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

    //-----------------------------------------------------------------
    // Local Parameters
    //-----------------------------------------------------------------
    localparam int AXI4_BYTES     = AXI4_DATA_WIDTH / 8;
    localparam int AXI4_SIZE_CODE = $clog2(AXI4_BYTES);  // 64bit -> 3
    localparam int AXIL_BYTES     = AXIL_DATA_WIDTH / 8;

    localparam logic [1:0] BURST_INCR = 2'b01;
    localparam logic [1:0] RESP_OKAY  = 2'b00;

    localparam logic BUS_MEM    = 1'b0;  // AXI4      (memory bus)
    localparam logic BUS_PERIPH = 1'b1;  // AXI4-Lite (peripheral bus)

    localparam int MAX_BEATS = 256;      // AXI4 maximum burst length

    //-----------------------------------------------------------------
    // Command Interface (driven from the testbench via XMR)
    //-----------------------------------------------------------------
    logic                        cmd_valid;   // TB  -> BFM : request
    logic                        cmd_we;      // TB  -> BFM : 1=write, 0=read
    logic                        cmd_bus;     // TB  -> BFM : BUS_MEM / BUS_PERIPH
    logic [AXI4_ADDR_WIDTH-1:0]  cmd_addr;    // TB  -> BFM : start address
    logic [7:0]                  cmd_len;     // TB  -> BFM : burst beats-1 (AXI4 only)
    logic [AXI4_DATA_WIDTH-1:0]  cmd_wdata;   // TB  -> BFM : 1st beat write data
    logic                        cmd_wbuf_en; // TB  -> BFM : 1=take AXI4 beats from cmd_wbuf[]
                                              //              0=cmd_wdata, +1 per beat
    logic [AXI4_DATA_WIDTH-1:0]  cmd_wbuf [0:MAX_BEATS-1]; // TB -> BFM : per-beat write data
    logic [2:0]                  cmd_size;    // TB  -> BFM : AXI4 AxSIZE (0:8bit 1:16bit 2:32bit 3:64bit)
    logic [AXI4_BYTES-1:0]       cmd_wstrb;   // TB  -> BFM : WSTRB used when AxSIZE is the full
                                              //              bus width (AXI4) / always (AXI4-Lite)

    logic                        cmd_done;    // BFM -> TB  : transaction finished
    logic [AXI4_DATA_WIDTH-1:0]  cmd_rdata;   // BFM -> TB  : last read beat
    logic [1:0]                  cmd_resp;    // BFM -> TB  : BRESP / RRESP
    logic [AXI4_DATA_WIDTH-1:0]  cmd_rbuf [0:MAX_BEATS-1]; // BFM -> TB : all read beats

    // Time-0 initialisation of the TB-driven variables. The testbench is the
    // only writer afterwards, so there is no multiple-driver conflict.
    initial begin
        cmd_valid = 1'b0;
        cmd_we    = 1'b0;
        cmd_bus   = BUS_MEM;
        cmd_addr  = '0;
        cmd_len     = 8'd0;
        cmd_wdata   = '0;
        cmd_wbuf_en = 1'b0;
        cmd_size    = AXI4_SIZE_CODE[2:0];
        cmd_wstrb   = {AXI4_BYTES{1'b1}};
    end

    //-----------------------------------------------------------------
    // Narrow (AxSIZE < bus width) transfer helpers
    //-----------------------------------------------------------------
    // WSTRB of a beat. For a narrow transfer it covers the lanes from the
    // beat address up to the next (1 << size) boundary, as a real master
    // does. For a full-width transfer the testbench-given strobe is used.
    function automatic logic [AXI4_BYTES-1:0] beat_strb
        (input logic [2:0] size, input logic [AXI4_ADDR_WIDTH-1:0] a,
         input logic [AXI4_BYTES-1:0] user);
        int nbytes;
        int off;
        int base;
        logic [AXI4_BYTES-1:0] m;
        if (int'(size) >= AXI4_SIZE_CODE) begin
            beat_strb = user;
        end
        else begin
            nbytes = 1 << size;
            off    = int'(a[AXI4_SIZE_CODE-1:0]);
            base   = off - (off % nbytes);
            m      = '0;
            for (int b = 0; b < AXI4_BYTES; b++) begin
                if ((b >= off) && (b < base + nbytes)) m[b] = 1'b1;
            end
            beat_strb = m;
        end
    endfunction

    // Address of the next beat of an INCR burst (aligned to the size)
    function automatic logic [AXI4_ADDR_WIDTH-1:0] next_addr
        (input logic [AXI4_ADDR_WIDTH-1:0] a, input logic [2:0] size);
        logic [AXI4_ADDR_WIDTH-1:0] nb;
        nb        = AXI4_ADDR_WIDTH'(1) << size;
        next_addr = (a & ~(nb - 1'b1)) + nb;
    endfunction

    //-----------------------------------------------------------------
    // FSM
    //-----------------------------------------------------------------
    localparam logic [3:0] S_IDLE  = 4'd0;
    localparam logic [3:0] S4_WA   = 4'd1;   // AXI4      write address
    localparam logic [3:0] S4_WD   = 4'd2;   // AXI4      write data
    localparam logic [3:0] S4_WB   = 4'd3;   // AXI4      write response
    localparam logic [3:0] S4_RA   = 4'd4;   // AXI4      read address
    localparam logic [3:0] S4_RD   = 4'd5;   // AXI4      read data
    localparam logic [3:0] SL_WAW  = 4'd6;   // AXI4-Lite write address/data
    localparam logic [3:0] SL_WB   = 4'd7;   // AXI4-Lite write response
    localparam logic [3:0] SL_RA   = 4'd8;   // AXI4-Lite read address
    localparam logic [3:0] SL_RD   = 4'd9;   // AXI4-Lite read data
    localparam logic [3:0] S_ACK   = 4'd10;  // wait for TB to release cmd_valid

    logic [3:0] state;
    logic [8:0] beat;                        // 0..256
    logic [7:0] len_r;                       // burst length latched at start
    logic [7:0] beat_nx;                     // index of the next write beat
    logic [2:0]                 size_r;      // AxSIZE latched at start
    logic [AXI4_BYTES-1:0]      ustrb_r;     // user WSTRB latched at start
    logic [AXI4_ADDR_WIDTH-1:0] wa;          // address of the current write beat

    assign beat_nx = beat[7:0] + 8'd1;

    // AXI4-Lite write channel completion flags
    logic axil_aw_sent;
    logic axil_w_sent;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            beat           <= 9'd0;
            len_r          <= 8'd0;
            size_r         <= AXI4_SIZE_CODE[2:0];
            ustrb_r        <= '0;
            wa             <= '0;
            cmd_done       <= 1'b0;
            cmd_rdata      <= '0;
            cmd_resp       <= RESP_OKAY;

            m_axi4_awid    <= '0;
            m_axi4_awaddr  <= '0;
            m_axi4_awlen   <= 8'd0;
            m_axi4_awsize  <= AXI4_SIZE_CODE[2:0];
            m_axi4_awburst <= BURST_INCR;
            m_axi4_awlock  <= 1'b0;
            m_axi4_awcache <= 4'b0011;
            m_axi4_awprot  <= 3'b000;
            m_axi4_awqos   <= 4'b0000;
            m_axi4_awvalid <= 1'b0;

            m_axi4_wdata   <= '0;
            m_axi4_wstrb   <= '0;
            m_axi4_wlast   <= 1'b0;
            m_axi4_wvalid  <= 1'b0;
            m_axi4_bready  <= 1'b0;

            m_axi4_arid    <= '0;
            m_axi4_araddr  <= '0;
            m_axi4_arlen   <= 8'd0;
            m_axi4_arsize  <= AXI4_SIZE_CODE[2:0];
            m_axi4_arburst <= BURST_INCR;
            m_axi4_arlock  <= 1'b0;
            m_axi4_arcache <= 4'b0011;
            m_axi4_arprot  <= 3'b000;
            m_axi4_arqos   <= 4'b0000;
            m_axi4_arvalid <= 1'b0;
            m_axi4_rready  <= 1'b0;

            m_axil_awaddr  <= '0;
            m_axil_awprot  <= 3'b000;
            m_axil_awvalid <= 1'b0;
            m_axil_wdata   <= '0;
            m_axil_wstrb   <= '0;
            m_axil_wvalid  <= 1'b0;
            m_axil_bready  <= 1'b0;
            m_axil_araddr  <= '0;
            m_axil_arprot  <= 3'b000;
            m_axil_arvalid <= 1'b0;
            m_axil_rready  <= 1'b0;

            axil_aw_sent   <= 1'b0;
            axil_w_sent    <= 1'b0;
        end
        else begin
            case (state)
                //-----------------------------------------------------
                S_IDLE: begin
                    beat <= 9'd0;
                    if (cmd_valid && !cmd_done) begin
                        len_r   <= cmd_len;
                        size_r  <= cmd_size;
                        ustrb_r <= cmd_wstrb;
                        wa      <= cmd_addr;
                        if (cmd_bus == BUS_MEM) begin
                            if (cmd_we) begin
                                // AXI4 burst write
                                m_axi4_awid    <= '0;
                                m_axi4_awaddr  <= cmd_addr;
                                m_axi4_awlen   <= cmd_len;
                                m_axi4_awsize  <= cmd_size;
                                m_axi4_awburst <= BURST_INCR;
                                m_axi4_awvalid <= 1'b1;
                                m_axi4_wdata   <= cmd_wbuf_en ? cmd_wbuf[0] : cmd_wdata;
                                m_axi4_wstrb   <= beat_strb(cmd_size, cmd_addr, cmd_wstrb);
                                m_axi4_wlast   <= (cmd_len == 8'd0);
                                state          <= S4_WA;
                            end
                            else begin
                                // AXI4 burst read
                                m_axi4_arid    <= '0;
                                m_axi4_araddr  <= cmd_addr;
                                m_axi4_arlen   <= cmd_len;
                                m_axi4_arsize  <= cmd_size;
                                m_axi4_arburst <= BURST_INCR;
                                m_axi4_arvalid <= 1'b1;
                                state          <= S4_RA;
                            end
                        end
                        else begin
                            if (cmd_we) begin
                                // AXI4-Lite single write
                                m_axil_awaddr  <= cmd_addr[AXIL_ADDR_WIDTH-1:0];
                                m_axil_awprot  <= 3'b000;
                                m_axil_awvalid <= 1'b1;
                                m_axil_wdata   <= cmd_wdata[AXIL_DATA_WIDTH-1:0];
                                m_axil_wstrb   <= cmd_wstrb[AXIL_BYTES-1:0];
                                m_axil_wvalid  <= 1'b1;
                                axil_aw_sent   <= 1'b0;
                                axil_w_sent    <= 1'b0;
                                state          <= SL_WAW;
                            end
                            else begin
                                // AXI4-Lite single read
                                m_axil_araddr  <= cmd_addr[AXIL_ADDR_WIDTH-1:0];
                                m_axil_arprot  <= 3'b000;
                                m_axil_arvalid <= 1'b1;
                                state          <= SL_RA;
                            end
                        end
                    end
                end

                //-----------------------------------------------------
                // AXI4 write
                //-----------------------------------------------------
                S4_WA: begin
                    if (m_axi4_awvalid && m_axi4_awready) begin
                        m_axi4_awvalid <= 1'b0;
                        m_axi4_wvalid  <= 1'b1;
                        state          <= S4_WD;
                    end
                end

                S4_WD: begin
                    if (m_axi4_wvalid && m_axi4_wready) begin
                        if (m_axi4_wlast) begin
                            m_axi4_wvalid <= 1'b0;
                            m_axi4_wlast  <= 1'b0;
                            m_axi4_bready <= 1'b1;
                            state         <= S4_WB;
                        end
                        else begin
                            beat         <= beat + 9'd1;
                            m_axi4_wdata <= cmd_wbuf_en ? cmd_wbuf[beat_nx]
                                                        : (m_axi4_wdata + 64'd1);
                            wa           <= next_addr(wa, size_r);
                            m_axi4_wstrb <= beat_strb(size_r, next_addr(wa, size_r), ustrb_r);
                            m_axi4_wlast <= ((beat + 9'd1) == {1'b0, len_r});
                        end
                    end
                end

                S4_WB: begin
                    if (m_axi4_bvalid && m_axi4_bready) begin
                        m_axi4_bready <= 1'b0;
                        cmd_resp      <= m_axi4_bresp;
                        cmd_done      <= 1'b1;
                        state         <= S_ACK;
                    end
                end

                //-----------------------------------------------------
                // AXI4 read
                //-----------------------------------------------------
                S4_RA: begin
                    if (m_axi4_arvalid && m_axi4_arready) begin
                        m_axi4_arvalid <= 1'b0;
                        m_axi4_rready  <= 1'b1;
                        state          <= S4_RD;
                    end
                end

                S4_RD: begin
                    if (m_axi4_rvalid && m_axi4_rready) begin
                        cmd_rbuf[beat[7:0]] <= m_axi4_rdata;
                        cmd_rdata           <= m_axi4_rdata;
                        cmd_resp            <= m_axi4_rresp;
                        beat                <= beat + 9'd1;
                        if (m_axi4_rlast) begin
                            m_axi4_rready <= 1'b0;
                            cmd_done      <= 1'b1;
                            state         <= S_ACK;
                        end
                    end
                end

                //-----------------------------------------------------
                // AXI4-Lite write
                //-----------------------------------------------------
                SL_WAW: begin
                    if (m_axil_awvalid && m_axil_awready) begin
                        m_axil_awvalid <= 1'b0;
                        axil_aw_sent   <= 1'b1;
                    end
                    if (m_axil_wvalid && m_axil_wready) begin
                        m_axil_wvalid <= 1'b0;
                        axil_w_sent   <= 1'b1;
                    end
                    if ((axil_aw_sent || (m_axil_awvalid && m_axil_awready)) &&
                        (axil_w_sent  || (m_axil_wvalid  && m_axil_wready ))) begin
                        m_axil_bready <= 1'b1;
                        state         <= SL_WB;
                    end
                end

                SL_WB: begin
                    if (m_axil_bvalid && m_axil_bready) begin
                        m_axil_bready <= 1'b0;
                        cmd_resp      <= m_axil_bresp;
                        cmd_done      <= 1'b1;
                        state         <= S_ACK;
                    end
                end

                //-----------------------------------------------------
                // AXI4-Lite read
                //-----------------------------------------------------
                SL_RA: begin
                    if (m_axil_arvalid && m_axil_arready) begin
                        m_axil_arvalid <= 1'b0;
                        m_axil_rready  <= 1'b1;
                        state          <= SL_RD;
                    end
                end

                SL_RD: begin
                    if (m_axil_rvalid && m_axil_rready) begin
                        m_axil_rready <= 1'b0;
                        cmd_rdata     <= {{(AXI4_DATA_WIDTH-AXIL_DATA_WIDTH){1'b0}}, m_axil_rdata};
                        cmd_rbuf[0]   <= {{(AXI4_DATA_WIDTH-AXIL_DATA_WIDTH){1'b0}}, m_axil_rdata};
                        cmd_resp      <= m_axil_rresp;
                        cmd_done      <= 1'b1;
                        state         <= S_ACK;
                    end
                end

                //-----------------------------------------------------
                S_ACK: begin
                    if (!cmd_valid) begin
                        cmd_done <= 1'b0;
                        state    <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
