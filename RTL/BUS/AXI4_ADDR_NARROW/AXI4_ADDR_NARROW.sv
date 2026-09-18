//---------------------------------------------------------------------------
// AXI4_ADDR_NARROW.sv
//
// AXI4 address narrowing bridge with DECERR on unmapped upper bits.
//
// Connects a master with a wide address (e.g. the 40-bit mmRISC-2 memory bus)
// to a slave with a narrow address (e.g. a 32-bit LiteX SoC).
//
//   - Upper address bits [S_ADDR_WIDTH-1:M_ADDR_WIDTH] all zero
//       -> the transaction is passed through to the M side,
//          with the address truncated to [M_ADDR_WIDTH-1:0].
//   - Any upper address bit non-zero
//       -> the transaction is NOT forwarded. The bridge itself terminates it:
//          write : all W beats are accepted and discarded, then BRESP=DECERR
//          read  : (ARLEN+1) R beats with RDATA=0, RRESP=DECERR, RLAST on the
//                  final beat
//     This prevents the aliasing that plain truncation would cause.
//
// Implementation notes:
//   - W is forwarded to the M side only while a valid AW whose address has
//     been decoded as in range is present (or after its handshake), so that
//     data of an erroneous write can never reach the M side. W is not held
//     until AWREADY, because an AXI master must not wait for AWREADY before
//     asserting WVALID (a slave may wait for both AWVALID and WVALID).
//   - One write and one read transaction are handled at a time (AWREADY /
//     ARREADY are held low until the current transaction completes). Read
//     and write paths are independent.
//   - VALID/READY and payload are combinational in the pass-through path
//     (no pipeline stage is added).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXI4_ADDR_NARROW
    #(
        parameter int ID_WIDTH     = 4,
        parameter int S_ADDR_WIDTH = 40,      // slave side  (from wide master)
        parameter int M_ADDR_WIDTH = 32,      // master side (to narrow slave)
        parameter int DATA_WIDTH   = 64
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        //-------------------------------------------------------------
        // Slave port : connect to the wide-address master
        //-------------------------------------------------------------
        input  logic [ID_WIDTH-1:0]     s_awid,
        input  logic [S_ADDR_WIDTH-1:0] s_awaddr,
        input  logic [7:0]              s_awlen,
        input  logic [2:0]              s_awsize,
        input  logic [1:0]              s_awburst,
        input  logic                    s_awlock,
        input  logic [3:0]              s_awcache,
        input  logic [2:0]              s_awprot,
        input  logic [3:0]              s_awqos,
        input  logic                    s_awvalid,
        output logic                    s_awready,

        input  logic [DATA_WIDTH-1:0]   s_wdata,
        input  logic [DATA_WIDTH/8-1:0] s_wstrb,
        input  logic                    s_wlast,
        input  logic                    s_wvalid,
        output logic                    s_wready,

        output logic [ID_WIDTH-1:0]     s_bid,
        output logic [1:0]              s_bresp,
        output logic                    s_bvalid,
        input  logic                    s_bready,

        input  logic [ID_WIDTH-1:0]     s_arid,
        input  logic [S_ADDR_WIDTH-1:0] s_araddr,
        input  logic [7:0]              s_arlen,
        input  logic [2:0]              s_arsize,
        input  logic [1:0]              s_arburst,
        input  logic                    s_arlock,
        input  logic [3:0]              s_arcache,
        input  logic [2:0]              s_arprot,
        input  logic [3:0]              s_arqos,
        input  logic                    s_arvalid,
        output logic                    s_arready,

        output logic [ID_WIDTH-1:0]     s_rid,
        output logic [DATA_WIDTH-1:0]   s_rdata,
        output logic [1:0]              s_rresp,
        output logic                    s_rlast,
        output logic                    s_rvalid,
        input  logic                    s_rready,

        //-------------------------------------------------------------
        // Master port : connect to the narrow-address slave
        //-------------------------------------------------------------
        output logic [ID_WIDTH-1:0]     m_awid,
        output logic [M_ADDR_WIDTH-1:0] m_awaddr,
        output logic [7:0]              m_awlen,
        output logic [2:0]              m_awsize,
        output logic [1:0]              m_awburst,
        output logic                    m_awlock,
        output logic [3:0]              m_awcache,
        output logic [2:0]              m_awprot,
        output logic [3:0]              m_awqos,
        output logic                    m_awvalid,
        input  logic                    m_awready,

        output logic [DATA_WIDTH-1:0]   m_wdata,
        output logic [DATA_WIDTH/8-1:0] m_wstrb,
        output logic                    m_wlast,
        output logic                    m_wvalid,
        input  logic                    m_wready,

        input  logic [ID_WIDTH-1:0]     m_bid,
        input  logic [1:0]              m_bresp,
        input  logic                    m_bvalid,
        output logic                    m_bready,

        output logic [ID_WIDTH-1:0]     m_arid,
        output logic [M_ADDR_WIDTH-1:0] m_araddr,
        output logic [7:0]              m_arlen,
        output logic [2:0]              m_arsize,
        output logic [1:0]              m_arburst,
        output logic                    m_arlock,
        output logic [3:0]              m_arcache,
        output logic [2:0]              m_arprot,
        output logic [3:0]              m_arqos,
        output logic                    m_arvalid,
        input  logic                    m_arready,

        input  logic [ID_WIDTH-1:0]     m_rid,
        input  logic [DATA_WIDTH-1:0]   m_rdata,
        input  logic [1:0]              m_rresp,
        input  logic                    m_rlast,
        input  logic                    m_rvalid,
        output logic                    m_rready
    );

    localparam logic [1:0] RESP_DECERR = 2'b11;

    // Upper address bits that do not exist on the narrow side
    wire aw_err = |s_awaddr[S_ADDR_WIDTH-1:M_ADDR_WIDTH];
    wire ar_err = |s_araddr[S_ADDR_WIDTH-1:M_ADDR_WIDTH];

    //-----------------------------------------------------------------
    // Payload pass-through
    //-----------------------------------------------------------------
    assign m_awid    = s_awid;
    assign m_awaddr  = s_awaddr[M_ADDR_WIDTH-1:0];
    assign m_awlen   = s_awlen;
    assign m_awsize  = s_awsize;
    assign m_awburst = s_awburst;
    assign m_awlock  = s_awlock;
    assign m_awcache = s_awcache;
    assign m_awprot  = s_awprot;
    assign m_awqos   = s_awqos;

    assign m_wdata   = s_wdata;
    assign m_wstrb   = s_wstrb;
    assign m_wlast   = s_wlast;

    assign m_arid    = s_arid;
    assign m_araddr  = s_araddr[M_ADDR_WIDTH-1:0];
    assign m_arlen   = s_arlen;
    assign m_arsize  = s_arsize;
    assign m_arburst = s_arburst;
    assign m_arlock  = s_arlock;
    assign m_arcache = s_arcache;
    assign m_arprot  = s_arprot;
    assign m_arqos   = s_arqos;

    //-----------------------------------------------------------------
    // Write path
    //-----------------------------------------------------------------
    localparam logic [2:0] W_IDLE      = 3'd0;  // waiting for AW (W forwarded with a decoded AW)
    localparam logic [2:0] W_PASS_DATA = 3'd1;  // forwarding W beats
    localparam logic [2:0] W_PASS_RESP = 3'd2;  // forwarding B
    localparam logic [2:0] W_ERR_DATA  = 3'd3;  // discarding W beats
    localparam logic [2:0] W_ERR_RESP  = 3'd4;  // returning DECERR on B
    localparam logic [2:0] W_PASS_AW   = 3'd5;  // W finished first, waiting for AW handshake

    logic [2:0]          wstate;
    logic [ID_WIDTH-1:0] err_awid;

    always_comb begin
        m_awvalid = 1'b0;
        s_awready = 1'b0;
        m_wvalid  = 1'b0;
        s_wready  = 1'b0;
        s_bvalid  = 1'b0;
        m_bready  = 1'b0;
        s_bid     = m_bid;
        s_bresp   = m_bresp;

        case (wstate)
            W_IDLE: begin
                m_awvalid = s_awvalid & ~aw_err;
                s_awready = aw_err ? 1'b1 : m_awready;
                // W is forwarded together with a decoded, valid AW, so the
                // M side never waits for AWREADY before asserting WVALID
                m_wvalid  = s_wvalid & s_awvalid & ~aw_err;
                s_wready  = m_wready & s_awvalid & ~aw_err;
            end
            W_PASS_AW: begin
                m_awvalid = s_awvalid;
                s_awready = m_awready;
            end
            W_PASS_DATA: begin
                m_wvalid  = s_wvalid;
                s_wready  = m_wready;
            end
            W_PASS_RESP: begin
                s_bvalid  = m_bvalid;
                m_bready  = s_bready;
            end
            W_ERR_DATA: begin
                s_wready  = 1'b1;
            end
            W_ERR_RESP: begin
                s_bvalid  = 1'b1;
                s_bid     = err_awid;
                s_bresp   = RESP_DECERR;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate   <= W_IDLE;
            err_awid <= '0;
        end
        else begin
            case (wstate)
                W_IDLE: begin
                    if (s_awvalid && s_awready) begin
                        if (aw_err) begin
                            err_awid <= s_awid;
                            wstate   <= W_ERR_DATA;
                        end
                        else if (s_wvalid && s_wready && s_wlast) begin
                            wstate   <= W_PASS_RESP;
                        end
                        else begin
                            wstate   <= W_PASS_DATA;
                        end
                    end
                    else if (s_wvalid && s_wready && s_wlast) begin
                        wstate <= W_PASS_AW;
                    end
                end
                W_PASS_AW:   if (s_awvalid && s_awready)            wstate <= W_PASS_RESP;
                W_PASS_DATA: if (s_wvalid && s_wready && s_wlast) wstate <= W_PASS_RESP;
                W_PASS_RESP: if (s_bvalid && s_bready)            wstate <= W_IDLE;
                W_ERR_DATA:  if (s_wvalid && s_wready && s_wlast) wstate <= W_ERR_RESP;
                W_ERR_RESP:  if (s_bvalid && s_bready)            wstate <= W_IDLE;
                default:                                          wstate <= W_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // Read path
    //-----------------------------------------------------------------
    localparam logic [1:0] R_IDLE = 2'd0;       // waiting for AR
    localparam logic [1:0] R_PASS = 2'd1;       // forwarding R beats
    localparam logic [1:0] R_ERR  = 2'd2;       // generating DECERR beats

    logic [1:0]          rstate;
    logic [ID_WIDTH-1:0] err_arid;
    logic [7:0]          err_arlen;
    logic [7:0]          err_rbeat;

    always_comb begin
        m_arvalid = 1'b0;
        s_arready = 1'b0;
        s_rvalid  = 1'b0;
        m_rready  = 1'b0;
        s_rid     = m_rid;
        s_rdata   = m_rdata;
        s_rresp   = m_rresp;
        s_rlast   = m_rlast;

        case (rstate)
            R_IDLE: begin
                m_arvalid = s_arvalid & ~ar_err;
                s_arready = ar_err ? 1'b1 : m_arready;
            end
            R_PASS: begin
                s_rvalid  = m_rvalid;
                m_rready  = s_rready;
            end
            R_ERR: begin
                s_rvalid  = 1'b1;
                s_rid     = err_arid;
                s_rdata   = '0;
                s_rresp   = RESP_DECERR;
                s_rlast   = (err_rbeat == err_arlen);
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate    <= R_IDLE;
            err_arid  <= '0;
            err_arlen <= 8'd0;
            err_rbeat <= 8'd0;
        end
        else begin
            case (rstate)
                R_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        if (ar_err) begin
                            err_arid  <= s_arid;
                            err_arlen <= s_arlen;
                            err_rbeat <= 8'd0;
                            rstate    <= R_ERR;
                        end
                        else begin
                            rstate    <= R_PASS;
                        end
                    end
                end
                R_PASS: if (s_rvalid && s_rready && s_rlast) rstate <= R_IDLE;
                R_ERR: begin
                    if (s_rvalid && s_rready) begin
                        if (err_rbeat == err_arlen) rstate    <= R_IDLE;
                        else                        err_rbeat <= err_rbeat + 8'd1;
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
