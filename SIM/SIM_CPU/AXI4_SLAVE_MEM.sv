//---------------------------------------------------------------------------
// AXI4_SLAVE_MEM.sv
//
// Simple AXI4 slave memory model for CPU_TOP verification.
//
//  - INCR burst supported, up to 256 beats (FIXED / WRAP are not modelled)
//  - Narrow transfers (AxSIZE smaller than the data bus) supported: the beat
//    address advances by (1 << AxSIZE), WSTRB selects the lanes written, and
//    a read beat returns the whole data-bus word that contains the beat
//    address (the master picks the lanes it needs)
//  - Read and write channels operate independently
//  - Memory is initialised so that the content increments with the word
//    address:  mem[i] = INIT_BASE + i
//
//  Stall injection (for handshake robustness):
//    stall_en = 1 makes AWREADY / WREADY / ARREADY drop randomly and
//    inserts random idle cycles before BVALID and before every RVALID.
//    VALID signals are never withdrawn before their handshake, as required
//    by the AXI specification. stall_en is a variable driven from the
//    testbench through a hierarchical reference.
//
//  Protocol checks (counted in protocol_err):
//    - a burst must not cross a 4KB address boundary
//    - WLAST must be asserted on, and only on, the final write beat
//    - AxSIZE must not exceed the data bus width
//    - for a narrow write, WSTRB must not select lanes outside the beat
//      (from the beat address up to the next (1 << AWSIZE) boundary)
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module AXI4_SLAVE_MEM
    #(
        parameter int ID_WIDTH   = 4,
        parameter int ADDR_WIDTH = 32,
        parameter int DATA_WIDTH = 64,
        parameter int DEPTH      = 512,                  // words (power of 2)
        parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = 32'h8000_0000,
        parameter logic [DATA_WIDTH-1:0] INIT_BASE = '0
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // Write Address Channel
        input  logic [ID_WIDTH-1:0]     awid,
        input  logic [ADDR_WIDTH-1:0]   awaddr,
        input  logic [7:0]              awlen,
        input  logic [2:0]              awsize,
        input  logic [1:0]              awburst,
        input  logic                    awlock,
        input  logic [3:0]              awcache,
        input  logic [2:0]              awprot,
        input  logic [3:0]              awqos,
        input  logic                    awvalid,
        output logic                    awready,

        // Write Data Channel
        input  logic [DATA_WIDTH-1:0]   wdata,
        input  logic [DATA_WIDTH/8-1:0] wstrb,
        input  logic                    wlast,
        input  logic                    wvalid,
        output logic                    wready,

        // Write Response Channel
        output logic [ID_WIDTH-1:0]     bid,
        output logic [1:0]              bresp,
        output logic                    bvalid,
        input  logic                    bready,

        // Read Address Channel
        input  logic [ID_WIDTH-1:0]     arid,
        input  logic [ADDR_WIDTH-1:0]   araddr,
        input  logic [7:0]              arlen,
        input  logic [2:0]              arsize,
        input  logic [1:0]              arburst,
        input  logic                    arlock,
        input  logic [3:0]              arcache,
        input  logic [2:0]              arprot,
        input  logic [3:0]              arqos,
        input  logic                    arvalid,
        output logic                    arready,

        // Read Data Channel
        output logic [ID_WIDTH-1:0]     rid,
        output logic [DATA_WIDTH-1:0]   rdata,
        output logic [1:0]              rresp,
        output logic                    rlast,
        output logic                    rvalid,
        input  logic                    rready
    );

    localparam int BYTES      = DATA_WIDTH / 8;
    localparam int WORD_SHIFT = $clog2(BYTES);      // 64bit -> 3
    localparam int IDX_BITS   = $clog2(DEPTH);

    localparam logic [1:0] RESP_OKAY = 2'b00;

    //-----------------------------------------------------------------
    // Testbench-controlled variables
    //-----------------------------------------------------------------
    logic stall_en;         // 1 = inject random ready drops / valid delays

    initial begin
        stall_en = 1'b0;
    end

    // Number of AXI protocol violations detected (write + read channels)
    int protocol_err_w;
    int protocol_err_r;
    int protocol_err;
    assign protocol_err = protocol_err_w + protocol_err_r;

    //-----------------------------------------------------------------
    // Memory array
    //-----------------------------------------------------------------
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            mem[i] = INIT_BASE + DATA_WIDTH'(i);
        end
    end

    // Byte address -> word index inside this memory
    function automatic logic [IDX_BITS-1:0] idx_of(input logic [ADDR_WIDTH-1:0] a);
        logic [ADDR_WIDTH-1:0] off;
        off    = a - BASE_ADDR;
        idx_of = off[WORD_SHIFT+IDX_BITS-1 : WORD_SHIFT];
    endfunction

    // 1 if an INCR burst of (len+1) beats starting at addr crosses 4KB
    function automatic logic crosses_4kb(input logic [ADDR_WIDTH-1:0] a,
                                         input logic [7:0] len,
                                         input logic [2:0] size);
        logic [15:0] last_byte;
        last_byte   = {4'd0, a[11:0]} + ((16'(len) + 16'd1) << size) - 16'd1;
        crosses_4kb = (last_byte > 16'h0FFF);
    endfunction

    // Address of the next beat of an INCR burst (aligned to the size)
    function automatic logic [ADDR_WIDTH-1:0] next_addr(input logic [ADDR_WIDTH-1:0] a,
                                                         input logic [2:0] size);
        logic [ADDR_WIDTH-1:0] nb;
        nb        = ADDR_WIDTH'(1) << size;
        next_addr = (a & ~(nb - 1'b1)) + nb;
    endfunction

    // Lanes a beat of the given size at address a may write
    function automatic logic [BYTES-1:0] legal_strb(input logic [ADDR_WIDTH-1:0] a,
                                                    input logic [2:0] size);
        int nbytes;
        int off;
        int base;
        logic [BYTES-1:0] m;
        if (int'(size) >= WORD_SHIFT) begin
            legal_strb = '1;
        end
        else begin
            nbytes = 1 << size;
            off    = int'(a[WORD_SHIFT-1:0]);
            base   = off - (off % nbytes);
            m      = '0;
            for (int b = 0; b < BYTES; b++) begin
                if ((b >= off) && (b < base + nbytes)) m[b] = 1'b1;
            end
            legal_strb = m;
        end
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

    // ready: 75% probability when stalling
    wire aw_rdy_nx = stall_en ? (rnd_aw[1:0] != 2'b00) : 1'b1;
    wire w_rdy_nx  = stall_en ? (rnd_w[1:0]  != 2'b00) : 1'b1;
    wire ar_rdy_nx = stall_en ? (rnd_ar[1:0] != 2'b00) : 1'b1;
    // valid delay: 0..3 idle cycles when stalling
    wire [1:0] b_dly_nx = stall_en ? rnd_b[1:0] : 2'd0;
    wire [1:0] r_dly_nx = stall_en ? rnd_r[1:0] : 2'd0;

    //-----------------------------------------------------------------
    // Write channels
    //-----------------------------------------------------------------
    localparam logic [1:0] W_IDLE = 2'd0;
    localparam logic [1:0] W_DATA = 2'd1;
    localparam logic [1:0] W_BDLY = 2'd2;
    localparam logic [1:0] W_RESP = 2'd3;

    logic [1:0]            wstate;
    logic [ADDR_WIDTH-1:0] waddr_r;     // address of the current write beat
    logic [2:0]            wsize_r;
    logic [ID_WIDTH-1:0]   wid_r;
    logic [7:0]          wlen_r;
    logic [8:0]          wbeat;
    logic [1:0]          wdly;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate  <= W_IDLE;
            awready <= 1'b1;
            wready  <= 1'b0;
            bvalid  <= 1'b0;
            bid     <= '0;
            bresp   <= RESP_OKAY;
            waddr_r <= '0;
            wsize_r <= 3'd0;
            wid_r   <= '0;
            wlen_r  <= 8'd0;
            wbeat   <= 9'd0;
            wdly    <= 2'd0;
            protocol_err_w <= 0;
        end
        else begin
            case (wstate)
                W_IDLE: begin
                    if (awvalid && awready) begin
                        if (crosses_4kb(awaddr, awlen, awsize)) begin
                            protocol_err_w <= protocol_err_w + 1;
                            $display("[%0t] [AXI4 PROTOCOL] write burst crosses 4KB: awaddr=0x%08h awlen=%0d",
                                     $time, awaddr, awlen);
                        end
                        if (int'(awsize) > WORD_SHIFT) begin
                            protocol_err_w <= protocol_err_w + 1;
                            $display("[%0t] [AXI4 PROTOCOL] AWSIZE=%0d exceeds the data bus width",
                                     $time, awsize);
                        end
                        waddr_r <= awaddr;
                        wsize_r <= awsize;
                        wid_r   <= awid;
                        wlen_r  <= awlen;
                        wbeat   <= 9'd0;
                        awready <= 1'b0;
                        wready  <= w_rdy_nx;
                        wstate  <= W_DATA;
                    end
                    else begin
                        awready <= aw_rdy_nx;
                    end
                end

                W_DATA: begin
                    if (wvalid && wready) begin
                        for (int b = 0; b < BYTES; b++) begin
                            if (wstrb[b]) mem[idx_of(waddr_r)][8*b +: 8] <= wdata[8*b +: 8];
                        end
                        if ((wstrb & ~legal_strb(waddr_r, wsize_r)) != '0) begin
                            protocol_err_w <= protocol_err_w + 1;
                            $display("[%0t] [AXI4 PROTOCOL] WSTRB=0x%02h outside the lanes of a %0d-byte beat at 0x%08h",
                                     $time, wstrb, 1 << wsize_r, waddr_r);
                        end
                        waddr_r <= next_addr(waddr_r, wsize_r);
                        wbeat   <= wbeat + 9'd1;

                        if (wlast != (wbeat == {1'b0, wlen_r})) begin
                            protocol_err_w <= protocol_err_w + 1;
                            $display("[%0t] [AXI4 PROTOCOL] WLAST=%0d on beat %0d of awlen=%0d",
                                     $time, wlast, wbeat, wlen_r);
                        end

                        if (wbeat == {1'b0, wlen_r}) begin
                            wready <= 1'b0;
                            bid    <= wid_r;
                            bresp  <= RESP_OKAY;
                            wdly   <= b_dly_nx;
                            wstate <= W_BDLY;
                        end
                        else begin
                            wready <= w_rdy_nx;
                        end
                    end
                    else begin
                        wready <= w_rdy_nx;
                    end
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
    logic [ADDR_WIDTH-1:0] raddr_r;   // address of the beat being presented
    logic [2:0]            rsize_r;
    logic [8:0]          rbeat;     // number of the beat being presented
    logic [7:0]          rlen_r;
    logic [1:0]          rdly;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate  <= R_IDLE;
            arready <= 1'b1;
            rvalid  <= 1'b0;
            rlast   <= 1'b0;
            rid     <= '0;
            rdata   <= '0;
            rresp   <= RESP_OKAY;
            raddr_r <= '0;
            rsize_r <= 3'd0;
            rbeat   <= 9'd0;
            rlen_r  <= 8'd0;
            rdly    <= 2'd0;
            protocol_err_r <= 0;
        end
        else begin
            case (rstate)
                R_IDLE: begin
                    if (arvalid && arready) begin
                        if (crosses_4kb(araddr, arlen, arsize)) begin
                            protocol_err_r <= protocol_err_r + 1;
                            $display("[%0t] [AXI4 PROTOCOL] read burst crosses 4KB: araddr=0x%08h arlen=%0d",
                                     $time, araddr, arlen);
                        end
                        if (int'(arsize) > WORD_SHIFT) begin
                            protocol_err_r <= protocol_err_r + 1;
                            $display("[%0t] [AXI4 PROTOCOL] ARSIZE=%0d exceeds the data bus width",
                                     $time, arsize);
                        end
                        arready <= 1'b0;
                        rid     <= arid;
                        rresp   <= RESP_OKAY;
                        raddr_r <= araddr;
                        rsize_r <= arsize;
                        rbeat   <= 9'd0;
                        rlen_r  <= arlen;
                        rdly    <= r_dly_nx;
                        rstate  <= R_DLY;
                    end
                    else begin
                        arready <= ar_rdy_nx;
                    end
                end

                // Idle cycles before presenting the next beat
                R_DLY: begin
                    if (rdly == 2'd0) begin
                        rdata  <= mem[idx_of(raddr_r)];
                        rlast  <= (rbeat == {1'b0, rlen_r});
                        rvalid <= 1'b1;
                        rstate <= R_DATA;
                    end
                    else begin
                        rdly <= rdly - 2'd1;
                    end
                end

                R_DATA: begin
                    if (rvalid && rready) begin
                        if (rlast) begin
                            rvalid  <= 1'b0;
                            rlast   <= 1'b0;
                            arready <= ar_rdy_nx;
                            rstate  <= R_IDLE;
                        end
                        else if (r_dly_nx != 2'd0) begin
                            // withdraw VALID only after the handshake, then wait
                            rvalid  <= 1'b0;
                            raddr_r <= next_addr(raddr_r, rsize_r);
                            rbeat   <= rbeat + 9'd1;
                            rdly   <= r_dly_nx - 2'd1;
                            rstate <= R_DLY;
                        end
                        else begin
                            // back-to-back beat, VALID stays high
                            rdata   <= mem[idx_of(next_addr(raddr_r, rsize_r))];
                            raddr_r <= next_addr(raddr_r, rsize_r);
                            rbeat   <= rbeat + 9'd1;
                            rlast <= ((rbeat + 9'd1) == {1'b0, rlen_r});
                        end
                    end
                end

                default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
