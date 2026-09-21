//---------------------------------------------------------------------------
// tb_PLIC.sv
//
// Directed test of CPU_PLIC. The register map of the RISC-V specification is
// driven straight through the port, because the interesting part of the
// block -- several contexts claiming out of one set of sources -- cannot be
// reached from a program on a single core.
//
//   0x000000 + 4*s          priority of source s
//   0x001000 + 4*w          pending, read only
//   0x002000 + 0x80*c + 4*w enable for context c
//   0x200000 + 0x1000*c + 0 threshold of context c
//   0x200000 + 0x1000*c + 4 claim on read, complete on write
//
// The accesses follow the convention of the cache port: the address is the
// byte address and the data is already in its lane.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_PLIC;

    localparam int SOURCES   = 31;
    localparam int CONTEXTS  = 4;         // two harts worth, to show they differ
    localparam int PRIO_BITS = 3;

    logic clk = 1'b0;
    logic rst_n;
    always #10 clk = ~clk;

    logic                  sel, we;
    logic [21:0]           addr;
    logic [63:0]           wdata, rdata;
    logic [7:0]            wstrb;
    logic [SOURCES:0]      src;
    logic [CONTEXTS-1:0]   irq;

    int errors = 0;
    int checks = 0;

    CPU_PLIC #(.SOURCES(SOURCES), .CONTEXTS(CONTEXTS), .PRIO_BITS(PRIO_BITS)) dut
        (
            .clk (clk), .rst_n (rst_n),
            .sel (sel), .we (we), .addr (addr),
            .wdata (wdata), .wstrb (wstrb), .rdata (rdata),
            .src (src), .irq (irq)
        );

    //-----------------------------------------------------------------
    // the port
    //-----------------------------------------------------------------
    task automatic wr(input logic [21:0] a, input logic [63:0] d,
                      input logic [7:0] s);
        @(negedge clk);
        sel = 1'b1; we = 1'b1; addr = a; wdata = d; wstrb = s;
        @(posedge clk);
        @(negedge clk);
        sel = 1'b0; we = 1'b0; wstrb = 8'd0;
    endtask

    task automatic wr32(input logic [21:0] a, input logic [31:0] d);
        if (a[2]) wr(a, {d, 32'd0}, 8'hF0);
        else      wr(a, {32'd0, d}, 8'h0F);
    endtask

    task automatic rd(input logic [21:0] a, output logic [63:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b0; addr = a; wstrb = 8'd0;
        #1 d = rdata;
        @(posedge clk);
        @(negedge clk);
        sel = 1'b0;
    endtask

    task automatic rd32(input logic [21:0] a, output logic [31:0] d);
        logic [63:0] v;
        rd(a, v);
        d = a[2] ? v[63:32] : v[31:0];
    endtask

    // a read that does not touch the port at all, for looking at a register
    // without claiming
    task automatic peek_pending(output logic [31:0] d);
        logic [63:0] v;
        rd(22'h001000, v);
        d = v[31:0];
    endtask

    // claim and complete until there is nothing left; more than one source
    // can be waiting, and one claim would leave the others behind
    task automatic drain(input int c);
        logic [31:0] id;
        logic        done;
        begin
            done = 1'b0;
            for (int i = 0; (i < SOURCES + 2) && !done; i++) begin
                rd32(a_claim(c), id);
                if (id == 32'd0) done = 1'b1;
                else             wr32(a_claim(c), id);
            end
        end
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
    // the addresses
    //-----------------------------------------------------------------
    function automatic logic [21:0] a_prio(input int s);
        a_prio = 22'(4 * s);
    endfunction
    function automatic logic [21:0] a_enable(input int c, input int w);
        a_enable = 22'(22'h002000 + 22'h80 * c + 4 * w);
    endfunction
    function automatic logic [21:0] a_threshold(input int c);
        a_threshold = 22'(22'h200000 + 22'h1000 * c);
    endfunction
    function automatic logic [21:0] a_claim(input int c);
        a_claim = 22'(22'h200000 + 22'h1000 * c + 4);
    endfunction

    //-----------------------------------------------------------------
    logic [31:0] v32;
    logic [63:0] v64;

    initial begin
        rst_n = 1'b0;
        sel = 1'b0; we = 1'b0; addr = '0; wdata = '0; wstrb = '0;
        src = '0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //-------------------------------------------------------------
        $display("--- 1. everything is quiet after reset ---");
        //-------------------------------------------------------------
        chk("no line is raised", {60'd0, irq}, 64'd0);
        peek_pending(v32);
        chk("nothing is pending", {32'd0, v32}, 64'd0);
        rd32(a_claim(0), v32);
        chk("claiming gives zero", {32'd0, v32}, 64'd0);

        //-------------------------------------------------------------
        $display("--- 2. a source has to be enabled and have a priority ---");
        //-------------------------------------------------------------
        src[5] = 1'b1;
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("the gateway latched source 5", {32'd0, v32}, 64'(1 << 5));
        chk("but no context wants it yet", {60'd0, irq}, 64'd0);

        wr32(a_enable(0, 0), 32'(1 << 5));
        repeat (2) @(posedge clk);
        chk("enabled with priority zero is still nothing", {60'd0, irq}, 64'd0);

        wr32(a_prio(5), 32'd3);
        repeat (2) @(posedge clk);
        chk("now context 0 has a line", {60'd0, irq}, 64'd1);
        chk("and nobody else does", {60'd0, irq[3:1]}, 64'd0);

        //-------------------------------------------------------------
        $display("--- 3. claim and complete ---");
        //-------------------------------------------------------------
        rd32(a_claim(0), v32);
        chk("the claim gives the source number", {32'd0, v32}, 64'd5);
        repeat (1) @(posedge clk);
        chk("the line drops once it is claimed", {60'd0, irq}, 64'd0);
        peek_pending(v32);
        chk("and it is not pending any more", {32'd0, v32}, 64'd0);

        rd32(a_claim(0), v32);
        chk("a second claim gives nothing", {32'd0, v32}, 64'd0);

        // the line is still up, but the gateway waits for the completion
        repeat (4) @(posedge clk);
        peek_pending(v32);
        chk("the gateway holds the source back until it is completed",
            {32'd0, v32}, 64'd0);

        wr32(a_claim(0), 32'd5);
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("after the completion the line makes it pending again",
            {32'd0, v32}, 64'(1 << 5));
        chk("and the context is asked again", {60'd0, irq}, 64'd1);

        // this time the line goes away before the claim
        src[5] = 1'b0;
        rd32(a_claim(0), v32);
        chk("claimed once more", {32'd0, v32}, 64'd5);
        wr32(a_claim(0), 32'd5);
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("a line that went away does not come back", {32'd0, v32}, 64'd0);
        chk("and the context is quiet", {60'd0, irq}, 64'd0);

        //-------------------------------------------------------------
        $display("--- 4. priority decides, the lowest number breaks a tie ---");
        //-------------------------------------------------------------
        wr32(a_enable(0, 0), 32'(32'hFFFF_FFFE));     // every source
        wr32(a_prio(7),  32'd2);
        wr32(a_prio(9),  32'd5);
        wr32(a_prio(11), 32'd5);
        src[7] = 1'b1; src[9] = 1'b1; src[11] = 1'b1;
        repeat (2) @(posedge clk);
        rd32(a_claim(0), v32);
        chk("the highest priority comes first", {32'd0, v32}, 64'd9);
        rd32(a_claim(0), v32);
        chk("then the other one of the same priority", {32'd0, v32}, 64'd11);
        rd32(a_claim(0), v32);
        chk("then the lower priority", {32'd0, v32}, 64'd7);
        rd32(a_claim(0), v32);
        chk("and then nothing", {32'd0, v32}, 64'd0);

        wr32(a_claim(0), 32'd7);
        wr32(a_claim(0), 32'd9);
        wr32(a_claim(0), 32'd11);
        src[7] = 1'b0; src[9] = 1'b0; src[11] = 1'b0;
        repeat (3) @(posedge clk);
        drain(0);

        //-------------------------------------------------------------
        $display("--- 5. the threshold masks what is below it ---");
        //-------------------------------------------------------------
        wr32(a_threshold(0), 32'd5);
        src[7] = 1'b1;                                // priority 2
        src[9] = 1'b1;                                // priority 5
        repeat (2) @(posedge clk);
        chk("nothing at or below the threshold is offered", {60'd0, irq}, 64'd0);
        rd32(a_claim(0), v32);
        chk("and nothing can be claimed either", {32'd0, v32}, 64'd0);

        wr32(a_prio(9), 32'd6);
        repeat (2) @(posedge clk);
        chk("above it the line comes up", {60'd0, irq}, 64'd1);
        rd32(a_claim(0), v32);
        chk("and that is what is claimed", {32'd0, v32}, 64'd9);
        wr32(a_claim(0), 32'd9);
        wr32(a_threshold(0), 32'd0);
        src[7] = 1'b0; src[9] = 1'b0;
        repeat (3) @(posedge clk);
        drain(0);
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("nothing is left over", {32'd0, v32}, 64'd0);

        //-------------------------------------------------------------
        $display("--- 6. the contexts are separate ---");
        //-------------------------------------------------------------
        wr32(a_enable(0, 0), 32'(1 << 3));
        wr32(a_enable(1, 0), 32'(1 << 4));
        wr32(a_prio(3), 32'd1);
        wr32(a_prio(4), 32'd1);
        src[3] = 1'b1; src[4] = 1'b1;
        repeat (2) @(posedge clk);
        chk("each context sees only what it enabled", {60'd0, irq}, 64'b0011);

        rd32(a_claim(1), v32);
        chk("context 1 claims its own source", {32'd0, v32}, 64'd4);
        rd32(a_claim(0), v32);
        chk("context 0 claims its own", {32'd0, v32}, 64'd3);
        repeat (1) @(posedge clk);
        chk("both are quiet now", {60'd0, irq}, 64'd0);

        // a completion from the wrong context is ignored
        wr32(a_claim(0), 32'd4);
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("a completion of a source the context may not use does nothing",
            {32'd0, v32}, 64'd0);
        wr32(a_claim(1), 32'd4);
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("the right context completes it", {32'd0, v32}, 64'(1 << 4));

        wr32(a_claim(0), 32'd3);
        src[3] = 1'b0; src[4] = 1'b0;
        repeat (2) @(posedge clk);
        drain(1);
        drain(0);
        repeat (2) @(posedge clk);
        peek_pending(v32);
        chk("and nothing is left over here either", {32'd0, v32}, 64'd0);

        //-------------------------------------------------------------
        $display("--- 7. the registers read back ---");
        //-------------------------------------------------------------
        wr32(a_prio(1), 32'd7);
        rd32(a_prio(1), v32);
        chk("a priority reads back", {32'd0, v32}, 64'd7);
        wr32(a_prio(1), 32'hFFFF_FFFF);
        rd32(a_prio(1), v32);
        chk("and keeps only the bits it has", {32'd0, v32},
            64'((1 << PRIO_BITS) - 1));
        wr32(a_prio(1), 32'd0);

        wr32(a_threshold(2), 32'd4);
        rd32(a_threshold(2), v32);
        chk("a threshold reads back", {32'd0, v32}, 64'd4);
        rd32(a_threshold(3), v32);
        chk("and belongs to its own context", {32'd0, v32}, 64'd0);
        wr32(a_threshold(2), 32'd0);

        wr32(a_enable(2, 0), 32'hDEAD_BEEF);
        rd32(a_enable(2, 0), v32);
        chk("an enable word reads back without source 0",
            {32'd0, v32}, 64'h0000_0000_DEAD_BEEE);
        wr32(a_enable(2, 0), 32'd0);

        //-------------------------------------------------------------
        $display("--- 8. what is not there ---");
        //-------------------------------------------------------------
        wr32(a_prio(0), 32'd7);
        rd32(a_prio(0), v32);
        chk("source 0 has no priority", {32'd0, v32}, 64'd0);
        rd32(a_prio(SOURCES + 1), v32);
        chk("a source above the last one reads zero", {32'd0, v32}, 64'd0);
        rd32(a_claim(CONTEXTS), v32);
        chk("a context that does not exist reads zero", {32'd0, v32}, 64'd0);

        // a wide read that happens to cover the claim register must not claim
        src[5] = 1'b1;
        wr32(a_enable(0, 0), 32'(1 << 5));
        wr32(a_prio(5), 32'd1);
        repeat (2) @(posedge clk);
        rd(a_threshold(0), v64);                      // 64 bit, covers both
        repeat (1) @(posedge clk);
        peek_pending(v32);
        chk("a read of the threshold does not claim", {32'd0, v32}, 64'(1 << 5));
        chk("and the line is still up", {60'd0, irq[0]}, 64'd1);

        //-------------------------------------------------------------
        $display("");
        $display("==========================================================");
        if (errors == 0) $display(" PLIC RESULT : PASS   (%0d checks)", checks);
        else             $display(" PLIC RESULT : FAIL   (%0d checks, %0d errors)",
                                  checks, errors);
        $display("==========================================================");
        $finish;
    end

endmodule : tb_PLIC
