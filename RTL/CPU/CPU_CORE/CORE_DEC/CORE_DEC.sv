//---------------------------------------------------------------------------
// CORE_DEC.sv
//
// mmRISC-2 instruction decoder (RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md 2).
//
//   32 bit instruction -> one uop record. Purely combinational, no state, so
//   it can be tested on its own. Extensions are added as further branches of
//   the opcode case; anything that is not decoded raises `illegal`.
//
//   M1 covers RV64I (without CSR access, which comes with the trap logic).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_DEC
    (
        input  logic [31:0] insn,

        // register operands
        output logic [4:0]  rs1,
        output logic [4:0]  rs2,
        output logic [4:0]  rd,
        output logic        use_rs1,
        output logic        use_rs2,
        output logic        we_rd,

        // ALU
        output logic [63:0] imm,
        output logic [3:0]  alu_op,
        output logic [1:0]  a_sel,        // A_RS1 / A_PC / A_ZERO
        output logic        b_sel,        // B_RS2 / B_IMM
        output logic        word_op,      // 32 bit operation, result sign extended

        // control transfer
        output logic        is_branch,
        output logic        is_jal,
        output logic        is_jalr,
        output logic [2:0]  br_op,        // funct3 of the branch

        // memory
        output logic        is_load,
        output logic        is_store,
        output logic [1:0]  mem_size,     // 0:byte 1:half 2:word 3:double
        output logic        mem_signed,

        // system
        output logic        is_fence,
        output logic        is_fence_i,
        output logic        is_ecall,
        output logic        is_ebreak,
        output logic        illegal
    );

    // ALU operations
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

    // operand A / B select
    localparam logic [1:0] A_RS1  = 2'd0;
    localparam logic [1:0] A_PC   = 2'd1;
    localparam logic [1:0] A_ZERO = 2'd2;
    localparam logic       B_RS2  = 1'b0;
    localparam logic       B_IMM  = 1'b1;

    // opcodes
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_IMM    = 7'b0010011;
    localparam logic [6:0] OP_IMM32  = 7'b0011011;
    localparam logic [6:0] OP_REG    = 7'b0110011;
    localparam logic [6:0] OP_REG32  = 7'b0111011;
    localparam logic [6:0] OP_FENCE  = 7'b0001111;
    localparam logic [6:0] OP_SYSTEM = 7'b1110011;

    logic [6:0] opcode, funct7;
    logic [2:0] funct3;

    assign opcode = insn[6:0];
    assign funct3 = insn[14:12];
    assign funct7 = insn[31:25];
    assign rs1    = insn[19:15];
    assign rs2    = insn[24:20];
    assign rd     = insn[11:7];

    // immediates
    logic [63:0] imm_i, imm_s, imm_b, imm_u, imm_j;

    assign imm_i = {{52{insn[31]}}, insn[31:20]};
    assign imm_s = {{52{insn[31]}}, insn[31:25], insn[11:7]};
    assign imm_b = {{51{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
    assign imm_u = {{32{insn[31]}}, insn[31:12], 12'd0};
    assign imm_j = {{43{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

    // shift amount checks
    logic shamt64_ok, shamt32_ok;
    assign shamt64_ok = (insn[31:26] == 6'b000000) || (insn[31:26] == 6'b010000);
    assign shamt32_ok = (funct7 == 7'b0000000)     || (funct7 == 7'b0100000);

    always @(*) begin
        use_rs1    = 1'b0;
        use_rs2    = 1'b0;
        we_rd      = 1'b0;
        imm        = 64'd0;
        alu_op     = ALU_ADD;
        a_sel      = A_RS1;
        b_sel      = B_IMM;
        word_op    = 1'b0;
        is_branch  = 1'b0;
        is_jal     = 1'b0;
        is_jalr    = 1'b0;
        br_op      = funct3;
        is_load    = 1'b0;
        is_store   = 1'b0;
        mem_size   = funct3[1:0];
        mem_signed = ~funct3[2];
        is_fence   = 1'b0;
        is_fence_i = 1'b0;
        is_ecall   = 1'b0;
        is_ebreak  = 1'b0;
        illegal    = 1'b0;

        case (opcode)
            //---------------------------------------------------------
            OP_LUI: begin
                we_rd = 1'b1;
                imm   = imm_u;
                a_sel = A_ZERO;
                b_sel = B_IMM;
            end
            OP_AUIPC: begin
                we_rd = 1'b1;
                imm   = imm_u;
                a_sel = A_PC;
                b_sel = B_IMM;
            end
            //---------------------------------------------------------
            OP_JAL: begin
                we_rd  = 1'b1;
                is_jal = 1'b1;
                imm    = imm_j;
                a_sel  = A_PC;          // result = PC + 4 (EXU adds 4)
                b_sel  = B_IMM;
            end
            OP_JALR: begin
                if (funct3 == 3'b000) begin
                    we_rd   = 1'b1;
                    is_jalr = 1'b1;
                    use_rs1 = 1'b1;
                    imm     = imm_i;
                    a_sel   = A_RS1;
                    b_sel   = B_IMM;
                end else illegal = 1'b1;
            end
            //---------------------------------------------------------
            OP_BRANCH: begin
                case (funct3)
                    3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: begin
                        is_branch = 1'b1;
                        use_rs1   = 1'b1;
                        use_rs2   = 1'b1;
                        imm       = imm_b;
                    end
                    default: illegal = 1'b1;
                endcase
            end
            //---------------------------------------------------------
            OP_LOAD: begin
                case (funct3)
                    3'b000, 3'b001, 3'b010, 3'b011, 3'b100, 3'b101, 3'b110: begin
                        is_load = 1'b1;
                        we_rd   = 1'b1;
                        use_rs1 = 1'b1;
                        imm     = imm_i;
                    end
                    default: illegal = 1'b1;
                endcase
            end
            OP_STORE: begin
                case (funct3)
                    3'b000, 3'b001, 3'b010, 3'b011: begin
                        is_store = 1'b1;
                        use_rs1  = 1'b1;
                        use_rs2  = 1'b1;
                        imm      = imm_s;
                    end
                    default: illegal = 1'b1;
                endcase
            end
            //---------------------------------------------------------
            OP_IMM: begin
                we_rd   = 1'b1;
                use_rs1 = 1'b1;
                imm     = imm_i;
                case (funct3)
                    3'b000: alu_op = ALU_ADD;                       // ADDI
                    3'b010: alu_op = ALU_SLT;                       // SLTI
                    3'b011: alu_op = ALU_SLTU;                      // SLTIU
                    3'b100: alu_op = ALU_XOR;                       // XORI
                    3'b110: alu_op = ALU_OR;                        // ORI
                    3'b111: alu_op = ALU_AND;                       // ANDI
                    3'b001: begin                                   // SLLI
                        alu_op = ALU_SLL;
                        imm    = {58'd0, insn[25:20]};
                        if (insn[31:26] != 6'b000000) illegal = 1'b1;
                    end
                    3'b101: begin                                   // SRLI / SRAI
                        alu_op = insn[30] ? ALU_SRA : ALU_SRL;
                        imm    = {58'd0, insn[25:20]};
                        if (!shamt64_ok) illegal = 1'b1;
                    end
                    default: illegal = 1'b1;
                endcase
            end
            OP_IMM32: begin
                we_rd   = 1'b1;
                use_rs1 = 1'b1;
                word_op = 1'b1;
                imm     = imm_i;
                case (funct3)
                    3'b000: alu_op = ALU_ADD;                       // ADDIW
                    3'b001: begin                                   // SLLIW
                        alu_op = ALU_SLL;
                        imm    = {59'd0, insn[24:20]};
                        if (funct7 != 7'b0000000) illegal = 1'b1;
                    end
                    3'b101: begin                                   // SRLIW / SRAIW
                        alu_op = insn[30] ? ALU_SRA : ALU_SRL;
                        imm    = {59'd0, insn[24:20]};
                        if (!shamt32_ok) illegal = 1'b1;
                    end
                    default: illegal = 1'b1;
                endcase
            end
            //---------------------------------------------------------
            OP_REG: begin
                we_rd   = 1'b1;
                use_rs1 = 1'b1;
                use_rs2 = 1'b1;
                b_sel   = B_RS2;
                case ({funct7, funct3})
                    {7'b0000000, 3'b000}: alu_op = ALU_ADD;
                    {7'b0100000, 3'b000}: alu_op = ALU_SUB;
                    {7'b0000000, 3'b001}: alu_op = ALU_SLL;
                    {7'b0000000, 3'b010}: alu_op = ALU_SLT;
                    {7'b0000000, 3'b011}: alu_op = ALU_SLTU;
                    {7'b0000000, 3'b100}: alu_op = ALU_XOR;
                    {7'b0000000, 3'b101}: alu_op = ALU_SRL;
                    {7'b0100000, 3'b101}: alu_op = ALU_SRA;
                    {7'b0000000, 3'b110}: alu_op = ALU_OR;
                    {7'b0000000, 3'b111}: alu_op = ALU_AND;
                    default: illegal = 1'b1;
                endcase
            end
            OP_REG32: begin
                we_rd   = 1'b1;
                use_rs1 = 1'b1;
                use_rs2 = 1'b1;
                b_sel   = B_RS2;
                word_op = 1'b1;
                case ({funct7, funct3})
                    {7'b0000000, 3'b000}: alu_op = ALU_ADD;         // ADDW
                    {7'b0100000, 3'b000}: alu_op = ALU_SUB;         // SUBW
                    {7'b0000000, 3'b001}: alu_op = ALU_SLL;         // SLLW
                    {7'b0000000, 3'b101}: alu_op = ALU_SRL;         // SRLW
                    {7'b0100000, 3'b101}: alu_op = ALU_SRA;         // SRAW
                    default: illegal = 1'b1;
                endcase
            end
            //---------------------------------------------------------
            OP_FENCE: begin
                case (funct3)
                    3'b000: is_fence   = 1'b1;
                    3'b001: is_fence_i = 1'b1;
                    default: illegal = 1'b1;
                endcase
            end
            OP_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    case (insn[31:20])
                        12'h000: is_ecall  = 1'b1;
                        12'h001: is_ebreak = 1'b1;
                        default: illegal   = 1'b1;   // CSR / trap return: M2
                    endcase
                end else begin
                    illegal = 1'b1;                  // CSR access: M2
                end
            end
            default: illegal = 1'b1;
        endcase

        if (illegal) begin
            we_rd    = 1'b0;
            is_load  = 1'b0;
            is_store = 1'b0;
            is_branch= 1'b0;
            is_jal   = 1'b0;
            is_jalr  = 1'b0;
        end
    end

endmodule : CORE_DEC
