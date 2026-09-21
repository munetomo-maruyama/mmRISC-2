//---------------------------------------------------------------------------
// CORE_LSU.sv
//
// Load / store unit : drives the data cache port and aligns the data.
//
//   The request is issued when the address is ready (EX), the answer is
//   awaited in MA. The cache answers in order, and M1 keeps one access in
//   flight at a time, which makes the load-use interlock fall out of the MA
//   stall (the pipeline behind it cannot advance either).
//
//   The command comes from the decoder, so LR, SC and the atomic operations
//   of the A extension go through the same path as a load or a store; the
//   cache does the read modify write and the reservation.
//
//   Misaligned accesses never reach this unit: EX turns them into a trap,
//   and so does an address the MMU refuses, so everything that arrives here
//   has a physical address already.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_LSU
    #(
        parameter int PADDR_WIDTH = 40
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // request from EX
        input  logic                    req_valid,     // start an access
        input  logic [3:0]              req_cmd,       // command of the cache port
        input  logic [63:0]             req_addr,
        input  logic [63:0]             req_paddr,     // from the MMU
        input  logic [1:0]              req_size,      // 0:byte 1:half 2:word 3:double
        input  logic                    req_signed,
        input  logic [63:0]             req_wdata,
        output logic                    req_accept,    // taken by the cache this cycle

        // result for MA
        output logic                    resp_valid,
        output logic [63:0]             resp_data,
        output logic                    resp_error,

        // flush (exception / redirect while an access is outstanding)
        input  logic                    kill,

        // data cache port
        output logic                    d_req_valid,
        input  logic                    d_req_ready,
        output logic [PADDR_WIDTH-1:0]  d_req_addr,
        output logic [PADDR_WIDTH-1:0]  d_req_paddr,
        output logic [1:0]              d_req_size,
        output logic [3:0]              d_req_cmd,
        output logic [63:0]             d_req_wdata,
        input  logic                    d_resp_valid,
        input  logic [63:0]             d_resp_data,
        input  logic                    d_resp_error
    );

    logic        busy;            // an access is in the cache
    logic [1:0]  size_r;
    logic        signed_r;

    // a new access may start in the very cycle the previous one answers, so
    // that back to back loads and stores do not lose a cycle
    assign d_req_valid = req_valid & (~busy | d_resp_valid);
    assign d_req_addr  = req_addr[PADDR_WIDTH-1:0];
    assign d_req_size  = req_size;
    assign d_req_cmd   = req_cmd;
    // the data of a store is placed in its lane by the cache
    assign d_req_wdata = req_wdata;
    assign req_accept  = d_req_valid & d_req_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy        <= 1'b0;
            size_r      <= 2'd0;
            signed_r    <= 1'b0;
            d_req_paddr <= '0;
        end else begin
            if (req_accept) begin
                busy        <= 1'b1;        // wins over the answer of this cycle
                size_r      <= req_size;
                signed_r    <= req_signed;
                // the cache wants the tag one cycle after the request was
                // taken (CPU_CACHE_SPEC.md 5.6)
                d_req_paddr <= req_paddr[PADDR_WIDTH-1:0];
            end else if (d_resp_valid) begin
                busy        <= 1'b0;
            end else if (kill) begin
                busy        <= 1'b0;
            end
        end
    end

    // the answer of the cache is right aligned already; only the sign
    // extension of the smaller sizes is left
    logic [63:0] ext;

    always @(*) begin
        case (size_r)
            2'd0:    ext = signed_r ? {{56{d_resp_data[7]}},  d_resp_data[7:0]}
                                    : {56'd0, d_resp_data[7:0]};
            2'd1:    ext = signed_r ? {{48{d_resp_data[15]}}, d_resp_data[15:0]}
                                    : {48'd0, d_resp_data[15:0]};
            2'd2:    ext = signed_r ? {{32{d_resp_data[31]}}, d_resp_data[31:0]}
                                    : {32'd0, d_resp_data[31:0]};
            default: ext = d_resp_data;
        endcase
    end

    // the answer is only looked at by an access that writes a register
    // (load, LR, SC and the atomic operations)
    assign resp_valid = d_resp_valid;
    assign resp_data  = ext;
    assign resp_error = d_resp_error;

endmodule : CORE_LSU
