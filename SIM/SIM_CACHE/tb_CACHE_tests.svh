//---------------------------------------------------------------------------
// tb_CACHE_tests.svh : test sequence of tb_CACHE (included inside tb_CACHE)
//
//    1. D$ basic : miss, hit, word read / write
//    2. D$ byte lanes : 1/2/4/8 byte accesses at every offset
//    3. D$ replacement and dirty writeback
//    4. AMO (all operations, 32 / 64 bit, signed boundaries)
//    5. LR / SC
//    6. FENCE / FLUSH / fence.i (I$ invalidate)
//    7. Uncached region (peripheral bus), AMO/LR/SC rejected there
//    8. Bus errors (DECERR through the address bridge)
//    9. MSHR : overlapping misses, secondary miss to the same line
//   10. I$ basic and mixed I$ / D$ traffic
//   11. Random stress against the reference model
//   12. Final FLUSH and full memory image check
//   13. Write through, no allocate (CMD_STWTHR, used by the debug port)
//   14. Debug port : the second port of the data cache (CACHE_PORT_ARB)
//
//   Plusargs: +from=<n> +to=<n> run only sections n..m
//             +perf[=<n>]        run the throughput patterns afterwards
//                                (tb_CACHE_perf.svh)
//---------------------------------------------------------------------------

    int from_sec, to_sec;
    int e0;

    // address helpers (cacheable window)
    function automatic logic [PADDR_WIDTH-1:0] a_mem(input int word_index);
        return MEM_BASE + PADDR_WIDTH'(8 * word_index);
    endfunction
    function automatic logic [PADDR_WIDTH-1:0] a_peri(input int word_index);
        return PERI_BASE + PADDR_WIDTH'(8 * word_index);
    endfunction
    // word index of the first word of set `set`, way iteration `n`
    function automatic int set_word(input int set, input int n);
        return (n * DC_SETS * DC_BLOCK + set * DC_BLOCK) / 8;
    endfunction

    initial begin : main
        $display("==========================================================");
        $display(" tb_CACHE : mmRISC-2 L1 cache verification");
        $display("   I$ %0d sets x %0d ways x %0dB, D$ %0d sets x %0d ways x %0dB,",
                 IC_SETS, IC_WAYS, IC_BLOCK, DC_SETS, DC_WAYS, DC_BLOCK);
        $display("   MSHR=%0d WB=%0d replace=%s",
                 NUM_MSHR, NUM_WB, REPLACE_RANDOM ? "random" : "pseudo-LRU");
        $display("==========================================================");

        i_req_valid   = 1'b0;
        i_req_addr    = '0;
        i_flush_valid = 1'b0;
        i_kill        = 1'b0;
        d_req_valid   = 1'b0;
        d_req_addr    = '0;
        d_req_size    = 2'd3;
        d_req_cmd     = CMD_LOAD;
        d_req_wdata   = '0;
        dbg_req_valid = 1'b0;
        dbg_req_addr  = '0;
        dbg_req_size  = 2'd3;
        dbg_req_cmd   = CMD_LOAD;
        dbg_req_wdata = '0;
        ref_init();

        if (!$value$plusargs("from=%d", from_sec)) from_sec = 1;
        if (!$value$plusargs("to=%d", to_sec))     to_sec   = 99;

        wait (rst_n === 1'b1);
        repeat (4) @(posedge clk);

        //=============================================================
        section("1. D$ basic : miss / hit / write");
        //=============================================================
        if (from_sec <= 1 && 1 <= to_sec) begin
            e0 = n_error;
            // cold miss, then hits in the same line
            d_load("load word 0 (cold miss)", a_mem(0), 2'd3);
            for (int i = 1; i < DC_BLOCK/8; i++)
                d_load($sformatf("load word %0d (hit in same line)", i), a_mem(i), 2'd3);
            d_drain();
            // write then read back
            d_store("store word 2", a_mem(2), 2'd3, 64'hA5A5_5A5A_1234_5678);
            d_load ("read back word 2", a_mem(2), 2'd3);
            // write to a fresh line (write allocate)
            d_store("store to a new line", a_mem(DC_BLOCK/8 + 1), 2'd3, 64'hDEAD_BEEF_CAFE_0001);
            d_load ("read back new line", a_mem(DC_BLOCK/8 + 1), 2'd3);
            d_drain();
            if (n_error == e0) ok("miss, hit, write allocate, read back");
        end

        //=============================================================
        section("2. D$ byte lanes : 1/2/4/8 byte at every offset");
        //=============================================================
        if (from_sec <= 2 && 2 <= to_sec) begin
            logic [63:0] v;
            e0 = n_error;
            for (int size = 0; size <= 3; size++) begin
                for (int off = 0; off < 8; off += (1 << size)) begin
                    logic [PADDR_WIDTH-1:0] a;
                    a = a_mem(100 + size) + PADDR_WIDTH'(off);
                    v = {$urandom, $urandom};
                    d_store($sformatf("store size%0d off%0d", size, off), a, 2'(size), v);
                    d_load ($sformatf("load  size%0d off%0d", size, off), a, 2'(size));
                end
            end
            d_drain();
            // whole word read back : lanes must not disturb each other
            for (int size = 0; size <= 3; size++)
                d_load($sformatf("word read after size%0d stores", size), a_mem(100 + size), 2'd3);
            d_drain();
            if (n_error == e0) ok("byte / half / word / double accesses on all lanes");
        end

        //=============================================================
        section("3. D$ replacement and dirty writeback");
        //=============================================================
        if (from_sec <= 3 && 3 <= to_sec) begin
            e0 = n_error;
            // dirty up every way of set 3, then push them out with more lines
            for (int n = 0; n < DC_WAYS; n++)
                d_store($sformatf("dirty way %0d of set 3", n),
                        a_mem(set_word(3, n)), 2'd3, 64'h1000_0000_0000_0000 + 64'(n));
            d_drain();
            for (int n = DC_WAYS; n < DC_WAYS * 2; n++)
                d_store($sformatf("evict with line %0d of set 3", n),
                        a_mem(set_word(3, n)), 2'd3, 64'h2000_0000_0000_0000 + 64'(n));
            d_drain();
            // the evicted lines must have reached memory
            for (int n = 0; n < DC_WAYS; n++)
                d_load($sformatf("re-read evicted line %0d", n), a_mem(set_word(3, n)), 2'd3);
            d_drain();
            d_flush("flush after replacement");
            d_drain();
            check_memory("memory image after replacement");
            // one dirty line in every set, including the last one the flush
            // walk visits : the FLUSH must not answer before that writeback
            // has reached memory
            // the modified word is the last one of the block, so it travels in
            // the last beat of the writeback burst
            for (int s = 0; s < DC_SETS; s++)
                d_store($sformatf("dirty set %0d", s),
                        a_mem(set_word(s, 0) + DC_BLOCK/8 - 1), 2'd3,
                        64'h3000_0000_0000_0000 + 64'(s));
            d_drain();
            d_flush("flush every dirty line");
            d_drain();
            check_memory("memory image immediately after the flush");
            if (n_error == e0) ok("replacement, dirty writeback, re-fill");
        end

        //=============================================================
        section("4. AMO");
        //=============================================================
        if (from_sec <= 4 && 4 <= to_sec) begin
            e0 = n_error;
            for (int size = 2; size <= 3; size++) begin
                for (int c = 4; c <= 12; c++) begin
                    logic [PADDR_WIDTH-1:0] a;
                    a = a_mem(200 + c) + ((size == 2) ? PADDR_WIDTH'(4) : PADDR_WIDTH'(0));
                    d_store($sformatf("amo init cmd%0d size%0d", c, size), a, 2'(size),
                            64'h0000_0000_8000_0000);
                    d_push($sformatf("amo cmd%0d size%0d", c, size), 4'(c), a, 2'(size),
                           64'h0000_0000_7FFF_FFFF);
                    d_load($sformatf("amo result cmd%0d size%0d", c, size), a, 2'(size));
                end
            end
            d_drain();
            // signed / unsigned boundaries for min/max
            for (int c = 9; c <= 12; c++) begin
                d_store("amo bound init", a_mem(240 + c), 2'd3, 64'hFFFF_FFFF_FFFF_FFFF);
                d_push ($sformatf("amo bound cmd%0d", c), 4'(c), a_mem(240 + c), 2'd3, 64'd1);
                d_load ($sformatf("amo bound result cmd%0d", c), a_mem(240 + c), 2'd3);
            end
            d_drain();
            if (n_error == e0) ok("AMO swap/add/xor/and/or/min/max/minu/maxu, 32 and 64 bit");
        end

        //=============================================================
        section("5. LR / SC");
        //=============================================================
        if (from_sec <= 5 && 5 <= to_sec) begin
            e0 = n_error;
            // success : LR immediately followed by SC on the same address
            d_push("LR (success case)", CMD_LR, a_mem(300), 2'd3, 64'd0);
            d_drain();
            d_push("SC (must succeed)", CMD_SC, a_mem(300), 2'd3, 64'h1111_2222_3333_4444);
            d_drain();
            check64("SC succeeded (data 0)", 64'd0, d_resp_data);
            d_load("value written by SC", a_mem(300), 2'd3);
            d_drain();
            // failure : SC without LR
            d_push("SC without LR (must fail)", CMD_SC, a_mem(301), 2'd3, 64'hDEAD_DEAD_DEAD_DEAD);
            d_drain();
            check64("SC failed (data 1)", 64'd1, d_resp_data);
            d_load("SC failure leaves memory unchanged", a_mem(301), 2'd3);
            // failure : SC to a different line than LR
            d_push("LR for other-line test", CMD_LR, a_mem(302), 2'd3, 64'd0);
            d_drain();
            d_push("SC to another line (must fail)", CMD_SC, a_mem(302 + DC_BLOCK/8), 2'd3,
                   64'hBAAD_BAAD_BAAD_BAAD);
            d_drain();
            check64("SC to another line failed", 64'd1, d_resp_data);
            // failure : store to the reserved line cancels the reservation
            d_push ("LR before intervening store", CMD_LR, a_mem(304), 2'd3, 64'd0);
            d_store("intervening store to the same line", a_mem(304), 2'd3, 64'h5555_5555_5555_5555);
            d_drain();
            d_push("SC after intervening store (must fail)", CMD_SC, a_mem(304), 2'd3, 64'd0);
            d_drain();
            check64("SC after store failed", 64'd1, d_resp_data);
            // failure : FLUSH clears the reservation
            d_push ("LR before flush", CMD_LR, a_mem(306), 2'd3, 64'd0);
            d_drain();
            d_flush("flush clears reservation");
            d_drain();
            d_push("SC after flush (must fail)", CMD_SC, a_mem(306), 2'd3, 64'd0);
            d_drain();
            check64("SC after flush failed", 64'd1, d_resp_data);
            d_load("memory not written by failed SC", a_mem(306), 2'd3);
            d_drain();
            if (n_error == e0) ok("LR/SC success and failure cases");
        end

        //=============================================================
        section("6. FENCE / FLUSH / fence.i");
        //=============================================================
        if (from_sec <= 6 && 6 <= to_sec) begin
            e0 = n_error;
            d_store("store before fence", a_mem(400), 2'd3, 64'h0F0F_0F0F_0F0F_0F0F);
            d_fence("fence");
            d_drain();
            d_store("store before flush", a_mem(401), 2'd3, 64'hF0F0_F0F0_F0F0_F0F0);
            d_flush("flush writes dirty lines back");
            d_drain();
            check_memory("memory image after flush");
            d_load("load after flush (refill)", a_mem(401), 2'd3);
            d_drain();
            // fence.i : the instruction cache must see a new value
            i_push("fetch before self-modifying store", a_mem(410));
            i_drain();
            d_store("store new instruction word", a_mem(410), 2'd3, 64'h0000_0000_1234_5678);
            d_flush("write it back to memory");
            d_drain();
            i_flush_all();
            i_push("fetch after fence.i", a_mem(410));
            i_drain();
            // fence.i while a fill is in progress : the line brought in by that
            // fill must not become valid, so the next fetch has to go to memory
            d_store("store word 420 (old)", a_mem(420), 2'd3, 64'h0000_0000_AAAA_AAAA);
            d_flush("write word 420 back");
            d_drain();
            i_flush_all();                        // the next fetch of 420 misses
            i_push("fetch that starts a fill", a_mem(420));
            repeat (5) @(posedge clk);            // the fill is under way
            i_flush_start();                      // fence.i during the fill
            i_drain();                            // the fetch still returns the old word
            i_flush_wait();
            d_store("store word 420 (new)", a_mem(420), 2'd3, 64'h0000_0000_BBBB_BBBB);
            d_flush("write word 420 back");
            d_drain();
            i_push("fetch after fence.i during a fill", a_mem(420));
            i_drain();
            // same, but fence.i is released again before the fill ends: the
            // line must still not become valid (fill_flushed)
            d_store("store word 430 (old)", a_mem(430), 2'd3, 64'h0000_0000_CCCC_CCCC);
            d_flush("write word 430 back");
            d_drain();
            i_flush_all();                        // the next fetch of 430 misses
            i_push("fetch that starts a fill (pulse)", a_mem(430));
            i_wait_fill();                        // first beat of the fill
            i_flush_pulse(2);                     // fence.i, released early
            i_drain();
            d_store("store word 430 (new)", a_mem(430), 2'd3, 64'h0000_0000_DDDD_DDDD);
            d_flush("write word 430 back");
            d_drain();
            i_push("fetch after a fence.i pulse during a fill", a_mem(430));
            i_drain();
            if (n_error == e0) ok("FENCE, FLUSH, fence.i");
        end

        //=============================================================
        section("7. Uncached region (peripheral bus)");
        //=============================================================
        if (from_sec <= 7 && 7 <= to_sec) begin
            e0 = n_error;
            d_load ("uncached load", a_peri(0), 2'd3);
            d_store("uncached store", a_peri(1), 2'd3, 64'hCAFE_0000_0000_BABE);
            d_load ("uncached read back", a_peri(1), 2'd3);
            d_store("uncached byte store", a_peri(2) + 40'd3, 2'd0, 64'h00000000000000AA);
            d_load ("uncached byte read", a_peri(2) + 40'd3, 2'd0);
            d_load ("uncached word read", a_peri(2), 2'd3);
            d_drain();
            // the uncached window must not be cached : write through the bus,
            // then read it again
            u_peri.mem[4] = 64'h9999_8888_7777_6666;
            ref_peri[4]   = 64'h9999_8888_7777_6666;
            d_load("uncached load sees the new value", a_peri(4), 2'd3);
            d_drain();
            // atomics are not supported there
            d_push("AMO on uncached (error)", CMD_AMOADD, a_peri(5), 2'd3, 64'd1);
            d_push("LR on uncached (error)",  CMD_LR,     a_peri(5), 2'd3, 64'd0);
            d_push("SC on uncached (error)",  CMD_SC,     a_peri(5), 2'd3, 64'd0);
            d_drain();
            // instruction fetch from the uncached window (LiteX boot ROM case)
            i_push("uncached instruction fetch", a_peri(8));
            i_push("uncached instruction fetch again", a_peri(8));
            i_drain();
            if (n_error == e0) ok("uncached load/store, no caching, atomics rejected, fetch");
        end

        //=============================================================
        section("8. Bus errors");
        //=============================================================
        if (from_sec <= 8 && 8 <= to_sec) begin
            logic [PADDR_WIDTH-1:0] bad;
            e0 = n_error;
            bad = 40'h01_8000_0000;                    // upper bits set -> DECERR
            d_push_err("load from unmapped address", CMD_LOAD, bad, 2'd3, 64'd0);
            d_drain();
            d_push_err("store to unmapped address", CMD_STORE, bad + 40'd8, 2'd3, 64'd1);
            d_drain();
            i_push_err("fetch from unmapped address", bad + 40'd16);
            i_drain();
            // the cache must still work afterwards
            d_load("load after bus error", a_mem(0), 2'd3);
            i_push("fetch after bus error", a_mem(0));
            d_drain();
            i_drain();
            if (n_error == e0) ok("DECERR on load / store / fetch, recovery");
        end

        //=============================================================
        section("9. MSHR : overlapping misses");
        //=============================================================
        if (from_sec <= 9 && 9 <= to_sec) begin
            e0 = n_error;
            // misses to different lines, issued back to back
            for (int n = 0; n < 8; n++)
                d_load($sformatf("overlapping miss %0d", n), a_mem(set_word(10 + n, 0)), 2'd3);
            d_drain();
            // secondary misses to the same line (must merge into one fill)
            d_flush("flush before secondary miss test");
            d_drain();
            for (int i = 0; i < DC_BLOCK/8; i++)
                d_load($sformatf("secondary miss word %0d", i), a_mem(set_word(20, 0) + i), 2'd3);
            d_drain();
            // mixed loads and stores to the same line while a fill is running
            d_flush("flush before mixed test");
            d_drain();
            d_load ("miss then store to same line", a_mem(set_word(21, 0)), 2'd3);
            d_store("store during fill", a_mem(set_word(21, 0) + 1), 2'd3, 64'h1234_5678_9ABC_DEF0);
            d_load ("load during fill", a_mem(set_word(21, 0) + 2), 2'd3);
            d_load ("read back store during fill", a_mem(set_word(21, 0) + 1), 2'd3);
            d_drain();
            if (n_error == e0) ok("overlapping misses, secondary miss merging");
        end

        //=============================================================
        section("10. I$ basic and mixed traffic");
        //=============================================================
        if (from_sec <= 10 && 10 <= to_sec) begin
            e0 = n_error;
            // sequential fetch through several lines
            for (int i = 0; i < 4 * IC_BLOCK/8; i++)
                i_push($sformatf("sequential fetch %0d", i), a_mem(500 + i));
            i_drain();
            // re-fetch : all hits
            for (int i = 0; i < IC_BLOCK/8; i++)
                i_push($sformatf("re-fetch %0d", i), a_mem(500 + i));
            i_drain();
            // fetch and data access in parallel
            fork
                begin
                    for (int i = 0; i < 32; i++)
                        i_push($sformatf("mixed fetch %0d", i), a_mem(600 + i));
                    i_drain();
                end
                begin
                    for (int i = 0; i < 32; i++) begin
                        d_store($sformatf("mixed store %0d", i), a_mem(700 + i), 2'd3,
                                64'h3000_0000_0000_0000 + 64'(i));
                        d_load ($sformatf("mixed load %0d", i), a_mem(700 + i), 2'd3);
                    end
                    d_drain();
                end
            join
            // I$ replacement
            for (int n = 0; n < IC_WAYS + 2; n++)
                i_push($sformatf("I$ replacement %0d", n),
                       a_mem((n * IC_SETS * IC_BLOCK + 5 * IC_BLOCK) / 8));
            i_drain();
            if (n_error == e0) ok("instruction fetch, hits, replacement, mixed with data");
        end

        //=============================================================
        section("11. Random stress against the reference model");
        //=============================================================
        if (from_sec <= 11 && 11 <= to_sec) begin
            int n_ops;
            e0 = n_error;
            if (!$value$plusargs("ops=%d", n_ops)) n_ops = 4000;
            for (int i = 0; i < n_ops; i++) begin
                int r, sz, widx;
                logic [PADDR_WIDTH-1:0] a;
                r    = $urandom_range(0, 99);
                sz   = $urandom_range(0, 3);
                widx = $urandom_range(0, 255);
                a    = a_mem(widx) + PADDR_WIDTH'($urandom_range(0, 7) & ~((1 << sz) - 1));
                if (r < 35) begin
                    d_load($sformatf("random load @%010h sz%0d", a, sz), a, 2'(sz));
                end else if (r < 65) begin
                    d_store($sformatf("random store @%010h sz%0d", a, sz), a, 2'(sz), {$urandom, $urandom});
                end else if (r < 72) begin
                    // aligned atomics only
                    a = a_mem(widx);
                    d_push($sformatf("random AMO @%010h", a), 4'($urandom_range(4, 12)), a, 2'd3, {$urandom, $urandom});
                end else if (r < 76) begin
                    a = a_mem(widx);
                    d_push($sformatf("random LR @%010h", a), CMD_LR, a, 2'd3, 64'd0);
                end else if (r < 80) begin
                    a = a_mem(widx);
                    d_push($sformatf("random SC @%010h", a), CMD_SC, a, 2'd3, {$urandom, $urandom});
                end else if (r < 84) begin
                    d_load("random uncached load", a_peri($urandom_range(0, 63)), 2'd3);
                end else if (r < 88) begin
                    d_store("random uncached store", a_peri($urandom_range(0, 63)), 2'd3,
                            {$urandom, $urandom});
                end else if (r < 92) begin
                    // fetch from a window the data side never writes: without
                    // fence.i the instruction cache may hold an older copy
                    i_push("random fetch", a_mem($urandom_range(1024, 1279)));
                end else if (r < 96) begin
                    i_push("random fetch (other window)", a_mem($urandom_range(1280, 1535)));
                end else if (r < 98) begin
                    d_fence("random fence");
                end else begin
                    d_drain();
                    i_drain();
                    d_flush("random flush");
                    d_drain();
                end
            end
            d_drain();
            i_drain();
            if (n_error == e0) ok($sformatf("%0d random operations against the reference model", n_ops));
        end

        //=============================================================
        section("12. Final memory image");
        //=============================================================
        if (from_sec <= 12 && 12 <= to_sec) begin
            e0 = n_error;
            d_flush("final flush");
            d_drain();
            check_memory("final memory image");
            if (n_error == e0) ok("memory image matches the reference model");
        end

        //=============================================================
        section("13. Write through (debug port) : CMD_STWTHR");
        //=============================================================
        if (from_sec <= 13 && 13 <= to_sec) begin
            e0 = n_error;
            d_flush("flush before the write through tests");
            d_drain();

            // (a) miss : the word goes to memory, the line is not allocated
            d_stwthr("write through, line not cached", a_mem(900), 2'd3,
                     64'hAAAA_0000_0000_0001);
            d_drain();
            check("write through miss does not allocate", !dc_line_present(a_mem(900)));
            check_memory("memory after a write through miss");
            d_load("read back (fills the line now)", a_mem(900), 2'd3);
            d_fence("wait for the fill to finish");   // the load answers early
            d_drain();
            check("the load allocated the line", dc_line_present(a_mem(900)));

            // (b) hit : the line is updated and memory is written as well
            d_stwthr("write through, line cached", a_mem(900), 2'd3,
                     64'hAAAA_0000_0000_0002);
            d_drain();
            check("the line stays in the cache", dc_line_present(a_mem(900)));
            check_memory("memory after a write through hit");
            d_load("the cached line has the new value", a_mem(900), 2'd3);
            d_drain();

            // (c) hit on a dirty line : the line keeps its own dirty data
            d_store("make the line dirty", a_mem(901), 2'd3, 64'hBBBB_0000_0000_0001);
            d_drain();
            d_stwthr("write through into a dirty line", a_mem(900), 2'd3,
                     64'hAAAA_0000_0000_0003);
            d_drain();
            // the line at 901 is dirty, so only the word written through has
            // reached memory
            check_mem_word("write through into a dirty line", a_mem(900));
            d_load("dirty word still there",     a_mem(901), 2'd3);
            d_load("written through word there", a_mem(900), 2'd3);
            d_flush("flush the dirty line");
            d_drain();
            check_memory("memory after the flush");

            // (d) byte lanes
            for (int sz = 0; sz < 4; sz++)
                for (int off = 0; off < 8; off += (1 << sz))
                    d_stwthr($sformatf("write through size %0d offset %0d", sz, off),
                             a_mem(910) + PADDR_WIDTH'(off), sz[1:0],
                             64'hC0DE_0000_0000_0000 + 64'(off) + 64'(sz) * 16);
            d_drain();
            check_memory("memory after byte lane write throughs");
            for (int i = 0; i < 4; i++)
                d_load($sformatf("read back byte lanes %0d", i), a_mem(910 + i), 2'd3);
            d_drain();

            // (e) while the line is being filled : must wait for the fill
            d_flush("flush before the fill race");
            d_drain();
            d_load("start a fill of the line",  a_mem(920), 2'd3);
            d_stwthr("write through during the fill", a_mem(921), 2'd3,
                     64'hDDDD_0000_0000_0001);
            d_load("read the written word",     a_mem(921), 2'd3);
            d_drain();
            check_memory("memory after the fill race");

            // (f) uncached region : goes to the peripheral bus
            d_stwthr("write through to the peripheral bus", a_peri(20), 2'd3,
                     64'hEEEE_0000_0000_0001);
            d_load("read it back from the peripheral bus", a_peri(20), 2'd3);
            d_drain();

            // (g) bus error
            d_push_err("write through to an unmapped address", CMD_STWTHR,
                       MEM_BASE + 40'h0001_0000_0000, 2'd3, 64'hDEAD);
            d_drain();
            d_load("the cache still works after the error", a_mem(900), 2'd3);
            d_drain();

            if (n_error == e0) ok("write through: miss, hit, dirty line, lanes, fill race");
        end

        //=============================================================
        section("14. Debug port (second cache port)");
        //=============================================================
        if (from_sec <= 14 && 14 <= to_sec) begin
            e0 = n_error;
            d_flush("flush before the debug port tests");
            d_drain();

            // (a) read : first access misses and fills, the next one hits
            dbg_load("debug read (miss)", a_mem(940), 2'd3);
            d_fence("wait for the fill");
            d_drain();
            check("debug read allocated the line", dc_line_present(a_mem(940)));
            dbg_load("debug read (hit)", a_mem(940), 2'd3);

            // (b) write through : memory and the cached line are updated
            dbg_store("debug write (line cached)", a_mem(940), 2'd3, 64'h1234_5678_9ABC_DEF0);
            check_mem_word("debug write (line cached)", a_mem(940));
            dbg_load("debug read after the write", a_mem(940), 2'd3);
            d_load("CPU sees the debug write", a_mem(940), 2'd3);
            d_drain();

            // (c) write to a line that is not cached : no allocation
            dbg_store("debug write (line not cached)", a_mem(960), 2'd3, 64'h0F0F_1111_2222_3333);
            check("debug write did not allocate", !dc_line_present(a_mem(960)));
            check_mem_word("debug write (line not cached)", a_mem(960));
            d_load("CPU reads the written word", a_mem(960), 2'd3);
            d_drain();

            // (d) the CPU has the line dirty : the debug read must see it
            d_store("CPU makes a line dirty", a_mem(970), 2'd3, 64'hCAFE_0000_0000_0001);
            d_drain();
            dbg_load("debug read of a dirty line", a_mem(970), 2'd3);

            // (e) byte lanes through the debug port
            for (int sz = 0; sz < 4; sz++) begin
                dbg_store($sformatf("debug write size %0d", sz),
                          a_mem(980) + PADDR_WIDTH'(1 << sz), sz[1:0],
                          64'h5A5A_0000_0000_0000 + 64'(sz));
                dbg_load($sformatf("debug read size %0d", sz),
                         a_mem(980) + PADDR_WIDTH'(1 << sz), sz[1:0]);
            end

            // (f) uncached region through the debug port
            dbg_store("debug write to the peripheral bus", a_peri(24), 2'd3,
                      64'h9999_8888_7777_6666);
            dbg_load("debug read from the peripheral bus", a_peri(24), 2'd3);

            // (g) bus error
            dbg_exec("debug read of an unmapped address", CMD_LOAD,
                     MEM_BASE + 40'h0001_0000_0000, 2'd3, 64'd0, 64'd0, 1'b1, 1'b0);

            // (h) both ports busy at the same time : the CPU has priority but
            //     the debug access must still get through
            fork
                begin
                    for (int i = 0; i < 64; i++)
                        d_load($sformatf("CPU load during debug traffic %0d", i),
                               a_mem(1000 + i), 2'd3);
                    d_drain();
                end
                begin
                    for (int i = 0; i < 4; i++) begin
                        dbg_load($sformatf("debug read during CPU traffic %0d", i),
                                 a_mem(1100 + i), 2'd3);
                        dbg_store($sformatf("debug write during CPU traffic %0d", i),
                                  a_mem(1100 + i), 2'd3, 64'hD0D0_0000_0000_0000 + 64'(i));
                    end
                end
            join
            d_flush("flush the dirty lines of the CPU");
            d_drain();
            check_memory("memory image after the debug port tests");

            if (n_error == e0) ok("debug port: miss, hit, write through, sharing with the CPU");
        end

        //=============================================================
        // Throughput patterns (only with +perf, see tb_CACHE_perf.svh)
        //=============================================================
        if ($test$plusargs("perf")) perf_run();

        //=============================================================
        $display("");
        $display("==========================================================");
        $display(" RESULT : %s   (%0d checks, %0d errors, %0d D responses, %0d I responses)",
                 (n_error == 0) ? "PASS" : "FAIL", n_check, n_error, n_d_resp, n_i_resp);
        $display("==========================================================");
        $finish;
    end
