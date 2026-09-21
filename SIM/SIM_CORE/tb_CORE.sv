//---------------------------------------------------------------------------
// tb_CORE.sv
//
// Core test bench (M2). The core runs against CORE_MEM_MODEL, which speaks
// the cache port protocol, so the core is tested without the caches. The
// CLINT of the system is next to the model, at its usual address.
//
//   Programs follow the riscv-tests convention: the program writes 1 to
//   `tohost` when it passes and (testnum << 1) | 1 when it fails. The test
//   bench watches the store channel and ends the run on the first value that
//   is not zero, so the program may spin afterwards.
//
//   Plusargs:
//     +hex=<file>     program image, one 64 bit word per line
//     +name=<name>    name printed in the result line
//     +tohost=<addr>  address of the tohost word (default 0x80002000)
//     +trace          print every retired instruction and every trap
//     +dtrace         print every access on the data port
//     +istall=<n>     hold the ready of the instruction port low in n% of the
//                     cycles, +dstall=<n> the same for the data port
//     +maxcycles=n    watchdog (default 200000)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_CORE;

    localparam int          PADDR_WIDTH = 40;
    localparam logic [63:0] MEM_BASE    = 64'h0000_0000_8000_0000;
    localparam int          MEM_WORDS   = 8192;                  // 64 KiB
    localparam logic [63:0] CLINT_BASE  = 64'h0000_0000_0200_0000;

    //=================================================================
    // clock and reset
    //=================================================================
    logic clk = 1'b0;
    logic rst_n;

    always #10 clk = ~clk;          // 50 MHz

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    //=================================================================
    // DUT
    //=================================================================
    logic                   i_req_valid, i_req_ready, i_resp_valid, i_resp_error, i_kill;
    logic [PADDR_WIDTH-1:0] i_req_addr, i_req_paddr;
    logic [63:0]            i_resp_data;
    logic                   i_flush_valid, i_flush_done;

    logic                   d_req_valid, d_req_ready, d_resp_valid, d_resp_error;
    logic [PADDR_WIDTH-1:0] d_req_addr, d_req_paddr;
    logic [1:0]             d_req_size;
    logic [3:0]             d_req_cmd;
    logic [63:0]            d_req_wdata, d_resp_data;

    logic                   trace_valid, trace_rd_we;
    logic [63:0]            trace_pc, trace_rd_data;
    logic [31:0]            trace_insn;
    logic [4:0]             trace_rd;

    logic [1:0]             trace_priv;

    logic                   trap_valid, trap_is_int, trap_to_s;
    logic [4:0]             trap_cause;
    logic [63:0]            trap_epc, trap_tval;

    logic                   irq_m_ext, irq_s_ext;
    logic [0:0]             irq_m_soft, irq_m_timer;   // one bit per hart
    logic [63:0]            mtime;

    // the instruction cache of the system answers the invalidate of a fence.i
    // as soon as it is idle; there is no cache here, so it is always done
    assign i_flush_done = i_flush_valid;

    CPU_CORE
        #(
            .PADDR_WIDTH  (PADDR_WIDTH),
            .RESET_VECTOR (MEM_BASE),
            .HART_ID      (64'd0),
            .PQ_DEPTH     (16)
        )
    u_core
        (
            .clk           (clk),
            .rst_n         (rst_n),
            .i_req_valid   (i_req_valid),
            .i_req_ready   (i_req_ready),
            .i_req_addr    (i_req_addr),
            .i_req_paddr   (i_req_paddr),
            .i_resp_valid  (i_resp_valid),
            .i_resp_data   (i_resp_data),
            .i_resp_error  (i_resp_error),
            .i_flush_valid (i_flush_valid),
            .i_flush_done  (i_flush_done),
            .i_kill        (i_kill),
            .d_req_valid   (d_req_valid),
            .d_req_ready   (d_req_ready),
            .d_req_addr    (d_req_addr),
            .d_req_paddr   (d_req_paddr),
            .d_req_size    (d_req_size),
            .d_req_cmd     (d_req_cmd),
            .d_req_wdata   (d_req_wdata),
            .d_resp_valid  (d_resp_valid),
            .d_resp_data   (d_resp_data),
            .d_resp_error  (d_resp_error),
            .irq_m_soft    (irq_m_soft[0]),
            .irq_m_timer   (irq_m_timer[0]),
            .irq_m_ext     (irq_m_ext),
            .irq_s_ext     (irq_s_ext),
            .mtime         (mtime),
            .trace_valid   (trace_valid),
            .trace_pc      (trace_pc),
            .trace_insn    (trace_insn),
            .trace_rd_we   (trace_rd_we),
            .trace_rd      (trace_rd),
            .trace_rd_data (trace_rd_data),
            .trace_priv    (trace_priv),
            .trap_valid    (trap_valid),
            .trap_is_int   (trap_is_int),
            .trap_cause    (trap_cause),
            .trap_epc      (trap_epc),
            .trap_tval     (trap_tval),
            .trap_to_s     (trap_to_s)
        );

    //=================================================================
    // memory model and CLINT
    //=================================================================
    logic        clint_sel, clint_we;
    logic [15:0] clint_addr;
    logic [63:0] clint_wdata, clint_rdata;
    logic [7:0]  clint_wstrb;
    logic        prot_error;

    CORE_MEM_MODEL
        #(
            .PADDR_WIDTH (PADDR_WIDTH),
            .BASE_ADDR   (MEM_BASE),
            .WORDS       (MEM_WORDS),
            .CLINT_BASE  (CLINT_BASE),
            .I_LATENCY   (2),
            .D_LATENCY   (3)
        )
    u_mem
        (
            .clk          (clk),
            .rst_n        (rst_n),
            .i_req_valid  (i_req_valid),
            .i_req_ready  (i_req_ready),
            .i_req_addr   (i_req_addr),
            .i_kill       (i_kill),
            .i_resp_valid (i_resp_valid),
            .i_resp_data  (i_resp_data),
            .i_resp_error (i_resp_error),
            .d_req_valid  (d_req_valid),
            .d_req_ready  (d_req_ready),
            .d_req_addr   (d_req_addr),
            .d_req_size   (d_req_size),
            .d_req_cmd    (d_req_cmd),
            .d_req_wdata  (d_req_wdata),
            .d_resp_valid (d_resp_valid),
            .d_resp_data  (d_resp_data),
            .d_resp_error (d_resp_error),
            .clint_sel    (clint_sel),
            .clint_we     (clint_we),
            .clint_addr   (clint_addr),
            .clint_wdata  (clint_wdata),
            .clint_wstrb  (clint_wstrb),
            .clint_rdata  (clint_rdata),
            .irq_ext      (irq_m_ext),
            .irq_s_ext    (irq_s_ext),
            .prot_error   (prot_error)
        );

    CPU_CLINT #(.NUM_HARTS(1), .TICK_DIV(1)) u_clint
        (
            .clk         (clk),
            .rst_n       (rst_n),
            .sel         (clint_sel),
            .we          (clint_we),
            .addr        (clint_addr),
            .wdata       (clint_wdata),
            .wstrb       (clint_wstrb),
            .rdata       (clint_rdata),
            .irq_m_soft  (irq_m_soft),
            .irq_m_timer (irq_m_timer),
            .mtime       (mtime)
        );

    //=================================================================
    // program image
    //=================================================================
    string       hex_file;
    string       test_name;
    logic [63:0] tohost_addr;

    initial begin
        if (!$value$plusargs("hex=%s", hex_file))   hex_file  = "tests/t01_alu.hex";
        if (!$value$plusargs("name=%s", test_name)) test_name = hex_file;
        if (!$value$plusargs("tohost=%h", tohost_addr))
            tohost_addr = 64'h0000_0000_8000_2000;
        for (int i = 0; i < MEM_WORDS; i++) u_mem.mem[i] = 64'd0;
        $readmemh(hex_file, u_mem.mem);
    end

    //=================================================================
    // tohost, trace
    //=================================================================
    logic [63:0] tohost;
    int          n_retired;
    bit          do_trace;
    logic        last_trace_valid;
    logic [63:0] last_trace_pc;
    logic        retire_error;

    logic        seen_trap;
    logic        last_trap_int;
    logic [4:0]  last_trap_cause;
    logic [63:0] last_trap_epc, last_trap_tval;

    initial begin
        tohost           = 64'd0;
        n_retired        = 0;
        do_trace         = $test$plusargs("trace");
        last_trace_valid = 1'b0;
        last_trace_pc    = 64'd0;
        retire_error     = 1'b0;
        seen_trap        = 1'b0;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (d_req_valid && d_req_ready && (d_req_cmd == 4'd1) &&
                ({24'd0, d_req_addr} == tohost_addr) && (d_req_wdata != 64'd0))
                tohost <= d_req_wdata;

            if (trap_valid) begin
                seen_trap       <= 1'b1;
                last_trap_int   <= trap_is_int;
                last_trap_cause <= trap_cause;
                last_trap_epc   <= trap_epc;
                last_trap_tval  <= trap_tval;
                if (do_trace)
                    $display("[%0t] TRAP %s cause=%0d epc=%010h tval=%016h",
                             $time, trap_is_int ? "interrupt" : "exception",
                             trap_cause, trap_epc, trap_tval);
            end

            last_trace_valid <= trace_valid;
            last_trace_pc    <= trace_pc;
            if (trace_valid) begin
                n_retired <= n_retired + 1;
                // none of the test programs is a one instruction loop, so the
                // same PC twice in a row means the pipeline retired it twice
                if (last_trace_valid && (trace_pc == last_trace_pc)) begin
                    retire_error <= 1'b1;
                    $display("[%0t] tb_CORE: pc %010h retired twice in a row",
                             $time, trace_pc);
                end
                if (do_trace) begin
                    if (u_core.wb_fp_we)
                        $display("[%0t] %010h : %08h   f%0d <- %016h",
                                 $time, trace_pc, trace_insn,
                                 u_core.wb_fp_rd, u_core.wb_fp_data);
                    else if (trace_rd_we)
                        $display("[%0t] %010h : %08h   x%0d <- %016h",
                                 $time, trace_pc, trace_insn, trace_rd, trace_rd_data);
                    else
                        $display("[%0t] %010h : %08h", $time, trace_pc, trace_insn);
                end
            end
        end
    end

    //=================================================================
    // end of test
    //=================================================================
    int max_cycles;
    int cycle_count;

    task automatic report_trap();
        if (seen_trap)
            $display("          last trap: %s cause=%0d epc=%010h tval=%016h",
                     last_trap_int ? "interrupt" : "exception",
                     last_trap_cause, last_trap_epc, last_trap_tval);
        else
            $display("          no trap was taken");
    endtask

    initial begin
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 200000;

        wait (rst_n === 1'b1);
        cycle_count = 0;
        while ((tohost === 64'd0) && (cycle_count < max_cycles)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end

        $display("");
        $display("==========================================================");
        if (tohost === 64'd0) begin
            $display(" %s : FAIL   (watchdog after %0d cycles, %0d retired, pc=%010h)",
                     test_name, cycle_count, n_retired, u_core.wb_pc);
            report_trap();
        end else if (prot_error) begin
            $display(" %s : FAIL   (the core broke the rules of the cache port)",
                     test_name);
        end else if (retire_error) begin
            $display(" %s : FAIL   (an instruction was retired twice)", test_name);
        end else if (tohost == 64'd1) begin
            $display(" %s : PASS   (%0d instructions retired, %0d cycles)",
                     test_name, n_retired, cycle_count);
        end else begin
            $display(" %s : FAIL   (check %0d, tohost=%016h)",
                     test_name, tohost >> 1, tohost);
            report_trap();
        end
        $display("==========================================================");
        $finish;
    end

    always @(posedge clk) begin
        if ($test$plusargs("ftrace") && rst_n && u_core.fpu_start)
            $display("[%0t] FPU op=%0d fmt=%0d rm=%0d a=%016h b=%016h c=%016h",
                     $time, u_core.ex_fp_op, u_core.ex_fp_fmt, u_core.ex_rm_eff,
                     u_core.fpu_a, u_core.ex_fs2_fwd, u_core.ex_fs3_fwd);
    end

    // +dtrace : every access on the data port
    always @(posedge clk) begin
        if ($test$plusargs("dtrace") && rst_n && d_req_valid && d_req_ready)
            $display("[%0t] REQ cmd=%0d size=%0d addr=%010h wdata=%016h",
                     $time, d_req_cmd, d_req_size, d_req_addr, d_req_wdata);
        if ($test$plusargs("dtrace") && rst_n && d_resp_valid)
            $display("[%0t] RSP %016h err=%b", $time, d_resp_data, d_resp_error);
    end

`ifdef DUMP_VCD
    initial begin
        string vcd_name;
        if (!$value$plusargs("vcd=%s", vcd_name)) vcd_name = "tb_CORE.vcd";
        $dumpfile(vcd_name);
        $dumpvars(0, tb_CORE);
    end
`endif

endmodule : tb_CORE
