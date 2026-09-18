//---------------------------------------------------------------------------
// AXI4_RAM.sv
//
// Synthesizable AXI4 slave RAM (block RAM, simple dual port).
//
//   - INCR bursts up to 256 beats, narrow transfers (AxSIZE < 3)
//   - WSTRB selects the bytes written (little endian, 64-bit data)
//   - Address range [BASE_ADDR, BASE_ADDR + DEPTH*8). Beats outside the range
//     are not written / read as 0, and the transaction returns DECERR.
//   - Independent write and read paths (one transaction each at a time)
//   - Read latency: one cycle from address to RVALID
//   - The block RAM address / write enable pins are driven only by local
//     registers with synchronous reset (Xilinx REQP-1839: RAMB control pins
//     must not come from asynchronously reset registers). Writes are
//     committed one cycle after the W handshake, before BVALID is seen.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXI4_RAM
    #(
        parameter int ID_WIDTH   = 4,
        parameter int ADDR_WIDTH = 32,
        parameter int DEPTH      = 8192,                 // words (power of 2)
        parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = 32'h8000_0000
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        input  logic [ID_WIDTH-1:0]   awid,
        input  logic [ADDR_WIDTH-1:0] awaddr,
        input  logic [7:0]            awlen,
        input  logic [2:0]            awsize,
        input  logic [1:0]            awburst,
        input  logic                  awlock,
        input  logic [3:0]            awcache,
        input  logic [2:0]            awprot,
        input  logic [3:0]            awqos,
        input  logic                  awvalid,
        output logic                  awready,

        input  logic [63:0]           wdata,
        input  logic [7:0]            wstrb,
        input  logic                  wlast,
        input  logic                  wvalid,
        output logic                  wready,

        output logic [ID_WIDTH-1:0]   bid,
        output logic [1:0]            bresp,
        output logic                  bvalid,
        input  logic                  bready,

        input  logic [ID_WIDTH-1:0]   arid,
        input  logic [ADDR_WIDTH-1:0] araddr,
        input  logic [7:0]            arlen,
        input  logic [2:0]            arsize,
        input  logic [1:0]            arburst,
        input  logic                  arlock,
        input  logic [3:0]            arcache,
        input  logic [2:0]            arprot,
        input  logic [3:0]            arqos,
        input  logic                  arvalid,
        output logic                  arready,

        output logic [ID_WIDTH-1:0]   rid,
        output logic [63:0]           rdata,
        output logic [1:0]            rresp,
        output logic                  rlast,
        output logic                  rvalid,
        input  logic                  rready
    );

    localparam int IDX_BITS = $clog2(DEPTH);
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    //-----------------------------------------------------------------
    // Memory
    //-----------------------------------------------------------------
    (* ram_style = "block" *) logic [63:0] mem [0:DEPTH-1];
    initial for (int i = 0; i < DEPTH; i++) mem[i] = 64'd0;

    function automatic logic in_range(input logic [ADDR_WIDTH-1:0] a);
        logic [ADDR_WIDTH-1:0] off;
        off = a - BASE_ADDR;
        return (a >= BASE_ADDR) && ({3'b000, off[ADDR_WIDTH-1:3]} < ADDR_WIDTH'(DEPTH));
    endfunction

    function automatic logic [IDX_BITS-1:0] idx_of(input logic [ADDR_WIDTH-1:0] a);
        logic [ADDR_WIDTH-1:0] off;
        off = a - BASE_ADDR;
        return off[IDX_BITS+2:3];
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] next_addr
        (input logic [ADDR_WIDTH-1:0] a, input logic [2:0] size);
        logic [ADDR_WIDTH-1:0] nb;
        nb = ADDR_WIDTH'(1) << size;
        return (a & ~(nb - 1'b1)) + nb;
    endfunction

    //-----------------------------------------------------------------
    // Write path
    //-----------------------------------------------------------------
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} w_state_t;
    w_state_t              w_state;
    logic [ADDR_WIDTH-1:0] w_addr;
    logic [2:0]            w_size;
    logic                  w_err;

    logic                  mem_we;
    logic [7:0]            mem_wstrb;
    logic [IDX_BITS-1:0]   mem_widx;
    logic [63:0]           mem_wdata;

    //-----------------------------------------------------------------
    // Simulation-only stall (testbench sets sim_stall through a hierarchical
    // reference). Only AWREADY / ARREADY are withheld, which is a legal slave
    // stall. Not present in synthesis.
    //-----------------------------------------------------------------
`ifndef SYNTHESIS
    logic sim_stall = 1'b0;
`else
    localparam logic sim_stall = 1'b0;
`endif

    assign awready   = (w_state == W_IDLE) & ~sim_stall;
    assign wready    = (w_state == W_DATA);
    assign bvalid    = (w_state == W_RESP);
    assign bresp     = w_err ? RESP_DECERR : RESP_OKAY;

    // write stage register (no asynchronous reset on the RAM pins)
    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_we <= 1'b0;
        else
            mem_we <= wvalid & wready & in_range(w_addr);
        mem_wstrb <= wstrb;
        mem_widx  <= idx_of(w_addr);
        mem_wdata <= wdata;
    end

    always_ff @(posedge clk) begin
        for (int b = 0; b < 8; b++) begin
            if (mem_we && mem_wstrb[b])
                mem[mem_widx][8*b +: 8] <= mem_wdata[8*b +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_state <= W_IDLE;
            w_addr  <= '0;
            w_size  <= 3'd3;
            w_err   <= 1'b0;
            bid     <= '0;
        end else begin
            case (w_state)
                W_IDLE: if (awvalid && awready) begin
                    bid     <= awid;
                    w_addr  <= awaddr;
                    w_size  <= awsize;
                    w_err   <= 1'b0;
                    w_state <= W_DATA;
                end
                W_DATA: if (wvalid) begin
                    if (!in_range(w_addr)) w_err <= 1'b1;
                    w_addr <= next_addr(w_addr, w_size);
                    if (wlast) w_state <= W_RESP;
                end
                W_RESP: if (bready) w_state <= W_IDLE;
                default: w_state <= W_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // Read path
    //-----------------------------------------------------------------
    typedef enum logic [1:0] {R_IDLE, R_ADDR, R_DATA} r_state_t;
    r_state_t              r_state;
    logic [ADDR_WIDTH-1:0] r_addr;
    logic [2:0]            r_size;
    logic [7:0]            r_cnt;
    logic [7:0]            r_len;
    logic                  r_err;
    logic                  r_hit;
    logic [63:0]           mem_q;

    assign arready = (r_state == R_IDLE) & ~sim_stall;
    assign rvalid  = (r_state == R_DATA);
    assign rdata   = r_hit ? mem_q : 64'd0;
    assign rresp   = r_err ? RESP_DECERR : RESP_OKAY;
    assign rlast   = (r_cnt == r_len);

    always_ff @(posedge clk) begin
        if (r_state == R_ADDR)
            mem_q <= mem[idx_of(r_addr)];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r_state <= R_IDLE;
            r_addr  <= '0;
            r_size  <= 3'd3;
            r_cnt   <= 8'd0;
            r_len   <= 8'd0;
            r_err   <= 1'b0;
            r_hit   <= 1'b0;
            rid     <= '0;
        end else begin
            case (r_state)
                R_IDLE: if (arvalid && arready) begin
                    rid     <= arid;
                    r_addr  <= araddr;
                    r_size  <= arsize;
                    r_len   <= arlen;
                    r_cnt   <= 8'd0;
                    r_state <= R_ADDR;
                end
                R_ADDR: begin
                    r_hit   <= in_range(r_addr);
                    r_err   <= ~in_range(r_addr);
                    r_state <= R_DATA;
                end
                R_DATA: if (rready) begin
                    if (rlast) begin
                        r_state <= R_IDLE;
                    end else begin
                        r_cnt   <= r_cnt + 8'd1;
                        r_addr  <= next_addr(r_addr, r_size);
                        r_state <= R_ADDR;
                    end
                end
                default: r_state <= R_IDLE;
            endcase
        end
    end

endmodule : AXI4_RAM
