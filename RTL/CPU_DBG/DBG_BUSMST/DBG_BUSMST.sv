//---------------------------------------------------------------------------
// DBG_BUSMST.sv
//
// Bus master for System Bus Access and the Access Memory abstract command.
//
//   Request (bm_req pulse) -> single-beat AXI transaction -> bm_ack pulse
//
//   Bus select : bm_addr >= MEM_BASE -> memory bus (AXI4)
//                otherwise           -> peripheral bus (AXI4-Lite)
//   Access size: bm_size 0/1/2/3 = 8/16/32/64 bit. The address must be
//                aligned to the size (checked by DBG_DM).
//     AXI4     : AxSIZE = bm_size (narrow transfer for 8/16/32 bit)
//     AXI4-Lite: WSTRB selects the lanes, read data is taken from the lanes
//     Lane position in the 64-bit data bus = bm_addr[2:0] (little endian).
//   bm_err     : 0 OK, 1 timeout, 2 DECERR, 7 SLVERR (= sberror encoding)
//
//   Timeout: when the transaction does not finish within TIMEOUT_CYCLES,
//   bm_ack is returned with bm_err=1 and the master keeps waiting for the
//   bus in the background (drain state). Requests received while draining
//   are answered immediately with bm_err=1.
//
//   Reset: rst_n is the system bus reset. DBG_DM watches the bus reset and
//   gives up a pending request by itself.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_BUSMST
    #(
        parameter int          AXI4_ID_WIDTH   = 4,
        parameter int          ADDR_WIDTH      = 40,
        parameter logic [AXI4_ID_WIDTH-1:0] AXI4_ID = 1,
        parameter logic [39:0] MEM_BASE        = 40'h00_8000_0000,
        parameter int          TIMEOUT_CYCLES  = 1 << 20
    )
    (
        input  logic                     clk,
        input  logic                     rst_n,

        // request from DBG_DM
        input  logic                     bm_req,
        input  logic                     bm_wr,
        input  logic [ADDR_WIDTH-1:0]    bm_addr,
        input  logic [1:0]               bm_size,
        input  logic [63:0]              bm_wdata,
        output logic                     bm_ack,
        output logic [63:0]              bm_rdata,
        output logic [2:0]               bm_err,

        // memory bus : AXI4 master
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_awid,
        output logic [ADDR_WIDTH-1:0]    m_axi4_awaddr,
        output logic [7:0]               m_axi4_awlen,
        output logic [2:0]               m_axi4_awsize,
        output logic [1:0]               m_axi4_awburst,
        output logic                     m_axi4_awlock,
        output logic [3:0]               m_axi4_awcache,
        output logic [2:0]               m_axi4_awprot,
        output logic [3:0]               m_axi4_awqos,
        output logic                     m_axi4_awvalid,
        input  logic                     m_axi4_awready,
        output logic [63:0]              m_axi4_wdata,
        output logic [7:0]               m_axi4_wstrb,
        output logic                     m_axi4_wlast,
        output logic                     m_axi4_wvalid,
        input  logic                     m_axi4_wready,
        input  logic [AXI4_ID_WIDTH-1:0] m_axi4_bid,
        input  logic [1:0]               m_axi4_bresp,
        input  logic                     m_axi4_bvalid,
        output logic                     m_axi4_bready,
        output logic [AXI4_ID_WIDTH-1:0] m_axi4_arid,
        output logic [ADDR_WIDTH-1:0]    m_axi4_araddr,
        output logic [7:0]               m_axi4_arlen,
        output logic [2:0]               m_axi4_arsize,
        output logic [1:0]               m_axi4_arburst,
        output logic                     m_axi4_arlock,
        output logic [3:0]               m_axi4_arcache,
        output logic [2:0]               m_axi4_arprot,
        output logic [3:0]               m_axi4_arqos,
        output logic                     m_axi4_arvalid,
        input  logic                     m_axi4_arready,
        input  logic [AXI4_ID_WIDTH-1:0] m_axi4_rid,
        input  logic [63:0]              m_axi4_rdata,
        input  logic [1:0]               m_axi4_rresp,
        input  logic                     m_axi4_rlast,
        input  logic                     m_axi4_rvalid,
        output logic                     m_axi4_rready,

        // peripheral bus : AXI4-Lite master
        output logic [ADDR_WIDTH-1:0]    m_axil_awaddr,
        output logic [2:0]               m_axil_awprot,
        output logic                     m_axil_awvalid,
        input  logic                     m_axil_awready,
        output logic [63:0]              m_axil_wdata,
        output logic [7:0]               m_axil_wstrb,
        output logic                     m_axil_wvalid,
        input  logic                     m_axil_wready,
        input  logic [1:0]               m_axil_bresp,
        input  logic                     m_axil_bvalid,
        output logic                     m_axil_bready,
        output logic [ADDR_WIDTH-1:0]    m_axil_araddr,
        output logic [2:0]               m_axil_arprot,
        output logic                     m_axil_arvalid,
        input  logic                     m_axil_arready,
        input  logic [63:0]              m_axil_rdata,
        input  logic [1:0]               m_axil_rresp,
        input  logic                     m_axil_rvalid,
        output logic                     m_axil_rready
    );

    //-----------------------------------------------------------------
    // Transaction registers
    //-----------------------------------------------------------------
    logic                  t_mem;     // 1: AXI4, 0: AXI4-Lite
    logic [ADDR_WIDTH-1:0] t_addr;
    logic [1:0]            t_size;
    logic [63:0]           t_wdata;
    logic [7:0]            t_wstrb;
    logic [5:0]            t_shift;   // lane offset in bits

    function automatic logic [63:0] size_mask(input logic [1:0] s);
        case (s)
            2'd0:    return 64'h0000_0000_0000_00FF;
            2'd1:    return 64'h0000_0000_0000_FFFF;
            2'd2:    return 64'h0000_0000_FFFF_FFFF;
            default: return 64'hFFFF_FFFF_FFFF_FFFF;
        endcase
    endfunction

    function automatic logic [7:0] size_strb(input logic [1:0] s);
        case (s)
            2'd0:    return 8'h01;
            2'd1:    return 8'h03;
            2'd2:    return 8'h0F;
            default: return 8'hFF;
        endcase
    endfunction

    function automatic logic [2:0] resp2err(input logic [1:0] r);
        case (r)
            2'b10:   return 3'd7;   // SLVERR -> other error
            2'b11:   return 3'd2;   // DECERR -> bad address
            default: return 3'd0;   // OKAY / EXOKAY
        endcase
    endfunction

    //-----------------------------------------------------------------
    // FSM
    //-----------------------------------------------------------------
    typedef enum logic [2:0] {
        B_IDLE, B_W_AW_W, B_W_B, B_R_AR, B_R_R
    } b_state_t;

    b_state_t b_state;
    logic     aw_done, w_done;
    logic     draining;              // timed out, waiting for the bus
    logic [$clog2(TIMEOUT_CYCLES+1)-1:0] tmo_cnt;

    // channel handshakes (selected bus)
    logic aw_hs, w_hs, b_hs, ar_hs, r_hs;
    logic [1:0]  b_resp, r_resp;
    logic [63:0] r_data;

    assign aw_hs  = t_mem ? (m_axi4_awvalid & m_axi4_awready) : (m_axil_awvalid & m_axil_awready);
    assign w_hs   = t_mem ? (m_axi4_wvalid  & m_axi4_wready)  : (m_axil_wvalid  & m_axil_wready);
    assign b_hs   = t_mem ? (m_axi4_bvalid  & m_axi4_bready)  : (m_axil_bvalid  & m_axil_bready);
    assign ar_hs  = t_mem ? (m_axi4_arvalid & m_axi4_arready) : (m_axil_arvalid & m_axil_arready);
    assign r_hs   = t_mem ? (m_axi4_rvalid  & m_axi4_rready)  : (m_axil_rvalid  & m_axil_rready);
    assign b_resp = t_mem ? m_axi4_bresp : m_axil_bresp;
    assign r_resp = t_mem ? m_axi4_rresp : m_axil_rresp;
    assign r_data = t_mem ? m_axi4_rdata : m_axil_rdata;

    logic tmo_hit;
    assign tmo_hit = ~draining & (tmo_cnt == TIMEOUT_CYCLES[$bits(tmo_cnt)-1:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_state  <= B_IDLE;
            aw_done  <= 1'b0;
            w_done   <= 1'b0;
            draining <= 1'b0;
            tmo_cnt  <= '0;
            t_mem    <= 1'b0;
            t_addr   <= '0;
            t_size   <= 2'd0;
            t_wdata  <= '0;
            t_wstrb  <= '0;
            t_shift  <= '0;
            bm_ack   <= 1'b0;
            bm_rdata <= '0;
            bm_err   <= 3'd0;
        end else begin
            bm_ack <= 1'b0;

            // request while a timed-out transaction is still draining
            if (bm_req && b_state != B_IDLE) begin
                bm_ack <= 1'b1;
                bm_err <= 3'd1;
            end

            // timeout
            if (b_state != B_IDLE) begin
                if (!draining) tmo_cnt <= tmo_cnt + 1'b1;
                if (tmo_hit) begin
                    draining <= 1'b1;
                    bm_ack   <= 1'b1;
                    bm_err   <= 3'd1;
                end
            end

            case (b_state)
                B_IDLE: begin
                    draining <= 1'b0;
                    tmo_cnt  <= '0;
                    if (bm_req) begin
                        t_mem   <= (bm_addr >= MEM_BASE[ADDR_WIDTH-1:0]);
                        t_addr  <= bm_addr;
                        t_size  <= bm_size;
                        t_shift <= {bm_addr[2:0], 3'b000};
                        t_wdata <= (bm_wdata & size_mask(bm_size)) << {bm_addr[2:0], 3'b000};
                        t_wstrb <= size_strb(bm_size) << bm_addr[2:0];
                        aw_done <= 1'b0;
                        w_done  <= 1'b0;
                        b_state <= bm_wr ? B_W_AW_W : B_R_AR;
                    end
                end
                B_W_AW_W: begin
                    if (aw_hs) aw_done <= 1'b1;
                    if (w_hs)  w_done  <= 1'b1;
                    if ((aw_done | aw_hs) & (w_done | w_hs))
                        b_state <= B_W_B;
                end
                B_W_B: begin
                    if (b_hs) begin
                        if (!draining && !tmo_hit) begin
                            bm_ack   <= 1'b1;
                            bm_err   <= resp2err(b_resp);
                        end
                        b_state <= B_IDLE;
                    end
                end
                B_R_AR: begin
                    if (ar_hs) b_state <= B_R_R;
                end
                B_R_R: begin
                    if (r_hs) begin
                        if (!draining && !tmo_hit) begin
                            bm_ack   <= 1'b1;
                            bm_err   <= resp2err(r_resp);
                            bm_rdata <= (r_data >> t_shift) & size_mask(t_size);
                        end
                        if (!t_mem || m_axi4_rlast)
                            b_state <= B_IDLE;
                    end
                end
                default: b_state <= B_IDLE;
            endcase
        end
    end

    //-----------------------------------------------------------------
    // AXI4 outputs
    //-----------------------------------------------------------------
    assign m_axi4_awid    = AXI4_ID;
    assign m_axi4_awaddr  = t_addr;
    assign m_axi4_awlen   = 8'd0;
    assign m_axi4_awsize  = {1'b0, t_size};
    assign m_axi4_awburst = 2'b01;
    assign m_axi4_awlock  = 1'b0;
    assign m_axi4_awcache = 4'b0000;
    assign m_axi4_awprot  = 3'b000;
    assign m_axi4_awqos   = 4'd0;
    assign m_axi4_awvalid = t_mem & (b_state == B_W_AW_W) & ~aw_done;
    assign m_axi4_wdata   = t_wdata;
    assign m_axi4_wstrb   = t_wstrb;
    assign m_axi4_wlast   = 1'b1;
    assign m_axi4_wvalid  = t_mem & (b_state == B_W_AW_W) & ~w_done;
    assign m_axi4_bready  = t_mem & (b_state == B_W_B);
    assign m_axi4_arid    = AXI4_ID;
    assign m_axi4_araddr  = t_addr;
    assign m_axi4_arlen   = 8'd0;
    assign m_axi4_arsize  = {1'b0, t_size};
    assign m_axi4_arburst = 2'b01;
    assign m_axi4_arlock  = 1'b0;
    assign m_axi4_arcache = 4'b0000;
    assign m_axi4_arprot  = 3'b000;
    assign m_axi4_arqos   = 4'd0;
    assign m_axi4_arvalid = t_mem & (b_state == B_R_AR);
    assign m_axi4_rready  = t_mem & (b_state == B_R_R);

    //-----------------------------------------------------------------
    // AXI4-Lite outputs
    //-----------------------------------------------------------------
    assign m_axil_awaddr  = t_addr;
    assign m_axil_awprot  = 3'b000;
    assign m_axil_awvalid = ~t_mem & (b_state == B_W_AW_W) & ~aw_done;
    assign m_axil_wdata   = t_wdata;
    assign m_axil_wstrb   = t_wstrb;
    assign m_axil_wvalid  = ~t_mem & (b_state == B_W_AW_W) & ~w_done;
    assign m_axil_bready  = ~t_mem & (b_state == B_W_B);
    assign m_axil_araddr  = t_addr;
    assign m_axil_arprot  = 3'b000;
    assign m_axil_arvalid = ~t_mem & (b_state == B_R_AR);
    assign m_axil_rready  = ~t_mem & (b_state == B_R_R);

endmodule : DBG_BUSMST
