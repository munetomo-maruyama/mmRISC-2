//---------------------------------------------------------------------------
// CORE_FRF.sv
//
// Floating point register file (CPU_CORE_SPEC.md 10.4): 32 x 64 bit,
// three read ports and two write ports. The third read port is there for
// the fused multiply add, which needs rs1, rs2 and rs3 at once.
//
//   f0 is an ordinary register, unlike x0 of the integer file.
//
//   Write port A is the pipeline's (FLW / FLD in WB, and the debugger);
//   write port B is FPU_PIPE's, whose answers come out on their own time
//   (CPU_CORE_SPEC.md 10.11).
//
//   A write is visible to a read of the same cycle, so an instruction three
//   ahead in the pipeline does not need a forwarding path of its own.
//
//   Distributed RAM, one bank per write port (three read ports each fit
//   one RAM32M per two bits), and a live value table of 32 bits that says
//   which bank holds each register (see CORE_RF). The banks are not reset;
//   they come up as the canonical NaN of a double when the FPGA is
//   configured, as the flip flop file used to after a reset.
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

        input  logic        we,             // port A
        input  logic [4:0]  rd,
        input  logic [63:0] rd_data,

        input  logic        we_b,           // port B
        input  logic [4:0]  rd_b,
        input  logic [63:0] rd_data_b
    );

    (* ram_style = "distributed" *) logic [63:0] bank_a [0:31];
    (* ram_style = "distributed" *) logic [63:0] bank_b [0:31];
    logic [31:0] lvt;                       // 1 : the value is in bank_b

    initial begin
        for (int i = 0; i < 32; i++) begin
            bank_a[i] = 64'h7FF8_0000_0000_0000;
            bank_b[i] = 64'h7FF8_0000_0000_0000;
        end
    end

    always_ff @(posedge clk) begin
        if (we)   bank_a[rd]   <= rd_data;
        if (we_b) bank_b[rd_b] <= rd_data_b;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lvt <= 32'd0;
        else begin
            if (we)   lvt[rd]   <= 1'b0;
            if (we_b) lvt[rd_b] <= 1'b1;
        end
    end

    function automatic logic [63:0] rd_port(input logic [4:0] r);
        if (we_b && (r == rd_b))  return rd_data_b;
        if (we   && (r == rd))    return rd_data;
        return lvt[r] ? bank_b[r] : bank_a[r];
    endfunction

    // always_comb: the function reads more than its argument
    always_comb begin
        rs1_data = rd_port(rs1);
        rs2_data = rd_port(rs2);
        rs3_data = rd_port(rs3);
    end

endmodule : CORE_FRF
