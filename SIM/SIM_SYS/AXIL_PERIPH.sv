//---------------------------------------------------------------------------
// AXIL_PERIPH.sv
//
// The peripheral side of the system bench: a small memory in a window, and
// DECERR for everything outside it.
//
//   AXIL_SLAVE_MEM answers every address it is given, folding it into its
//   array. That is what SIM_CPU wants, because it checks that an aliased
//   address is left untouched. A program, though, has to be able to tell a
//   region that exists from one that does not: t07_trap loads from an
//   address nothing answers and expects an access fault. So this model
//   decodes, and an address outside its window comes back DECERR.
//
//   One transfer at a time in each direction, which is all AXI4-Lite from a
//   cache ever asks for.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXIL_PERIPH
    #(
        parameter int ADDR_WIDTH = 40,
        parameter int DATA_WIDTH = 64,
        parameter int DEPTH      = 512,
        parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = 40'h00_1200_0000
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        input  logic [ADDR_WIDTH-1:0]   awaddr,
        input  logic [2:0]              awprot,
        input  logic                    awvalid,
        output logic                    awready,
        input  logic [DATA_WIDTH-1:0]   wdata,
        input  logic [DATA_WIDTH/8-1:0] wstrb,
        input  logic                    wvalid,
        output logic                    wready,
        output logic [1:0]              bresp,
        output logic                    bvalid,
        input  logic                    bready,
        input  logic [ADDR_WIDTH-1:0]   araddr,
        input  logic [2:0]              arprot,
        input  logic                    arvalid,
        output logic                    arready,
        output logic [DATA_WIDTH-1:0]   rdata,
        output logic [1:0]              rresp,
        output logic                    rvalid,
        input  logic                    rready
    );

    localparam int BYTES      = DATA_WIDTH / 8;
    localparam int WORD_SHIFT = $clog2(BYTES);
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    logic stall_en;
    initial stall_en = 1'b0;

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    function automatic bit in_range(input logic [ADDR_WIDTH-1:0] a);
        return (a >= BASE_ADDR) &&
               (a <  BASE_ADDR + ADDR_WIDTH'(DEPTH * BYTES));
    endfunction

    function automatic int idx_of(input logic [ADDR_WIDTH-1:0] a);
        return int'((a - BASE_ADDR) >> WORD_SHIFT);
    endfunction

    //-----------------------------------------------------------------
    // write
    //-----------------------------------------------------------------
    logic                  aw_got, w_got;
    logic [ADDR_WIDTH-1:0] aw_addr;
    logic [DATA_WIDTH-1:0] w_data;
    logic [BYTES-1:0]      w_strb;

    assign awready = ~aw_got & ~bvalid & (~stall_en | ($urandom_range(3) != 0));
    assign wready  = ~w_got  & ~bvalid & (~stall_en | ($urandom_range(3) != 0));

    //-----------------------------------------------------------------
    // read
    //-----------------------------------------------------------------
    assign arready = ~rvalid & (~stall_en | ($urandom_range(3) != 0));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_got  <= 1'b0;
            w_got   <= 1'b0;
            aw_addr <= '0;
            w_data  <= '0;
            w_strb  <= '0;
            bvalid  <= 1'b0;
            bresp   <= RESP_OKAY;
            rvalid  <= 1'b0;
            rresp   <= RESP_OKAY;
            rdata   <= '0;
        end else begin
            if (awvalid && awready) begin
                aw_got  <= 1'b1;
                aw_addr <= awaddr;
            end
            if (wvalid && wready) begin
                w_got  <= 1'b1;
                w_data <= wdata;
                w_strb <= wstrb;
            end

            if (aw_got && w_got && !bvalid) begin
                if (in_range(aw_addr)) begin
                    for (int b = 0; b < BYTES; b++)
                        if (w_strb[b])
                            mem[idx_of(aw_addr)][8*b +: 8] <= w_data[8*b +: 8];
                    bresp <= RESP_OKAY;
                end else begin
                    bresp <= RESP_DECERR;
                end
                bvalid <= 1'b1;
                aw_got <= 1'b0;
                w_got  <= 1'b0;
            end else if (bvalid && bready) begin
                bvalid <= 1'b0;
            end

            if (arvalid && arready) begin
                if (in_range(araddr)) begin
                    rdata <= mem[idx_of(araddr)];
                    rresp <= RESP_OKAY;
                end else begin
                    rdata <= '0;
                    rresp <= RESP_DECERR;
                end
                rvalid <= 1'b1;
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

endmodule : AXIL_PERIPH
