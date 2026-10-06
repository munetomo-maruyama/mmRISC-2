//---------------------------------------------------------------------------
// tb_L2.sv : verification of the L2 cache (RTL/CPU/CPU_L2)
//
// CPU_L2 between an AXI4 master of the bench (playing CPU_CACHE) and the
// memory model AXI4_SLAVE_MEM. The reference is a flat image of the
// memory as the master must see it (ref_mem): every beat read through the
// L2 is compared with it, and every write updates it when its B arrives.
//
//   1 directed: a read miss, then a hit; a line write that allocates without
//     reading memory; WAYS + 1 dirty lines in one set (an eviction and its
//     write out); a part write (write through: the bytes are in memory when
//     B comes back); short reads inside a line. Each step checks the
//     number of memory reads and writes and the PMU pulses it causes.
//   2 random, two threads at once (reads; line writes and part writes) on
//     lines that are hot, conflict in a few sets, or are anywhere; a line
//     in flight on one thread is not used by the other. Random R / B ready
//     and W valid on the bench side.
//   3 the same with stalls in the memory model (AXI4_SLAVE_MEM stall_en)
//   4 every line read back through the L2 and compared
//   5 reset: the L2 must come back empty. The memory gets a new pattern
//     through the back door, and every line must read as the new pattern
//
//   Parameters (make PARAMS=...): L2_SIZE, L2_WAYS, L2_RANDOM, RANGE_X
//   (the memory covers RANGE_X times the L2). Plusargs: +ops=<n> per random
//   phase, +seed=<n>.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_L2;

    parameter int L2_SIZE   = 256 * 1024;
    parameter int L2_WAYS   = 4;
    parameter int L2_RANDOM = 0;
    parameter int RANGE_X   = 4;

    localparam int AW      = 40;
    localparam int IW      = 4;
    localparam int LINES   = L2_SIZE / 64 * RANGE_X;      // lines of memory used
    localparam int WORDS   = LINES * 8;
    localparam int SETS    = L2_SIZE / (L2_WAYS * 64);
    localparam logic [AW-1:0] BASE = 40'h00_8000_0000;
    // CPU_L2's states M_INIT and M_IDLE (Verilator cannot reach an enum
    // item through the hierarchy)
    localparam int ST_INIT = 0, ST_IDLE = 1;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    //-----------------------------------------------------------------
    // slave side of the DUT (driven by the bench)
    //-----------------------------------------------------------------
    logic [IW-1:0] s_awid, s_arid, s_bid, s_rid;
    logic [AW-1:0] s_awaddr, s_araddr;
    logic [7:0]    s_awlen, s_arlen;
    logic          s_awvalid, s_awready, s_arvalid, s_arready;
    logic [63:0]   s_wdata, s_rdata;
    logic [7:0]    s_wstrb;
    logic          s_wlast, s_wvalid, s_wready;
    logic [1:0]    s_bresp, s_rresp;
    logic          s_bvalid, s_bready, s_rlast, s_rvalid, s_rready;

    // master side (DUT -> memory)
    logic [IW-1:0] m_awid, m_bid, m_arid, m_rid;
    logic [AW-1:0] m_awaddr, m_araddr;
    logic [7:0]    m_awlen, m_arlen;
    logic [2:0]    m_awsize, m_arsize, m_awprot, m_arprot;
    logic [1:0]    m_awburst, m_arburst, m_bresp, m_rresp;
    logic          m_awlock, m_arlock;
    logic [3:0]    m_awcache, m_arcache, m_awqos, m_arqos;
    logic          m_awvalid, m_awready, m_wlast, m_wvalid, m_wready;
    logic [63:0]   m_wdata, m_rdata;
    logic [7:0]    m_wstrb;
    logic          m_bvalid, m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    logic          ev_read, ev_miss;

    CPU_L2 #(.ADDR_WIDTH(AW), .ID_WIDTH(IW), .SIZE_BYTES(L2_SIZE), .WAYS(L2_WAYS),
             .REPLACE_RANDOM(L2_RANDOM)) u_dut
        (
            .clk (clk), .rst_n (rst_n),
            .s_axi4_awid (s_awid), .s_axi4_awaddr (s_awaddr), .s_axi4_awlen (s_awlen),
            .s_axi4_awsize (3'd3), .s_axi4_awburst (2'b01),
            .s_axi4_awvalid (s_awvalid), .s_axi4_awready (s_awready),
            .s_axi4_wdata (s_wdata), .s_axi4_wstrb (s_wstrb), .s_axi4_wlast (s_wlast),
            .s_axi4_wvalid (s_wvalid), .s_axi4_wready (s_wready),
            .s_axi4_bid (s_bid), .s_axi4_bresp (s_bresp), .s_axi4_bvalid (s_bvalid),
            .s_axi4_bready (s_bready),
            .s_axi4_arid (s_arid), .s_axi4_araddr (s_araddr), .s_axi4_arlen (s_arlen),
            .s_axi4_arsize (3'd3), .s_axi4_arburst (2'b01),
            .s_axi4_arvalid (s_arvalid), .s_axi4_arready (s_arready),
            .s_axi4_rid (s_rid), .s_axi4_rdata (s_rdata), .s_axi4_rresp (s_rresp),
            .s_axi4_rlast (s_rlast), .s_axi4_rvalid (s_rvalid), .s_axi4_rready (s_rready),
            .m_axi4_awid (m_awid), .m_axi4_awaddr (m_awaddr), .m_axi4_awlen (m_awlen),
            .m_axi4_awsize (m_awsize), .m_axi4_awburst (m_awburst), .m_axi4_awlock (m_awlock),
            .m_axi4_awcache (m_awcache), .m_axi4_awprot (m_awprot), .m_axi4_awqos (m_awqos),
            .m_axi4_awvalid (m_awvalid), .m_axi4_awready (m_awready),
            .m_axi4_wdata (m_wdata), .m_axi4_wstrb (m_wstrb), .m_axi4_wlast (m_wlast),
            .m_axi4_wvalid (m_wvalid), .m_axi4_wready (m_wready),
            .m_axi4_bid (m_bid), .m_axi4_bresp (m_bresp), .m_axi4_bvalid (m_bvalid),
            .m_axi4_bready (m_bready),
            .m_axi4_arid (m_arid), .m_axi4_araddr (m_araddr), .m_axi4_arlen (m_arlen),
            .m_axi4_arsize (m_arsize), .m_axi4_arburst (m_arburst), .m_axi4_arlock (m_arlock),
            .m_axi4_arcache (m_arcache), .m_axi4_arprot (m_arprot), .m_axi4_arqos (m_arqos),
            .m_axi4_arvalid (m_arvalid), .m_axi4_arready (m_arready),
            .m_axi4_rid (m_rid), .m_axi4_rdata (m_rdata), .m_axi4_rresp (m_rresp),
            .m_axi4_rlast (m_rlast), .m_axi4_rvalid (m_rvalid), .m_axi4_rready (m_rready),
            .ready (), .ev_read (ev_read), .ev_miss (ev_miss)
        );

    AXI4_SLAVE_MEM #(.ID_WIDTH(IW), .ADDR_WIDTH(AW), .DATA_WIDTH(64), .DEPTH(WORDS),
                     .BASE_ADDR(BASE), .INIT_BASE(64'h1000_0000_0000_0000)) u_mem
        (
            .clk (clk), .rst_n (1'b1),
            .awid (m_awid), .awaddr (m_awaddr), .awlen (m_awlen), .awsize (m_awsize),
            .awburst (m_awburst), .awlock (m_awlock), .awcache (m_awcache),
            .awprot (m_awprot), .awqos (m_awqos), .awvalid (m_awvalid), .awready (m_awready),
            .wdata (m_wdata), .wstrb (m_wstrb), .wlast (m_wlast), .wvalid (m_wvalid),
            .wready (m_wready),
            .bid (m_bid), .bresp (m_bresp), .bvalid (m_bvalid), .bready (m_bready),
            .arid (m_arid), .araddr (m_araddr), .arlen (m_arlen), .arsize (m_arsize),
            .arburst (m_arburst), .arlock (m_arlock), .arcache (m_arcache),
            .arprot (m_arprot), .arqos (m_arqos), .arvalid (m_arvalid), .arready (m_arready),
            .rid (m_rid), .rdata (m_rdata), .rresp (m_rresp), .rlast (m_rlast),
            .rvalid (m_rvalid), .rready (m_rready)
        );

    //-----------------------------------------------------------------
    // reference, counters, errors
    //-----------------------------------------------------------------
    logic [63:0] ref_mem [0:WORDS-1];
    bit          busy    [0:LINES-1];                 // a line in flight on a thread
    int          errors = 0, checks = 0;
    int          n_mar = 0, n_maw = 0, n_read = 0, n_miss = 0;
    longint      cyc = 0;
    longint      rd_ar_cyc, rd_first_cyc, rd_last_cyc;  // of the last read
    longint      wr_b_cyc;                              // B of the last write
    longint      m_ar_cyc, m_r_cyc;                     // memory: last AR, its first R
    bit          m_r_first;

    // the cycle count moves at the falling edge: stable for every process
    // that samples it at the rising one
    always @(negedge clk) cyc++;

    always @(posedge clk) begin
        if (m_arvalid && m_arready) begin n_mar++; m_ar_cyc = cyc; m_r_first = 1; end
        if (m_rvalid && m_rready && m_r_first) begin m_r_cyc = cyc; m_r_first = 0; end
        if (m_awvalid && m_awready) n_maw++;
        if (ev_read) n_read++;
        if (ev_miss) n_miss++;
    end

    function automatic logic [AW-1:0] line_addr(input int line);
        return BASE + AW'(line) * 64;
    endfunction

    task automatic fail(input string what);
        errors++;
        if (errors <= 20) $display("[%0t] tb_L2: ERROR %s", $time, what);
    endtask

    task automatic check(input bit ok, input string what);
        checks++;
        if (!ok) fail(what);
    endtask

    int seed;
    function automatic int rnd(input int n);              // 0 .. n-1
        return $urandom() % n;
    endfunction

    //-----------------------------------------------------------------
    // the read channel (AR / R): bursts inside a line, from any number of
    // threads. AR is taken by one thread at a time; the reads AR has taken
    // wait in q_* in that order, and one monitor takes the R beats (the L2
    // answers in order) and checks them against the oldest.
    //-----------------------------------------------------------------
    bit          ar_busy = 0;
    int          q_line[$], q_word[$], q_len[$];
    logic [IW-1:0] q_id[$];
    int          ar_seq = 0, rd_done = 0, r_got = 0;
    bit          r_rand = 0;                          // random RREADY

    always @(negedge clk) s_rready <= r_rand ? (rnd(4) != 0) : 1'b1;

    always @(posedge clk) begin
        if (s_rvalid && s_rready) begin
            if (q_line.size() == 0) begin
                fail("an R beat with no read outstanding");
            end else begin
                int line = q_line[0], word = q_word[0], len = q_len[0];
                check(s_rid == q_id[0], $sformatf("rid %0d, expected %0d", s_rid, q_id[0]));
                check(s_rresp == 2'b00, "rresp");
                check(s_rdata == ref_mem[line * 8 + word + r_got],
                      $sformatf("line %0d word %0d: %016h, expected %016h", line, word + r_got,
                                s_rdata, ref_mem[line * 8 + word + r_got]));
                check(s_rlast == (r_got == len), $sformatf("rlast at beat %0d of %0d", r_got, len));
                if (r_got == 0) rd_first_cyc = cyc;
                rd_last_cyc = cyc;
                r_got++;
                if (r_got > len) begin
                    void'(q_line.pop_front()); void'(q_word.pop_front());
                    void'(q_len.pop_front());  void'(q_id.pop_front());
                    r_got = 0;
                    rd_done++;
                end
            end
        end
    end

    task automatic do_read(input int line, input int word, input int len, input logic [IW-1:0] id);
        int seq;
        while (ar_busy) @(negedge clk);
        ar_busy = 1;
        @(negedge clk);
        s_arid    = id;
        s_araddr  = line_addr(line) + AW'(word * 8);
        s_arlen   = 8'(len);
        s_arvalid = 1'b1;
        do @(posedge clk); while (!s_arready);
        seq = ar_seq++;
        q_line.push_back(line); q_word.push_back(word);
        q_len.push_back(len);   q_id.push_back(id);
        rd_ar_cyc = cyc;
        @(negedge clk);
        s_arvalid = 1'b0;
        ar_busy   = 0;
        while (rd_done <= seq) @(posedge clk);
    endtask

    //-----------------------------------------------------------------
    // the write channels (AW / W / B): a line write or a part write
    //-----------------------------------------------------------------
    task automatic do_write(input int line, input bit whole, input int word,
                            input logic [7:0] strb_in, input logic [IW-1:0] id,
                            input bit rand_timing);
        logic [63:0] data [0:7];
        logic [7:0]  strb;
        int n   = whole ? 8 : 1;
        int put = 0;
        bit aw_done = 0;
        for (int i = 0; i < 8; i++) data[i] = {$urandom(), $urandom()};
        strb = whole ? 8'hff : strb_in;
        @(negedge clk);
        s_awid    = id;
        s_awaddr  = line_addr(line) + AW'(whole ? 0 : word * 8);
        s_awlen   = 8'(n - 1);
        s_awvalid = 1'b1;
        // W may come with AW, or later
        while (put < n || !aw_done) begin
            if (put < n) begin
                s_wvalid = rand_timing ? (rnd(4) != 0) : 1'b1;
                s_wdata  = data[put];
                s_wstrb  = strb;
                s_wlast  = (put == n - 1);
            end else begin
                s_wvalid = 1'b0;
            end
            @(posedge clk);
            if (s_awvalid && s_awready) aw_done = 1;
            if (s_wvalid && s_wready) put++;
            @(negedge clk);
            if (aw_done) s_awvalid = 1'b0;
        end
        s_wvalid = 1'b0;
        s_wlast  = 1'b0;
        // B
        forever begin
            s_bready = rand_timing ? (rnd(3) != 0) : 1'b1;
            @(posedge clk);
            if (s_bvalid && s_bready) break;
            @(negedge clk);
        end
        wr_b_cyc = cyc;
        check(s_bid == id, $sformatf("bid %0d, expected %0d", s_bid, id));
        check(s_bresp == 2'b00, "bresp");
        @(negedge clk);
        s_bready = 1'b0;
        // the reference, now that the write is done
        for (int i = 0; i < n; i++) begin
            int w = line * 8 + (whole ? i : word);
            for (int b = 0; b < 8; b++)
                if (strb[b]) ref_mem[w][8*b +: 8] = data[i][8*b +: 8];
        end
        // a part write is written through: the bytes are in memory now
        if (!whole) begin
            int w = line * 8 + word;
            for (int b = 0; b < 8; b++)
                if (strb[b])
                    check(u_mem.mem[w][8*b +: 8] == data[0][8*b +: 8],
                          $sformatf("part write of line %0d word %0d byte %0d not in memory",
                                    line, word, b));
        end
    endtask

    //-----------------------------------------------------------------
    // random traffic
    //-----------------------------------------------------------------
    int hot_base;
    localparam int HOT = (L2_SIZE / 64 / 4 < 256) ? L2_SIZE / 64 / 4 : 256;
    // a line: hot (a window smaller than the L2), in a few sets (evictions),
    // or anywhere
    function automatic int pick_line();
        int k = rnd(8);
        if (k < 4) return (hot_base + rnd(HOT)) % LINES;
        if (k < 6) return (rnd(4) + SETS * rnd(LINES / SETS)) % LINES;
        return rnd(LINES);
    endfunction

    task automatic lock_line(output int line);
        do line = pick_line(); while (busy[line]);
        busy[line] = 1;
    endtask

    int ops;

    task automatic reader(input int n, input logic [IW-1:0] id);
        for (int i = 0; i < n; i++) begin
            int line, word, len;
            lock_line(line);
            if (rnd(4) == 0) begin word = rnd(8); len = rnd(8 - word); end
            else begin word = 0; len = 7; end
            do_read(line, word, len, id);
            busy[line] = 0;
            if (rnd(256) == 0) hot_base = rnd(LINES);
        end
    endtask

    task automatic writer(input int n);
        for (int i = 0; i < n; i++) begin
            int line;
            lock_line(line);
            if (rnd(4) == 0) do_write(line, 0, rnd(8), 8'(1 + rnd(255)), IW'(1), 1);
            else             do_write(line, 1, 0, 8'hff, IW'(4), 1);
            busy[line] = 0;
        end
    endtask

    // nothing in flight inside the L2 any more (its write out included)
    task automatic wait_idle();
        repeat (2) @(posedge clk);
        while ((int'(u_dut.st) != ST_IDLE) || u_dut.eb_valid || s_rvalid || (q_line.size() != 0))
            @(posedge clk);
        repeat (2) @(posedge clk);
    endtask

    // every way of the set dirty, then a miss in it with the memory's AW
    // (hold_w = 0) or W (hold_w = 1) held: one dirty line waits in the evict
    // buffer, or in its write out. Then, released after 40 cycles:
    //   mode 0  a read of that line          must wait for the write out
    //   mode 1  a part write to that line    must wait (memory in order)
    //           (in both, the victim is a clean line)
    //   mode 2  a line write that misses in the set: its victim is dirty
    //           (pseudo LRU) and the buffer is full, so it must wait
    task automatic held_eviction(input int set, input int mode, input bit hold_w);
        int     ev;
        longint rel = 0;
        for (int k = 0; k < L2_WAYS; k++) do_write(set + k * SETS, 1, 0, 8'hff, 4, 0);
        wait_idle();
        if (hold_w) u_mem.w_hold  = 1'b1;
        else        u_mem.aw_hold = 1'b1;
        do_read(set + L2_WAYS * SETS, 0, 7, 2);
        check(u_dut.eb_valid, "held eviction: a line in the evict buffer");
        ev = int'((u_dut.eb_addr - BASE) / 64);
        // modes 0 and 1: the dirty lines read again (hits), so that the
        // victim of what follows is the clean line just filled. The wait must
        // come from the evict buffer, not from a dirty victim
        if (mode != 2)
            for (int k = 0; k < L2_WAYS; k++)
                if (set + k * SETS != ev) do_read(set + k * SETS, 0, 7, 2);
        fork
            case (mode)
                0:       do_read(ev, 0, 7, 3);
                1:       do_write(ev, 0, 2, 8'hf0, 1, 0);
                default: do_write(set + (L2_WAYS + 1) * SETS, 1, 0, 8'hff, 4, 0);
            endcase
            begin
                repeat (40) @(posedge clk);
                rel = cyc;
                u_mem.aw_hold = 1'b0;
                u_mem.w_hold  = 1'b0;
            end
        join
        case (mode)
            0: check(rd_first_cyc > rel, "held eviction: a read did not wait for the write out");
            1: check(wr_b_cyc > rel, "held eviction: a part write did not wait for the write out");
            default:
                if (!L2_RANDOM && L2_WAYS > 1)
                    check(wr_b_cyc > rel, "held eviction: a line write did not wait for the buffer");
        endcase
        wait_idle();
        do_read(ev, 0, 7, 3);
        if (mode == 2) do_read(set + (L2_WAYS + 1) * SETS, 0, 7, 3);
    endtask

    // every line, upwards or downwards
    task automatic read_all(input string what, input bit down);
        int e0 = errors;
        for (int i = 0; i < LINES; i++) do_read(down ? LINES - 1 - i : i, 0, 7, IW'(3));
        $display("tb_L2: %s: %0d lines read back, %0d errors", what, LINES, errors - e0);
    endtask

    //-----------------------------------------------------------------
    // the run
    //-----------------------------------------------------------------
    int r0, a0, w0, m0;
    int lA, lB;

    initial begin
        if (!$value$plusargs("ops=%d", ops)) ops = 4000;
        if ($value$plusargs("seed=%d", seed)) void'($urandom(seed));
        s_awvalid = 0; s_wvalid = 0; s_wlast = 0; s_bready = 0;
        s_arvalid = 0;
        s_awid = 0; s_awaddr = 0; s_awlen = 0; s_wdata = 0; s_wstrb = 0;
        s_arid = 0; s_araddr = 0; s_arlen = 0;
        for (int i = 0; i < LINES; i++) busy[i] = 0;
        u_mem.stall_en = 1'b0;
        u_mem.aw_hold  = 1'b0;
        u_mem.w_hold   = 1'b0;
        #1;
        for (int i = 0; i < WORDS; i++) ref_mem[i] = u_mem.mem[i];
        $display("tb_L2: L2 %0d KB, %0d ways, %0d sets, %s; memory %0d lines",
                 L2_SIZE / 1024, L2_WAYS, SETS, L2_RANDOM ? "random" : "pseudo LRU", LINES);

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        // the walk that clears the tags
        while (int'(u_dut.st) == ST_INIT) @(posedge clk);

        //-------------------------------------------------------------
        // 1 directed
        //-------------------------------------------------------------
        lA = 5;
        lB = 5 + SETS;                                   // the same set as lA
        // a read miss, then a hit
        a0 = n_mar; r0 = n_read; m0 = n_miss;
        do_read(lA, 0, 7, 2);
        wait_idle();
        check(n_mar == a0 + 1 && n_read == r0 + 1 && n_miss == m0 + 1, "read miss: one fill");
        $display("tb_L2: read miss: first beat %0d cycles after AR, of which the memory %0d (AR to R); 8 beats in %0d cycles",
                 rd_first_cyc - rd_ar_cyc, m_r_cyc - m_ar_cyc, rd_last_cyc - rd_first_cyc + 1);
        a0 = n_mar;
        do_read(lA, 0, 7, 3);
        wait_idle();
        check(n_mar == a0 && n_read == r0 + 2 && n_miss == m0 + 1, "read hit: no fill");
        // a hit: the first beat 2 cycles after AR, then one beat a cycle
        check(rd_first_cyc - rd_ar_cyc == 2 && rd_last_cyc - rd_first_cyc == 7,
              $sformatf("read hit timing: first beat +%0d, 8 beats in %0d cycles",
                        rd_first_cyc - rd_ar_cyc, rd_last_cyc - rd_first_cyc + 1));
        // back to back hits: the next AR is taken once the last beat is out
        do_read(lA, 0, 7, 3);
        check(rd_first_cyc - rd_ar_cyc == 2 && rd_last_cyc - rd_first_cyc == 7,
              "read hit timing, second hit");
        // a line write that misses: allocated without reading memory
        a0 = n_mar; w0 = n_maw;
        do_write(lB, 1, 0, 8'hff, 4, 0);
        wait_idle();
        check(n_mar == a0 && n_maw == w0, "line write miss: no memory access");
        do_read(lB, 0, 7, 2);
        wait_idle();
        check(n_mar == a0, "line written: a hit");
        // WAYS + 1 dirty lines in the set of lB: one write out
        w0 = n_maw;
        for (int k = 2; k <= L2_WAYS + 1; k++) begin
            do_write(lA + k * SETS, 1, 0, 8'hff, 4, 0);
            wait_idle();
        end
        check(n_maw >= w0 + 1, $sformatf("dirty eviction: %0d write outs", n_maw - w0));
        begin
            int in_mem = 0;
            for (int k = 1; k <= L2_WAYS + 1; k++) begin
                bit same = 1;
                for (int i = 0; i < 8; i++)
                    if (u_mem.mem[(lA + k * SETS) * 8 + i] != ref_mem[(lA + k * SETS) * 8 + i])
                        same = 0;
                in_mem += same;
            end
            check(in_mem >= 1, "the evicted dirty line is in memory");
        end
        // a part write to a dirty line: memory has the bytes, the line merges
        do_write(lB, 0, 3, 8'b0011_1100, 1, 0);
        wait_idle();
        do_read(lB, 0, 7, 2);
        // short reads, hit and miss
        do_read(lA, 5, 0, 3);
        do_read(lA, 2, 3, 3);
        do_read(lA + 1, 6, 1, 2);
        // a part write to a line that is not in the L2: memory only
        a0 = n_mar;
        do_write(lA + 11, 0, 7, 8'h80, 1, 0);
        wait_idle();
        check(n_mar == a0, "part write miss: not allocated");
        // replacement: a set filled in order gives up way 0 first (pseudo
        // LRU), and a clean victim is not written to memory
        begin
            int p = SETS - 1;
            for (int k = 0; k < L2_WAYS; k++) do_read(p + k * SETS, 0, 7, 2);
            wait_idle();
            a0 = n_mar; w0 = n_maw;
            do_read(p + L2_WAYS * SETS, 0, 7, 2);
            wait_idle();
            check(n_mar == a0 + 1 && n_maw == w0, "clean victim: no write out");
            if (!L2_RANDOM && L2_WAYS > 1) begin
                a0 = n_mar;
                for (int k = 1; k < L2_WAYS; k++) do_read(p + k * SETS, 0, 7, 2);
                wait_idle();
                check(n_mar == a0, "pseudo LRU: the lines read after the first stay");
                do_read(p, 0, 7, 2);
                wait_idle();
                check(n_mar == a0 + 1, "pseudo LRU: the first line read is the victim");
            end
        end
        // a dirty victim held in the evict buffer (memory AWREADY held low):
        // a read of that line, and then a part write to it, wait for its
        // write out
        held_eviction(SETS - 2, 0, 0);
        held_eviction(SETS - 3, 1, 0);
        held_eviction(SETS - 4, 2, 0);
        held_eviction(SETS - 5, 0, 1);
        held_eviction(SETS - 6, 1, 1);
        held_eviction(SETS - 7, 2, 1);
        $display("tb_L2: 1 directed: %0d checks, %0d errors", checks, errors);

        //-------------------------------------------------------------
        // 2 / 3 random, without and with memory stalls
        //-------------------------------------------------------------
        hot_base = 0;
        r_rand = 1;
        fork
            reader(ops, 2);
            reader(ops, 3);
            writer(ops);
        join
        r_rand = 0;
        wait_idle();
        $display("tb_L2: 2 random: %0d reads, %0d misses, %0d fills, %0d writes to memory, %0d errors",
                 n_read, n_miss, n_mar, n_maw, errors);
        u_mem.stall_en = 1'b1;
        r_rand = 1;
        fork
            reader(ops, 2);
            reader(ops, 3);
            writer(ops);
        join
        r_rand = 0;
        wait_idle();
        u_mem.stall_en = 1'b0;
        $display("tb_L2: 3 random with memory stalls: %0d errors", errors);

        //-------------------------------------------------------------
        // 4 everything read back
        //-------------------------------------------------------------
        read_all("4 read back", 0);

        //-------------------------------------------------------------
        // 5 reset: the L2 must forget everything
        //-------------------------------------------------------------
        wait_idle();
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        for (int i = 0; i < WORDS; i++) begin
            u_mem.mem[i] = {32'h5eed_0000 | 32'(i), $urandom()};
            ref_mem[i]   = u_mem.mem[i];
        end
        rst_n = 1'b1;
        read_all("5 after reset", 1);

        check(u_mem.protocol_err == 0, $sformatf("memory side AXI protocol errors: %0d",
                                                 u_mem.protocol_err));
        $display("");
        $display(" L2 RESULT : %s   (%0d checks, %0d errors, %0d reads, %0d misses)",
                 (errors == 0) ? "PASS" : "FAIL", checks, errors, n_read, n_miss);
        $finish;
    end

    // watchdog
    initial begin
        int lim;
        if (!$value$plusargs("maxcycles=%d", lim)) lim = 20_000_000;
        repeat (lim) @(posedge clk);
        $display(" L2 RESULT : FAIL   (watchdog after %0d cycles, %0d errors)", lim, errors);
        $finish;
    end

endmodule : tb_L2
