//---------------------------------------------------------------------------
// DBG_CDC.sv
//
// Clock Domain Crossing primitives for the mmRISC-2 debug logic
//
//   DBG_SYNC      : 2-FF level synchronizer (async reset)
//   DBG_RST_SYNC  : reset synchronizer, asynchronous assert / synchronous
//                   deassert
//   DBG_CDC       : DMI request/response crossing between the JTAG TCK
//                   domain (DTM) and the system clock domain (DM)
//
// DBG_CDC protocol (bundled data + 4-phase handshake):
//
//   TCK domain                              system clock domain
//   ----------                              -------------------
//   q_addr/q_wr/q_wdata (held while req=1) --(not synchronized)-->
//   req  ---------------[2FF]--------------> req_s
//                                           req_s=1 in S_IDLE : latch q_*,
//                                                               issue dmi_req
//                                           dmi_ack           : latch rdata,
//                                                               ack=1
//   ack_s <-------------[2FF]--------------- ack
//   req & ack_s : take response, req=0
//                                           req_s=0 in S_ACK  : ack=0
//   a new req is raised only when ack_s=0
//
//   - Only the 1-bit req/ack lines are synchronized. Multi-bit data is
//     guaranteed stable by the handshake, so no bit skew can corrupt it.
//   - Each side advances only with its own clock, so any frequency ratio
//     and any phase relation (including a stopped TCK) is safe.
//   - The handshake state is reset only by the debug power-on reset, which
//     is shared by both domains. dtmhardreset / TRST / Test-Logic-Reset only
//     cancel a request that has not yet been raised (t_abort); a request
//     already raised always runs to completion, so the two sides can never
//     get out of step and stale responses can never be mistaken for new
//     ones.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

//===========================================================================
// 2-FF level synchronizer
//===========================================================================
module DBG_SYNC
    #(
        parameter int WIDTH     = 1,
        parameter logic [WIDTH-1:0] RESET_VAL = '0
    )
    (
        input  logic             clk,
        input  logic             rst_n,
        input  logic [WIDTH-1:0] d,
        output logic [WIDTH-1:0] q
    );

    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] ff1;
    (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] ff2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ff1 <= RESET_VAL;
            ff2 <= RESET_VAL;
        end else begin
            ff1 <= d;
            ff2 <= ff1;
        end
    end

    assign q = ff2;

endmodule : DBG_SYNC

//===========================================================================
// Reset synchronizer (asynchronous assert, synchronous deassert)
//===========================================================================
module DBG_RST_SYNC
    (
        input  logic clk,
        input  logic rst_in_n,     // asynchronous, active low
        output logic rst_out_n     // asserted asynchronously,
                                   // deasserted synchronously to clk
    );

    // Initial value 0 = reset asserted at power-up (FPGA register INIT). This
    // matters for a clock that is not running during the power-on reset
    // (TCK): the output is then asserted without needing a reset edge.
    (* ASYNC_REG = "TRUE" *) logic ff1 = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic ff2 = 1'b0;

    always_ff @(posedge clk or negedge rst_in_n) begin
        if (!rst_in_n) begin
            ff1 <= 1'b0;
            ff2 <= 1'b0;
        end else begin
            ff1 <= 1'b1;
            ff2 <= ff1;
        end
    end

    assign rst_out_n = ff2;

endmodule : DBG_RST_SYNC

//===========================================================================
// DMI request/response crossing
//===========================================================================
module DBG_CDC
    #(
        parameter int ABITS = 7
    )
    (
        //-------------------------------------------------------------
        // TCK domain (DTM side)
        //-------------------------------------------------------------
        input  logic             tck,
        input  logic             t_rst_n,      // debug POR, synchronized to TCK

        input  logic             t_start,      // start request (ignored when t_busy)
        input  logic [ABITS-1:0] t_addr,
        input  logic             t_wr,
        input  logic [31:0]      t_wdata,
        input  logic             t_abort,      // cancel a not-yet-raised request

        output logic             t_busy,       // request outstanding
        output logic [31:0]      t_rdata,      // response of last request
        output logic             t_err,

        //-------------------------------------------------------------
        // System clock domain (DM side)
        //-------------------------------------------------------------
        input  logic             clk,
        input  logic             s_rst_n,      // debug POR, synchronized to clk

        output logic             dmi_req,      // 1-cycle pulse
        output logic [ABITS-1:0] dmi_addr,
        output logic             dmi_wr,
        output logic [31:0]      dmi_wdata,
        input  logic             dmi_ack,      // 1-cycle pulse
        input  logic [31:0]      dmi_rdata,
        input  logic             dmi_err
    );

    //=================================================================
    // TCK domain
    //=================================================================
    logic             pend;         // accepted, waiting for ack_s=0
    logic             req;
    logic             ack_s;
    logic [ABITS-1:0] q_addr;
    logic             q_wr;
    logic [31:0]      q_wdata;
    logic [31:0]      r_rdata;
    logic             r_err;

    // system-domain response registers (bundled with ack)
    logic [31:0]      s_rdata;
    logic             s_err;
    logic             ack;

    // Complete at this edge when req is up and the ack has arrived.
    // The response is readable combinationally in that case because it is
    // held stable by the system side while ack=1.
    logic             t_complete;
    assign t_complete = req & ack_s;

    assign t_busy  = pend | (req & ~ack_s);
    assign t_rdata = t_complete ? s_rdata : r_rdata;
    assign t_err   = t_complete ? s_err   : r_err;

    always_ff @(posedge tck or negedge t_rst_n) begin
        if (!t_rst_n) begin
            pend    <= 1'b0;
            req     <= 1'b0;
            q_addr  <= '0;
            q_wr    <= 1'b0;
            q_wdata <= '0;
            r_rdata <= '0;
            r_err   <= 1'b0;
        end else begin
            // take response
            if (t_complete) begin
                req     <= 1'b0;
                r_rdata <= s_rdata;
                r_err   <= s_err;
            end
            // accept new request
            if (t_start & ~t_busy & ~t_abort) begin
                q_addr  <= t_addr;
                q_wr    <= t_wr;
                q_wdata <= t_wdata;
                if (~req & ~ack_s)
                    req  <= 1'b1;     // raise immediately
                else
                    pend <= 1'b1;     // previous handshake still closing
            end
            // raise a pending request once the previous ack has fallen
            else if (pend & ~req & ~ack_s) begin
                if (t_abort) begin
                    pend <= 1'b0;
                end else begin
                    pend <= 1'b0;
                    req  <= 1'b1;
                end
            end
            else if (t_abort) begin
                pend <= 1'b0;
            end
        end
    end

    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync_ack
        (.clk(tck), .rst_n(t_rst_n), .d(ack), .q(ack_s));

    //=================================================================
    // System clock domain
    //=================================================================
    typedef enum logic [1:0] {S_IDLE, S_WAIT, S_ACK} s_state_t;
    s_state_t s_state;
    logic     req_s;

    DBG_SYNC #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync_req
        (.clk(clk), .rst_n(s_rst_n), .d(req), .q(req_s));

    always_ff @(posedge clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            s_state   <= S_IDLE;
            ack       <= 1'b0;
            dmi_req   <= 1'b0;
            dmi_addr  <= '0;
            dmi_wr    <= 1'b0;
            dmi_wdata <= '0;
            s_rdata   <= '0;
            s_err     <= 1'b0;
        end else begin
            dmi_req <= 1'b0;
            case (s_state)
                S_IDLE: begin
                    if (req_s) begin
                        dmi_req   <= 1'b1;
                        dmi_addr  <= q_addr;
                        dmi_wr    <= q_wr;
                        dmi_wdata <= q_wdata;
                        s_state   <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (dmi_ack) begin
                        s_rdata <= dmi_rdata;
                        s_err   <= dmi_err;
                        ack     <= 1'b1;
                        s_state <= S_ACK;
                    end
                end
                S_ACK: begin
                    if (!req_s) begin
                        ack     <= 1'b0;
                        s_state <= S_IDLE;
                    end
                end
                default: s_state <= S_IDLE;
            endcase
        end
    end

endmodule : DBG_CDC
