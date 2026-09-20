//---------------------------------------------------------------------------
// CORE_FRF.sv
//
// Floating point register file (CPU_CORE_SPEC.md 10.4): 32 x 64 bit,
// three read ports and one write port. The third read port is there for the
// fused multiply add, which needs rs1, rs2 and rs3 at once.
//
//   f0 is an ordinary register, unlike x0 of the integer file.
//
//   A write is visible to a read of the same cycle, so an instruction three
//   ahead in the pipeline does not need a forwarding path of its own.
//
//   On an FPGA this becomes three mirrored copies of a 32 x 64 bit
//   distributed RAM, all written with the same data.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_FRF
    (
        input  logic        clk,
        input  logic        rst_n,

        input  logic [4:0]  rs1,
        output logic [63:0] rs1_data,
        input  logic [4:0]  rs2,
        output logic [63:0] rs2_data,
        input  logic [4:0]  rs3,
        output logic [63:0] rs3_data,

        input  logic        we,
        input  logic [4:0]  rd,
        input  logic [63:0] rd_data
    );

    logic [63:0] regs [0:31];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // the canonical NaN is as good a reset value as any, and it makes
            // a register that was never written obvious in a trace
            for (int i = 0; i < 32; i++) regs[i] <= 64'h7FF8_0000_0000_0000;
        end else if (we) begin
            regs[rd] <= rd_data;
        end
    end

    always @(*) begin
        rs1_data = (we && (rs1 == rd)) ? rd_data : regs[rs1];
        rs2_data = (we && (rs2 == rd)) ? rd_data : regs[rs2];
        rs3_data = (we && (rs3 == rd)) ? rd_data : regs[rs3];
    end

endmodule : CORE_FRF
