//---------------------------------------------------------------------------
// tb_MDU.sv
//
// Random test of CORE_MDU against a reference written with the arithmetic
// of the simulator. The programs of SIM_CORE (t09_muldiv) and riscv-tests
// (rv64um) check the results through the core; this bench adds what they
// cannot steer:
//
//   - many operands: random ones, and the edges (0, 1, -1, the most negative
//     number, the largest, one bit set) of both 64 and 32 bits
//   - the number of cycles: MUL / MULW are done one cycle after the start,
//     MULH / MULHSU / MULHU two cycles after it, a division by zero or the
//     overflow one, a divide 2 + steps after it, where the steps are what
//     is left after the early out (CPU_CORE_SPEC.md decisions 61, 62); so a
//     slower unit fails here, not only in the benchmarks
//   - the answer held while the core does not take it (ack late), and
//   - kill in the middle of an operation or while the answer is held: the
//     unit must be idle afterwards and the next operation right
//
//   +n=<count>   number of operations (default 200000)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_MDU;

    logic clk = 1'b0;
    logic rst_n;
    always #10 clk = ~clk;

    logic        start, kill, word_op, ack;
    logic [2:0]  op;
    logic [63:0] rs1, rs2;
    logic        busy, done;
    logic [63:0] result;

    CORE_MDU u_mdu
        (
            .clk      (clk),
            .rst_n    (rst_n),
            .start    (start),
            .kill     (kill),
            .op       (op),
            .word_op  (word_op),
            .rs1_data (rs1),
            .rs2_data (rs2),
            .busy     (busy),
            .done     (done),
            .ack      (ack),
            .result   (result)
        );

    //-----------------------------------------------------------------
    // reference
    //-----------------------------------------------------------------
    function automatic logic [63:0] sx32(input logic [31:0] v);
        return {{32{v[31]}}, v};
    endfunction

    function automatic logic [63:0] reference(input logic [2:0] o, input logic w,
                                              input logic [63:0] a, input logic [63:0] b);
        logic signed [127:0] sa, sb;
        logic        [127:0] ua, ub, p;
        logic signed [63:0]  qa, qb;
        logic signed [31:0]  wa, wb;
        sa = {{64{a[63]}}, a};  sb = {{64{b[63]}}, b};
        ua = {64'd0, a};        ub = {64'd0, b};
        qa = a;  qb = b;  wa = a[31:0];  wb = b[31:0];
        case (o)
            3'd0: begin
                p = ua * ub;
                return w ? sx32(p[31:0]) : p[63:0];
            end
            3'd1: begin p = sa * sb; return p[127:64]; end
            3'd2: begin p = sa * ub; return p[127:64]; end
            3'd3: begin p = ua * ub; return p[127:64]; end
            3'd4: begin                                     // DIV
                if (w) begin
                    if (wb == 0)                               return 64'hFFFF_FFFF_FFFF_FFFF;
                    if (wa == 32'sh8000_0000 && wb == -32'sd1) return sx32(wa);
                    return sx32(wa / wb);
                end
                if (qb == 0)                                        return 64'hFFFF_FFFF_FFFF_FFFF;
                if (qa == 64'sh8000_0000_0000_0000 && qb == -64'sd1) return qa;
                return qa / qb;
            end
            3'd5: begin                                     // DIVU
                if (w) return (b[31:0] == 0) ? 64'hFFFF_FFFF_FFFF_FFFF
                                             : sx32(a[31:0] / b[31:0]);
                return (b == 0) ? 64'hFFFF_FFFF_FFFF_FFFF : a / b;
            end
            3'd6: begin                                     // REM
                if (w) begin
                    if (wb == 0)                               return sx32(wa);
                    if (wa == 32'sh8000_0000 && wb == -32'sd1) return 64'd0;
                    return sx32(wa % wb);
                end
                if (qb == 0)                                        return qa;
                if (qa == 64'sh8000_0000_0000_0000 && qb == -64'sd1) return 64'd0;
                return qa % qb;
            end
            default: begin                                  // REMU
                if (w) return (b[31:0] == 0) ? sx32(a[31:0]) : sx32(a[31:0] % b[31:0]);
                return (b == 0) ? a : a % b;
            end
        endcase
    endfunction

    // the operand: random, or one of the edges
    function automatic logic [63:0] operand();
        logic [63:0] r;
        r = {$urandom, $urandom};
        case ($urandom_range(0, 15))
            0:  return 64'd0;
            1:  return 64'd1;
            2:  return 64'hFFFF_FFFF_FFFF_FFFF;
            3:  return 64'h8000_0000_0000_0000;
            4:  return 64'h7FFF_FFFF_FFFF_FFFF;
            5:  return 64'h0000_0000_8000_0000;
            6:  return 64'hFFFF_FFFF_8000_0000;
            7:  return 64'h0000_0000_7FFF_FFFF;
            8:  return 64'd1 << $urandom_range(0, 63);
            9:  return r >> $urandom_range(1, 63);              // small
            10: return {{32{r[31]}}, r[31:0]};                  // a 32 bit value
            default: return r;
        endcase
    endfunction

    // cycles from the start to done for a divide (CORE_MDU.sv, S_DIVN)
    function automatic int div_latency(input logic [2:0] o, input logic w,
                                       input logic [63:0] a, input logic [63:0] b);
        logic        sgn;
        logic [63:0] da, db;
        int          width, lz, bits_d, skip;
        sgn   = (o == 3'd4) || (o == 3'd6);
        width = w ? 32 : 64;
        if (w) begin
            da = sgn ? sx32(a[31:0]) : {32'd0, a[31:0]};
            db = sgn ? sx32(b[31:0]) : {32'd0, b[31:0]};
        end else begin
            da = a;  db = b;
        end
        if (db == 0) return 1;
        if (sgn && (db == 64'hFFFF_FFFF_FFFF_FFFF) &&
            (da == (w ? 64'hFFFF_FFFF_8000_0000 : 64'h8000_0000_0000_0000))) return 1;
        if (sgn && da[63]) da = -da;
        if (sgn && db[63]) db = -db;
        lz = width;
        for (int i = 0; i < width; i++) if (da[i]) lz = width - 1 - i;
        bits_d = 0;
        for (int i = 0; i < 64; i++) if (db[i]) bits_d = i + 1;
        skip = lz + bits_d - 1;
        if (skip > width - 1) skip = width - 1;
        return 2 + (width - skip);
    endfunction

    //-----------------------------------------------------------------
    int n_ops = 200000;
    int errors = 0, checks = 0, kills = 0;

    task automatic fail(input string what);
        errors++;
        if (errors <= 20)
            $display("[%0t] [FAIL] %s : op %0d word %0d a %016h b %016h", $time, what,
                     op, word_op, rs1, rs2);
    endtask

    initial begin
        void'($value$plusargs("n=%d", n_ops));
        start = 0; kill = 0; ack = 0; op = 0; word_op = 0; rs1 = 0; rs2 = 0;
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (int i = 0; i < n_ops; i++) begin
            logic [63:0] expect_v;
            int          lat, want_lat, hold, kill_at;
            bit          killed;

            // the operation (no 32 bit form of MULH*)
            #1;
            op      = 3'($urandom_range(0, 7));
            word_op = (op inside {3'd1, 3'd2, 3'd3}) ? 1'b0 : 1'($urandom_range(0, 1));
            rs1     = operand();
            rs2     = operand();
            expect_v = reference(op, word_op, rs1, rs2);
            if (busy || done) fail("not idle before a start");

            // one operation in sixteen is killed somewhere along the way
            kill_at = ($urandom_range(0, 15) == 0) ? $urandom_range(0, 6) : -1;
            want_lat = (op == 3'd0) ? 1 : (op inside {3'd1, 3'd2, 3'd3}) ? 2
                                        : div_latency(op, word_op, rs1, rs2);

            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
            // a new operand on the inputs must not matter any more
            rs1 = ~rs1;  rs2 = {$urandom, $urandom};

            lat = 1; killed = 0;
            while (!done && !killed) begin
                if (lat - 1 == kill_at) begin
                    kill = 1'b1; @(posedge clk); #1; kill = 1'b0; killed = 1;
                end else begin
                    if (!busy) fail("neither busy nor done");
                    @(posedge clk); #1; lat++;
                    if (lat > 80) begin fail("hangs"); break; end
                end
            end

            if (!killed) begin
                if (want_lat > 0 && lat != want_lat)
                    fail($sformatf("done after %0d cycles, %0d expected", lat, want_lat));
                // the core may take the answer late; it must stay
                hold = $urandom_range(0, 3) == 0 ? $urandom_range(1, 4) : 0;
                for (int h = 0; h <= hold; h++) begin
                    checks++;
                    if (!done) fail("done dropped before ack");
                    if (result !== expect_v)
                        fail($sformatf("result %016h, %016h expected", result, expect_v));
                    if (h == hold) begin
                        if ((kill_at >= 0) && $urandom_range(0, 1)) begin
                            kill = 1'b1; killed = 1;    // flushed with the answer held
                        end else begin
                            ack = 1'b1;
                        end
                    end
                    @(posedge clk); #1;
                    kill = 1'b0; ack = 1'b0;
                end
            end
            if (killed) kills++;
            if (busy || done) fail("not idle after ack or kill");
            // sometimes a cycle of nothing in between
            if ($urandom_range(0, 3) == 0) @(posedge clk);
        end

        $display("==========================================================");
        if (errors == 0)
            $display(" MDU TEST RESULT : PASS   (%0d operations, %0d checks, %0d killed)",
                     n_ops, checks, kills);
        else
            $display(" MDU TEST RESULT : FAIL   (%0d errors)", errors);
        $display("==========================================================");
        $finish;
    end

endmodule : tb_MDU
