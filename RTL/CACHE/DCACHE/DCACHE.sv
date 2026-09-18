//---------------------------------------------------------------------------
// DCACHE.sv
//
// mmRISC-2 L1 data cache (RTL/CACHE/CACHE_SPEC.md).
//
//   - Physically indexed / tagged, set associative, write back + write
//     allocate.
//   - Cacheable region (addr >= MEM_BASE) uses the arrays and the AXI4 memory
//     bus; below MEM_BASE the access is passed to the AXI4-Lite peripheral
//     bus and nothing is cached.
//   - MSHR (NUM_MSHR entries) hold the lines being filled so that load misses
//     do not block the pipeline:
//       * a load miss allocates an MSHR (or attaches to the one that already
//         covers the line) and takes its data from the fill beats;
//       * a store miss allocates an MSHR and attaches the store, which is
//         merged into the line while it is filled. The line is then locked
//         and further requests to it wait for the fill;
//       * AMO / LR / SC that miss wait for the line and are executed again.
//   - Writeback buffers (NUM_WB entries) hold evicted dirty lines.
//   - Responses come back in request order through a small reorder buffer.
//
// Array ports: one read and one write port each. Priorities are
//   read  : flush walk > victim copy > pipeline
//   write : fill beat  > store / AMO / SC in stage 1
// A write in the cycle a read is issued is forwarded to stage 1 (fwd_*),
// because the arrays return the old value in that case.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DCACHE
    #(
        parameter int          PADDR_WIDTH    = 40,
        parameter int          XLEN           = 64,
        parameter logic [39:0] MEM_BASE       = 40'h00_8000_0000,
        parameter int          SETS           = 64,
        parameter int          WAYS           = 4,
        parameter int          BLOCK_BYTES    = 64,
        parameter int          NUM_MSHR       = 2,
        parameter int          NUM_WB         = 2,
        parameter int          ROB_DEPTH      = 8,
        parameter int          REPLACE_RANDOM = 0,
        parameter int          AXI4_ID_WIDTH  = 4,
        parameter logic [3:0]  AXI4_ID_FILL   = 4'd3,
        parameter logic [3:0]  AXI4_ID_WB     = 4'd4
    )
    (
        input  logic                     clk,
        input  logic                     rst_n,

        // CPU side
        input  logic                     d_req_valid,
        output logic                     d_req_ready,
        input  logic [PADDR_WIDTH-1:0]   d_req_addr,
        input  logic [1:0]               d_req_size,
        input  logic [3:0]               d_req_cmd,
        input  logic [XLEN-1:0]          d_req_wdata,
        output logic                     d_resp_valid,
        output logic [XLEN-1:0]          d_resp_data,
        output logic                     d_resp_error,

        // memory bus : AXI4
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_awid,
        output logic [PADDR_WIDTH-1:0]   m_axi4_awaddr,
        output logic [7:0]               m_axi4_awlen,
        output logic [2:0]               m_axi4_awsize,
        output logic [1:0]               m_axi4_awburst,
        output logic                     m_axi4_awvalid,
        input  logic                     m_axi4_awready,
        output logic [63:0]              m_axi4_wdata,
        output logic [7:0]               m_axi4_wstrb,
        output logic                     m_axi4_wlast,
        output logic                     m_axi4_wvalid,
        input  logic                     m_axi4_wready,
        input  logic [1:0]               m_axi4_bresp,
        input  logic                     m_axi4_bvalid,
        output logic                     m_axi4_bready,
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_arid,
        output logic [PADDR_WIDTH-1:0]   m_axi4_araddr,
        output logic [7:0]               m_axi4_arlen,
        output logic [2:0]               m_axi4_arsize,
        output logic [1:0]               m_axi4_arburst,
        output logic                     m_axi4_arvalid,
        input  logic                     m_axi4_arready,
        input  logic [63:0]              m_axi4_rdata,
        input  logic [1:0]               m_axi4_rresp,
        input  logic                     m_axi4_rlast,
        input  logic                     m_axi4_rvalid,
        output logic                     m_axi4_rready,

        // peripheral bus : AXI4-Lite (uncached)
        output logic [PADDR_WIDTH-1:0]   m_axil_awaddr,
        output logic                     m_axil_awvalid,
        input  logic                     m_axil_awready,
        output logic [63:0]              m_axil_wdata,
        output logic [7:0]               m_axil_wstrb,
        output logic                     m_axil_wvalid,
        input  logic                     m_axil_wready,
        input  logic [1:0]               m_axil_bresp,
        input  logic                     m_axil_bvalid,
        output logic                     m_axil_bready,
        output logic [PADDR_WIDTH-1:0]   m_axil_araddr,
        output logic                     m_axil_arvalid,
        input  logic                     m_axil_arready,
        input  logic [63:0]              m_axil_rdata,
        input  logic [1:0]               m_axil_rresp,
        input  logic                     m_axil_rvalid,
        output logic                     m_axil_rready
    );

    //=================================================================
    // Commands
    //=================================================================
    localparam logic [3:0] CMD_LOAD   = 4'd0;
    localparam logic [3:0] CMD_STORE  = 4'd1;
    localparam logic [3:0] CMD_LR     = 4'd2;
    localparam logic [3:0] CMD_SC     = 4'd3;
    localparam logic [3:0] CMD_AMO_LO = 4'd4;
    localparam logic [3:0] CMD_AMO_HI = 4'd12;
    localparam logic [3:0] CMD_FENCE  = 4'd13;
    localparam logic [3:0] CMD_FLUSH  = 4'd14;

    //=================================================================
    // Geometry
    //=================================================================
    localparam int WORDS_PER_BLOCK = BLOCK_BYTES / 8;
    localparam int OFF_BITS        = $clog2(BLOCK_BYTES);
    localparam int WOFF_BITS       = $clog2(WORDS_PER_BLOCK);
    localparam int IDX_BITS        = $clog2(SETS);
    localparam int TAG_BITS        = PADDR_WIDTH - OFF_BITS - IDX_BITS;
    localparam int WAY_BITS        = $clog2(WAYS);
    localparam int DADDR_BITS      = $clog2(SETS * WORDS_PER_BLOCK);
    localparam int ROB_BITS        = $clog2(ROB_DEPTH);
    localparam int MSHR_BITS       = (NUM_MSHR > 1) ? $clog2(NUM_MSHR) : 1;
    localparam int WB_BITS         = (NUM_WB   > 1) ? $clog2(NUM_WB)   : 1;
    localparam int LINE_BITS       = PADDR_WIDTH - OFF_BITS;

    function automatic logic [TAG_BITS-1:0]  addr_tag  (input logic [PADDR_WIDTH-1:0] a);
        return a[PADDR_WIDTH-1 -: TAG_BITS];
    endfunction
    function automatic logic [IDX_BITS-1:0]  addr_index(input logic [PADDR_WIDTH-1:0] a);
        return a[OFF_BITS +: IDX_BITS];
    endfunction
    function automatic logic [WOFF_BITS-1:0] addr_woff (input logic [PADDR_WIDTH-1:0] a);
        return a[3 +: WOFF_BITS];
    endfunction
    function automatic logic [LINE_BITS-1:0] addr_line (input logic [PADDR_WIDTH-1:0] a);
        return a[PADDR_WIDTH-1:OFF_BITS];
    endfunction

    function automatic logic [7:0] size_strb(input logic [2:0] lsb, input logic [1:0] size);
        logic [7:0] m;
        m = '0;
        for (int b = 0; b < 8; b++)
            if (b >= int'(lsb) && b < int'(lsb) + (1 << size)) m[b] = 1'b1;
        return m;
    endfunction

    function automatic logic [63:0] align_wdata(input logic [2:0] lsb, input logic [63:0] d);
        return d << (8 * int'(lsb));
    endfunction

    function automatic logic [63:0] extract(input logic [63:0] word, input logic [2:0] lsb,
                                            input logic [1:0] size);
        logic [63:0] v;
        v = word >> (8 * int'(lsb));
        case (size)
            2'd0:    return {56'd0, v[7:0]};
            2'd1:    return {48'd0, v[15:0]};
            2'd2:    return {32'd0, v[31:0]};
            default: return v;
        endcase
    endfunction

    function automatic logic [63:0] merge_bytes(input logic [63:0] base, input logic [63:0] ov,
                                                input logic [7:0] strb);
        logic [63:0] r;
        r = base;
        for (int b = 0; b < 8; b++) if (strb[b]) r[8*b +: 8] = ov[8*b +: 8];
        return r;
    endfunction

    function automatic logic [63:0] amo_calc(input logic [3:0] cmd, input logic [1:0] size,
                                             input logic [63:0] old_v, input logic [63:0] src);
        logic signed [63:0] so, ss;
        logic [63:0] o, s;
        if (size == 2'd2) begin
            o  = {32'd0, old_v[31:0]};
            s  = {32'd0, src[31:0]};
            so = {{32{old_v[31]}}, old_v[31:0]};
            ss = {{32{src[31]}},   src[31:0]};
        end else begin
            o  = old_v;  s  = src;
            so = old_v;  ss = src;
        end
        case (cmd)
            4'd4:    return s;
            4'd5:    return o + s;
            4'd6:    return o ^ s;
            4'd7:    return o & s;
            4'd8:    return o | s;
            4'd9:    return (so < ss) ? o : s;
            4'd10:   return (so < ss) ? s : o;
            4'd11:   return (o  < s)  ? o : s;
            default: return (o  < s)  ? s : o;
        endcase
    endfunction

    function automatic logic [WAY_BITS-1:0] onehot_to_bin(input logic [WAYS-1:0] oh);
        logic [WAY_BITS-1:0] r;
        r = '0;
        for (int w = 0; w < WAYS; w++) if (oh[w]) r = WAY_BITS'(w);
        return r;
    endfunction

    //=================================================================
    // State declarations
    //=================================================================
    typedef enum logic [2:0] {F_IDLE, F_WB_READ, F_WB_WAIT, F_WB_PUSH, F_AR, F_DATA} f_state_t;
    typedef enum logic [1:0] {W_IDLE, W_ADDR, W_DATA, W_RESP} w_state_t;
    typedef enum logic [2:0] {U_IDLE, U_AR, U_R, U_AW, U_B} u_state_t;
    typedef enum logic [2:0] {FL_IDLE, FL_TAG, FL_LOOK, FL_READ, FL_WAIT, FL_PUSH, FL_INV,
                              FL_DRAIN} fl_state_t;

    f_state_t              f_state;
    w_state_t              w_state;
    u_state_t              u_state;
    fl_state_t             fl_state;

    logic [WOFF_BITS-1:0]  f_beat, f_wb_word, w_beat, fl_word;
    logic                  f_err;
    logic [63:0]           f_wb_buf [0:WORDS_PER_BLOCK-1];
    logic [63:0]           fl_buf   [0:WORDS_PER_BLOCK-1];
    logic [WAY_BITS-1:0]   f_wb_way;
    logic [IDX_BITS-1:0]   fl_index;
    logic [WAY_BITS-1:0]   fl_way;
    logic [ROB_BITS-1:0]   fl_rob;
    logic [ROB_BITS-1:0]   u_rob;
    logic [2:0]            u_lsb;
    logic [1:0]            u_size;

    // stage 1
    logic                    s1_valid, s1_cacheable, s1_data_ok, s1_reread, s1_wait_fill;
    logic [PADDR_WIDTH-1:0]  s1_addr;
    logic [1:0]              s1_size;
    logic [3:0]              s1_cmd;
    logic [63:0]             s1_wdata;
    logic [ROB_BITS-1:0]     s1_rob;

    //=================================================================
    // Arrays
    //=================================================================
    logic                     tag_rd_en;
    logic [IDX_BITS-1:0]      tag_rd_index;
    logic [WAYS*TAG_BITS-1:0] tag_rd_tag;
    logic [WAYS-1:0]          tag_rd_valid, tag_rd_dirty;
    logic                     tag_wr_en;
    logic [IDX_BITS-1:0]      tag_wr_index;
    logic [WAY_BITS-1:0]      tag_wr_way;
    logic [TAG_BITS-1:0]      tag_wr_tag;
    logic                     tag_wr_valid, tag_wr_dirty;
    logic [WAYS-1:0]          tag_sc_valid, tag_sc_dirty;

    CACHE_TAG_ARRAY #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS)) u_tag
        (
            .clk(clk), .rst_n(rst_n),
            .rd_en(tag_rd_en), .rd_index(tag_rd_index),
            .rd_tag(tag_rd_tag), .rd_valid(tag_rd_valid), .rd_dirty(tag_rd_dirty),
            .wr_en(tag_wr_en), .wr_index(tag_wr_index), .wr_way(tag_wr_way),
            .wr_tag(tag_wr_tag), .wr_valid(tag_wr_valid), .wr_dirty(tag_wr_dirty),
            .sc_index(fl_index), .sc_valid(tag_sc_valid), .sc_dirty(tag_sc_dirty),
            .inv_all(1'b0)
        );

    logic                  dat_rd_en;
    logic [DADDR_BITS-1:0] dat_rd_addr;
    logic [WAYS*64-1:0]    dat_rd_data;
    logic                  dat_wr_en;
    logic [WAY_BITS-1:0]   dat_wr_way;
    logic [DADDR_BITS-1:0] dat_wr_addr;
    logic [63:0]           dat_wr_data;
    logic [7:0]            dat_wr_strb;

    CACHE_DATA_ARRAY #(.SETS(SETS), .WAYS(WAYS), .BLOCK_BYTES(BLOCK_BYTES)) u_dat
        (
            .clk(clk),
            .rd_en(dat_rd_en), .rd_addr(dat_rd_addr), .rd_data(dat_rd_data),
            .wr_en(dat_wr_en), .wr_way(dat_wr_way), .wr_addr(dat_wr_addr),
            .wr_data(dat_wr_data), .wr_strb(dat_wr_strb)
        );

    //=================================================================
    // Reorder buffer, MSHRs, writeback buffers, reservation
    //=================================================================
    logic [ROB_DEPTH-1:0]  rob_valid, rob_done, rob_err, rob_wait, rob_st;
    logic [63:0]           rob_data  [0:ROB_DEPTH-1];
    logic [MSHR_BITS-1:0]  rob_mshr  [0:ROB_DEPTH-1];
    logic [WOFF_BITS-1:0]  rob_woff  [0:ROB_DEPTH-1];
    logic [2:0]            rob_lsb   [0:ROB_DEPTH-1];
    logic [1:0]            rob_size  [0:ROB_DEPTH-1];
    logic [ROB_BITS-1:0]   rob_head, rob_tail;
    logic [ROB_BITS:0]     rob_count;
    logic                  rob_full, rob_empty;

    assign rob_full  = ((ROB_BITS+1)'(rob_count) == (ROB_BITS+1)'(ROB_DEPTH));
    assign rob_empty = (rob_count == '0);

    logic [NUM_MSHR-1:0]   ms_valid, ms_locked, ms_wb_needed, ms_st_pending;
    logic [LINE_BITS-1:0]  ms_line   [0:NUM_MSHR-1];
    logic [WAY_BITS-1:0]   ms_way    [0:NUM_MSHR-1];
    logic [WOFF_BITS-1:0]  ms_st_woff[0:NUM_MSHR-1];
    logic [7:0]            ms_st_strb[0:NUM_MSHR-1];
    logic [63:0]           ms_st_data[0:NUM_MSHR-1];
    logic [TAG_BITS-1:0]   ms_wb_tag [0:NUM_MSHR-1];
    logic [MSHR_BITS-1:0]  ms_head, ms_tail;
    logic [MSHR_BITS:0]    ms_count;
    logic                  ms_full, ms_empty;

    assign ms_full  = ((MSHR_BITS+1)'(ms_count) == (MSHR_BITS+1)'(NUM_MSHR));
    assign ms_empty = (ms_count == '0);

    logic [NUM_WB-1:0]     wb_valid;
    logic [LINE_BITS-1:0]  wb_line [0:NUM_WB-1];
    logic [63:0]           wb_data [0:NUM_WB-1][0:WORDS_PER_BLOCK-1];
    logic [WB_BITS-1:0]    wb_head, wb_tail;
    logic [WB_BITS:0]      wb_count;
    logic                  wb_full, wb_empty;

    assign wb_full  = ((WB_BITS+1)'(wb_count) == (WB_BITS+1)'(NUM_WB));
    assign wb_empty = (wb_count == '0);

    logic                  res_valid;
    logic [LINE_BITS-1:0]  res_line;

    logic [15:0]           lfsr;

    //=================================================================
    // Array read port (flush walk > victim copy > pipeline)
    //=================================================================
    logic fl_rd_busy, f_rd_busy, array_rd_busy, fl_busy;

    assign fl_rd_busy    = (fl_state == FL_READ);
    assign f_rd_busy     = (f_state  == F_WB_READ);
    assign array_rd_busy = fl_rd_busy | f_rd_busy;
    assign fl_busy       = (fl_state != FL_IDLE);

    always_comb begin
        if (fl_rd_busy) begin
            dat_rd_en   = 1'b1;
            dat_rd_addr = {fl_index, fl_word};
        end else if (f_rd_busy) begin
            dat_rd_en   = 1'b1;
            dat_rd_addr = {ms_line[ms_head][IDX_BITS-1:0], f_wb_word};
        end else if (s1_reread) begin
            dat_rd_en   = 1'b1;
            dat_rd_addr = {addr_index(s1_addr), addr_woff(s1_addr)};
        end else begin
            dat_rd_en   = d_req_valid & d_req_ready;
            dat_rd_addr = {addr_index(d_req_addr), addr_woff(d_req_addr)};
        end
    end

    always_comb begin
        if (fl_state == FL_TAG) begin
            tag_rd_en    = 1'b1;
            tag_rd_index = fl_index;
        end else if (array_rd_busy) begin
            tag_rd_en    = 1'b0;
            tag_rd_index = fl_index;
        end else if (s1_reread) begin
            tag_rd_en    = 1'b1;
            tag_rd_index = addr_index(s1_addr);
        end else begin
            tag_rd_en    = d_req_valid & d_req_ready;
            tag_rd_index = addr_index(d_req_addr);
        end
    end

    //=================================================================
    // Write forwarding (a write in the cycle a read was issued)
    //=================================================================
    logic                  fwd_valid;
    logic [DADDR_BITS-1:0] fwd_addr;
    logic [WAY_BITS-1:0]   fwd_way;
    logic [63:0]           fwd_data;
    logic [7:0]            fwd_strb;

    //=================================================================
    // Lookup
    //=================================================================
    logic [WAYS-1:0]     hit_oh;
    logic                hit;
    logic [WAY_BITS-1:0] hit_way;
    logic [63:0]         hit_word;

    always_comb begin
        for (int w = 0; w < WAYS; w++)
            hit_oh[w] = tag_rd_valid[w] &&
                        (tag_rd_tag[w*TAG_BITS +: TAG_BITS] == addr_tag(s1_addr));
        hit     = s1_valid & s1_cacheable & s1_data_ok & (|hit_oh);
        hit_way = onehot_to_bin(hit_oh);
        hit_word = dat_rd_data[hit_way*64 +: 64];
        if (fwd_valid && (fwd_way == hit_way) &&
            (fwd_addr == {addr_index(s1_addr), addr_woff(s1_addr)}))
            hit_word = merge_bytes(hit_word, fwd_data, fwd_strb);
    end

    logic                 ms_match;
    logic [MSHR_BITS-1:0] ms_match_id;
    logic                 ms_attach_ok;   // the beat of this word is still ahead
    always_comb begin
        ms_match    = 1'b0;
        ms_match_id = '0;
        for (int m = 0; m < NUM_MSHR; m++)
            if (ms_valid[m] && (ms_line[m] == addr_line(s1_addr))) begin
                ms_match    = 1'b1;
                ms_match_id = MSHR_BITS'(m);
            end
    end

    logic [WAYS-1:0] busy_way;
    always_comb begin
        busy_way = '0;
        for (int m = 0; m < NUM_MSHR; m++)
            if (ms_valid[m] && (ms_line[m][IDX_BITS-1:0] == addr_index(s1_addr)))
                busy_way[ms_way[m]] = 1'b1;
    end

    // victim : an invalid way first, otherwise a free way chosen by the LFSR
    logic [WAY_BITS-1:0] victim_way;
    logic                victim_valid, victim_dirty, victim_avail;
    logic [TAG_BITS-1:0] victim_tag;

    always_comb begin
        logic found;
        found        = 1'b0;
        victim_way   = '0;
        victim_avail = 1'b0;
        // free way chosen by the LFSR (fallback)
        for (int w = 0; w < WAYS; w++) begin
            int cand;
            cand = (int'(lfsr[7:0]) + w) % WAYS;
            if (!busy_way[cand] && !victim_avail) begin
                victim_way   = WAY_BITS'(cand);
                victim_avail = 1'b1;
            end
        end
        // prefer an invalid way
        for (int w = WAYS-1; w >= 0; w--)
            if (!tag_rd_valid[w] && !busy_way[w] && !found) begin
                victim_way   = WAY_BITS'(w);
                victim_avail = 1'b1;
                found        = 1'b1;
            end
        victim_valid = tag_rd_valid[victim_way];
        victim_dirty = tag_rd_valid[victim_way] & tag_rd_dirty[victim_way];
        victim_tag   = tag_rd_tag[victim_way*TAG_BITS +: TAG_BITS];
    end

    //=================================================================
    // Stage 1 decode
    //=================================================================
    logic s1_is_amo, s1_is_load, s1_is_store, s1_is_lr, s1_is_sc, s1_is_fence, s1_is_flush;
    logic s1_needs_line, s1_writes, sc_ok, all_idle, fill_wr_en, fill_beat_now;

    assign s1_is_load  = (s1_cmd == CMD_LOAD);
    assign s1_is_store = (s1_cmd == CMD_STORE);
    assign s1_is_lr    = (s1_cmd == CMD_LR);
    assign s1_is_sc    = (s1_cmd == CMD_SC);
    assign s1_is_amo   = (s1_cmd >= CMD_AMO_LO) && (s1_cmd <= CMD_AMO_HI);
    assign s1_is_fence = (s1_cmd == CMD_FENCE);
    assign s1_is_flush = (s1_cmd == CMD_FLUSH);
    assign s1_needs_line = s1_is_amo | s1_is_lr | s1_is_sc;
    assign sc_ok         = res_valid && (res_line == addr_line(s1_addr));
    assign s1_writes     = s1_is_store | s1_is_amo | (s1_is_sc & sc_ok);

    assign all_idle = ms_empty && wb_empty && (f_state == F_IDLE) &&
                      (w_state == W_IDLE) && (u_state == U_IDLE);

    assign fill_beat_now = (f_state == F_DATA) && m_axi4_rvalid;
    assign fill_wr_en    = fill_beat_now && (m_axi4_rresp == 2'b00);

    // A request can only join a fill while the beat carrying its word has not
    // been written yet; otherwise it waits for the fill and is executed again.
    assign ms_attach_ok = !((ms_match_id == ms_head) && (f_state == F_DATA) &&
                            !(addr_woff(s1_addr) > f_beat));

    logic s1_can_retire, s1_busy;

    always_comb begin
        s1_can_retire = 1'b0;
        if (s1_valid && s1_data_ok) begin
            if (s1_is_fence) begin
                s1_can_retire = all_idle;
            end else if (s1_is_flush) begin
                s1_can_retire = (fl_state == FL_IDLE) && all_idle;
            end else if (!s1_cacheable) begin
                s1_can_retire = (u_state == U_IDLE);
            end else if (hit) begin
                // writing accesses need the array and the tag write port
                s1_can_retire = !(s1_writes && (fill_beat_now || fl_busy));
            end else if (s1_needs_line) begin
                s1_can_retire = 1'b0;                 // wait for the fill, then retry
            end else if (ms_match) begin
                s1_can_retire = !ms_locked[ms_match_id] && ms_attach_ok;
            end else begin
                s1_can_retire = !ms_full && victim_avail && !(victim_dirty && wb_full) &&
                                !fl_busy;
            end
        end
    end

    assign s1_busy     = s1_valid & ~s1_can_retire;
    assign d_req_ready = rst_n & ~s1_busy & ~s1_reread & ~rob_full & ~array_rd_busy & ~fl_busy;

    //=================================================================
    // Stage 1 array write (store / AMO / SC hit)
    //=================================================================
    logic                  s1_store_hit;
    logic [63:0]           s1_wr_data, amo_result;
    logic [7:0]            s1_wr_strb;
    logic [WAY_BITS-1:0]   s1_wr_way;
    logic [DADDR_BITS-1:0] s1_wr_addr;

    assign amo_result = amo_calc(s1_cmd, s1_size, extract(hit_word, s1_addr[2:0], s1_size), s1_wdata);

    always_comb begin
        s1_store_hit = 1'b0;
        s1_wr_way    = hit_way;
        s1_wr_addr   = {addr_index(s1_addr), addr_woff(s1_addr)};
        s1_wr_strb   = size_strb(s1_addr[2:0], s1_size);
        s1_wr_data   = align_wdata(s1_addr[2:0], s1_wdata);
        if (s1_valid && s1_data_ok && s1_cacheable && hit && s1_can_retire && s1_writes) begin
            s1_store_hit = 1'b1;
            if (s1_is_amo) s1_wr_data = align_wdata(s1_addr[2:0], amo_result);
        end
    end

    //=================================================================
    // Data array write port (fill beat > stage 1)
    //=================================================================
    always_comb begin
        if (fill_wr_en) begin
            dat_wr_en   = 1'b1;
            dat_wr_way  = ms_way[ms_head];
            dat_wr_addr = {ms_line[ms_head][IDX_BITS-1:0], f_beat};
            dat_wr_data = m_axi4_rdata;
            dat_wr_strb = 8'hFF;
            if (ms_st_pending[ms_head] && (ms_st_woff[ms_head] == f_beat))
                dat_wr_data = merge_bytes(m_axi4_rdata, ms_st_data[ms_head], ms_st_strb[ms_head]);
        end else begin
            dat_wr_en   = s1_store_hit;
            dat_wr_way  = s1_wr_way;
            dat_wr_addr = s1_wr_addr;
            dat_wr_data = s1_wr_data;
            dat_wr_strb = s1_wr_strb;
        end
    end

    //=================================================================
    // Tag write port (fill completion > flush invalidate > store hit)
    //=================================================================
    always_comb begin
        tag_wr_en    = 1'b0;
        tag_wr_index = addr_index(s1_addr);
        tag_wr_way   = hit_way;
        tag_wr_tag   = addr_tag(s1_addr);
        tag_wr_valid = 1'b1;
        tag_wr_dirty = 1'b1;
        if (fill_beat_now && m_axi4_rlast) begin
            tag_wr_en    = 1'b1;
            tag_wr_index = ms_line[ms_head][IDX_BITS-1:0];
            tag_wr_way   = ms_way[ms_head];
            tag_wr_tag   = ms_line[ms_head][LINE_BITS-1:IDX_BITS];
            tag_wr_valid = !(f_err || (m_axi4_rresp != 2'b00));
            tag_wr_dirty = ms_st_pending[ms_head] && !(f_err || (m_axi4_rresp != 2'b00));
        end else if (fl_state == FL_INV) begin
            tag_wr_en    = 1'b1;
            tag_wr_index = fl_index;
            tag_wr_way   = fl_way;
            tag_wr_tag   = '0;
            tag_wr_valid = 1'b0;
            tag_wr_dirty = 1'b0;
        end else if (s1_store_hit) begin
            tag_wr_en    = 1'b1;
        end
    end

    //=================================================================
    // Sequential logic
    //=================================================================
    integer i;
    // push / pop flags of this cycle. A queue can be pushed and popped in the
    // same cycle, so the counters are updated once at the end of the process
    // (two separate assignments would lose one of them).
    /* verilator lint_off BLKSEQ */
    logic rob_push, rob_pop, ms_push, ms_pop, wb_push, wb_pop;
    logic [WOFF_BITS-1:0] f_wb_word_q, fl_word_q;
    logic [WAY_BITS-1:0]  f_wb_way_q,  fl_way_q;
    logic                 f_wb_cap,    fl_cap;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid     <= 1'b0;
            s1_addr      <= '0;
            s1_size      <= 2'd0;
            s1_cmd       <= CMD_LOAD;
            s1_wdata     <= '0;
            s1_rob       <= '0;
            s1_cacheable <= 1'b0;
            s1_data_ok   <= 1'b0;
            s1_reread    <= 1'b0;
            s1_wait_fill <= 1'b0;
            rob_valid    <= '0;
            rob_done     <= '0;
            rob_err      <= '0;
            rob_wait     <= '0;
            rob_st       <= '0;
            rob_head     <= '0;
            rob_tail     <= '0;
            rob_count    <= '0;
            ms_valid     <= '0;
            ms_locked    <= '0;
            ms_wb_needed <= '0;
            ms_st_pending<= '0;
            ms_head      <= '0;
            ms_tail      <= '0;
            ms_count     <= '0;
            wb_valid     <= '0;
            wb_head      <= '0;
            wb_tail      <= '0;
            wb_count     <= '0;
            res_valid    <= 1'b0;
            res_line     <= '0;
            f_state      <= F_IDLE;
            f_beat       <= '0;
            f_wb_word    <= '0;
            f_err        <= 1'b0;
            f_wb_way     <= '0;
            w_state      <= W_IDLE;
            w_beat       <= '0;
            u_state      <= U_IDLE;
            u_rob        <= '0;
            u_lsb        <= 3'd0;
            u_size       <= 2'd0;
            fl_state     <= FL_IDLE;
            fl_index     <= '0;
            fl_way       <= '0;
            fl_word      <= '0;
            fl_rob       <= '0;
            lfsr         <= 16'hBEEF;
            fwd_valid    <= 1'b0;
            fwd_addr     <= '0;
            fwd_way      <= '0;
            fwd_data     <= '0;
            fwd_strb     <= '0;
            f_wb_cap     <= 1'b0;
            fl_cap       <= 1'b0;
            f_wb_word_q  <= '0;
            fl_word_q    <= '0;
            f_wb_way_q   <= '0;
            fl_way_q     <= '0;
            d_resp_valid <= 1'b0;
            d_resp_data  <= '0;
            d_resp_error <= 1'b0;
            m_axi4_arvalid <= 1'b0;
            m_axi4_araddr  <= '0;
            m_axi4_awvalid <= 1'b0;
            m_axi4_awaddr  <= '0;
            m_axil_arvalid <= 1'b0;
            m_axil_araddr  <= '0;
            m_axil_awvalid <= 1'b0;
            m_axil_awaddr  <= '0;
            m_axil_wvalid  <= 1'b0;
            m_axil_wdata   <= '0;
            m_axil_wstrb   <= '0;
            for (i = 0; i < ROB_DEPTH; i++) begin
                rob_data[i] <= '0;
                rob_mshr[i] <= '0;
                rob_woff[i] <= '0;
                rob_lsb[i]  <= 3'd0;
                rob_size[i] <= 2'd0;
            end
        end else begin
            lfsr         <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            d_resp_valid <= 1'b0;
            s1_reread    <= 1'b0;
            rob_push = 1'b0; rob_pop = 1'b0;
            ms_push  = 1'b0; ms_pop  = 1'b0;
            wb_push  = 1'b0; wb_pop  = 1'b0;

            // write forwarding register
            fwd_valid <= dat_wr_en;
            fwd_addr  <= dat_wr_addr;
            fwd_way   <= dat_wr_way;
            fwd_data  <= dat_wr_data;
            fwd_strb  <= dat_wr_strb;

            // line capture for victim copy / flush (array data one cycle later)
            f_wb_cap    <= f_rd_busy;
            f_wb_word_q <= f_wb_word;
            f_wb_way_q  <= f_wb_way;
            fl_cap      <= fl_rd_busy;
            fl_word_q   <= fl_word;
            fl_way_q    <= fl_way;
            if (f_wb_cap) f_wb_buf[f_wb_word_q] <= dat_rd_data[f_wb_way_q*64 +: 64];
            if (fl_cap)   fl_buf[fl_word_q]     <= dat_rd_data[fl_way_q*64 +: 64];

            //---------------------------------------------------------
            // stage 0 : accept a request
            //---------------------------------------------------------
            if (d_req_valid && d_req_ready) begin
                s1_valid     <= 1'b1;
                s1_addr      <= d_req_addr;
                s1_size      <= d_req_size;
                s1_cmd       <= d_req_cmd;
                s1_wdata     <= d_req_wdata;
                s1_cacheable <= (d_req_addr >= PADDR_WIDTH'(MEM_BASE));
                s1_data_ok   <= 1'b1;
                s1_rob       <= rob_tail;
                rob_valid[rob_tail] <= 1'b1;
                rob_done[rob_tail]  <= 1'b0;
                rob_err[rob_tail]   <= 1'b0;
                rob_wait[rob_tail]  <= 1'b0;
                rob_st[rob_tail]    <= 1'b0;
                rob_data[rob_tail]  <= '0;
                rob_lsb[rob_tail]   <= d_req_addr[2:0];
                rob_size[rob_tail]  <= d_req_size;
                rob_tail            <= rob_tail + ROB_BITS'(1);
                rob_push             = 1'b1;
            end else if (s1_valid && s1_can_retire) begin
                s1_valid   <= 1'b0;
                s1_data_ok <= 1'b0;
            end

            // the array outputs stop belonging to stage 1 when an engine
            // used the read port, or when the line arrived from memory
            if (s1_valid && !s1_can_retire) begin
                if (array_rd_busy || (fill_beat_now && m_axi4_rlast))
                    s1_data_ok <= 1'b0;
            end
            // re-read the arrays for the request kept in stage 1
            if (s1_valid && !s1_can_retire && !s1_wait_fill && !array_rd_busy && !fl_busy &&
                !(d_req_valid && d_req_ready) && !s1_reread &&
                (!s1_data_ok || (fill_beat_now && m_axi4_rlast)))
                s1_reread <= 1'b1;
            if (s1_reread)
                s1_data_ok <= 1'b1;

            //---------------------------------------------------------
            // stage 1 : execute
            //---------------------------------------------------------
            if (s1_valid && s1_data_ok && s1_can_retire) begin
                if (s1_is_fence) begin
                    rob_done[s1_rob] <= 1'b1;
                end
                else if (s1_is_flush) begin
                    fl_state  <= FL_TAG;
                    fl_index  <= '0;
                    fl_way    <= '0;
                    fl_rob    <= s1_rob;
                    res_valid <= 1'b0;
                end
                else if (!s1_cacheable) begin
                    u_rob  <= s1_rob;
                    u_lsb  <= s1_addr[2:0];
                    u_size <= s1_size;
                    if (s1_is_load) begin
                        m_axil_araddr  <= {s1_addr[PADDR_WIDTH-1:3], 3'b000};
                        m_axil_arvalid <= 1'b1;
                        u_state        <= U_AR;
                    end else if (s1_is_store) begin
                        m_axil_awaddr  <= {s1_addr[PADDR_WIDTH-1:3], 3'b000};
                        m_axil_awvalid <= 1'b1;
                        m_axil_wdata   <= align_wdata(s1_addr[2:0], s1_wdata);
                        m_axil_wstrb   <= size_strb(s1_addr[2:0], s1_size);
                        m_axil_wvalid  <= 1'b1;
                        u_state        <= U_AW;
                    end else begin
                        rob_done[s1_rob] <= 1'b1;      // atomics : not supported
                        rob_err[s1_rob]  <= 1'b1;
                    end
                end
                else if (hit) begin
                    rob_done[s1_rob] <= 1'b1;
                    if (s1_is_load | s1_is_lr | s1_is_amo)
                        rob_data[s1_rob] <= extract(hit_word, s1_addr[2:0], s1_size);
                    if (s1_is_lr) begin
                        res_valid <= 1'b1;
                        res_line  <= addr_line(s1_addr);
                    end else if (s1_is_sc) begin
                        rob_data[s1_rob] <= sc_ok ? 64'd0 : 64'd1;
                        res_valid        <= 1'b0;
                    end else if (s1_writes) begin
                        if (res_valid && (res_line == addr_line(s1_addr))) res_valid <= 1'b0;
                    end
                end
                else if (ms_match) begin
                    if (s1_is_load) begin
                        rob_wait[s1_rob] <= 1'b1;
                        rob_mshr[s1_rob] <= ms_match_id;
                        rob_woff[s1_rob] <= addr_woff(s1_addr);
                    end else begin                      // store
                        ms_st_pending[ms_match_id] <= 1'b1;
                        ms_locked[ms_match_id]     <= 1'b1;
                        ms_st_woff[ms_match_id]    <= addr_woff(s1_addr);
                        ms_st_strb[ms_match_id]    <= size_strb(s1_addr[2:0], s1_size);
                        ms_st_data[ms_match_id]    <= align_wdata(s1_addr[2:0], s1_wdata);
                        // the response waits for the fill so that a bus error
                        // of the line can be reported to the CPU
                        rob_wait[s1_rob] <= 1'b1;
                        rob_st[s1_rob]   <= 1'b1;
                        rob_mshr[s1_rob] <= ms_match_id;
                        if (res_valid && (res_line == addr_line(s1_addr))) res_valid <= 1'b0;
                    end
                end
                else begin
                    // new MSHR
                    ms_valid[ms_tail]      <= 1'b1;
                    ms_line[ms_tail]       <= addr_line(s1_addr);
                    ms_way[ms_tail]        <= victim_way;
                    ms_wb_needed[ms_tail]  <= victim_dirty;
                    ms_wb_tag[ms_tail]     <= victim_tag;
                    ms_locked[ms_tail]     <= s1_is_store;
                    ms_st_pending[ms_tail] <= s1_is_store;
                    ms_st_woff[ms_tail]    <= addr_woff(s1_addr);
                    ms_st_strb[ms_tail]    <= size_strb(s1_addr[2:0], s1_size);
                    ms_st_data[ms_tail]    <= align_wdata(s1_addr[2:0], s1_wdata);
                    ms_tail                <= ms_tail + MSHR_BITS'(1);
                    ms_push                = 1'b1;
                    if (s1_is_load) begin
                        rob_wait[s1_rob] <= 1'b1;
                        rob_mshr[s1_rob] <= ms_tail;
                        rob_woff[s1_rob] <= addr_woff(s1_addr);
                    end else begin
                        rob_wait[s1_rob] <= 1'b1;
                        rob_st[s1_rob]   <= 1'b1;
                        rob_mshr[s1_rob] <= ms_tail;
                        if (res_valid && (res_line == addr_line(s1_addr))) res_valid <= 1'b0;
                    end
                    if (victim_valid && res_valid &&
                        (res_line == {victim_tag, addr_index(s1_addr)}))
                        res_valid <= 1'b0;
                end
            end

            // A miss that cannot be served right now waits for the line:
            //   - AMO / LR / SC always (they are executed again as a hit)
            //   - load / store when the line is already being filled but its
            //     beat has passed, or the MSHR is locked by another store
            if (s1_valid && s1_data_ok && !s1_can_retire && s1_cacheable &&
                !hit && !s1_wait_fill && !fl_busy &&
                (s1_needs_line || ms_match)) begin
                if (ms_match) begin
                    s1_wait_fill <= 1'b1;
                end else if (!ms_full && victim_avail && !(victim_dirty && wb_full)) begin
                    ms_valid[ms_tail]      <= 1'b1;
                    ms_line[ms_tail]       <= addr_line(s1_addr);
                    ms_way[ms_tail]        <= victim_way;
                    ms_wb_needed[ms_tail]  <= victim_dirty;
                    ms_wb_tag[ms_tail]     <= victim_tag;
                    ms_locked[ms_tail]     <= 1'b1;
                    ms_st_pending[ms_tail] <= 1'b0;
                    ms_tail                <= ms_tail + MSHR_BITS'(1);
                    ms_push                = 1'b1;
                    s1_wait_fill           <= 1'b1;
                    if (victim_valid && res_valid &&
                        (res_line == {victim_tag, addr_index(s1_addr)}))
                        res_valid <= 1'b0;
                end
            end

            //---------------------------------------------------------
            // fill engine
            //---------------------------------------------------------
            case (f_state)
                F_IDLE: begin
                    if (!ms_empty) begin
                        f_err  <= 1'b0;
                        f_beat <= '0;
                        if (ms_wb_needed[ms_head]) begin
                            if (!wb_full) begin
                                f_wb_word <= '0;
                                f_wb_way  <= ms_way[ms_head];
                                f_state   <= F_WB_READ;
                            end
                        end else begin
                            m_axi4_araddr  <= {ms_line[ms_head], {OFF_BITS{1'b0}}};
                            m_axi4_arvalid <= 1'b1;
                            f_state        <= F_AR;
                        end
                    end
                end
                F_WB_READ: begin
                    if (f_wb_word == WOFF_BITS'(WORDS_PER_BLOCK-1)) f_state <= F_WB_WAIT;
                    else                                            f_wb_word <= f_wb_word + WOFF_BITS'(1);
                end
                F_WB_WAIT: begin
                    f_state <= F_WB_PUSH;          // wait for the last captured word
                end
                F_WB_PUSH: begin
                    wb_valid[wb_tail] <= 1'b1;
                    wb_line[wb_tail]  <= {ms_wb_tag[ms_head], ms_line[ms_head][IDX_BITS-1:0]};
                    for (i = 0; i < WORDS_PER_BLOCK; i++)
                        wb_data[wb_tail][i] <= f_wb_buf[i];
                    wb_tail        <= wb_tail + WB_BITS'(1);
                    wb_push        = 1'b1;
                    m_axi4_araddr  <= {ms_line[ms_head], {OFF_BITS{1'b0}}};
                    m_axi4_arvalid <= 1'b1;
                    f_state        <= F_AR;
                end
                F_AR: begin
                    if (m_axi4_arvalid && m_axi4_arready) begin
                        m_axi4_arvalid <= 1'b0;
                        f_state        <= F_DATA;
                    end
                end
                F_DATA: begin
                    if (m_axi4_rvalid) begin
                        if (m_axi4_rresp != 2'b00) f_err <= 1'b1;
                        f_beat <= f_beat + WOFF_BITS'(1);
                        for (i = 0; i < ROB_DEPTH; i++) begin
                            if (rob_valid[i] && rob_wait[i] && (rob_mshr[i] == ms_head)) begin
                                if (rob_st[i]) begin
                                    // a store waits for the end of the fill
                                    if (m_axi4_rlast) begin
                                        rob_done[i] <= 1'b1;
                                        rob_wait[i] <= 1'b0;
                                        rob_err[i]  <= f_err | (m_axi4_rresp != 2'b00);
                                    end
                                end else if (rob_woff[i] == f_beat) begin
                                    rob_data[i] <= extract(m_axi4_rdata, rob_lsb[i], rob_size[i]);
                                    rob_done[i] <= 1'b1;
                                    rob_wait[i] <= 1'b0;
                                    rob_err[i]  <= (m_axi4_rresp != 2'b00);
                                end else if (m_axi4_rlast) begin
                                    // the fill ended before the word arrived
                                    rob_done[i] <= 1'b1;
                                    rob_wait[i] <= 1'b0;
                                    rob_err[i]  <= 1'b1;
                                end
                            end
                        end
                        if (m_axi4_rlast) begin
                            ms_valid[ms_head]      <= 1'b0;
                            ms_locked[ms_head]     <= 1'b0;
                            ms_st_pending[ms_head] <= 1'b0;
                            ms_head                <= ms_head + MSHR_BITS'(1);
                            ms_pop                  = 1'b1;
                            s1_wait_fill           <= 1'b0;
                            f_state                <= F_IDLE;
                        end
                    end
                end
                default: f_state <= F_IDLE;
            endcase

            //---------------------------------------------------------
            // writeback engine
            //---------------------------------------------------------
            case (w_state)
                W_IDLE: begin
                    if (!wb_empty) begin
                        m_axi4_awaddr  <= {wb_line[wb_head], {OFF_BITS{1'b0}}};
                        m_axi4_awvalid <= 1'b1;
                        w_beat         <= '0;
                        w_state        <= W_ADDR;
                    end
                end
                W_ADDR: begin
                    if (m_axi4_awvalid && m_axi4_awready) begin
                        m_axi4_awvalid <= 1'b0;
                        w_state        <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (m_axi4_wready) begin
                        if (w_beat == WOFF_BITS'(WORDS_PER_BLOCK-1)) w_state <= W_RESP;
                        else                                         w_beat  <= w_beat + WOFF_BITS'(1);
                    end
                end
                W_RESP: begin
                    if (m_axi4_bvalid) begin
                        wb_valid[wb_head] <= 1'b0;
                        wb_head           <= wb_head + WB_BITS'(1);
                        wb_pop             = 1'b1;
                        w_state           <= W_IDLE;
                    end
                end
                default: w_state <= W_IDLE;
            endcase

            //---------------------------------------------------------
            // uncached engine (AXI4-Lite)
            //---------------------------------------------------------
            case (u_state)
                U_AR: begin
                    if (m_axil_arvalid && m_axil_arready) begin
                        m_axil_arvalid <= 1'b0;
                        u_state        <= U_R;
                    end
                end
                U_R: begin
                    if (m_axil_rvalid) begin
                        rob_data[u_rob] <= extract(m_axil_rdata, u_lsb, u_size);
                        rob_err[u_rob]  <= (m_axil_rresp != 2'b00);
                        rob_done[u_rob] <= 1'b1;
                        u_state         <= U_IDLE;
                    end
                end
                U_AW: begin
                    if (m_axil_awvalid && m_axil_awready) m_axil_awvalid <= 1'b0;
                    if (m_axil_wvalid  && m_axil_wready)  m_axil_wvalid  <= 1'b0;
                    if ((!m_axil_awvalid || m_axil_awready) && (!m_axil_wvalid || m_axil_wready))
                        u_state <= U_B;
                end
                U_B: begin
                    if (m_axil_bvalid) begin
                        rob_err[u_rob]  <= (m_axil_bresp != 2'b00);
                        rob_done[u_rob] <= 1'b1;
                        u_state         <= U_IDLE;
                    end
                end
                default: ;
            endcase

            //---------------------------------------------------------
            // flush engine : write back every dirty line and invalidate
            //---------------------------------------------------------
            case (fl_state)
                FL_TAG: begin
                    fl_state <= FL_LOOK;           // tag read issued this cycle
                end
                FL_LOOK: begin
                    if (tag_sc_valid[fl_way] && tag_sc_dirty[fl_way]) begin
                        if (!wb_full) begin
                            fl_word  <= '0;
                            fl_state <= FL_READ;
                        end
                    end else if (tag_sc_valid[fl_way]) begin
                        fl_state <= FL_INV;
                    end else begin
                        if (fl_way == WAY_BITS'(WAYS-1)) begin
                            fl_way <= '0;
                            if (fl_index == IDX_BITS'(SETS-1)) begin
                                fl_state <= FL_DRAIN;
                            end else begin
                                fl_index <= fl_index + IDX_BITS'(1);
                                fl_state <= FL_TAG;
                            end
                        end else begin
                            fl_way <= fl_way + WAY_BITS'(1);
                        end
                    end
                end
                FL_READ: begin
                    if (fl_word == WOFF_BITS'(WORDS_PER_BLOCK-1)) fl_state <= FL_WAIT;
                    else                                          fl_word  <= fl_word + WOFF_BITS'(1);
                end
                FL_WAIT: begin
                    fl_state <= FL_PUSH;
                end
                FL_PUSH: begin
                    wb_valid[wb_tail] <= 1'b1;
                    wb_line[wb_tail]  <= {tag_rd_tag[fl_way*TAG_BITS +: TAG_BITS], fl_index};
                    for (i = 0; i < WORDS_PER_BLOCK; i++)
                        wb_data[wb_tail][i] <= fl_buf[i];
                    wb_tail  <= wb_tail + WB_BITS'(1);
                    wb_push  = 1'b1;
                    fl_state <= FL_INV;
                end
                FL_INV: begin
                    if (fl_way == WAY_BITS'(WAYS-1)) begin
                        fl_way <= '0;
                        if (fl_index == IDX_BITS'(SETS-1)) begin
                            fl_state <= FL_DRAIN;
                        end else begin
                            fl_index <= fl_index + IDX_BITS'(1);
                            fl_state <= FL_TAG;
                        end
                    end else begin
                        fl_way   <= fl_way + WAY_BITS'(1);
                        fl_state <= FL_LOOK;
                    end
                end
                FL_DRAIN: begin
                    if (wb_empty && (w_state == W_IDLE)) begin
                        rob_done[fl_rob] <= 1'b1;
                        fl_state         <= FL_IDLE;
                    end
                end
                default: ;
            endcase

            //---------------------------------------------------------
            // response (in request order)
            //---------------------------------------------------------
            if (!rob_empty && rob_valid[rob_head] && rob_done[rob_head]) begin
                d_resp_valid        <= 1'b1;
                d_resp_data         <= rob_data[rob_head];
                d_resp_error        <= rob_err[rob_head];
                rob_valid[rob_head] <= 1'b0;
                rob_done[rob_head]  <= 1'b0;
                rob_head            <= rob_head + ROB_BITS'(1);
                rob_pop              = 1'b1;
            end

            //---------------------------------------------------------
            // queue counters (one update per queue and cycle)
            //---------------------------------------------------------
            rob_count <= rob_count + (rob_push ? 1 : 0) - (rob_pop ? 1 : 0);
            ms_count  <= ms_count  + (ms_push  ? 1 : 0) - (ms_pop  ? 1 : 0);
            wb_count  <= wb_count  + (wb_push  ? 1 : 0) - (wb_pop  ? 1 : 0);
        end
    end
    /* verilator lint_on BLKSEQ */

    //=================================================================
    // AXI fixed fields
    //=================================================================
    assign m_axi4_arid    = AXI4_ID_FILL[AXI4_ID_WIDTH-1:0];
    assign m_axi4_arlen   = 8'(WORDS_PER_BLOCK - 1);
    assign m_axi4_arsize  = 3'd3;
    assign m_axi4_arburst = 2'b01;
    assign m_axi4_rready  = (f_state == F_DATA);

    assign m_axi4_awid    = AXI4_ID_WB[AXI4_ID_WIDTH-1:0];
    assign m_axi4_awlen   = 8'(WORDS_PER_BLOCK - 1);
    assign m_axi4_awsize  = 3'd3;
    assign m_axi4_awburst = 2'b01;
    assign m_axi4_wvalid  = (w_state == W_DATA);
    assign m_axi4_wdata   = wb_data[wb_head][w_beat];
    assign m_axi4_wstrb   = 8'hFF;
    assign m_axi4_wlast   = (w_state == W_DATA) && (w_beat == WOFF_BITS'(WORDS_PER_BLOCK-1));
    assign m_axi4_bready  = (w_state == W_RESP);

    assign m_axil_rready  = (u_state == U_R);
    assign m_axil_bready  = (u_state == U_B);

endmodule : DCACHE
