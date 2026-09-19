//---------------------------------------------------------------------------
// tb_CACHE_perf.svh : throughput patterns (included inside tb_CACHE)
//
//   Runs only with +perf. Every pattern is a burst of accesses of one kind,
//   so the waveform shows the steady state of that case:
//
//     +perf=1  I$ : hit burst      (every fetch hits)
//     +perf=2  I$ : miss burst     (every fetch misses, one line each)
//     +perf=3  D$ : hit burst      (load burst, then store burst)
//     +perf=4  D$ : miss burst     (clean fill, write allocate, dirty evict)
//     +perf=0  all of them (default when +perf is given without a value)
//
//   +pn=<n>     accesses in a hit burst (default 32)
//   +pm=<n>     lines in a miss burst   (default 8)
//   +marks=<f>  write "<time> <label>" of every phase to file <f>
//               (gen_gtkw.py turns them into GTKWave markers)
//
//   The accesses go through the normal request path, so the reference model
//   checks them like any other test.
//---------------------------------------------------------------------------

    int      perf_sel, perf_n, perf_m;
    integer  perf_fd = 0;
    int      perf_t0, perf_c0;
    string   perf_label;

    // response timestamps inside the measured burst: the total time contains
    // the pipeline latency of the first access, the distance between the
    // first and the last response is the steady state throughput
    bit      perf_active = 1'b0, perf_wait_first = 1'b0;
    int      perf_first, perf_last;

    always @(posedge clk) begin
        if (rst_n && perf_active && (d_resp_valid || i_resp_valid)) begin
            if (perf_wait_first) begin
                perf_first      <= cyc;
                perf_wait_first <= 1'b0;
            end
            perf_last <= cyc;
        end
    end

    // word index of the first word of the I$ pattern area: the end of the
    // cacheable window, so that it never overlaps the D$ pattern area
    function automatic int ip_word(input int line, input int word);
        return (MEM_WORDS - 1024) + line * (IC_BLOCK/8) + word;
    endfunction

    task automatic perf_mark(input string label);
        if (perf_fd != 0) $fdisplay(perf_fd, "%0t %s", $time, label);
    endtask

    // idle gap so that the bursts are easy to tell apart in the waveform
    task automatic perf_gap();
        d_drain();
        i_drain();
        repeat (16) @(posedge clk);
    endtask

    task automatic perf_begin(input string label);
        perf_gap();
        perf_label      = label;
        perf_mark(label);
        perf_t0         = cyc;
        perf_c0         = n_d_resp + n_i_resp;
        perf_wait_first = 1'b1;
        perf_active     = 1'b1;
    endtask

    // waits for the last response and prints cycles / access
    task automatic perf_end();
        int n_acc, n_cyc;
        real per_acc, steady;
        d_drain();
        i_drain();
        perf_active = 1'b0;
        n_cyc   = cyc - perf_t0;
        n_acc   = (n_d_resp + n_i_resp) - perf_c0;
        per_acc = real'(n_cyc) / real'(n_acc);
        steady  = (n_acc > 1) ? real'(perf_last - perf_first) / real'(n_acc - 1) : per_acc;
        $display("   %-32s : %0d accesses, %0d cycles, %0.2f cycles/access (steady %0.2f)",
                 perf_label, n_acc, n_cyc, per_acc, steady);
    endtask

    //-----------------------------------------------------------------
    // 1. I$ hit burst : warm the lines, then fetch them again
    //-----------------------------------------------------------------
    task automatic perf_ihit();
        section("P1. I$ hit burst");
        i_flush_all();
        for (int i = 0; i < perf_n; i++)
            i_push($sformatf("warm fetch %0d", i), a_mem(ip_word(0, 0) + i));
        i_drain();
        perf_begin("I$ hit burst");
        for (int i = 0; i < perf_n; i++)
            i_push($sformatf("hit fetch %0d", i), a_mem(ip_word(0, 0) + i));
        perf_end();
    endtask

    //-----------------------------------------------------------------
    // 2. I$ miss burst : one fetch per line, cache empty
    //-----------------------------------------------------------------
    task automatic perf_imiss();
        section("P2. I$ miss burst");
        i_flush_all();
        perf_begin("I$ miss burst");
        for (int i = 0; i < perf_m; i++)
            i_push($sformatf("miss fetch %0d", i), a_mem(ip_word(i, 0)));
        perf_end();
    endtask

    //-----------------------------------------------------------------
    // 3. D$ hit burst : load burst and store burst on warm lines
    //-----------------------------------------------------------------
    task automatic perf_dhit();
        section("P3. D$ hit burst");
        d_flush("flush before the pattern");
        d_drain();
        for (int i = 0; i < perf_n; i++)
            d_load($sformatf("warm load %0d", i), a_mem(set_word(0, 0) + i), 2'd3);
        d_drain();
        perf_begin("D$ load hit burst");
        for (int i = 0; i < perf_n; i++)
            d_load($sformatf("hit load %0d", i), a_mem(set_word(0, 0) + i), 2'd3);
        perf_end();
        perf_begin("D$ store hit burst");
        for (int i = 0; i < perf_n; i++)
            d_store($sformatf("hit store %0d", i), a_mem(set_word(0, 0) + i), 2'd3,
                    64'h5000_0000_0000_0000 + 64'(i));
        perf_end();
    endtask

    //-----------------------------------------------------------------
    // 4. D$ miss burst : clean fill, write allocate, dirty eviction
    //-----------------------------------------------------------------
    task automatic perf_dmiss();
        section("P4. D$ miss burst");
        d_flush("flush before the pattern");
        d_drain();

        // (a) read miss on an empty cache : fill only
        perf_begin("D$ load miss burst (fill)");
        for (int i = 0; i < perf_m; i++)
            d_load($sformatf("miss load %0d", i), a_mem(set_word(i, 0)), 2'd3);
        perf_end();

        // (b) write miss : fill + write allocate, still no victim to write back
        perf_begin("D$ store miss burst (allocate)");
        for (int i = 0; i < perf_m; i++)
            d_store($sformatf("miss store %0d", i), a_mem(set_word(i, 1)), 2'd3,
                    64'h6000_0000_0000_0000 + 64'(i));
        perf_end();

        // fill the remaining ways of those sets with dirty lines
        for (int w = 2; w < DC_WAYS; w++)
            for (int i = 0; i < perf_m; i++)
                d_store($sformatf("dirty way %0d set %0d", w, i), a_mem(set_word(i, w)), 2'd3,
                        64'h7000_0000_0000_0000 + 64'(w) * 256 + 64'(i));
        // make way 0 dirty as well, so every way of the set is dirty
        for (int i = 0; i < perf_m; i++)
            d_store($sformatf("dirty way 0 set %0d", i), a_mem(set_word(i, 0)), 2'd3,
                    64'h7F00_0000_0000_0000 + 64'(i));
        d_drain();

        // (c) every set is full of dirty lines : each access evicts one
        perf_begin("D$ miss burst (writeback + fill)");
        for (int i = 0; i < perf_m; i++)
            d_load($sformatf("evicting load %0d", i), a_mem(set_word(i, DC_WAYS)), 2'd3);
        perf_end();
    endtask

    //-----------------------------------------------------------------
    task automatic perf_run();
        string marks;
        if (!$value$plusargs("perf=%d", perf_sel)) perf_sel = 0;
        if (!$value$plusargs("pn=%d", perf_n))     perf_n   = 32;
        if (!$value$plusargs("pm=%d", perf_m))     perf_m   = 8;
        if ($value$plusargs("marks=%s", marks))    perf_fd  = $fopen(marks, "w");

        $display("");
        $display("==========================================================");
        $display(" throughput patterns (hit burst = %0d accesses, miss burst = %0d lines)",
                 perf_n, perf_m);
        $display("==========================================================");

        if (perf_sel == 0 || perf_sel == 1) perf_ihit();
        if (perf_sel == 0 || perf_sel == 2) perf_imiss();
        if (perf_sel == 0 || perf_sel == 3) perf_dhit();
        if (perf_sel == 0 || perf_sel == 4) perf_dmiss();

        perf_gap();
        perf_mark("end");
        if (perf_fd != 0) $fclose(perf_fd);
    endtask
