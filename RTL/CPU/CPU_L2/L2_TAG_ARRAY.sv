//---------------------------------------------------------------------------
// L2_TAG_ARRAY.sv
//
// Tag storage of the L2 cache: {valid, dirty, tag} per set and way.
//
//   - One memory per way (generate), so that the memories are inferred as
//     block RAM. Unlike the L1's CACHE_TAG_ARRAY, valid and dirty are in
//     the same memory as the tag: in flip-flops, 1024 sets x 4 ways would
//     be 8192 of them, each read through a 1024 to 1 multiplexer. The price
//     is that the array cannot be cleared in one cycle; CPU_L2 walks it
//     after reset.
//   - Synchronous read of all ways: rd_* valid one cycle after rd_en.
//   - One write port; wr_way_en selects the ways written (all of them
//     during the walk). A read and a write of the same set in the same
//     cycle return the old entry (CPU_L2 never does that).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module L2_TAG_ARRAY
    #(
        parameter int SETS     = 1024,
        parameter int WAYS     = 4,
        parameter int TAG_BITS = 24,
        // derived; do not override
        parameter int IDX_BITS = $clog2(SETS)
    )
    (
        input  logic                     clk,

        input  logic                     rd_en,
        input  logic [IDX_BITS-1:0]      rd_index,
        output logic [WAYS*TAG_BITS-1:0] rd_tag,
        output logic [WAYS-1:0]          rd_valid,
        output logic [WAYS-1:0]          rd_dirty,

        input  logic [WAYS-1:0]          wr_way_en,
        input  logic [IDX_BITS-1:0]      wr_index,
        input  logic [TAG_BITS-1:0]      wr_tag,
        input  logic                     wr_valid,
        input  logic                     wr_dirty
    );

    genvar gw;
    generate
        for (gw = 0; gw < WAYS; gw++) begin : g_way
            (* ram_style = "block" *)
            logic [TAG_BITS+1:0] mem [0:SETS-1];
            logic [TAG_BITS+1:0] rd_w;

            initial begin
                rd_w = '0;
                for (int i = 0; i < SETS; i++) mem[i] = '0;
            end

            always_ff @(posedge clk) begin
                if (wr_way_en[gw]) mem[wr_index] <= {wr_valid, wr_dirty, wr_tag};
            end

            always_ff @(posedge clk) begin
                if (rd_en) rd_w <= mem[rd_index];
            end

            assign rd_valid[gw]                      = rd_w[TAG_BITS+1];
            assign rd_dirty[gw]                      = rd_w[TAG_BITS];
            assign rd_tag[gw*TAG_BITS +: TAG_BITS]   = rd_w[TAG_BITS-1:0];
        end
    endgenerate

endmodule : L2_TAG_ARRAY
