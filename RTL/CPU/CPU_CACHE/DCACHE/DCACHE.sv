//---------------------------------------------------------------------------
// DCACHE.sv
//
// mmRISC-2 L1 data cache (RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md).
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
//
//   Note on coding style: the combinational blocks are written as
//   "always @(*)" instead of "always_comb". Icarus Verilog re-triggers an
//   always_comb process on every assignment to a variable that is read with a
//   variable index inside the same process, which makes the combinational
//   network of this module loop forever at one simulation time. "always @(*)"
//   uses value-change semantics and behaves identically in synthesis.
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
        // Physical address of the request. It has to be valid in the cycle
        // the request is in stage 1, which is the cycle after d_req_valid &
        // d_req_ready (CPU_CACHE_SPEC.md 5.2). The index and the offset are
        // taken from d_req_addr, only the tag comes from here, so the CPU can
        // present d_req_addr before the translation is finished (VIPT). With
        // no MMU, drive it with d_req_addr delayed by one cycle.
        input  logic [PADDR_WIDTH-1:0]   d_req_paddr,
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
    // write through, no allocate (debug port): the word always goes to memory,
    // a line that happens to be in the cache is updated but not made dirty
    localparam logic [3:0] CMD_STWTHR = 4'd15;

    //=================================================================
    // Geometry
    //=================================================================
    localparam int WORDS_PER_BLOCK = BLOCK_BYTES / 8;
    localparam int OFF_BITS        = $clog2(BLOCK_BYTES);
    localparam int WOFF_BITS       = $clog2(WORDS_PER_BLOCK);
    localparam int IDX_BITS        = $clog2(SETS);
    localparam int TAG_BITS        = PADDR_WIDTH - OFF_BITS - IDX_BITS;
    localparam int WAY_BITS        = (WAYS > 1) ? $clog2(WAYS) : 1;
    localparam int DADDR_BITS      = $clog2(SETS * WORDS_PER_BLOCK);
    localparam int ROB_BITS        = $clog2(ROB_DEPTH);
    localparam int MSHR_BITS       = (NUM_MSHR > 1) ? $clog2(NUM_MSHR) : 1;
    localparam int WB_BITS         = (NUM_WB   > 1) ? $clog2(NUM_WB)   : 1;
    localparam int LINE_BITS       = PADDR_WIDTH - OFF_BITS;

    initial begin
    // The index and the offset have to fit into the page offset, so that the
    // cache can be indexed with the virtual address while the tag is compared
    // against the physical one (CPU_CACHE_SPEC.md 3.5 and 6.4.7). The default
    // is exactly at the limit, so a bigger cache has to gain ways, not sets.
    if (SETS * BLOCK_BYTES > 4096)
        $fatal(1, "SETS * BLOCK_BYTES must not be larger than the page size (4096)");
    end

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

    // queue pointer increment (the depth is not necessarily a power of two)
    function automatic logic [MSHR_BITS-1:0] ms_next(input logic [MSHR_BITS-1:0] p);
        return (int'(p) == NUM_MSHR-1) ? '0 : p + MSHR_BITS'(1);
    endfunction
    function automatic logic [WB_BITS-1:0] wb_next(input logic [WB_BITS-1:0] p);
        return (int'(p) == NUM_WB-1) ? '0 : p + WB_BITS'(1);
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
    typedef enum logic [2:0] {F_IDLE, F_WB_READ, F_WB_WAIT, F_WB_PUSH, F_ARW, F_AR, F_DATA} f_state_t;
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
    logic                    s1_valid, s1_data_ok, s1_reread, s1_wait_fill;
    logic                    s1_ptag_v;                 // the tag has been captured
    logic [TAG_BITS-1:0]     s1_ptag_r;
    logic [TAG_BITS-1:0]     s1_ptag;                   // tag of stage 1 (live or captured)
    logic [PADDR_WIDTH-1:0]  s1_paddr;                  // full physical address of stage 1
    logic [LINE_BITS-1:0]    s1_line;                   // physical line of stage 1
    logic                    s1_cacheable;
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

    // How many entries of the writeback queue the pipeline may use. A
    // coherent version keeps one for the probe, so that an external
    // invalidate of a dirty line can always be answered even when the CPU
    // filled the queue (CPU_CACHE_SPEC.md 6.4.4): WB_CPU_LIMIT = NUM_WB - 1.
    localparam int WB_CPU_LIMIT = NUM_WB;

    assign wb_full  = ((WB_BITS+1)'(wb_count) >= (WB_BITS+1)'(WB_CPU_LIMIT));
    assign wb_empty = (wb_count == '0);

    logic                  res_valid;
    logic [LINE_BITS-1:0]  res_line;

    //-----------------------------------------------------------------
    // Single word write through (CMD_STWTHR, one outstanding)
    //-----------------------------------------------------------------
    logic                  sw_pend;     // posted by stage 1, not started yet
    logic                  w_single;    // the write engine is doing this write
    logic [PADDR_WIDTH-1:0] sw_addr;
    logic [63:0]           sw_data;
    logic [7:0]            sw_strb;
    logic [ROB_BITS-1:0]   sw_rob;
    logic                  sw_busy;

    assign sw_busy = sw_pend | w_single;

    //-----------------------------------------------------------------
    // Memory is behind a line that is still on its way out
    //
    //   An entry of the writeback queue stays valid until its write has
    //   been answered, and so does the single write through. Until then
    //   memory holds the old contents of that line, and the AXI4 read and
    //   write channels are not ordered against each other, so
    //     - a fill of the line waits (f_ar_block), or it would read the old
    //       line: a CPU miss on a line it has just evicted, or a DMA read
    //       of it through the second port;
    //     - a write through of the line waits for the writeback (the write
    //       engine takes the queue first), or the old line would be written
    //       over it: a DMA write into a page the CPU has just evicted.
    //   (CPU_CACHE_SPEC.md 4.3)
    //-----------------------------------------------------------------
    function automatic logic wb_has_line(input logic [LINE_BITS-1:0] l);
        logic r;
        r = 1'b0;
        for (int e = 0; e < NUM_WB; e++)
            if (wb_valid[e] && (wb_line[e] == l)) r = 1'b1;
        return r;
    endfunction

    logic [LINE_BITS-1:0]  sw_line;
    logic                  f_ar_block, sw_wait_wb;

    assign sw_line    = sw_addr[PADDR_WIDTH-1:OFF_BITS];
    assign f_ar_block = wb_has_line(ms_line[ms_head]) |
                        (sw_busy & (sw_line == ms_line[ms_head]));
    assign sw_wait_wb = wb_has_line(sw_line);

    logic [15:0]           lfsr;

    //=================================================================
    // Array read port (flush walk > victim copy > pipeline)
    //=================================================================
    logic fl_rd_busy, f_rd_busy, array_rd_busy, fl_busy;

    assign fl_rd_busy    = (fl_state == FL_READ);
    assign f_rd_busy     = (f_state  == F_WB_READ);
    assign array_rd_busy = fl_rd_busy | f_rd_busy;
    assign fl_busy       = (fl_state != FL_IDLE);

    //-----------------------------------------------------------------
    // Who may use the arrays (CPU_CACHE_SPEC.md 6.4.3)
    //
    //   priority   requester            read tag  read data  can be held back
    //   1          (probe, not built)   no (*)    yes        no
    //   2          fill completion      no        no         no
    //   3          flush walk           yes       yes        no, has its own
    //                                                        state machine
    //   4          pipeline stage 1     yes       yes        yes (s1_reread)
    //   5          pipeline stage 0     yes       yes        yes (d_req_ready)
    //
    //   (*) a probe would look its line up in a copy of the tag array that is
    //       written from the same tag_wr_* bundle, so it never takes the read
    //       port away from the pipeline. It does take the data read port when
    //       it has to write a dirty line back.
    //
    // Every requester below drives one *_req / *_index (or *_addr) pair; the
    // block after them is the only place that picks one. Adding the probe
    // means adding one row here, not hunting through the module.
    //-----------------------------------------------------------------
    logic                    flw_dat_req;     // flush walk, reading a line out
    logic [DADDR_BITS-1:0]   flw_dat_addr;
    logic                    fwb_dat_req;     // writeback of a victim
    logic [DADDR_BITS-1:0]   fwb_dat_addr;
    logic                    s1_dat_req;      // stage 1, reading again
    logic [DADDR_BITS-1:0]   s1_dat_addr;
    logic                    s0_dat_req;      // a new request from the CPU
    logic [DADDR_BITS-1:0]   s0_dat_addr;

    logic                    flw_tag_req;     // flush walk, tag of one set
    logic [IDX_BITS-1:0]     flw_tag_index;
    logic                    s1_tag_req;
    logic [IDX_BITS-1:0]     s1_tag_index;
    logic                    s0_tag_req;
    logic [IDX_BITS-1:0]     s0_tag_index;

    assign flw_dat_req  = fl_rd_busy;
    assign flw_dat_addr = {fl_index, fl_word};
    assign fwb_dat_req  = f_rd_busy;
    assign fwb_dat_addr = {ms_line[ms_head][IDX_BITS-1:0], f_wb_word};
    assign s1_dat_req   = s1_reread;
    assign s1_dat_addr  = {addr_index(s1_addr), addr_woff(s1_addr)};
    assign s0_dat_req   = d_req_valid & d_req_ready;
    assign s0_dat_addr  = {addr_index(d_req_addr), addr_woff(d_req_addr)};

    assign flw_tag_req   = (fl_state == FL_TAG);
    assign flw_tag_index = fl_index;
    assign s1_tag_req    = s1_reread;
    assign s1_tag_index  = addr_index(s1_addr);
    assign s0_tag_req    = d_req_valid & d_req_ready;
    assign s0_tag_index  = addr_index(d_req_addr);

    // data array, read port
    always @(*) begin
        if (flw_dat_req) begin
            dat_rd_en   = 1'b1;
            dat_rd_addr = flw_dat_addr;
        end else if (fwb_dat_req) begin
            dat_rd_en   = 1'b1;
            dat_rd_addr = fwb_dat_addr;
        end else if (s1_dat_req) begin
            dat_rd_en   = 1'b1;
            dat_rd_addr = s1_dat_addr;
        end else begin
            dat_rd_en   = s0_dat_req;
            dat_rd_addr = s0_dat_addr;
        end
    end

    // tag array, read port. While the flush walk or a writeback is reading the
    // data array the pipeline is held back anyway (array_rd_busy is part of
    // d_req_ready), so the tag port simply stays idle.
    always @(*) begin
        if (flw_tag_req) begin
            tag_rd_en    = 1'b1;
            tag_rd_index = flw_tag_index;
        end else if (array_rd_busy) begin
            tag_rd_en    = 1'b0;
            tag_rd_index = fl_index;
        end else if (s1_tag_req) begin
            tag_rd_en    = 1'b1;
            tag_rd_index = s1_tag_index;
        end else begin
            tag_rd_en    = s0_tag_req;
            tag_rd_index = s0_tag_index;
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
    // Tag forwarding
    //   The tag array (and the valid / dirty bits) return the old value when
    //   a write happens in the cycle the read is issued, so the last write is
    //   merged into the lookup result of stage 1.
    //=================================================================
    logic                     tfwd_en, tfwd_valid, tfwd_dirty;
    logic [IDX_BITS-1:0]      tfwd_index;
    logic [WAY_BITS-1:0]      tfwd_way;
    logic [TAG_BITS-1:0]      tfwd_tag;

    logic [WAYS*TAG_BITS-1:0] eff_tag;
    logic [WAYS-1:0]          eff_valid, eff_dirty;

    always @(*) begin
        eff_tag   = tag_rd_tag;
        eff_valid = tag_rd_valid;
        eff_dirty = tag_rd_dirty;
        if (tfwd_en && (tfwd_index == addr_index(s1_addr))) begin
            eff_tag[tfwd_way*TAG_BITS +: TAG_BITS] = tfwd_tag;
            eff_valid[tfwd_way]                    = tfwd_valid;
            eff_dirty[tfwd_way]                    = tfwd_dirty;
        end
    end

    //=================================================================
    // Lookup
    //=================================================================
    logic [WAYS-1:0]     hit_oh;
    logic                hit;
    logic [WAY_BITS-1:0] hit_way;
    logic [63:0]         hit_word;

    always @(*) begin
        for (int w = 0; w < WAYS; w++)
            hit_oh[w] = eff_valid[w] &&
                        (eff_tag[w*TAG_BITS +: TAG_BITS] == s1_ptag);
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
    always @(*) begin
        ms_match    = 1'b0;
        ms_match_id = '0;
        for (int m = 0; m < NUM_MSHR; m++)
            if (ms_valid[m] && (ms_line[m] == s1_line)) begin
                ms_match    = 1'b1;
                ms_match_id = MSHR_BITS'(m);
            end
    end

    // ways of this set that an in-flight MSHR is using: the tag still shows
    // the victim line while its data is being copied out and overwritten, so
    // an access that "hits" such a way has to wait for the fill
    logic [WAYS-1:0] busy_way;
    logic            hit_busy;
    always @(*) begin
        busy_way = '0;
        for (int m = 0; m < NUM_MSHR; m++)
            if (ms_valid[m] && (ms_line[m][IDX_BITS-1:0] == addr_index(s1_addr)))
                busy_way[ms_way[m]] = 1'b1;
    end

    assign hit_busy = hit && busy_way[hit_way];

    // victim : an invalid way first, otherwise a free way chosen by the LFSR
    logic [WAY_BITS-1:0] victim_way;
    logic                victim_valid, victim_dirty, victim_avail;
    logic [TAG_BITS-1:0] victim_tag;

    always @(*) begin
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
            if (!eff_valid[w] && !busy_way[w] && !found) begin
                victim_way   = WAY_BITS'(w);
                victim_avail = 1'b1;
                found        = 1'b1;
            end
        victim_valid = eff_valid[victim_way];
        victim_dirty = eff_valid[victim_way] & eff_dirty[victim_way];
        victim_tag   = eff_tag[victim_way*TAG_BITS +: TAG_BITS];
    end

    // The physical address arrives one cycle after the request, so the first
    // stage 1 cycle uses the input directly and every later cycle (re-read,
    // waiting for a fill) uses the captured value.
    assign s1_ptag     = s1_ptag_v ? s1_ptag_r : addr_tag(d_req_paddr);
    assign s1_paddr    = {s1_ptag, s1_addr[PADDR_WIDTH-TAG_BITS-1:0]};
    assign s1_line     = {s1_ptag, addr_index(s1_addr)};
    assign s1_cacheable = (s1_paddr >= PADDR_WIDTH'(MEM_BASE));

    //=================================================================
    // Stage 1 decode
    //=================================================================
    logic s1_is_amo, s1_is_load, s1_is_store, s1_is_lr, s1_is_sc, s1_is_fence, s1_is_flush;
    logic s1_is_stwthr;
    logic s1_needs_line, s1_writes, sc_ok, all_idle, fill_wr_en, fill_beat_now;

    assign s1_is_load  = (s1_cmd == CMD_LOAD);
    assign s1_is_store = (s1_cmd == CMD_STORE);
    assign s1_is_lr    = (s1_cmd == CMD_LR);
    assign s1_is_sc    = (s1_cmd == CMD_SC);
    assign s1_is_amo   = (s1_cmd >= CMD_AMO_LO) && (s1_cmd <= CMD_AMO_HI);
    assign s1_is_fence = (s1_cmd == CMD_FENCE);
    assign s1_is_flush = (s1_cmd == CMD_FLUSH);
    assign s1_is_stwthr = (s1_cmd == CMD_STWTHR);
    assign s1_needs_line = s1_is_amo | s1_is_lr | s1_is_sc;
    assign sc_ok         = res_valid && (res_line == s1_line);
    assign s1_writes     = s1_is_store | s1_is_amo | (s1_is_sc & sc_ok);

    assign all_idle = ms_empty && wb_empty && (f_state == F_IDLE) &&
                      (w_state == W_IDLE) && (u_state == U_IDLE) && !sw_pend;

    assign fill_beat_now = (f_state == F_DATA) && m_axi4_rvalid;
    assign fill_wr_en    = fill_beat_now && (m_axi4_rresp == 2'b00);

    // A request can only join a fill while the beat carrying its word has not
    // been written yet; otherwise it waits for the fill and is executed again.
    assign ms_attach_ok = !((ms_match_id == ms_head) && (f_state == F_DATA) &&
                            !(addr_woff(s1_addr) > f_beat));

    logic s1_can_retire, s1_busy;

    always @(*) begin
        s1_can_retire = 1'b0;
        if (s1_valid && s1_data_ok) begin
            if (s1_is_fence) begin
                s1_can_retire = all_idle;
            end else if (s1_is_flush) begin
                s1_can_retire = (fl_state == FL_IDLE) && all_idle;
            end else if (!s1_cacheable) begin
                s1_can_retire = (u_state == U_IDLE);
            end else if (s1_is_stwthr) begin
                // write through: the bus write slot must be free. A line that
                // is being filled has to be waited for, otherwise the fill
                // would overwrite the new value with the old memory word.
                s1_can_retire = !sw_busy && !fl_busy &&
                                (hit ? (!hit_busy && !fill_beat_now) : !ms_match);
            end else if (hit) begin
                // writing accesses need the array and the tag write port
                s1_can_retire = !hit_busy && !(s1_writes && (fill_beat_now || fl_busy));
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
    logic                  s1_store_hit, s1_thr_hit;
    logic [63:0]           s1_wr_data, amo_result;
    logic [7:0]            s1_wr_strb;
    logic [WAY_BITS-1:0]   s1_wr_way;
    logic [DADDR_BITS-1:0] s1_wr_addr;

    // An atomic operation is a naturally aligned word or double word (the
    // core traps a misaligned one before it gets here), so its lanes are
    // the whole word or one of its halves, picked by address bit 2. That is
    // one 2:1 multiplexer on each side of the arithmetic instead of the
    // byte shifters of extract and align_wdata: this path runs from the tag
    // array through the way select and the arithmetic into the data array
    // in one cycle, and was the longest of the design once the core was cut
    // (LitexSystem/docs/TIMING.md 17). For a word, amo_calc only looks at
    // the low half of what it is given, and the write strobe only lets the
    // four bytes of the word through.
    logic [63:0] amo_old, amo_wr;

    assign amo_old    = s1_addr[2] ? {32'd0, hit_word[63:32]} : hit_word;
    assign amo_result = amo_calc(s1_cmd, s1_size, amo_old, s1_wdata);
    assign amo_wr     = s1_addr[2] ? {amo_result[31:0], 32'd0} : amo_result;

    always @(*) begin
        s1_store_hit = 1'b0;
        s1_thr_hit   = 1'b0;
        s1_wr_way    = hit_way;
        s1_wr_addr   = {addr_index(s1_addr), addr_woff(s1_addr)};
        s1_wr_strb   = size_strb(s1_addr[2:0], s1_size);
        s1_wr_data   = align_wdata(s1_addr[2:0], s1_wdata);
        if (s1_valid && s1_data_ok && s1_cacheable && hit && s1_can_retire && s1_writes) begin
            s1_store_hit = 1'b1;
            if (s1_is_amo) s1_wr_data = amo_wr;
        end
        // write through hit: update the data array, leave valid / dirty alone
        if (s1_valid && s1_data_ok && s1_cacheable && hit && s1_can_retire && s1_is_stwthr)
            s1_thr_hit = 1'b1;
    end

    //=================================================================
    // Data array write port
    //
    //   priority   requester           can be held back
    //   1          fill beat           no, the bus is delivering
    //   2          pipeline stage 1    yes
    //
    // A probe never writes the data array: it reads a dirty line out and
    // invalidates it in the tag array (CPU_CACHE_SPEC.md 6.4.3).
    //=================================================================
    always @(*) begin
        if (fill_wr_en) begin
            dat_wr_en   = 1'b1;
            dat_wr_way  = ms_way[ms_head];
            dat_wr_addr = {ms_line[ms_head][IDX_BITS-1:0], f_beat};
            dat_wr_data = m_axi4_rdata;
            dat_wr_strb = 8'hFF;
            if (ms_st_pending[ms_head] && (ms_st_woff[ms_head] == f_beat))
                dat_wr_data = merge_bytes(m_axi4_rdata, ms_st_data[ms_head], ms_st_strb[ms_head]);
        end else begin
            dat_wr_en   = s1_store_hit | s1_thr_hit;
            dat_wr_way  = s1_wr_way;
            dat_wr_addr = s1_wr_addr;
            dat_wr_data = s1_wr_data;
            dat_wr_strb = s1_wr_strb;
        end
    end

    //=================================================================
    // Tag write port
    //
    //   priority   requester           writes
    //   1          (probe, not built)  valid / dirty of the probed line
    //   2          fill completion     tag + valid + dirty of the new line
    //   3          flush invalidate    valid = 0
    //   4          store hit           dirty = 1
    //
    // A copy of the tag array for the probe hit test (6.4.3) is written from
    // exactly this bundle, so it stays in step without any further logic.
    //=================================================================
    always @(*) begin
        tag_wr_en    = 1'b0;
        tag_wr_index = addr_index(s1_addr);
        tag_wr_way   = hit_way;
        tag_wr_tag   = s1_ptag;
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
            s1_ptag_v    <= 1'b0;
            s1_ptag_r    <= '0;
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
            w_single     <= 1'b0;
            sw_pend      <= 1'b0;
            sw_addr      <= '0;
            sw_data      <= '0;
            sw_strb      <= '0;
            sw_rob       <= '0;
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
            tfwd_en      <= 1'b0;
            tfwd_index   <= '0;
            tfwd_way     <= '0;
            tfwd_tag     <= '0;
            tfwd_valid   <= 1'b0;
            tfwd_dirty   <= 1'b0;
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

            // write forwarding registers (data array and tag array)
            tfwd_en    <= tag_wr_en;
            tfwd_index <= tag_wr_index;
            tfwd_way   <= tag_wr_way;
            tfwd_tag   <= tag_wr_tag;
            tfwd_valid <= tag_wr_valid;
            tfwd_dirty <= tag_wr_dirty;
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
                s1_ptag_v    <= 1'b0;        // the physical tag arrives next cycle
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

            // the physical address is valid in the first stage 1 cycle
            if (s1_valid && !s1_ptag_v && !(d_req_valid && d_req_ready)) begin
                s1_ptag_r <= addr_tag(d_req_paddr);
                s1_ptag_v <= 1'b1;
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
            // the re-read only happens when the read port is granted; an
            // engine using the port keeps the request waiting
            if (s1_reread) begin
                if (array_rd_busy) s1_reread  <= 1'b1;
                else               s1_data_ok <= 1'b1;
            end

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
                    // The address goes out exact, down to the byte, and the
                    // strobes say which lanes of the double word are meant.
                    // A slave that decodes 32 bit registers needs bit 2: the
                    // PLIC keeps two registers in one double word, and the
                    // one at +4 (claim) is read with a side effect, so an
                    // aligned address would make a read of the threshold
                    // claim an interrupt and a write to +4 miss its register
                    // (LitexSystem/docs/TIMING.md 20, the BIOS hung on it).
                    if (s1_is_load) begin
                        m_axil_araddr  <= s1_paddr;
                        m_axil_arvalid <= 1'b1;
                        u_state        <= U_AR;
                    end else if (s1_is_store || s1_is_stwthr) begin
                        m_axil_awaddr  <= s1_paddr;
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
                else if (s1_is_stwthr) begin
                    // the word goes to memory in any case; when the line is in
                    // the cache it was updated by s1_thr_hit in this cycle
                    sw_pend <= 1'b1;
                    sw_addr <= {s1_paddr[PADDR_WIDTH-1:3], 3'b000};
                    sw_data <= align_wdata(s1_addr[2:0], s1_wdata);
                    sw_strb <= size_strb(s1_addr[2:0], s1_size);
                    sw_rob  <= s1_rob;
                    rob_wait[s1_rob] <= 1'b1;
                    if (res_valid && (res_line == s1_line)) res_valid <= 1'b0;
                end
                else if (hit) begin
                    rob_done[s1_rob] <= 1'b1;
                    if (s1_is_load | s1_is_lr | s1_is_amo)
                        rob_data[s1_rob] <= extract(hit_word, s1_addr[2:0], s1_size);
                    if (s1_is_lr) begin
                        res_valid <= 1'b1;
                        res_line  <= s1_line;
                    end else if (s1_is_sc) begin
                        rob_data[s1_rob] <= sc_ok ? 64'd0 : 64'd1;
                        res_valid        <= 1'b0;
                    end else if (s1_writes) begin
                        if (res_valid && (res_line == s1_line)) res_valid <= 1'b0;
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
                        if (res_valid && (res_line == s1_line)) res_valid <= 1'b0;
                    end
                end
                else begin
                    // new MSHR
                    ms_valid[ms_tail]      <= 1'b1;
                    ms_line[ms_tail]       <= s1_line;
                    ms_way[ms_tail]        <= victim_way;
                    ms_wb_needed[ms_tail]  <= victim_dirty;
                    ms_wb_tag[ms_tail]     <= victim_tag;
                    ms_locked[ms_tail]     <= s1_is_store;
                    ms_st_pending[ms_tail] <= s1_is_store;
                    ms_st_woff[ms_tail]    <= addr_woff(s1_addr);
                    ms_st_strb[ms_tail]    <= size_strb(s1_addr[2:0], s1_size);
                    ms_st_data[ms_tail]    <= align_wdata(s1_addr[2:0], s1_wdata);
                    ms_tail                <= ms_next(ms_tail);
                    ms_push                = 1'b1;
                    if (s1_is_load) begin
                        rob_wait[s1_rob] <= 1'b1;
                        rob_mshr[s1_rob] <= ms_tail;
                        rob_woff[s1_rob] <= addr_woff(s1_addr);
                    end else begin
                        rob_wait[s1_rob] <= 1'b1;
                        rob_st[s1_rob]   <= 1'b1;
                        rob_mshr[s1_rob] <= ms_tail;
                        if (res_valid && (res_line == s1_line)) res_valid <= 1'b0;
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
                !s1_wait_fill && !fl_busy &&
                (hit_busy || (!hit && (s1_needs_line || ms_match)))) begin
                if (hit_busy) begin
                    s1_wait_fill <= 1'b1;         // the way is being replaced
                end else
                if (ms_match) begin
                    s1_wait_fill <= 1'b1;
                end else if (!ms_full && victim_avail && !(victim_dirty && wb_full)) begin
                    ms_valid[ms_tail]      <= 1'b1;
                    ms_line[ms_tail]       <= s1_line;
                    ms_way[ms_tail]        <= victim_way;
                    ms_wb_needed[ms_tail]  <= victim_dirty;
                    ms_wb_tag[ms_tail]     <= victim_tag;
                    ms_locked[ms_tail]     <= 1'b1;
                    ms_st_pending[ms_tail] <= 1'b0;
                    ms_tail                <= ms_next(ms_tail);
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
                        end else if (!f_ar_block) begin
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
                    wb_tail        <= wb_next(wb_tail);
                    wb_push        = 1'b1;
                    // the victim is another line of the set, so it does not
                    // hold this fill up; an older writeback may
                    if (!f_ar_block) begin
                        m_axi4_araddr  <= {ms_line[ms_head], {OFF_BITS{1'b0}}};
                        m_axi4_arvalid <= 1'b1;
                        f_state        <= F_AR;
                    end else begin
                        f_state        <= F_ARW;
                    end
                end
                F_ARW: begin
                    if (!f_ar_block) begin
                        m_axi4_araddr  <= {ms_line[ms_head], {OFF_BITS{1'b0}}};
                        m_axi4_arvalid <= 1'b1;
                        f_state        <= F_AR;
                    end
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
                            ms_head                <= ms_next(ms_head);
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
                    if (sw_pend && !sw_wait_wb) begin
                        m_axi4_awaddr  <= sw_addr;
                        m_axi4_awvalid <= 1'b1;
                        w_single       <= 1'b1;
                        sw_pend        <= 1'b0;
                        w_beat         <= '0;
                        w_state        <= W_ADDR;
                    end else if (!wb_empty) begin
                        m_axi4_awaddr  <= {wb_line[wb_head], {OFF_BITS{1'b0}}};
                        m_axi4_awvalid <= 1'b1;
                        w_single       <= 1'b0;
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
                        if (w_single || (w_beat == WOFF_BITS'(WORDS_PER_BLOCK-1)))
                             w_state <= W_RESP;
                        else w_beat  <= w_beat + WOFF_BITS'(1);
                    end
                end
                W_RESP: begin
                    if (m_axi4_bvalid) begin
                        if (w_single) begin
                            rob_err[sw_rob]  <= (m_axi4_bresp != 2'b00);
                            rob_wait[sw_rob] <= 1'b0;
                            rob_done[sw_rob] <= 1'b1;
                            w_single         <= 1'b0;
                        end else begin
                            wb_valid[wb_head] <= 1'b0;
                            wb_head           <= wb_next(wb_head);
                            wb_pop             = 1'b1;
                        end
                        w_state <= W_IDLE;
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
                    wb_tail  <= wb_next(wb_tail);
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
    assign m_axi4_awlen   = w_single ? 8'd0 : 8'(WORDS_PER_BLOCK - 1);
    assign m_axi4_awsize  = 3'd3;
    assign m_axi4_awburst = 2'b01;
    assign m_axi4_wvalid  = (w_state == W_DATA);
    assign m_axi4_wdata   = w_single ? sw_data : wb_data[wb_head][w_beat];
    assign m_axi4_wstrb   = w_single ? sw_strb : 8'hFF;
    assign m_axi4_wlast   = (w_state == W_DATA) &&
                            (w_single || (w_beat == WOFF_BITS'(WORDS_PER_BLOCK-1)));
    assign m_axi4_bready  = (w_state == W_RESP);

    assign m_axil_rready  = (u_state == U_R);
    assign m_axil_bready  = (u_state == U_B);

endmodule : DCACHE
