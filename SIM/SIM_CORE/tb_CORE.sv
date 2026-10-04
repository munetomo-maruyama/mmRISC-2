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
//
//   t23_debug is run against a debugger in the bench (see "debugger"): it
//   halts the core, steps it and reads and writes its registers through the
//   debug port of the core, the way DBG_DM does.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_CORE;

    localparam int          PADDR_WIDTH = 40;
    localparam logic [63:0] MEM_BASE    = 64'h0000_0000_8000_0000;
    // Two megabytes. The riscv-tests virtual memory environment maps a whole
    // megapage of them and hands out pages out of the first half of it.
    localparam int          MEM_WORDS   = 262144;                // 2 MiB
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
    logic                   i_cancel;
    logic [PADDR_WIDTH-1:0] i_req_addr, i_req_paddr;
    logic [63:0]            i_resp_data;
    logic                   i_flush_valid, i_flush_done;

    logic                   d_req_valid, d_req_ready, d_resp_valid, d_resp_error;
    logic [PADDR_WIDTH-1:0] d_req_addr, d_req_paddr;
    logic [1:0]             d_req_size;
    logic [3:0]             d_req_cmd;
    logic [63:0]            d_req_wdata, d_resp_data;
    logic                   d_req_cancel;

    logic                   trace_valid, trace_rd_we;
    logic [63:0]            trace_pc, trace_rd_data;
    logic [31:0]            trace_insn;
    logic [4:0]             trace_rd;

    logic [1:0]             trace_priv;

    logic                   trap_valid, trap_is_int, trap_to_s;
    logic [4:0]             trap_cause;
    logic [63:0]            trap_epc, trap_tval;

    // the lines the core sees: what the bench raises by hand, or the PLIC
    logic                   irq_m_ext, irq_s_ext;
    logic                   tb_irq_m_ext, tb_irq_s_ext;
    logic [1:0]             plic_irq;
    logic [31:0]            plic_src;

    assign irq_m_ext = tb_irq_m_ext | plic_irq[0];
    assign irq_s_ext = tb_irq_s_ext | plic_irq[1];
    logic [0:0]             irq_m_soft, irq_m_timer;   // one bit per hart
    logic [63:0]            mtime;

    // debug port (driven by the debugger below, idle for the other tests)
    logic                   dbg_haltreq, dbg_resumereq, dbg_resethaltreq;
    logic                   dbg_halted, dbg_running, dbg_resumed;
    logic                   dbg_reg_req, dbg_reg_wr, dbg_reg_size64;
    logic [15:0]            dbg_reg_regno;
    logic [63:0]            dbg_reg_wdata, dbg_reg_rdata;
    logic                   dbg_reg_ack, dbg_reg_err;

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
            .i_cancel      (i_cancel),
            .d_req_valid   (d_req_valid),
            .d_req_ready   (d_req_ready),
            .d_req_addr    (d_req_addr),
            .d_req_paddr   (d_req_paddr),
            .d_req_size    (d_req_size),
            .d_req_cmd     (d_req_cmd),
            .d_req_wdata   (d_req_wdata),
            .d_req_cancel  (d_req_cancel),
            .d_resp_valid  (d_resp_valid),
            .d_resp_data   (d_resp_data),
            .d_resp_error  (d_resp_error),
            .irq_m_soft    (irq_m_soft[0]),
            .irq_m_timer   (irq_m_timer[0]),
            .irq_m_ext     (irq_m_ext),
            .irq_s_ext     (irq_s_ext),
            .mtime         (mtime),
            .ev_ic_refill  (1'b0),            // no caches here
            .ev_dc_refill  (1'b0),
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
            .trap_to_s     (trap_to_s),
            .dbg_haltreq      (dbg_haltreq),
            .dbg_resumereq    (dbg_resumereq),
            .dbg_resethaltreq (dbg_resethaltreq),
            .dbg_halted       (dbg_halted),
            .dbg_running      (dbg_running),
            .dbg_resumed      (dbg_resumed),
            .dbg_reg_req      (dbg_reg_req),
            .dbg_reg_wr       (dbg_reg_wr),
            .dbg_reg_regno    (dbg_reg_regno),
            .dbg_reg_size64   (dbg_reg_size64),
            .dbg_reg_wdata    (dbg_reg_wdata),
            .dbg_reg_ack      (dbg_reg_ack),
            .dbg_reg_rdata    (dbg_reg_rdata),
            .dbg_reg_err      (dbg_reg_err)
        );

    //=================================================================
    // memory model and CLINT
    //=================================================================
    logic        plic_sel, plic_we;
    logic [21:0] plic_addr;
    logic [63:0] plic_wdata, plic_rdata;
    logic [7:0]  plic_wstrb;

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
            .i_req_paddr  (i_req_paddr),
            .i_kill       (i_kill),
            .i_cancel     (i_cancel),
            .i_resp_valid (i_resp_valid),
            .i_resp_data  (i_resp_data),
            .i_resp_error (i_resp_error),
            .d_req_valid  (d_req_valid),
            .d_req_ready  (d_req_ready),
            .d_req_addr   (d_req_addr),
            .d_req_paddr  (d_req_paddr),
            .d_req_cancel (d_req_cancel),
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
            .irq_ext      (tb_irq_m_ext),
            .irq_s_ext    (tb_irq_s_ext),
            .plic_sel     (plic_sel),
            .plic_we      (plic_we),
            .plic_addr    (plic_addr),
            .plic_wdata   (plic_wdata),
            .plic_wstrb   (plic_wstrb),
            .plic_rdata   (plic_rdata),
            .plic_src     (plic_src),
            .prot_error   (prot_error)
        );

    // context 0 is machine mode of hart 0, context 1 its supervisor mode,
    // which is the layout the device tree of Linux describes
    CPU_PLIC #(.SOURCES(31), .CONTEXTS(2), .PRIO_BITS(3)) u_plic
        (
            .clk   (clk),
            .rst_n (rst_n),
            .sel   (plic_sel),
            .we    (plic_we),
            .addr  (plic_addr),
            .wdata (plic_wdata),
            .wstrb (plic_wstrb),
            .rdata (plic_rdata),
            .src   ({plic_src[31:1], 1'b0}),
            .irq   (plic_irq)
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
    logic        resp_error_tb;     // an answer of the data port nobody waits for
    logic        fence_error_tb;    // a FENCE went ahead of an older access

    logic        seen_trap;
    logic        last_trap_int;
    logic [4:0]  last_trap_cause;
    logic [63:0] last_trap_epc, last_trap_tval;

    // a branch, a jump, or one of their compressed forms
    function automatic bit is_ctrl(input logic [31:0] insn);
        if (insn[1:0] == 2'b11)
            return (insn[6:0] == 7'h63) || (insn[6:0] == 7'h6F) ||
                   (insn[6:0] == 7'h67);
        else if (insn[1:0] == 2'b01)
            return (insn[15:13] == 3'b101) ||        // c.j
                   (insn[15:13] == 3'b110) ||        // c.beqz
                   (insn[15:13] == 3'b111);          // c.bnez
        else if (insn[1:0] == 2'b10)
            return (insn[15:13] == 3'b100) && (insn[6:2] == 5'd0);  // c.jr/jalr
        else
            return 1'b0;
    endfunction

    initial begin
        tohost           = 64'd0;
        n_retired        = 0;
        do_trace         = $test$plusargs("trace");
        last_trace_valid = 1'b0;
        last_trace_pc    = 64'd0;
        retire_error     = 1'b0;
        resp_error_tb    = 1'b0;
        fence_error_tb   = 1'b0;
        seen_trap        = 1'b0;
    end

    //-----------------------------------------------------------------
    // The write is caught by its physical address, one cycle behind the
    // request, because the virtual memory environment writes the word
    // through a kernel mapping and not at the address it was linked at.
    //
    // The value follows the HTIF convention: the top byte is the device and
    // the one below it the command. Device 0 ends the test, device 1 is the
    // console, and the word has to be put back to zero afterwards because
    // the caller waits for that before it writes the next one.
    //-----------------------------------------------------------------
    logic        th_write, th_pending;
    logic [63:0] th_value;
    logic [7:0]  th_dev, th_cmd;

    assign th_write = u_mem.s1d_live && (u_mem.s1d_cmd == 4'd1) &&
                      ({24'd0, u_mem.s1d_addr} == tohost_addr);
    assign th_value = u_mem.s1d_wdata;
    assign th_dev   = th_value[63:56];
    assign th_cmd   = th_value[55:48];

    always @(posedge clk) begin
        if (rst_n) begin
            th_pending <= th_write && (th_value != 64'd0) && (th_dev != 8'd0);
            if (th_write && (th_value != 64'd0)) begin
                if (th_dev == 8'd0)
                    tohost <= th_value;                  // the test is over
                else if ((th_dev == 8'd1) && (th_cmd == 8'd1))
                    $write("%c", th_value[7:0]);         // the console
            end
            // One cycle later, so that it does not race with the write of
            // the memory model itself: the program waits for the word to go
            // back to zero before it sends the next one.
            if (th_pending)
                u_mem.mem[(tohost_addr - MEM_BASE) >> 3] <= 64'd0;

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

            // Every answer the LSU passes on belongs to the access in MA
            // (CORE_LSU): one that arrives while MA waits for none is an
            // answer of a flushed access that should have been dropped.
            if (u_core.lsu_resp_valid && !(u_core.ma_valid && u_core.ma_mem)) begin
                resp_error_tb <= 1'b1;
                $display("[%0t] tb_CORE: an answer of the data port that no access in MA waits for", $time);
            end
            // A FENCE goes on only when every access in front of it has
            // been answered (CPU_CORE_SPEC.md 5.3): in the cycle it leaves
            // ID, the LSU has nothing in flight but answers it will throw
            // away (those of a flushed path, which are no accesses at all).
            if (u_core.id_issue && u_core.dec_is_fence &&
                (u_core.u_lsu.os != u_core.u_lsu.drop)) begin
                fence_error_tb <= 1'b1;
                $display("[%0t] tb_CORE: a FENCE issued with %0d accesses in front of it unanswered",
                         $time, u_core.u_lsu.os - u_core.u_lsu.drop);
            end
            last_trace_valid <= trace_valid;
            last_trace_pc    <= trace_pc;
            if (trace_valid) begin
                n_retired <= n_retired + 1;
                // The same PC twice in a row means the pipeline retired it
                // twice -- unless it is a branch to itself, which t06 uses
                // to wait for an interrupt. Before the branch predictor
                // there was always a refetch between two turns of such a
                // loop; now there is not, so control transfers are left out
                // of the check.
                if (last_trace_valid && (trace_pc == last_trace_pc) &&
                    !is_ctrl(trace_insn)) begin
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
    // debugger (t23_debug)
    //
    //   It does what DBG_DM does on behalf of OpenOCD, one step at a time,
    //   in step with the program (tests/t23_debug.S):
    //
    //   1 halt at reset (resethaltreq): cause 5, dpc at the reset vector;
    //     x10 and dcsr.ebreakm written; errors for a read only CSR, a
    //     register that does not exist and an access while running
    //   2 halt request in a loop: cause 3; three single steps (cause 4)
    //     whose pc follows the loop; x12 written
    //   3 EBREAK: cause 1 and no trap; GPR (64 and 32 bit), FPR and CSR
    //     written; a step with an interrupt pending and enabled goes to the
    //     next instruction, not to the handler; a step over ECALL stops on
    //     the first instruction of the handler
    //   4 halt request while WFI waits: the WFI completes, dpc is behind it;
    //     resumed in user mode through dcsr.prv
    //   5 triggers (Sdtrig), set up at the halt of 4 as gdb's hbreak and
    //     watch do through OpenOCD: dmode, action 1, in user mode. The
    //     execute trigger halts in front of its instruction (cause 2), the
    //     load trigger in front of the load, which has not written its
    //     register; hit is set, no trap is taken; tdata1 written to 0 takes
    //     a trigger away, one with dmode and nothing on keeps it for the
    //     debugger: tdata1 / tdata2 of a dmode trigger can be written by the
    //     debugger only (the program checks that)
    //=================================================================
    localparam logic [15:0] R_MSTATUS  = 16'h0300;
    localparam logic [15:0] R_MTVEC    = 16'h0305;
    localparam logic [15:0] R_MSCRATCH = 16'h0340;
    localparam logic [15:0] R_MEPC     = 16'h0341;
    localparam logic [15:0] R_MCAUSE   = 16'h0342;
    localparam logic [15:0] R_MHARTID  = 16'h0F14;
    localparam logic [15:0] R_DCSR     = 16'h07B0;
    localparam logic [15:0] R_DPC      = 16'h07B1;
    localparam logic [15:0] R_DSCRATCH0= 16'h07B2;
    localparam logic [15:0] R_TSELECT  = 16'h07A0;
    localparam logic [15:0] R_TDATA1   = 16'h07A1;
    localparam logic [15:0] R_TDATA2   = 16'h07A2;
    localparam logic [15:0] R_MTVAL    = 16'h0343;
    function automatic logic [15:0] R_X(input int n); return 16'h1000 + n; endfunction
    function automatic logic [15:0] R_F(input int n); return 16'h1020 + n; endfunction

    bit          dbg_test;
    int          dbg_fail;          // number of the first debugger check that failed
    logic [63:0] dr_data;
    logic        dr_err;

    task automatic dbg_check(input int n, input bit ok, input string what);
        if (!ok && dbg_fail == 0) begin
            dbg_fail = n;
            $display("[%0t] tb_CORE: debugger check %0d failed: %s", $time, n, what);
        end
    endtask

    // one register access, as DBG_DM makes it : a request pulse, then wait
    // for the acknowledge
    task automatic dbg_reg(input bit wr, input logic [15:0] regno,
                           input bit size64, input logic [63:0] wdata);
        int t;
        @(negedge clk);
        dbg_reg_req    = 1'b1;
        dbg_reg_wr     = wr;
        dbg_reg_regno  = regno;
        dbg_reg_size64 = size64;
        dbg_reg_wdata  = wdata;
        @(negedge clk);
        dbg_reg_req    = 1'b0;
        t = 0;
        while (dbg_reg_ack !== 1'b1 && t < 100) begin @(negedge clk); t++; end
        dr_data = dbg_reg_rdata;
        dr_err  = (t >= 100) ? 1'b1 : dbg_reg_err;
        if (t >= 100) $display("[%0t] tb_CORE: no answer to a register access", $time);
    endtask

    task automatic dbg_rd(input logic [15:0] regno);
        dbg_reg(1'b0, regno, 1'b1, 64'd0);
    endtask

    task automatic dbg_wr(input logic [15:0] regno, input logic [63:0] v);
        dbg_reg(1'b1, regno, 1'b1, v);
    endtask

    task automatic dbg_wait_halted(input int n);
        int t;
        t = 0;
        while (dbg_halted !== 1'b1 && t < 50000) begin @(negedge clk); t++; end
        dbg_check(n, dbg_halted === 1'b1, "the core did not halt");
    endtask

    task automatic dbg_resume(input int n);
        int t;
        bit seen;
        @(negedge clk);
        dbg_resumereq = 1'b1;
        @(negedge clk);
        dbg_resumereq = 1'b0;
        seen = (dbg_resumed === 1'b1);
        t = 0;
        while (!seen && t < 10) begin @(negedge clk); seen = (dbg_resumed === 1'b1); t++; end
        dbg_check(n, seen && dbg_running === 1'b1, "the core did not resume");
    endtask

    task automatic dbg_halt(input int n);
        @(negedge clk);
        dbg_haltreq = 1'b1;
        dbg_wait_halted(n);
        @(negedge clk);
        dbg_haltreq = 1'b0;
    endtask

    // dcsr.cause
    task automatic dbg_cause(input int n, input int cause);
        dbg_rd(R_DCSR);
        dbg_check(n, !dr_err && dr_data[8:6] == cause[2:0],
                  $sformatf("dcsr.cause %0d, expected %0d", dr_data[8:6], cause));
    endtask

    initial begin
        string       nm;
        logic [63:0] v, pc, pc0, x20, mst, bp;
        int          t;

        dbg_test = $value$plusargs("name=%s", nm) && (nm == "t23_debug");
        dbg_fail = 0;
        dbg_haltreq      = 1'b0;
        dbg_resumereq    = 1'b0;
        dbg_resethaltreq = dbg_test;       // before the reset ends
        dbg_reg_req      = 1'b0;
        dbg_reg_wr       = 1'b0;
        dbg_reg_regno    = 16'd0;
        dbg_reg_size64   = 1'b0;
        dbg_reg_wdata    = 64'd0;

        if (dbg_test) begin
            wait (rst_n === 1'b1);

            //---------------------------------------------------------
            // 1 halt at reset
            //---------------------------------------------------------
            dbg_wait_halted(101);
            dbg_resethaltreq = 1'b0;
            dbg_rd(R_DCSR);
            dbg_check(102, !dr_err && dr_data[31:28] == 4'd4 && dr_data[8:6] == 3'd5 &&
                           dr_data[1:0] == 2'd3,
                      $sformatf("dcsr after reset %016h", dr_data));
            dbg_rd(R_DPC);
            dbg_check(103, !dr_err && dr_data == MEM_BASE, "dpc after reset");
            dbg_wr(R_X(10), 64'h1234);
            dbg_check(104, !dr_err, "write x10");
            dbg_rd(R_X(10));
            dbg_check(105, !dr_err && dr_data == 64'h1234, "read x10 back");
            dbg_wr(R_X(0), 64'h55);                           // x0 stays 0
            dbg_rd(R_X(0));
            dbg_check(106, !dr_err && dr_data == 64'd0, "x0");
            dbg_reg(1'b1, R_DCSR, 1'b0, 64'h8003);            // ebreakm, prv M
            dbg_check(107, !dr_err, "write dcsr");
            dbg_rd(R_DCSR);
            dbg_check(108, dr_data[15] && !dr_data[2] && dr_data[31:28] == 4'd4,
                      "dcsr read back");
            dbg_wr(R_DSCRATCH0, 64'hdead_beef_0bad_f00d);
            dbg_rd(R_DSCRATCH0);
            dbg_check(109, !dr_err && dr_data == 64'hdead_beef_0bad_f00d, "dscratch0");
            dbg_wr(R_MHARTID, 64'd5);                         // read only
            dbg_check(110, dr_err, "write to mhartid did not fail");
            dbg_rd(16'h2000);                                 // no such register
            dbg_check(111, dr_err, "regno 0x2000 did not fail");
            dbg_rd(16'h07A6);                                 // no such CSR
            dbg_check(112, dr_err, "CSR 0x7a6 did not fail");
            dbg_rd(R_X(10));                                  // no error sticks
            dbg_check(113, !dr_err, "error after an error");
            dbg_resume(114);

            // the registers are not there while the core runs
            dbg_rd(R_X(10));
            dbg_check(115, dr_err, "access while running did not fail");

            //---------------------------------------------------------
            // 2 halt request in the loop, three steps
            //---------------------------------------------------------
            repeat (400) @(negedge clk);
            dbg_halt(201);
            dbg_cause(202, 3);
            dbg_rd(R_X(20));
            x20 = dr_data;
            dbg_check(203, x20 > 0 && x20 < 3000, $sformatf("x20 %0d", x20));
            dbg_rd(R_DPC);
            pc0 = dr_data;
            dbg_wr(R_DCSR, 64'h8007);                         // step
            for (int k = 0; k < 3; k++) begin
                dbg_rd(R_DPC);
                pc = dr_data;
                dbg_resume(204);
                dbg_wait_halted(205);
                dbg_cause(206, 4);
                dbg_rd(R_DPC);
                // addi / blt : one after the other
                dbg_check(207, dr_data != pc && (dr_data - pc0 == 4 || pc0 - dr_data == 4 ||
                                                 dr_data == pc0),
                          $sformatf("dpc %010h after a step from %010h", dr_data, pc));
                if (k == 1) begin
                    dbg_rd(R_X(20));
                    dbg_check(208, dr_data == x20 + 1,
                              $sformatf("x20 %0d after two steps from %0d", dr_data, x20));
                end
            end
            dbg_wr(R_DCSR, 64'h8003);
            dbg_wr(R_X(12), 64'h5678);
            dbg_resume(209);

            //---------------------------------------------------------
            // 3 EBREAK
            //---------------------------------------------------------
            dbg_wait_halted(301);
            dbg_cause(302, 1);
            dbg_rd(R_X(13));
            bp = dr_data;
            dbg_rd(R_DPC);
            dbg_check(303, dr_data == bp, $sformatf("dpc %010h at ebreak %010h", dr_data, bp));
            dbg_rd(R_MCAUSE);
            dbg_check(304, dr_data == 64'd0, "EBREAK took a trap");
            dbg_rd(R_MSCRATCH);
            dbg_check(305, dr_data == 64'h77, "mscratch");
            dbg_wr(R_X(15), 64'h9abc);
            dbg_reg(1'b1, R_X(11), 1'b0, 64'hffff_ffff_1234_5678);  // 32 bit
            dbg_check(306, !dr_err, "32 bit write");
            dbg_wr(R_F(1), 64'h3ff0_0000_0000_0000);
            dbg_check(307, !dr_err, "write f1");
            dbg_rd(R_F(1));
            dbg_check(308, dr_data == 64'h3ff0_0000_0000_0000, "f1 read back");
            dbg_wr(R_MSCRATCH, 64'h88);
            // an interrupt is pending and enabled in mie, only mstatus.MIE
            // keeps it out; with MIE on a step still does not take it
            dbg_rd(R_MSTATUS);
            mst = dr_data;
            dbg_wr(R_MSTATUS, mst | 64'h8);
            dbg_wr(R_DPC, bp + 4);
            dbg_wr(R_DCSR, 64'h8007);
            dbg_resume(309);
            dbg_wait_halted(310);
            dbg_cause(311, 4);
            dbg_rd(R_DPC);
            dbg_check(312, dr_data == bp + 8, $sformatf("dpc %010h after the step", dr_data));
            dbg_rd(R_X(16));
            dbg_check(313, dr_data == 64'd1, "the stepped instruction");
            dbg_rd(R_MCAUSE);
            dbg_check(314, dr_data == 64'd0, "an interrupt was taken while stepping");
            dbg_wr(R_MSTATUS, mst);
            // a step over ECALL ends on the handler
            dbg_resume(315);
            dbg_wait_halted(316);
            dbg_cause(317, 4);
            dbg_rd(R_MTVEC);
            v = dr_data;
            dbg_rd(R_DPC);
            dbg_check(318, dr_data == v, $sformatf("dpc %010h, mtvec %010h", dr_data, v));
            dbg_rd(R_MEPC);
            dbg_check(319, dr_data == bp + 8, "mepc of the ECALL");
            dbg_rd(R_MCAUSE);
            dbg_check(320, dr_data == 64'd11, "mcause of the ECALL");
            dbg_wr(R_DCSR, 64'h8003);
            dbg_resume(321);

            //---------------------------------------------------------
            // 4 WFI
            //---------------------------------------------------------
            t = 0;
            while (t < 20) begin
                @(negedge clk);
                t = u_core.wfi_wait ? t + 1 : 0;
            end
            dbg_halt(401);
            dbg_cause(402, 3);
            dbg_rd(R_X(19));
            v = dr_data;
            dbg_rd(R_DPC);
            dbg_check(403, dr_data == v, $sformatf("dpc %010h, behind the WFI %010h", dr_data, v));
            dbg_rd(R_DCSR);
            dbg_check(404, dr_data[1:0] == 2'd3, "dcsr.prv");
            dbg_wr(R_X(12), 64'd1);
            dbg_wr(R_DCSR, 64'h8000);                        // go on in user mode
            dbg_rd(R_DCSR);
            dbg_check(405, dr_data[1:0] == 2'd0, "dcsr.prv written");

            //---------------------------------------------------------
            // 5 triggers: an execute and a load trigger, dmode, action 1
            //---------------------------------------------------------
            dbg_rd(R_X(22));                                  // the instruction
            bp = dr_data;
            dbg_wr(R_TSELECT, 64'd0);
            dbg_wr(R_TDATA1, 64'h2800_0000_0000_100C);        // dmode, action 1, u, execute
            dbg_wr(R_TDATA2, bp);
            dbg_rd(R_TDATA1);
            dbg_check(501, !dr_err && dr_data == 64'h2800_0000_0000_100C,
                      $sformatf("tdata1 %016h", dr_data));
            dbg_rd(R_X(23));                                  // the data
            v = dr_data;
            dbg_wr(R_TSELECT, 64'd3);
            dbg_wr(R_TDATA1, 64'h2800_0000_0000_1009);        // dmode, action 1, u, load
            dbg_wr(R_TDATA2, v);
            dbg_rd(R_TDATA2);
            dbg_check(502, !dr_err && dr_data == v, "tdata2");
            dbg_wr(R_MCAUSE, 64'd0);                          // no trap from here on
            dbg_resume(406);

            dbg_wait_halted(503);
            dbg_cause(504, 2);
            dbg_rd(R_DPC);
            dbg_check(505, dr_data == bp, $sformatf("dpc %010h at the execute trigger %010h",
                                                    dr_data, bp));
            dbg_rd(R_DCSR);
            dbg_check(506, dr_data[1:0] == 2'd0, "dcsr.prv at the trigger");
            dbg_wr(R_TSELECT, 64'd0);
            dbg_rd(R_TDATA1);
            dbg_check(507, dr_data[20], "hit of the execute trigger");
            dbg_wr(R_TDATA1, 64'h2800_0000_0000_1000);        // off, still the debugger's
            dbg_rd(R_MCAUSE);
            dbg_check(508, dr_data == 64'd0, "the trigger took a trap");
            dbg_resume(509);

            dbg_wait_halted(510);
            dbg_cause(511, 2);
            dbg_rd(R_X(24));                                  // the load
            bp = dr_data;
            dbg_rd(R_DPC);
            dbg_check(512, dr_data == bp, $sformatf("dpc %010h at the load trigger %010h",
                                                    dr_data, bp));
            dbg_rd(R_X(25));
            dbg_check(513, dr_data == 64'h1111, "the load wrote its register");
            dbg_wr(R_TSELECT, 64'd3);
            dbg_rd(R_TDATA1);
            dbg_check(514, dr_data[20], "hit of the load trigger");
            dbg_wr(R_TDATA1, 64'd0);
            dbg_rd(R_MCAUSE);
            dbg_check(515, dr_data == 64'd0, "the trigger took a trap");
            dbg_resume(516);
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

    logic [63:0] bench_v;

    //=================================================================
    // where the cycles go (+profile)
    //
    //   Every cycle in which nothing reaches write back is charged to one
    //   reason, in the order below, so the parts add up to the whole.
    //=================================================================
    int p_total, p_retire, p_dcache, p_unit, p_mmu, p_starve, p_serial, p_other;

    always @(posedge clk) begin
        if (rst_n) begin
            p_total <= p_total + 1;
            if (trace_valid)                 p_retire <= p_retire + 1;
            else if (u_core.stall_ma)        p_dcache <= p_dcache + 1;
            else if ((u_core.mdu_active & ~u_core.mdu_done) |
                     (u_core.fpu_active & ~u_core.fpu_done))
                                             p_unit   <= p_unit   + 1;
            else if (u_core.ex_mmu_wait)     p_mmu    <= p_mmu    + 1;
            else if (~u_core.fq_valid)       p_starve <= p_starve + 1;
            else if (~u_core.id_ready)       p_serial <= p_serial + 1;
            else                             p_other  <= p_other  + 1;
        end
    end

    task automatic report_profile;
        $display("");
        $display(" cycles %0d, retired %0d, CPI %0.2f",
                 p_total, p_retire, real'(p_total) / real'(p_retire));
        $display("   waiting for the data cache : %6d (%0.1f%%)",
                 p_dcache, 100.0 * real'(p_dcache) / real'(p_total));
        $display("   waiting for MDU or FPU     : %6d (%0.1f%%)",
                 p_unit,   100.0 * real'(p_unit)   / real'(p_total));
        $display("   waiting for a translation  : %6d (%0.1f%%)",
                 p_mmu,    100.0 * real'(p_mmu)    / real'(p_total));
        $display("   front end has nothing      : %6d (%0.1f%%)",
                 p_starve, 100.0 * real'(p_starve) / real'(p_total));
        $display("   serialising an instruction : %6d (%0.1f%%)",
                 p_serial, 100.0 * real'(p_serial) / real'(p_total));
        $display("   other bubbles              : %6d (%0.1f%%)",
                 p_other,  100.0 * real'(p_other)  / real'(p_total));
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
        end else if (resp_error_tb) begin
            $display(" %s : FAIL   (an answer of the data port that nothing waited for)", test_name);
        end else if (fence_error_tb) begin
            $display(" %s : FAIL   (a FENCE went ahead of an access in front of it)", test_name);
        end else if (dbg_fail != 0) begin
            $display(" %s : FAIL   (debugger check %0d)", test_name, dbg_fail);
        end else if (tohost == 64'd1) begin
            $display(" %s : PASS   (%0d instructions retired, %0d cycles)",
                     test_name, n_retired, cycle_count);
        end else begin
            $display(" %s : FAIL   (check %0d, tohost=%016h)",
                     test_name, tohost >> 1, tohost);
            report_trap();
        end
        if ($test$plusargs("profile")) report_profile();
        if ($test$plusargs("bench")) begin
            // the sixteen words a benchmark leaves at BENCH_SLOT
            for (int k = 0; k < 16; k++) begin
                bench_v = u_mem.mem[((64'h8000_2100 - MEM_BASE) >> 3) + k];
                if (bench_v != 64'd0)
                    $display(" part %0d : %0d cycles", k, bench_v);
            end
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
