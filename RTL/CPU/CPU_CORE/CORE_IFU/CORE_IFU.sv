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
//   A branch target buffer predicts at IF1 (4.2). It is a fetch block
//   predictor, because this unit only knows the address of an eight byte
//   word when it issues the request: an entry says "the word at this
//   address contains a branch whose first parcel is at `off`, going to
//   `target`". A predicted word is pushed with the parcels behind the
//   branch thrown away, and the fetch goes on at the target.
//
//   A prediction is never trusted to be about a real instruction boundary.
//   The entry was written from a branch that really executed, but the same
//   bytes can be decoded at another alignment if the program jumps into the
//   middle of an instruction. The head therefore watches for the one case
//   that would go wrong: a 32 bit instruction whose first parcel is the
//   last one of a trimmed word, so that its second half would come from the
//   predicted target. That is a misfetch; the queue is thrown away and the
//   word is fetched again with the prediction suppressed.
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
        parameter int          PQ_DEPTH     = 16,     // parcels, power of two
        parameter int          BTB_ENTRIES  = 64
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
        output logic [1:0]              fq_fault,
        output logic                    fq_fault_hi, // in the second parcel
        output logic                    fq_pred_taken,
        output logic [63:0]             fq_pred_target,

        // branch target buffer, written from the execute stage
        input  logic                    btb_upd_valid,
        input  logic [63:0]             btb_upd_pc,
        input  logic                    btb_upd_is32,
        input  logic [63:0]             btb_upd_target,
        input  logic                    btb_upd_taken,
        input  logic                    btb_flush    // fence.i, sfence.vma
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
    // this parcel is the last one of a branch that was predicted taken
    logic               pq_pend  [0:PQ_DEPTH-1];
    logic [PQ_BITS-1:0] pq_head, pq_tail;
    logic [PQ_BITS:0]   pq_count;
    logic [OS_BITS:0]   os_count;

    logic push_req, push_resp, resp_real, local_resp, pop_q;
    logic req_want, fetch_bad, self_redirect;
    logic [2:0] push_n;           // parcels of this answer that are kept
    logic [1:0] keep_lo, keep_hi;

    //-----------------------------------------------------------------
    // the prediction
    //-----------------------------------------------------------------
    logic        btb_hit, btb_taken, btb_is32;
    logic [1:0]  btb_off;
    logic [63:0] btb_target;
    logic        use_pred, no_pred;
    logic [1:0]  next_start;      // first parcel of the word this fetch wants

    // one record per request that is in the cache
    logic        pr_valid  [0:OS_DEPTH-1];
    logic [1:0]  pr_last   [0:OS_DEPTH-1];
    logic [63:0] pr_target [0:OS_DEPTH-1];
    logic [OS_BITS-1:0] pr_head, pr_tail;
    logic        pred_resp;

    // the targets of the predictions whose parcels are in the queue, in the
    // order the head will meet them
    logic [63:0] tg_data [0:7];
    logic [2:0]  tg_head, tg_tail;

    // a request is issued while the queue can take four more parcels; every
    // request that is in the cache brings four
    logic [PQ_BITS+1:0] pq_inflight;
    assign pq_inflight = (PQ_BITS+2)'(pq_count) + ((PQ_BITS+2)'(os_count) << 2);
    assign req_want    = rst_n & ~redirect_valid & ~self_redirect &
                         (pq_inflight <= (PQ_BITS+2)'(PQ_DEPTH - 4));

    //-----------------------------------------------------------------
    // the branch target buffer
    //
    //   A prediction is only used when the branch it names begins at or
    //   after the first parcel this fetch wants. Without that test a branch
    //   that sits before the address a redirect jumped into would be
    //   predicted, and the parcels of the instruction that is really there
    //   would be thrown away.
    //-----------------------------------------------------------------
    CORE_BTB #(.ENTRIES(BTB_ENTRIES)) u_btb
        (
            .clk        (clk),
            .rst_n      (rst_n),
            .look_pc    (fetch_pc),
            .hit        (btb_hit),
            .hit_off    (btb_off),
            .hit_is32   (btb_is32),
            .hit_target (btb_target),
            .hit_taken  (btb_taken),
            .upd_valid  (btb_upd_valid),
            .upd_pc     (btb_upd_pc),
            .upd_is32   (btb_upd_is32),
            .upd_target (btb_upd_target),
            .upd_taken  (btb_upd_taken),
            .flush      (btb_flush)
        );

    assign use_pred = req_want & tr_ready & (tr_fault == 2'd0) &
                      btb_hit & btb_taken & ~no_pred &
                      (btb_off >= next_start);

    assign tr_req      = req_want;
    assign tr_vaddr    = fetch_pc;

    assign fetch_bad   = req_want & tr_ready & (tr_fault != 2'd0);
    assign local_resp  = fetch_bad & (os_count == '0);
    assign i_req_valid = req_want & tr_ready & (tr_fault == 2'd0);
    // the cache is indexed with the virtual address and tagged with the
    // physical one, and the two agree on the bits it indexes with
    assign i_req_addr  = fetch_pc[PADDR_WIDTH-1:0];
    assign i_kill      = redirect_valid | self_redirect;

    assign push_req  = i_req_valid & i_req_ready;
    assign resp_real = i_resp_valid & ~redirect_valid & ~self_redirect &
                       (os_count != '0);
    assign push_resp = resp_real | local_resp;

    // The parcels in front of push_pc belong to the word but not to the
    // path, and so do the ones behind a branch that was predicted taken.
    assign pred_resp = resp_real & pr_valid[pr_head];
    assign keep_lo   = push_pc[2:1];
    assign keep_hi   = pred_resp ? pr_last[pr_head] : 2'd3;
    assign push_n    = 3'(keep_hi) - 3'(keep_lo) + 3'd1;

    //-----------------------------------------------------------------
    // the instruction at the head
    //-----------------------------------------------------------------
    logic [15:0] p0, p1;
    logic [1:0]  e0, e1;
    logic        d0, d1;
    logic [PQ_BITS-1:0] head_next;
    logic        fq_have, straddle;

    assign head_next = pq_head + PQ_BITS'(1);
    assign p0 = pq_data[pq_head];
    assign p1 = pq_data[head_next];
    assign e0 = pq_fault[pq_head];
    assign e1 = pq_fault[head_next];
    assign d0 = pq_pend[pq_head];
    assign d1 = pq_pend[head_next];

    assign fq_is_rvc = (p0[1:0] != 2'b11);
    assign fq_have   = (pq_count != '0) &&
                       (fq_is_rvc || (pq_count >= (PQ_BITS+1)'(2)));

    // A 32 bit instruction whose first parcel ended a trimmed word: its
    // second half would come from the predicted target, so the queue is not
    // the instruction stream any more. Throw it away and fetch again
    // without the prediction.
    assign straddle      = fq_have & ~fq_is_rvc & d0;
    assign self_redirect = straddle;

    assign fq_valid  = fq_have & ~straddle;
    assign fq_pred_taken  = fq_is_rvc ? d0 : d1;
    assign fq_pred_target = tg_data[tg_head];
    assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p1, p0};
    // A 32 bit instruction across two pages takes the fault of whichever
    // half has one. Which half it was has to be passed on: the exception
    // reports the address that faulted, which is two bytes on when only the
    // second half did.
    assign fq_fault    = fq_is_rvc ? e0 : ((e0 != 2'd0) ? e0 : e1);
    assign fq_fault_hi = ~fq_is_rvc & (e0 == 2'd0) & (e1 != 2'd0);
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
            no_pred     <= 1'b0;
            next_start  <= 2'd0;
            pr_head     <= '0;
            pr_tail     <= '0;
            tg_head     <= 3'd0;
            tg_tail     <= 3'd0;
            for (int i = 0; i < OS_DEPTH; i++) pr_valid[i] <= 1'b0;
        end else begin
            // the cache wants the tag in the cycle after the request was
            // taken (CPU_CACHE_SPEC.md 5.6)
            if (push_req) i_req_paddr <= tr_paddr[PADDR_WIDTH-1:0];

            if (redirect_valid || self_redirect) begin
                // a misfetch keeps the address it was trying to reach and
                // only asks for it again, without a prediction this time
                fetch_pc   <= redirect_valid ? {redirect_pc[63:3], 3'b000}
                                             : {head_pc[63:3], 3'b000};
                head_pc    <= redirect_valid ? redirect_pc : head_pc;
                push_pc    <= redirect_valid ? redirect_pc : head_pc;
                next_start <= redirect_valid ? redirect_pc[2:1] : head_pc[2:1];
                no_pred    <= ~redirect_valid;
                pq_head  <= '0;
                pq_tail  <= '0;
                pq_count <= '0;
                os_count <= '0;
                pr_head  <= '0;
                pr_tail  <= '0;
                tg_head  <= 3'd0;
                tg_tail  <= 3'd0;
                for (int i = 0; i < OS_DEPTH; i++) pr_valid[i] <= 1'b0;
            end else begin
                if (push_req | local_resp) begin
                    fetch_pc   <= use_pred ? btb_target : fetch_pc + 64'd8;
                    next_start <= use_pred ? btb_target[2:1] : 2'd0;
                    no_pred    <= 1'b0;
                end

                // the record that travels with the request
                if (push_req) begin
                    pr_valid [pr_tail] <= use_pred;
                    pr_last  [pr_tail] <= btb_off + {1'b0, btb_is32};
                    pr_target[pr_tail] <= btb_target;
                    pr_tail            <= pr_tail + OS_BITS'(1);
                end
                if (resp_real) pr_head <= pr_head + OS_BITS'(1);

                if (push_resp) begin
                    for (int i = 0; i < 4; i++) begin
                        if ((2'(i) >= keep_lo) && (2'(i) <= keep_hi)) begin
                            pq_data[pq_tail + PQ_BITS'(i) - PQ_BITS'(keep_lo)]
                                <= local_resp ? 16'd0 : i_resp_data[16*i +: 16];
                            pq_fault[pq_tail + PQ_BITS'(i) - PQ_BITS'(keep_lo)]
                                <= local_resp ? tr_fault
                                              : (i_resp_error ? 2'd1 : 2'd0);
                            pq_pend[pq_tail + PQ_BITS'(i) - PQ_BITS'(keep_lo)]
                                <= pred_resp && (2'(i) == keep_hi);
                        end
                    end
                    pq_tail <= pq_tail + PQ_BITS'(push_n);
                    push_pc <= pred_resp ? pr_target[pr_head]
                                         : {push_pc[63:3], 3'b000} + 64'd8;
                    if (pred_resp) begin
                        tg_data[tg_tail] <= pr_target[pr_head];
                        tg_tail          <= tg_tail + 3'd1;
                    end
                end

                if (pop_q) begin
                    pq_head <= pq_head + (fq_is_rvc ? PQ_BITS'(1) : PQ_BITS'(2));
                    // a branch that was predicted taken carries the head to
                    // the target instead of to the instruction behind it
                    if (fq_pred_taken) begin
                        head_pc <= fq_pred_target;
                        tg_head <= tg_head + 3'd1;
                    end else begin
                        head_pc <= head_pc + (fq_is_rvc ? 64'd2 : 64'd4);
                    end
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
