//---------------------------------------------------------------------------
// CORE_MMU.sv
//
// Address translation and protection (CPU_CORE_SPEC.md 6).
//
//   One of these sits between the pipeline and the two cache ports. Each
//   side hands it a virtual address and gets back a physical one, or a
//   fault, or "not this cycle" while the page table is being walked.
//
//   A TLB hit translates combinationally, so the physical address is ready
//   in the same cycle the request is made. The cache is indexed with the
//   virtual address and tagged with the physical one (CPU_CACHE_SPEC.md
//   5.6); because the index and the offset together stay inside a page, the
//   two agree on those bits and nothing in the cache has to change.
//
//   The permissions are checked on every lookup and not when an entry is
//   filled, because the privilege level, SUM and MXR change without
//   anything being invalidated.
//
//   The walker reads the page table through the data cache port. It is only
//   started while the load store unit has nothing in flight, and it then
//   holds the port until it is finished, so the two can never be in the
//   cache at the same time. While it holds the port the data side is told
//   "not this cycle": no access could be issued anyway, and it frees the
//   protection checker of that side for the walker's own reads.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_MMU
    #(
        parameter int PMP_ENTRIES  = 8,
        parameter int ITLB_ENTRIES = 8,
        parameter int DTLB_ENTRIES = 8
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // state of the privilege architecture
        input  logic [1:0]  priv,
        input  logic [63:0] satp,
        input  logic        mstatus_sum,
        input  logic        mstatus_mxr,
        input  logic        mstatus_mprv,
        input  logic [1:0]  mstatus_mpp,

        input  logic [8*(PMP_ENTRIES > 0 ? PMP_ENTRIES : 1)-1:0]  pmpcfg,
        input  logic [64*(PMP_ENTRIES > 0 ? PMP_ENTRIES : 1)-1:0] pmpaddr,

        // instruction side
        input  logic        i_req,          // a fetch would be issued now
        input  logic [63:0] i_vaddr,
        output logic        i_ready,        // the answer below is valid
        output logic [63:0] i_paddr,
        output logic [1:0]  i_fault,        // 0 none, 1 access fault, 2 page fault

        // data side
        input  logic        d_req,
        input  logic [63:0] d_vaddr,
        input  logic [1:0]  d_size,
        input  logic        d_is_load,
        input  logic        d_is_store,
        output logic        d_ready,
        output logic [63:0] d_paddr,
        output logic [1:0]  d_fault,

        // SFENCE.VMA at the commit point
        input  logic        sfence_valid,
        input  logic [63:0] sfence_vaddr,   // 0 : every address
        input  logic [63:0] sfence_asid,    // 0 : every ASID

        // a trap emptied the pipeline : throw a walk away
        input  logic        kill,

        // data cache port for the walker
        input  logic        lsu_idle,       // nothing of the pipeline in flight
        output logic        ptw_active,     // the walker owns the port
        output logic        m_req_valid,
        input  logic        m_req_ready,
        output logic [63:0] m_req_addr,
        output logic [63:0] m_req_paddr,
        input  logic        m_resp_valid,
        input  logic [63:0] m_resp_data,
        input  logic        m_resp_error
    );

    localparam logic [1:0] PRIV_M     = 2'b11;
    localparam logic [1:0] PRIV_U     = 2'b00;
    localparam logic [1:0] FAULT_NONE = 2'd0;
    localparam logic [1:0] FAULT_ACC  = 2'd1;
    localparam logic [1:0] FAULT_PAGE = 2'd2;
    localparam logic [3:0] SATP_SV39  = 4'd8;

    //-----------------------------------------------------------------
    // what applies to which access
    //
    //   MPRV makes the data side behave as if it ran at MPP. It is cleared
    //   whenever a return leaves machine mode, so it can only ever be set
    //   while the hart is in M. An instruction fetch is never affected.
    //-----------------------------------------------------------------
    logic [1:0]  d_priv;
    logic        sv39, i_trans, d_trans;
    logic [15:0] asid;

    assign d_priv  = mstatus_mprv ? mstatus_mpp : priv;
    assign sv39    = (satp[63:60] == SATP_SV39);
    assign i_trans = sv39 & (priv   != PRIV_M);
    assign d_trans = sv39 & (d_priv != PRIV_M);
    assign asid    = satp[59:44];

    //-----------------------------------------------------------------
    // the virtual address has to be a sign extension of bit 38
    //-----------------------------------------------------------------
    logic        i_va_ok, d_va_ok;
    logic [26:0] i_vpn, d_vpn;

    assign i_va_ok = (i_vaddr[63:39] == {25{i_vaddr[38]}});
    assign d_va_ok = (d_vaddr[63:39] == {25{d_vaddr[38]}});
    assign i_vpn   = i_vaddr[38:12];
    assign d_vpn   = d_vaddr[38:12];

    //-----------------------------------------------------------------
    // the two translation buffers
    //-----------------------------------------------------------------
    logic        i_hit, d_hit;
    logic [43:0] i_tppn, d_tppn;
    logic [1:0]  i_tlevel, d_tlevel;
    logic [7:0]  i_tperm, d_tperm;
    logic        i_fill, d_fill;
    logic        inv_all_addr, inv_all_asid;

    assign inv_all_addr = (sfence_vaddr == 64'd0);
    assign inv_all_asid = (sfence_asid  == 64'd0);

    logic [43:0] ptw_ppn;
    logic [1:0]  ptw_level;
    logic [7:0]  ptw_perm;
    logic [26:0] ptw_vpn_r;

    MMU_TLB #(.ENTRIES(ITLB_ENTRIES)) u_itlb
        (
            .clk (clk), .rst_n (rst_n),
            .vpn (i_vpn), .asid (asid),
            .hit (i_hit), .ppn (i_tppn), .level (i_tlevel), .perm (i_tperm),
            .fill_en (i_fill), .fill_vpn (ptw_vpn_r), .fill_asid (asid),
            .fill_ppn (ptw_ppn), .fill_level (ptw_level), .fill_perm (ptw_perm),
            .inv_en (sfence_valid),
            .inv_all_addr (inv_all_addr), .inv_all_asid (inv_all_asid),
            .inv_vpn (sfence_vaddr[38:12]), .inv_asid (sfence_asid[15:0])
        );

    MMU_TLB #(.ENTRIES(DTLB_ENTRIES)) u_dtlb
        (
            .clk (clk), .rst_n (rst_n),
            .vpn (d_vpn), .asid (asid),
            .hit (d_hit), .ppn (d_tppn), .level (d_tlevel), .perm (d_tperm),
            .fill_en (d_fill), .fill_vpn (ptw_vpn_r), .fill_asid (asid),
            .fill_ppn (ptw_ppn), .fill_level (ptw_level), .fill_perm (ptw_perm),
            .inv_en (sfence_valid),
            .inv_all_addr (inv_all_addr), .inv_all_asid (inv_all_asid),
            .inv_vpn (sfence_vaddr[38:12]), .inv_asid (sfence_asid[15:0])
        );

    //-----------------------------------------------------------------
    // the physical address of a hit
    //-----------------------------------------------------------------
    function automatic logic [63:0] merge_pa(input logic [43:0] ppn_in,
                                             input logic [1:0]  lv,
                                             input logic [63:0] va);
        begin
            case (lv)
                2'd2:    merge_pa = {8'd0, ppn_in[43:18], va[29:0]};   // 1G
                2'd1:    merge_pa = {8'd0, ppn_in[43:9],  va[20:0]};   // 2M
                default: merge_pa = {8'd0, ppn_in,        va[11:0]};   // 4K
            endcase
        end
    endfunction

    assign i_paddr = i_trans ? merge_pa(i_tppn, i_tlevel, i_vaddr) : i_vaddr;
    assign d_paddr = d_trans ? merge_pa(d_tppn, d_tlevel, d_vaddr) : d_vaddr;

    //-----------------------------------------------------------------
    // permissions of an entry, bit for bit as the page table holds them
    //
    //   [7] D  [6] A  [5] G  [4] U  [3] X  [2] W  [1] R  [0] V
    //-----------------------------------------------------------------
    logic i_perm_ok, d_perm_ok, d_u_ok, d_rd_ok;

    // SUM lets the supervisor read and write a user page, but never execute
    // one, so the instruction side has no SUM in it
    assign i_perm_ok = i_tperm[3] & i_tperm[6]
                     & ((priv == PRIV_U) ? i_tperm[4] : ~i_tperm[4]);

    assign d_u_ok    = (d_priv == PRIV_U) ? d_tperm[4]
                                          : (~d_tperm[4] | mstatus_sum);
    // MXR lets a page that is only executable be read
    assign d_rd_ok   = d_tperm[1] | (mstatus_mxr & d_tperm[3]);
    assign d_perm_ok = d_u_ok & d_tperm[6]                       // A
                     & (d_is_load  ? d_rd_ok : 1'b1)
                     & (d_is_store ? (d_tperm[2] & d_tperm[7]) : 1'b1);  // W, D

    //-----------------------------------------------------------------
    // what a walk that ended in a fault left behind
    //
    //   Held until the address moves on or something is invalidated, so
    //   that a fetch of the same page does not walk the table again.
    //-----------------------------------------------------------------
    logic        i_flt_valid, d_flt_valid;
    logic [1:0]  i_flt_code,  d_flt_code;
    logic [26:0] i_flt_vpn,   d_flt_vpn;
    logic        i_flt_hit,   d_flt_hit;

    assign i_flt_hit = i_flt_valid & (i_flt_vpn == i_vpn);
    assign d_flt_hit = d_flt_valid & (d_flt_vpn == d_vpn);

    //-----------------------------------------------------------------
    // the walker and the port it borrows
    //-----------------------------------------------------------------
    logic        i_need_walk, d_need_walk, ptw_need;
    logic        grant, killed, for_d, m_inflight;
    logic [1:0]  ptw_priv;
    logic        ptw_req, ptw_busy, ptw_done;
    logic [1:0]  ptw_fault;
    logic [63:0] ptw_pmp_addr;
    logic        ptw_pmp_fail;

    assign i_need_walk = i_req & i_trans & i_va_ok & ~i_hit & ~i_flt_hit;
    assign d_need_walk = d_req & d_trans & d_va_ok & ~d_hit & ~d_flt_hit;
    assign ptw_need    = i_need_walk | d_need_walk;

    assign ptw_active  = grant;
    assign ptw_req     = grant & ~ptw_busy & ~ptw_done & ~killed;

    MMU_PTW u_ptw
        (
            .clk (clk), .rst_n (rst_n),
            .req (ptw_req), .vpn (ptw_vpn_r), .satp (satp), .kill (killed),
            .busy (ptw_busy), .done (ptw_done), .fault (ptw_fault),
            .ppn (ptw_ppn), .level (ptw_level), .perm (ptw_perm),
            .pmp_addr (ptw_pmp_addr), .pmp_fail (ptw_pmp_fail),
            .m_req_valid (m_req_valid), .m_req_ready (m_req_ready),
            .m_req_addr (m_req_addr),
            .m_resp_valid (m_resp_valid), .m_resp_data (m_resp_data),
            .m_resp_error (m_resp_error)
        );

    assign i_fill = ptw_done & ~for_d & (ptw_fault == FAULT_NONE);
    assign d_fill = ptw_done &  for_d & (ptw_fault == FAULT_NONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant       <= 1'b0;
            killed      <= 1'b0;
            for_d       <= 1'b0;
            ptw_vpn_r   <= 27'd0;
            ptw_priv    <= PRIV_M;
            m_inflight  <= 1'b0;
            m_req_paddr <= 64'd0;
        end else begin
            if (m_req_valid && m_req_ready) begin
                m_inflight  <= 1'b1;
                m_req_paddr <= m_req_addr;    // the cache wants the tag next cycle
            end else if (m_resp_valid) begin
                m_inflight  <= 1'b0;
            end

            if (!grant) begin
                killed <= 1'b0;
                if (lsu_idle && ptw_need && !kill) begin
                    grant     <= 1'b1;
                    for_d     <= d_need_walk;      // the data side goes first
                    ptw_vpn_r <= d_need_walk ? d_vpn : i_vpn;
                    ptw_priv  <= d_need_walk ? d_priv : priv;
                end
            end else begin
                if (kill) killed <= 1'b1;
                // the port is not handed back while a read of the walker is
                // still in the cache, or its answer would go to the pipeline
                if ((ptw_done || killed || kill) &&
                    !m_inflight && !(m_req_valid && m_req_ready))
                    grant <= 1'b0;
            end
        end
    end

    //-----------------------------------------------------------------
    // the fault a walk left behind
    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_flt_valid <= 1'b0;
            d_flt_valid <= 1'b0;
            i_flt_code  <= FAULT_NONE;
            d_flt_code  <= FAULT_NONE;
            i_flt_vpn   <= 27'd0;
            d_flt_vpn   <= 27'd0;
        end else begin
            // anything that changes the table takes the memory away
            if (sfence_valid) begin
                i_flt_valid <= 1'b0;
                d_flt_valid <= 1'b0;
            end else begin
                if (ptw_done && !killed && (ptw_fault != FAULT_NONE)) begin
                    if (for_d) begin
                        d_flt_valid <= 1'b1;
                        d_flt_code  <= ptw_fault;
                        d_flt_vpn   <= ptw_vpn_r;
                    end else begin
                        i_flt_valid <= 1'b1;
                        i_flt_code  <= ptw_fault;
                        i_flt_vpn   <= ptw_vpn_r;
                    end
                end
                if (i_flt_valid && i_req && !i_flt_hit) i_flt_valid <= 1'b0;
                if (d_flt_valid && d_req && !d_flt_hit) d_flt_valid <= 1'b0;
            end
        end
    end

    //-----------------------------------------------------------------
    // protection
    //
    //   The checker of the data side is lent to the walker while it owns
    //   the port; the data side is held back in those cycles anyway.
    //-----------------------------------------------------------------
    logic        i_pmp_fail, d_pmp_fail;
    logic [63:0] pmp_d_addr;
    logic [1:0]  pmp_d_priv, pmp_d_size;
    logic        pmp_d_read, pmp_d_write;

    assign pmp_d_addr  = grant ? ptw_pmp_addr : d_paddr;
    assign pmp_d_priv  = grant ? ptw_priv     : d_priv;
    assign pmp_d_size  = grant ? 2'd3         : d_size;
    assign pmp_d_read  = grant ? 1'b1         : d_is_load;
    assign pmp_d_write = grant ? 1'b0         : d_is_store;
    assign ptw_pmp_fail = grant & d_pmp_fail;

    MMU_PMP #(.ENTRIES(PMP_ENTRIES)) u_pmp_i
        (
            .cfg      (pmpcfg),
            .addr     (pmpaddr),
            .priv     (priv),
            .paddr    (i_paddr),
            .size     (2'd3),            // a fetch brings a whole double word
            .is_read  (1'b0),
            .is_write (1'b0),
            .is_exec  (1'b1),
            .fail     (i_pmp_fail)
        );

    MMU_PMP #(.ENTRIES(PMP_ENTRIES)) u_pmp_d
        (
            .cfg      (pmpcfg),
            .addr     (pmpaddr),
            .priv     (pmp_d_priv),
            .paddr    (pmp_d_addr),
            .size     (pmp_d_size),
            .is_read  (pmp_d_read),
            .is_write (pmp_d_write),
            .is_exec  (1'b0),
            .fail     (d_pmp_fail)
        );

    //-----------------------------------------------------------------
    // the answers
    //-----------------------------------------------------------------
    always @(*) begin
        i_ready = 1'b1;
        i_fault = FAULT_NONE;
        if (!i_req) begin
            i_fault = FAULT_NONE;
        end else if (i_trans && !i_va_ok) begin
            i_fault = FAULT_PAGE;            // not a sign extension of bit 38
        end else if (i_trans && !i_hit) begin
            if (i_flt_hit) i_fault = i_flt_code;
            else           i_ready = 1'b0;   // the table is being walked
        end else if (i_trans && !i_perm_ok) begin
            i_fault = FAULT_PAGE;
        end else if (i_pmp_fail) begin
            i_fault = FAULT_ACC;
        end
    end

    always @(*) begin
        d_ready = 1'b1;
        d_fault = FAULT_NONE;
        if (grant) begin
            // the walker has the port and the checker
            d_ready = ~d_req;
        end else if (!d_req) begin
            d_fault = FAULT_NONE;
        end else if (d_trans && !d_va_ok) begin
            d_fault = FAULT_PAGE;
        end else if (d_trans && !d_hit) begin
            if (d_flt_hit) d_fault = d_flt_code;
            else           d_ready = 1'b0;
        end else if (d_trans && !d_perm_ok) begin
            d_fault = FAULT_PAGE;
        end else if (d_pmp_fail) begin
            d_fault = FAULT_ACC;
        end
    end

endmodule : CORE_MMU
