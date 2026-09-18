    initial begin
        int n;
        n = 0;
        @(posedge rst_n);
        forever begin
            @(posedge clk);
            n++;
            if (n < 120)
                $display("%4d rq=%b/%b addr=%h cmd=%0d | s1=%b ok=%b re=%b wait=%b hit=%b canret=%b | f=%0d beat=%0d ms=%0d/%b | ar=%b/%b r=%b last=%b | rob=%0d done=%b resp=%b",
                  n, d_req_valid, d_req_ready, d_req_addr, d_req_cmd,
                  u_cache.u_dcache.s1_valid, u_cache.u_dcache.s1_data_ok, u_cache.u_dcache.s1_reread,
                  u_cache.u_dcache.s1_wait_fill, u_cache.u_dcache.hit, u_cache.u_dcache.s1_can_retire,
                  u_cache.u_dcache.f_state, u_cache.u_dcache.f_beat, u_cache.u_dcache.ms_count,
                  u_cache.u_dcache.ms_valid,
                  m_axi4_arvalid, m_axi4_arready, m_axi4_rvalid, m_axi4_rlast,
                  u_cache.u_dcache.rob_count, u_cache.u_dcache.rob_done, d_resp_valid);
        end
    end
