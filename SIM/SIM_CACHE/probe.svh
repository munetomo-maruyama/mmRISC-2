    // debug probe: +pfrom / +pto select the cycle window
    initial begin
        int n, pf, pt;
        n = 0;
        if (!$value$plusargs("pfrom=%d", pf)) pf = 0;
        if (!$value$plusargs("pto=%d", pt))   pt = 200;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            n++;
            if (n >= pf && n <= pt)
                $display("%4d rq=%b/%b a=%h c=%0d sz=%0d wd=%h | s1 v=%b a=%h c=%0d ok=%b hit=%b hb=%b ret=%b wf=%b | f=%0d beat=%0d msc=%0d msl=%h msw=%0d wbn=%b stp=%b | wb=%0d/%0d w=%0d | dwr=%b way=%0d ad=%h d=%h s=%h | twr=%b i=%0d w=%0d v=%b d=%b | resp=%b %h",
                  n, d_req_valid, d_req_ready, d_req_addr, d_req_cmd, d_req_size, d_req_wdata,
                  u_cache.u_dcache.s1_valid, u_cache.u_dcache.s1_addr, u_cache.u_dcache.s1_cmd,
                  u_cache.u_dcache.s1_data_ok, u_cache.u_dcache.hit, u_cache.u_dcache.hit_busy,
                  u_cache.u_dcache.s1_can_retire, u_cache.u_dcache.s1_wait_fill,
                  u_cache.u_dcache.f_state, u_cache.u_dcache.f_beat, u_cache.u_dcache.ms_count,
                  u_cache.u_dcache.ms_line[u_cache.u_dcache.ms_head],
                  u_cache.u_dcache.ms_way[u_cache.u_dcache.ms_head],
                  u_cache.u_dcache.ms_wb_needed, u_cache.u_dcache.ms_st_pending,
                  u_cache.u_dcache.wb_count, u_cache.u_dcache.wb_valid, u_cache.u_dcache.w_state,
                  u_cache.u_dcache.dat_wr_en, u_cache.u_dcache.dat_wr_way, u_cache.u_dcache.dat_wr_addr,
                  u_cache.u_dcache.dat_wr_data, u_cache.u_dcache.dat_wr_strb,
                  u_cache.u_dcache.tag_wr_en, u_cache.u_dcache.tag_wr_index, u_cache.u_dcache.tag_wr_way,
                  u_cache.u_dcache.tag_wr_valid, u_cache.u_dcache.tag_wr_dirty,
                  d_resp_valid, d_resp_data);
        end
    end
