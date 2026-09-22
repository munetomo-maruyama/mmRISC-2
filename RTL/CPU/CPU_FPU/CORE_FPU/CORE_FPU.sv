//---------------------------------------------------------------------------
// CORE_FPU.sv
//
// Floating point unit of the F and D extensions (CPU_CORE_SPEC.md 10).
//
//   The unit is asked for one operation at a time and answers when it is
//   done, like CORE_MDU: EX waits for it. Floating point arithmetic in
//   RISC-V does not trap, so nothing about the precise exceptions of the
//   pipeline depends on where the answer appears.
//
//   Single precision values live in a 64 bit register NaN boxed (the upper
//   half is all ones). A source of a single precision operation that is not
//   boxed reads as the canonical NaN, which is what the specification asks
//   for.
//
//   Everything that rounds ends in FPU_ROUND, so the subnormal handling and
//   the overflow / underflow flags exist exactly once.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_FPU
    (
        input  logic        clk,
        input  logic        rst_n,

        input  logic        start,        // begin, one cycle
        input  logic        kill,         // the instruction was flushed
        input  logic [4:0]  op,
        input  logic        fmt,          // 0 : single, 1 : double
        input  logic [2:0]  rm,           // already resolved (never 111)
        input  logic        int_signed,   // conversions with an integer side
        input  logic        int_w,        // 0 : 32 bit, 1 : 64 bit
        input  logic [63:0] a,            // rs1 (or the integer for CVT)
        input  logic [63:0] b,            // rs2
        input  logic [63:0] c,            // rs3

        output logic        busy,
        output logic        done,         // held until ack
        input  logic        ack,
        output logic [63:0] result,
        output logic        result_is_int,
        output logic [4:0]  flags         // NV DZ OF UF NX
    );

    //-----------------------------------------------------------------
    // operations
    //-----------------------------------------------------------------
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
    localparam logic [4:0] FOP_MV_X_F  = 5'd18;   // the bits of an FP register
    localparam logic [4:0] FOP_MV_F_X  = 5'd19;
    localparam logic [4:0] FOP_CVT_S_D = 5'd20;   // double -> single
    localparam logic [4:0] FOP_CVT_D_S = 5'd21;   // single -> double
    localparam logic [4:0] FOP_CVT_F_I = 5'd22;   // integer -> floating point
    localparam logic [4:0] FOP_CVT_I_F = 5'd23;   // floating point -> integer

    localparam logic [2:0]  RM_RDN_L = 3'b010;

    localparam logic [63:0] QNAN64 = 64'h7FF8_0000_0000_0000;
    localparam logic [63:0] QNAN32 = {32'hFFFF_FFFF, 32'h7FC0_0000};

    // flags
    localparam int F_NX = 0;
    localparam int F_UF = 1;
    localparam int F_OF = 2;
    localparam int F_DZ = 3;
    localparam int F_NV = 4;

    //=================================================================
    // unpacking
    //=================================================================
    // A value is taken apart into sign, unbiased exponent and a significand
    // normalised so that its leading one sits at bit 63, which is what
    // FPU_ROUND wants to see.
    //
    //   is_nan / is_snan / is_inf / is_zero say what kind of value it is;
    //   for those the exponent and the significand mean nothing.

    // leading zeros; a function with an output port is not portable, so the
    // shift is returned and the caller applies it
    function automatic int clz64(input logic [63:0] v);
        for (int i = 0; i < 64; i++)
            if (v[63-i]) return i;
        return 64;
    endfunction

    // the raw fields of the format
    task automatic unpack(input logic [63:0] v, input logic f,
                          output logic        o_sign,
                          output int signed   o_exp,
                          output logic [63:0] o_sig,
                          output logic        o_zero,
                          output logic        o_inf,
                          output logic        o_nan,
                          output logic        o_snan);
        logic [63:0] raw;
        logic [11:0] ex;
        logic [63:0] fr, nrm;
        int          ew, pw, bs, sh;
        logic        boxed;
        begin
            boxed = f | (&v[63:32]);
            raw   = v;
            if (!f && !boxed) begin
                // not NaN boxed : the value is the canonical NaN
                o_sign = 1'b0; o_exp = 0; o_sig = 64'd0;
                o_zero = 1'b0; o_inf = 1'b0; o_nan = 1'b1; o_snan = 1'b0;
            end else begin
                if (f) begin
                    ew = 11; pw = 52; bs = 1023;
                    o_sign = raw[63];
                    ex     = {1'b0, raw[62:52]};
                    fr     = {12'd0, raw[51:0]};
                end else begin
                    ew = 8;  pw = 23; bs = 127;
                    o_sign = raw[31];
                    ex     = {4'd0, raw[30:23]};
                    fr     = {41'd0, raw[22:0]};
                end
                o_zero = 1'b0; o_inf = 1'b0; o_nan = 1'b0; o_snan = 1'b0;
                o_exp  = 0;    o_sig = 64'd0;
                if (ex == 12'd0) begin
                    if (fr == 64'd0) begin
                        o_zero = 1'b1;
                    end else begin
                        // Subnormal: normalise it. After the shift the
                        // significand is fraction * 2^(64-pw+sh) and the
                        // value is fraction * 2^(1-bias-pw), so with
                        // value = sig * 2^(exp-63) the exponent is -bias-sh.
                        nrm   = fr << (64 - pw);
                        sh    = clz64(nrm);
                        o_sig = nrm << sh;
                        o_exp = -bs - sh;
                    end
                end else if (int'(ex) == ((1 << ew) - 1)) begin
                    if (fr == 64'd0) o_inf = 1'b1;
                    else begin
                        o_nan  = 1'b1;
                        // the top bit of the fraction tells quiet from signalling
                        o_snan = ~fr[pw-1];
                    end
                end else begin
                    o_sig = {1'b1, 63'd0} | (fr << (63 - pw));
                    o_exp = int'(ex) - bs;
                end
            end
        end
    endtask

    //=================================================================
    // the operands, held for as long as the operation lasts
    //
    //   EX keeps them steady while the unit is busy, but it holds them
    //   through the forwarding multiplexers of the pipeline, so without a
    //   copy of its own every path into this unit starts at a writeback
    //   register and runs through those multiplexers and the unpacking
    //   before it reaches anything. Taking the copy at `start` puts a flip
    //   flop in front of all of that. The first cycle still needs the live
    //   value -- that is when the partial products are taken and when the
    //   special cases decide which way to go -- so the copy is bypassed
    //   exactly then.
    //=================================================================
    logic [63:0] q_a, q_b, q_c;
    logic [63:0] u_a, u_b, u_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_a <= 64'd0;
            q_b <= 64'd0;
            q_c <= 64'd0;
        end else if (start) begin
            q_a <= a;
            q_b <= b;
            q_c <= c;
        end
    end

    assign u_a = start ? a : q_a;
    assign u_b = start ? b : q_b;
    assign u_c = start ? c : q_c;

    // The operand as an operation sees it. Everything except the transfer
    // instructions (FLW/FSW, FMV.W.X, FMV.X.W) reads a single that is not
    // NaN boxed as the canonical NaN.
    logic [63:0] a_cval, b_cval;
    assign a_cval = (fmt | (&u_a[63:32])) ? u_a : QNAN32;
    assign b_cval = (fmt | (&u_b[63:32])) ? u_b : QNAN32;

    logic        a_sign, a_zero, a_inf, a_nan, a_snan;
    logic        b_sign, b_zero, b_inf, b_nan, b_snan;
    int signed   a_exp, b_exp;
    logic [63:0] a_sig, b_sig;

    logic        c_sign, c_zero, c_inf, c_nan, c_snan;
    int signed   c_exp;
    logic [63:0] c_sig;
    logic [63:0] c_cval;
    assign c_cval = (fmt | (&u_c[63:32])) ? u_c : QNAN32;

    // The sensitivity list is written out on purpose. `unpack` is a task
    // with output arguments, and with @(*) Icarus Verilog puts those outputs
    // into the list as well, so the block keeps waking itself up; the whole
    // core then runs about a thousand times slower. The task reads nothing
    // but its two inputs, so naming them is exact as well as portable.
    always @(u_a, fmt) unpack(u_a, fmt, a_sign, a_exp, a_sig, a_zero, a_inf, a_nan, a_snan);
    always @(u_b, fmt) unpack(u_b, fmt, b_sign, b_exp, b_sig, b_zero, b_inf, b_nan, b_snan);
    always @(u_c, fmt) unpack(u_c, fmt, c_sign, c_exp, c_sig, c_zero, c_inf, c_nan, c_snan);

    //=================================================================
    // the rounder, shared by everything that rounds
    //=================================================================
    logic               rnd_sign;
    logic signed [13:0] rnd_exp;
    logic [127:0]       rnd_sig;
    logic               rnd_sticky;
    logic               rnd_fmt;
    logic [63:0]        rnd_result;
    logic [4:0]         rnd_flags;

    // The rounder is given registered inputs. Selecting what it is to round
    // and rounding it are each about half of the longest path of this unit,
    // and one cycle cannot hold both.
    logic               q_rnd_sign, q_rnd_sticky, q_rnd_fmt;
    logic signed [13:0] q_rnd_exp;
    logic [127:0]       q_rnd_sig;

    FPU_ROUND u_round
        (
            .sign   (q_rnd_sign),
            .exp_in (q_rnd_exp),
            .sig_in (q_rnd_sig),
            .sticky_in (q_rnd_sticky),
            .fmt    (q_rnd_fmt),
            .rm     (rm),
            .result (rnd_result),
            .flags  (rnd_flags)
        );

    //=================================================================
    // sign injection, moves
    //=================================================================
    logic [63:0] sgnj_res;
    logic        sgn_a, sgn_b, sgn_new;

    always @(*) begin
        sgn_a = fmt ? a_cval[63] : a_cval[31];
        sgn_b = fmt ? b_cval[63] : b_cval[31];
        case (op)
            FOP_SGNJN: sgn_new = ~sgn_b;
            FOP_SGNJX: sgn_new = sgn_a ^ sgn_b;
            default:   sgn_new = sgn_b;
        endcase
        if (fmt) sgnj_res = {sgn_new, a_cval[62:0]};
        else     sgnj_res = {32'hFFFF_FFFF, sgn_new, a_cval[30:0]};
    end

    //=================================================================
    // comparisons
    //=================================================================
    logic cmp_eq, cmp_lt, cmp_unordered, cmp_res;
    logic [4:0] cmp_flags;

    always @(*) begin
        cmp_unordered = a_nan | b_nan;
        cmp_eq = (a_zero & b_zero) |
                 (~a_zero & ~b_zero & ~a_inf & ~b_inf & (a_sign == b_sign) &&
                  (a_exp == b_exp) && (a_sig == b_sig)) |
                 (a_inf & b_inf & (a_sign == b_sign));
        if (a_zero && b_zero)            cmp_lt = 1'b0;
        else if (a_sign != b_sign)       cmp_lt = a_sign & ~(a_zero & b_zero);
        else if (a_inf && b_inf)         cmp_lt = 1'b0;
        else if (a_inf)                  cmp_lt = a_sign;
        else if (b_inf)                  cmp_lt = ~b_sign;
        else if (a_zero)                 cmp_lt = ~b_sign;
        else if (b_zero)                 cmp_lt = a_sign;
        else if (a_exp != b_exp)         cmp_lt = (a_exp < b_exp) ^ a_sign;
        // equal significands are not "less than", so the sign trick only
        // applies when they differ
        else                             cmp_lt = (a_sig != b_sig) &
                                                  ((a_sig < b_sig) ^ a_sign);

        cmp_res   = 1'b0;
        cmp_flags = 5'd0;
        case (op)
            FOP_EQ: begin
                cmp_res = ~cmp_unordered & cmp_eq;
                // FEQ is quiet : only a signalling NaN is invalid
                if (a_snan | b_snan) cmp_flags[F_NV] = 1'b1;
            end
            FOP_LT: begin
                cmp_res = ~cmp_unordered & cmp_lt;
                if (a_nan | b_nan) cmp_flags[F_NV] = 1'b1;
            end
            default: begin              // FOP_LE
                cmp_res = ~cmp_unordered & (cmp_lt | cmp_eq);
                if (a_nan | b_nan) cmp_flags[F_NV] = 1'b1;
            end
        endcase
    end

    //=================================================================
    // minimum and maximum
    //=================================================================
    logic [63:0] minmax_res;
    logic [4:0]  minmax_flags;
    logic        take_b;

    always @(*) begin
        minmax_flags = 5'd0;
        if (a_snan | b_snan) minmax_flags[F_NV] = 1'b1;

        // -0 is smaller than +0, and a NaN loses against a number
        if      (a_zero && b_zero && (a_sign != b_sign))
            take_b = (op == FOP_MIN) ? b_sign : a_sign;
        else if (op == FOP_MIN) take_b = ~cmp_lt;
        else                    take_b =  cmp_lt;

        if (a_nan && b_nan)      minmax_res = fmt ? QNAN64 : QNAN32;
        else if (a_nan)          minmax_res = b_cval;
        else if (b_nan)          minmax_res = a_cval;
        else                     minmax_res = take_b ? b_cval : a_cval;
        if (!fmt && !(a_nan && b_nan))
            minmax_res = {32'hFFFF_FFFF, minmax_res[31:0]};
    end

    //=================================================================
    // classify
    //=================================================================
    logic [63:0] class_res;
    logic        a_sub;

    always @(*) begin
        a_sub = ~a_zero & ~a_inf & ~a_nan &
                (fmt ? (a_cval[62:52] == 11'd0) : (a_cval[30:23] == 8'd0));
        class_res = 64'd0;
        if      (a_inf  &&  a_sign)              class_res[0] = 1'b1;
        else if (!a_nan && !a_inf && !a_zero && a_sign && !a_sub) class_res[1] = 1'b1;
        else if (a_sub  &&  a_sign)              class_res[2] = 1'b1;
        else if (a_zero &&  a_sign)              class_res[3] = 1'b1;
        else if (a_zero && !a_sign)              class_res[4] = 1'b1;
        else if (a_sub  && !a_sign)              class_res[5] = 1'b1;
        else if (!a_nan && !a_inf && !a_zero && !a_sign && !a_sub) class_res[6] = 1'b1;
        else if (a_inf  && !a_sign)              class_res[7] = 1'b1;
        else if (a_snan)                         class_res[8] = 1'b1;
        else                                     class_res[9] = 1'b1;
    end

    //=================================================================
    // conversions
    //=================================================================
    // integer -> floating point
    logic [63:0] i2f_mag;
    logic        i2f_sign;
    logic [63:0] i2f_norm;
    int          i2f_shift;
    logic        i2f_zero;

    always @(*) begin
        logic [63:0] v;
        v = int_w ? u_a : (int_signed ? {{32{u_a[31]}}, u_a[31:0]} : {32'd0, u_a[31:0]});
        i2f_sign = int_signed & v[63];
        i2f_mag  = i2f_sign ? (~v + 64'd1) : v;
        i2f_zero = (i2f_mag == 64'd0);
        i2f_shift = clz64(i2f_mag);
        i2f_norm  = i2f_mag << i2f_shift;
    end

    // floating point -> integer
    logic [63:0] f2i_res;
    logic [4:0]  f2i_flags;

    always @(*) begin
        logic [127:0] wide;
        logic [63:0]  ival;
        logic         g, s, inc_i, ovf;
        int signed    sh;
        logic [63:0]  lim_max, lim_min;
        int           iw;

        iw      = int_w ? 64 : 32;
        lim_max = int_signed ? ((64'd1 << (iw-1)) - 64'd1)
                             : (int_w ? {64{1'b1}} : 64'h0000_0000_FFFF_FFFF);
        lim_min = int_signed ? (64'd1 << (iw-1)) : 64'd0;   // magnitude of the min

        f2i_res   = 64'd0;
        f2i_flags = 5'd0;
        ovf       = 1'b0;
        ival      = 64'd0;
        wide      = 128'd0;
        sh        = 0;
        inc_i     = 1'b0;
        g = 1'b0; s = 1'b0;

        if (a_nan) begin
            f2i_res         = lim_max;
            f2i_flags[F_NV] = 1'b1;
        end else if (a_inf) begin
            f2i_res         = a_sign ? (int_signed ? (~lim_min + 64'd1) : 64'd0)
                                     : lim_max;
            f2i_flags[F_NV] = 1'b1;
        end else if (a_zero) begin
            f2i_res = 64'd0;
        end else begin
            // the significand has its leading one at bit 63; an exponent of
            // 63 therefore means the value is already an integer
            sh = 63 - a_exp;
            if (sh <= 0) begin
                // far too large, unless it is exactly the most negative value
                wide = {64'd0, a_sig} << (-sh);
                ival = wide[63:0];
                ovf  = (-sh > 0) || 1'b0;
                if (wide[127:64] != 64'd0) ovf = 1'b1;
            end else if (sh >= 64) begin
                ival = 64'd0;
                g    = (sh == 64) ? a_sig[63] : 1'b0;
                s    = (sh == 64) ? (|a_sig[62:0]) : 1'b1;
            end else begin
                ival = a_sig >> sh;
                g    = a_sig[sh-1];
                s    = |(a_sig & ((64'd1 << (sh-1)) - 64'd1));
            end

            case (rm)
                3'b000:  inc_i = g & (s | ival[0]);
                3'b001:  inc_i = 1'b0;
                3'b010:  inc_i =  a_sign & (g | s);
                3'b011:  inc_i = ~a_sign & (g | s);
                3'b100:  inc_i = g;
                default: inc_i = 1'b0;
            endcase
            if (inc_i) begin
                if (ival == {64{1'b1}}) ovf = 1'b1;
                ival = ival + 64'd1;
            end

            if (a_sign && !int_signed && (ival != 64'd0)) ovf = 1'b1;
            if (!a_sign && (ival > lim_max))              ovf = 1'b1;
            if (a_sign && int_signed && (ival > lim_min)) ovf = 1'b1;

            if (ovf) begin
                f2i_res         = a_sign ? (int_signed ? (~lim_min + 64'd1) : 64'd0)
                                         : lim_max;
                f2i_flags[F_NV] = 1'b1;
            end else begin
                f2i_res         = a_sign ? (~ival + 64'd1) : ival;
                f2i_flags[F_NX] = g | s;
            end
        end

        // a 32 bit result is sign extended into the register
        if (!int_w) f2i_res = {{32{f2i_res[31]}}, f2i_res[31:0]};
    end


    //=================================================================
    // multiply and add : a * b + c
    //
    //   FADD, FSUB, FMUL and the four fused forms all run through this one
    //   datapath. The product and the addend are brought into a common frame
    //   of 128 bits and added exactly, so the result is rounded once, which
    //   is what "fused" means and what a separate adder and multiplier could
    //   not do.
    //
    //     x = rs1 (negated for FNMSUB / FNMADD)
    //     y = rs2, or 1.0 for FADD / FSUB
    //     z = the addend: rs2 for FADD / FSUB, rs3 for the fused forms,
    //         negated for FSUB / FMSUB / FNMADD; absent for FMUL
    //=================================================================
    logic        is_fma_op, y_is_one, has_z, z_from_c, x_neg, z_neg;

    always @(*) begin
        is_fma_op = (op <= FOP_NMADD) && (op != FOP_DIV) && (op != FOP_SQRT);
        y_is_one  = (op == FOP_ADD) || (op == FOP_SUB);
        has_z     = (op != FOP_MUL);
        z_from_c  = (op >= FOP_MADD) && (op <= FOP_NMADD);
        x_neg     = (op == FOP_NMSUB) || (op == FOP_NMADD);
        z_neg     = (op == FOP_SUB)   || (op == FOP_MSUB) || (op == FOP_NMADD);
    end

    logic        x_sign, x_zero, x_inf, x_nan, x_snan;
    logic        y_sign, y_zero, y_inf, y_nan, y_snan;
    logic        zz_sign, zz_zero, zz_inf, zz_nan, zz_snan;
    int signed   x_exp, y_exp, zz_exp;
    logic [63:0] x_sig, y_sig, zz_sig;
    logic [63:0] z_packed;

    always @(*) begin
        x_sign = a_sign ^ x_neg;
        x_exp  = a_exp;  x_sig = a_sig;
        x_zero = a_zero; x_inf = a_inf; x_nan = a_nan; x_snan = a_snan;

        if (y_is_one) begin
            y_sign = 1'b0; y_exp = 0; y_sig = {1'b1, 63'd0};
            y_zero = 1'b0; y_inf = 1'b0; y_nan = 1'b0; y_snan = 1'b0;
        end else begin
            y_sign = b_sign; y_exp = b_exp; y_sig = b_sig;
            y_zero = b_zero; y_inf = b_inf; y_nan = b_nan; y_snan = b_snan;
        end

        if (z_from_c) begin
            zz_sign = c_sign ^ z_neg; zz_exp = c_exp; zz_sig = c_sig;
            zz_zero = c_zero; zz_inf = c_inf; zz_nan = c_nan; zz_snan = c_snan;
            z_packed = fmt ? {c_cval[63] ^ z_neg, c_cval[62:0]}
                           : {32'hFFFF_FFFF, c_cval[31] ^ z_neg, c_cval[30:0]};
        end else begin
            zz_sign = b_sign ^ z_neg; zz_exp = b_exp; zz_sig = b_sig;
            zz_zero = b_zero; zz_inf = b_inf; zz_nan = b_nan; zz_snan = b_snan;
            z_packed = fmt ? {b_cval[63] ^ z_neg, b_cval[62:0]}
                           : {32'hFFFF_FFFF, b_cval[31] ^ z_neg, b_cval[30:0]};
        end
    end

    // the sign a zero result gets: minus only when both sides are minus, or
    // when rounding goes towards minus infinity
    logic zero_sign, zsum_sign;
    assign zero_sign = (rm == RM_RDN_L) ? 1'b1 : 1'b0;
    assign zsum_sign = (!has_z)                    ? prod_sign :
                       (prod_sign == zz_sign)      ? prod_sign : zero_sign;

    //-----------------------------------------------------------------
    // the cases that never reach the datapath
    //-----------------------------------------------------------------
    logic        fma_special, prod_inf, prod_zero, prod_sign;
    logic [63:0] fma_sp_res;
    logic [4:0]  fma_sp_flags;

    assign prod_sign = x_sign ^ y_sign;
    assign prod_inf  = (x_inf & ~y_zero) | (y_inf & ~x_zero);
    assign prod_zero = (x_zero | y_zero) & ~x_inf & ~y_inf;

    always @(*) begin
        fma_special  = 1'b1;
        fma_sp_res   = fmt ? QNAN64 : QNAN32;
        fma_sp_flags = 5'd0;

        if ((x_inf & y_zero) | (y_inf & x_zero)) begin
            // infinity times zero has no value
            fma_sp_flags[F_NV] = 1'b1;
            if (x_snan | y_snan | (has_z & zz_snan)) fma_sp_flags[F_NV] = 1'b1;
        end else if (x_nan | y_nan | (has_z & zz_nan)) begin
            if (x_snan | y_snan | (has_z & zz_snan)) fma_sp_flags[F_NV] = 1'b1;
        end else if (prod_inf) begin
            if (has_z & zz_inf & (zz_sign != prod_sign)) begin
                fma_sp_flags[F_NV] = 1'b1;               // inf - inf
            end else begin
                fma_sp_res = fmt ? {prod_sign, 11'h7FF, 52'd0}
                                 : {32'hFFFF_FFFF, prod_sign, 8'hFF, 23'd0};
            end
        end else if (has_z & zz_inf) begin
            fma_sp_res = fmt ? {zz_sign, 11'h7FF, 52'd0}
                             : {32'hFFFF_FFFF, zz_sign, 8'hFF, 23'd0};
        end else if (prod_zero & (~has_z | zz_zero)) begin
            // both sides are zero: minus only when both are minus, or when
            // the rounding goes towards minus infinity
            fma_sp_res = fmt ? {zsum_sign, 63'd0}
                             : {32'hFFFF_FFFF, zsum_sign, 31'd0};
        end else if (prod_zero) begin
            fma_sp_res = z_packed;                       // 0 + z is z
        end else begin
            fma_special = 1'b0;
        end
    end

    //-----------------------------------------------------------------
    // the datapath
    //-----------------------------------------------------------------
    logic [63:0]  pp_ll, pp_hl, pp_lh, pp_hh;
    logic [127:0] prod;
    int signed    com_exp;
    logic [128:0] sum_r;
    logic         sum_sign, stick_sum;

    // what the alignment hands to the addition, one cycle later
    logic [128:0] al_gt, al_ls;
    logic         al_st, al_add, al_sgn_gt, al_sgn_ls;

    // what the select hands to the rounding, one cycle later
    logic [63:0]  q_sp_res;
    logic         q_sp_is_int, q_use_rnd;
    logic [4:0]   q_sp_flags;

    // shift a 128 bit value right, keeping what leaves in a sticky bit
    function automatic logic [128:0] shr_jam(input logic [127:0] v, input int n);
        logic [127:0] sh;
        logic         st;
        if (n <= 0) begin
            sh = v; st = 1'b0;
        end else if (n >= 128) begin
            sh = 128'd0; st = |v;
        end else begin
            sh = v >> n;
            st = |(v & ((128'd1 << n) - 128'd1));
        end
        return {st, sh};
    endfunction

    // leading zeros of the 129 bit sum
    function automatic int lzc129(input logic [128:0] v);
        int i;
        for (i = 0; i < 129; i++)
            if (v[128-i]) return i;
        return 129;
    endfunction

    logic [128:0] sum_norm;
    int           sum_lz;
    logic [127:0] fma_sig;
    int signed    fma_exp;
    logic         fma_sticky, fma_zero;

    always @(*) begin
        sum_lz     = lzc129(sum_r);
        fma_zero   = (sum_r == 129'd0);
        sum_norm   = sum_r << sum_lz;
        fma_sig    = sum_norm[128:1];
        fma_sticky = sum_norm[0] | stick_sum;
        fma_exp    = com_exp + 1 - sum_lz;
    end


    //=================================================================
    // divide and square root
    //
    //   Both are iterative and not pipelined: one bit of the result per
    //   cycle. The divide produces 128 bits for a double and 64 for a
    //   single, which is what the deepest subnormal result needs before the
    //   rounding position falls below the last computed bit; the square root
    //   of a finite number is never subnormal, so 64 bits are always enough
    //   there.
    //=================================================================
    logic [64:0]  dv_rem;
    logic [127:0] dv_quo;
    logic [63:0]  dv_div;
    logic [7:0]   dv_cnt;
    int signed    dv_exp;
    logic         dv_sign, dv_fmt;

    // A single needs half as many quotient bits, so the first bit produced
    // does not end up at the top of the register; line it up before looking
    // at it.
    logic [127:0] dv_al;
    assign dv_al = dv_fmt ? dv_quo : {dv_quo[63:0], 64'd0};

    logic [65:0]  sq_rem;
    logic [63:0]  sq_root;
    logic [127:0] sq_rad;
    logic [7:0]   sq_cnt;
    int signed    sq_exp;

    logic [127:0] ds_sig;
    int signed    ds_exp;
    logic         ds_sticky, ds_sign;
    logic         is_sqrt_r;

    always @(*) begin
        if (is_sqrt_r) begin
            ds_sig    = {sq_root, 64'd0};
            ds_exp    = sq_exp;
            ds_sticky = |sq_rem;
            ds_sign   = 1'b0;
        end else begin
            // the first bit produced is the integer part of a / b, and it
            // is zero when the quotient is below one
            ds_sig    = dv_al[127] ? dv_al : (dv_al << 1);
            ds_exp    = dv_al[127] ? dv_exp : (dv_exp - 1);
            ds_sticky = |dv_rem;
            ds_sign   = dv_sign;
        end
    end

    //-----------------------------------------------------------------
    // the cases that never reach the iteration
    //-----------------------------------------------------------------
    logic        div_special, sqrt_special;
    logic [63:0] div_sp_res, sqrt_sp_res;
    logic [4:0]  div_sp_flags, sqrt_sp_flags;
    logic        div_sign;

    assign div_sign = a_sign ^ b_sign;

    always @(*) begin
        div_special  = 1'b1;
        div_sp_res   = fmt ? QNAN64 : QNAN32;
        div_sp_flags = 5'd0;

        if (a_nan | b_nan) begin
            if (a_snan | b_snan) div_sp_flags[F_NV] = 1'b1;
        end else if (a_inf & b_inf) begin
            div_sp_flags[F_NV] = 1'b1;
        end else if (a_zero & b_zero) begin
            div_sp_flags[F_NV] = 1'b1;
        end else if (a_inf) begin
            // an infinite dividend gives an infinity, and no flag: divide by
            // zero is only raised for a finite non zero dividend
            div_sp_res = fmt ? {div_sign, 11'h7FF, 52'd0}
                             : {32'hFFFF_FFFF, div_sign, 8'hFF, 23'd0};
        end else if (b_zero) begin
            div_sp_flags[F_DZ] = 1'b1;
            div_sp_res = fmt ? {div_sign, 11'h7FF, 52'd0}
                             : {32'hFFFF_FFFF, div_sign, 8'hFF, 23'd0};
        end else if (b_inf | a_zero) begin
            div_sp_res = fmt ? {div_sign, 63'd0} : {32'hFFFF_FFFF, div_sign, 31'd0};
        end else begin
            div_special = 1'b0;
        end

        sqrt_special  = 1'b1;
        sqrt_sp_res   = fmt ? QNAN64 : QNAN32;
        sqrt_sp_flags = 5'd0;

        if (a_nan) begin
            if (a_snan) sqrt_sp_flags[F_NV] = 1'b1;
        end else if (a_zero) begin
            sqrt_sp_res = fmt ? {a_sign, 63'd0} : {32'hFFFF_FFFF, a_sign, 31'd0};
        end else if (a_sign) begin
            sqrt_sp_flags[F_NV] = 1'b1;          // the root of a negative number
        end else if (a_inf) begin
            sqrt_sp_res = fmt ? {1'b0, 11'h7FF, 52'd0}
                              : {32'hFFFF_FFFF, 1'b0, 8'hFF, 23'd0};
        end else begin
            sqrt_special = 1'b0;
        end
    end

    //=================================================================
    // what the answer is
    //=================================================================
    // The block below decides what the rounder is given and what the answer
    // is when nothing has to be rounded. It must not read the output of the
    // rounder: that would be a combinational loop through it, which costs
    // nothing in a synthesised design but makes an event driven simulator
    // evaluate the whole thing several times per cycle. What this block
    // produces is written into registers by S_SEL, and the rounder is read
    // one cycle later by S_RND.
    logic [63:0] sp_res;
    logic        sp_is_int;
    logic [4:0]  sp_flags;
    logic        use_rnd;

    always @(*) begin
        sp_res    = 64'd0;
        sp_is_int = 1'b0;
        sp_flags  = 5'd0;
        use_rnd   = 1'b0;
        rnd_sign     = 1'b0;
        rnd_exp      = 14'sd0;
        rnd_sig      = 128'd0;
        rnd_sticky   = 1'b0;
        rnd_fmt      = fmt;

        case (op)
            FOP_SGNJ, FOP_SGNJN, FOP_SGNJX: sp_res = sgnj_res;

            FOP_MIN, FOP_MAX: begin
                sp_res = minmax_res;
                sp_flags = minmax_flags;
            end

            FOP_EQ, FOP_LT, FOP_LE: begin
                sp_res     = {63'd0, cmp_res};
                sp_is_int = 1'b1;
                sp_flags     = cmp_flags;
            end

            FOP_CLASS: begin
                sp_res     = class_res;
                sp_is_int = 1'b1;
            end

            FOP_MV_X_F: begin
                // the raw bits; a single is sign extended from bit 31
                sp_res     = fmt ? u_a : {{32{u_a[31]}}, u_a[31:0]};
                sp_is_int = 1'b1;
            end

            FOP_MV_F_X: sp_res = fmt ? u_a : {32'hFFFF_FFFF, u_a[31:0]};

            FOP_CVT_S_D: begin                    // double -> single
                rnd_fmt = 1'b0;
                if (a_nan)       sp_res = QNAN32;
                else if (a_inf)  sp_res = {32'hFFFF_FFFF, a_sign, 8'hFF, 23'd0};
                else if (a_zero) sp_res = {32'hFFFF_FFFF, a_sign, 31'd0};
                else begin
                    rnd_sign = a_sign;
                    rnd_exp  = 14'(a_exp);
                    rnd_sig  = {a_sig, 64'd0};
                    use_rnd  = 1'b1;
                end
                if (a_snan) sp_flags[F_NV] = 1'b1;
            end

            FOP_CVT_D_S: begin                    // single -> double, exact
                rnd_fmt = 1'b1;
                if (a_nan)       sp_res = QNAN64;
                else if (a_inf)  sp_res = {a_sign, 11'h7FF, 52'd0};
                else if (a_zero) sp_res = {a_sign, 63'd0};
                else begin
                    rnd_sign = a_sign;
                    rnd_exp  = 14'(a_exp);
                    rnd_sig  = {a_sig, 64'd0};
                    use_rnd  = 1'b1;
                end
                if (a_snan) sp_flags[F_NV] = 1'b1;
            end

            FOP_CVT_F_I: begin                    // integer -> floating point
                if (i2f_zero) sp_res = fmt ? 64'd0 : {32'hFFFF_FFFF, 32'd0};
                else begin
                    rnd_sign = i2f_sign;
                    rnd_exp  = 14'(63 - i2f_shift);
                    rnd_sig  = {i2f_norm, 64'd0};
                    use_rnd  = 1'b1;
                end
            end

            FOP_CVT_I_F: begin                    // floating point -> integer
                sp_res     = f2i_res;
                sp_is_int = 1'b1;
                sp_flags     = f2i_flags;
            end

            FOP_DIV, FOP_SQRT: begin
                if ((op == FOP_DIV) ? div_special : sqrt_special) begin
                    sp_res = (op == FOP_DIV) ? div_sp_res   : sqrt_sp_res;
                    sp_flags = (op == FOP_DIV) ? div_sp_flags : sqrt_sp_flags;
                end else begin
                    rnd_sign   = ds_sign;
                    rnd_exp    = 14'(ds_exp);
                    rnd_sig    = ds_sig;
                    rnd_sticky = ds_sticky;
                    use_rnd  = 1'b1;
                end
            end

            FOP_ADD, FOP_SUB, FOP_MUL,
            FOP_MADD, FOP_MSUB, FOP_NMSUB, FOP_NMADD: begin
                if (fma_special) begin
                    sp_res = fma_sp_res;
                    sp_flags = fma_sp_flags;
                end else if (fma_zero) begin
                    // everything cancelled out
                    sp_res = fmt ? {zero_sign, 63'd0}
                                   : {32'hFFFF_FFFF, zero_sign, 31'd0};
                end else begin
                    rnd_sign = sum_sign;
                    rnd_exp  = 14'(fma_exp);
                    rnd_sig  = fma_sig;
                    rnd_sticky = fma_sticky;
                    use_rnd  = 1'b1;
                end
            end

            default: begin
                sp_res = 64'd0;
            end
        endcase

        // a NaN that arrives at an operation which produces a floating point
        // number turns into the canonical one; a signalling NaN is invalid
    end


    //=================================================================
    // sequencing
    //
    //   Every operation ends the same way: S_SEL decides what the answer is
    //   made of and what the rounder is given, S_RND rounds it. Those are
    //   two cycles because together they are the longest path in the unit --
    //   a leading zero count over 129 bits, a shift of the same width, and
    //   then the subnormal shift and the carry of the rounding.
    //
    //   The multiply and add reaches them through four more: the partial
    //   products, their sum, the alignment of the addend, and the addition.
    //   The alignment and the addition are apart for the same reason: a
    //   variable shift followed by two adders as wide as the product does
    //   not fit in a cycle.
    //
    //   It is not pipelined, one operation at a time, which is all an in
    //   order single issue pipeline can use.
    //=================================================================
    typedef enum logic [3:0] {S_IDLE, S_M1, S_M2, S_M3, S_SEL, S_RND,
                              S_DIV, S_SQRT, S_DONE} state_t;
    state_t state;

    assign busy = (state != S_IDLE) && (state != S_DONE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            result        <= 64'd0;
            result_is_int <= 1'b0;
            flags         <= 5'd0;
            pp_ll <= 64'd0; pp_hl <= 64'd0; pp_lh <= 64'd0; pp_hh <= 64'd0;
            prod  <= 128'd0;
            sum_r <= 129'd0;
            com_exp <= 0; sum_sign <= 1'b0; stick_sum <= 1'b0;
            al_gt <= 129'd0; al_ls <= 129'd0; al_st <= 1'b0;
            al_add <= 1'b0; al_sgn_gt <= 1'b0; al_sgn_ls <= 1'b0;
            q_sp_res <= 64'd0; q_sp_is_int <= 1'b0; q_sp_flags <= 5'd0;
            q_use_rnd <= 1'b0;
            q_rnd_sign <= 1'b0; q_rnd_exp <= 14'sd0; q_rnd_sig <= 128'd0;
            q_rnd_sticky <= 1'b0; q_rnd_fmt <= 1'b0;
            dv_rem <= 65'd0; dv_quo <= 128'd0; dv_div <= 64'd0;
            dv_cnt <= 8'd0;  dv_exp <= 0; dv_sign <= 1'b0; dv_fmt <= 1'b0;
            sq_rem <= 66'd0; sq_root <= 64'd0; sq_rad <= 128'd0;
            sq_cnt <= 8'd0;  sq_exp <= 0; is_sqrt_r <= 1'b0;
        end else if (kill) begin
            state <= S_IDLE;
        end else begin
            case (state)
                //-----------------------------------------------------
                S_IDLE: if (start) begin
                    if ((op == FOP_DIV) && !div_special) begin
                        dv_rem  <= {1'b0, a_sig};
                        dv_div  <= b_sig;
                        dv_quo  <= 128'd0;
                        dv_cnt  <= fmt ? 8'd128 : 8'd64;
                        dv_exp  <= a_exp - b_exp;
                        dv_sign <= div_sign;
                        dv_fmt  <= fmt;
                        is_sqrt_r <= 1'b0;
                        state   <= S_DIV;
                    end else if ((op == FOP_SQRT) && !sqrt_special) begin
                        // an odd exponent leaves a factor of two in the
                        // radicand, so that the exponent of the root stays
                        // a whole number
                        sq_rad  <= a_exp[0] ? {a_sig, 64'd0} : {1'b0, a_sig, 63'd0};
                        sq_rem  <= 66'd0;
                        sq_root <= 64'd0;
                        sq_cnt  <= 8'd64;
                        sq_exp  <= a_exp >>> 1;
                        is_sqrt_r <= 1'b1;
                        state   <= S_SQRT;
                    end else if (is_fma_op && !fma_special) begin
                        pp_ll <= {32'd0, x_sig[31:0]}  * {32'd0, y_sig[31:0]};
                        pp_hl <= {32'd0, x_sig[63:32]} * {32'd0, y_sig[31:0]};
                        pp_lh <= {32'd0, x_sig[31:0]}  * {32'd0, y_sig[63:32]};
                        pp_hh <= {32'd0, x_sig[63:32]} * {32'd0, y_sig[63:32]};
                        state <= S_M1;
                    end else begin
                        // everything else -- the moves, the comparisons, the
                        // conversions, and every special case of the four
                        // above -- is decided by S_SEL out of the copy of
                        // the operands that was just taken
                        state <= S_SEL;
                    end
                end
                //-----------------------------------------------------
                S_M1: begin
                    prod  <= {pp_hh, 64'd0} + {32'd0, pp_hl, 32'd0} +
                             {32'd0, pp_lh, 32'd0} + {64'd0, pp_ll};
                    state <= S_M2;
                end
                //-----------------------------------------------------
                S_M2: begin
                    // normalise the product and bring the addend into its
                    // frame. The larger of the two is `al_gt`, the one that
                    // was shifted is `al_ls`, and `al_add` says whether the
                    // next cycle adds them or takes one from the other.
                    logic [127:0] pn_v, zn_v;
                    int signed    pexp_v, d_v;
                    logic [128:0] sh;

                    pn_v   = prod[127] ? prod : (prod << 1);
                    pexp_v = prod[127] ? (x_exp + y_exp + 1) : (x_exp + y_exp);
                    zn_v   = {zz_sig, 64'd0};

                    if (!has_z || zz_zero) begin
                        al_gt     <= {1'b0, pn_v};
                        al_ls     <= 129'd0;
                        al_st     <= 1'b0;
                        al_add    <= 1'b1;
                        al_sgn_gt <= prod_sign;
                        al_sgn_ls <= prod_sign;
                        com_exp   <= pexp_v;
                    end else begin
                        d_v = pexp_v - zz_exp;
                        if (d_v >= 0) begin
                            sh        = shr_jam(zn_v, d_v);
                            al_gt     <= {1'b0, pn_v};
                            al_ls     <= {1'b0, sh[127:0]};
                            al_st     <= sh[128];
                            al_sgn_gt <= prod_sign;
                            al_sgn_ls <= zz_sign;
                            com_exp   <= pexp_v;
                        end else begin
                            sh        = shr_jam(pn_v, -d_v);
                            al_gt     <= {1'b0, zn_v};
                            al_ls     <= {1'b0, sh[127:0]};
                            al_st     <= sh[128];
                            al_sgn_gt <= zz_sign;
                            al_sgn_ls <= prod_sign;
                            com_exp   <= zz_exp;
                        end
                        al_add <= (prod_sign == zz_sign);
                    end
                    state <= S_M3;
                end
                //-----------------------------------------------------
                S_M3: begin
                    // The three results are built side by side and one of
                    // them is picked, so the cycle holds one adder and not
                    // a comparison followed by a subtraction.
                    //
                    // The one that was shifted is the smaller one whenever
                    // anything was lost, so a borrow can only happen without
                    // a sticky bit.
                    logic [128:0] sum_add, sum_sub, sum_rev;

                    sum_add = al_gt + al_ls;
                    sum_sub = al_gt - al_ls - (al_st ? 129'd1 : 129'd0);
                    sum_rev = al_ls - al_gt;

                    if (al_add) begin
                        sum_r    <= sum_add;
                        sum_sign <= al_sgn_gt;
                    end else if (al_gt >= al_ls) begin
                        sum_r    <= sum_sub;
                        sum_sign <= al_sgn_gt;
                    end else begin
                        sum_r    <= sum_rev;
                        sum_sign <= al_sgn_ls;
                    end
                    stick_sum <= al_st;
                    state     <= S_SEL;
                end
                //-----------------------------------------------------
                S_DIV: begin
                    logic [64:0] r1;
                    logic        qbit;
                    if (dv_rem >= {1'b0, dv_div}) begin
                        r1   = dv_rem - {1'b0, dv_div};
                        qbit = 1'b1;
                    end else begin
                        r1   = dv_rem;
                        qbit = 1'b0;
                    end
                    dv_quo <= {dv_quo[126:0], qbit};
                    dv_rem <= {r1[63:0], 1'b0};
                    dv_cnt <= dv_cnt - 8'd1;
                    if (dv_cnt == 8'd1) state <= S_SEL;
                end
                //-----------------------------------------------------
                S_SQRT: begin
                    logic [65:0] rem2, trial;
                    rem2  = {sq_rem[63:0], sq_rad[127:126]};
                    trial = {sq_root, 2'b01};
                    if (rem2 >= trial) begin
                        sq_rem  <= rem2 - trial;
                        sq_root <= {sq_root[62:0], 1'b1};
                    end else begin
                        sq_rem  <= rem2;
                        sq_root <= {sq_root[62:0], 1'b0};
                    end
                    sq_rad <= sq_rad << 2;
                    sq_cnt <= sq_cnt - 8'd1;
                    if (sq_cnt == 8'd1) state <= S_SEL;
                end
                //-----------------------------------------------------
                S_SEL: begin
                    q_sp_res     <= sp_res;
                    q_sp_is_int  <= sp_is_int;
                    q_sp_flags   <= sp_flags;
                    q_use_rnd    <= use_rnd;
                    q_rnd_sign   <= rnd_sign;
                    q_rnd_exp    <= rnd_exp;
                    q_rnd_sig    <= rnd_sig;
                    q_rnd_sticky <= rnd_sticky;
                    q_rnd_fmt    <= rnd_fmt;
                    state        <= S_RND;
                end
                //-----------------------------------------------------
                S_RND: begin
                    result        <= q_use_rnd ? rnd_result : q_sp_res;
                    result_is_int <= q_sp_is_int;
                    flags         <= q_use_rnd ? (q_sp_flags | rnd_flags)
                                               : q_sp_flags;
                    state         <= S_DONE;
                end
                //-----------------------------------------------------
                default: if (ack) state <= S_IDLE;
            endcase
        end
    end

endmodule : CORE_FPU
