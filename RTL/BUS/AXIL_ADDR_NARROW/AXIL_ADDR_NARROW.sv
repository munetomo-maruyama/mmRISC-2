//---------------------------------------------------------------------------
// AXIL_ADDR_NARROW.sv
//
// AXI4-Lite address narrowing bridge with DECERR on unmapped upper bits.
//
// Connects a master with a wide address (e.g. the 40-bit mmRISC-2 peripheral
// bus) to a slave with a narrow address (e.g. a 32-bit LiteX SoC).
//
//   - Upper address bits [S_ADDR_WIDTH-1:M_ADDR_WIDTH] all zero
//       -> passed through, address truncated to [M_ADDR_WIDTH-1:0]
//   - Any upper address bit non-zero
//       -> not forwarded; the bridge terminates the transaction itself:
//          write : W is accepted and discarded, BRESP=DECERR
//          read  : RDATA=0, RRESP=DECERR
//
// Implementation notes:
//   - W is forwarded to the M side only while a valid AW whose address has
//     been decoded as in range is present (or after its handshake), so that
//     data of an erroneous write can never reach the M side. W is not held
//     until AWREADY, because a master must not wait for AWREADY before
//     asserting WVALID (a slave may wait for both AWVALID and WVALID).
//   - One write and one read transaction at a time; read and write paths are
//     independent.
//   - VALID/READY and payload are combinational in the pass-through path.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXIL_ADDR_NARROW
    #(
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
        input  logic [S_ADDR_WIDTH-1:0] s_awaddr,
        input  logic [2:0]              s_awprot,
        input  logic                    s_awvalid,
        output logic                    s_awready,

        input  logic [DATA_WIDTH-1:0]   s_wdata,
        input  logic [DATA_WIDTH/8-1:0] s_wstrb,
        input  logic                    s_wvalid,
        output logic                    s_wready,

        output logic [1:0]              s_bresp,
        output logic                    s_bvalid,
        input  logic                    s_bready,

        input  logic [S_ADDR_WIDTH-1:0] s_araddr,
        input  logic [2:0]              s_arprot,
        input  logic                    s_arvalid,
        output logic                    s_arready,

        output logic [DATA_WIDTH-1:0]   s_rdata,
        output logic [1:0]              s_rresp,
        output logic                    s_rvalid,
        input  logic                    s_rready,

        //-------------------------------------------------------------
        // Master port : connect to the narrow-address slave
        //-------------------------------------------------------------
        output logic [M_ADDR_WIDTH-1:0] m_awaddr,
        output logic [2:0]              m_awprot,
        output logic                    m_awvalid,
        input  logic                    m_awready,

        output logic [DATA_WIDTH-1:0]   m_wdata,
        output logic [DATA_WIDTH/8-1:0] m_wstrb,
        output logic                    m_wvalid,
        input  logic                    m_wready,

        input  logic [1:0]              m_bresp,
        input  logic                    m_bvalid,
        output logic                    m_bready,

        output logic [M_ADDR_WIDTH-1:0] m_araddr,
        output logic [2:0]              m_arprot,
        output logic                    m_arvalid,
        input  logic                    m_arready,

        input  logic [DATA_WIDTH-1:0]   m_rdata,
        input  logic [1:0]              m_rresp,
        input  logic                    m_rvalid,
        output logic                    m_rready
    );

    localparam logic [1:0] RESP_DECERR = 2'b11;

    wire aw_err = |s_awaddr[S_ADDR_WIDTH-1:M_ADDR_WIDTH];
    wire ar_err = |s_araddr[S_ADDR_WIDTH-1:M_ADDR_WIDTH];

    //-----------------------------------------------------------------
    // Payload pass-through
    //-----------------------------------------------------------------
    assign m_awaddr = s_awaddr[M_ADDR_WIDTH-1:0];
    assign m_awprot = s_awprot;
    assign m_wdata  = s_wdata;
    assign m_wstrb  = s_wstrb;
    assign m_araddr = s_araddr[M_ADDR_WIDTH-1:0];
    assign m_arprot = s_arprot;

    //-----------------------------------------------------------------
    // Write path
    //-----------------------------------------------------------------
    localparam logic [2:0] W_IDLE      = 3'd0;  // waiting for AW (W forwarded once AW is decoded)
    localparam logic [2:0] W_PASS_DATA = 3'd1;  // AW done, forwarding W
    localparam logic [2:0] W_PASS_RESP = 3'd2;  // forwarding B
    localparam logic [2:0] W_ERR_DATA  = 3'd3;  // discarding W
    localparam logic [2:0] W_ERR_RESP  = 3'd4;  // returning DECERR on B
    localparam logic [2:0] W_PASS_AW   = 3'd5;  // W done first, waiting for AW handshake

    logic [2:0] wstate;

    always_comb begin
        m_awvalid = 1'b0;
        s_awready = 1'b0;
        m_wvalid  = 1'b0;
        s_wready  = 1'b0;
        s_bvalid  = 1'b0;
        m_bready  = 1'b0;
        s_bresp   = m_bresp;

        case (wstate)
            W_IDLE: begin
                m_awvalid = s_awvalid & ~aw_err;
                s_awready = aw_err ? 1'b1 : m_awready;
                // W is forwarded together with a decoded, valid AW so that
                // the M side never waits for AWREADY before WVALID
                m_wvalid  = s_wvalid  & s_awvalid & ~aw_err;
                s_wready  = m_wready  & s_awvalid & ~aw_err;
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
                s_bresp   = RESP_DECERR;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate <= W_IDLE;
        end
        else begin
            case (wstate)
                W_IDLE: begin
                    if (s_awvalid && s_awready) begin
                        if (aw_err)
                            wstate <= W_ERR_DATA;
                        else if (s_wvalid && s_wready)
                            wstate <= W_PASS_RESP;
                        else
                            wstate <= W_PASS_DATA;
                    end
                    else if (s_wvalid && s_wready) begin
                        wstate <= W_PASS_AW;
                    end
                end
                W_PASS_AW:   if (s_awvalid && s_awready) wstate <= W_PASS_RESP;
                W_PASS_DATA: if (s_wvalid && s_wready) wstate <= W_PASS_RESP;
                W_PASS_RESP: if (s_bvalid && s_bready) wstate <= W_IDLE;
                W_ERR_DATA:  if (s_wvalid && s_wready) wstate <= W_ERR_RESP;
                W_ERR_RESP:  if (s_bvalid && s_bready) wstate <= W_IDLE;
                default:                               wstate <= W_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // Read path
    //-----------------------------------------------------------------
    localparam logic [1:0] R_IDLE = 2'd0;
    localparam logic [1:0] R_PASS = 2'd1;
    localparam logic [1:0] R_ERR  = 2'd2;

    logic [1:0] rstate;

    always_comb begin
        m_arvalid = 1'b0;
        s_arready = 1'b0;
        s_rvalid  = 1'b0;
        m_rready  = 1'b0;
        s_rdata   = m_rdata;
        s_rresp   = m_rresp;

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
                s_rdata   = '0;
                s_rresp   = RESP_DECERR;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE;
        end
        else begin
            case (rstate)
                R_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        rstate <= ar_err ? R_ERR : R_PASS;
                    end
                end
                R_PASS: if (s_rvalid && s_rready) rstate <= R_IDLE;
                R_ERR:  if (s_rvalid && s_rready) rstate <= R_IDLE;
                default:                          rstate <= R_IDLE;
            endcase
        end
    end

endmodule
