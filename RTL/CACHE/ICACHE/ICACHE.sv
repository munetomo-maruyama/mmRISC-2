//---------------------------------------------------------------------------
// ICACHE.sv
//
// mmRISC-2 L1 instruction cache (RTL/CACHE/CACHE_SPEC.md).
//
//   - Physically indexed, physically tagged, set associative, read only.
//   - Cacheable region (addr >= MEM_BASE) : line fill over AXI4, INCR burst
//     of BLOCK_BYTES/8 beats, early restart (the requested word is returned
//     as soon as its beat arrives).
//   - Uncached region (addr < MEM_BASE) : single 64-bit read over AXI4-Lite,
//     nothing is stored in the arrays (LiteX boot ROM case).
//   - One miss at a time; requests are accepted again once the fill or the
//     uncached access has finished. Hits are accepted every cycle.
//   - i_flush_valid invalidates every line in one cycle (fence.i).
//   - i_kill drops the response of the request in flight.
//   - A bus error (SLVERR/DECERR) is reported with i_resp_error and the line
//     is not cached.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module ICACHE
    #(
        parameter int          PADDR_WIDTH = 40,
        parameter logic [39:0] MEM_BASE    = 40'h00_8000_0000,
        parameter int          SETS        = 64,
        parameter int          WAYS        = 4,
        parameter int          BLOCK_BYTES = 64,
        parameter int          FETCH_WIDTH = 64,
        parameter int          REPLACE_RANDOM = 0,
        parameter int          AXI4_ID_WIDTH  = 4,
        parameter logic [3:0]  AXI4_ID        = 4'd2
    )
    (
        input  logic                        clk,
        input  logic                        rst_n,

        // CPU side
        input  logic                        i_req_valid,
        output logic                        i_req_ready,
        input  logic [PADDR_WIDTH-1:0]      i_req_addr,
        output logic                        i_resp_valid,
        output logic [FETCH_WIDTH-1:0]      i_resp_data,
        output logic                        i_resp_error,
        input  logic                        i_flush_valid,
        output logic                        i_flush_done,
        input  logic                        i_kill,

        // memory bus : AXI4 read only
        output logic [AXI4_ID_WIDTH-1:0]    m_axi4_arid,
        output logic [PADDR_WIDTH-1:0]      m_axi4_araddr,
        output logic [7:0]                  m_axi4_arlen,
        output logic [2:0]                  m_axi4_arsize,
        output logic [1:0]                  m_axi4_arburst,
        output logic                        m_axi4_arvalid,
        input  logic                        m_axi4_arready,
        input  logic [63:0]                 m_axi4_rdata,
        input  logic [1:0]                  m_axi4_rresp,
        input  logic                        m_axi4_rlast,
        input  logic                        m_axi4_rvalid,
        output logic                        m_axi4_rready,

        // peripheral bus : AXI4-Lite read only (uncached fetch)
        output logic [PADDR_WIDTH-1:0]      m_axil_araddr,
        output logic                        m_axil_arvalid,
        input  logic                        m_axil_arready,
        input  logic [63:0]                 m_axil_rdata,
        input  logic [1:0]                  m_axil_rresp,
        input  logic                        m_axil_rvalid,
        output logic                        m_axil_rready
    );

    //-----------------------------------------------------------------
    // Geometry
    //-----------------------------------------------------------------
    localparam int WORDS_PER_BLOCK = BLOCK_BYTES / 8;
    localparam int OFF_BITS        = $clog2(BLOCK_BYTES);       // byte offset in a block
    localparam int WOFF_BITS       = $clog2(WORDS_PER_BLOCK);   // word offset in a block
    localparam int IDX_BITS        = $clog2(SETS);
    localparam int TAG_BITS        = PADDR_WIDTH - OFF_BITS - IDX_BITS;
    localparam int WAY_BITS        = $clog2(WAYS);
    localparam int DADDR_BITS      = $clog2(SETS * WORDS_PER_BLOCK);

    function automatic logic [TAG_BITS-1:0]  addr_tag  (input logic [PADDR_WIDTH-1:0] a);
        return a[PADDR_WIDTH-1 -: TAG_BITS];
    endfunction
    function automatic logic [IDX_BITS-1:0]  addr_index(input logic [PADDR_WIDTH-1:0] a);
        return a[OFF_BITS +: IDX_BITS];
    endfunction
    function automatic logic [WOFF_BITS-1:0] addr_woff (input logic [PADDR_WIDTH-1:0] a);
        return a[3 +: WOFF_BITS];
    endfunction

    //-----------------------------------------------------------------
    // Arrays
    //-----------------------------------------------------------------
    logic                     tag_rd_en;
    logic [IDX_BITS-1:0]      tag_rd_index;
    logic [WAYS*TAG_BITS-1:0] tag_rd_tag;
    logic [WAYS-1:0]          tag_rd_valid;
    logic                     tag_wr_en;
    logic [IDX_BITS-1:0]      tag_wr_index;
    logic [WAY_BITS-1:0]      tag_wr_way;
    logic [TAG_BITS-1:0]      tag_wr_tag;

    CACHE_TAG_ARRAY #(.SETS(SETS), .WAYS(WAYS), .TAG_BITS(TAG_BITS)) u_tag
        (
            .clk(clk), .rst_n(rst_n),
            .rd_en(tag_rd_en), .rd_index(tag_rd_index),
            .rd_tag(tag_rd_tag), .rd_valid(tag_rd_valid), .rd_dirty(),
            .wr_en(tag_wr_en), .wr_index(tag_wr_index), .wr_way(tag_wr_way),
            .wr_tag(tag_wr_tag), .wr_valid(1'b1), .wr_dirty(1'b0),
            .sc_index('0), .sc_valid(), .sc_dirty(),
            .inv_all(i_flush_valid)
        );

    logic                     dat_rd_en;
    logic [DADDR_BITS-1:0]    dat_rd_addr;
    logic [WAYS*64-1:0]       dat_rd_data;
    logic                     dat_wr_en;
    logic [WAY_BITS-1:0]      dat_wr_way;
    logic [DADDR_BITS-1:0]    dat_wr_addr;
    logic [63:0]              dat_wr_data;

    CACHE_DATA_ARRAY #(.SETS(SETS), .WAYS(WAYS), .BLOCK_BYTES(BLOCK_BYTES)) u_dat
        (
            .clk(clk),
            .rd_en(dat_rd_en), .rd_addr(dat_rd_addr), .rd_data(dat_rd_data),
            .wr_en(dat_wr_en), .wr_way(dat_wr_way), .wr_addr(dat_wr_addr),
            .wr_data(dat_wr_data), .wr_strb(8'hFF)
        );

    //-----------------------------------------------------------------
    // Replacement
    //-----------------------------------------------------------------
    logic [15:0]         lfsr;
    logic [WAYS-1:0]     rr_way;      // round robin when not random

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr   <= 16'hACE1;
            rr_way <= {{(WAYS-1){1'b0}}, 1'b1};
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (tag_wr_en) rr_way <= {rr_way[WAYS-2:0], rr_way[WAYS-1]};
        end
    end

    function automatic logic [WAY_BITS-1:0] onehot_to_bin(input logic [WAYS-1:0] oh);
        logic [WAY_BITS-1:0] r;
        r = '0;
        for (int w = 0; w < WAYS; w++) if (oh[w]) r = WAY_BITS'(w);
        return r;
    endfunction

    //-----------------------------------------------------------------
    // Pipeline stage 1 (lookup result)
    //-----------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_FILL, S_UNC} state_t;
    state_t state;

    logic                    s1_valid;
    logic [PADDR_WIDTH-1:0]  s1_addr;
    logic                    s1_cacheable;

    logic [WAYS-1:0]         hit_way_oh;
    logic                    hit;
    logic [WAY_BITS-1:0]     hit_way;

    always_comb begin
        for (int w = 0; w < WAYS; w++)
            hit_way_oh[w] = tag_rd_valid[w] &&
                            (tag_rd_tag[w*TAG_BITS +: TAG_BITS] == addr_tag(s1_addr));
        hit     = s1_valid & s1_cacheable & (|hit_way_oh);
        hit_way = onehot_to_bin(hit_way_oh);
    end

    // fill state
    logic [PADDR_WIDTH-1:0]  fill_addr;
    logic [WAY_BITS-1:0]     fill_way;
    logic [WOFF_BITS-1:0]    fill_beat;
    logic                    fill_err;
    logic                    fill_kill;      // response no longer needed
    logic                    fill_flushed;   // fence.i happened during the fill
    logic                    fill_hold_valid;
    logic [63:0]             fill_hold_data;

    // A new request is accepted while stage 1 hits (one request per cycle).
    // When stage 1 misses, the pipeline stops until the fill has finished.
    assign i_req_ready = (state == S_IDLE) && !i_flush_valid &&
                         !(s1_valid && !hit && !i_kill);

    // array read for a new request
    assign tag_rd_en    = i_req_valid & i_req_ready;
    assign tag_rd_index = addr_index(i_req_addr);
    assign dat_rd_en    = i_req_valid & i_req_ready;
    assign dat_rd_addr  = {addr_index(i_req_addr), addr_woff(i_req_addr)};

    // response of a hit (the data array output is already registered)
    logic [63:0] hit_data;
    always_comb begin
        hit_data = dat_rd_data[hit_way*64 +: 64];
    end

    //-----------------------------------------------------------------
    // Main state machine
    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            s1_valid        <= 1'b0;
            s1_addr         <= '0;
            s1_cacheable    <= 1'b0;
            fill_addr       <= '0;
            fill_way        <= '0;
            fill_beat       <= '0;
            fill_err        <= 1'b0;
            fill_kill       <= 1'b0;
            fill_flushed    <= 1'b0;
            fill_hold_valid <= 1'b0;
            fill_hold_data  <= '0;
            i_resp_valid    <= 1'b0;
            i_resp_data     <= '0;
            i_resp_error    <= 1'b0;
            m_axi4_arvalid  <= 1'b0;
            m_axi4_araddr   <= '0;
            m_axil_arvalid  <= 1'b0;
            m_axil_araddr   <= '0;
        end else begin
            i_resp_valid <= 1'b0;
            i_resp_error <= 1'b0;

            // stage 0 -> stage 1
            if (i_req_valid && i_req_ready) begin
                s1_valid     <= 1'b1;
                s1_addr      <= i_req_addr;
                s1_cacheable <= (i_req_addr >= PADDR_WIDTH'(MEM_BASE));
            end else if (state == S_IDLE) begin
                s1_valid     <= 1'b0;
            end

            case (state)
                //-----------------------------------------------------
                S_IDLE: begin
                    if (s1_valid && i_kill) begin
                        s1_valid <= 1'b0;
                    end else if (s1_valid && hit) begin
                        i_resp_valid <= 1'b1;
                        i_resp_data  <= hit_data[FETCH_WIDTH-1:0];
                    end else if (s1_valid && s1_cacheable) begin
                        // miss : start a line fill
                        fill_addr      <= s1_addr;
                        fill_way       <= (REPLACE_RANDOM != 0) ? WAY_BITS'(lfsr[WAY_BITS-1:0])
                                                         : onehot_to_bin(rr_way);
                        fill_beat      <= '0;
                        fill_err       <= 1'b0;
                        fill_kill      <= 1'b0;
                        fill_flushed   <= 1'b0;
                        fill_hold_valid<= 1'b0;
                        m_axi4_araddr  <= {s1_addr[PADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
                        m_axi4_arvalid <= 1'b1;
                        state          <= S_FILL;
                    end else if (s1_valid) begin
                        // uncached fetch
                        fill_addr      <= s1_addr;
                        fill_kill      <= 1'b0;
                        m_axil_araddr  <= {s1_addr[PADDR_WIDTH-1:3], 3'b000};
                        m_axil_arvalid <= 1'b1;
                        state          <= S_UNC;
                    end
                end
                //-----------------------------------------------------
                S_FILL: begin
                    if (i_kill) fill_kill <= 1'b1;
                    if (m_axi4_arvalid && m_axi4_arready)
                        m_axi4_arvalid <= 1'b0;
                    if (i_flush_valid) fill_flushed <= 1'b1;
                    if (m_axi4_rvalid) begin
                        if (m_axi4_rresp != 2'b00) fill_err <= 1'b1;
                        fill_beat <= fill_beat + WOFF_BITS'(1);
                        // early restart : answer as soon as the requested
                        // word arrives, the rest of the line keeps filling
                        if ((fill_beat == addr_woff(fill_addr)) && !fill_hold_valid) begin
                            fill_hold_valid <= 1'b1;
                            if (!fill_kill && !i_kill) begin
                                i_resp_valid <= 1'b1;
                                i_resp_error <= (m_axi4_rresp != 2'b00);
                                i_resp_data  <= m_axi4_rdata[FETCH_WIDTH-1:0];
                            end
                        end
                        if (m_axi4_rlast) begin
                            state    <= S_IDLE;
                            s1_valid <= 1'b0;
                        end
                    end
                end
                //-----------------------------------------------------
                S_UNC: begin
                    if (i_kill) fill_kill <= 1'b1;
                    if (m_axil_arvalid && m_axil_arready)
                        m_axil_arvalid <= 1'b0;
                    if (m_axil_rvalid) begin
                        state    <= S_IDLE;
                        s1_valid <= 1'b0;
                        if (!fill_kill && !i_kill) begin
                            i_resp_valid <= 1'b1;
                            i_resp_error <= (m_axil_rresp != 2'b00);
                            i_resp_data  <= m_axil_rdata[FETCH_WIDTH-1:0];
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // Array writes during a fill
    //-----------------------------------------------------------------
    assign dat_wr_en   = (state == S_FILL) && m_axi4_rvalid && (m_axi4_rresp == 2'b00);
    assign dat_wr_way  = fill_way;
    assign dat_wr_addr = {addr_index(fill_addr), fill_beat};
    assign dat_wr_data = m_axi4_rdata;

    // the tag is written when the last beat arrived without error
    assign tag_wr_en    = (state == S_FILL) && m_axi4_rvalid && m_axi4_rlast &&
                          !fill_err && (m_axi4_rresp == 2'b00) &&
                          !fill_flushed && !i_flush_valid;
    assign tag_wr_index = addr_index(fill_addr);
    assign tag_wr_way   = fill_way;
    assign tag_wr_tag   = addr_tag(fill_addr);

    //-----------------------------------------------------------------
    // Fixed AXI fields
    //-----------------------------------------------------------------
    assign m_axi4_arid    = AXI4_ID[AXI4_ID_WIDTH-1:0];
    assign m_axi4_arlen   = 8'(WORDS_PER_BLOCK - 1);
    assign m_axi4_arsize  = 3'd3;
    assign m_axi4_arburst = 2'b01;                 // INCR
    assign m_axi4_rready  = (state == S_FILL);
    assign m_axil_rready  = (state == S_UNC);

    //-----------------------------------------------------------------
    // fence.i : the array is cleared in one cycle
    //-----------------------------------------------------------------
    assign i_flush_done = i_flush_valid && (state == S_IDLE);

endmodule : ICACHE
