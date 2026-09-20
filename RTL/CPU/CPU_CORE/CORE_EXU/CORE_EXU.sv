//---------------------------------------------------------------------------
// CORE_EXU.sv
//
// Execute stage : ALU, branch condition and address generation.
// Combinational; the pipeline registers live in CPU_CORE.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_EXU
    (
        // operands
        input  logic [63:0] rs1_data,
        input  logic [63:0] rs2_data,
        input  logic [63:0] pc,
        input  logic [63:0] imm,

        // control from the decoder
        input  logic [3:0]  alu_op,
        input  logic [1:0]  a_sel,
        input  logic        b_sel,
        input  logic        word_op,
        input  logic [2:0]  br_op,
        input  logic        is_branch,
        input  logic        is_jal,
        input  logic        is_jalr,
        input  logic        is_rvc,       // the instruction is 16 bit wide

        output logic [63:0] alu_result,
        output logic [63:0] link_pc,      // PC + 4, the result of JAL / JALR
        output logic [63:0] target_pc,    // branch / jump target
        output logic        take_branch,
        output logic [63:0] mem_addr      // rs1 + imm
    );

    localparam logic [3:0] ALU_ADD  = 4'd0;
    localparam logic [3:0] ALU_SUB  = 4'd1;
    localparam logic [3:0] ALU_SLL  = 4'd2;
    localparam logic [3:0] ALU_SLT  = 4'd3;
    localparam logic [3:0] ALU_SLTU = 4'd4;
    localparam logic [3:0] ALU_XOR  = 4'd5;
    localparam logic [3:0] ALU_SRL  = 4'd6;
    localparam logic [3:0] ALU_SRA  = 4'd7;
    localparam logic [3:0] ALU_OR   = 4'd8;
    localparam logic [3:0] ALU_AND  = 4'd9;

    localparam logic [1:0] A_RS1  = 2'd0;
    localparam logic [1:0] A_PC   = 2'd1;
    localparam logic [1:0] A_ZERO = 2'd2;

    logic [63:0] op_a, op_b, res;
    logic [5:0]  shamt;
    logic [63:0] sh_src;

    always @(*) begin
        case (a_sel)
            A_PC:    op_a = pc;
            A_ZERO:  op_a = 64'd0;
            default: op_a = rs1_data;
        endcase
        op_b  = b_sel ? imm : rs2_data;
        shamt = word_op ? {1'b0, op_b[4:0]} : op_b[5:0];
        // a 32 bit shift works on the zero / sign extended low half
        if (!word_op)              sh_src = op_a;
        else if (alu_op == ALU_SRA) sh_src = {{32{op_a[31]}}, op_a[31:0]};
        else                        sh_src = {32'd0, op_a[31:0]};

        case (alu_op)
            ALU_SUB:  res = op_a - op_b;
            ALU_SLL:  res = sh_src << shamt;
            ALU_SLT:  res = {63'd0, ($signed(op_a) < $signed(op_b))};
            ALU_SLTU: res = {63'd0, (op_a < op_b)};
            ALU_XOR:  res = op_a ^ op_b;
            ALU_SRL:  res = sh_src >> shamt;
            ALU_SRA:  res = $signed(sh_src) >>> shamt;
            ALU_OR:   res = op_a | op_b;
            ALU_AND:  res = op_a & op_b;
            default:  res = op_a + op_b;              // ALU_ADD
        endcase

        alu_result = word_op ? {{32{res[31]}}, res[31:0]} : res;
    end

    // branch condition
    logic eq, lt, ltu;
    assign eq  = (rs1_data == rs2_data);
    assign lt  = ($signed(rs1_data) < $signed(rs2_data));
    assign ltu = (rs1_data < rs2_data);

    always @(*) begin
        case (br_op)
            3'b000:  take_branch = is_branch &  eq;     // BEQ
            3'b001:  take_branch = is_branch & ~eq;     // BNE
            3'b100:  take_branch = is_branch &  lt;     // BLT
            3'b101:  take_branch = is_branch & ~lt;     // BGE
            3'b110:  take_branch = is_branch &  ltu;    // BLTU
            3'b111:  take_branch = is_branch & ~ltu;    // BGEU
            default: take_branch = 1'b0;
        endcase
        if (is_jal || is_jalr) take_branch = 1'b1;
    end

    assign link_pc  = pc + (is_rvc ? 64'd2 : 64'd4);
    assign mem_addr = rs1_data + imm;

    always @(*) begin
        if (is_jalr) target_pc = (rs1_data + imm) & ~64'd1;
        else         target_pc = pc + imm;             // branch, JAL
    end

endmodule : CORE_EXU
