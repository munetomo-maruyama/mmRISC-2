//---------------------------------------------------------------------------
// CORE_IFU.sv
//
// Instruction fetch (CPU_CORE_SPEC.md 4).
//
//   IF1 : PC selection and the request to the instruction cache
//   IF2 : the cache answers two cycles later; the word is cut into a 32 bit
//         instruction and pushed into the fetch queue
//   FQ  : fetch queue, decouples the front end from the back end
//
//   The cache answers in order and carries no address, so the PC of every
//   outstanding request is kept in a small FIFO. A redirect (branch, jump,
//   exception) clears both FIFOs and kills the request that is in the cache
//   (i_kill), so nothing of the wrong path reaches the queue.
//
//   M1 fetches one 32 bit instruction per request. The cache takes one
//   request per cycle, so this is still one instruction per cycle; using both
//   halves of the 64 bit word (and the compressed instructions) comes with C.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_IFU
    #(
        parameter int          PADDR_WIDTH  = 40,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000,
        parameter int          FQ_DEPTH     = 4
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // instruction cache port
        output logic                    i_req_valid,
        input  logic                    i_req_ready,
        output logic [PADDR_WIDTH-1:0]  i_req_addr,
        output logic [PADDR_WIDTH-1:0]  i_req_paddr,
        input  logic                    i_resp_valid,
        input  logic [63:0]             i_resp_data,
        input  logic                    i_resp_error,
        output logic                    i_kill,

        // redirect from the back end
        input  logic                    redirect_valid,
        input  logic [63:0]             redirect_pc,

        // instruction queue to ID
        output logic                    fq_valid,
        input  logic                    fq_ready,
        output logic [63:0]             fq_pc,
        output logic [31:0]             fq_insn,
        output logic                    fq_error
    );

    localparam int OS_DEPTH = 4;                  // outstanding requests
    localparam int OS_BITS  = $clog2(OS_DEPTH);
    localparam int FQ_BITS  = $clog2(FQ_DEPTH);

    //-----------------------------------------------------------------
    // fetch PC
    //-----------------------------------------------------------------
    logic [63:0] fetch_pc;

    //-----------------------------------------------------------------
    // outstanding request FIFO (PC of every request in the cache)
    //-----------------------------------------------------------------
    logic [63:0]        os_pc [0:OS_DEPTH-1];
    logic [OS_BITS-1:0] os_head, os_tail;
    logic [OS_BITS:0]   os_count;

    //-----------------------------------------------------------------
    // fetch queue
    //-----------------------------------------------------------------
    logic [63:0]        q_pc   [0:FQ_DEPTH-1];
    logic [31:0]        q_insn [0:FQ_DEPTH-1];
    logic               q_err  [0:FQ_DEPTH-1];
    logic [FQ_BITS-1:0] q_head, q_tail;
    logic [FQ_BITS:0]   q_count;

    logic push_req, push_q, pop_q;

    // a request is issued while queue plus outstanding stays below the depth
    assign i_req_valid = rst_n & ~redirect_valid &
                         (((FQ_BITS+1)'(q_count) + (OS_BITS+1)'(os_count)) < (FQ_BITS+1)'(FQ_DEPTH));
    assign i_req_addr  = fetch_pc[PADDR_WIDTH-1:0];
    assign i_kill      = redirect_valid;

    assign push_req = i_req_valid & i_req_ready;
    assign push_q   = i_resp_valid & ~redirect_valid & (os_count != '0);
    assign pop_q    = fq_valid & fq_ready;

    assign fq_valid = (q_count != '0);
    assign fq_pc    = q_pc[q_head];
    assign fq_insn  = q_insn[q_head];
    assign fq_error = q_err[q_head];

    function automatic logic [OS_BITS-1:0] os_next(input logic [OS_BITS-1:0] p);
        return (int'(p) == OS_DEPTH-1) ? '0 : p + OS_BITS'(1);
    endfunction
    function automatic logic [FQ_BITS-1:0] q_next(input logic [FQ_BITS-1:0] p);
        return (int'(p) == FQ_DEPTH-1) ? '0 : p + FQ_BITS'(1);
    endfunction

    logic [63:0] resp_pc;
    logic [31:0] resp_insn;

    assign resp_pc   = os_pc[os_head];
    assign resp_insn = resp_pc[2] ? i_resp_data[63:32] : i_resp_data[31:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_pc    <= RESET_VECTOR;
            os_head     <= '0;
            os_tail     <= '0;
            os_count    <= '0;
            q_head      <= '0;
            q_tail      <= '0;
            q_count     <= '0;
            i_req_paddr <= '0;
        end else begin
            // physical address of the request accepted in the previous cycle
            // (no MMU yet, CPU_CACHE_SPEC.md 5.6)
            if (push_req) i_req_paddr <= i_req_addr;

            if (redirect_valid) begin
                fetch_pc <= redirect_pc;
                os_head  <= '0;
                os_tail  <= '0;
                os_count <= '0;
                q_head   <= '0;
                q_tail   <= '0;
                q_count  <= '0;
            end else begin
                // issue
                if (push_req) begin
                    os_pc[os_tail] <= fetch_pc;
                    os_tail        <= os_next(os_tail);
                    fetch_pc       <= fetch_pc + 64'd4;
                end
                // response -> queue
                if (push_q) begin
                    q_pc[q_tail]   <= resp_pc;
                    q_insn[q_tail] <= resp_insn;
                    q_err[q_tail]  <= i_resp_error;
                    q_tail         <= q_next(q_tail);
                    os_head        <= os_next(os_head);
                end
                if (pop_q) q_head <= q_next(q_head);

                os_count <= os_count + ((OS_BITS+1)'(push_req ? 1 : 0))
                                     - ((OS_BITS+1)'(push_q   ? 1 : 0));
                q_count  <= q_count  + ((FQ_BITS+1)'(push_q   ? 1 : 0))
                                     - ((FQ_BITS+1)'(pop_q    ? 1 : 0));
            end
        end
    end

endmodule : CORE_IFU
