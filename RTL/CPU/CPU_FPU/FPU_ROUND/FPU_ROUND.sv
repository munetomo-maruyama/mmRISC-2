//---------------------------------------------------------------------------
// FPU_ROUND.sv
//
// Normalising, rounding and packing of a finite non zero result
// (CPU_CORE_SPEC.md 10). Every arithmetic unit of the FPU ends here, so the
// rounding, the subnormal handling and the overflow / underflow flags exist
// exactly once.
//
//   The input is a significand that has already been normalised, together
//   with the exponent that belongs to it and a sticky bit for everything that
//   was shifted out below it:
//
//       value = sig[127:0] * 2^(exp - 127)        sig[127] = 1
//
//   128 bits is more than any format needs even when the result lands deep
//   in the subnormal range: a division can push the rounding position up to
//   54 bits below the leading one, and there is room for that here. The unit
//   in front hands over that many bits of its exact result and a sticky bit
//   for everything below them.
//
//   Specials (NaN, infinity, an exactly zero result) are dealt with by the
//   unit in front, not here.
//
//   Tininess is detected **after** rounding, which is what the RISC-V
//   specification asks for (and what SoftFloat does with the RISCV
//   specialisation, the reference model of SIM_FPU).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module FPU_ROUND
    (
        input  logic                sign,
        input  logic signed [13:0]  exp_in,     // unbiased, of sig_in[127]
        input  logic [127:0]        sig_in,     // normalised, sig_in[127] = 1
        input  logic                sticky_in,  // anything below sig_in[0]
        input  logic                fmt,        // 0 : single, 1 : double
        input  logic [2:0]          rm,

        output logic [63:0]         result,     // packed, single is NaN boxed
        output logic [4:0]          flags       // NV DZ OF UF NX
    );

    localparam logic [2:0] RM_RNE = 3'b000;
    localparam logic [2:0] RM_RTZ = 3'b001;
    localparam logic [2:0] RM_RDN = 3'b010;
    localparam logic [2:0] RM_RUP = 3'b011;
    localparam logic [2:0] RM_RMM = 3'b100;

    //-----------------------------------------------------------------
    // what the target format looks like
    //-----------------------------------------------------------------
    int          prec;        // bits of significand, hidden one included
    int signed   e_min;       // exponent of the smallest normal
    int signed   e_max;       // exponent of the largest normal
    int          bias;

    always @(*) begin
        if (fmt) begin
            prec  = 53;  e_min = -1022;  e_max = 1023;  bias = 1023;
        end else begin
            prec  = 24;  e_min =  -126;  e_max =  127;  bias =  127;
        end
    end

    //-----------------------------------------------------------------
    // bring the value to the exponent it will be packed with
    //
    //   a normal result keeps its own exponent, a subnormal one is shifted
    //   down to e_min
    //-----------------------------------------------------------------
    int signed   sub_shift;
    int          shift_n;
    logic [127:0] sig_sh;
    logic         sticky_sh;
    int signed   exp_adj;

    always @(*) begin
        sub_shift = e_min - int'(exp_in);
        if (sub_shift > 0) begin
            shift_n = (sub_shift > 128) ? 128 : sub_shift;
            exp_adj = e_min;
        end else begin
            shift_n = 0;
            exp_adj = int'(exp_in);
        end
    end

    // shift right, keeping everything that leaves in the sticky bit
    logic [127:0] shifted;
    logic         lost;

    always @(*) begin
        if (shift_n == 0) begin
            shifted = sig_in;
            lost    = 1'b0;
        end else if (shift_n >= 128) begin
            shifted = 128'd0;
            lost    = |sig_in;
        end else begin
            shifted = sig_in >> shift_n;
            lost    = |(sig_in & ((128'd1 << shift_n) - 128'd1));
        end
    end

    assign sig_sh    = shifted;
    assign sticky_sh = lost | sticky_in;

    //-----------------------------------------------------------------
    // cut the significand to the precision of the format
    //-----------------------------------------------------------------
    logic [127:0] mant;       // prec bits, right aligned
    logic         guard, rest, lsb;

    always @(*) begin
        mant  = sig_sh >> (128 - prec);
        guard = sig_sh[128 - prec - 1];
        rest  = (|(sig_sh & ((128'd1 << (128 - prec - 1)) - 128'd1))) | sticky_sh;
        lsb   = mant[0];
    end

    //-----------------------------------------------------------------
    // round
    //-----------------------------------------------------------------
    logic inc;

    always @(*) begin
        case (rm)
            RM_RNE:  inc = guard & (rest | lsb);
            RM_RTZ:  inc = 1'b0;
            RM_RDN:  inc =  sign & (guard | rest);
            RM_RUP:  inc = ~sign & (guard | rest);
            RM_RMM:  inc = guard;
            default: inc = 1'b0;
        endcase
    end

    logic [127:0] mant_r;
    int signed    exp_r;

    always @(*) begin
        mant_r = mant + (inc ? 128'd1 : 128'd0);
        exp_r  = exp_adj;
        // the increment can carry into the next power of two
        if (mant_r[prec] == 1'b1) begin
            mant_r = mant_r >> 1;
            exp_r  = exp_adj + 1;
        end
    end

    //-----------------------------------------------------------------
    // is the result tiny
    //
    //   "Tiny after rounding" is about the value that would come out if the
    //   exponent range had no lower end: round the significand at the full
    //   precision of the format, without the shift into the subnormal range,
    //   and see whether it still falls below the smallest normal. Looking at
    //   the exponent field of the packed result instead is not the same
    //   thing: the shift into the subnormal range loses bits and can round
    //   the value up to the smallest normal although the unbounded result
    //   stays below it.
    //-----------------------------------------------------------------
    logic [127:0] mant_u, mant_u_r;
    logic         guard_u, rest_u, lsb_u, inc_u, carry_u, tiny;

    always @(*) begin
        mant_u  = sig_in >> (128 - prec);
        guard_u = sig_in[128 - prec - 1];
        rest_u  = (|(sig_in & ((128'd1 << (128 - prec - 1)) - 128'd1))) | sticky_in;
        lsb_u   = mant_u[0];
        case (rm)
            RM_RNE:  inc_u = guard_u & (rest_u | lsb_u);
            RM_RTZ:  inc_u = 1'b0;
            RM_RDN:  inc_u =  sign & (guard_u | rest_u);
            RM_RUP:  inc_u = ~sign & (guard_u | rest_u);
            RM_RMM:  inc_u = guard_u;
            default: inc_u = 1'b0;
        endcase
        mant_u_r = mant_u + (inc_u ? 128'd1 : 128'd0);
        carry_u  = mant_u_r[prec];
        tiny     = (int'(exp_in) + (carry_u ? 1 : 0)) < e_min;
    end

    //-----------------------------------------------------------------
    // pack, and the flags that go with it
    //-----------------------------------------------------------------
    logic        inexact, is_sub, overflow, to_inf;
    logic [63:0] packed_val;
    logic [62:0] big64;
    logic [30:0] big32;

    assign inexact = guard | rest;
    // after rounding: the exponent field is zero, so the value did not reach
    // the smallest normal
    assign is_sub  = (mant_r[prec-1] == 1'b0);
    assign overflow = (exp_r > e_max);

    always @(*) begin
        case (rm)
            RM_RTZ:  to_inf = 1'b0;
            RM_RDN:  to_inf =  sign;
            RM_RUP:  to_inf = ~sign;
            default: to_inf = 1'b1;          // RNE, RMM
        endcase
    end

    // what an overflow turns into: infinity, or the largest finite value
    assign big64 = to_inf ? {11'h7FF, 52'd0} : {11'h7FE, {52{1'b1}}};
    assign big32 = to_inf ? { 8'hFF,  23'd0} : { 8'hFE, {23{1'b1}}};

    logic [10:0] exp_field64;
    logic [7:0]  exp_field32;

    always @(*) begin
        exp_field64 = is_sub ? 11'd0 : 11'((exp_r + bias));
        exp_field32 = is_sub ?  8'd0 :  8'((exp_r + bias));

        if (overflow) begin
            if (fmt) packed_val = {sign, big64};
            else     packed_val = {32'hFFFF_FFFF, sign, big32};
        end else if (fmt) begin
            packed_val = {sign, exp_field64, mant_r[51:0]};
        end else begin
            packed_val = {32'hFFFF_FFFF, sign, exp_field32, mant_r[22:0]};
        end
    end

    assign result = packed_val;

    always @(*) begin
        flags    = 5'd0;
        flags[0] = inexact | overflow;                       // NX
        flags[1] = tiny & inexact & ~overflow;              // UF
        flags[2] = overflow;                                 // OF
    end

endmodule : FPU_ROUND
