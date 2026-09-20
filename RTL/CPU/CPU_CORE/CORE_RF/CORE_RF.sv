//---------------------------------------------------------------------------
// CORE_RF.sv
//
// Integer register file : 32 x 64 bit, two read ports and one write port.
//
//   - x0 always reads as zero and is never written.
//   - A read of the register that is being written in the same cycle returns
//     the new value (write first), so an instruction in ID sees the result of
//     an instruction that is in WB. Together with the forwarding from MA and
//     WB into EX this covers every distance.
//   - Distributed RAM would need two copies; with 32 entries a flip-flop file
//     is small enough and keeps the write-first behaviour simple.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_RF
    (
        input  logic        clk,
        input  logic        rst_n,

        input  logic [4:0]  rs1,
        output logic [63:0] rs1_data,
        input  logic [4:0]  rs2,
        output logic [63:0] rs2_data,

        input  logic        we,
        input  logic [4:0]  rd,
        input  logic [63:0] rd_data
    );

    logic [63:0] regs [0:31];
    logic        wr_en;

    assign wr_en = we && (rd != 5'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) regs[i] <= 64'd0;
        end else if (wr_en) begin
            regs[rd] <= rd_data;
        end
    end

    always @(*) begin
        if (rs1 == 5'd0)                  rs1_data = 64'd0;
        else if (wr_en && (rs1 == rd))    rs1_data = rd_data;
        else                              rs1_data = regs[rs1];

        if (rs2 == 5'd0)                  rs2_data = 64'd0;
        else if (wr_en && (rs2 == rd))    rs2_data = rd_data;
        else                              rs2_data = regs[rs2];
    end

endmodule : CORE_RF
