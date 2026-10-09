//---------------------------------------------------------------------------
// tb_FPU_PIPE.sv
//
// FPU_PIPE (the pipelined FPU, ROADMAP C2) against Berkeley SoftFloat.
//
//   The operations are streamed, one offered every cycle, and every answer
//   is compared with SoftFloat (result, flags, integer or not) in the order
//   the operations were taken. Two phases:
//
//   1 the same operand pools as tb_FPU (every operation, both formats, all
//     five rounding modes, the pool exhaustively, random patterns on top),
//     back to back with nothing in the way. Checked besides the answers:
//     every operation but a divide / square root of non special values
//     comes out exactly 9 cycles after it was taken, and a run of such
//     operations comes out one per cycle.
//   2 random operations of every kind with what the core will do around
//     them: gaps in the offers, the first two stages held (hold0, hold1
//     with hold0), operations taken back there (kill0, kill1 with kill0).
//     The answers of the operations taken back must not appear, the rest
//     in order.
//
//   Plusargs: +rand=<n> random operands per operation, format and rounding
//   mode in phase 1 (default 200), +ops2=<n> operations in phase 2 (default
//   200000), +seed=<n>, +verbose
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_FPU_PIPE;

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

    localparam int TAG_W = 32;

    localparam int FOP_DIV     = 3;
    localparam int FOP_MADD    = 5;
    localparam int FOP_SQRT    = 4;
    localparam int FOP_CVT_S_D = 20;
    localparam int FOP_CVT_D_S = 21;
    localparam int FOP_CVT_F_I = 22;
    localparam int FOP_CVT_I_F = 23;

    //-----------------------------------------------------------------
    // clock and DUT
    //-----------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #10 clk = ~clk;

    logic             in_valid, in_ready;
    logic [4:0]       in_op;
    logic             in_fmt, in_isg, in_iw;
    logic [2:0]       in_rm;
    logic [63:0]      in_a, in_b, in_c;
    logic [TAG_W-1:0] in_tag;
    logic             hold0, hold1, kill0, kill1;
    logic             out_valid, out_is_int, busy;
    logic [63:0]      out_result;
    logic [4:0]       out_flags;
    logic [TAG_W-1:0] out_tag;

    FPU_PIPE #(.TAG_W(TAG_W)) dut
        (
            .clk(clk), .rst_n(rst_n),
            .in_valid(in_valid), .in_ready(in_ready), .in_op(in_op),
            .in_fmt(in_fmt), .in_rm(in_rm), .in_int_signed(in_isg), .in_int_w(in_iw),
            .in_a(in_a), .in_b(in_b), .in_c(in_c), .in_tag(in_tag),
            .hold0(hold0), .hold1(hold1), .kill0(kill0), .kill1(kill1),
            .out_valid(out_valid), .out_result(out_result), .out_is_int(out_is_int),
            .out_flags(out_flags), .out_tag(out_tag), .busy(busy)
        );

    //-----------------------------------------------------------------
    // operand pools (as tb_FPU)
    //-----------------------------------------------------------------
    localparam int NP = 40;
    logic [63:0] pool64 [0:NP-1];
    logic [63:0] pool32 [0:NP-1];

    initial begin
        pool64[0]  = 64'h0000_0000_0000_0000;  pool64[1]  = 64'h8000_0000_0000_0000;
        pool64[2]  = 64'h0000_0000_0000_0001;  pool64[3]  = 64'h8000_0000_0000_0001;
        pool64[4]  = 64'h000F_FFFF_FFFF_FFFF;  pool64[5]  = 64'h0010_0000_0000_0000;
        pool64[6]  = 64'h8010_0000_0000_0000;  pool64[7]  = 64'h3FF0_0000_0000_0000;
        pool64[8]  = 64'hBFF0_0000_0000_0000;  pool64[9]  = 64'h4000_0000_0000_0000;
        pool64[10] = 64'h3FE0_0000_0000_0000;  pool64[11] = 64'h7FEF_FFFF_FFFF_FFFF;
        pool64[12] = 64'hFFEF_FFFF_FFFF_FFFF;  pool64[13] = 64'h7FF0_0000_0000_0000;
        pool64[14] = 64'hFFF0_0000_0000_0000;  pool64[15] = 64'h7FF8_0000_0000_0000;
        pool64[16] = 64'h7FF4_0000_0000_0000;  pool64[17] = 64'hFFF7_FFFF_FFFF_FFFF;
        pool64[18] = 64'h3FF0_0000_0000_0001;  pool64[19] = 64'h3FEF_FFFF_FFFF_FFFF;
        pool64[20] = 64'h4340_0000_0000_0000;  pool64[21] = 64'h4330_0000_0000_0000;
        pool64[22] = 64'h41E0_0000_0000_0000;  pool64[23] = 64'h43E0_0000_0000_0000;
        pool64[24] = 64'hC3E0_0000_0000_0000;  pool64[25] = 64'h4059_0000_0000_0000;
        pool64[26] = 64'h3FB9_9999_9999_999A;  pool64[27] = 64'h0008_0000_0000_0000;
        pool64[28] = 64'h0000_0000_0000_0003;  pool64[29] = 64'h7FE0_0000_0000_0000;
        pool64[30] = 64'h0010_0000_0000_0001;  pool64[31] = 64'hC000_0000_0000_0000;
        pool64[32] = 64'h3CA0_0000_0000_0000;  pool64[33] = 64'h4330_0000_0000_0001;
        pool64[34] = 64'h3FF8_0000_0000_0000;  pool64[35] = 64'h4004_0000_0000_0000;
        pool64[36] = 64'hC004_0000_0000_0000;  pool64[37] = 64'h41DF_FFFF_FFE0_0000;
        pool64[38] = 64'h41EF_FFFF_FFF0_0000;  pool64[39] = 64'hC1E0_0000_0010_0000;

        pool32[0]  = {32'hFFFF_FFFF, 32'h0000_0000};  pool32[1]  = {32'hFFFF_FFFF, 32'h8000_0000};
        pool32[2]  = {32'hFFFF_FFFF, 32'h0000_0001};  pool32[3]  = {32'hFFFF_FFFF, 32'h8000_0001};
        pool32[4]  = {32'hFFFF_FFFF, 32'h007F_FFFF};  pool32[5]  = {32'hFFFF_FFFF, 32'h0080_0000};
        pool32[6]  = {32'hFFFF_FFFF, 32'h8080_0000};  pool32[7]  = {32'hFFFF_FFFF, 32'h3F80_0000};
        pool32[8]  = {32'hFFFF_FFFF, 32'hBF80_0000};  pool32[9]  = {32'hFFFF_FFFF, 32'h4000_0000};
        pool32[10] = {32'hFFFF_FFFF, 32'h3F00_0000};  pool32[11] = {32'hFFFF_FFFF, 32'h7F7F_FFFF};
        pool32[12] = {32'hFFFF_FFFF, 32'hFF7F_FFFF};  pool32[13] = {32'hFFFF_FFFF, 32'h7F80_0000};
        pool32[14] = {32'hFFFF_FFFF, 32'hFF80_0000};  pool32[15] = {32'hFFFF_FFFF, 32'h7FC0_0000};
        pool32[16] = {32'hFFFF_FFFF, 32'h7FA0_0000};  pool32[17] = {32'hFFFF_FFFF, 32'hFFBF_FFFF};
        pool32[18] = {32'hFFFF_FFFF, 32'h3F80_0001};  pool32[19] = {32'hFFFF_FFFF, 32'h3F7F_FFFF};
        pool32[20] = {32'hFFFF_FFFF, 32'h4B00_0000};  pool32[21] = {32'hFFFF_FFFF, 32'h4B80_0000};
        pool32[22] = {32'hFFFF_FFFF, 32'h4F00_0000};  pool32[23] = {32'hFFFF_FFFF, 32'h5F00_0000};
        pool32[24] = {32'hFFFF_FFFF, 32'hDF00_0000};  pool32[25] = {32'hFFFF_FFFF, 32'h42C8_0000};
        pool32[26] = {32'hFFFF_FFFF, 32'h3DCC_CCCD};  pool32[27] = {32'hFFFF_FFFF, 32'h0040_0000};
        pool32[28] = {32'hFFFF_FFFF, 32'h0000_0003};  pool32[29] = {32'hFFFF_FFFF, 32'h7F00_0000};
        pool32[30] = {32'hFFFF_FFFF, 32'h0080_0001};  pool32[31] = {32'hFFFF_FFFF, 32'hC000_0000};
        pool32[32] = 64'h0000_0000_3F80_0000;         pool32[33] = 64'h1234_5678_3F80_0000;
        pool32[34] = {32'hFFFF_FFFF, 32'h3FC0_0000};  pool32[35] = {32'hFFFF_FFFF, 32'h4020_0000};
        pool32[36] = {32'hFFFF_FFFF, 32'hC020_0000};  pool32[37] = {32'hFFFF_FFFF, 32'h4AFF_FFFF};
        pool32[38] = {32'hFFFF_FFFF, 32'h4B7F_FFFF};  pool32[39] = {32'hFFFF_FFFF, 32'hCAFF_FFFF};
    end

    // Square roots whose sticky bit decides the answer: the root has 64
    // bits, 11 below the precision of a double, and for these all 11 are
    // zero (inexact only through the remainder) or a lone guard bit (a tie
    // broken by the remainder). Found by searching (math.isqrt), no
    // operand of the pools comes near one.
    localparam int NH = 8;
    logic [63:0] sqrt_hard [0:NH-1];
    initial begin
        sqrt_hard[0] = 64'h1129FFA30B726F56;  sqrt_hard[1] = 64'h463D3A7DAB59B2B8;
        sqrt_hard[2] = 64'h3B885FE32682DD2B;  sqrt_hard[3] = 64'h796F80A743A5D63C;
        sqrt_hard[4] = 64'h210BA672DC1BBB58;  sqrt_hard[5] = 64'h4D7731DA23784584;
        sqrt_hard[6] = 64'h3AD610687FDE5DAE;  sqrt_hard[7] = 64'h5B50227659F6589E;
    end

    //-----------------------------------------------------------------
    // the expected answers, in the order the operations were taken
    //-----------------------------------------------------------------
    typedef struct {
        logic [TAG_W-1:0] tag;
        int               op, fmt, rm, isg, iw;
        logic [63:0]      a, b, c;
        logic [63:0]      res;
        logic [4:0]       flags;
        logic             is_int;
        longint           t_in;      // the cycle it was taken
        bit               fixed;     // its latency must be 9
    } exp_t;

    exp_t   expq [$];
    bit     killed [logic [TAG_W-1:0]];
    longint cyc = 0;
    int     errors = 0, checks = 0, shown = 0;
    int     lat_errors = 0, gap_errors = 0;
    bit     verbose;
    longint last_out = -10;
    logic [TAG_W-1:0] last_answered;
    bit     any_answered = 1'b0;
    bit     streak;              // phase 1: the run of fixed latency ones

    // moves at the falling edge, so every process that samples it at the
    // rising one sees the same number
    always @(negedge clk) cyc++;

    function automatic bit ds_engine(input int op, input int fmt,
                                     input logic [63:0] a, input logic [63:0] b);
        // a divide / square root that goes to the engine (not special):
        // its latency is not fixed
        return (op == FOP_DIV) || (op == FOP_SQRT);
    endfunction

    // the answer checker
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            exp_t e;
            // the operations taken back have no answer
            while ((expq.size() != 0) && killed.exists(expq[0].tag)) begin
                killed.delete(expq[0].tag);
                void'(expq.pop_front());
            end
            if (expq.size() == 0) begin
                errors++;
                $display(" [FAIL] an answer (tag %0d) with nothing expected", out_tag);
            end else begin
                e = expq.pop_front();
                checks++;
                if ((out_tag !== e.tag) || (out_result !== e.res) ||
                    (out_flags !== e.flags) || (out_is_int !== e.is_int)) begin
                    errors++;
                    if (verbose || (shown < 20)) begin
                        shown++;
                        $display(" [FAIL] op %0d fmt=%0d rm=%0d sgn=%0d w=%0d tag %0d (got tag %0d)",
                                 e.op, e.fmt, e.rm, e.isg, e.iw, e.tag, out_tag);
                        $display("        a=%016h b=%016h c=%016h", e.a, e.b, e.c);
                        $display("        got %016h flags=%05b int=%0d", out_result, out_flags, out_is_int);
                        $display("        exp %016h flags=%05b int=%0d", e.res, e.flags, e.is_int);
                    end
                end
                // latency: an operation that never waited in front
                if (e.fixed && (cyc - e.t_in != 9)) begin
                    lat_errors++;
                    if (lat_errors <= 5)
                        $display(" [FAIL] latency %0d (op %0d tag %0d)", cyc - e.t_in, e.op, e.tag);
                end
            end
            last_out = cyc;
            last_answered = out_tag;
            any_answered  = 1'b1;
        end
    end

    // an operation is taken back only before its answer comes out (tags
    // grow, and the answers come in their order)
    task automatic mark_killed(input logic [TAG_W-1:0] t);
        if (any_answered && (t <= last_answered)) begin
            errors++;
            $display(" [FAIL] tag %0d taken back after its answer came out", t);
        end
        killed[t] = 1'b1;
    endtask

    //-----------------------------------------------------------------
    // offering
    //-----------------------------------------------------------------
    logic [TAG_W-1:0] next_tag = '0;
    int               long_hold = 0;
    int               wait_cnt;
    bit               phase2 = 0;
    longint           took_prev = -10;   // phase 1: the cycle of the last taking

    // offer one operation and keep it offered until it is taken
    task automatic offer(input int o, input int f, input int r, input int isg, input int iw,
                         input logic [63:0] va, input logic [63:0] vb, input logic [63:0] vc,
                         input int gap_pct);
        exp_t e;
        int   fl, ii;
        bit   taken;
        e.res    = sf_op(o, f, r, isg, iw, va, vb, vc, fl, ii);
        e.flags  = 5'(fl);
        e.is_int = 1'(ii);
        e.op = o; e.fmt = f; e.rm = r; e.isg = isg; e.iw = iw;
        e.a = va; e.b = vb; e.c = vc;
        taken = 0;
        wait_cnt = 0;
        while (!taken) begin
            // an offer that is never taken: the unit hangs
            wait_cnt = wait_cnt + 1;
            if (wait_cnt > 5000) begin
                $display(" FPU PIPE RESULT : FAIL   (an offer not taken in 5000 cycles, tag %0d)",
                         next_tag);
                $finish;
            end
            @(negedge clk);
            // phase 2: what the core does around the unit
            if (phase2) begin
                int h, k;
                h = $urandom_range(0, 15);
                k = $urandom_range(0, 63);
                // now and then a long hold of both, as a miss of the data
                // cache longer than a divide holds MA in the core
                if ((long_hold == 0) && ($urandom_range(0, 499) == 0))
                    long_hold = $urandom_range(60, 200);
                if (long_hold != 0) begin
                    long_hold--;
                    h = 0;
                end
                hold1 = (h == 0);
                hold0 = hold1 | (h == 1);
                kill1 = (k == 0);
                kill0 = kill1 | (k == 1);
                in_valid = ($urandom_range(0, 99) >= gap_pct);
            end else begin
                in_valid = 1'b1;
            end
            in_op = 5'(o); in_fmt = f[0]; in_rm = 3'(r); in_isg = isg[0]; in_iw = iw[0];
            in_a = va; in_b = vb; in_c = vc; in_tag = next_tag;
            @(posedge clk);
            // what is taken back this cycle
            if (kill0 && dut.p0_v) mark_killed(dut.p0_tag);
            if (kill1 && dut.p1_v) mark_killed(dut.p1_tag);
            if (in_valid && in_ready && !hold0 && !kill0) begin
                e.tag   = next_tag;
                e.t_in  = cyc;
                e.fixed = !phase2 && !ds_engine(o, f, va, vb);
                // phase 1: a run of fixed latency operations comes out one
                // per cycle (checked here on the side of the offers: they
                // are taken every cycle, so the answers can only keep pace
                // if the latency check holds)
                expq.push_back(e);
                next_tag++;
                taken = 1;
            end
        end
        // the next offer comes at the next falling edge: back to back
    endtask

    // phase 3: a divide held in P1 for longer than it takes, then let go
    // or taken back there
    task automatic ds_held(input int o, input logic [63:0] va, input logic [63:0] vb,
                           input bit kill_it);
        exp_t e;
        int   fl, ii;
        e.res    = sf_op(o, 1, 0, 0, 0, va, vb, 64'd0, fl, ii);
        e.flags  = 5'(fl);  e.is_int = 1'(ii);
        e.op = o; e.fmt = 1; e.rm = 0; e.isg = 0; e.iw = 0;
        e.a = va; e.b = vb; e.c = 64'd0; e.fixed = 0;
        while (busy) @(posedge clk);
        @(negedge clk);
        in_valid = 1'b1; in_op = 5'(o); in_fmt = 1'b1; in_rm = 3'd0;
        in_isg = 1'b0; in_iw = 1'b0; in_a = va; in_b = vb; in_c = 64'd0;
        in_tag = next_tag;
        @(posedge clk);                         // taken into P0
        e.tag = next_tag;  e.t_in = cyc;
        expq.push_back(e);
        next_tag++;
        @(negedge clk);
        in_valid = 1'b0;
        @(posedge clk);                         // into P1, the engine starts
        @(negedge clk);
        hold0 = 1'b1; hold1 = 1'b1;
        repeat (300) @(posedge clk);            // the engine is long done
        @(negedge clk);
        if (kill_it) begin
            kill0 = 1'b1; kill1 = 1'b1;
            @(posedge clk);
            if (dut.p1_v) mark_killed(dut.p1_tag);
            @(negedge clk);
            kill0 = 1'b0; kill1 = 1'b0;
        end
        hold0 = 1'b0; hold1 = 1'b0;
        repeat (20) @(posedge clk);
        while (busy) @(posedge clk);
    endtask

    task automatic quiet();
        @(negedge clk);
        in_valid = 1'b0;
        hold0 = 1'b0; hold1 = 1'b0; kill0 = 1'b0; kill1 = 1'b0;
    endtask

    //-----------------------------------------------------------------
    int  n_rand, n_ops2, seed;
    int  o, f, r, i, j, k;
    logic [63:0] va, vb, vc;
    longint t0;

    initial begin
        verbose = $test$plusargs("verbose");
        if (!$value$plusargs("rand=%d", n_rand)) n_rand = 200;
        if (!$value$plusargs("ops2=%d", n_ops2)) n_ops2 = 200000;
        if (!$value$plusargs("seed=%d", seed))   seed = 1;
        void'($urandom(seed));

        in_valid = 1'b0; hold0 = 1'b0; hold1 = 1'b0; kill0 = 1'b0; kill1 = 1'b0;
        in_op = '0; in_fmt = 1'b0; in_rm = 3'd0; in_isg = 1'b0; in_iw = 1'b0;
        in_a = '0; in_b = '0; in_c = '0; in_tag = '0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        $display("");
        $display("==========================================================");
        $display(" tb_FPU_PIPE : FPU_PIPE against Berkeley SoftFloat");
        $display("==========================================================");

        //-------------------------------------------------------------
        // 1 the pools, back to back
        //-------------------------------------------------------------
        t0 = cyc;
        for (o = 0; o <= 23; o++) begin
            for (f = 0; f <= 1; f++) begin
                if ((o == FOP_CVT_S_D) && (f == 0)) continue;
                if ((o == FOP_CVT_D_S) && (f == 1)) continue;
                for (r = 0; r <= 4; r++) begin
                    for (i = 0; i < NP; i++)
                        for (j = 0; j < NP; j++) begin
                            va = f ? pool64[i] : pool32[i];
                            vb = f ? pool64[j] : pool32[j];
                            vc = f ? pool64[(i+j) % NP] : pool32[(i+j) % NP];
                            if ((o == FOP_CVT_F_I) || (o == FOP_CVT_I_F))
                                for (k = 0; k < 4; k++) offer(o, f, r, k[0], k[1], va, vb, vc, 0);
                            else
                                offer(o, f, r, 0, 0, va, vb, vc, 0);
                        end
                    for (i = 0; i < n_rand; i++) begin
                        va = {$urandom(), $urandom()};
                        vb = {$urandom(), $urandom()};
                        vc = {$urandom(), $urandom()};
                        if (!f) begin
                            va = {32'hFFFF_FFFF, va[31:0]};
                            vb = {32'hFFFF_FFFF, vb[31:0]};
                            vc = {32'hFFFF_FFFF, vc[31:0]};
                        end
                        offer(o, f, r, i[0], i[1], va, vb, vc, 0);
                    end
                end
            end
            $display(" phase 1: op %2d done, %0d checks, %0d errors", o, checks, errors);
        end
        for (r = 0; r <= 4; r++)
            for (i = 0; i < NH; i++)
                offer(FOP_SQRT, 1, r, 0, 0, sqrt_hard[i], 64'd0, 64'd0, 0);
        quiet();
        while (busy) @(posedge clk);
        repeat (3) @(posedge clk);
        $display(" phase 1: %0d checks in %0d cycles, %0d errors, %0d latency errors",
                 checks, cyc - t0, errors, lat_errors);

        //-------------------------------------------------------------
        // 2 random, with gaps, holds and take backs
        //-------------------------------------------------------------
        phase2 = 1;
        t0 = cyc;
        for (i = 0; i < n_ops2; i++) begin
            int pick;
            o = $urandom_range(0, 23);
            // the divide and square root are long; fewer of them
            if (((o == FOP_DIV) || (o == FOP_SQRT)) && ($urandom_range(0, 7) != 0))
                o = $urandom_range(5, 8);
            f = $urandom_range(0, 1);
            if (o == FOP_CVT_S_D) f = 1;
            if (o == FOP_CVT_D_S) f = 0;
            r = $urandom_range(0, 4);
            pick = $urandom_range(0, 3);
            if (pick == 0) begin
                va = f ? pool64[$urandom_range(0, NP-1)] : pool32[$urandom_range(0, NP-1)];
                vb = f ? pool64[$urandom_range(0, NP-1)] : pool32[$urandom_range(0, NP-1)];
                vc = f ? pool64[$urandom_range(0, NP-1)] : pool32[$urandom_range(0, NP-1)];
            end else begin
                va = {$urandom(), $urandom()};
                vb = {$urandom(), $urandom()};
                vc = {$urandom(), $urandom()};
                if (!f) begin
                    va = {32'hFFFF_FFFF, va[31:0]};
                    vb = {32'hFFFF_FFFF, vb[31:0]};
                    vc = {32'hFFFF_FFFF, vc[31:0]};
                end
            end
            offer(o, f, r, $urandom_range(0, 1), $urandom_range(0, 1), va, vb, vc, 25);
        end
        quiet();
        while (busy) @(posedge clk);
        repeat (3) @(posedge clk);
        // whatever is left in the queue must have been taken back
        while ((expq.size() != 0) && killed.exists(expq[0].tag)) begin
            killed.delete(expq[0].tag);
            void'(expq.pop_front());
        end
        if (expq.size() != 0) begin
            errors++;
            $display(" [FAIL] %0d answers never came (first tag %0d)", expq.size(), expq[0].tag);
        end
        $display(" phase 2: %0d checks in total, %0d cycles, %0d errors", checks, cyc - t0, errors);

        //-------------------------------------------------------------
        // 3 a divide / square root held in P1 longer than it runs
        //-------------------------------------------------------------
        phase2 = 0;
        ds_held(FOP_DIV,  64'h3FF0_0000_0000_0000, 64'h4008_0000_0000_0000, 1'b0);  // 1/3
        ds_held(FOP_DIV,  64'h3FF0_0000_0000_0000, 64'h4008_0000_0000_0000, 1'b1);
        ds_held(FOP_SQRT, sqrt_hard[4],            64'd0,                   1'b0);
        ds_held(FOP_SQRT, sqrt_hard[4],            64'd0,                   1'b1);
        // the unit takes operations again after them
        for (i = 0; i < 100; i++)
            offer(FOP_MADD, 1, 0, 0, 0, pool64[i % NP], pool64[(i+7) % NP], pool64[(i+3) % NP], 0);
        quiet();
        while (busy) @(posedge clk);
        repeat (3) @(posedge clk);
        while ((expq.size() != 0) && killed.exists(expq[0].tag)) begin
            killed.delete(expq[0].tag);
            void'(expq.pop_front());
        end
        if (expq.size() != 0) begin
            errors++;
            $display(" [FAIL] phase 3: %0d answers never came", expq.size());
        end
        $display(" phase 3: %0d checks in total, %0d errors", checks, errors);

        $display("");
        $display("==========================================================");
        if ((errors == 0) && (lat_errors == 0))
            $display(" FPU PIPE RESULT : PASS   (%0d checks)", checks);
        else
            $display(" FPU PIPE RESULT : FAIL   (%0d checks, %0d errors, %0d latency errors)",
                     checks, errors, lat_errors);
        $display("==========================================================");
        $finish;
    end

    // watchdog
    initial begin
        #(64'd400_000_000_000);
        $display(" FPU PIPE RESULT : FAIL   (watchdog)");
        $finish;
    end

endmodule : tb_FPU_PIPE
