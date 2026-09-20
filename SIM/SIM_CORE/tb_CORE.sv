//---------------------------------------------------------------------------
// tb_CORE.sv
//
// Core test bench (M1). The core runs against CORE_MEM_MODEL, which speaks
// the cache port protocol, so the core is tested without the caches.
//
//   Programs are built from tests/*.S and follow the riscv-tests convention:
//   the program writes 1 to `tohost` when it passes and (testnum << 1) | 1
//   when it fails, then executes ECALL, which stops the core in M1.
//
//   Plusargs:
//     +hex=<file>   program image, one 64 bit word per line (default given
//                   by the Makefile)
//     +trace        print every retired instruction
//     +maxcycles=n  watchdog (default 200000)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_CORE;

    localparam int          PADDR_WIDTH = 40;
    localparam logic [63:0] MEM_BASE    = 64'h0000_0000_8000_0000;
    localparam int          MEM_WORDS   = 8192;                  // 64 KiB
    localparam logic [63:0] TOHOST      = 64'h0000_0000_8000_2000;

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

    logic                   trace_valid, trace_rd_we, core_halted;
    logic [63:0]            trace_pc, trace_rd_data;
    logic [31:0]            trace_insn;
    logic [4:0]             trace_rd;
    logic [2:0]             halt_cause;

    assign i_flush_done = 1'b1;

    CPU_CORE
        #(
            .PADDR_WIDTH  (PADDR_WIDTH),
            .RESET_VECTOR (MEM_BASE),
            .FQ_DEPTH     (4)
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
            .trace_valid   (trace_valid),
            .trace_pc      (trace_pc),
            .trace_insn    (trace_insn),
            .trace_rd_we   (trace_rd_we),
            .trace_rd      (trace_rd),
            .trace_rd_data (trace_rd_data),
            .core_halted   (core_halted),
            .halt_cause    (halt_cause)
        );

    logic prot_error;

    CORE_MEM_MODEL
        #(
            .PADDR_WIDTH (PADDR_WIDTH),
            .BASE_ADDR   (MEM_BASE),
            .WORDS       (MEM_WORDS),
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
            .prot_error   (prot_error)
        );

    //=================================================================
    // program image
    //=================================================================
    string hex_file;
    string test_name;

    initial begin
        if (!$value$plusargs("hex=%s", hex_file)) hex_file = "tests/t01_alu.hex";
        if (!$value$plusargs("name=%s", test_name)) test_name = hex_file;
        for (int i = 0; i < MEM_WORDS; i++) u_mem.mem[i] = 64'd0;
        $readmemh(hex_file, u_mem.mem);
    end

    //=================================================================
    // tohost : the program reports the result here
    //=================================================================
    logic [63:0] tohost;
    int          n_retired;
    bit          do_trace;
    logic        last_trace_valid;
    logic [63:0] last_trace_pc;
    logic        retire_error;

    initial begin
        tohost           = 64'd0;
        n_retired        = 0;
        do_trace         = $test$plusargs("trace");
        last_trace_valid = 1'b0;
        last_trace_pc    = 64'd0;
        retire_error     = 1'b0;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (d_req_valid && d_req_ready && (d_req_cmd == 4'd1) &&
                ({24'd0, d_req_addr} == TOHOST))
                tohost <= d_req_wdata;
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
                    if (trace_rd_we)
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
    string cause_name [0:4];
    int    max_cycles;
    int    cycle_count;

    initial begin
        cause_name[0] = "none";
        cause_name[1] = "ECALL";
        cause_name[2] = "EBREAK";
        cause_name[3] = "illegal instruction";
        cause_name[4] = "bus error";
        if (!$value$plusargs("maxcycles=%d", max_cycles)) max_cycles = 200000;

        wait (rst_n === 1'b1);
        cycle_count = 0;
        while ((core_halted !== 1'b1) && (cycle_count < max_cycles)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end

        $display("");
        $display("==========================================================");
        if (core_halted !== 1'b1) begin
            $display(" %s : FAIL   (watchdog after %0d cycles, %0d retired, pc=%010h)",
                     test_name, cycle_count, n_retired, u_core.wb_pc);
        end else begin
            repeat (4) @(posedge clk);
            if (prot_error) begin
                $display(" %s : FAIL   (the core broke the rules of the cache port)",
                         test_name);
            end else if (retire_error) begin
                $display(" %s : FAIL   (an instruction was retired twice)", test_name);
            end else if (halt_cause != 3'd1) begin
                $display(" %s : FAIL   (core stopped on %s at pc=%010h)",
                         test_name, cause_name[halt_cause], u_core.wb_pc);
            end else if (tohost == 64'd1) begin
                $display(" %s : PASS   (%0d instructions retired, %0d cycles)",
                         test_name, n_retired, cycle_count);
            end else if (tohost == 64'd0) begin
                $display(" %s : FAIL   (ECALL without a result in tohost)", test_name);
            end else begin
                $display(" %s : FAIL   (check %0d, tohost=%016h)",
                         test_name, tohost >> 1, tohost);
            end
        end
        $display("==========================================================");
        $finish;
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
