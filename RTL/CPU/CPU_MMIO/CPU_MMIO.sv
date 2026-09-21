//---------------------------------------------------------------------------
// CPU_MMIO.sv
//
// The peripheral bus of the CPU, with the two blocks that belong to the core
// itself sitting on it (CPU_CORE_SPEC.md 8).
//
//   Everything below MEM_BASE leaves the caches uncached on the AXI4-Lite
//   bus (CPU_CACHE_SPEC.md 5.5). This block decodes that stream: an address
//   inside the CLINT or the PLIC is answered here, everything else is passed
//   on to the outside unchanged.
//
//   One write and one read are in flight at a time. The address is taken
//   into a register first and the decision made from there, so the data
//   channel of a write is never forwarded before it is known where the write
//   is going; AXI4-Lite allows the data to arrive first, and a block that
//   guessed would send the CLINT's data to the outside. MMIO throughput is
//   not worth any more than that.
//
//   The CLINT and the PLIC are plain synchronous slaves with a
//   combinational read, so one cycle of `sel` is the whole access.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_MMIO
    #(
        parameter int          ADDR_WIDTH    = 40,
        parameter logic [39:0] CLINT_BASE    = 40'h00_0200_0000,
        parameter logic [39:0] PLIC_BASE     = 40'h00_0C00_0000,
        parameter int          NUM_HARTS     = 1,
        parameter int          CLINT_TICK_DIV= 1,
        parameter int          PLIC_SOURCES  = 31,
        parameter int          PLIC_CONTEXTS = 2,
        parameter int          PLIC_PRIO_BITS= 3
    )
    (
        input  logic                     clk,
        input  logic                     rst_n,

        // from the caches
        input  logic [ADDR_WIDTH-1:0]    s_awaddr,
        input  logic [2:0]               s_awprot,
        input  logic                     s_awvalid,
        output logic                     s_awready,
        input  logic [63:0]              s_wdata,
        input  logic [7:0]               s_wstrb,
        input  logic                     s_wvalid,
        output logic                     s_wready,
        output logic [1:0]               s_bresp,
        output logic                     s_bvalid,
        input  logic                     s_bready,
        input  logic [ADDR_WIDTH-1:0]    s_araddr,
        input  logic [2:0]               s_arprot,
        input  logic                     s_arvalid,
        output logic                     s_arready,
        output logic [63:0]              s_rdata,
        output logic [1:0]               s_rresp,
        output logic                     s_rvalid,
        input  logic                     s_rready,

        // to the outside
        output logic [ADDR_WIDTH-1:0]    m_awaddr,
        output logic [2:0]               m_awprot,
        output logic                     m_awvalid,
        input  logic                     m_awready,
        output logic [63:0]              m_wdata,
        output logic [7:0]               m_wstrb,
        output logic                     m_wvalid,
        input  logic                     m_wready,
        input  logic [1:0]               m_bresp,
        input  logic                     m_bvalid,
        output logic                     m_bready,
        output logic [ADDR_WIDTH-1:0]    m_araddr,
        output logic [2:0]               m_arprot,
        output logic                     m_arvalid,
        input  logic                     m_arready,
        input  logic [63:0]              m_rdata,
        input  logic [1:0]               m_rresp,
        input  logic                     m_rvalid,
        output logic                     m_rready,

        // interrupt sources of the platform
        input  logic [PLIC_SOURCES:0]    ext_irq,

        // to the harts
        output logic [NUM_HARTS-1:0]     irq_m_soft,
        output logic [NUM_HARTS-1:0]     irq_m_timer,
        output logic [NUM_HARTS-1:0]     irq_m_ext,
        output logic [NUM_HARTS-1:0]     irq_s_ext,
        output logic [63:0]              mtime
    );

    localparam logic [1:0] RESP_OKAY = 2'b00;

    localparam logic [1:0] W_IDLE = 2'd0;   // collecting the address and data
    localparam logic [1:0] W_INT  = 2'd1;   // answered here
    localparam logic [1:0] W_EXT  = 2'd2;   // handed to the outside
    localparam logic [1:0] R_IDLE = 2'd0;
    localparam logic [1:0] R_INT  = 2'd1;
    localparam logic [1:0] R_EXT  = 2'd2;

    //-----------------------------------------------------------------
    // decode
    //-----------------------------------------------------------------
    function automatic bit in_clint(input logic [ADDR_WIDTH-1:0] a);
        return (a >= ADDR_WIDTH'(CLINT_BASE)) &&
               (a <  ADDR_WIDTH'(CLINT_BASE) + ADDR_WIDTH'(64 * 1024));
    endfunction

    function automatic bit in_plic(input logic [ADDR_WIDTH-1:0] a);
        return (a >= ADDR_WIDTH'(PLIC_BASE)) &&
               (a <  ADDR_WIDTH'(PLIC_BASE) + ADDR_WIDTH'(4 * 1024 * 1024));
    endfunction

    //-----------------------------------------------------------------
    // write
    //-----------------------------------------------------------------
    logic [1:0]            w_state;
    logic                  aw_got, w_got, aw_sent, w_sent;
    logic [ADDR_WIDTH-1:0] aw_addr;
    logic [2:0]            aw_prot;
    logic [63:0]           w_data;
    logic [7:0]            w_strb;
    logic                  wr_do;

    assign s_awready = (w_state == W_IDLE) & ~aw_got;
    assign s_wready  = (w_state == W_IDLE) & ~w_got;

    // both halves are in and the address belongs to this block
    assign wr_do = (w_state == W_IDLE) & aw_got & w_got &
                   (in_clint(aw_addr) | in_plic(aw_addr));

    assign m_awaddr  = aw_addr;
    assign m_awprot  = aw_prot;
    assign m_awvalid = (w_state == W_EXT) & ~aw_sent;
    assign m_wdata   = w_data;
    assign m_wstrb   = w_strb;
    assign m_wvalid  = (w_state == W_EXT) & ~w_sent;
    assign m_bready  = (w_state == W_EXT) & s_bready;

    assign s_bvalid  = (w_state == W_INT) ? 1'b1
                     : (w_state == W_EXT) ? m_bvalid : 1'b0;
    assign s_bresp   = (w_state == W_EXT) ? m_bresp : RESP_OKAY;

    //-----------------------------------------------------------------
    // read
    //-----------------------------------------------------------------
    logic [1:0]            r_state;
    logic [ADDR_WIDTH-1:0] ar_addr;
    logic [2:0]            ar_prot;
    logic                  ar_sent, rd_ready;
    logic [63:0]           rd_data;
    logic                  rd_do;

    assign s_arready = (r_state == R_IDLE);

    // the access is made in the cycle after the address was taken
    assign rd_do = (r_state == R_INT) & ~rd_ready;

    assign m_araddr  = ar_addr;
    assign m_arprot  = ar_prot;
    assign m_arvalid = (r_state == R_EXT) & ~ar_sent;
    assign m_rready  = (r_state == R_EXT) & s_rready;

    assign s_rvalid  = (r_state == R_INT) ? rd_ready
                     : (r_state == R_EXT) ? m_rvalid : 1'b0;
    assign s_rdata   = (r_state == R_EXT) ? m_rdata : rd_data;
    assign s_rresp   = (r_state == R_EXT) ? m_rresp : RESP_OKAY;

    //-----------------------------------------------------------------
    // the two blocks
    //-----------------------------------------------------------------
    logic        clint_sel, clint_we;
    logic [63:0] clint_rdata;
    logic        plic_sel, plic_we;
    logic [63:0] plic_rdata;
    logic [ADDR_WIDTH-1:0] acc_addr;

    assign acc_addr  = rd_do ? ar_addr : aw_addr;
    assign clint_sel = (rd_do | wr_do) & in_clint(acc_addr);
    assign clint_we  = wr_do;
    assign plic_sel  = (rd_do | wr_do) & in_plic(acc_addr);
    assign plic_we   = wr_do;

    CPU_CLINT #(.NUM_HARTS(NUM_HARTS), .TICK_DIV(CLINT_TICK_DIV)) u_clint
        (
            .clk         (clk),
            .rst_n       (rst_n),
            .sel         (clint_sel),
            .we          (clint_we),
            .addr        (acc_addr[15:0]),
            .wdata       (w_data),
            .wstrb       (w_strb),
            .rdata       (clint_rdata),
            .irq_m_soft  (irq_m_soft),
            .irq_m_timer (irq_m_timer),
            .mtime       (mtime)
        );

    logic [PLIC_CONTEXTS-1:0] plic_irq;

    CPU_PLIC #(.SOURCES(PLIC_SOURCES), .CONTEXTS(PLIC_CONTEXTS),
               .PRIO_BITS(PLIC_PRIO_BITS)) u_plic
        (
            .clk   (clk),
            .rst_n (rst_n),
            .sel   (plic_sel),
            .we    (plic_we),
            .addr  (acc_addr[21:0]),
            .wdata (w_data),
            .wstrb (w_strb),
            .rdata (plic_rdata),
            .src   ({ext_irq[PLIC_SOURCES:1], 1'b0}),
            .irq   (plic_irq)
        );

    // context 2*h is the machine mode of hart h, 2*h+1 its supervisor mode
    always @(*) begin
        for (int h = 0; h < NUM_HARTS; h++) begin
            irq_m_ext[h] = plic_irq[2*h];
            irq_s_ext[h] = ((2*h + 1) < PLIC_CONTEXTS) ? plic_irq[2*h + 1] : 1'b0;
        end
    end

    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_state  <= W_IDLE;
            aw_got   <= 1'b0;
            w_got    <= 1'b0;
            aw_sent  <= 1'b0;
            w_sent   <= 1'b0;
            aw_addr  <= '0;
            aw_prot  <= 3'd0;
            w_data   <= 64'd0;
            w_strb   <= 8'd0;
            r_state  <= R_IDLE;
            ar_addr  <= '0;
            ar_prot  <= 3'd0;
            ar_sent  <= 1'b0;
            rd_ready <= 1'b0;
            rd_data  <= 64'd0;
        end else begin
            //---------------------------------------------------------
            // write
            //---------------------------------------------------------
            case (w_state)
                W_IDLE: begin
                    if (s_awvalid && s_awready) begin
                        aw_got  <= 1'b1;
                        aw_addr <= s_awaddr;
                        aw_prot <= s_awprot;
                    end
                    if (s_wvalid && s_wready) begin
                        w_got  <= 1'b1;
                        w_data <= s_wdata;
                        w_strb <= s_wstrb;
                    end
                    if (wr_do) begin
                        w_state <= W_INT;
                    end else if (aw_got && w_got) begin
                        w_state <= W_EXT;      // not ours
                        aw_sent <= 1'b0;
                        w_sent  <= 1'b0;
                    end
                end

                W_INT: begin
                    if (s_bready) begin
                        w_state <= W_IDLE;
                        aw_got  <= 1'b0;
                        w_got   <= 1'b0;
                    end
                end

                default: begin                 // W_EXT
                    if (m_awvalid && m_awready) aw_sent <= 1'b1;
                    if (m_wvalid  && m_wready)  w_sent  <= 1'b1;
                    if (m_bvalid && s_bready) begin
                        w_state <= W_IDLE;
                        aw_got  <= 1'b0;
                        w_got   <= 1'b0;
                    end
                end
            endcase

            //---------------------------------------------------------
            // read
            //---------------------------------------------------------
            case (r_state)
                R_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        ar_addr  <= s_araddr;
                        ar_prot  <= s_arprot;
                        rd_ready <= 1'b0;
                        ar_sent  <= 1'b0;
                        r_state  <= (in_clint(s_araddr) | in_plic(s_araddr))
                                  ? R_INT : R_EXT;
                    end
                end

                R_INT: begin
                    if (rd_do) begin
                        rd_data  <= in_clint(ar_addr) ? clint_rdata : plic_rdata;
                        rd_ready <= 1'b1;
                    end else if (s_rready) begin
                        r_state <= R_IDLE;
                    end
                end

                default: begin                 // R_EXT
                    if (m_arvalid && m_arready) ar_sent <= 1'b1;
                    if (m_rvalid && s_rready)   r_state <= R_IDLE;
                end
            endcase
        end
    end

endmodule : CPU_MMIO
