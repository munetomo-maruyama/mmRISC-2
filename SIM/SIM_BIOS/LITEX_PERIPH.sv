//---------------------------------------------------------------------------
// LITEX_PERIPH.sv
//
// The part of the LiteX SoC that sits on the peripheral bus of mmRISC-2 on
// the Arty build (LitexSystem/build/csr.csv), enough for the LiteX BIOS:
//
//   0x1000_0000  ROM   128 KiB, the BIOS image
//   0x1100_0000  SRAM    8 KiB, stack and data of the BIOS
//   0x1200_0000  CSRs, 32 bit wide at a stride of four bytes:
//                  ctrl    0x1200_0000  reset, scratch, bus_errors
//                  timer0  0x1200_3000  load, reload, en, update_value,
//                                       value, ev_status, ev_pending,
//                                       ev_enable
//                  uart    0x1200_3800  rxtx, txfull, rxempty, ev_status,
//                                       ev_pending, ev_enable, txempty,
//                                       rxfull
//                sdcard  0x1200_2000  passed on to SD_MODEL (sd_*)
//                every other CSR reads as zero and ignores writes
//
// The UART follows litex/soc/cores/uart.py: a TX FIFO of 16, the TX event
// is a level source triggered while the FIFO is not full, the RX event
// while the RX FIFO holds something (never, here), and the interrupt is
// (pending & enable). A character leaves the FIFO every +uart_cycles=<n>
// cycles (default 4340, 115200 baud at 50 MHz) and is printed.
//
// The bus is 64 bit wide: a read returns the two CSRs of the double word,
// a write goes to the CSRs its byte strobes select.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module LITEX_PERIPH
    #(
        parameter int ADDR_WIDTH  = 40
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        input  logic [ADDR_WIDTH-1:0]   awaddr,
        input  logic [2:0]              awprot,
        input  logic                    awvalid,
        output logic                    awready,
        input  logic [63:0]             wdata,
        input  logic [7:0]              wstrb,
        input  logic                    wvalid,
        output logic                    wready,
        output logic [1:0]              bresp,
        output logic                    bvalid,
        input  logic                    bready,
        input  logic [ADDR_WIDTH-1:0]   araddr,
        input  logic [2:0]              arprot,
        input  logic                    arvalid,
        output logic                    arready,
        output logic [63:0]             rdata,
        output logic [1:0]              rresp,
        output logic                    rvalid,
        input  logic                    rready,

        output logic                    uart_irq,
        output logic                    timer_irq,

        // the CSRs of the SD card (SD_MODEL): 64 words at 0x1200_2000
        output logic                    sd_wr0_en,
        output logic [5:0]              sd_wr0_idx,
        output logic [31:0]             sd_wr0_dat,
        output logic                    sd_wr1_en,
        output logic [5:0]              sd_wr1_idx,
        output logic [31:0]             sd_wr1_dat,
        input  logic [64*32-1:0]        sd_regs
    );

    localparam logic [39:0] ROM_BASE  = 40'h00_1000_0000;
    localparam logic [39:0] SRAM_BASE = 40'h00_1100_0000;
    localparam logic [39:0] CSR_BASE  = 40'h00_1200_0000;
    localparam int ROM_WORDS  = 128 * 1024 / 8;
    localparam int SRAM_WORDS =   8 * 1024 / 8;

    logic [63:0] rom  [0:ROM_WORDS-1];
    logic [63:0] sram [0:SRAM_WORDS-1];

    function automatic bit in_rom (input logic [ADDR_WIDTH-1:0] a);
        return (a >= ROM_BASE)  && (a < ROM_BASE  + 40'(ROM_WORDS * 8));
    endfunction
    function automatic bit in_sram(input logic [ADDR_WIDTH-1:0] a);
        return (a >= SRAM_BASE) && (a < SRAM_BASE + 40'(SRAM_WORDS * 8));
    endfunction
    function automatic bit in_csr (input logic [ADDR_WIDTH-1:0] a);
        return (a >= CSR_BASE)  && (a < CSR_BASE  + 40'h1_0000);
    endfunction

    //-----------------------------------------------------------------
    // UART
    //-----------------------------------------------------------------
    logic [7:0] tx_fifo [0:15];
    logic [4:0] tx_count;
    logic [3:0] tx_rd;
    logic [1:0] uart_ev_enable;
    int         tx_timer;
    int         UART_CYCLES;
    initial if (!$value$plusargs("uart_cycles=%d", UART_CYCLES)) UART_CYCLES = 4340;
    logic       tx_full, tx_empty;
    // the last characters sent, for the bench to recognise a line
    logic [8*24-1:0] tx_tail;
    initial tx_tail = '0;
    logic [1:0] uart_ev_status;

    assign tx_full        = (tx_count == 5'd16);
    assign tx_empty       = (tx_count == 5'd0);
    assign uart_ev_status = {1'b0, ~tx_full};         // rx : never, tx : not full
    assign uart_irq       = |(uart_ev_status & uart_ev_enable);

    //-----------------------------------------------------------------
    // timer0 (counts down while enabled, reloads at zero)
    //-----------------------------------------------------------------
    logic [31:0] t_load, t_reload, t_value, t_latched;
    logic        t_en, t_zero_pend, t_ev_enable;

    assign timer_irq = t_zero_pend & t_ev_enable;

    logic [31:0] ctrl_scratch;

    function automatic logic [31:0] csr_read(input logic [15:0] off);
        if ((off >= 16'h2000) && (off < 16'h2100))
            return sd_regs[32 * int'(off[7:2]) +: 32];
        case (off)
            16'h0004: return ctrl_scratch;
            16'h3000: return t_load;
            16'h3004: return t_reload;
            16'h3008: return {31'd0, t_en};
            16'h3010: return t_latched;
            16'h3014: return {31'd0, t_zero_pend};
            16'h3018: return {31'd0, t_zero_pend};
            16'h301c: return {31'd0, t_ev_enable};
            16'h3800: return 32'd0;                     // rxtx : RX is empty
            16'h3804: return {31'd0, tx_full};
            16'h3808: return 32'd1;                     // rxempty
            16'h380c: return {30'd0, uart_ev_status};
            16'h3810: return {30'd0, uart_ev_status};   // level : pending = status
            16'h3814: return {30'd0, uart_ev_enable};
            16'h3818: return {31'd0, tx_empty};
            16'h381c: return 32'd0;                     // rxfull
            16'h1004: return 32'h0000_1111;             // id word, arbitrary
            default:  return 32'd0;
        endcase
    endfunction

    //-----------------------------------------------------------------
    // AXI4-Lite : one transfer at a time in each direction
    //-----------------------------------------------------------------
    logic                  aw_got, w_got;
    logic [ADDR_WIDTH-1:0] aw_q;
    logic [63:0]           w_q;
    logic [7:0]            s_q;

    assign awready = ~aw_got & ~bvalid;
    assign wready  = ~w_got  & ~bvalid;
    assign arready = ~rvalid;

    // the character written in this cycle, if any
    logic       tx_push;
    logic [7:0] tx_char;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_got <= 1'b0; w_got <= 1'b0;
            bvalid <= 1'b0; bresp <= 2'b00;
            rvalid <= 1'b0; rresp <= 2'b00; rdata <= 64'd0;
            tx_count <= 5'd0; tx_rd <= 4'd0; tx_timer <= 0;
            uart_ev_enable <= 2'd0;
            t_load <= 0; t_reload <= 0; t_value <= 0; t_latched <= 0;
            t_en <= 1'b0; t_zero_pend <= 1'b0; t_ev_enable <= 1'b0;
            ctrl_scratch <= 32'h1234_5678;
            sd_wr0_en <= 1'b0; sd_wr1_en <= 1'b0;
        end else begin
            tx_push = 1'b0;
            tx_char = 8'd0;
            sd_wr0_en <= 1'b0;
            sd_wr1_en <= 1'b0;

            // --- write
            if (awvalid && awready) begin aw_got <= 1'b1; aw_q <= awaddr; end
            if (wvalid && wready)   begin w_got  <= 1'b1; w_q <= wdata; s_q <= wstrb; end
            if (aw_got && w_got && !bvalid) begin
                aw_got <= 1'b0; w_got <= 1'b0;
                bvalid <= 1'b1;
                bresp  <= 2'b00;
                if (in_sram(aw_q)) begin
                    for (int b = 0; b < 8; b++)
                        if (s_q[b]) sram[(aw_q - SRAM_BASE) >> 3][8*b +: 8] <= w_q[8*b +: 8];
                end else if (in_csr(aw_q)) begin
                    for (int h = 0; h < 2; h++) begin
                        if (|s_q[4*h +: 4]) begin
                            logic [15:0] off;
                            logic [31:0] v;
                            off = 16'(((aw_q - CSR_BASE) & ~40'd7) + 40'(4 * h));
                            v   = w_q[32*h +: 32];
                            if ((off >= 16'h2000) && (off < 16'h2100)) begin
                                if (h == 0) begin
                                    sd_wr0_en <= 1'b1; sd_wr0_idx <= off[7:2]; sd_wr0_dat <= v;
                                end else begin
                                    sd_wr1_en <= 1'b1; sd_wr1_idx <= off[7:2]; sd_wr1_dat <= v;
                                end
                            end
                            case (off)
                                16'h0004: ctrl_scratch   <= v;
                                16'h3000: t_load         <= v;
                                16'h3004: t_reload       <= v;
                                16'h3008: begin t_en <= v[0]; if (v[0]) t_value <= t_load; end
                                16'h300c: t_latched      <= t_value;
                                16'h3018: if (v[0]) t_zero_pend <= 1'b0;
                                16'h301c: t_ev_enable    <= v[0];
                                16'h3800: begin tx_push = 1'b1; tx_char = v[7:0]; end
                                16'h3814: uart_ev_enable <= v[1:0];
                                default: ;
                            endcase
                        end
                    end
                end else if (!in_rom(aw_q)) begin
                    bresp <= 2'b11;
                    $display("LITEX_PERIPH: write to an unmapped address %010h", aw_q);
                end
            end
            if (bvalid && bready) bvalid <= 1'b0;

            // --- read
            if (arvalid && arready) begin
                logic [ADDR_WIDTH-1:0] a;
                logic [15:0] off;
                a = araddr & ~40'd7;
                rvalid <= 1'b1;
                rresp  <= 2'b00;
                if (in_rom(a))       rdata <= rom[(a - ROM_BASE) >> 3];
                else if (in_sram(a)) rdata <= sram[(a - SRAM_BASE) >> 3];
                else if (in_csr(a)) begin
                    off   = 16'(a - CSR_BASE);
                    rdata <= {csr_read(off + 16'd4), csr_read(off)};
                end else begin
                    rdata <= 64'd0;
                    rresp <= 2'b11;
                    $display("LITEX_PERIPH: read of an unmapped address %010h", araddr);
                end
            end
            if (rvalid && rready) rvalid <= 1'b0;

            // --- the UART sends one character every UART_CYCLES
            if (!tx_empty) begin
                if (tx_timer >= UART_CYCLES) begin
                    $write("%c", tx_fifo[tx_rd]);
                    $fflush;
                    tx_tail <= {tx_tail[8*23-1:0], tx_fifo[tx_rd]};
                    tx_rd    <= tx_rd + 4'd1;
                    tx_timer <= 0;
                end else begin
                    tx_timer <= tx_timer + 1;
                end
            end
            if (tx_push && !tx_full) tx_fifo[tx_rd + 4'(tx_count)] <= tx_char;
            tx_count <= tx_count + ((tx_push && !tx_full) ? 5'd1 : 5'd0)
                                 - ((!tx_empty && (tx_timer >= UART_CYCLES)) ? 5'd1 : 5'd0);

            // --- timer0
            if (t_en) begin
                if (t_value == 0) begin
                    t_value     <= t_reload;
                    t_zero_pend <= 1'b1;
                end else begin
                    t_value <= t_value - 1;
                end
            end
        end
    end

endmodule : LITEX_PERIPH
