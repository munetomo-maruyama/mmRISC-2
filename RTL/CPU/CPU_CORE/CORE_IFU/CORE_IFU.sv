//---------------------------------------------------------------------------
// CORE_IFU.sv
//
// Instruction fetch (CPU_CORE_SPEC.md 4).
//
//   IF1 : the address of the next 64 bit word and the request to the cache
//   IF2 : the cache answers two cycles later; the word is cut into four
//         parcels of 16 bit which are pushed into the parcel queue
//   FQ  : the head of the queue is one instruction, 16 or 32 bit wide
//
//   With the C extension an instruction is not aligned to four bytes any more
//   and may sit across two words, so the queue holds parcels and not whole
//   instructions. The address of the parcel at the head is `head_pc`: the
//   parcels are pushed in order and thrown away together, so one counter is
//   enough and no address has to be stored per entry.
//
//   The cache answers in order and carries no address. A redirect (branch,
//   jump, trap) clears the queue and kills what is in the cache (i_kill), so
//   nothing of the wrong path arrives. `push_pc` says which parcel of the
//   next answer is the first one that belongs to the new path, which is how
//   a redirect into the middle of a word is handled.
//
//   Every fetch goes through the MMU. Three things can come back: the
//   physical address, a fault, or nothing yet because the page table is
//   being walked. A fault does not become an exception here -- the fetch is
//   speculative and may never be used -- so it is written into the queue
//   with the parcels and raised in ID by whichever instruction ends up
//   carrying it. Such a fetch is answered inside this unit and never
//   reaches the cache, and it waits until the answers already in the cache
//   have come back so that the queue stays in order.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_IFU
    #(
        parameter int          PADDR_WIDTH  = 40,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000,
        parameter int          PQ_DEPTH     = 16      // parcels, power of two
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

        // address translation and protection
        output logic                    tr_req,
        output logic [63:0]             tr_vaddr,
        input  logic                    tr_ready,    // the two below are valid
        input  logic [63:0]             tr_paddr,
        input  logic [1:0]              tr_fault,    // 0 none, 1 access, 2 page

        // instruction to ID
        output logic                    fq_valid,
        input  logic                    fq_ready,
        output logic [63:0]             fq_pc,
        output logic [31:0]             fq_insn,     // raw; 16 bit in the low half
        output logic                    fq_is_rvc,
        output logic [1:0]              fq_fault
    );

    localparam int OS_DEPTH = 4;                  // outstanding requests
    localparam int OS_BITS  = $clog2(OS_DEPTH);
    localparam int PQ_BITS  = $clog2(PQ_DEPTH);

    //-----------------------------------------------------------------
    // addresses
    //-----------------------------------------------------------------
    logic [63:0] fetch_pc;        // next word to ask for, eight byte aligned
    logic [63:0] head_pc;         // address of the parcel at the head
    logic [63:0] push_pc;         // address of the next parcel to be pushed

    //-----------------------------------------------------------------
    // parcel queue
    //-----------------------------------------------------------------
    logic [15:0]        pq_data  [0:PQ_DEPTH-1];
    logic [1:0]         pq_fault [0:PQ_DEPTH-1];
    logic [PQ_BITS-1:0] pq_head, pq_tail;
    logic [PQ_BITS:0]   pq_count;
    logic [OS_BITS:0]   os_count;

    logic push_req, push_resp, resp_real, local_resp, pop_q;
    logic req_want, fetch_bad;
    logic [2:0] push_n;           // parcels of this answer that are kept

    // a request is issued while the queue can take four more parcels; every
    // request that is in the cache brings four
    logic [PQ_BITS+1:0] pq_inflight;
    assign pq_inflight = (PQ_BITS+2)'(pq_count) + ((PQ_BITS+2)'(os_count) << 2);
    assign req_want    = rst_n & ~redirect_valid &
                         (pq_inflight <= (PQ_BITS+2)'(PQ_DEPTH - 4));

    assign tr_req      = req_want;
    assign tr_vaddr    = fetch_pc;

    assign fetch_bad   = req_want & tr_ready & (tr_fault != 2'd0);
    assign local_resp  = fetch_bad & (os_count == '0);
    assign i_req_valid = req_want & tr_ready & (tr_fault == 2'd0);
    // the cache is indexed with the virtual address and tagged with the
    // physical one, and the two agree on the bits it indexes with
    assign i_req_addr  = fetch_pc[PADDR_WIDTH-1:0];
    assign i_kill      = redirect_valid;

    assign push_req  = i_req_valid & i_req_ready;
    assign resp_real = i_resp_valid & ~redirect_valid & (os_count != '0);
    assign push_resp = resp_real | local_resp;
    // the parcels in front of push_pc belong to the word but not to the path
    assign push_n    = 3'd4 - {1'b0, push_pc[2:1]};

    //-----------------------------------------------------------------
    // the instruction at the head
    //-----------------------------------------------------------------
    logic [15:0] p0, p1;
    logic [1:0]  e0, e1;
    logic [PQ_BITS-1:0] head_next;

    assign head_next = pq_head + PQ_BITS'(1);
    assign p0 = pq_data[pq_head];
    assign p1 = pq_data[head_next];
    assign e0 = pq_fault[pq_head];
    assign e1 = pq_fault[head_next];

    assign fq_is_rvc = (p0[1:0] != 2'b11);
    assign fq_valid  = (pq_count != '0) &&
                       (fq_is_rvc || (pq_count >= (PQ_BITS+1)'(2)));
    assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p1, p0};
    // a 32 bit instruction across two words takes the fault of whichever
    // half has one
    assign fq_fault  = fq_is_rvc ? e0 : ((e0 != 2'd0) ? e0 : e1);
    assign fq_pc     = head_pc;
    assign pop_q     = fq_valid & fq_ready;

    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_pc    <= {RESET_VECTOR[63:3], 3'b000};
            head_pc     <= RESET_VECTOR;
            push_pc     <= RESET_VECTOR;
            pq_head     <= '0;
            pq_tail     <= '0;
            pq_count    <= '0;
            os_count    <= '0;
            i_req_paddr <= '0;
        end else begin
            // the cache wants the tag in the cycle after the request was
            // taken (CPU_CACHE_SPEC.md 5.6)
            if (push_req) i_req_paddr <= tr_paddr[PADDR_WIDTH-1:0];

            if (redirect_valid) begin
                fetch_pc <= {redirect_pc[63:3], 3'b000};
                head_pc  <= redirect_pc;
                push_pc  <= redirect_pc;
                pq_head  <= '0;
                pq_tail  <= '0;
                pq_count <= '0;
                os_count <= '0;
            end else begin
                if (push_req | local_resp) fetch_pc <= fetch_pc + 64'd8;

                if (push_resp) begin
                    for (int i = 0; i < 4; i++) begin
                        if ((PQ_BITS+1)'(i) >= {{(PQ_BITS-1){1'b0}}, push_pc[2:1]}) begin
                            pq_data[pq_tail + PQ_BITS'(i) - PQ_BITS'(push_pc[2:1])]
                                <= local_resp ? 16'd0 : i_resp_data[16*i +: 16];
                            pq_fault[pq_tail + PQ_BITS'(i) - PQ_BITS'(push_pc[2:1])]
                                <= local_resp ? tr_fault
                                              : (i_resp_error ? 2'd1 : 2'd0);
                        end
                    end
                    pq_tail <= pq_tail + PQ_BITS'(push_n);
                    push_pc <= {push_pc[63:3], 3'b000} + 64'd8;
                end

                if (pop_q) begin
                    pq_head <= pq_head + (fq_is_rvc ? PQ_BITS'(1) : PQ_BITS'(2));
                    head_pc <= head_pc + (fq_is_rvc ? 64'd2 : 64'd4);
                end

                pq_count <= pq_count
                          + (push_resp ? (PQ_BITS+1)'(push_n) : (PQ_BITS+1)'(0))
                          - (pop_q ? (fq_is_rvc ? (PQ_BITS+1)'(1) : (PQ_BITS+1)'(2))
                                   : (PQ_BITS+1)'(0));
                os_count <= os_count + ((OS_BITS+1)'(push_req  ? 1 : 0))
                                     - ((OS_BITS+1)'(resp_real ? 1 : 0));
            end
        end
    end

endmodule : CORE_IFU
