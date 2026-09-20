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

        // multiply and divide (M)
        output logic        is_mdu,
        output logic [2:0]  mdu_op,       // funct3 of the instruction

        // memory
        output logic        is_load,      // the result comes from the cache
        output logic        is_store,     // the access changes memory
        output logic [3:0]  mem_cmd,      // command of the cache port
        output logic [1:0]  mem_size,     // 0:byte 1:half 2:word 3:double
        output logic        mem_signed,

        // system
        output logic        is_fence,
        output logic        is_fence_i,
        output logic        is_ecall,
        output logic        is_ebreak,
        output logic        is_mret,
        output logic        is_wfi,
        output logic        illegal,

        // floating point (F / D)
        output logic        is_fp,        // any instruction of F or D
        output logic        fp_arith,     // goes to the FPU
        output logic [4:0]  fp_op,        // FOP_* of CORE_FPU
        output logic        fp_fmt,       // 0 : single, 1 : double
        output logic [2:0]  fp_rm,        // the rm field of the instruction
        output logic        use_fs1,
        output logic        use_fs2,
        output logic        use_fs3,
        output logic        fp_we_rd,     // writes a floating point register
        output logic        fp_int_signed,
        output logic        fp_int_w,
        output logic        is_fp_load,
        output logic        is_fp_store,

        // CSR (Zicsr)
        output logic        is_csr,
        output logic [11:0] csr_addr,
        output logic [1:0]  csr_op,       // CSR_RW / CSR_RS / CSR_RC
        output logic        csr_imm_sel,  // the source is the uimm field
        output logic        csr_wr,       // the instruction writes the CSR
        output logic        csr_rd        // the instruction reads the CSR
    );

    // CSR operations
    localparam logic [1:0] CSR_RW = 2'd1;
    localparam logic [1:0] CSR_RS = 2'd2;
    localparam logic [1:0] CSR_RC = 2'd3;

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
    localparam logic [6:0] OP_AMO    = 7'b0101111;
    localparam logic [6:0] OP_LOADFP = 7'b0000111;
    localparam logic [6:0] OP_STOREFP= 7'b0100111;
    localparam logic [6:0] OP_MADD   = 7'b1000011;
    localparam logic [6:0] OP_MSUB   = 7'b1000111;
    localparam logic [6:0] OP_NMSUB  = 7'b1001011;
    localparam logic [6:0] OP_NMADD  = 7'b1001111;
    localparam logic [6:0] OP_FP     = 7'b1010011;

    // the operation numbers of CORE_FPU
    localparam logic [4:0] FOP_ADD     = 5'd0;
    localparam logic [4:0] FOP_SUB     = 5'd1;
    localparam logic [4:0] FOP_MUL     = 5'd2;
    localparam logic [4:0] FOP_DIV     = 5'd3;
    localparam logic [4:0] FOP_SQRT    = 5'd4;
    localparam logic [4:0] FOP_MADD    = 5'd5;
    localparam logic [4:0] FOP_MSUB    = 5'd6;
    localparam logic [4:0] FOP_NMSUB   = 5'd7;
    localparam logic [4:0] FOP_NMADD   = 5'd8;
    localparam logic [4:0] FOP_SGNJ    = 5'd9;
    localparam logic [4:0] FOP_SGNJN   = 5'd10;
    localparam logic [4:0] FOP_SGNJX   = 5'd11;
    localparam logic [4:0] FOP_MIN     = 5'd12;
    localparam logic [4:0] FOP_MAX     = 5'd13;
    localparam logic [4:0] FOP_EQ      = 5'd14;
    localparam logic [4:0] FOP_LT      = 5'd15;
    localparam logic [4:0] FOP_LE      = 5'd16;
    localparam logic [4:0] FOP_CLASS   = 5'd17;
    localparam logic [4:0] FOP_MV_X_F  = 5'd18;
    localparam logic [4:0] FOP_MV_F_X  = 5'd19;
    localparam logic [4:0] FOP_CVT_S_D = 5'd20;
    localparam logic [4:0] FOP_CVT_D_S = 5'd21;
    localparam logic [4:0] FOP_CVT_F_I = 5'd22;
    localparam logic [4:0] FOP_CVT_I_F = 5'd23;

    // commands of the cache port (CPU_CACHE_SPEC.md 5)
    localparam logic [3:0] CMD_LOAD  = 4'd0;
    localparam logic [3:0] CMD_STORE = 4'd1;
    localparam logic [3:0] CMD_LR    = 4'd2;
    localparam logic [3:0] CMD_SC    = 4'd3;

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
        is_mdu     = 1'b0;
        mdu_op     = funct3;
        is_load    = 1'b0;
        is_store   = 1'b0;
        mem_cmd    = CMD_LOAD;
        mem_size   = funct3[1:0];
        mem_signed = ~funct3[2];
        is_fence   = 1'b0;
        is_fence_i = 1'b0;
        is_ecall   = 1'b0;
        is_ebreak  = 1'b0;
        is_mret    = 1'b0;
        is_wfi     = 1'b0;
        illegal    = 1'b0;

        is_fp         = 1'b0;
        fp_arith      = 1'b0;
        fp_op         = FOP_ADD;
        fp_fmt        = insn[25];
        fp_rm         = funct3;
        use_fs1       = 1'b0;
        use_fs2       = 1'b0;
        use_fs3       = 1'b0;
        fp_we_rd      = 1'b0;
        fp_int_signed = ~insn[20];
        fp_int_w      = insn[21];
        is_fp_load    = 1'b0;
        is_fp_store   = 1'b0;

        is_csr      = 1'b0;
        csr_addr    = insn[31:20];
        csr_op      = CSR_RW;
        csr_imm_sel = funct3[2];
        // CSRRS / CSRRC with x0 (or with a zero immediate) do not write, and
        // CSRRW with x0 as the destination does not read: neither may have a
        // side effect on the CSR
        csr_wr      = 1'b0;
        csr_rd      = 1'b0;

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
                        mem_cmd = CMD_LOAD;
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
                        mem_cmd  = CMD_STORE;
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
                if (funct7 == 7'b0000001) begin
                    is_mdu = 1'b1;               // MUL .. REMU
                end else
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
                if (funct7 == 7'b0000001) begin
                    // MULW, DIVW, DIVUW, REMW, REMUW
                    if ((funct3 == 3'b000) || funct3[2]) is_mdu = 1'b1;
                    else                                 illegal = 1'b1;
                end else
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
            // A : LR / SC and the atomic memory operations. The address is
            // rs1 without an offset, and aq / rl need nothing on a single
            // hart that finishes one access before it starts the next.
            OP_AMO: begin
                if ((funct3 == 3'b010) || (funct3 == 3'b011)) begin
                    we_rd   = 1'b1;
                    use_rs1 = 1'b1;
                    use_rs2 = 1'b1;
                    is_load = 1'b1;              // rs2 is the source of the
                    is_store= 1'b1;              // access, rd takes the answer
                    case (insn[31:27])
                        5'b00010: begin                     // LR
                            mem_cmd  = CMD_LR;
                            use_rs2  = 1'b0;
                            is_store = 1'b0;
                            if (rs2 != 5'd0) illegal = 1'b1;
                        end
                        5'b00011: mem_cmd = CMD_SC;
                        5'b00001: mem_cmd = 4'd4;           // AMOSWAP
                        5'b00000: mem_cmd = 4'd5;           // AMOADD
                        5'b00100: mem_cmd = 4'd6;           // AMOXOR
                        5'b01100: mem_cmd = 4'd7;           // AMOAND
                        5'b01000: mem_cmd = 4'd8;           // AMOOR
                        5'b10000: mem_cmd = 4'd9;           // AMOMIN
                        5'b10100: mem_cmd = 4'd10;          // AMOMAX
                        5'b11000: mem_cmd = 4'd11;          // AMOMINU
                        5'b11100: mem_cmd = 4'd12;          // AMOMAXU
                        default:  illegal = 1'b1;           // AMOCAS is Zacas
                    endcase
                end else illegal = 1'b1;
            end

            //---------------------------------------------------------
            // F and D
            //---------------------------------------------------------
            OP_LOADFP: begin
                // FLW and FLD go through the ordinary load path; the answer
                // is NaN boxed by the core when it is a single
                if ((funct3 == 3'b010) || (funct3 == 3'b011)) begin
                    is_fp      = 1'b1;
                    is_fp_load = 1'b1;
                    is_load    = 1'b1;
                    mem_cmd    = CMD_LOAD;
                    fp_we_rd   = 1'b1;
                    use_rs1    = 1'b1;
                    imm        = imm_i;
                    mem_signed = 1'b0;           // a word is boxed, not extended
                    fp_fmt     = funct3[0];
                end else illegal = 1'b1;
            end
            OP_STOREFP: begin
                if ((funct3 == 3'b010) || (funct3 == 3'b011)) begin
                    is_fp       = 1'b1;
                    is_fp_store = 1'b1;
                    is_store    = 1'b1;
                    mem_cmd     = CMD_STORE;
                    use_rs1     = 1'b1;
                    use_fs2     = 1'b1;
                    imm         = imm_s;
                    fp_fmt      = funct3[0];
                end else illegal = 1'b1;
            end
            OP_MADD, OP_MSUB, OP_NMSUB, OP_NMADD: begin
                is_fp    = 1'b1;
                fp_arith = 1'b1;
                fp_we_rd = 1'b1;
                use_fs1  = 1'b1;
                use_fs2  = 1'b1;
                use_fs3  = 1'b1;
                case (opcode)
                    OP_MADD:  fp_op = FOP_MADD;
                    OP_MSUB:  fp_op = FOP_MSUB;
                    OP_NMSUB: fp_op = FOP_NMSUB;
                    default:  fp_op = FOP_NMADD;
                endcase
                if (insn[26]) illegal = 1'b1;    // only single and double
            end
            OP_FP: begin
                is_fp    = 1'b1;
                fp_arith = 1'b1;
                use_fs1  = 1'b1;
                use_fs2  = 1'b1;
                fp_we_rd = 1'b1;
                if (insn[26]) illegal = 1'b1;    // only single and double
                case (funct7[6:2])
                    5'b00000: fp_op = FOP_ADD;
                    5'b00001: fp_op = FOP_SUB;
                    5'b00010: fp_op = FOP_MUL;
                    5'b00011: fp_op = FOP_DIV;
                    5'b01011: begin
                        fp_op   = FOP_SQRT;
                        use_fs2 = 1'b0;
                        if (rs2 != 5'd0) illegal = 1'b1;
                    end
                    5'b00100: begin
                        case (funct3)
                            3'b000:  fp_op = FOP_SGNJ;
                            3'b001:  fp_op = FOP_SGNJN;
                            3'b010:  fp_op = FOP_SGNJX;
                            default: illegal = 1'b1;
                        endcase
                        fp_rm = 3'b000;          // no rounding takes place
                    end
                    5'b00101: begin
                        case (funct3)
                            3'b000:  fp_op = FOP_MIN;
                            3'b001:  fp_op = FOP_MAX;
                            default: illegal = 1'b1;
                        endcase
                        fp_rm = 3'b000;
                    end
                    5'b01000: begin              // between the two formats
                        use_fs2 = 1'b0;
                        if (insn[25]) begin      // FCVT.D.S : source single
                            fp_op  = FOP_CVT_D_S;
                            fp_fmt = 1'b0;
                            if (rs2 != 5'd0) illegal = 1'b1;
                        end else begin           // FCVT.S.D : source double
                            fp_op  = FOP_CVT_S_D;
                            fp_fmt = 1'b1;
                            if (rs2 != 5'd1) illegal = 1'b1;
                        end
                    end
                    5'b10100: begin              // the comparisons
                        case (funct3)
                            3'b010:  fp_op = FOP_EQ;
                            3'b001:  fp_op = FOP_LT;
                            3'b000:  fp_op = FOP_LE;
                            default: illegal = 1'b1;
                        endcase
                        fp_we_rd = 1'b0;
                        we_rd    = 1'b1;
                        fp_rm    = 3'b000;
                    end
                    5'b11000: begin              // floating point -> integer
                        fp_op    = FOP_CVT_I_F;
                        use_fs2  = 1'b0;
                        fp_we_rd = 1'b0;
                        we_rd    = 1'b1;
                        if (rs2[4:2] != 3'b000) illegal = 1'b1;
                    end
                    5'b11010: begin              // integer -> floating point
                        fp_op   = FOP_CVT_F_I;
                        use_fs1 = 1'b0;
                        use_fs2 = 1'b0;
                        use_rs1 = 1'b1;
                        if (rs2[4:2] != 3'b000) illegal = 1'b1;
                    end
                    5'b11100: begin
                        use_fs2  = 1'b0;
                        fp_we_rd = 1'b0;
                        we_rd    = 1'b1;
                        fp_rm    = 3'b000;
                        case (funct3)
                            3'b000:  fp_op = FOP_MV_X_F;
                            3'b001:  fp_op = FOP_CLASS;
                            default: illegal = 1'b1;
                        endcase
                        if (rs2 != 5'd0) illegal = 1'b1;
                    end
                    5'b11110: begin
                        fp_op   = FOP_MV_F_X;
                        use_fs1 = 1'b0;
                        use_fs2 = 1'b0;
                        use_rs1 = 1'b1;
                        fp_rm   = 3'b000;
                        if ((rs2 != 5'd0) || (funct3 != 3'b000)) illegal = 1'b1;
                    end
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
                case (funct3)
                    3'b000: begin
                        case (insn[31:20])
                            12'h000: is_ecall  = 1'b1;
                            12'h001: is_ebreak = 1'b1;
                            12'h302: is_mret   = 1'b1;
                            12'h105: is_wfi    = 1'b1;
                            // SRET, SFENCE.VMA and the debug return come with
                            // the supervisor mode (M5) and the debug mode
                            default: illegal   = 1'b1;
                        endcase
                        // the register fields of these have to be zero
                        if ((rs1 != 5'd0) || (rd != 5'd0)) illegal = 1'b1;
                    end
                    3'b100: illegal = 1'b1;
                    default: begin                   // CSRRW/S/C and the immediate forms
                        is_csr  = 1'b1;
                        we_rd   = 1'b1;
                        use_rs1 = ~funct3[2];
                        case (funct3[1:0])
                            2'b01:   csr_op = CSR_RW;
                            2'b10:   csr_op = CSR_RS;
                            default: csr_op = CSR_RC;
                        endcase
                        // rs1 (or the immediate) being zero means no write for
                        // the set and clear forms; the write form always writes
                        csr_wr = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
                        csr_rd = (funct3[1:0] != 2'b01) || (rd  != 5'd0);
                    end
                endcase
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
