//---------------------------------------------------------------------------
// tb_CLINT.sv
//
// Directed test of CPU_CLINT with more than one hart. SIM_CORE runs a single
// core, so the register map of a multi hart system cannot be reached from a
// program; this bench drives the register port directly and checks that every
// hart has its own msip and its own mtimecmp, at the addresses the software
// and the device tree expect (CPU_CACHE_SPEC.md 6.4.8).
//
//   0x0000 + 4 * hart   msip      32 bit
//   0x4000 + 8 * hart   mtimecmp  64 bit
//   0xBFF8              mtime     64 bit, shared
//
// The accesses follow the convention of the cache port: the address is the
// byte address, the data is already in its lane and the strobes say which
// bytes are written.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_CLINT;

    localparam int NUM_HARTS = 4;

    logic clk = 1'b0;
    logic rst_n;
    always #10 clk = ~clk;

    logic                   sel, we;
    logic [15:0]            addr;
    logic [63:0]            wdata, rdata;
    logic [7:0]             wstrb;
    logic [NUM_HARTS-1:0]   irq_m_soft, irq_m_timer;
    logic [63:0]            mtime;

    int errors = 0;
    int checks = 0;

    CPU_CLINT #(.NUM_HARTS(NUM_HARTS), .TICK_DIV(1)) dut
        (
            .clk         (clk),
            .rst_n       (rst_n),
            .sel         (sel),
            .we          (we),
            .addr        (addr),
            .wdata       (wdata),
            .wstrb       (wstrb),
            .rdata       (rdata),
            .irq_m_soft  (irq_m_soft),
            .irq_m_timer (irq_m_timer),
            .mtime       (mtime)
        );

    //-----------------------------------------------------------------
    task automatic wr(input logic [15:0] a, input logic [63:0] d,
                      input logic [7:0] s);
        @(negedge clk);
        sel = 1'b1; we = 1'b1; addr = a; wdata = d; wstrb = s;
        @(posedge clk);
        @(negedge clk);
        sel = 1'b0; we = 1'b0; wstrb = 8'd0;
    endtask

    // a 32 bit write, placed in its lane like the cache does
    task automatic wr32(input logic [15:0] a, input logic [31:0] d);
        if (a[2]) wr(a, {d, 32'd0}, 8'hF0);
        else      wr(a, {32'd0, d}, 8'h0F);
    endtask

    task automatic rd(input logic [15:0] a, output logic [63:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b0; addr = a; wstrb = 8'd0;
        #1 d = rdata;
        @(posedge clk);
        @(negedge clk);
        sel = 1'b0;
    endtask

    task automatic rd32(input logic [15:0] a, output logic [31:0] d);
        logic [63:0] v;
        rd(a, v);
        d = a[2] ? v[63:32] : v[31:0];
    endtask

    task automatic chk(input string name, input logic [63:0] got,
                       input logic [63:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display(" [FAIL] %s : expected %016h, got %016h", name, exp, got);
        end
    endtask

    //-----------------------------------------------------------------
    logic [63:0] v;
    logic [31:0] w;

    initial begin
        sel = 1'b0; we = 1'b0; addr = 16'd0; wdata = 64'd0; wstrb = 8'd0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("");
        $display("==========================================================");
        $display(" tb_CLINT : %0d harts", NUM_HARTS);
        $display("==========================================================");

        //-------------------------------------------------------------
        // reset values
        //-------------------------------------------------------------
        chk("msip after reset",  {60'd0, irq_m_soft},  64'd0);
        chk("mtip after reset",  {60'd0, irq_m_timer}, 64'd0);
        for (int h = 0; h < NUM_HARTS; h++) begin
            rd(16'(16'h4000 + 8*h), v);
            chk($sformatf("mtimecmp[%0d] after reset", h), v, {64{1'b1}});
        end

        //-------------------------------------------------------------
        // mtime runs and can be written
        //-------------------------------------------------------------
        rd(16'hBFF8, v);
        repeat (4) @(posedge clk);
        begin
            logic [63:0] v2;
            rd(16'hBFF8, v2);
            chk("mtime moves on", (v2 > v) ? 64'd1 : 64'd0, 64'd1);
        end
        wr(16'hBFF8, 64'h0000_0000_0000_1000, 8'hFF);
        rd(16'hBFF8, v);
        chk("mtime was written", (v >= 64'h1000) && (v < 64'h1010), 64'd1);

        //-------------------------------------------------------------
        // every hart has its own msip, two of them in one 64 bit word
        //-------------------------------------------------------------
        for (int h = 0; h < NUM_HARTS; h++) begin
            wr32(16'(16'h0000 + 4*h), 32'd1);
            chk($sformatf("msip[%0d] raises only its own line", h),
                {60'd0, irq_m_soft}, 64'(1 << h));
            rd32(16'(16'h0000 + 4*h), w);
            chk($sformatf("msip[%0d] reads back", h), {32'd0, w}, 64'd1);
            wr32(16'(16'h0000 + 4*h), 32'd0);
            chk($sformatf("msip[%0d] clears", h), {60'd0, irq_m_soft}, 64'd0);
        end

        // both halves of one word at the same time
        wr(16'h0000, {32'd1, 32'd1}, 8'hFF);
        chk("msip[0] and msip[1] together", {60'd0, irq_m_soft}, 64'd3);
        wr(16'h0000, 64'd0, 8'hFF);
        chk("both cleared", {60'd0, irq_m_soft}, 64'd0);

        //-------------------------------------------------------------
        // every hart has its own mtimecmp
        //-------------------------------------------------------------
        for (int h = 0; h < NUM_HARTS; h++) begin
            rd(16'hBFF8, v);
            wr(16'(16'h4000 + 8*h), v + 64'd4, 8'hFF);
            rd(16'(16'h4000 + 8*h), v);
            repeat (20) @(posedge clk);
            chk($sformatf("mtimecmp[%0d] raises only its own timer", h),
                {60'd0, irq_m_timer}, 64'(1 << h));
            wr(16'(16'h4000 + 8*h), {64{1'b1}}, 8'hFF);
            chk($sformatf("mtimecmp[%0d] switched off again", h),
                {60'd0, irq_m_timer}, 64'd0);
        end

        //-------------------------------------------------------------
        // a hart that does not exist
        //-------------------------------------------------------------
        wr32(16'(16'h0000 + 4*NUM_HARTS), 32'd1);
        chk("msip of a hart that does not exist is ignored",
            {60'd0, irq_m_soft}, 64'd0);
        rd(16'(16'h4000 + 8*NUM_HARTS), v);
        chk("mtimecmp of a hart that does not exist reads zero", v, 64'd0);

        //-------------------------------------------------------------
        $display("");
        $display("==========================================================");
        if (errors == 0) $display(" CLINT RESULT : PASS   (%0d checks)", checks);
        else             $display(" CLINT RESULT : FAIL   (%0d checks, %0d errors)",
                                  checks, errors);
        $display("==========================================================");
        $finish;
    end

endmodule : tb_CLINT
