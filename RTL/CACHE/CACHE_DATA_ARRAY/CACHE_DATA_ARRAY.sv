//---------------------------------------------------------------------------
// CACHE_DATA_ARRAY.sv
//
// Data storage of a set-associative L1 cache.
//
//   - 64-bit words, one memory per way, byte write enables.
//   - Address = set * WORDS_PER_BLOCK + word offset inside the block.
//   - Synchronous read: rd_data is valid one cycle after rd_en. All ways are
//     read in parallel and returned as one packed vector.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CACHE_DATA_ARRAY
    #(
        parameter int SETS        = 64,
        parameter int WAYS        = 4,
        parameter int BLOCK_BYTES = 64,
        // derived; do not override
        parameter int ADDR_BITS   = $clog2(SETS * BLOCK_BYTES / 8),
        parameter int WAY_BITS    = (WAYS > 1) ? $clog2(WAYS) : 1
    )
    (
        input  logic                     clk,

        input  logic                     rd_en,
        input  logic [ADDR_BITS-1:0]     rd_addr,
        output logic [WAYS*64-1:0]       rd_data,

        input  logic                     wr_en,
        input  logic [WAY_BITS-1:0]  wr_way,
        input  logic [ADDR_BITS-1:0]     wr_addr,
        input  logic [63:0]              wr_data,
        input  logic [7:0]               wr_strb
    );

    localparam int WORDS_PER_BLOCK = BLOCK_BYTES / 8;
    localparam int WORDS           = SETS * WORDS_PER_BLOCK;

    logic [63:0] mem [0:WAYS-1][0:WORDS-1];

    initial begin
        for (int w = 0; w < WAYS; w++)
            for (int i = 0; i < WORDS; i++)
                mem[w][i] = 64'd0;
    end

    always_ff @(posedge clk) begin
        for (int b = 0; b < 8; b++) begin
            if (wr_en && wr_strb[b])
                mem[wr_way][wr_addr][8*b +: 8] <= wr_data[8*b +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (rd_en) begin
            for (int w = 0; w < WAYS; w++)
                rd_data[w*64 +: 64] <= mem[w][rd_addr];
        end
    end

endmodule : CACHE_DATA_ARRAY
