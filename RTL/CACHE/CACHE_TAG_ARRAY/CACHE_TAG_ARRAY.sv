//---------------------------------------------------------------------------
// CACHE_TAG_ARRAY.sv
//
// Tag / valid / dirty storage of a set-associative L1 cache.
//
//   - Tags are kept in a memory array (one entry per set and way) with
//     synchronous read: rd_tag is valid one cycle after rd_en.
//   - Valid and dirty bits are kept in flip-flops, so "invalidate all" takes
//     a single cycle and the flush walk can inspect any set combinationally
//     (sc_* port) without using the read port.
//   - One read port and one write port. A read and a write of the same set in
//     the same cycle return the old tag (no forwarding).
//   - Ports carrying one value per way are packed vectors ([WAYS*W-1:0]) so
//     that both Verilator and Icarus Verilog accept them.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CACHE_TAG_ARRAY
    #(
        parameter int SETS     = 64,
        parameter int WAYS     = 4,
        parameter int TAG_BITS = 20,
        // derived; do not override
        parameter int WAY_BITS = (WAYS > 1) ? $clog2(WAYS) : 1
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // read port (result one cycle later)
        input  logic                        rd_en,
        input  logic [$clog2(SETS)-1:0]     rd_index,
        output logic [WAYS*TAG_BITS-1:0]    rd_tag,
        output logic [WAYS-1:0]             rd_valid,
        output logic [WAYS-1:0]             rd_dirty,

        // write port
        input  logic                        wr_en,
        input  logic [$clog2(SETS)-1:0]     wr_index,
        input  logic [WAY_BITS-1:0]     wr_way,
        input  logic [TAG_BITS-1:0]         wr_tag,
        input  logic                        wr_valid,
        input  logic                        wr_dirty,

        // combinational look at valid / dirty (flush walk)
        input  logic [$clog2(SETS)-1:0]     sc_index,
        output logic [WAYS-1:0]             sc_valid,
        output logic [WAYS-1:0]             sc_dirty,

        // invalidate every line (single cycle)
        input  logic                        inv_all
    );

    localparam int IDX_BITS = $clog2(SETS);

    //-----------------------------------------------------------------
    // Tag memory
    //-----------------------------------------------------------------
    logic [TAG_BITS-1:0] tag_mem [0:SETS*WAYS-1];

    always_ff @(posedge clk) begin
        if (wr_en)
            tag_mem[int'(wr_index) * WAYS + int'(wr_way)] <= wr_tag;
    end

    always_ff @(posedge clk) begin
        if (rd_en) begin
            for (int w = 0; w < WAYS; w++)
                rd_tag[w*TAG_BITS +: TAG_BITS] <= tag_mem[int'(rd_index) * WAYS + w];
        end
    end

    //-----------------------------------------------------------------
    // Valid / dirty bits
    //   Flat vectors (set * WAYS + way) so that reset and invalidate-all are
    //   single assignments; a loop with non-blocking assignments to an array
    //   is not supported by Verilator for large set counts.
    //-----------------------------------------------------------------
    logic [SETS*WAYS-1:0] valid_bit;
    logic [SETS*WAYS-1:0] dirty_bit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_bit <= '0;
            dirty_bit <= '0;
        end else if (inv_all) begin
            valid_bit <= '0;
            dirty_bit <= '0;
        end else if (wr_en) begin
            valid_bit[int'(wr_index) * WAYS + int'(wr_way)] <= wr_valid;
            dirty_bit[int'(wr_index) * WAYS + int'(wr_way)] <= wr_dirty;
        end
    end

    always_ff @(posedge clk) begin
        if (rd_en) begin
            rd_valid <= valid_bit[int'(rd_index) * WAYS +: WAYS];
            rd_dirty <= dirty_bit[int'(rd_index) * WAYS +: WAYS];
        end
    end

    assign sc_valid = valid_bit[int'(sc_index) * WAYS +: WAYS];
    assign sc_dirty = dirty_bit[int'(sc_index) * WAYS +: WAYS];

endmodule : CACHE_TAG_ARRAY
