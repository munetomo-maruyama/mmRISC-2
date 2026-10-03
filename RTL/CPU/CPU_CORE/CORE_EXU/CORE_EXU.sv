//---------------------------------------------------------------------------
// CORE_EXU.sv
//
// Execute stage : ALU, branch condition and address generation.
// Combinational; the pipeline registers live in CPU_CORE.
//
// The ALU also does the bit manipulation of Zba and Zbb (CPU_CORE_SPEC.md
// 2.1). Zba is the adder and the left shift with two changes to the first
// operand in front of them: its low half zero extended (a_uw, the .uw
// forms) and a shift left by one to three (a_shift, sh1add .. sh3add).
// Zbb has operations of its own. None of this touches the branch
// comparison, the target or the address of a memory access.
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
        input  logic [4:0]  alu_op,
        input  logic        a_uw,         // rs1 : the low half, zero extended
        input  logic [1:0]  a_shift,      // rs1 : shifted left by this much
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

    localparam logic [4:0] ALU_ADD  = 5'd0;
    localparam logic [4:0] ALU_SUB  = 5'd1;
    localparam logic [4:0] ALU_SLL  = 5'd2;
    localparam logic [4:0] ALU_SLT  = 5'd3;
    localparam logic [4:0] ALU_SLTU = 5'd4;
    localparam logic [4:0] ALU_XOR  = 5'd5;
    localparam logic [4:0] ALU_SRL  = 5'd6;
    localparam logic [4:0] ALU_SRA  = 5'd7;
    localparam logic [4:0] ALU_OR   = 5'd8;
    localparam logic [4:0] ALU_AND  = 5'd9;
    // Zbb
    localparam logic [4:0] ALU_ANDN = 5'd10;
    localparam logic [4:0] ALU_ORN  = 5'd11;
    localparam logic [4:0] ALU_XNOR = 5'd12;
    localparam logic [4:0] ALU_MIN  = 5'd13;
    localparam logic [4:0] ALU_MINU = 5'd14;
    localparam logic [4:0] ALU_MAX  = 5'd15;
    localparam logic [4:0] ALU_MAXU = 5'd16;
    localparam logic [4:0] ALU_ROL  = 5'd17;
    localparam logic [4:0] ALU_ROR  = 5'd18;
    localparam logic [4:0] ALU_CLZ  = 5'd19;
    localparam logic [4:0] ALU_CTZ  = 5'd20;
    localparam logic [4:0] ALU_CPOP = 5'd21;
    localparam logic [4:0] ALU_SEXTB= 5'd22;
    localparam logic [4:0] ALU_SEXTH= 5'd23;
    localparam logic [4:0] ALU_ZEXTH= 5'd24;
    localparam logic [4:0] ALU_ORCB = 5'd25;
    localparam logic [4:0] ALU_REV8 = 5'd26;

    localparam logic [1:0] A_RS1  = 2'd0;
    localparam logic [1:0] A_PC   = 2'd1;
    localparam logic [1:0] A_ZERO = 2'd2;

    logic [63:0] op_a, op_b, res;
    logic [5:0]  shamt;
    logic [63:0] sh_src;
    logic [63:0] a_zx;            // op_a with the .uw change
    logic [63:0] a_add;           // and the sh*add shift : the adder's input
    logic [63:0] a_cnt;           // what clz / ctz / cpop count in
    logic [6:0]  n_clz, n_ctz, n_pop;
    logic [63:0] rot_l, rot_r;
    logic [31:0] a32;

    // counts over 64 bits; a 32 bit form puts its half where they see it
    function automatic logic [6:0] count_lz(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd64;
        for (int i = 0; i < 64; i++) if (v[i]) n = 7'(63 - i);
        return n;
    endfunction
    function automatic logic [6:0] count_tz(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd64;
        for (int i = 63; i >= 0; i--) if (v[i]) n = 7'(i);
        return n;
    endfunction
    function automatic logic [6:0] count_ones(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd0;
        for (int i = 0; i < 64; i++) n = n + 7'(v[i]);
        return n;
    endfunction

    always @(*) begin
        case (a_sel)
            A_PC:    op_a = pc;
            A_ZERO:  op_a = 64'd0;
            default: op_a = rs1_data;
        endcase
        op_b  = b_sel ? imm : rs2_data;
        a_zx  = a_uw ? {32'd0, op_a[31:0]} : op_a;
        a_add = a_zx << a_shift;
        shamt = word_op ? {1'b0, op_b[4:0]} : op_b[5:0];
        // a 32 bit shift works on the zero / sign extended low half
        if (!word_op)              sh_src = a_zx;
        else if (alu_op == ALU_SRA) sh_src = {{32{op_a[31]}}, op_a[31:0]};
        else                        sh_src = {32'd0, op_a[31:0]};

        // Zbb : the 32 bit forms work on the low half (a leading zero count
        // of a word starts at bit 31, a trailing one stops at 32)
        a32   = op_a[31:0];
        a_cnt = word_op ? {a32, 32'hFFFF_FFFF} : op_a;
        n_clz = count_lz(a_cnt);
        n_ctz = word_op ? count_tz({32'hFFFF_FFFF, a32}) : count_tz(op_a);
        n_pop = word_op ? count_ones({32'd0, a32}) : count_ones(op_a);
        if (word_op) begin
            rot_l = {32'd0, (a32 << shamt[4:0]) | (a32 >> (6'd32 - {1'b0, shamt[4:0]}))};
            rot_r = {32'd0, (a32 >> shamt[4:0]) | (a32 << (6'd32 - {1'b0, shamt[4:0]}))};
        end else begin
            rot_l = (op_a << shamt) | (op_a >> (7'd64 - {1'b0, shamt}));
            rot_r = (op_a >> shamt) | (op_a << (7'd64 - {1'b0, shamt}));
        end

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
            ALU_ANDN: res = op_a & ~op_b;
            ALU_ORN:  res = op_a | ~op_b;
            ALU_XNOR: res = ~(op_a ^ op_b);
            ALU_MIN:  res = ($signed(op_a) < $signed(op_b)) ? op_a : op_b;
            ALU_MINU: res = (op_a < op_b) ? op_a : op_b;
            ALU_MAX:  res = ($signed(op_a) < $signed(op_b)) ? op_b : op_a;
            ALU_MAXU: res = (op_a < op_b) ? op_b : op_a;
            ALU_ROL:  res = rot_l;
            ALU_ROR:  res = rot_r;
            ALU_CLZ:  res = {57'd0, n_clz};
            ALU_CTZ:  res = {57'd0, n_ctz};
            ALU_CPOP: res = {57'd0, n_pop};
            ALU_SEXTB:res = {{56{op_a[7]}},  op_a[7:0]};
            ALU_SEXTH:res = {{48{op_a[15]}}, op_a[15:0]};
            ALU_ZEXTH:res = {48'd0, op_a[15:0]};
            ALU_ORCB: for (int i = 0; i < 8; i++) res[8*i +: 8] = {8{|op_a[8*i +: 8]}};
            ALU_REV8: for (int i = 0; i < 8; i++) res[8*i +: 8] = op_a[8*(7-i) +: 8];
            default:  res = a_add + op_b;             // ALU_ADD, add.uw, sh*add
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
