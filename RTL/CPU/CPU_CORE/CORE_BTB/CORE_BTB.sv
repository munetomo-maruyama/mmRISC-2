//---------------------------------------------------------------------------
// CORE_BTB.sv
//
// Branch target buffer with a two bit counter per entry (CPU_CORE_SPEC.md
// 4.2). Direct mapped.
//
//   The fetch unit deals in eight byte words, so this is a fetch block
//   predictor and not an instruction one: an entry says "the word at this
//   address contains a branch whose first parcel is at `off`, and it goes
//   to `target`". One entry per word, so of two branches in the same word
//   only the one that was taken last is remembered.
//
//   A 32 bit branch whose second parcel falls into the next word is never
//   allocated. The fetch unit answers a prediction by throwing away the
//   parcels behind the branch, and for such a branch the half it needs is
//   among them.
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
        parameter int ENTRIES = 64        // power of two
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // lookup, by the address of the eight byte word being fetched
        input  logic [63:0] look_pc,
        output logic        hit,
        output logic [1:0]  hit_off,      // parcel of the branch in the word
        output logic        hit_is32,
        output logic [63:0] hit_target,
        output logic        hit_taken,    // the counter says take it

        // update, from the execute stage
        input  logic        upd_valid,
        input  logic [63:0] upd_pc,       // the address of the branch itself
        input  logic        upd_is32,
        input  logic [63:0] upd_target,
        input  logic        upd_taken,

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

    // one entry, packed : { tag, off, is32, target, cnt }
    localparam int F_CNT    = 0;
    localparam int F_TARGET = F_CNT    + 2;
    localparam int F_IS32   = F_TARGET + 64;
    localparam int F_OFF    = F_IS32   + 1;
    localparam int F_TAG    = F_OFF    + 2;
    localparam int ENT_BITS = F_TAG    + TAG_BITS;

    logic [ENTRIES-1:0]   e_valid;
    logic [ENT_BITS-1:0]  e_data [0:ENTRIES-1];

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
    assign hit_taken  = look_d[F_CNT + 1];

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

    assign upd_idx = upd_pc[TAG_LSB-1:3];
    assign upd_tag = upd_pc[63:TAG_LSB];
    assign upd_off = upd_pc[2:1];
    assign upd_d   = e_data[upd_idx];

    assign same    = e_valid[upd_idx] &&
                     (upd_d[F_TAG +: TAG_BITS] == upd_tag) &&
                     (upd_d[F_OFF +: 2] == upd_off);
    // the second parcel of this branch is in the next word
    assign spans   = upd_is32 && (upd_off == 2'b11);
    assign allow   = upd_valid && !spans;

    assign old_cnt = upd_d[F_CNT +: 2];
    assign new_cnt = upd_taken ? ((old_cnt != 2'd3) ? old_cnt + 2'd1 : 2'd3)
                               : ((old_cnt != 2'd0) ? old_cnt - 2'd1 : 2'd0);

    // an entry that is being kept only moves its target and its counter,
    // one that is being taken over is written whole
    assign wr_data = same ? { upd_d[F_TAG +: TAG_BITS], upd_d[F_OFF +: 2],
                              upd_d[F_IS32], upd_target, new_cnt }
                          : { upd_tag, upd_off, upd_is32, upd_target, 2'b10 };
    assign wr_en   = allow && (same || upd_taken);

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
