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

    logic                e_valid  [0:ENTRIES-1];
    logic [TAG_BITS-1:0] e_tag    [0:ENTRIES-1];
    logic [1:0]          e_off    [0:ENTRIES-1];
    logic                e_is32   [0:ENTRIES-1];
    logic [63:0]         e_target [0:ENTRIES-1];
    logic [1:0]          e_cnt    [0:ENTRIES-1];

    //-----------------------------------------------------------------
    // lookup
    //-----------------------------------------------------------------
    logic [IDX_BITS-1:0] look_idx;
    logic [TAG_BITS-1:0] look_tag;

    assign look_idx = look_pc[TAG_LSB-1:3];
    assign look_tag = look_pc[63:TAG_LSB];

    assign hit        = e_valid[look_idx] && (e_tag[look_idx] == look_tag);
    assign hit_off    = e_off[look_idx];
    assign hit_is32   = e_is32[look_idx];
    assign hit_target = e_target[look_idx];
    assign hit_taken  = e_cnt[look_idx][1];

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
    logic                same, spans, allow;

    assign upd_idx = upd_pc[TAG_LSB-1:3];
    assign upd_tag = upd_pc[63:TAG_LSB];
    assign upd_off = upd_pc[2:1];
    assign same    = e_valid[upd_idx] && (e_tag[upd_idx] == upd_tag) &&
                     (e_off[upd_idx] == upd_off);
    // the second parcel of this branch is in the next word
    assign spans   = upd_is32 && (upd_off == 2'b11);
    assign allow   = upd_valid && !spans;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ENTRIES; i++) begin
                e_valid[i]  <= 1'b0;
                e_tag[i]    <= '0;
                e_off[i]    <= 2'd0;
                e_is32[i]   <= 1'b0;
                e_target[i] <= 64'd0;
                e_cnt[i]    <= 2'd0;
            end
        end else if (flush) begin
            for (int i = 0; i < ENTRIES; i++) e_valid[i] <= 1'b0;
        end else if (allow) begin
            if (same) begin
                e_target[upd_idx] <= upd_target;
                if (upd_taken) begin
                    if (e_cnt[upd_idx] != 2'd3) e_cnt[upd_idx] <= e_cnt[upd_idx] + 2'd1;
                end else begin
                    if (e_cnt[upd_idx] != 2'd0) e_cnt[upd_idx] <= e_cnt[upd_idx] - 2'd1;
                end
            end else if (upd_taken) begin
                e_valid[upd_idx]  <= 1'b1;
                e_tag[upd_idx]    <= upd_tag;
                e_off[upd_idx]    <= upd_off;
                e_is32[upd_idx]   <= upd_is32;
                e_target[upd_idx] <= upd_target;
                e_cnt[upd_idx]    <= 2'b10;      // weakly taken
            end
        end
    end

endmodule : CORE_BTB
