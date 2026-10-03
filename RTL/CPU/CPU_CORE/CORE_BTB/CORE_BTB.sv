//---------------------------------------------------------------------------
// CORE_BTB.sv
//
// Branch target buffer with a two bit counter per entry, and a gshare
// table for the direction of conditional branches (CPU_CORE_SPEC.md 4.2).
// Direct mapped.
//
//   The fetch unit deals in eight byte words, so this is a fetch block
//   predictor and not an instruction one: an entry says "the word at this
//   address contains a branch whose first parcel is at `off`, and it goes
//   to `target`". One entry per word, so of two branches in the same word
//   only the one that was taken last is remembered.
//
//   A 32 bit branch whose second parcel falls into the next word cannot be
//   predicted from the word it begins in: the fetch unit answers a
//   prediction by throwing away the parcels behind the branch, and the half
//   it needs is among them. Its entry is put on the next word instead, as a
//   "tail": the branch that began in the word before ends at parcel 0 of
//   this one. The fetch unit only uses a tail when it reached the word by
//   going on from the one before, not by jumping into it (CPU_CORE_SPEC.md
//   4.2). Before 2026-10 such branches were not predicted at all, which on
//   compressed code was half of the mispredictions (LitexSystem/docs/BENCH.md).
//
//   An entry also says whether its branch is a call (jal / jalr that writes
//   ra or t0) or a return (jalr x0 through ra or t0). The fetch unit takes
//   the target of a return from its return address stack, not from here.
//
//   The direction of a conditional branch comes from the gshare table (the
//   pattern history table, PHT): two bit counters indexed by the address of
//   the word and the global history, folded together. The history is the
//   direction of the conditional branches that have an entry (see
//   CORE_IFU), which the fetch unit keeps for its predictions and the
//   execute stage for its updates; the two agree as long as the predictions
//   were right, and a redirect makes them agree again. Jumps keep the
//   counter of their entry, which only ever says "taken" for them.
//
//   The table is held so that it maps onto the distributed RAM of the
//   fabric: one array, written at one index and read at two, with no reset
//   on it. Only the valid bits are flip flops, because reset and flush
//   clear all of them at once and a memory cannot do that. Nothing reads
//   the array unless its valid bit says the entry was written, so what the
//   memory holds out of reset never matters.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_BTB
    #(
        parameter int ENTRIES   = 64,      // power of two
        parameter int PHT_ENTRIES = 8192,  // power of two
        parameter int HIST_BITS = 12
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // lookup, by the address of the eight byte word being fetched
        input  logic [63:0] look_pc,
        input  logic [HIST_BITS-1:0] look_hist,   // the fetch unit's history
        output logic        hit,
        output logic [1:0]  hit_off,      // parcel of the branch in the word
        output logic        hit_is32,
        output logic [63:0] hit_target,
        output logic        hit_taken,    // the counter says take it
        output logic        hit_tail,     // a 32 bit branch ending at parcel 0
        output logic        hit_call,
        output logic        hit_ret,
        output logic        hit_cond,     // a conditional branch

        // update, from the execute stage
        input  logic        upd_valid,
        input  logic [63:0] upd_pc,       // the address of the branch itself
        input  logic        upd_is32,
        input  logic [63:0] upd_target,
        input  logic        upd_taken,
        input  logic        upd_call,
        input  logic        upd_ret,
        input  logic        upd_cond,     // a conditional branch (PHT update)
        input  logic [HIST_BITS-1:0] upd_hist,    // history before this branch
        output logic        upd_known,    // the entry of its word is this branch's

        // fence.i and sfence.vma can leave the entries describing code that
        // is not there any more. That is not a correctness matter -- the
        // execute stage catches a wrong prediction, and the fetch unit
        // catches a trim that lands inside an instruction -- but it costs
        // misfetches until the entries are replaced.
        input  logic        flush
    );

    localparam int IDX_BITS = (ENTRIES > 1) ? $clog2(ENTRIES) : 1;
    localparam int TAG_LSB  = 3 + IDX_BITS;
    localparam int TAG_BITS = 64 - TAG_LSB;

    // one entry, packed : { tag, off, is32, tail, call, ret, cond, target, cnt }
    localparam int F_CNT    = 0;
    localparam int F_TARGET = F_CNT    + 2;
    localparam int F_COND   = F_TARGET + 64;
    localparam int F_RET    = F_COND   + 1;
    localparam int F_CALL   = F_RET    + 1;
    localparam int F_TAIL   = F_CALL   + 1;
    localparam int F_IS32   = F_TAIL   + 1;
    localparam int F_OFF    = F_IS32   + 1;
    localparam int F_TAG    = F_OFF    + 2;
    localparam int ENT_BITS = F_TAG    + TAG_BITS;

    logic [ENTRIES-1:0]   e_valid;
    logic [ENT_BITS-1:0]  e_data [0:ENTRIES-1];

    //-----------------------------------------------------------------
    // gshare : the word address and the history, folded to an index
    //-----------------------------------------------------------------
    localparam int PHT_BITS = (PHT_ENTRIES > 1) ? $clog2(PHT_ENTRIES) : 1;

    function automatic logic [PHT_BITS-1:0] pht_index(input logic [63:0] word,
                                                      input logic [HIST_BITS-1:0] h);
        logic [PHT_BITS-1:0] x;
        x = word[3 +: PHT_BITS];
        // the history goes into the index from the top: the low bits tell
        // neighbouring words apart and are left to the address
        for (int i = 0; i < HIST_BITS; i++)
            x[PHT_BITS-1 - (i % PHT_BITS)] = x[PHT_BITS-1 - (i % PHT_BITS)] ^ h[i];
        return x;
    endfunction

    // no reset : distributed RAM, read at two indexes. It starts at weakly
    // not taken (the initial values of the memory, in the FPGA as in the
    // simulation); reset and flush leave it alone, a stale counter only
    // costs a misprediction.
    logic [1:0]          pht [0:PHT_ENTRIES-1];
    logic [PHT_BITS-1:0] pht_look_idx, pht_upd_idx;
    logic [1:0]          pht_old;
    logic                pht_look;
    initial for (int i = 0; i < PHT_ENTRIES; i++) pht[i] = 2'b10;

    //-----------------------------------------------------------------
    // lookup
    //-----------------------------------------------------------------
    logic [IDX_BITS-1:0] look_idx;
    logic [TAG_BITS-1:0] look_tag;
    logic [ENT_BITS-1:0] look_d;

    assign look_idx = look_pc[TAG_LSB-1:3];
    assign look_tag = look_pc[63:TAG_LSB];
    assign look_d   = e_data[look_idx];

    assign hit        = e_valid[look_idx] &&
                        (look_d[F_TAG +: TAG_BITS] == look_tag);
    assign hit_off    = look_d[F_OFF +: 2];
    assign hit_is32   = look_d[F_IS32];
    assign hit_target = look_d[F_TARGET +: 64];
    assign hit_cond   = look_d[F_COND];
    assign hit_taken  = look_d[F_COND] ? pht_look : look_d[F_CNT + 1];
    assign hit_tail   = look_d[F_TAIL];
    assign hit_call   = look_d[F_CALL];
    assign hit_ret    = look_d[F_RET];

    //-----------------------------------------------------------------
    // update
    //
    //   The entry belongs to the word, so an update only strengthens or
    //   weakens the entry that is already there when it is about the same
    //   branch. A taken branch that finds someone else's entry takes it
    //   over; a branch that was not taken and has no entry is not worth one.
    //-----------------------------------------------------------------
    logic [IDX_BITS-1:0] upd_idx;
    logic [TAG_BITS-1:0] upd_tag;
    logic [1:0]          upd_off;
    logic [ENT_BITS-1:0] upd_d;
    logic                same, spans, allow, wr_en;
    logic [1:0]          old_cnt, new_cnt;
    logic [ENT_BITS-1:0] wr_data;
    logic [63:0]         upd_word;
    logic [63:0]         look_word;

    assign upd_off = upd_pc[2:1];
    // the second parcel of this branch is in the next word: its entry is the
    // tail on that word
    assign spans    = upd_is32 && (upd_off == 2'b11);
    assign upd_word = spans ? ({upd_pc[63:3], 3'b000} + 64'd8) : upd_pc;
    assign upd_idx  = upd_word[TAG_LSB-1:3];
    assign upd_tag  = upd_word[63:TAG_LSB];
    assign upd_d    = e_data[upd_idx];

    assign same    = e_valid[upd_idx] &&
                     (upd_d[F_TAG +: TAG_BITS] == upd_tag) &&
                     (upd_d[F_OFF +: 2] == upd_off) &&
                     (upd_d[F_TAIL] == spans);
    assign allow   = upd_valid;
    assign upd_known = same;

    assign old_cnt = upd_d[F_CNT +: 2];
    assign new_cnt = upd_taken ? ((old_cnt != 2'd3) ? old_cnt + 2'd1 : 2'd3)
                               : ((old_cnt != 2'd0) ? old_cnt - 2'd1 : 2'd0);

    // an entry that is being kept only moves its target and its counter,
    // one that is being taken over is written whole
    assign wr_data = same ? { upd_d[F_TAG +: TAG_BITS], upd_d[F_OFF +: 2],
                              upd_d[F_IS32], upd_d[F_TAIL], upd_call, upd_ret,
                              upd_cond, upd_target, new_cnt }
                          : { upd_tag, upd_off, upd_is32, spans, upd_call, upd_ret,
                              upd_cond, upd_target, 2'b10 };
    assign wr_en   = allow && (same || upd_taken);

    // the counters of the gshare table: every conditional branch trains
    // the one its word and the history picked, with or without an entry
    assign look_word    = {look_pc[63:3], 3'b000};
    assign pht_look_idx = pht_index(look_word, look_hist);
    assign pht_look     = pht[pht_look_idx][1];
    assign pht_upd_idx  = pht_index(upd_word, upd_hist);
    assign pht_old      = pht[pht_upd_idx];

    always_ff @(posedge clk) begin
        if (upd_valid && upd_cond)
            pht[pht_upd_idx] <= upd_taken ? ((pht_old != 2'd3) ? pht_old + 2'd1 : 2'd3)
                                          : ((pht_old != 2'd0) ? pht_old - 2'd1 : 2'd0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          e_valid          <= '0;
        else if (flush)      e_valid          <= '0;
        else if (wr_en)      e_valid[upd_idx] <= 1'b1;
    end

    // no reset : this is the distributed RAM
    always_ff @(posedge clk) begin
        if (wr_en) e_data[upd_idx] <= wr_data;
    end

endmodule : CORE_BTB
