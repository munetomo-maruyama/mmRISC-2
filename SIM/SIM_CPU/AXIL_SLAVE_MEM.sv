//---------------------------------------------------------------------------
// AXIL_SLAVE_MEM.sv
//
// Simple AXI4-Lite slave memory model for CPU_TOP verification.
//
//  - Single-beat transfers only (as per the AXI4-Lite specification)
//  - WSTRB byte enables are honoured
//  - Memory is initialised so that the content increments with the word
//    address:  mem[i] = INIT_BASE + i
//
//  Stall injection (for handshake robustness):
//    stall_en = 1 makes AWREADY / WREADY / ARREADY drop randomly and
//    inserts random idle cycles before BVALID and RVALID. VALID signals are
//    never withdrawn before their handshake. stall_en is a variable driven
//    from the testbench through a hierarchical reference.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXIL_SLAVE_MEM
    #(
        parameter int ADDR_WIDTH = 32,
        parameter int DATA_WIDTH = 64,
        parameter int DEPTH      = 512,                  // words (power of 2)
        parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = 32'h1200_0000,
        parameter logic [DATA_WIDTH-1:0] INIT_BASE = '0
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // Write Address Channel
        input  logic [ADDR_WIDTH-1:0]   awaddr,
        input  logic [2:0]              awprot,
        input  logic                    awvalid,
        output logic                    awready,

        // Write Data Channel
        input  logic [DATA_WIDTH-1:0]   wdata,
        input  logic [DATA_WIDTH/8-1:0] wstrb,
        input  logic                    wvalid,
        output logic                    wready,

        // Write Response Channel
        output logic [1:0]              bresp,
        output logic                    bvalid,
        input  logic                    bready,

        // Read Address Channel
        input  logic [ADDR_WIDTH-1:0]   araddr,
        input  logic [2:0]              arprot,
        input  logic                    arvalid,
        output logic                    arready,

        // Read Data Channel
        output logic [DATA_WIDTH-1:0]   rdata,
        output logic [1:0]              rresp,
        output logic                    rvalid,
        input  logic                    rready
    );

    localparam int BYTES      = DATA_WIDTH / 8;
    localparam int WORD_SHIFT = $clog2(BYTES);
    localparam int IDX_BITS   = $clog2(DEPTH);

    localparam logic [1:0] RESP_OKAY = 2'b00;

    //-----------------------------------------------------------------
    // Testbench-controlled variable
    //-----------------------------------------------------------------
    logic stall_en;         // 1 = inject random ready drops / valid delays

    initial begin
        stall_en = 1'b0;
    end

    //-----------------------------------------------------------------
    // Memory array
    //-----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            mem[i] = INIT_BASE + DATA_WIDTH'(i);
        end
    end

    function automatic logic [IDX_BITS-1:0] idx_of(input logic [ADDR_WIDTH-1:0] a);
        logic [ADDR_WIDTH-1:0] off;
        off    = a - BASE_ADDR;
        idx_of = off[WORD_SHIFT+IDX_BITS-1 : WORD_SHIFT];
    endfunction

    //-----------------------------------------------------------------
    // Random sources (refreshed every cycle)
    //-----------------------------------------------------------------
    logic [7:0] rnd_aw, rnd_w, rnd_b, rnd_ar, rnd_r;

    always_ff @(posedge clk) begin
        rnd_aw <= 8'($urandom);
        rnd_w  <= 8'($urandom);
        rnd_b  <= 8'($urandom);
        rnd_ar <= 8'($urandom);
        rnd_r  <= 8'($urandom);
    end

    wire aw_rdy_nx = stall_en ? (rnd_aw[1:0] != 2'b00) : 1'b1;
    wire w_rdy_nx  = stall_en ? (rnd_w[1:0]  != 2'b00) : 1'b1;
    wire ar_rdy_nx = stall_en ? (rnd_ar[1:0] != 2'b00) : 1'b1;
    wire [1:0] b_dly_nx = stall_en ? rnd_b[1:0] : 2'd0;
    wire [1:0] r_dly_nx = stall_en ? rnd_r[1:0] : 2'd0;

    //-----------------------------------------------------------------
    // Write channels
    //-----------------------------------------------------------------
    localparam logic [1:0] W_IDLE = 2'd0;
    localparam logic [1:0] W_CMT  = 2'd1;
    localparam logic [1:0] W_BDLY = 2'd2;
    localparam logic [1:0] W_RESP = 2'd3;

    logic [1:0]            wstate;
    logic [ADDR_WIDTH-1:0] waddr_r;
    logic                  aw_got;
    logic                  w_got;
    logic [DATA_WIDTH-1:0] wdata_r;
    logic [BYTES-1:0]      wstrb_r;
    logic [1:0]            wdly;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate  <= W_IDLE;
            awready <= 1'b1;
            wready  <= 1'b1;
            bvalid  <= 1'b0;
            bresp   <= RESP_OKAY;
            waddr_r <= '0;
            wdata_r <= '0;
            wstrb_r <= '0;
            aw_got  <= 1'b0;
            w_got   <= 1'b0;
            wdly    <= 2'd0;
        end
        else begin
            case (wstate)
                // Latch the address and the data; they may arrive in any
                // order and on different cycles.
                W_IDLE: begin
                    if (!aw_got) begin
                        if (awvalid && awready) begin
                            waddr_r <= awaddr;
                            aw_got  <= 1'b1;
                            awready <= 1'b0;
                        end
                        else begin
                            awready <= aw_rdy_nx;
                        end
                    end
                    if (!w_got) begin
                        if (wvalid && wready) begin
                            wdata_r <= wdata;
                            wstrb_r <= wstrb;
                            w_got   <= 1'b1;
                            wready  <= 1'b0;
                        end
                        else begin
                            wready <= w_rdy_nx;
                        end
                    end
                    if (aw_got && w_got) begin
                        wstate <= W_CMT;
                    end
                end

                // Both address and data are available -> commit to memory
                W_CMT: begin
                    for (int b = 0; b < BYTES; b++) begin
                        if (wstrb_r[b]) mem[idx_of(waddr_r)][8*b +: 8] <= wdata_r[8*b +: 8];
                    end
                    bresp  <= RESP_OKAY;
                    aw_got <= 1'b0;
                    w_got  <= 1'b0;
                    wdly   <= b_dly_nx;
                    wstate <= W_BDLY;
                end

                W_BDLY: begin
                    if (wdly == 2'd0) begin
                        bvalid <= 1'b1;
                        wstate <= W_RESP;
                    end
                    else begin
                        wdly <= wdly - 2'd1;
                    end
                end

                W_RESP: begin
                    if (bvalid && bready) begin
                        bvalid  <= 1'b0;
                        awready <= aw_rdy_nx;
                        wready  <= w_rdy_nx;
                        wstate  <= W_IDLE;
                    end
                end

                default: wstate <= W_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // Read channels
    //-----------------------------------------------------------------
    localparam logic [1:0] R_IDLE = 2'd0;
    localparam logic [1:0] R_DLY  = 2'd1;
    localparam logic [1:0] R_DATA = 2'd2;

    logic [1:0]            rstate;
    logic [ADDR_WIDTH-1:0] raddr_r;
    logic [1:0]            rdly;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate  <= R_IDLE;
            arready <= 1'b1;
            rvalid  <= 1'b0;
            rdata   <= '0;
            rresp   <= RESP_OKAY;
            raddr_r <= '0;
            rdly    <= 2'd0;
        end
        else begin
            case (rstate)
                R_IDLE: begin
                    if (arvalid && arready) begin
                        arready <= 1'b0;
                        raddr_r <= araddr;
                        rresp   <= RESP_OKAY;
                        rdly    <= r_dly_nx;
                        rstate  <= R_DLY;
                    end
                    else begin
                        arready <= ar_rdy_nx;
                    end
                end

                R_DLY: begin
                    if (rdly == 2'd0) begin
                        rdata  <= mem[idx_of(raddr_r)];
                        rvalid <= 1'b1;
                        rstate <= R_DATA;
                    end
                    else begin
                        rdly <= rdly - 2'd1;
                    end
                end

                R_DATA: begin
                    if (rvalid && rready) begin
                        rvalid  <= 1'b0;
                        arready <= ar_rdy_nx;
                        rstate  <= R_IDLE;
                    end
                end

                default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
