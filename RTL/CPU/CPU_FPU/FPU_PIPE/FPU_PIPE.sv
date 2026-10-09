//---------------------------------------------------------------------------
// FPU_PIPE.sv
//
// Pipelined floating point unit of the F and D extensions
// (CPU_CORE_SPEC.md 10, ROADMAP C2).
//
//   The same arithmetic as CORE_FPU, cut into stages that each take a new
//   operation every cycle. Every operation but the divide and the square
//   root goes through all of them, so the latency is the same for all (9:
//   an operation offered in cycle t has its result on out_* in cycle t+9)
//   and the results come out in the order the operations went in, one per
//   cycle at most.
//
//     P0  the copy of the operands and the control (the cycle after the
//         offer; the core's EX offers, so P0 is where MR is)
//     P1  unpacking: the kind of each value, the exponent and the
//         normalised significand (a leading zero count and a shift)
//     P2  the multiply and add: the partial products. Everything else:
//         its answer, or what it asks the rounder for ("the bundle")
//     P3  the sum of the partial products          (the bundle waits)
//     P4  the alignment of the addend              (the bundle waits)
//     P5  the addition                             (the bundle waits)
//     P6  the select: the normalisation of the sum, or the bundle, or the
//         result of the divide / square root
//     P7  the first half of the rounder (FPU_ROUND); the second half of a
//         conversion to an integer
//     P8  the second half of the rounder, the answer
//
//   The stages are the states of CORE_FPU; each already wrote registers of
//   its own, so the cuts and with them the paths are the same.
//
//   Divide and square root keep the iterative engine of CORE_FPU. One is
//   taken at P1 and leaves the pipeline there; no operation is accepted
//   until its answer is out (in_ready is low), so when the engine is done
//   the pipeline is empty and the answer enters at P6. A divide or square
//   root of special values (NaN, zero, infinity, ...) does not need the
//   engine and goes down the pipeline like any other operation.
//
//   The first two stages move with the pipeline of the core and can be
//   held and killed with it (hold0 / hold1, kill0 / kill1); from P2 on an
//   operation is past the point where the core can take it back, and the
//   stages run on their own. hold1 must come with hold0 (the younger one
//   cannot pass the older), and an operation killed in P1 has its younger
//   one in P0 killed as well (kill1 with kill0).
//
//   in_tag is carried along and comes out with the result (the register
//   to write, for the core).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module FPU_PIPE
    #(
        parameter int TAG_W = 8
    )
    (
        input  logic             clk,
        input  logic             rst_n,

        // the offer: an operation in the cycle the core has it in EX
        input  logic             in_valid,
        output logic             in_ready,       // low while a divide / square root runs
        input  logic [4:0]       in_op,
        input  logic             in_fmt,         // 0 : single, 1 : double
        input  logic [2:0]       in_rm,          // already resolved (never 111)
        input  logic             in_int_signed,  // conversions with an integer side
        input  logic             in_int_w,       // 0 : 32 bit, 1 : 64 bit
        input  logic [63:0]      in_a,           // rs1 (or the integer for FCVT.F.I)
        input  logic [63:0]      in_b,           // rs2
        input  logic [63:0]      in_c,           // rs3
        input  logic [TAG_W-1:0] in_tag,

        // the first two stages move with the core
        input  logic             hold0,          // P0 keeps its operation
        input  logic             hold1,          // P1 keeps its operation (with hold0)
        input  logic             kill0,          // the operation in P0 is taken back
        input  logic             kill1,          // the operation in P1 is taken back

        // the answer
        output logic             out_valid,
        output logic [63:0]      out_result,
        output logic             out_is_int,     // for the integer register file
        output logic [4:0]       out_flags,      // NV DZ OF UF NX
        output logic [TAG_W-1:0] out_tag,

        output logic             busy            // anything in flight
    );

    //-----------------------------------------------------------------
    // operations (the numbers of CORE_FPU)
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
    localparam logic [4:0] FOP_MV_X_F  = 5'd18;
    localparam logic [4:0] FOP_MV_F_X  = 5'd19;
    localparam logic [4:0] FOP_CVT_S_D = 5'd20;
    localparam logic [4:0] FOP_CVT_D_S = 5'd21;
    localparam logic [4:0] FOP_CVT_F_I = 5'd22;
    localparam logic [4:0] FOP_CVT_I_F = 5'd23;

    localparam logic [2:0]  RM_RDN_L = 3'b010;
    localparam logic [63:0] QNAN64 = 64'h7FF8_0000_0000_0000;
    localparam logic [63:0] QNAN32 = {32'hFFFF_FFFF, 32'h7FC0_0000};

    localparam int F_NX = 0;
    localparam int F_UF = 1;
    localparam int F_OF = 2;
    localparam int F_DZ = 3;
    localparam int F_NV = 4;

    // exponents are kept in this many bits (signed); the widest any value
    // reaches is a sum of two of them plus a few, well inside
    localparam int EW = 16;

    //=================================================================
    // helpers (as in CORE_FPU)
    //=================================================================
    function automatic int clz64(input logic [63:0] v);
        for (int i = 0; i < 64; i++)
            if (v[63-i]) return i;
        return 64;
    endfunction

    function automatic int lzc129(input logic [128:0] v);
        for (int i = 0; i < 129; i++)
            if (v[128-i]) return i;
        return 129;
    endfunction

    // shift a 128 bit value right, keeping what leaves in a sticky bit
    function automatic logic [128:0] shr_jam(input logic [127:0] v, input int n);
        logic [127:0] sh;
        logic         st;
        if (n <= 0) begin
            sh = v; st = 1'b0;
        end else if (n >= 128) begin
            sh = 128'd0; st = |v;
        end else begin
            logic [127:0] m;
            for (int i = 0; i < 128; i++) m[i] = (n[6:0] > 7'(i));
            sh = v >> n[6:0];
            st = |(v & m);
        end
        return {st, sh};
    endfunction

    // the raw fields of the format, the significand normalised to bit 63
    task automatic unpack(input logic [63:0] v, input logic f,
                          output logic        o_sign,
                          output int signed   o_exp,
                          output logic [63:0] o_sig,
                          output logic        o_zero,
                          output logic        o_inf,
                          output logic        o_nan,
                          output logic        o_snan);
        logic [11:0] ex;
        logic [63:0] fr, nrm;
        int          ew, pw, bs, sh;
        logic        boxed;
        begin
            boxed = f | (&v[63:32]);
            if (!f && !boxed) begin
                o_sign = 1'b0; o_exp = 0; o_sig = 64'd0;
                o_zero = 1'b0; o_inf = 1'b0; o_nan = 1'b1; o_snan = 1'b0;
            end else begin
                if (f) begin
                    ew = 11; pw = 52; bs = 1023;
                    o_sign = v[63];
                    ex     = {1'b0, v[62:52]};
                    fr     = {12'd0, v[51:0]};
                end else begin
                    ew = 8;  pw = 23; bs = 127;
                    o_sign = v[31];
                    ex     = {4'd0, v[30:23]};
                    fr     = {41'd0, v[22:0]};
                end
                o_zero = 1'b0; o_inf = 1'b0; o_nan = 1'b0; o_snan = 1'b0;
                o_exp  = 0;    o_sig = 64'd0;
                if (ex == 12'd0) begin
                    if (fr == 64'd0) begin
                        o_zero = 1'b1;
                    end else begin
                        nrm   = fr << (64 - pw);
                        sh    = clz64(nrm);
                        o_sig = nrm << sh;
                        o_exp = -bs - sh;
                    end
                end else if (int'(ex) == ((1 << ew) - 1)) begin
                    if (fr == 64'd0) o_inf = 1'b1;
                    else begin
                        o_nan  = 1'b1;
                        o_snan = ~fr[pw-1];
                    end
                end else begin
                    o_sig = {1'b1, 63'd0} | (fr << (63 - pw));
                    o_exp = int'(ex) - bs;
                end
            end
        end
    endtask

    // the limits of an integer format
    task automatic iw_lim(input logic w, input logic sgn,
                          output logic [63:0] lmax, output logic [63:0] lmin);
        lmax = sgn ? (w ? 64'h7FFF_FFFF_FFFF_FFFF : 64'h0000_0000_7FFF_FFFF)
                   : (w ? 64'hFFFF_FFFF_FFFF_FFFF : 64'h0000_0000_FFFF_FFFF);
        lmin = sgn ? (w ? 64'h8000_0000_0000_0000 : 64'h0000_0000_8000_0000)
                   : 64'd0;
    endtask

    function automatic logic is_fma(input logic [4:0] o);
        return (o <= FOP_NMADD) && (o != FOP_DIV) && (o != FOP_SQRT);
    endfunction

    function automatic logic is_ds(input logic [4:0] o);
        return (o == FOP_DIV) || (o == FOP_SQRT);
    endfunction

    //=================================================================
    // the divide / square root engine (declared here: P0 / P1 start it)
    //=================================================================
    logic               ds_busy;        // one was accepted and is not out yet
    logic               ds_run;         // the engine iterates or holds its result
    logic               ds_cmt;         // its operation has left P1
    logic [64:0]        dv_rem;
    logic [127:0]       dv_quo;
    logic [63:0]        dv_div;
    logic [7:0]         ds_cnt;
    logic signed [EW-1:0] dv_exp;
    logic               dv_sign;
    logic [65:0]        sq_rem;
    logic [63:0]        sq_root;
    logic [127:0]       sq_rad;
    logic signed [EW-1:0] sq_exp;
    logic               is_sqrt_r;
    logic               ds_fmt;
    logic [2:0]         ds_rm;
    logic [TAG_W-1:0]   ds_tag;

    //=================================================================
    // P0 : the copy
    //=================================================================
    logic               p0_v;
    logic [4:0]         p0_op;
    logic               p0_fmt, p0_isg, p0_iw;
    logic [2:0]         p0_rm;
    logic [63:0]        p0_a, p0_b, p0_c;
    logic [TAG_W-1:0]   p0_tag;

    logic accept;
    assign in_ready = ~ds_busy;
    assign accept   = in_valid & in_ready & ~hold0 & ~kill0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                p0_v <= 1'b0;
        else if (kill0)            p0_v <= 1'b0;
        else if (!hold0)           p0_v <= accept;
    end

    always_ff @(posedge clk) begin
        if (!hold0) begin
            p0_op  <= in_op;  p0_fmt <= in_fmt; p0_rm <= in_rm;
            p0_isg <= in_int_signed; p0_iw <= in_int_w;
            p0_a   <= in_a;   p0_b   <= in_b;   p0_c  <= in_c;
            p0_tag <= in_tag;
        end
    end

    //=================================================================
    // P1 : unpacking
    //=================================================================
    logic        w_a_sign, w_a_zero, w_a_inf, w_a_nan, w_a_snan;
    logic        w_b_sign, w_b_zero, w_b_inf, w_b_nan, w_b_snan;
    logic        w_c_sign, w_c_zero, w_c_inf, w_c_nan, w_c_snan;
    int signed   w_a_exp, w_b_exp, w_c_exp;
    logic [63:0] w_a_sig, w_b_sig, w_c_sig;

    // the sensitivity lists are written out for the reason given in CORE_FPU
    always @(p0_a, p0_fmt) unpack(p0_a, p0_fmt, w_a_sign, w_a_exp, w_a_sig,
                                  w_a_zero, w_a_inf, w_a_nan, w_a_snan);
    always @(p0_b, p0_fmt) unpack(p0_b, p0_fmt, w_b_sign, w_b_exp, w_b_sig,
                                  w_b_zero, w_b_inf, w_b_nan, w_b_snan);
    always @(p0_c, p0_fmt) unpack(p0_c, p0_fmt, w_c_sign, w_c_exp, w_c_sig,
                                  w_c_zero, w_c_inf, w_c_nan, w_c_snan);

    // does a divide / square root of P0 need the engine
    logic p0_ds_special;
    always_comb begin
        if (p0_op == FOP_DIV)
            p0_ds_special = w_a_nan | w_b_nan | (w_a_inf & w_b_inf) | (w_a_zero & w_b_zero) |
                            w_a_inf | w_b_zero | w_b_inf | w_a_zero;
        else
            p0_ds_special = w_a_nan | w_a_zero | w_a_sign | w_a_inf;
    end

    logic               p1_v, p1_ds_eng;
    logic [4:0]         p1_op;
    logic               p1_fmt, p1_isg, p1_iw;
    logic [2:0]         p1_rm;
    logic [63:0]        p1_a, p1_b, p1_c;
    logic [TAG_W-1:0]   p1_tag;
    logic               a_sign, a_zero, a_inf, a_nan, a_snan;
    logic               b_sign, b_zero, b_inf, b_nan, b_snan;
    logic               c_sign, c_zero, c_inf, c_nan, c_snan;
    logic signed [EW-1:0] a_exp, b_exp, c_exp;
    logic [63:0]        a_sig, b_sig, c_sig;

    logic p0_go, p1_go;           // the operation moves on this cycle
    assign p0_go = p0_v & ~kill0 & ~hold0 & ~hold1;
    assign p1_go = p1_v & ~kill1 & ~hold1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)             p1_v <= 1'b0;
        else if (kill1)         p1_v <= 1'b0;
        else if (!hold1)        p1_v <= p0_go;
    end

    always_ff @(posedge clk) begin
        if (!hold1) begin
            p1_op  <= p0_op;  p1_fmt <= p0_fmt; p1_rm <= p0_rm;
            p1_isg <= p0_isg; p1_iw  <= p0_iw;
            p1_a   <= p0_a;   p1_b   <= p0_b;   p1_c  <= p0_c;
            p1_tag <= p0_tag;
            p1_ds_eng <= is_ds(p0_op) & ~p0_ds_special;
            a_sign <= w_a_sign; a_zero <= w_a_zero; a_inf <= w_a_inf;
            a_nan  <= w_a_nan;  a_snan <= w_a_snan;
            b_sign <= w_b_sign; b_zero <= w_b_zero; b_inf <= w_b_inf;
            b_nan  <= w_b_nan;  b_snan <= w_b_snan;
            c_sign <= w_c_sign; c_zero <= w_c_zero; c_inf <= w_c_inf;
            c_nan  <= w_c_nan;  c_snan <= w_c_snan;
            a_exp  <= EW'(w_a_exp); a_sig <= w_a_sig;
            b_exp  <= EW'(w_b_exp); b_sig <= w_b_sig;
            c_exp  <= EW'(w_c_exp); c_sig <= w_c_sig;
        end
    end

    //=================================================================
    // P2 : the bundle of everything but the multiply and add, and the
    //      partial products
    //=================================================================
    // the operand as an operation sees it (not NaN boxed : canonical NaN)
    logic [63:0] a_cval, b_cval, c_cval;
    assign a_cval = (p1_fmt | (&p1_a[63:32])) ? p1_a : QNAN32;
    assign b_cval = (p1_fmt | (&p1_b[63:32])) ? p1_b : QNAN32;
    assign c_cval = (p1_fmt | (&p1_c[63:32])) ? p1_c : QNAN32;

    //-----------------------------------------------------------------
    // sign injection
    //-----------------------------------------------------------------
    logic [63:0] sgnj_res;
    always_comb begin
        logic sgn_a, sgn_b, sgn_new;
        sgn_a = p1_fmt ? a_cval[63] : a_cval[31];
        sgn_b = p1_fmt ? b_cval[63] : b_cval[31];
        case (p1_op)
            FOP_SGNJN: sgn_new = ~sgn_b;
            FOP_SGNJX: sgn_new = sgn_a ^ sgn_b;
            default:   sgn_new = sgn_b;
        endcase
        if (p1_fmt) sgnj_res = {sgn_new, a_cval[62:0]};
        else        sgnj_res = {32'hFFFF_FFFF, sgn_new, a_cval[30:0]};
    end

    //-----------------------------------------------------------------
    // comparisons
    //-----------------------------------------------------------------
    logic       cmp_lt, cmp_res;
    logic [4:0] cmp_flags;
    always_comb begin
        logic cmp_eq, cmp_unordered;
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
        else                             cmp_lt = (a_sig != b_sig) &
                                                  ((a_sig < b_sig) ^ a_sign);
        cmp_res   = 1'b0;
        cmp_flags = 5'd0;
        case (p1_op)
            FOP_EQ: begin
                cmp_res = ~cmp_unordered & cmp_eq;
                if (a_snan | b_snan) cmp_flags[F_NV] = 1'b1;
            end
            FOP_LT: begin
                cmp_res = ~cmp_unordered & cmp_lt;
                if (a_nan | b_nan) cmp_flags[F_NV] = 1'b1;
            end
            default: begin
                cmp_res = ~cmp_unordered & (cmp_lt | cmp_eq);
                if (a_nan | b_nan) cmp_flags[F_NV] = 1'b1;
            end
        endcase
    end

    //-----------------------------------------------------------------
    // minimum and maximum
    //-----------------------------------------------------------------
    logic [63:0] minmax_res;
    logic [4:0]  minmax_flags;
    always_comb begin
        logic take_b;
        minmax_flags = 5'd0;
        if (a_snan | b_snan) minmax_flags[F_NV] = 1'b1;
        if      (a_zero && b_zero && (a_sign != b_sign))
            take_b = (p1_op == FOP_MIN) ? b_sign : a_sign;
        else if (p1_op == FOP_MIN) take_b = ~cmp_lt;
        else                       take_b =  cmp_lt;
        if (a_nan && b_nan)      minmax_res = p1_fmt ? QNAN64 : QNAN32;
        else if (a_nan)          minmax_res = b_cval;
        else if (b_nan)          minmax_res = a_cval;
        else                     minmax_res = take_b ? b_cval : a_cval;
        if (!p1_fmt && !(a_nan && b_nan))
            minmax_res = {32'hFFFF_FFFF, minmax_res[31:0]};
    end

    //-----------------------------------------------------------------
    // classify
    //-----------------------------------------------------------------
    logic [63:0] class_res;
    always_comb begin
        logic a_sub;
        a_sub = ~a_zero & ~a_inf & ~a_nan &
                (p1_fmt ? (a_cval[62:52] == 11'd0) : (a_cval[30:23] == 8'd0));
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

    //-----------------------------------------------------------------
    // integer -> floating point
    //-----------------------------------------------------------------
    logic        i2f_sign, i2f_zero;
    logic [63:0] i2f_norm;
    int          i2f_shift;
    always_comb begin
        logic [63:0] v, mag;
        v = p1_iw ? p1_a : (p1_isg ? {{32{p1_a[31]}}, p1_a[31:0]} : {32'd0, p1_a[31:0]});
        i2f_sign  = p1_isg & v[63];
        mag       = i2f_sign ? (~v + 64'd1) : v;
        i2f_zero  = (mag == 64'd0);
        i2f_shift = clz64(mag);
        i2f_norm  = mag << i2f_shift;
    end

    //-----------------------------------------------------------------
    // floating point -> integer, first half: the integer part, the guard
    // and the sticky bit (the second half is in P7)
    //-----------------------------------------------------------------
    logic [63:0] f2i_ival, f2i_spec_res;
    logic        f2i_g, f2i_s, f2i_big, f2i_spec;
    always_comb begin
        logic [5:0]  k;
        logic [63:0] m, lmax, lmin;
        iw_lim(p1_iw, p1_isg, lmax, lmin);
        f2i_ival     = 64'd0;
        f2i_g        = 1'b0;
        f2i_s        = 1'b0;
        f2i_big      = 1'b0;
        f2i_spec     = 1'b1;
        f2i_spec_res = 64'd0;
        k            = 6'd0;
        m            = 64'd0;
        if (a_nan) begin
            f2i_spec_res = lmax;
        end else if (a_inf) begin
            f2i_spec_res = a_sign ? (p1_isg ? (~lmin + 64'd1) : 64'd0) : lmax;
        end else if (a_zero) begin
            f2i_spec_res = 64'd0;
        end else begin
            f2i_spec = 1'b0;
            if (a_exp > 63) begin
                f2i_big = 1'b1;
            end else if (a_exp == 63) begin
                f2i_ival = a_sig;
            end else if (a_exp < 0) begin
                f2i_g = (a_exp == -1) & a_sig[63];
                f2i_s = (a_exp == -1) ? (|a_sig[62:0]) : 1'b1;
            end else begin
                k        = ~a_exp[5:0];                 // 63 - a_exp
                f2i_ival = a_sig >> k;
                f2i_g    = a_sig[k - 6'd1];
                for (int i = 0; i < 64; i++) m[i] = ({1'b0, k} > 7'(i + 1));
                f2i_s    = |(a_sig & m);
            end
        end
    end

    //-----------------------------------------------------------------
    // multiply and add : the operands as the datapath sees them, and the
    // cases that never reach the datapath
    //-----------------------------------------------------------------
    logic        y_is_one, has_z, z_from_c, x_neg, z_neg;
    always_comb begin
        y_is_one = (p1_op == FOP_ADD) || (p1_op == FOP_SUB);
        has_z    = (p1_op != FOP_MUL);
        z_from_c = (p1_op >= FOP_MADD) && (p1_op <= FOP_NMADD);
        x_neg    = (p1_op == FOP_NMSUB) || (p1_op == FOP_NMADD);
        z_neg    = (p1_op == FOP_SUB)   || (p1_op == FOP_MSUB) || (p1_op == FOP_NMADD);
    end

    logic        x_sign, x_zero, x_inf, x_nan, x_snan;
    logic        y_sign, y_zero, y_inf, y_nan, y_snan;
    logic        zz_sign, zz_zero, zz_inf, zz_nan, zz_snan;
    logic signed [EW-1:0] x_exp, y_exp, zz_exp;
    logic [63:0] x_sig, y_sig, zz_sig, z_packed;
    always_comb begin
        x_sign = a_sign ^ x_neg;
        x_exp  = a_exp;  x_sig = a_sig;
        x_zero = a_zero; x_inf = a_inf; x_nan = a_nan; x_snan = a_snan;
        if (y_is_one) begin
            y_sign = 1'b0; y_exp = '0; y_sig = {1'b1, 63'd0};
            y_zero = 1'b0; y_inf = 1'b0; y_nan = 1'b0; y_snan = 1'b0;
        end else begin
            y_sign = b_sign; y_exp = b_exp; y_sig = b_sig;
            y_zero = b_zero; y_inf = b_inf; y_nan = b_nan; y_snan = b_snan;
        end
        if (z_from_c) begin
            zz_sign = c_sign ^ z_neg; zz_exp = c_exp; zz_sig = c_sig;
            zz_zero = c_zero; zz_inf = c_inf; zz_nan = c_nan; zz_snan = c_snan;
            z_packed = p1_fmt ? {c_cval[63] ^ z_neg, c_cval[62:0]}
                              : {32'hFFFF_FFFF, c_cval[31] ^ z_neg, c_cval[30:0]};
        end else begin
            zz_sign = b_sign ^ z_neg; zz_exp = b_exp; zz_sig = b_sig;
            zz_zero = b_zero; zz_inf = b_inf; zz_nan = b_nan; zz_snan = b_snan;
            z_packed = p1_fmt ? {b_cval[63] ^ z_neg, b_cval[62:0]}
                              : {32'hFFFF_FFFF, b_cval[31] ^ z_neg, b_cval[30:0]};
        end
    end

    logic        prod_sign, prod_inf, prod_zero, fma_special, zsum_sign;
    logic [63:0] fma_sp_res;
    logic [4:0]  fma_sp_flags;
    assign prod_sign = x_sign ^ y_sign;
    assign prod_inf  = (x_inf & ~y_zero) | (y_inf & ~x_zero);
    assign prod_zero = (x_zero | y_zero) & ~x_inf & ~y_inf;
    assign zsum_sign = (!has_z)               ? prod_sign :
                       (prod_sign == zz_sign) ? prod_sign :
                       ((p1_rm == RM_RDN_L) ? 1'b1 : 1'b0);

    always_comb begin
        fma_special  = 1'b1;
        fma_sp_res   = p1_fmt ? QNAN64 : QNAN32;
        fma_sp_flags = 5'd0;
        if ((x_inf & y_zero) | (y_inf & x_zero)) begin
            fma_sp_flags[F_NV] = 1'b1;
        end else if (x_nan | y_nan | (has_z & zz_nan)) begin
            if (x_snan | y_snan | (has_z & zz_snan)) fma_sp_flags[F_NV] = 1'b1;
        end else if (prod_inf) begin
            if (has_z & zz_inf & (zz_sign != prod_sign)) begin
                fma_sp_flags[F_NV] = 1'b1;
            end else begin
                fma_sp_res = p1_fmt ? {prod_sign, 11'h7FF, 52'd0}
                                    : {32'hFFFF_FFFF, prod_sign, 8'hFF, 23'd0};
            end
        end else if (has_z & zz_inf) begin
            fma_sp_res = p1_fmt ? {zz_sign, 11'h7FF, 52'd0}
                                : {32'hFFFF_FFFF, zz_sign, 8'hFF, 23'd0};
        end else if (prod_zero & (~has_z | zz_zero)) begin
            fma_sp_res = p1_fmt ? {zsum_sign, 63'd0}
                                : {32'hFFFF_FFFF, zsum_sign, 31'd0};
        end else if (prod_zero) begin
            fma_sp_res = z_packed;
        end else begin
            fma_special = 1'b0;
        end
    end

    //-----------------------------------------------------------------
    // divide / square root of special values
    //-----------------------------------------------------------------
    logic [63:0] ds_sp_res;
    logic [4:0]  ds_sp_flags;
    always_comb begin
        logic dsg;
        dsg         = a_sign ^ b_sign;
        ds_sp_res   = p1_fmt ? QNAN64 : QNAN32;
        ds_sp_flags = 5'd0;
        if (p1_op == FOP_DIV) begin
            if (a_nan | b_nan) begin
                if (a_snan | b_snan) ds_sp_flags[F_NV] = 1'b1;
            end else if (a_inf & b_inf) begin
                ds_sp_flags[F_NV] = 1'b1;
            end else if (a_zero & b_zero) begin
                ds_sp_flags[F_NV] = 1'b1;
            end else if (a_inf) begin
                ds_sp_res = p1_fmt ? {dsg, 11'h7FF, 52'd0}
                                   : {32'hFFFF_FFFF, dsg, 8'hFF, 23'd0};
            end else if (b_zero) begin
                ds_sp_flags[F_DZ] = 1'b1;
                ds_sp_res = p1_fmt ? {dsg, 11'h7FF, 52'd0}
                                   : {32'hFFFF_FFFF, dsg, 8'hFF, 23'd0};
            end else begin                       // b_inf | a_zero
                ds_sp_res = p1_fmt ? {dsg, 63'd0} : {32'hFFFF_FFFF, dsg, 31'd0};
            end
        end else begin
            if (a_nan) begin
                if (a_snan) ds_sp_flags[F_NV] = 1'b1;
            end else if (a_zero) begin
                ds_sp_res = p1_fmt ? {a_sign, 63'd0} : {32'hFFFF_FFFF, a_sign, 31'd0};
            end else if (a_sign) begin
                ds_sp_flags[F_NV] = 1'b1;
            end else begin                       // a_inf
                ds_sp_res = p1_fmt ? {1'b0, 11'h7FF, 52'd0}
                                   : {32'hFFFF_FFFF, 1'b0, 8'hFF, 23'd0};
            end
        end
    end

    //-----------------------------------------------------------------
    // the bundle: what an operation that is not a multiply and add (or
    // one of special values) asks of the stages after the wait. For a
    // conversion to an integer the integer part goes in b_hi and its
    // special result in b_sp.
    //-----------------------------------------------------------------
    logic                 b_use_rnd, b_is_int, b_rsign;
    logic [63:0]          b_sp, b_hi;
    logic [4:0]           b_flags;
    logic signed [EW-1:0] b_rexp;
    logic                 p2_use_fma;

    always_comb begin
        b_sp      = 64'd0;
        b_is_int  = 1'b0;
        b_flags   = 5'd0;
        b_use_rnd = 1'b0;
        b_rsign   = 1'b0;
        b_rexp    = '0;
        b_hi      = 64'd0;
        p2_use_fma = 1'b0;
        case (p1_op)
            FOP_SGNJ, FOP_SGNJN, FOP_SGNJX: b_sp = sgnj_res;
            FOP_MIN, FOP_MAX: begin
                b_sp = minmax_res;  b_flags = minmax_flags;
            end
            FOP_EQ, FOP_LT, FOP_LE: begin
                b_sp = {63'd0, cmp_res};  b_is_int = 1'b1;  b_flags = cmp_flags;
            end
            FOP_CLASS: begin
                b_sp = class_res;  b_is_int = 1'b1;
            end
            FOP_MV_X_F: begin
                b_sp = p1_fmt ? p1_a : {{32{p1_a[31]}}, p1_a[31:0]};
                b_is_int = 1'b1;
            end
            FOP_MV_F_X: b_sp = p1_fmt ? p1_a : {32'hFFFF_FFFF, p1_a[31:0]};
            FOP_CVT_S_D, FOP_CVT_D_S: begin
                if (a_nan)       b_sp = (p1_op == FOP_CVT_S_D) ? QNAN32 : QNAN64;
                else if (a_inf)  b_sp = (p1_op == FOP_CVT_S_D)
                                        ? {32'hFFFF_FFFF, a_sign, 8'hFF, 23'd0}
                                        : {a_sign, 11'h7FF, 52'd0};
                else if (a_zero) b_sp = (p1_op == FOP_CVT_S_D)
                                        ? {32'hFFFF_FFFF, a_sign, 31'd0}
                                        : {a_sign, 63'd0};
                else begin
                    b_rsign = a_sign;  b_rexp = a_exp;  b_hi = a_sig;  b_use_rnd = 1'b1;
                end
                if (a_snan) b_flags[F_NV] = 1'b1;
            end
            FOP_CVT_F_I: begin
                if (i2f_zero) b_sp = p1_fmt ? 64'd0 : {32'hFFFF_FFFF, 32'd0};
                else begin
                    b_rsign = i2f_sign;  b_rexp = EW'(63 - i2f_shift);
                    b_hi    = i2f_norm;  b_use_rnd = 1'b1;
                end
            end
            FOP_CVT_I_F: begin
                b_is_int = 1'b1;
                b_hi     = f2i_ival;
                b_sp     = f2i_spec_res;
            end
            FOP_DIV, FOP_SQRT: begin
                b_sp = ds_sp_res;  b_flags = ds_sp_flags;
            end
            FOP_ADD, FOP_SUB, FOP_MUL,
            FOP_MADD, FOP_MSUB, FOP_NMSUB, FOP_NMADD: begin
                if (fma_special) begin
                    b_sp = fma_sp_res;  b_flags = fma_sp_flags;
                end else begin
                    p2_use_fma = 1'b1;
                end
            end
            default: b_sp = 64'd0;
        endcase
    end

    //-----------------------------------------------------------------
    // P2 registers
    //-----------------------------------------------------------------
    // the control and the bundle, carried through P2 .. P5
    typedef struct packed {
        logic [TAG_W-1:0]   tag;
        logic               fmt;
        logic               rfmt;       // the format the rounder makes
        logic [2:0]         rm;
        logic               isg, iw;
        logic               f2i;        // FCVT.I.F
        logic               ds;         // a divide / square root (for in_ready)
        logic               use_fma;
        // the bundle
        logic               use_rnd, is_int, rsign;
        logic [63:0]        sp, hi;
        logic [4:0]         flags;
        logic signed [EW-1:0] rexp;
        logic               f2i_g, f2i_s, f2i_big, f2i_spec, f2i_snv, a_sign;
    } ctl_t;

    // what the multiply and add carries besides its datapath
    typedef struct packed {
        logic signed [EW-1:0] sexp;     // x_exp + y_exp
        logic signed [EW-1:0] zexp;
        logic [63:0]        zsig;
        logic               zsign, zzero, has_z, psign;
    } fma_t;

    logic p2_v, p3_v, p4_v, p5_v;
    ctl_t p2_c, p3_c, p4_c, p5_c;
    fma_t p2_f, p3_f;
    logic [63:0]  pp_ll, pp_hl, pp_lh, pp_hh;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) p2_v <= 1'b0;
        else        p2_v <= p1_go & ~p1_ds_eng;
    end

    always_ff @(posedge clk) begin
        p2_c.tag      <= p1_tag;
        p2_c.fmt      <= p1_fmt;
        p2_c.rfmt     <= (p1_op == FOP_CVT_S_D) ? 1'b0 :
                         (p1_op == FOP_CVT_D_S) ? 1'b1 : p1_fmt;
        p2_c.rm       <= p1_rm;
        p2_c.isg      <= p1_isg;
        p2_c.iw       <= p1_iw;
        p2_c.f2i      <= (p1_op == FOP_CVT_I_F);
        p2_c.ds       <= is_ds(p1_op);
        p2_c.use_fma  <= p2_use_fma;
        p2_c.use_rnd  <= b_use_rnd;
        p2_c.is_int   <= b_is_int;
        p2_c.rsign    <= b_rsign;
        p2_c.sp       <= b_sp;
        p2_c.hi       <= b_hi;
        p2_c.flags    <= b_flags;
        p2_c.rexp     <= b_rexp;
        p2_c.f2i_g    <= f2i_g;
        p2_c.f2i_s    <= f2i_s;
        p2_c.f2i_big  <= f2i_big;
        p2_c.f2i_spec <= f2i_spec;
        p2_c.f2i_snv  <= a_nan | a_inf;
        p2_c.a_sign   <= a_sign;

        p2_f.sexp  <= x_exp + y_exp;
        p2_f.zexp  <= zz_exp;
        p2_f.zsig  <= zz_sig;
        p2_f.zsign <= zz_sign;
        p2_f.zzero <= zz_zero;
        p2_f.has_z <= has_z;
        p2_f.psign <= prod_sign;

        // the partial products, out of the held significands
        pp_ll <= {32'd0, x_sig[31:0]}  * {32'd0, y_sig[31:0]};
        pp_hl <= {32'd0, x_sig[63:32]} * {32'd0, y_sig[31:0]};
        pp_lh <= {32'd0, x_sig[31:0]}  * {32'd0, y_sig[63:32]};
        pp_hh <= {32'd0, x_sig[63:32]} * {32'd0, y_sig[63:32]};
    end

    //=================================================================
    // P3 : the sum of the partial products
    //=================================================================
    logic [127:0] prod;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) p3_v <= 1'b0;
        else        p3_v <= p2_v;
    end

    always_ff @(posedge clk) begin
        p3_c <= p2_c;
        p3_f <= p2_f;
        prod <= {pp_hh, 64'd0} + {32'd0, pp_hl, 32'd0} +
                {32'd0, pp_lh, 32'd0} + {64'd0, pp_ll};
    end

    //=================================================================
    // P4 : the alignment of the addend
    //=================================================================
    logic [128:0]          al_gt, al_ls;
    logic                  al_st, al_add, al_sgn_gt, al_sgn_ls;
    logic signed [EW-1:0]  p4_cexp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) p4_v <= 1'b0;
        else        p4_v <= p3_v;
    end

    always_ff @(posedge clk) begin
        logic [127:0] pn_v, zn_v;
        int signed    pexp_v, d_v;
        logic [128:0] sh;

        p4_c <= p3_c;

        pn_v   = prod[127] ? prod : (prod << 1);
        pexp_v = prod[127] ? (int'(p3_f.sexp) + 1) : int'(p3_f.sexp);
        zn_v   = {p3_f.zsig, 64'd0};

        if (!p3_f.has_z || p3_f.zzero) begin
            al_gt     <= {1'b0, pn_v};
            al_ls     <= 129'd0;
            al_st     <= 1'b0;
            al_add    <= 1'b1;
            al_sgn_gt <= p3_f.psign;
            al_sgn_ls <= p3_f.psign;
            p4_cexp   <= EW'(pexp_v);
        end else begin
            d_v = pexp_v - int'(p3_f.zexp);
            if (d_v >= 0) begin
                sh        = shr_jam(zn_v, d_v);
                al_gt     <= {1'b0, pn_v};
                al_ls     <= {1'b0, sh[127:0]};
                al_st     <= sh[128];
                al_sgn_gt <= p3_f.psign;
                al_sgn_ls <= p3_f.zsign;
                p4_cexp   <= EW'(pexp_v);
            end else begin
                sh        = shr_jam(pn_v, -d_v);
                al_gt     <= {1'b0, zn_v};
                al_ls     <= {1'b0, sh[127:0]};
                al_st     <= sh[128];
                al_sgn_gt <= p3_f.zsign;
                al_sgn_ls <= p3_f.psign;
                p4_cexp   <= p3_f.zexp;
            end
            al_add <= (p3_f.psign == p3_f.zsign);
        end
    end

    //=================================================================
    // P5 : the addition
    //=================================================================
    logic [128:0]          sum_r;
    logic                  sum_sign, stick_sum;
    logic signed [EW-1:0]  p5_cexp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) p5_v <= 1'b0;
        else        p5_v <= p4_v;
    end

    always_ff @(posedge clk) begin
        logic [128:0] sum_add, sum_sub, sum_rev;

        p5_c <= p4_c;
        p5_cexp <= p4_cexp;

        // the three results side by side, one of them picked
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
    end

    //=================================================================
    // the divide / square root engine (as in CORE_FPU)
    //=================================================================
    // started when its operation enters P1, taken back with it there
    logic ds_start, ds_kill, ds_inject, ds_out;
    assign ds_start  = p0_go & is_ds(p0_op) & ~p0_ds_special;
    assign ds_kill   = kill1 & p1_v & p1_ds_eng;
    // done, its operation committed, and the pipeline behind P6 empty
    assign ds_inject = ds_run & ds_cmt & (ds_cnt == 8'd0) & ~p5_v;

    logic [127:0] dv_al;
    assign dv_al = ds_fmt ? dv_quo : {dv_quo[63:0], 64'd0};

    logic [127:0]          ds_sig;
    logic signed [EW-1:0]  ds_exp;
    logic                  ds_sticky, ds_sign;
    always_comb begin
        if (is_sqrt_r) begin
            ds_sig    = {sq_root, 64'd0};
            ds_exp    = sq_exp;
            ds_sticky = |sq_rem;
            ds_sign   = 1'b0;
        end else begin
            ds_sig    = dv_al[127] ? dv_al : (dv_al << 1);
            ds_exp    = dv_al[127] ? dv_exp : (dv_exp - EW'(1));
            ds_sticky = |dv_rem;
            ds_sign   = dv_sign;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds_run <= 1'b0;
            ds_cmt <= 1'b0;
            ds_cnt <= 8'd0;
        end else if (ds_kill) begin
            ds_run <= 1'b0;
            ds_cmt <= 1'b0;
        end else if (ds_start) begin
            ds_run <= 1'b1;
            ds_cmt <= 1'b0;
            ds_cnt <= (p0_op == FOP_SQRT) ? 8'd64 : (p0_fmt ? 8'd128 : 8'd64);
        end else begin
            if (p1_go && p1_ds_eng) ds_cmt <= 1'b1;
            if (ds_inject)          ds_run <= 1'b0;
            if (ds_run && (ds_cnt != 8'd0)) ds_cnt <= ds_cnt - 8'd1;
        end
    end

    always_ff @(posedge clk) begin
        if (ds_start) begin
            ds_fmt    <= p0_fmt;
            ds_rm     <= p0_rm;
            ds_tag    <= p0_tag;
            is_sqrt_r <= (p0_op == FOP_SQRT);
            dv_rem    <= {1'b0, w_a_sig};
            dv_div    <= w_b_sig;
            dv_quo    <= 128'd0;
            dv_exp    <= EW'(w_a_exp - w_b_exp);
            dv_sign   <= w_a_sign ^ w_b_sign;
            // an odd exponent leaves a factor of two in the radicand
            sq_rad    <= w_a_exp[0] ? {w_a_sig, 64'd0} : {1'b0, w_a_sig, 63'd0};
            sq_rem    <= 66'd0;
            sq_root   <= 64'd0;
            sq_exp    <= EW'(w_a_exp >>> 1);
        end else if (ds_run && (ds_cnt != 8'd0)) begin
            if (is_sqrt_r) begin
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
            end else begin
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
            end
        end
    end

    //=================================================================
    // P6 : the select
    //=================================================================
    logic [128:0]          sum_norm;
    logic                  fma_zero, zero_sign;
    logic [127:0]          fma_sig;
    logic signed [EW-1:0]  fma_exp;
    logic                  fma_sticky;
    always_comb begin
        int sum_lz;
        sum_lz     = lzc129(sum_r);
        fma_zero   = (sum_r == 129'd0);
        sum_norm   = sum_r << sum_lz;
        fma_sig    = sum_norm[128:1];
        fma_sticky = sum_norm[0] | stick_sum;
        fma_exp    = EW'(int'(p5_cexp) + 1 - sum_lz);
        zero_sign  = (p5_c.rm == RM_RDN_L);
    end

    logic                 q_v, q_ds, q_use_rnd, q_is_int, q_f2i;
    logic [TAG_W-1:0]     q_tag;
    logic [63:0]          q_sp;
    logic [4:0]           q_flags;
    logic                 q_rsign, q_rsticky, q_rfmt;
    logic signed [13:0]   q_rexp;
    logic [127:0]         q_rsig;
    logic [2:0]           q_rm;
    logic                 q_isg, q_iw, q_g, q_s, q_big, q_spec, q_snv, q_asign;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) q_v <= 1'b0;
        else        q_v <= p5_v | ds_inject;
    end

    always_ff @(posedge clk) begin
        // what comes from the bundle unless overridden below
        q_tag     <= p5_c.tag;
        q_ds      <= p5_c.ds;
        q_rm      <= p5_c.rm;
        q_rfmt    <= p5_c.rfmt;
        q_isg     <= p5_c.isg;
        q_iw      <= p5_c.iw;
        q_f2i     <= p5_c.f2i;
        q_g       <= p5_c.f2i_g;
        q_s       <= p5_c.f2i_s;
        q_big     <= p5_c.f2i_big;
        q_spec    <= p5_c.f2i_spec;
        q_snv     <= p5_c.f2i_snv;
        q_asign   <= p5_c.a_sign;
        q_is_int  <= p5_c.is_int;
        q_sp      <= p5_c.sp;
        q_flags   <= p5_c.flags;
        q_use_rnd <= p5_c.use_rnd;
        q_rsign   <= p5_c.rsign;
        q_rexp    <= 14'(p5_c.rexp);
        q_rsig    <= {p5_c.hi, 64'd0};
        q_rsticky <= 1'b0;

        if (ds_inject) begin
            q_tag     <= ds_tag;
            q_ds      <= 1'b1;
            q_rm      <= ds_rm;
            q_rfmt    <= ds_fmt;
            q_f2i     <= 1'b0;
            q_is_int  <= 1'b0;
            q_sp      <= 64'd0;
            q_flags   <= 5'd0;
            q_use_rnd <= 1'b1;
            q_rsign   <= ds_sign;
            q_rexp    <= 14'(ds_exp);
            q_rsig    <= ds_sig;
            q_rsticky <= ds_sticky;
        end else if (p5_c.use_fma) begin
            if (fma_zero) begin
                // everything cancelled out
                q_sp      <= p5_c.fmt ? {zero_sign, 63'd0}
                                      : {32'hFFFF_FFFF, zero_sign, 31'd0};
                q_use_rnd <= 1'b0;
            end else begin
                q_rsign   <= sum_sign;
                q_rexp    <= 14'(fma_exp);
                q_rsig    <= fma_sig;
                q_rsticky <= fma_sticky;
                q_use_rnd <= 1'b1;
            end
        end
    end

    //=================================================================
    // P7 : the first half of the rounder; the second half of a
    //      conversion to an integer
    //=================================================================
    logic [63:0] rnd_result;
    logic [4:0]  rnd_flags;

    FPU_ROUND u_round
        (
            .clk       (clk),
            .rst_n     (rst_n),
            .load      (q_v),
            .sign      (q_rsign),
            .exp_in    (q_rexp),
            .sig_in    (q_rsig),
            .sticky_in (q_rsticky),
            .fmt       (q_rfmt),
            .rm        (q_rm),
            .result    (rnd_result),
            .flags     (rnd_flags)
        );

    logic [63:0] f2i_res;
    logic [4:0]  f2i_flags;
    always_comb begin
        logic        inc_i, ovf, nz;
        logic [63:0] v, v_inc, v_neg, v_neg_inc, lmax, lmin;
        iw_lim(q_iw, q_isg, lmax, lmin);
        v = q_rsig[127:64];                 // the integer part
        case (q_rm)
            3'b000:  inc_i = q_g & (q_s | v[0]);
            3'b001:  inc_i = 1'b0;
            3'b010:  inc_i =  q_asign & (q_g | q_s);
            3'b011:  inc_i = ~q_asign & (q_g | q_s);
            3'b100:  inc_i = q_g;
            default: inc_i = 1'b0;
        endcase
        v_inc     = v + 64'd1;
        v_neg     = ~v + 64'd1;
        v_neg_inc = ~v;
        nz        = (v != 64'd0) | inc_i;
        ovf = q_big;
        if (!q_asign && ((v > lmax) || ((v == lmax) && inc_i)))           ovf = 1'b1;
        if (q_asign &&  q_isg && ((v > lmin) || ((v == lmin) && inc_i))) ovf = 1'b1;
        if (q_asign && !q_isg && nz)                                      ovf = 1'b1;
        f2i_flags = 5'd0;
        if (q_spec) begin
            f2i_res         = q_sp;
            f2i_flags[F_NV] = q_snv;
        end else if (ovf) begin
            f2i_res         = q_asign ? (q_isg ? (~lmin + 64'd1) : 64'd0) : lmax;
            f2i_flags[F_NV] = 1'b1;
        end else begin
            f2i_res         = q_asign ? (inc_i ? v_neg_inc : v_neg)
                                      : (inc_i ? v_inc     : v);
            f2i_flags[F_NX] = q_g | q_s;
        end
        if (!q_iw) f2i_res = {{32{f2i_res[31]}}, f2i_res[31:0]};
    end

    logic                 r_v, r_ds, r_use_rnd, r_is_int;
    logic [TAG_W-1:0]     r_tag;
    logic [63:0]          r_sp;
    logic [4:0]           r_flags;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_v <= 1'b0;
        else        r_v <= q_v;
    end

    always_ff @(posedge clk) begin
        r_tag     <= q_tag;
        r_ds      <= q_ds;
        r_use_rnd <= q_use_rnd;
        r_is_int  <= q_is_int;
        r_sp      <= q_f2i ? f2i_res   : q_sp;
        r_flags   <= q_f2i ? f2i_flags : q_flags;
    end

    //=================================================================
    // P8 : the answer
    //=================================================================
    logic o_ds;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= r_v;
    end

    always_ff @(posedge clk) begin
        out_tag    <= r_tag;
        o_ds       <= r_ds;
        out_is_int <= r_is_int;
        out_result <= r_use_rnd ? rnd_result : r_sp;
        out_flags  <= r_use_rnd ? (r_flags | rnd_flags) : r_flags;
    end

    //=================================================================
    // a divide / square root is in flight from its offer to its answer
    //=================================================================
    assign ds_out = out_valid & o_ds;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ds_busy <= 1'b0;
        else if (accept && is_ds(in_op))
            ds_busy <= 1'b1;
        else if ((kill0 && p0_v && is_ds(p0_op)) ||
                 (kill1 && p1_v && is_ds(p1_op)) || ds_out)
            ds_busy <= 1'b0;
    end

    assign busy = p0_v | p1_v | p2_v | p3_v | p4_v | p5_v | q_v | r_v |
                  out_valid | ds_busy;

endmodule : FPU_PIPE
