//---------------------------------------------------------------------------
// tb_PMP.sv : MMU_PMP against a model written from the specification
//
//   The model below is written straight out of the privileged specification
//   and shares nothing with the RTL: it works on byte addresses and ranges
//   instead of the shifted comparisons the hardware uses, so that a mistake
//   in the shift or in the NAPOT mask shows up as a disagreement.
//
//   The entries are filled at random, with the NAPOT sizes and the region
//   edges weighted so that the interesting cases (an access that straddles
//   the boundary of a region, two entries that overlap, a locked entry seen
//   from machine mode) come up often.
//
//   +n=<count>    number of random cases   (default 200000)
//   +seed=<n>
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_PMP;

    localparam int ENTRIES = 16;

    logic [8*ENTRIES-1:0]  cfg;
    logic [64*ENTRIES-1:0] addr;
    logic [1:0]            priv;
    logic [63:0]           paddr;
    logic [1:0]            size;
    logic                  is_read, is_write, is_exec;
    logic                  fail;

    MMU_PMP #(.ENTRIES(ENTRIES)) dut
        (
            .cfg (cfg), .addr (addr), .priv (priv), .paddr (paddr),
            .size (size), .is_read (is_read), .is_write (is_write),
            .is_exec (is_exec), .fail (fail)
        );

    //-----------------------------------------------------------------
    // the model
    //
    //   Every entry is turned into a byte range [base, base + len). The
    //   access is allowed when every one of its bytes falls into the same
    //   entry and that entry permits it.
    //-----------------------------------------------------------------
    logic [63:0] m_base [0:ENTRIES-1];
    logic [63:0] m_len  [0:ENTRIES-1];
    logic        m_on   [0:ENTRIES-1];

    task automatic model_ranges;
        logic [63:0] this_a, prev_a;
        int          k;
        begin
            for (int i = 0; i < ENTRIES; i++) begin
                this_a = {10'd0, addr[64*i +: 54]};
                prev_a = (i == 0) ? 64'd0 : {10'd0, addr[64*(i-1) +: 54]};
                m_on[i]   = 1'b1;
                m_base[i] = 64'd0;
                m_len[i]  = 64'd0;
                case (cfg[8*i+3 +: 2])
                    2'd0: m_on[i] = 1'b0;                       // OFF
                    2'd1: begin                                 // TOR
                        m_base[i] = prev_a * 4;
                        m_len[i]  = (this_a > prev_a) ? (this_a - prev_a) * 4 : 64'd0;
                        if (m_len[i] == 0) m_on[i] = 1'b0;
                    end
                    2'd2: begin                                 // NA4
                        m_base[i] = this_a * 4;
                        m_len[i]  = 64'd4;
                    end
                    default: begin                              // NAPOT
                        // count the ones at the bottom of pmpaddr: k of them
                        // mean a region of 2^(k+3) bytes
                        k = 0;
                        while ((k < 54) && this_a[k]) k++;
                        m_len[i]  = 64'd8 << k;
                        m_base[i] = (this_a & ~((64'd1 << k) - 64'd1)) * 4;
                    end
                endcase
            end
        end
    endtask

    function automatic int model_entry_of(input logic [63:0] a);
        begin
            model_entry_of = -1;
            for (int i = 0; i < ENTRIES; i++)
                if ((model_entry_of < 0) && m_on[i] &&
                    (a >= m_base[i]) && (a < m_base[i] + m_len[i]))
                    model_entry_of = i;
        end
    endfunction

    function automatic logic model_fail(input logic [63:0] a, input int nbytes);
        int         e0, ei;
        logic [7:0] c;
        logic       split, done;
        begin
            e0    = model_entry_of(a & 64'h00FF_FFFF_FFFF_FFFF);
            split = 1'b0;
            for (int b = 1; b < nbytes; b++) begin
                ei = model_entry_of((a + 64'(b)) & 64'h00FF_FFFF_FFFF_FFFF);
                if (ei != e0) split = 1'b1;
            end
            model_fail = 1'b0;
            done       = 1'b0;
            if (split) begin
                model_fail = 1'b1;                  // not all in one entry
                done       = 1'b1;
            end else if (e0 < 0) begin
                model_fail = (priv != 2'b11);       // no entry : only M may
                done       = 1'b1;
            end
            if (!done) begin
                c = cfg[8*e0 +: 8];
                if ((priv == 2'b11) && !c[7])
                    model_fail = 1'b0;              // M and the entry is open
                else
                    model_fail = (is_read  && !c[0]) ||
                                 (is_write && !c[1]) ||
                                 (is_exec  && !c[2]);
            end
        end
    endfunction

    //-----------------------------------------------------------------
    // stimulus
    //-----------------------------------------------------------------
    int unsigned seed;
    int          n_cases, n_checks, n_bad;
    logic [63:0] anchor;

    function automatic logic [53:0] rand_napot(input logic [53:0] base,
                                               input int k);
        // an address whose bottom k bits are ones : a region of 2^(k+3) bytes
        begin
            rand_napot = (base & ~((54'd1 << (k+1)) - 54'd1)) |
                         ((54'd1 << k) - 54'd1);
        end
    endfunction

    initial begin
        seed     = 1;
        n_cases  = 200000;
        n_checks = 0;
        n_bad    = 0;
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("n=%d", n_cases));
        // seed once; $urandom(seed) would reset the generator on every call
        // and hand out the same number for ever
        void'($urandom(seed));

        for (int t = 0; t < n_cases; t++) begin
            int n_active;

            // The base the entries are built around. Most of the time it is
            // somewhere in the low addresses, but a quarter of the cases put
            // it high up so that the top bits of pmpaddr have to be compared
            // as well; one in eight sits at the very top of the space.
            case ($urandom() % 8)
                0, 1, 2: anchor = {48'd0, 16'($urandom())} & ~64'd7;
                3, 4:    anchor = 64'h0000_0000_8000_0000 +
                                  ({48'd0, 16'($urandom())} & ~64'd7);
                5, 6:    anchor = {8'd0, 56'({$urandom(), $urandom()})} & ~64'd7;
                default: anchor = 64'h00FF_FFFF_FFFF_FF00;
            endcase

            // Sometimes only a couple of entries are on. With sixteen random
            // ones almost every address matches something, and the case of
            // an access with one end inside a region and the other end in no
            // region at all would never come up.
            n_active = ($urandom() % 2) ? ENTRIES : (1 + $urandom() % 3);

            cfg  = '0;
            addr = '0;
            for (int i = 0; i < ENTRIES; i++) begin
                logic [1:0]  mode;
                logic [53:0] a;
                mode = (i < n_active) ? 2'($urandom() % 4) : 2'd0;
                case (mode)
                    2'd1: a = 54'((anchor + 64'($urandom() % 64'd256)) >> 2);
                    2'd2: a = 54'((anchor + 64'($urandom() % 64'd64)) >> 2);
                    2'd3: a = rand_napot(54'(anchor >> 2), $urandom() % 8);
                    default: a = 54'({$urandom(), $urandom()});
                endcase
                // now and then the entry that covers everything
                if ($urandom() % 32 == 0) begin mode = 2'd3; a = '1; end
                addr[64*i +: 54] = a;
                cfg[8*i +: 3]    = 3'($urandom() % 8);
                if (cfg[8*i+1] && !cfg[8*i]) cfg[8*i +: 3] = 3'b000;  // W without R
                cfg[8*i+3 +: 2]  = mode;
                cfg[8*i+7]       = ($urandom() % 8 == 0);              // locked
            end
            model_ranges();

            priv     = 2'($urandom() % 3);
            if (priv == 2'd2) priv = 2'b11;
            size     = 2'($urandom() % 4);
            paddr    = (anchor + 64'($urandom() % 64'd320)) & ~((64'd1 << size) - 64'd1);
            // Every so often one of the upper bits of the address is turned
            // over. The entries are all built around the anchor, so without
            // this the top bits of the comparison would never differ and a
            // comparison that is a bit too short would go unnoticed.
            if ($urandom() % 8 == 0)
                paddr = paddr ^ (64'd1 << (12 + ($urandom() % 44)));
            is_read  = 1'b0; is_write = 1'b0; is_exec = 1'b0;
            case ($urandom() % 3)
                0: is_read  = 1'b1;
                1: is_write = 1'b1;
                default: is_exec = 1'b1;
            endcase

            #1;
            n_checks++;
            if (fail !== model_fail(paddr, 1 << size)) begin
                n_bad++;
                if (n_bad <= 10)
                    $display("MISMATCH case %0d : paddr=%016h size=%0d priv=%0d r%0b w%0b x%0b  rtl=%0b model=%0b",
                             t, paddr, size, priv, is_read, is_write, is_exec,
                             fail, model_fail(paddr, 1 << size));
            end
        end

        $display("");
        if (n_bad == 0) $display("PMP TEST RESULT : PASS   (%0d checks)", n_checks);
        else            $display("PMP TEST RESULT : FAIL   (%0d of %0d)", n_bad, n_checks);
        $finish;
    end

endmodule : tb_PMP
