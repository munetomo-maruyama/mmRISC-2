//---------------------------------------------------------------------------
// DBG_CACHE.sv
//
// Debug bus master request -> data cache port
// (RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md 4.7).
//
//   The debug module issues one access at a time with the same handshake it
//   uses for DBG_BUSMST (bm_req pulse -> bm_ack pulse). This module turns it
//   into a request on the second port of the data cache, so that what the
//   debugger sees is what the CPU sees:
//
//     read  : CMD_LOAD    - a miss fills the line, the next read hits
//     write : CMD_STWTHR  - write through, no allocate. Memory always holds
//                           the value, and a line that happens to be in the
//                           cache is updated but not made dirty.
//
//   A read of a line the CPU has left dirty returns the dirty value, and a
//   debug write is visible to the CPU straight away.
//
//   The timeout is the same safety net as in DBG_BUSMST: if the cache does
//   not answer, the access is completed with bm_err=1 (timeout) so that the
//   debugger does not hang.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_CACHE
    #(
        parameter int ADDR_WIDTH     = 40,
        parameter int TIMEOUT_CYCLES = 1 << 20
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // request from DBG_DM (same protocol as DBG_BUSMST)
        input  logic                  bm_req,
        input  logic                  bm_wr,
        input  logic [ADDR_WIDTH-1:0] bm_addr,
        input  logic [1:0]            bm_size,
        input  logic [63:0]           bm_wdata,
        output logic                  bm_ack,
        output logic [63:0]           bm_rdata,
        output logic [2:0]            bm_err,

        // data cache port
        output logic                  dc_req_valid,
        input  logic                  dc_req_ready,
        output logic [ADDR_WIDTH-1:0] dc_req_addr,
        output logic [1:0]            dc_req_size,
        output logic [3:0]            dc_req_cmd,
        output logic [63:0]           dc_req_wdata,
        // the debug module works with physical addresses, so the cache gets
        // the same value (it is held until the next access, which is what the
        // cache needs in the cycle after the request was accepted)
        output logic [ADDR_WIDTH-1:0] dc_req_paddr,
        input  logic                  dc_resp_valid,
        input  logic [63:0]           dc_resp_data,
        input  logic                  dc_resp_error,

        // 1 while an access is in flight (used to invalidate the I$ after a
        // debug write, and as "busy" for the debug module)
        output logic                  busy,
        output logic                  wrote          // pulse: a write finished
    );

    localparam logic [3:0] CMD_LOAD   = 4'd0;
    localparam logic [3:0] CMD_STWTHR = 4'd15;

    typedef enum logic [1:0] {C_IDLE, C_REQ, C_RESP} state_t;
    state_t state;

    logic        c_wr;
    logic [31:0] tmo;

    assign busy         = (state != C_IDLE);
    assign dc_req_paddr = dc_req_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= C_IDLE;
            c_wr         <= 1'b0;
            tmo          <= '0;
            bm_ack       <= 1'b0;
            bm_rdata     <= '0;
            bm_err       <= 3'd0;
            wrote        <= 1'b0;
            dc_req_valid <= 1'b0;
            dc_req_addr  <= '0;
            dc_req_size  <= 2'd0;
            dc_req_cmd   <= CMD_LOAD;
            dc_req_wdata <= '0;
        end else begin
            bm_ack <= 1'b0;
            wrote  <= 1'b0;

            case (state)
                C_IDLE: begin
                    if (bm_req) begin
                        dc_req_valid <= 1'b1;
                        dc_req_addr  <= bm_addr;
                        dc_req_size  <= bm_size;
                        dc_req_cmd   <= bm_wr ? CMD_STWTHR : CMD_LOAD;
                        dc_req_wdata <= bm_wdata;
                        c_wr         <= bm_wr;
                        tmo          <= '0;
                        state        <= C_REQ;
                    end
                end
                C_REQ: begin
                    if (dc_req_ready) begin
                        dc_req_valid <= 1'b0;
                        state        <= C_RESP;
                    end
                    tmo <= tmo + 32'd1;
                    if (tmo == TIMEOUT_CYCLES[31:0]) begin
                        dc_req_valid <= 1'b0;
                        bm_ack       <= 1'b1;
                        bm_err       <= 3'd1;          // timeout
                        state        <= C_IDLE;
                    end
                end
                C_RESP: begin
                    tmo <= tmo + 32'd1;
                    if (dc_resp_valid) begin
                        bm_ack   <= 1'b1;
                        bm_rdata <= dc_resp_data;
                        bm_err   <= dc_resp_error ? 3'd2 : 3'd0;   // 2 = DECERR
                        wrote    <= c_wr & ~dc_resp_error;
                        state    <= C_IDLE;
                    end else if (tmo == TIMEOUT_CYCLES[31:0]) begin
                        bm_ack <= 1'b1;
                        bm_err <= 3'd1;                // timeout
                        state  <= C_IDLE;
                    end
                end
                default: state <= C_IDLE;
            endcase
        end
    end

endmodule : DBG_CACHE
