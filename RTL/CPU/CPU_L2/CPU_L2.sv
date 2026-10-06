//---------------------------------------------------------------------------
// CPU_L2.sv
//
// L2 cache between CPU_CACHE's memory bus and the memory (CPU_L2_SPEC.md).
//
//   SIZE_BYTES, WAYS, 64 byte lines, write back, non-inclusive.
//
//   AXI4 slave (s_axi4_*): what CPU_CACHE sends, which is three kinds of
//   transaction only (CPU_L2_SPEC.md 4):
//     line read    AR, INCR, 8 beats from the line base   I$ / D$ fill
//     line write   AW, INCR, 8 beats, every byte          D$ write back
//     part write   AW, 1 beat with strobes                the debugger's
//                                                         write through
//   A write of 8 beats from the line base is taken as a line write (all
//   strobes set, as the D$ always sends them); any other write as a part
//   write. A read may be any INCR burst inside one line.
//
//   AXI4 master (m_axi4_*): fills (INCR, 8 beats from the line base), the
//   write out of evicted dirty lines, and the part writes passed through.
//
//   One transaction at a time, in the order the slave accepts them (AR and
//   AW in turn when both wait):
//
//     read, hit      the line from the data array, 1 beat a cycle; the first
//                    beat leaves 2 cycles after AR (accept, compare)
//     read, miss     choose a victim (an invalid way, else pseudo LRU or
//                    random); a dirty victim is copied to the evict buffer
//                    first; the line is read from memory, written to the
//                    array and passed on as it arrives
//     line write     hit: written into the line, which becomes dirty.
//                    miss: a victim as above, the line written without
//                    reading memory, dirty
//     part write     passed through to memory (write through, not
//                    allocated); on a hit the bytes are also written into
//                    the line, whose dirty bit is left as it was
//
//   The evict buffer holds one line and is written out by its own engine
//   (drain_*) while the next transactions go on. A transaction that needs
//   memory (a miss, a part write) or the buffer (a dirty victim) waits until
//   the buffer is empty. That keeps every access of the same line in order:
//   a line in the buffer is no longer in the array, so a later access of it
//   misses and waits for its write out.
//
//   After reset the tag array is walked (SETS cycles) to clear the valid
//   bits; no transaction is accepted before that.
//
//   ev_read / ev_miss: one pulse per read and per read miss, for the PMU.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_L2
    #(
        parameter int ADDR_WIDTH     = 40,
        parameter int ID_WIDTH       = 4,
        parameter int SIZE_BYTES     = 256 * 1024,
        parameter int WAYS           = 4,
        parameter int REPLACE_RANDOM = 0,           // 0: tree pseudo LRU
        parameter logic [ID_WIDTH-1:0] DRAIN_ID = '0  // AXI ID of the write outs
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // slave : from CPU_CACHE
        input  logic [ID_WIDTH-1:0]     s_axi4_awid,
        input  logic [ADDR_WIDTH-1:0]   s_axi4_awaddr,
        input  logic [7:0]              s_axi4_awlen,
        input  logic [2:0]              s_axi4_awsize,
        input  logic [1:0]              s_axi4_awburst,
        input  logic                    s_axi4_awvalid,
        output logic                    s_axi4_awready,
        input  logic [63:0]             s_axi4_wdata,
        input  logic [7:0]              s_axi4_wstrb,
        input  logic                    s_axi4_wlast,
        input  logic                    s_axi4_wvalid,
        output logic                    s_axi4_wready,
        output logic [ID_WIDTH-1:0]     s_axi4_bid,
        output logic [1:0]              s_axi4_bresp,
        output logic                    s_axi4_bvalid,
        input  logic                    s_axi4_bready,
        input  logic [ID_WIDTH-1:0]     s_axi4_arid,
        input  logic [ADDR_WIDTH-1:0]   s_axi4_araddr,
        input  logic [7:0]              s_axi4_arlen,
        input  logic [2:0]              s_axi4_arsize,
        input  logic [1:0]              s_axi4_arburst,
        input  logic                    s_axi4_arvalid,
        output logic                    s_axi4_arready,
        output logic [ID_WIDTH-1:0]     s_axi4_rid,
        output logic [63:0]             s_axi4_rdata,
        output logic [1:0]              s_axi4_rresp,
        output logic                    s_axi4_rlast,
        output logic                    s_axi4_rvalid,
        input  logic                    s_axi4_rready,

        // master : to the memory
        output logic [ID_WIDTH-1:0]     m_axi4_awid,
        output logic [ADDR_WIDTH-1:0]   m_axi4_awaddr,
        output logic [7:0]              m_axi4_awlen,
        output logic [2:0]              m_axi4_awsize,
        output logic [1:0]              m_axi4_awburst,
        output logic                    m_axi4_awlock,
        output logic [3:0]              m_axi4_awcache,
        output logic [2:0]              m_axi4_awprot,
        output logic [3:0]              m_axi4_awqos,
        output logic                    m_axi4_awvalid,
        input  logic                    m_axi4_awready,
        output logic [63:0]             m_axi4_wdata,
        output logic [7:0]              m_axi4_wstrb,
        output logic                    m_axi4_wlast,
        output logic                    m_axi4_wvalid,
        input  logic                    m_axi4_wready,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [ID_WIDTH-1:0]     m_axi4_bid,          // one write at a time
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [1:0]              m_axi4_bresp,
        input  logic                    m_axi4_bvalid,
        output logic                    m_axi4_bready,
        output logic [ID_WIDTH-1:0]     m_axi4_arid,
        output logic [ADDR_WIDTH-1:0]   m_axi4_araddr,
        output logic [7:0]              m_axi4_arlen,
        output logic [2:0]              m_axi4_arsize,
        output logic [1:0]              m_axi4_arburst,
        output logic                    m_axi4_arlock,
        output logic [3:0]              m_axi4_arcache,
        output logic [2:0]              m_axi4_arprot,
        output logic [3:0]              m_axi4_arqos,
        output logic                    m_axi4_arvalid,
        input  logic                    m_axi4_arready,
        /* verilator lint_off UNUSEDSIGNAL */
        input  logic [ID_WIDTH-1:0]     m_axi4_rid,          // one read at a time
        /* verilator lint_on UNUSEDSIGNAL */
        input  logic [63:0]             m_axi4_rdata,
        input  logic [1:0]              m_axi4_rresp,
        input  logic                    m_axi4_rlast,
        input  logic                    m_axi4_rvalid,
        output logic                    m_axi4_rready,

        // PMU
        output logic                    ev_read,
        output logic                    ev_miss
    );

    //-----------------------------------------------------------------
    // geometry
    //-----------------------------------------------------------------
    localparam int OFF_BITS = 6;                         // 64 byte lines
    localparam int SETS     = SIZE_BYTES / (WAYS * 64);
    localparam int IDX_BITS = $clog2(SETS);
    localparam int TAG_BITS = ADDR_WIDTH - OFF_BITS - IDX_BITS;
    localparam int WAY_BITS = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam int DA_BITS  = IDX_BITS + 3;              // data array word address
    localparam int FIFO_D   = 4;                         // R beats waiting for the slave

    //-----------------------------------------------------------------
    // arrays
    //-----------------------------------------------------------------
    logic                     t_rd_en;
    logic [IDX_BITS-1:0]      t_rd_index;
    logic [WAYS*TAG_BITS-1:0] t_rd_tag;
    logic [WAYS-1:0]          t_rd_valid, t_rd_dirty;
    logic [WAYS-1:0]          t_wr_way_en;
    logic [IDX_BITS-1:0]      t_wr_index;
    logic [TAG_BITS-1:0]      t_wr_tag;
    logic                     t_wr_valid, t_wr_dirty;

    L2_TAG_ARRAY #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS)) u_tag
        (
            .clk       (clk),
            .rd_en     (t_rd_en),     .rd_index (t_rd_index),
            .rd_tag    (t_rd_tag),    .rd_valid (t_rd_valid), .rd_dirty (t_rd_dirty),
            .wr_way_en (t_wr_way_en), .wr_index (t_wr_index),
            .wr_tag    (t_wr_tag),    .wr_valid (t_wr_valid), .wr_dirty (t_wr_dirty)
        );

    logic                d_rd_en;
    logic [DA_BITS-1:0]  d_rd_addr;
    logic [WAYS*64-1:0]  d_rd_data;
    logic                d_wr_en;
    logic [WAY_BITS-1:0] d_wr_way;
    logic [DA_BITS-1:0]  d_wr_addr;
    logic [63:0]         d_wr_data;
    logic [7:0]          d_wr_strb;

    CACHE_DATA_ARRAY #(.SETS(SETS), .WAYS(WAYS), .BLOCK_BYTES(64)) u_dat
        (
            .clk     (clk),
            .rd_en   (d_rd_en),   .rd_addr (d_rd_addr), .rd_data (d_rd_data),
            .wr_en   (d_wr_en),   .wr_way  (d_wr_way),  .wr_addr (d_wr_addr),
            .wr_data (d_wr_data), .wr_strb (d_wr_strb)
        );

    // replacement : a tree of WAYS-1 bits per set (pseudo LRU), in LUT RAM
    localparam int PL_BITS = (WAYS > 1) ? WAYS - 1 : 1;
    (* ram_style = "distributed" *)
    logic [PL_BITS-1:0] plru_mem [0:SETS-1];
    initial for (int i = 0; i < SETS; i++) plru_mem[i] = '0;

    // the way the tree points at (each bit: 1 = the right half is older)
    function automatic logic [WAY_BITS-1:0] plru_victim(input logic [PL_BITS-1:0] t);
        int node = 0;
        logic [WAY_BITS-1:0] w = '0;
        for (int l = 0; l < WAY_BITS; l++) begin
            w    = (w << 1) | WAY_BITS'(t[node]);
            node = 2 * node + 1 + int'(t[node]);
        end
        return (WAYS > 1) ? w : '0;
    endfunction

    // after an access of way a: every node on its path points away from it
    function automatic logic [PL_BITS-1:0] plru_touch(input logic [PL_BITS-1:0] t,
                                                      input logic [WAY_BITS-1:0] a);
        int node = 0;
        logic [PL_BITS-1:0] r = t;
        for (int l = 0; l < WAY_BITS; l++) begin
            logic dir = a[WAY_BITS-1-l];
            r[node] = ~dir;
            node    = 2 * node + 1 + int'(dir);
        end
        return r;
    endfunction

    logic [7:0] lfsr;                               // random replacement

    //-----------------------------------------------------------------
    // the transaction in hand
    //-----------------------------------------------------------------
    typedef enum logic [3:0] {
        M_INIT, M_IDLE, M_CMP, M_RHIT, M_WAIT, M_VCOPY, M_FILL,
        M_WLINE, M_PW_AW, M_PW_W, M_PW_B, M_BRESP
    } mstate_t;
    mstate_t st;

    logic [IDX_BITS-1:0]   init_idx;
    logic                  rr_aw;                    // AW goes first next time
    logic                  cur_write, cur_line;      // write; a whole line
    logic [ID_WIDTH-1:0]   cur_id;
    logic [ADDR_WIDTH-1:0] cur_addr;
    logic [7:0]            cur_len;
    logic [2:0]            cur_size;
    logic [1:0]            cur_burst;
    logic [IDX_BITS-1:0]   cur_idx;
    logic [TAG_BITS-1:0]   cur_tag;
    logic [2:0]            cur_word;                 // first word of the burst
    logic                  cur_hit;
    logic [WAY_BITS-1:0]   way;                      // the hit way, or the victim
    logic                  vic_dirty;                // the victim goes to the buffer
    logic [TAG_BITS-1:0]   vic_tag;
    logic                  fill_err;

    // read streaming (hit) and victim copy
    logic [2:0]            iss_word;                 // next word to read
    logic [3:0]            iss_left;                 // words still to read
    logic                  rd_pend;                  // a read was issued last cycle
    logic [2:0]            pend_word;
    logic [2:0]            wcnt;                     // W beats taken, fill beats received

    // evict buffer and its write out
    logic                  eb_valid;
    logic [63:0]           eb_data [0:7];
    logic [ADDR_WIDTH-1:0] eb_addr;
    typedef enum logic [1:0] { D_IDLE, D_AW, D_W, D_B } dstate_t;
    dstate_t               dst;
    logic [2:0]            dcnt;

    // R FIFO
    logic [63:0]           f_data [0:FIFO_D-1];
    logic                  f_last [0:FIFO_D-1];
    logic [1:0]            f_resp [0:FIFO_D-1];
    logic [ID_WIDTH-1:0]   f_id   [0:FIFO_D-1];
    logic [1:0]            f_wp, f_rp;
    logic [2:0]            f_cnt;
    logic                  f_push, f_pop;
    logic [63:0]           f_in_data;
    logic                  f_in_last;
    logic [1:0]            f_in_resp;

    logic [1:0]            b_resp;                   // the answer of a part write

    //-----------------------------------------------------------------
    // accepting a transaction
    //-----------------------------------------------------------------
    logic acc_ar, acc_aw;
    // a read only when no beat of the last one is still waiting (M_CMP
    // pushes its first beat without asking)
    always_comb begin
        acc_ar = 1'b0;
        acc_aw = 1'b0;
        if (st == M_IDLE) begin
            if (s_axi4_arvalid && (f_cnt == 3'd0) && !(s_axi4_awvalid && rr_aw))
                acc_ar = 1'b1;
            else if (s_axi4_awvalid)
                acc_aw = 1'b1;
        end
    end
    assign s_axi4_arready = acc_ar;
    assign s_axi4_awready = acc_aw;

    // the hit and the victim, from the tag read of the accept cycle
    logic [WAYS-1:0]     hit_vec;
    logic                hit_any;
    logic [WAY_BITS-1:0] hit_way, vic_way, inv_way;
    logic                inv_any;
    logic [PL_BITS-1:0]  plru_cur;
    always_comb begin
        hit_way = '0;
        inv_way = '0;
        inv_any = 1'b0;
        for (int w = 0; w < WAYS; w++)
            hit_vec[w] = t_rd_valid[w] && (t_rd_tag[w*TAG_BITS +: TAG_BITS] == cur_tag);
        hit_any = |hit_vec;
        for (int w = WAYS - 1; w >= 0; w--) begin
            if (hit_vec[w])     hit_way = WAY_BITS'(w);
            if (!t_rd_valid[w]) begin inv_way = WAY_BITS'(w); inv_any = 1'b1; end
        end
        plru_cur = plru_mem[cur_idx];
        if (inv_any)                  vic_way = inv_way;
        else if (WAYS == 1)           vic_way = '0;
        else if (REPLACE_RANDOM != 0) vic_way = lfsr[WAY_BITS-1:0];
        else                      vic_way = plru_victim(plru_cur);
    end

    // the data of the way in hand, as the array returns it
    logic [63:0] rd_way_data;
    assign rd_way_data = d_rd_data[way*64 +: 64];

    //-----------------------------------------------------------------
    // array ports
    //-----------------------------------------------------------------
    logic iss_now;                                    // a streaming / copy read this cycle
    logic cmp_iss;                                    // a hit's second word, read while comparing
    assign cmp_iss = (st == M_CMP) && !cur_write && hit_any && (cur_len != 8'd0);
    always_comb begin
        iss_now = cmp_iss;
        if (iss_left != 4'd0) begin
            if (st == M_RHIT)  iss_now = ((f_cnt + 3'(rd_pend)) < 3'(FIFO_D));
            if (st == M_VCOPY) iss_now = 1'b1;
        end
    end

    always_comb begin
        // tag read at accept, tag write at init / compare / fill / line write
        t_rd_en     = acc_ar | acc_aw;
        t_rd_index  = acc_ar ? s_axi4_araddr[OFF_BITS +: IDX_BITS]
                             : s_axi4_awaddr[OFF_BITS +: IDX_BITS];
        t_wr_way_en = '0;
        t_wr_index  = cur_idx;
        t_wr_tag    = cur_tag;
        t_wr_valid  = 1'b1;
        t_wr_dirty  = 1'b1;

        d_rd_en     = 1'b0;
        d_rd_addr   = {cur_idx, iss_word};
        d_wr_en     = 1'b0;
        d_wr_way    = way;
        d_wr_addr   = {cur_idx, wcnt};
        d_wr_data   = s_axi4_wdata;
        d_wr_strb   = s_axi4_wstrb;

        case (st)
            M_INIT: begin
                t_wr_way_en = '1;
                t_wr_index  = init_idx;
                t_wr_valid  = 1'b0;
                t_wr_dirty  = 1'b0;
            end
            M_IDLE: begin
                // the first word of a read, with its tag
                d_rd_en   = acc_ar;
                d_rd_addr = {s_axi4_araddr[OFF_BITS +: IDX_BITS], s_axi4_araddr[5:3]};
            end
            M_CMP: begin
                // a line write that hits: the line is dirty from now on
                if (cur_write && cur_line && hit_any)
                    t_wr_way_en[hit_way] = 1'b1;
                // a read that hits: its second word (the first is out now)
                d_rd_en   = cmp_iss;
                d_rd_addr = {cur_idx, cur_word + 3'd1};
            end
            M_RHIT, M_VCOPY: begin
                d_rd_en = iss_now;
            end
            M_FILL: begin
                d_wr_en   = m_axi4_rvalid & m_axi4_rready;
                d_wr_addr = {cur_idx, wcnt};
                d_wr_data = m_axi4_rdata;
                d_wr_strb = 8'hff;
                if (m_axi4_rvalid && m_axi4_rready && m_axi4_rlast) begin
                    t_wr_way_en[way] = 1'b1;
                    t_wr_valid       = !(fill_err || (m_axi4_rresp != 2'b00));
                    t_wr_dirty       = 1'b0;
                end
            end
            M_WLINE: begin
                d_wr_en = s_axi4_wvalid;                 // s_axi4_wready is 1 here
                if (s_axi4_wvalid && s_axi4_wlast && !cur_hit)
                    t_wr_way_en[way] = 1'b1;             // the new line, dirty
            end
            M_PW_W: begin
                // a part write that hits also goes into the line
                d_wr_en   = s_axi4_wvalid & m_axi4_wready & cur_hit;
                d_wr_addr = {cur_idx, cur_word + wcnt};
            end
            default: ;
        endcase
    end

    //-----------------------------------------------------------------
    // R FIFO towards the slave
    //-----------------------------------------------------------------
    assign f_pop          = s_axi4_rvalid & s_axi4_rready;
    assign s_axi4_rvalid  = (f_cnt != 3'd0);
    assign s_axi4_rdata   = f_data[f_rp];
    assign s_axi4_rlast   = f_last[f_rp];
    assign s_axi4_rresp   = f_resp[f_rp];
    assign s_axi4_rid     = f_id[f_rp];

    // what goes into it this cycle
    logic [3:0] last_beat;                            // index of the last beat in the line
    assign last_beat = 4'(cur_word) + 4'(cur_len);
    always_comb begin
        f_push    = 1'b0;
        f_in_data = rd_way_data;
        f_in_resp = 2'b00;
        f_in_last = 1'b0;
        case (st)
            M_CMP: begin
                // first beat of a read hit
                f_push    = !cur_write && hit_any;
                f_in_data = d_rd_data[hit_way*64 +: 64];
                f_in_last = (cur_len == 8'd0);
            end
            M_RHIT: begin
                f_push    = rd_pend;
                f_in_last = (4'(pend_word) == last_beat);
            end
            M_FILL: begin
                // the beats the slave asked for, as they come
                f_push    = m_axi4_rvalid && m_axi4_rready &&
                            (wcnt >= cur_word) && (4'(wcnt) <= last_beat);
                f_in_data = m_axi4_rdata;
                f_in_resp = m_axi4_rresp;
                f_in_last = (4'(wcnt) == last_beat);
            end
            default: ;
        endcase
    end

    //-----------------------------------------------------------------
    // B towards the slave, W from it
    //-----------------------------------------------------------------
    assign s_axi4_bvalid = (st == M_BRESP);
    assign s_axi4_bid    = cur_id;
    assign s_axi4_bresp  = b_resp;
    assign s_axi4_wready = (st == M_WLINE) | ((st == M_PW_W) & m_axi4_wready);

    //-----------------------------------------------------------------
    // master channels
    //-----------------------------------------------------------------
    logic m_arvalid_r;
    assign m_axi4_arvalid = m_arvalid_r;
    assign m_axi4_arid    = cur_id;
    assign m_axi4_araddr  = {cur_tag, cur_idx, {OFF_BITS{1'b0}}};
    assign m_axi4_arlen   = 8'd7;
    assign m_axi4_arsize  = 3'd3;
    assign m_axi4_arburst = 2'b01;
    assign m_axi4_arlock  = 1'b0;
    assign m_axi4_arcache = 4'b0011;
    assign m_axi4_arprot  = 3'b000;
    assign m_axi4_arqos   = 4'd0;
    // after a dirty victim's copy only (the copy reads the words the fill writes)
    assign m_axi4_rready  = (st == M_FILL) && (f_cnt < 3'(FIFO_D));

    // AW / W / B : the write out of the evict buffer, or a part write passed
    // through (never both: a part write waits for an empty buffer)
    logic drain_on;
    assign drain_on = (dst != D_IDLE);
    always_comb begin
        m_axi4_awlock  = 1'b0;
        m_axi4_awcache = 4'b0011;
        m_axi4_awprot  = 3'b000;
        m_axi4_awqos   = 4'd0;
        if (drain_on) begin
            m_axi4_awid    = DRAIN_ID;
            m_axi4_awaddr  = eb_addr;
            m_axi4_awlen   = 8'd7;
            m_axi4_awsize  = 3'd3;
            m_axi4_awburst = 2'b01;
            m_axi4_awvalid = (dst == D_AW);
            m_axi4_wdata   = eb_data[dcnt];
            m_axi4_wstrb   = 8'hff;
            m_axi4_wlast   = (dcnt == 3'd7);
            m_axi4_wvalid  = (dst == D_W);
            m_axi4_bready  = (dst == D_B);
        end else begin
            m_axi4_awid    = cur_id;
            m_axi4_awaddr  = cur_addr;
            m_axi4_awlen   = cur_len;
            m_axi4_awsize  = cur_size;
            m_axi4_awburst = cur_burst;
            m_axi4_awvalid = (st == M_PW_AW);
            m_axi4_wdata   = s_axi4_wdata;
            m_axi4_wstrb   = s_axi4_wstrb;
            m_axi4_wlast   = s_axi4_wlast;
            m_axi4_wvalid  = (st == M_PW_W) & s_axi4_wvalid;
            m_axi4_bready  = (st == M_PW_B);
        end
    end

    //-----------------------------------------------------------------
    // PMU
    //-----------------------------------------------------------------
    assign ev_read = acc_ar;
    assign ev_miss = (st == M_CMP) && !cur_write && !hit_any;

    //-----------------------------------------------------------------
    // the main state machine
    //-----------------------------------------------------------------
    // what M_WAIT waits for: an empty evict buffer (always, for a read miss
    // or a part write; for a line write that misses, only with a dirty
    // victim). cmp_* : the same, worked out in M_CMP
    logic need_buf;
    logic cmp_vdirty, cmp_need;
    assign cmp_vdirty = t_rd_valid[vic_way] && t_rd_dirty[vic_way];
    assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= M_INIT;
            init_idx  <= '0;
            rr_aw     <= 1'b0;
            cur_write <= 1'b0;
            cur_line  <= 1'b0;
            cur_id    <= '0;
            cur_addr  <= '0;
            cur_len   <= '0;
            cur_size  <= '0;
            cur_burst <= '0;
            cur_idx   <= '0;
            cur_tag   <= '0;
            cur_word  <= '0;
            cur_hit   <= 1'b0;
            way       <= '0;
            vic_dirty <= 1'b0;
            vic_tag   <= '0;
            fill_err  <= 1'b0;
            need_buf  <= 1'b0;
            iss_word  <= '0;
            iss_left  <= '0;
            rd_pend   <= 1'b0;
            pend_word <= '0;
            wcnt      <= '0;
            b_resp    <= 2'b00;
            m_arvalid_r <= 1'b0;
            lfsr      <= 8'h5a;
            eb_valid  <= 1'b0;
            eb_addr   <= '0;
            for (int i = 0; i < 8; i++) eb_data[i] <= 64'd0;
        end else begin
            rd_pend   <= iss_now;
            pend_word <= cmp_iss ? cur_word + 3'd1 : iss_word;
            if (m_axi4_arvalid && m_axi4_arready) m_arvalid_r <= 1'b0;

            case (st)
                M_INIT: begin
                    init_idx <= init_idx + 1'b1;
                    if (init_idx == IDX_BITS'(SETS - 1)) st <= M_IDLE;
                end

                M_IDLE: begin
                    if (acc_ar || acc_aw) begin
                        rr_aw     <= acc_ar;
                        cur_write <= acc_aw;
                        cur_id    <= acc_ar ? s_axi4_arid    : s_axi4_awid;
                        cur_addr  <= acc_ar ? s_axi4_araddr  : s_axi4_awaddr;
                        cur_len   <= acc_ar ? s_axi4_arlen   : s_axi4_awlen;
                        cur_size  <= acc_ar ? s_axi4_arsize  : s_axi4_awsize;
                        cur_burst <= acc_ar ? s_axi4_arburst : s_axi4_awburst;
                        cur_idx   <= t_rd_index;
                        cur_tag   <= acc_ar ? s_axi4_araddr[ADDR_WIDTH-1 -: TAG_BITS]
                                            : s_axi4_awaddr[ADDR_WIDTH-1 -: TAG_BITS];
                        cur_word  <= acc_ar ? s_axi4_araddr[5:3] : s_axi4_awaddr[5:3];
                        cur_line  <= acc_aw && (s_axi4_awlen == 8'd7) &&
                                     (s_axi4_awaddr[5:3] == 3'd0);
                        st        <= M_CMP;
                    end
                end

                M_CMP: begin
                    cur_hit   <= hit_any;
                    way       <= hit_any ? hit_way : vic_way;
                    vic_dirty <= !hit_any && cmp_vdirty;
                    vic_tag   <= t_rd_tag[vic_way*TAG_BITS +: TAG_BITS];
                    fill_err  <= 1'b0;
                    wcnt      <= '0;
                    if (!hit_any && (REPLACE_RANDOM != 0)) lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
                    if (!cur_write) begin
                        if (hit_any) begin
                            // first beat pushed now, the second read now;
                            // the rest is streamed
                            iss_word <= cur_word + 3'd2;
                            iss_left <= (cur_len == 8'd0) ? 4'd0 : 4'(cur_len) - 4'd1;
                            st       <= (cur_len == 8'd0) ? M_IDLE : M_RHIT;
                        end
                    end else if (cur_line && hit_any) begin
                        st <= M_WLINE;
                    end
                    // a miss or a part write: on at once when the evict buffer
                    // is not in the way (as M_WAIT would, one cycle earlier)
                    if ((!cur_write && !hit_any) || (cur_write && !(cur_line && hit_any))) begin
                        need_buf <= cmp_need;
                        if (cmp_need && eb_valid) begin
                            st <= M_WAIT;
                        end else if (cur_write && !cur_line) begin
                            st <= M_PW_AW;
                        end else begin
                            if (cmp_vdirty) begin
                                iss_word <= 3'd0;
                                iss_left <= 4'd8;
                                st       <= M_VCOPY;
                            end else begin
                                st       <= cur_write ? M_WLINE : M_FILL;
                            end
                            if (!cur_write) m_arvalid_r <= 1'b1;
                        end
                    end
                end

                M_RHIT: begin
                    if (iss_now) begin
                        iss_word <= iss_word + 3'd1;
                        iss_left <= iss_left - 4'd1;
                    end
                    if (rd_pend && (4'(pend_word) == last_beat)) st <= M_IDLE;
                end

                M_WAIT: begin
                    if (!need_buf || !eb_valid) begin
                        if (!cur_write || cur_line) begin
                            // a miss: a dirty victim is copied out first
                            if (vic_dirty) begin
                                iss_word <= 3'd0;
                                iss_left <= 4'd8;
                                st       <= M_VCOPY;
                            end else begin
                                st       <= cur_write ? M_WLINE : M_FILL;
                            end
                            if (!cur_write) m_arvalid_r <= 1'b1;   // the fill, early
                        end else begin
                            st <= M_PW_AW;
                        end
                    end
                end

                M_VCOPY: begin
                    if (iss_now) begin
                        iss_word <= iss_word + 3'd1;
                        iss_left <= iss_left - 4'd1;
                    end
                    if (rd_pend) begin
                        eb_data[pend_word] <= rd_way_data;
                        if (pend_word == 3'd7) begin
                            eb_valid <= 1'b1;
                            eb_addr  <= {vic_tag, cur_idx, {OFF_BITS{1'b0}}};
                            st       <= cur_write ? M_WLINE : M_FILL;
                        end
                    end
                end

                M_FILL: begin
                    if (m_axi4_rvalid && m_axi4_rready) begin
                        wcnt <= wcnt + 3'd1;
                        if (m_axi4_rresp != 2'b00) fill_err <= 1'b1;
                        if (m_axi4_rlast) st <= M_IDLE;
                    end
                end

                M_WLINE: begin
                    if (s_axi4_wvalid) begin
                        wcnt <= wcnt + 3'd1;
                        if (s_axi4_wlast) begin
                            b_resp <= 2'b00;
                            st     <= M_BRESP;
                        end
                    end
                end

                M_PW_AW: begin
                    if (m_axi4_awready) st <= M_PW_W;
                end

                M_PW_W: begin
                    if (s_axi4_wvalid && m_axi4_wready) begin
                        wcnt <= wcnt + 3'd1;
                        if (s_axi4_wlast) st <= M_PW_B;
                    end
                end

                M_PW_B: begin
                    if (m_axi4_bvalid) begin
                        b_resp <= m_axi4_bresp;
                        st     <= M_BRESP;
                    end
                end

                M_BRESP: begin
                    if (s_axi4_bready) st <= M_IDLE;
                end

                default: st <= M_IDLE;
            endcase

            // the write out of the evict buffer is done
            if ((dst == D_B) && m_axi4_bvalid) eb_valid <= 1'b0;
        end
    end

    //-----------------------------------------------------------------
    // pseudo LRU: the way used is touched on a hit (not by a part write),
    // at the end of a fill, and at the end of a line write that allocated.
    // A process of its own, without reset, so that it is LUT RAM
    //-----------------------------------------------------------------
    logic                plru_we;
    logic [WAY_BITS-1:0] plru_way;
    always_comb begin
        plru_we  = 1'b0;
        plru_way = way;
        case (st)
            M_CMP: begin
                plru_we  = hit_any && !(cur_write && !cur_line);
                plru_way = hit_way;
            end
            M_FILL:  plru_we = m_axi4_rvalid && m_axi4_rready && m_axi4_rlast;
            M_WLINE: plru_we = s_axi4_wvalid && s_axi4_wlast && !cur_hit;
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (plru_we && (WAYS > 1)) plru_mem[cur_idx] <= plru_touch(plru_cur, plru_way);
    end

    //-----------------------------------------------------------------
    // write out of the evict buffer
    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dst  <= D_IDLE;
            dcnt <= '0;
        end else begin
            case (dst)
                D_IDLE: if (eb_valid && (st != M_PW_W) && (st != M_PW_B) && (st != M_PW_AW)) begin
                            dcnt <= '0;
                            dst  <= D_AW;
                        end
                D_AW:   if (m_axi4_awready) dst <= D_W;
                D_W:    if (m_axi4_wready) begin
                            dcnt <= dcnt + 3'd1;
                            if (dcnt == 3'd7) dst <= D_B;
                        end
                D_B:    if (m_axi4_bvalid) dst <= D_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // R FIFO
    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_wp  <= '0;
            f_rp  <= '0;
            f_cnt <= '0;
            for (int i = 0; i < FIFO_D; i++) begin
                f_data[i] <= 64'd0;
                f_last[i] <= 1'b0;
                f_resp[i] <= 2'b00;
                f_id[i]   <= '0;
            end
        end else begin
            if (f_push) begin
                f_data[f_wp] <= f_in_data;
                f_last[f_wp] <= f_in_last;
                f_resp[f_wp] <= f_in_resp;
                f_id[f_wp]   <= cur_id;
                f_wp         <= f_wp + 2'd1;
            end
            if (f_pop) f_rp <= f_rp + 2'd1;
            f_cnt <= f_cnt + 3'(f_push) - 3'(f_pop);
        end
    end

endmodule : CPU_L2
