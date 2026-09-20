//---------------------------------------------------------------------------
// tb_FPU.sv
//
// CORE_FPU against Berkeley SoftFloat (CPU_CORE_SPEC.md 10.8).
//
//   Every operation is run for both formats, all five rounding modes and a
//   pool of operands built around the places where floating point goes wrong:
//   zeros of both signs, subnormals, the smallest and largest normals, the
//   rounding boundaries, infinities, quiet and signalling NaNs, values that
//   are not NaN boxed, and random bit patterns on top of that.
//
//   The reference is SoftFloat with the RISCV specialisation, reached through
//   DPI (sf_dpi.c). Result and flags are both compared.
//
//   Plusargs:
//     +ops=<list>    only these operations (numbers, comma separated)
//     +rand=<n>      random pairs per operation and format (default 2000)
//     +seed=<n>
//     +verbose       print every mismatch (default: the first 20)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_FPU;

    import "DPI-C" function longint unsigned sf_op(
        input  int            op,
        input  int            fmt,
        input  int            rm,
        input  int            int_signed,
        input  int            int_w,
        input  longint unsigned a,
        input  longint unsigned b,
        input  longint unsigned c,
        output int            flags,
        output int            is_int);

    //-----------------------------------------------------------------
    localparam int FOP_ADD     = 0;
    localparam int FOP_SUB     = 1;
    localparam int FOP_MUL     = 2;
    localparam int FOP_DIV     = 3;
    localparam int FOP_SQRT    = 4;
    localparam int FOP_MADD    = 5;
    localparam int FOP_MSUB    = 6;
    localparam int FOP_NMSUB   = 7;
    localparam int FOP_NMADD   = 8;
    localparam int FOP_SGNJ    = 9;
    localparam int FOP_SGNJN   = 10;
    localparam int FOP_SGNJX   = 11;
    localparam int FOP_MIN     = 12;
    localparam int FOP_MAX     = 13;
    localparam int FOP_EQ      = 14;
    localparam int FOP_LT      = 15;
    localparam int FOP_LE      = 16;
    localparam int FOP_CLASS   = 17;
    localparam int FOP_MV_X_F  = 18;
    localparam int FOP_MV_F_X  = 19;
    localparam int FOP_CVT_S_D = 20;
    localparam int FOP_CVT_D_S = 21;
    localparam int FOP_CVT_F_I = 22;
    localparam int FOP_CVT_I_F = 23;

    string op_name [0:23];

    initial begin
        op_name[0]="FADD";     op_name[1]="FSUB";     op_name[2]="FMUL";
        op_name[3]="FDIV";     op_name[4]="FSQRT";    op_name[5]="FMADD";
        op_name[6]="FMSUB";    op_name[7]="FNMSUB";   op_name[8]="FNMADD";
        op_name[9]="FSGNJ";    op_name[10]="FSGNJN";  op_name[11]="FSGNJX";
        op_name[12]="FMIN";    op_name[13]="FMAX";    op_name[14]="FEQ";
        op_name[15]="FLT";     op_name[16]="FLE";     op_name[17]="FCLASS";
        op_name[18]="FMV.X.F"; op_name[19]="FMV.F.X"; op_name[20]="FCVT.S.D";
        op_name[21]="FCVT.D.S";op_name[22]="FCVT.F.I";op_name[23]="FCVT.I.F";
    end

    //-----------------------------------------------------------------
    // clock and DUT
    //-----------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #10 clk = ~clk;

    logic        start, kill, busy, done, ack;
    logic [4:0]  op;
    logic        fmt;
    logic [2:0]  rm;
    logic        int_signed, int_w;
    logic [63:0] a, b, c;
    logic [63:0] result;
    logic        result_is_int;
    logic [4:0]  flags;

    CORE_FPU dut
        (
            .clk(clk), .rst_n(rst_n),
            .start(start), .kill(kill), .op(op), .fmt(fmt), .rm(rm),
            .int_signed(int_signed), .int_w(int_w),
            .a(a), .b(b), .c(c),
            .busy(busy), .done(done), .ack(ack),
            .result(result), .result_is_int(result_is_int), .flags(flags)
        );

    //-----------------------------------------------------------------
    // operand pools
    //-----------------------------------------------------------------
    localparam int NP64 = 34;
    localparam int NP32 = 34;
    logic [63:0] pool64 [0:NP64-1];
    logic [63:0] pool32 [0:NP32-1];

    initial begin
        pool64[0]  = 64'h0000_0000_0000_0000;   // +0
        pool64[1]  = 64'h8000_0000_0000_0000;   // -0
        pool64[2]  = 64'h0000_0000_0000_0001;   // smallest subnormal
        pool64[3]  = 64'h8000_0000_0000_0001;
        pool64[4]  = 64'h000F_FFFF_FFFF_FFFF;   // largest subnormal
        pool64[5]  = 64'h0010_0000_0000_0000;   // smallest normal
        pool64[6]  = 64'h8010_0000_0000_0000;
        pool64[7]  = 64'h3FF0_0000_0000_0000;   // 1.0
        pool64[8]  = 64'hBFF0_0000_0000_0000;   // -1.0
        pool64[9]  = 64'h4000_0000_0000_0000;   // 2.0
        pool64[10] = 64'h3FE0_0000_0000_0000;   // 0.5
        pool64[11] = 64'h7FEF_FFFF_FFFF_FFFF;   // largest normal
        pool64[12] = 64'hFFEF_FFFF_FFFF_FFFF;
        pool64[13] = 64'h7FF0_0000_0000_0000;   // +inf
        pool64[14] = 64'hFFF0_0000_0000_0000;   // -inf
        pool64[15] = 64'h7FF8_0000_0000_0000;   // canonical NaN
        pool64[16] = 64'h7FF4_0000_0000_0000;   // signalling NaN
        pool64[17] = 64'hFFF7_FFFF_FFFF_FFFF;   // signalling NaN, negative
        pool64[18] = 64'h3FF0_0000_0000_0001;   // 1 + 1ulp
        pool64[19] = 64'h3FEF_FFFF_FFFF_FFFF;   // 1 - 1ulp
        pool64[20] = 64'h4340_0000_0000_0000;   // 2^53
        pool64[21] = 64'h4330_0000_0000_0000;   // 2^52
        pool64[22] = 64'h41E0_0000_0000_0000;   // 2^31
        pool64[23] = 64'h43E0_0000_0000_0000;   // 2^63
        pool64[24] = 64'hC3E0_0000_0000_0000;   // -2^63
        pool64[25] = 64'h4059_0000_0000_0000;   // 100.0
        pool64[26] = 64'h3FB9_9999_9999_999A;   // 0.1
        pool64[27] = 64'h0008_0000_0000_0000;   // subnormal, middle
        pool64[28] = 64'h0000_0000_0000_0003;
        pool64[29] = 64'h7FE0_0000_0000_0000;
        pool64[30] = 64'h0010_0000_0000_0001;
        pool64[31] = 64'hC000_0000_0000_0000;   // -2.0
        pool64[32] = 64'h3CA0_0000_0000_0000;   // 2^-53
        pool64[33] = 64'h4330_0000_0000_0001;

        pool32[0]  = {32'hFFFF_FFFF, 32'h0000_0000};   // +0
        pool32[1]  = {32'hFFFF_FFFF, 32'h8000_0000};   // -0
        pool32[2]  = {32'hFFFF_FFFF, 32'h0000_0001};   // smallest subnormal
        pool32[3]  = {32'hFFFF_FFFF, 32'h8000_0001};
        pool32[4]  = {32'hFFFF_FFFF, 32'h007F_FFFF};   // largest subnormal
        pool32[5]  = {32'hFFFF_FFFF, 32'h0080_0000};   // smallest normal
        pool32[6]  = {32'hFFFF_FFFF, 32'h8080_0000};
        pool32[7]  = {32'hFFFF_FFFF, 32'h3F80_0000};   // 1.0
        pool32[8]  = {32'hFFFF_FFFF, 32'hBF80_0000};   // -1.0
        pool32[9]  = {32'hFFFF_FFFF, 32'h4000_0000};   // 2.0
        pool32[10] = {32'hFFFF_FFFF, 32'h3F00_0000};   // 0.5
        pool32[11] = {32'hFFFF_FFFF, 32'h7F7F_FFFF};   // largest normal
        pool32[12] = {32'hFFFF_FFFF, 32'hFF7F_FFFF};
        pool32[13] = {32'hFFFF_FFFF, 32'h7F80_0000};   // +inf
        pool32[14] = {32'hFFFF_FFFF, 32'hFF80_0000};   // -inf
        pool32[15] = {32'hFFFF_FFFF, 32'h7FC0_0000};   // canonical NaN
        pool32[16] = {32'hFFFF_FFFF, 32'h7FA0_0000};   // signalling NaN
        pool32[17] = {32'hFFFF_FFFF, 32'hFFBF_FFFF};
        pool32[18] = {32'hFFFF_FFFF, 32'h3F80_0001};   // 1 + 1ulp
        pool32[19] = {32'hFFFF_FFFF, 32'h3F7F_FFFF};   // 1 - 1ulp
        pool32[20] = {32'hFFFF_FFFF, 32'h4B00_0000};   // 2^23
        pool32[21] = {32'hFFFF_FFFF, 32'h4B80_0000};   // 2^24
        pool32[22] = {32'hFFFF_FFFF, 32'h4F00_0000};   // 2^31
        pool32[23] = {32'hFFFF_FFFF, 32'h5F00_0000};   // 2^63
        pool32[24] = {32'hFFFF_FFFF, 32'hDF00_0000};   // -2^63
        pool32[25] = {32'hFFFF_FFFF, 32'h42C8_0000};   // 100.0
        pool32[26] = {32'hFFFF_FFFF, 32'h3DCC_CCCD};   // 0.1
        pool32[27] = {32'hFFFF_FFFF, 32'h0040_0000};
        pool32[28] = {32'hFFFF_FFFF, 32'h0000_0003};
        pool32[29] = {32'hFFFF_FFFF, 32'h7F00_0000};
        pool32[30] = {32'hFFFF_FFFF, 32'h0080_0001};
        pool32[31] = {32'hFFFF_FFFF, 32'hC000_0000};   // -2.0
        pool32[32] = 64'h0000_0000_3F80_0000;          // 1.0 but NOT boxed
        pool32[33] = 64'h1234_5678_3F80_0000;          // not boxed either
    end

    //-----------------------------------------------------------------
    int  errors, checks, shown;
    bit  verbose;
    int  n_rand;
    int  seed;
    string op_sel;

    task automatic run_one(input int o, input int f, input int r,
                           input int isg, input int iw,
                           input logic [63:0] va, input logic [63:0] vb,
                           input logic [63:0] vc);
        logic [63:0] exp_res;
        int          exp_flags, exp_is_int;
        begin
            exp_res = sf_op(o, f, r, isg, iw, va, vb, vc, exp_flags, exp_is_int);

            @(negedge clk);
            op = 5'(o); fmt = f[0]; rm = 3'(r);
            int_signed = isg[0]; int_w = iw[0];
            a = va; b = vb; c = vc;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            while (!done) @(posedge clk);

            checks++;
            if ((result !== exp_res) || (flags !== 5'(exp_flags)) ||
                (result_is_int !== 1'(exp_is_int))) begin
                errors++;
                if (verbose || (shown < 20)) begin
                    shown++;
                    $display(" [FAIL] %s fmt=%0d rm=%0d %s%s", op_name[o], f, r,
                             (o == FOP_CVT_F_I || o == FOP_CVT_I_F)
                               ? $sformatf("sgn=%0d w=%0d ", isg, iw) : "",
                             "");
                    $display("        a=%016h b=%016h c=%016h", va, vb, vc);
                    $display("        got %016h flags=%05b int=%0d",
                             result, flags, result_is_int);
                    $display("        exp %016h flags=%05b int=%0d",
                             exp_res, 5'(exp_flags), exp_is_int);
                end
            end

            @(negedge clk);
            ack = 1'b1;
            @(posedge clk);
            @(negedge clk);
            ack = 1'b0;
        end
    endtask

    // +ops=1,2,5 : only those operations
    function automatic bit sel_has(input int o);
        if (op_sel.len() == 0) return 1'b1;
        return has_sub(op_sel, $sformatf(",%0d,", o));
    endfunction

    function automatic bit has_sub(input string hay, input string needle);
        int i, j;
        bit ok;
        string h;
        h = {",", hay, ","};
        for (i = 0; i + needle.len() <= h.len(); i++) begin
            ok = 1'b1;
            for (j = 0; j < needle.len(); j++)
                if (h.getc(i+j) != needle.getc(j)) ok = 1'b0;
            if (ok) return 1'b1;
        end
        return 1'b0;
    endfunction

    //-----------------------------------------------------------------
    int  ops_to_run [$];
    int  o, f, r, i, j, k;
    logic [63:0] va, vb, vc;

    initial begin
        errors = 0; checks = 0; shown = 0;
        verbose = $test$plusargs("verbose");
        if (!$value$plusargs("rand=%d", n_rand)) n_rand = 500;
        if (!$value$plusargs("seed=%d", seed))   seed = 1;
        if (!$value$plusargs("ops=%s", op_sel))  op_sel = "";
        void'($urandom(seed));

        start = 1'b0; ack = 1'b0; kill = 1'b0;
        op = 5'd0; fmt = 1'b0; rm = 3'd0; int_signed = 1'b0; int_w = 1'b0;
        a = 64'd0; b = 64'd0; c = 64'd0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        $display("");
        $display("==========================================================");
        $display(" tb_FPU : CORE_FPU against Berkeley SoftFloat");
        $display("==========================================================");

        for (o = 0; o <= 23; o++) begin
            if (!sel_has(o)) continue;
            for (f = 0; f <= 1; f++) begin
                // the conversions between the two formats only make sense one
                // way round for each source format
                if ((o == FOP_CVT_S_D) && (f == 0)) continue;
                if ((o == FOP_CVT_D_S) && (f == 1)) continue;
                for (r = 0; r <= 4; r++) begin
                    // exhaustive over the pool, both operands
                    for (i = 0; i < NP64; i++) begin
                        for (j = 0; j < NP64; j++) begin
                            va = f ? pool64[i] : pool32[i];
                            vb = f ? pool64[j] : pool32[j];
                            vc = f ? pool64[(i+j) % NP64] : pool32[(i+j) % NP32];
                            if (o == FOP_CVT_F_I) begin
                                // the integer side: use the raw pattern
                                for (k = 0; k < 4; k++)
                                    run_one(o, f, r, k[0], k[1], va, vb, vc);
                            end else if (o == FOP_CVT_I_F) begin
                                for (k = 0; k < 4; k++)
                                    run_one(o, f, r, k[0], k[1], va, vb, vc);
                            end else begin
                                run_one(o, f, r, 0, 0, va, vb, vc);
                            end
                        end
                    end
                    // random on top
                    for (i = 0; i < n_rand; i++) begin
                        va = {$urandom(), $urandom()};
                        vb = {$urandom(), $urandom()};
                        vc = {$urandom(), $urandom()};
                        if (!f) begin
                            va = {32'hFFFF_FFFF, va[31:0]};
                            vb = {32'hFFFF_FFFF, vb[31:0]};
                            vc = {32'hFFFF_FFFF, vc[31:0]};
                        end
                        if ((o == FOP_CVT_F_I) || (o == FOP_CVT_I_F))
                            run_one(o, f, r, i[0], i[1], va, vb, vc);
                        else
                            run_one(o, f, r, 0, 0, va, vb, vc);
                    end
                end
            end
        end

        $display("");
        $display("==========================================================");
        if (errors == 0) $display(" FPU RESULT : PASS   (%0d checks)", checks);
        else             $display(" FPU RESULT : FAIL   (%0d checks, %0d errors)",
                                  checks, errors);
        $display("==========================================================");
        $finish;
    end

endmodule : tb_FPU
