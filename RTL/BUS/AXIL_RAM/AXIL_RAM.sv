//---------------------------------------------------------------------------
// AXIL_RAM.sv
//
// Synthesizable AXI4-Lite slave RAM (64-bit data).
//
//   - WSTRB selects the bytes written (little endian)
//   - Address range [BASE_ADDR, BASE_ADDR + DEPTH*8). Access outside the
//     range returns DECERR (write ignored, read data 0).
//   - Independent write and read paths
//   - Read latency: two cycles from AR handshake to RVALID
//   - The block RAM address / write enable pins are driven only by local
//     registers with synchronous reset (Xilinx REQP-1839). A write is
//     committed one cycle after the AW/W handshake.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXIL_RAM
    #(
        parameter int ADDR_WIDTH = 32,
        parameter int DEPTH      = 512,                  // words (power of 2)
        parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = 32'h1200_0000
    )
    (
        input  logic                  clk,
        input  logic                  rst_n,

        input  logic [ADDR_WIDTH-1:0] awaddr,
        input  logic [2:0]            awprot,
        input  logic                  awvalid,
        output logic                  awready,

        input  logic [63:0]           wdata,
        input  logic [7:0]            wstrb,
        input  logic                  wvalid,
        output logic                  wready,

        output logic [1:0]            bresp,
        output logic                  bvalid,
        input  logic                  bready,

        input  logic [ADDR_WIDTH-1:0] araddr,
        input  logic [2:0]            arprot,
        input  logic                  arvalid,
        output logic                  arready,

        output logic [63:0]           rdata,
        output logic [1:0]            rresp,
        output logic                  rvalid,
        input  logic                  rready
    );

    localparam int IDX_BITS = $clog2(DEPTH);
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    logic [63:0] mem [0:DEPTH-1];
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

    //-----------------------------------------------------------------
    // Write path : AW and W are accepted together
    //-----------------------------------------------------------------
    // Simulation-only stall (see AXI4_RAM)
`ifndef SYNTHESIS
    logic sim_stall = 1'b0;
`else
    localparam logic sim_stall = 1'b0;
`endif

    logic w_go;
    assign w_go    = awvalid & wvalid & ~bvalid & ~sim_stall;
    assign awready = w_go;
    assign wready  = w_go;

    // write stage register
    logic                we_q;
    logic [IDX_BITS-1:0] widx_q;
    logic [7:0]          wstrb_q;
    logic [63:0]         wdata_q;

    always_ff @(posedge clk) begin
        if (!rst_n)
            we_q <= 1'b0;
        else
            we_q <= w_go & in_range(awaddr);
        widx_q  <= idx_of(awaddr);
        wstrb_q <= wstrb;
        wdata_q <= wdata;
    end

    always_ff @(posedge clk) begin
        for (int b = 0; b < 8; b++) begin
            if (we_q && wstrb_q[b])
                mem[widx_q][8*b +: 8] <= wdata_q[8*b +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bvalid <= 1'b0;
            bresp  <= RESP_OKAY;
        end else if (w_go) begin
            bvalid <= 1'b1;
            bresp  <= in_range(awaddr) ? RESP_OKAY : RESP_DECERR;
        end else if (bready) begin
            bvalid <= 1'b0;
        end
    end

    //-----------------------------------------------------------------
    // Read path : AR handshake -> address register -> RAM read -> RVALID
    //-----------------------------------------------------------------
    logic                r_pend;
    logic                r_hit;
    logic [IDX_BITS-1:0] ridx_q;
    logic [63:0]         mem_q;

    assign arready = ~rvalid & ~r_pend & ~sim_stall;
    assign rdata   = r_hit ? mem_q : 64'd0;

    always_ff @(posedge clk) begin
        if (arvalid && arready)
            ridx_q <= idx_of(araddr);
    end

    always_ff @(posedge clk) begin
        if (r_pend)
            mem_q <= mem[ridx_q];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r_pend <= 1'b0;
            rvalid <= 1'b0;
            rresp  <= RESP_OKAY;
            r_hit  <= 1'b0;
        end else if (arvalid && arready) begin
            r_pend <= 1'b1;
            r_hit  <= in_range(araddr);
            rresp  <= in_range(araddr) ? RESP_OKAY : RESP_DECERR;
        end else if (r_pend) begin
            r_pend <= 1'b0;
            rvalid <= 1'b1;
        end else if (rready) begin
            rvalid <= 1'b0;
        end
    end

endmodule : AXIL_RAM
