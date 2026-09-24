//---------------------------------------------------------------------------
// DMA_CACHE.sv
//
// A DMA port for the SoC, through the data cache (CPU_CACHE_SPEC.md 4.8).
//
//   Masters outside the CPU (the SD card of LiteX, for one) write and read
//   main memory through this AXI4-Lite slave, and every access goes to the
//   data cache on its second port, the one the debug module uses. So what a
//   DMA master sees is what the CPU sees, and the other way round, without
//   any cache maintenance by software:
//
//     write : CMD_STWTHR - write through, no allocate. Memory always gets
//             the value, and a line the CPU has in the cache is updated in
//             the cache as well (and not made dirty).
//     read  : CMD_LOAD   - a line the CPU has left dirty gives its dirty
//             value; a miss fills the line.
//
//   Linux treats DMA as coherent unless a device tree says otherwise, and
//   its LiteX SD card driver relies on it. Without this port the SD card
//   wrote straight to memory behind the data cache.
//
//   An address below MEM_BASE is not cached by the data cache, which then
//   passes the access on to its peripheral bus: a DMA to the SRAM of the
//   LiteX BIOS works the same way.
//
//   One transfer at a time, a write before a read. A write whose strobes are
//   not one naturally aligned byte, half, word or double word is split into
//   as many such pieces as it takes, lowest first. A read always reads the
//   whole double word.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DMA_CACHE
    #(
        parameter int ADDR_WIDTH = 40
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        // AXI4-Lite slave, 64 bit data
        input  logic [ADDR_WIDTH-1:0] s_awaddr,
        input  logic                  s_awvalid,
        output logic                  s_awready,
        input  logic [63:0]           s_wdata,
        input  logic [7:0]            s_wstrb,
        input  logic                  s_wvalid,
        output logic                  s_wready,
        output logic [1:0]            s_bresp,
        output logic                  s_bvalid,
        input  logic                  s_bready,
        input  logic [ADDR_WIDTH-1:0] s_araddr,
        input  logic                  s_arvalid,
        output logic                  s_arready,
        output logic [63:0]           s_rdata,
        output logic [1:0]            s_rresp,
        output logic                  s_rvalid,
        input  logic                  s_rready,

        // data cache port
        output logic                  dc_req_valid,
        input  logic                  dc_req_ready,
        output logic [ADDR_WIDTH-1:0] dc_req_addr,
        output logic [1:0]            dc_req_size,
        output logic [3:0]            dc_req_cmd,
        output logic [63:0]           dc_req_wdata,
        // physical addresses already, and held until the next request: the
        // cache wants the tag in the cycle after it took the request
        output logic [ADDR_WIDTH-1:0] dc_req_paddr,
        input  logic                  dc_resp_valid,
        input  logic [63:0]           dc_resp_data,
        input  logic                  dc_resp_error
    );

    localparam logic [3:0] CMD_LOAD   = 4'd0;
    localparam logic [3:0] CMD_STWTHR = 4'd15;
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    typedef enum logic [2:0] {S_IDLE, S_WREQ, S_WRESP, S_B, S_RREQ, S_RRESP, S_R} state_t;
    state_t state;

    logic                  aw_got, w_got;
    logic [ADDR_WIDTH-1:0] aw_q, ar_q;
    logic [63:0]           w_q;
    logic [7:0]            left;          // strobes still to be written
    logic                  err;

    assign s_awready = (state == S_IDLE) & ~aw_got;
    assign s_wready  = (state == S_IDLE) & ~w_got;
    assign s_arready = (state == S_IDLE) & ~(aw_got | w_got | s_awvalid | s_wvalid);
    assign s_bvalid  = (state == S_B);
    assign s_bresp   = err ? RESP_SLVERR : RESP_OKAY;
    assign s_rvalid  = (state == S_R);

    //-----------------------------------------------------------------
    // the next piece of a write : the lowest strobe that is left, and the
    // biggest naturally aligned size that is all strobed from there
    //-----------------------------------------------------------------
    logic [2:0] p_off;
    logic [1:0] p_size;
    logic [7:0] p_mask;

    always @(*) begin
        p_off = 3'd0;
        for (int b = 7; b >= 0; b--)
            if (left[b]) p_off = 3'(b);
        p_size = 2'd0;
        for (int s = 1; s <= 3; s++) begin
            logic [7:0] m;
            m = 8'(((1 << (1 << s)) - 1) << p_off);
            if ((int'(p_off) % (1 << s) == 0) && (int'(p_off) + (1 << s) <= 8) &&
                ((left & m) == m))
                p_size = 2'(s);
        end
        p_mask = 8'(((1 << (1 << p_size)) - 1) << p_off);
    end

    //-----------------------------------------------------------------
    assign dc_req_valid = (state == S_WREQ) | (state == S_RREQ);
    assign dc_req_cmd   = (state == S_WREQ) ? CMD_STWTHR : CMD_LOAD;
    assign dc_req_size  = (state == S_WREQ) ? p_size : 2'd3;
    // the data of a store is right aligned; the cache puts it in its lane
    assign dc_req_wdata = w_q >> (8 * int'(p_off));

    always @(*) begin
        if (state == S_WREQ)      dc_req_addr = {aw_q[ADDR_WIDTH-1:3], p_off};
        else                      dc_req_addr = {ar_q[ADDR_WIDTH-1:3], 3'b000};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            aw_got       <= 1'b0;
            w_got        <= 1'b0;
            aw_q         <= '0;
            ar_q         <= '0;
            w_q          <= 64'd0;
            left         <= 8'd0;
            err          <= 1'b0;
            s_rdata      <= 64'd0;
            s_rresp      <= RESP_OKAY;
            dc_req_paddr <= '0;
        end else begin
            if (dc_req_valid && dc_req_ready) dc_req_paddr <= dc_req_addr;

            case (state)
                S_IDLE: begin
                    if (s_awvalid && s_awready) begin aw_got <= 1'b1; aw_q <= s_awaddr; end
                    if (s_wvalid  && s_wready)  begin
                        w_got <= 1'b1; w_q <= s_wdata; left <= s_wstrb;
                    end
                    if (aw_got && w_got) begin
                        aw_got <= 1'b0;
                        w_got  <= 1'b0;
                        err    <= 1'b0;
                        state  <= (left == 8'd0) ? S_B : S_WREQ;
                    end else if (s_arvalid && s_arready) begin
                        ar_q  <= s_araddr;
                        state <= S_RREQ;
                    end
                end
                S_WREQ: if (dc_req_ready) begin
                    left  <= left & ~p_mask;
                    state <= S_WRESP;
                end
                S_WRESP: if (dc_resp_valid) begin
                    if (dc_resp_error) err <= 1'b1;
                    state <= (left == 8'd0) ? S_B : S_WREQ;
                end
                S_B: if (s_bready) state <= S_IDLE;
                S_RREQ: if (dc_req_ready) state <= S_RRESP;
                S_RRESP: if (dc_resp_valid) begin
                    s_rdata <= dc_resp_data;
                    s_rresp <= dc_resp_error ? RESP_SLVERR : RESP_OKAY;
                    state   <= S_R;
                end
                S_R: if (s_rready) state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule : DMA_CACHE
