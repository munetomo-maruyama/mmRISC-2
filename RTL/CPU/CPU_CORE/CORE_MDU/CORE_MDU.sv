//---------------------------------------------------------------------------
// CORE_MDU.sv
//
// Multiply and divide unit of the M extension (CPU_CORE_SPEC.md 2).
//
//   The unit sits next to the ALU in EX and takes more than one cycle, so EX
//   waits for it. It is not pipelined: one operation at a time, which is what
//   an in order pipeline with a single issue can use anyway.
//
//   Multiply : the product is built from four unsigned 32 x 32 partial
//   products, which is what the DSP blocks of the FPGA do well, and the sign
//   is corrected afterwards:
//
//       a * b (signed) = ua * ub - (a < 0 ? ub << 64 : 0) - (b < 0 ? ua << 64 : 0)
//
//   The correction only touches the high half, and is added up while the
//   partial products are made (corr). So MUL and MULW, which want the low
//   half, are done one cycle after the start: the low half is the partial
//   products summed, straight into the result (EX waits one cycle). MULH,
//   MULHSU and MULHU sum the whole product first and subtract the
//   correction in the cycle after that (EX waits two cycles).
//
//   Divide : restoring division, one bit of the quotient per cycle. One
//   cycle after the start (S_DIVN) skips the steps whose quotient bit is
//   known to be 0, all at once with a shift: the leading zeros of the
//   dividend, and as many more as the divisor has bits less one (until then
//   the partial remainder is shorter than the divisor). What is left is
//   about the length of the quotient: bits(dividend) - bits(divisor) + 1
//   steps, at most 32 or 64. Division by zero and the one overflow case are
//   answered at once.
//
//   op is the funct3 field of the instruction:
//       0 MUL     1 MULH   2 MULHSU  3 MULHU
//       4 DIV     5 DIVU   6 REM     7 REMU
//   word_op selects the 32 bit forms (MULW, DIVW, DIVUW, REMW, REMUW).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_MDU
    (
        input  logic        clk,
        input  logic        rst_n,

        input  logic        start,        // begin, one cycle
        input  logic        kill,         // the instruction was flushed
        input  logic [2:0]  op,
        input  logic        word_op,
        input  logic [63:0] rs1_data,
        input  logic [63:0] rs2_data,

        output logic        busy,
        output logic        done,         // held until ack
        input  logic        ack,
        output logic [63:0] result
    );

    localparam logic [2:0] OP_MUL    = 3'd0;
    localparam logic [2:0] OP_MULH   = 3'd1;
    localparam logic [2:0] OP_MULHSU = 3'd2;
    localparam logic [2:0] OP_MULHU  = 3'd3;
    localparam logic [2:0] OP_DIV    = 3'd4;
    localparam logic [2:0] OP_DIVU   = 3'd5;
    localparam logic [2:0] OP_REM    = 3'd6;
    localparam logic [2:0] OP_REMU   = 3'd7;

    typedef enum logic [2:0] {S_IDLE, S_MUL, S_MULH, S_DIVN, S_DIV, S_DONE} state_t;
    state_t state;

    logic [2:0]  op_r;
    logic        word_r;

    //-----------------------------------------------------------------
    // what the operands mean for this operation
    //-----------------------------------------------------------------
    logic a_signed, b_signed;
    always @(*) begin
        case (op)
            OP_MULH:            begin a_signed = 1'b1; b_signed = 1'b1; end
            OP_MULHSU:          begin a_signed = 1'b1; b_signed = 1'b0; end
            OP_MULHU:           begin a_signed = 1'b0; b_signed = 1'b0; end
            OP_DIVU, OP_REMU:   begin a_signed = 1'b0; b_signed = 1'b0; end
            default:            begin a_signed = 1'b1; b_signed = 1'b1; end
        endcase
    end

    // the 32 bit forms work on the low half, extended the way the operation
    // reads it
    function automatic logic [63:0] prep(input logic [63:0] v,
                                         input logic        is_signed,
                                         input logic        word);
        if (!word)          return v;
        else if (is_signed) return {{32{v[31]}}, v[31:0]};
        else                return {32'd0, v[31:0]};
    endfunction

    logic [63:0] a_prep, b_prep, a_mag, b_mag, min_val;
    assign a_prep  = prep(rs1_data, a_signed, word_op);
    assign b_prep  = prep(rs2_data, b_signed, word_op);
    assign a_mag   = (a_signed & a_prep[63]) ? (~a_prep + 64'd1) : a_prep;
    assign b_mag   = (b_signed & b_prep[63]) ? (~b_prep + 64'd1) : b_prep;
    // the one dividend that has no positive counterpart
    assign min_val = word_op ? 64'hFFFF_FFFF_8000_0000 : 64'h8000_0000_0000_0000;

    //-----------------------------------------------------------------
    // multiply
    //-----------------------------------------------------------------
    logic [63:0]  pp_ll, pp_hl, pp_lh, pp_hh;
    logic [127:0] prod;
    logic [63:0]  corr;           // what the signs take off the high half
    logic [31:0]  mid_lo;
    logic [63:0]  mul_lo;

    // the low half: only the low 32 bits of the two middle products reach it
    assign mid_lo = pp_hl[31:0] + pp_lh[31:0];
    assign mul_lo = pp_ll + {mid_lo, 32'd0};

    //-----------------------------------------------------------------
    // divide
    //-----------------------------------------------------------------
    logic [127:0] acc;            // {remainder, quotient}
    logic [63:0]  divisor;
    logic [6:0]   count;
    logic         quo_neg, rem_neg;
    logic [63:0]  quo_r, rem_r;

    logic [127:0] acc_shift;
    logic [63:0]  acc_hi_next;
    logic         acc_ge;

    // the steps that can be skipped (S_DIVN). A 32 bit form has its
    // dividend in acc[63:32] (see the start).
    function automatic logic [6:0] clz64(input logic [63:0] v);
        logic [6:0] n;
        n = 7'd64;
        for (int i = 0; i < 64; i++)
            if (v[i]) n = 7'(63 - i);         // the highest one set wins
        return n;
    endfunction

    logic [6:0] dvd_lz, dvs_lz, width, skip_raw, skip;
    assign width    = word_r ? 7'd32 : 7'd64;
    assign dvd_lz   = word_r ? ((acc[63:32] == 32'd0) ? 7'd32 : clz64({acc[63:32], 32'd0}))
                             : clz64(acc[63:0]);
    assign dvs_lz   = clz64(divisor);                        // divisor is not 0
    // dvd_lz + bits(divisor) - 1 (at most 127, no wrap), leaving one step
    assign skip_raw = dvd_lz + (7'd63 - dvs_lz);
    assign skip     = (skip_raw > width - 7'd1) ? width - 7'd1 : skip_raw;

    assign acc_shift   = acc << 1;
    assign acc_ge      = (acc_shift[127:64] >= divisor);
    assign acc_hi_next = acc_ge ? (acc_shift[127:64] - divisor) : acc_shift[127:64];

    //-----------------------------------------------------------------
    // result
    //-----------------------------------------------------------------
    logic [63:0] mul_result, div_result;

    always @(*) begin
        if (op_r == OP_MUL) mul_result = word_r ? {{32{mul_lo[31]}}, mul_lo[31:0]} : mul_lo;
        else                mul_result = prod[127:64] - corr;
    end

    always @(*) begin
        if (op_r[1])  div_result = rem_r;      // REM, REMU
        else          div_result = quo_r;      // DIV, DIVU
        if (word_r)   div_result = {{32{div_result[31]}}, div_result[31:0]};
    end

    assign result = (op_r[2]) ? div_result : mul_result;
    assign done   = ((state == S_MUL) && (op_r == OP_MUL)) || (state == S_MULH) ||
                    (state == S_DONE);
    assign busy   = (state != S_IDLE) && !done;

    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            op_r    <= 3'd0;
            word_r  <= 1'b0;
            pp_ll   <= 64'd0;
            pp_hl   <= 64'd0;
            pp_lh   <= 64'd0;
            pp_hh   <= 64'd0;
            prod    <= 128'd0;
            corr    <= 64'd0;
            acc     <= 128'd0;
            divisor <= 64'd0;
            count   <= 7'd0;
            quo_neg <= 1'b0;
            rem_neg <= 1'b0;
            quo_r   <= 64'd0;
            rem_r   <= 64'd0;
        end else if (kill) begin
            state <= S_IDLE;
        end else begin
            case (state)
                //-----------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        op_r   <= op;
                        word_r <= word_op;
                        if (!op[2]) begin
                            // multiply : the four unsigned partial products
                            pp_ll <= {32'd0, a_prep[31:0]}  * {32'd0, b_prep[31:0]};
                            pp_hl <= {32'd0, a_prep[63:32]} * {32'd0, b_prep[31:0]};
                            pp_lh <= {32'd0, a_prep[31:0]}  * {32'd0, b_prep[63:32]};
                            pp_hh <= {32'd0, a_prep[63:32]} * {32'd0, b_prep[63:32]};
                            corr  <= ((a_signed & a_prep[63]) ? b_prep : 64'd0) +
                                     ((b_signed & b_prep[63]) ? a_prep : 64'd0);
                            state <= S_MUL;
                        end else if (b_prep == 64'd0) begin
                            // divide by zero : all ones and the dividend
                            quo_r <= {64{1'b1}};
                            rem_r <= a_prep;
                            state <= S_DONE;
                        end else if (a_signed && (b_prep == {64{1'b1}}) &&
                                     (a_prep == min_val)) begin
                            quo_r <= a_prep;                 // overflow
                            rem_r <= 64'd0;
                            state <= S_DONE;
                        end else begin
                            quo_neg <= a_signed & (a_prep[63] ^ b_prep[63]);
                            rem_neg <= a_signed & a_prep[63];
                            // the dividend starts where the first shift takes
                            // its top bit into the remainder
                            acc     <= word_op ? {64'd0, a_mag[31:0], 32'd0}
                                               : {64'd0, a_mag};
                            divisor <= b_mag;
                            state   <= S_DIVN;
                        end
                    end
                end
                //-----------------------------------------------------
                // MUL / MULW are done here (mul_lo); the high half goes on
                S_MUL: begin
                    if (op_r == OP_MUL) begin
                        if (ack) state <= S_IDLE;
                    end else begin
                        prod  <= {pp_hh, 64'd0} + {32'd0, pp_hl, 32'd0} +
                                 {32'd0, pp_lh, 32'd0} + {64'd0, pp_ll};
                        state <= S_MULH;
                    end
                end
                // the high half minus the correction, held until ack
                S_MULH: begin
                    if (ack) state <= S_IDLE;
                end
                //-----------------------------------------------------
                S_DIVN: begin
                    acc   <= acc << skip;
                    count <= width - skip;
                    state <= S_DIV;
                end
                S_DIV: begin
                    acc <= {acc_hi_next, acc_shift[63:1], acc_ge};
                    if (count == 7'd1) begin
                        quo_r <= quo_neg ? (~{acc_shift[63:1], acc_ge} + 64'd1)
                                         :   {acc_shift[63:1], acc_ge};
                        rem_r <= rem_neg ? (~acc_hi_next + 64'd1) : acc_hi_next;
                        state <= S_DONE;
                    end
                    count <= count - 7'd1;
                end
                //-----------------------------------------------------
                S_DONE: begin
                    if (ack) state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule : CORE_MDU
