//---------------------------------------------------------------------------
// CORE_RF.sv
//
// Integer register file : 32 x 64 bit, two read ports and two write ports.
//
//   - x0 always reads as zero and is never written.
//   - Write port A is the pipeline's (WB, and the debugger); write port B
//     is the FPU's, for the floating point instructions whose answer is an
//     integer (compares, FCLASS, FMV.X, FCVT to an integer), which come out
//     of FPU_PIPE on their own time (CPU_CORE_SPEC.md 10.11).
//   - A read of the register that is being written in the same cycle returns
//     the new value (write first), so an instruction in ID sees the result of
//     an instruction that is in WB. Together with the forwarding from MA and
//     WB into EX this covers every distance.
//   - Distributed RAM, one bank per write port, and a table of 32 bits that
//     says which bank holds the live value of each register (a "live value
//     table"). As flip flops each read port was a 32 to 1 multiplexer of 64
//     bits, and a second write port would have put a multiplexer in front of
//     every one of the 2048 bits. The banks are not reset (the registers
//     come up as zero when the FPGA is configured; RISC-V does not ask for
//     a value after reset).
//   - The core never writes one register through both ports in one cycle
//     (CPU_CORE keeps one writer at a time per register); if it did, B wins.
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
            bank_a[i] = 64'd0;
            bank_b[i] = 64'd0;
        end
    end

    logic wr_a, wr_b;
    assign wr_a = we   && (rd   != 5'd0);
    assign wr_b = we_b && (rd_b != 5'd0);

    always_ff @(posedge clk) begin
        if (wr_a) bank_a[rd]   <= rd_data;
        if (wr_b) bank_b[rd_b] <= rd_data_b;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lvt <= 32'd0;
        else begin
            if (wr_a) lvt[rd]   <= 1'b0;
            if (wr_b) lvt[rd_b] <= 1'b1;
        end
    end

    always @(*) begin
        if (rs1 == 5'd0)                    rs1_data = 64'd0;
        else if (wr_b && (rs1 == rd_b))     rs1_data = rd_data_b;
        else if (wr_a && (rs1 == rd))       rs1_data = rd_data;
        else                                rs1_data = lvt[rs1] ? bank_b[rs1] : bank_a[rs1];
        if (rs2 == 5'd0)                    rs2_data = 64'd0;
        else if (wr_b && (rs2 == rd_b))     rs2_data = rd_data_b;
        else if (wr_a && (rs2 == rd))       rs2_data = rd_data;
        else                                rs2_data = lvt[rs2] ? bank_b[rs2] : bank_a[rs2];
    end

endmodule : CORE_RF
