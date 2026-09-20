//---------------------------------------------------------------------------
// CORE_DECOMP.sv
//
// The C extension: a 16 bit instruction is turned into the 32 bit one that
// means the same, so that only one decoder has to exist (CPU_CORE_SPEC.md 2).
//
//   `illegal` marks the encodings that are reserved. The HINT encodings are
//   expanded into the instruction they stand for, which writes x0 and has no
//   effect, so nothing special has to happen for them.
//
//   The floating point forms (C.FLD, C.FSD, C.FLDSP, C.FSDSP) are reserved
//   here as long as the D extension is not implemented.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_DECOMP
    (
        input  logic [15:0] insn_c,
        output logic [31:0] insn,
        output logic        illegal
    );

    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_IMM    = 7'b0010011;
    localparam logic [6:0] OP_IMM32  = 7'b0011011;
    localparam logic [6:0] OP_REG    = 7'b0110011;
    localparam logic [6:0] OP_REG32  = 7'b0111011;
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;

    // register fields
    logic [4:0] rd, rs1, rs2, rdp, rs1p, rs2p;
    assign rd   = insn_c[11:7];
    assign rs1  = insn_c[11:7];
    assign rs2  = insn_c[6:2];
    assign rdp  = {2'b01, insn_c[4:2]};
    assign rs2p = {2'b01, insn_c[4:2]};
    assign rs1p = {2'b01, insn_c[9:7]};

    // immediates
    logic [11:0] imm_addi4spn, imm_lw, imm_ld, imm_ci, imm_addi16sp;
    logic [11:0] imm_lwsp, imm_ldsp, imm_swsp, imm_sdsp;
    logic [5:0]  shamt;
    logic [20:0] imm_cj;
    logic [12:0] imm_cb;
    logic [31:0] imm_lui;

    assign imm_addi4spn = {2'b00, insn_c[10:7], insn_c[12:11], insn_c[5], insn_c[6], 2'b00};
    assign imm_lw       = {5'd0, insn_c[5], insn_c[12:10], insn_c[6], 2'b00};
    assign imm_ld       = {4'd0, insn_c[6:5], insn_c[12:10], 3'b000};
    assign imm_ci       = {{7{insn_c[12]}}, insn_c[6:2]};
    assign imm_addi16sp = {{3{insn_c[12]}}, insn_c[4:3], insn_c[5], insn_c[2],
                           insn_c[6], 4'b0000};
    assign imm_lwsp     = {4'd0, insn_c[3:2], insn_c[12], insn_c[6:4], 2'b00};
    assign imm_ldsp     = {3'd0, insn_c[4:2], insn_c[12], insn_c[6:5], 3'b000};
    assign imm_swsp     = {4'd0, insn_c[8:7], insn_c[12:9], 2'b00};
    assign imm_sdsp     = {3'd0, insn_c[9:7], insn_c[12:10], 3'b000};
    assign shamt        = {insn_c[12], insn_c[6:2]};
    assign imm_lui      = {{15{insn_c[12]}}, insn_c[6:2], 12'd0};
    assign imm_cj       = {{9{insn_c[12]}}, insn_c[12], insn_c[8], insn_c[10:9],
                           insn_c[6], insn_c[7], insn_c[2], insn_c[11],
                           insn_c[5:3], 1'b0};
    assign imm_cb       = {{4{insn_c[12]}}, insn_c[12], insn_c[6:5], insn_c[2],
                           insn_c[11:10], insn_c[4:3], 1'b0};

    // builders of the 32 bit formats
    function automatic logic [31:0] i_type(input logic [11:0] imm,
                                           input logic [4:0]  rs1_f,
                                           input logic [2:0]  f3,
                                           input logic [4:0]  rd_f,
                                           input logic [6:0]  op);
        return {imm, rs1_f, f3, rd_f, op};
    endfunction
    function automatic logic [31:0] s_type(input logic [11:0] imm,
                                           input logic [4:0]  rs2_f,
                                           input logic [4:0]  rs1_f,
                                           input logic [2:0]  f3);
        return {imm[11:5], rs2_f, rs1_f, f3, imm[4:0], OP_STORE};
    endfunction
    function automatic logic [31:0] r_type(input logic [6:0] f7,
                                           input logic [4:0] rs2_f,
                                           input logic [4:0] rs1_f,
                                           input logic [2:0] f3,
                                           input logic [4:0] rd_f,
                                           input logic [6:0] op);
        return {f7, rs2_f, rs1_f, f3, rd_f, op};
    endfunction
    function automatic logic [31:0] b_type(input logic [12:0] imm,
                                           input logic [4:0]  rs2_f,
                                           input logic [4:0]  rs1_f,
                                           input logic [2:0]  f3);
        return {imm[12], imm[10:5], rs2_f, rs1_f, f3, imm[4:1], imm[11], OP_BRANCH};
    endfunction
    function automatic logic [31:0] j_type(input logic [20:0] imm,
                                           input logic [4:0]  rd_f);
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd_f, OP_JAL};
    endfunction

    logic [2:0] funct3;
    assign funct3 = insn_c[15:13];

    always @(*) begin
        insn    = 32'd0;
        illegal = 1'b0;

        case (insn_c[1:0])
        //-------------------------------------------------------------
        2'b00: begin
            case (funct3)
                3'b000: begin                                   // C.ADDI4SPN
                    insn = i_type(imm_addi4spn, 5'd2, 3'b000, rdp, OP_IMM);
                    if (insn_c[12:5] == 8'd0) illegal = 1'b1;   // also the all zero word
                end
                3'b010: insn = i_type(imm_lw, rs1p, 3'b010, rdp, OP_LOAD);   // C.LW
                3'b011: insn = i_type(imm_ld, rs1p, 3'b011, rdp, OP_LOAD);   // C.LD
                3'b110: insn = s_type(imm_lw, rs2p, rs1p, 3'b010);           // C.SW
                3'b111: insn = s_type(imm_ld, rs2p, rs1p, 3'b011);           // C.SD
                default: illegal = 1'b1;    // C.FLD / C.FSD need D, 100 is reserved
            endcase
        end
        //-------------------------------------------------------------
        2'b01: begin
            case (funct3)
                3'b000: insn = i_type(imm_ci, rd, 3'b000, rd, OP_IMM);       // C.ADDI / C.NOP
                3'b001: begin                                                // C.ADDIW
                    insn = i_type(imm_ci, rd, 3'b000, rd, OP_IMM32);
                    if (rd == 5'd0) illegal = 1'b1;
                end
                3'b010: insn = i_type(imm_ci, 5'd0, 3'b000, rd, OP_IMM);     // C.LI
                3'b011: begin
                    if (rd == 5'd2) begin                                    // C.ADDI16SP
                        insn = i_type(imm_addi16sp, 5'd2, 3'b000, 5'd2, OP_IMM);
                        if ({insn_c[12], insn_c[6:2]} == 6'd0) illegal = 1'b1;
                    end else begin                                           // C.LUI
                        insn = {imm_lui[31:12], rd, OP_LUI};
                        if ({insn_c[12], insn_c[6:2]} == 6'd0) illegal = 1'b1;
                    end
                end
                3'b100: begin
                    case (insn_c[11:10])
                        2'b00: insn = i_type({6'b000000, shamt}, rs1p, 3'b101, rs1p, OP_IMM);
                        2'b01: insn = i_type({6'b010000, shamt}, rs1p, 3'b101, rs1p, OP_IMM);
                        2'b10: insn = i_type(imm_ci, rs1p, 3'b111, rs1p, OP_IMM);  // C.ANDI
                        default: begin
                            case ({insn_c[12], insn_c[6:5]})
                                3'b000: insn = r_type(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_REG);   // C.SUB
                                3'b001: insn = r_type(7'b0000000, rs2p, rs1p, 3'b100, rs1p, OP_REG);   // C.XOR
                                3'b010: insn = r_type(7'b0000000, rs2p, rs1p, 3'b110, rs1p, OP_REG);   // C.OR
                                3'b011: insn = r_type(7'b0000000, rs2p, rs1p, 3'b111, rs1p, OP_REG);   // C.AND
                                3'b100: insn = r_type(7'b0100000, rs2p, rs1p, 3'b000, rs1p, OP_REG32); // C.SUBW
                                3'b101: insn = r_type(7'b0000000, rs2p, rs1p, 3'b000, rs1p, OP_REG32); // C.ADDW
                                default: illegal = 1'b1;
                            endcase
                        end
                    endcase
                end
                3'b101: insn = j_type(imm_cj, 5'd0);                         // C.J
                3'b110: insn = b_type(imm_cb, 5'd0, rs1p, 3'b000);           // C.BEQZ
                default: insn = b_type(imm_cb, 5'd0, rs1p, 3'b001);          // C.BNEZ
            endcase
        end
        //-------------------------------------------------------------
        2'b10: begin
            case (funct3)
                3'b000: insn = i_type({6'b000000, shamt}, rd, 3'b001, rd, OP_IMM);  // C.SLLI
                3'b010: begin                                                // C.LWSP
                    insn = i_type(imm_lwsp, 5'd2, 3'b010, rd, OP_LOAD);
                    if (rd == 5'd0) illegal = 1'b1;
                end
                3'b011: begin                                                // C.LDSP
                    insn = i_type(imm_ldsp, 5'd2, 3'b011, rd, OP_LOAD);
                    if (rd == 5'd0) illegal = 1'b1;
                end
                3'b100: begin
                    if (insn_c[12] == 1'b0) begin
                        if (rs2 == 5'd0) begin                               // C.JR
                            insn = i_type(12'd0, rs1, 3'b000, 5'd0, OP_JALR);
                            if (rs1 == 5'd0) illegal = 1'b1;
                        end else begin                                       // C.MV
                            insn = r_type(7'b0000000, rs2, 5'd0, 3'b000, rd, OP_REG);
                        end
                    end else begin
                        if ((rs1 == 5'd0) && (rs2 == 5'd0)) begin            // C.EBREAK
                            insn = 32'h00100073;
                        end else if (rs2 == 5'd0) begin                      // C.JALR
                            insn = i_type(12'd0, rs1, 3'b000, 5'd1, OP_JALR);
                        end else begin                                       // C.ADD
                            insn = r_type(7'b0000000, rs2, rs1, 3'b000, rd, OP_REG);
                        end
                    end
                end
                3'b110: insn = s_type(imm_swsp, rs2, 5'd2, 3'b010);          // C.SWSP
                3'b111: insn = s_type(imm_sdsp, rs2, 5'd2, 3'b011);          // C.SDSP
                default: illegal = 1'b1;    // C.FLDSP / C.FSDSP need D
            endcase
        end
        //-------------------------------------------------------------
        default: illegal = 1'b1;            // not a compressed instruction
        endcase
    end

endmodule : CORE_DECOMP
