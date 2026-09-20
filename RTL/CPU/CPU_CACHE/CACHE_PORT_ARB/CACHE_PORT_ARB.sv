//---------------------------------------------------------------------------
// CACHE_PORT_ARB.sv
//
// Two requesters on one data cache port (RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md
// 4.7). s0 is the CPU and has priority, s1 is the debug module.
//
//   - Requests are forwarded one at a time; the cache answers in the order it
//     accepted them, so a small FIFO of owner bits is enough to give every
//     response back to the requester it belongs to.
//   - s1 is not starved: after STARVE_CYCLES of waiting while s0 keeps the
//     port busy, s1 wins the next arbitration.
//   - The FIFO must be able to hold every request the cache can have in
//     flight (its ROB depth).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CACHE_PORT_ARB
    #(
        parameter int PADDR_WIDTH   = 40,
        parameter int XLEN          = 64,
        parameter int DEPTH         = 8,     // >= the ROB depth of the cache
        parameter int STARVE_CYCLES = 32
    )
    (
        input  logic                   clk,
        input  logic                   rst_n,

        // s0 : CPU (priority)
        input  logic                   s0_req_valid,
        output logic                   s0_req_ready,
        input  logic [PADDR_WIDTH-1:0] s0_req_addr,
        input  logic [1:0]             s0_req_size,
        input  logic [3:0]             s0_req_cmd,
        input  logic [XLEN-1:0]        s0_req_wdata,
        input  logic [PADDR_WIDTH-1:0] s0_req_paddr,
        output logic                   s0_resp_valid,
        output logic [XLEN-1:0]        s0_resp_data,
        output logic                   s0_resp_error,

        // s1 : debug module
        input  logic                   s1_req_valid,
        output logic                   s1_req_ready,
        input  logic [PADDR_WIDTH-1:0] s1_req_addr,
        input  logic [1:0]             s1_req_size,
        input  logic [3:0]             s1_req_cmd,
        input  logic [XLEN-1:0]        s1_req_wdata,
        input  logic [PADDR_WIDTH-1:0] s1_req_paddr,
        output logic                   s1_resp_valid,
        output logic [XLEN-1:0]        s1_resp_data,
        output logic                   s1_resp_error,

        // to the data cache
        output logic                   m_req_valid,
        input  logic                   m_req_ready,
        output logic [PADDR_WIDTH-1:0] m_req_addr,
        output logic [1:0]             m_req_size,
        output logic [3:0]             m_req_cmd,
        output logic [XLEN-1:0]        m_req_wdata,
        output logic [PADDR_WIDTH-1:0] m_req_paddr,
        input  logic                   m_resp_valid,
        input  logic [XLEN-1:0]        m_resp_data,
        input  logic                   m_resp_error
    );

    localparam int PTR_BITS = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    //-----------------------------------------------------------------
    // owner FIFO : 0 = s0, 1 = s1
    //-----------------------------------------------------------------
    logic [DEPTH-1:0]     owner;
    logic [PTR_BITS-1:0]  head, tail;
    logic [PTR_BITS:0]    count;
    logic                 full;
    logic                 push, pop;

    function automatic logic [PTR_BITS-1:0] nxt(input logic [PTR_BITS-1:0] p);
        return (int'(p) == DEPTH-1) ? '0 : p + PTR_BITS'(1);
    endfunction

    assign full = ((PTR_BITS+1)'(count) == (PTR_BITS+1)'(DEPTH));

    //-----------------------------------------------------------------
    // arbitration
    //-----------------------------------------------------------------
    logic [$clog2(STARVE_CYCLES+1)-1:0] wait_cnt;
    logic                               s1_first;

    assign s1_first = s1_req_valid && (!s0_req_valid || (wait_cnt == STARVE_CYCLES[$bits(wait_cnt)-1:0]));

    assign m_req_valid  = (s0_req_valid | s1_req_valid) & ~full;
    assign m_req_addr   = s1_first ? s1_req_addr  : s0_req_addr;
    assign m_req_size   = s1_first ? s1_req_size  : s0_req_size;
    assign m_req_cmd    = s1_first ? s1_req_cmd   : s0_req_cmd;
    assign m_req_wdata  = s1_first ? s1_req_wdata : s0_req_wdata;

    assign s0_req_ready = m_req_ready & ~full & ~s1_first;
    assign s1_req_ready = m_req_ready & ~full &  s1_first;

    // The physical address of a request arrives one cycle after it was
    // accepted, so it comes from the requester that won the last arbitration.
    logic last_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)   last_s1 <= 1'b0;
        else if (push) last_s1 <= s1_first;
    end

    assign m_req_paddr = last_s1 ? s1_req_paddr : s0_req_paddr;

    assign push = m_req_valid & m_req_ready;
    assign pop  = m_resp_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner    <= '0;
            head     <= '0;
            tail     <= '0;
            count    <= '0;
            wait_cnt <= '0;
        end else begin
            if (push) begin
                owner[tail] <= s1_first;
                tail        <= nxt(tail);
            end
            if (pop) head <= nxt(head);
            count <= count + ((PTR_BITS+1)'(push ? 1 : 0)) - ((PTR_BITS+1)'(pop ? 1 : 0));

            // s1 waiting while s0 is served
            if (s1_req_valid && !s1_req_ready) begin
                if (wait_cnt != STARVE_CYCLES[$bits(wait_cnt)-1:0])
                    wait_cnt <= wait_cnt + 1;
            end else begin
                wait_cnt <= '0;
            end
        end
    end

    //-----------------------------------------------------------------
    // responses (the cache answers in order)
    //-----------------------------------------------------------------
    assign s0_resp_valid = m_resp_valid & ~owner[head];
    assign s1_resp_valid = m_resp_valid &  owner[head];
    assign s0_resp_data  = m_resp_data;
    assign s1_resp_data  = m_resp_data;
    assign s0_resp_error = m_resp_error;
    assign s1_resp_error = m_resp_error;

endmodule : CACHE_PORT_ARB
