//---------------------------------------------------------------------------
// SD_MODEL.sv
//
// The LiteSDCard of the Arty build (litesdcard core + phy, block2mem and
// mem2block DMA, event manager), at the level of its registers, with an
// SDHC card behind it whose contents come from a disk image (+sdimg=<file>).
// It is what the Linux driver litex_mmc talks to, so that the kernel can
// mount its root from the "SD card" as it does on the board.
//
//   CSRs at 0x1200_2000 (LitexSystem/build/csr.csv), 32 bit, big ordering
//   (the high word of a wide CSR first). The register port comes from
//   LITEX_PERIPH: writes one cycle late, reads combinational from `regs`.
//
//   0x00 phy  card_detect (0 = present), clocker_divider, init_initialize,
//             cmdr_timeout, dataw_status, datar_timeout, settings
//   0x1c core cmd_argument, cmd_command, cmd_send, cmd_response (4 words),
//             cmd_event, data_event, block_length, block_count
//   0x48 block2mem base (2), length, enable, done, loop, offset, error
//   0x68 mem2block base (2), length, enable, done, loop, offset, error
//   0x88 ev   status, pending, enable
//             bit 0 card_detect (pulse), 1 block2mem (pulse),
//             2 mem2block (pulse), 3 data_done (level), 4 cmd_done (level)
//
// Core, as litesdcard/core.py: a cmd_send clears cmd_done and data_done;
// cmd_done comes with the response, data_done when the core is idle again,
// that is after the last byte of a read has gone to block2mem, or the
// last block of a write has been taken by the card. A timeout ends the
// command with done | timeout. A short response is exposed as the 48 bit
// frame without its last byte (index and 32 bit payload in bits 39:0), a
// long one as the 128 bits of CID / CSD.
//
// DMA, as the LiteX Wishbone DMA behind the 32 to 64 bit up-converter and
// Wishbone2AXILite: one 32 bit word per AXI4-Lite transfer at the double
// word address, write strobes 0x0F / 0xF0, one transfer at a time.
// block2mem writes what the card reads, mem2block fetches ahead of the card
// into a 16 word FIFO. `done` is enable & (offset == length); writing
// enable resets the engine.
//
// Card: SDHC, block addressed, C_SIZE from the image size. Commands:
// 0, 2, 3, 6 (64 byte status, no high speed), 7, 8, 9, 12, 13, 16, 17, 18,
// 24, 25, 55, and ACMD 6, 13 (64 bytes of zeros), 41, 51 (SCR: SD 2.0, 1/4
// bit, no CMD23). Everything else times out, which is what an SD card does
// to the SDIO / MMC probes of Linux.
//
// Speed: the card side runs at about the rate of a 25 MHz 4 bit bus (a
// 32 bit word every WORD_CYCLES), so DMA and CPU traffic interleave as
// they do on the board.
//
//   +sdimg=<file>   the disk image (raw, MBR); without it no card is present
//   +sdlog          print every command
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module SD_MODEL
    #(
        parameter int IMG_MAX     = 64 * 1024 * 1024,
        parameter int CMD_CYCLES  = 200,     // command + response
        parameter int WORD_CYCLES = 16,      // 4 bytes on a 25 MHz 4 bit bus
        parameter int BLK_GAP     = 100,     // between read blocks
        parameter int WR_BUSY     = 500      // card busy after a written block
    )
    (
        input  logic         clk,
        input  logic         rst_n,

        // register port (word index 0..63 of the 256 byte window)
        input  logic         wr0_en,
        input  logic [5:0]   wr0_idx,
        input  logic [31:0]  wr0_dat,
        input  logic         wr1_en,
        input  logic [5:0]   wr1_idx,
        input  logic [31:0]  wr1_dat,
        output logic [64*32-1:0] regs,

        output logic         irq,

        // AXI4-Lite master into the DMA port of the CPU
        output logic [31:0]  m_awaddr,
        output logic         m_awvalid,
        input  logic         m_awready,
        output logic [63:0]  m_wdata,
        output logic [7:0]   m_wstrb,
        output logic         m_wvalid,
        input  logic         m_wready,
        input  logic [1:0]   m_bresp,
        input  logic         m_bvalid,
        output logic         m_bready,
        output logic [31:0]  m_araddr,
        output logic         m_arvalid,
        input  logic         m_arready,
        input  logic [63:0]  m_rdata,
        input  logic [1:0]   m_rresp,
        input  logic         m_rvalid,
        output logic         m_rready
    );

    //-----------------------------------------------------------------
    // the image
    //-----------------------------------------------------------------
    logic [7:0] disk [0:IMG_MAX-1];
    int         img_bytes;
    bit         present, sdlog;
    string      img_file;
    logic [21:0] c_size;

    initial begin
        int fd, n;
        present   = 1'b0;
        img_bytes = 0;
        sdlog     = $test$plusargs("sdlog");
        if ($value$plusargs("sdimg=%s", img_file)) begin
            fd = $fopen(img_file, "rb");
            if (fd == 0) begin
                $display("SD_MODEL: cannot open %s", img_file);
                $finish;
            end
            n = $fread(disk, fd);
            $fclose(fd);
            img_bytes = n;
            present   = 1'b1;
            $display("SD_MODEL: %s, %0d bytes", img_file, img_bytes);
        end
        c_size = 22'((img_bytes / (512 * 1024)) - 1);
    end

    //-----------------------------------------------------------------
    // registers
    //-----------------------------------------------------------------
    logic [31:0]  cmd_argument, cmd_command;
    logic [127:0] cmd_response;
    logic         cmd_done, cmd_timeout, data_done;
    logic [9:0]   block_length;
    logic [31:0]  block_count;
    logic [63:0]  b2m_base, m2b_base;
    logic [31:0]  b2m_length, m2b_length, b2m_offset, m2b_offset;
    logic         b2m_enable, m2b_enable;
    logic [4:0]   ev_pending_p, ev_enable;       // pulse pending bits (0..2)
    logic [4:0]   ev_status;
    logic         b2m_done, m2b_done;

    assign b2m_done  = b2m_enable && (b2m_offset == b2m_length) && (b2m_length != 0);
    assign m2b_done  = m2b_enable && (m2b_offset == m2b_length) && (m2b_length != 0);
    assign ev_status = {cmd_done, data_done, 3'b000};
    // level sources: pending is the status; pulse sources: latched
    logic [4:0] ev_pending;
    assign ev_pending = {cmd_done, data_done, ev_pending_p[2:0]};
    assign irq        = |(ev_pending & ev_enable);

    always @(*) begin
        regs = '0;
        regs[32*0  +: 32] = {31'd0, ~present};
        regs[32*7  +: 32] = cmd_argument;
        regs[32*8  +: 32] = cmd_command;
        regs[32*10 +: 32] = cmd_response[127:96];
        regs[32*11 +: 32] = cmd_response[95:64];
        regs[32*12 +: 32] = cmd_response[63:32];
        regs[32*13 +: 32] = cmd_response[31:0];
        regs[32*14 +: 32] = {28'd0, 1'b0, cmd_timeout, 1'b0, cmd_done};
        regs[32*15 +: 32] = {31'd0, data_done};
        regs[32*16 +: 32] = {22'd0, block_length};
        regs[32*17 +: 32] = block_count;
        regs[32*18 +: 32] = b2m_base[63:32];
        regs[32*19 +: 32] = b2m_base[31:0];
        regs[32*20 +: 32] = b2m_length;
        regs[32*21 +: 32] = {31'd0, b2m_enable};
        regs[32*22 +: 32] = {31'd0, b2m_done};
        regs[32*24 +: 32] = b2m_offset;
        regs[32*26 +: 32] = m2b_base[63:32];
        regs[32*27 +: 32] = m2b_base[31:0];
        regs[32*28 +: 32] = m2b_length;
        regs[32*29 +: 32] = {31'd0, m2b_enable};
        regs[32*30 +: 32] = {31'd0, m2b_done};
        regs[32*32 +: 32] = m2b_offset;
        regs[32*34 +: 32] = {27'd0, ev_status};
        regs[32*35 +: 32] = {27'd0, ev_pending};
        regs[32*36 +: 32] = {27'd0, ev_enable};
    end

    //-----------------------------------------------------------------
    // FIFOs between the card and the DMA engines (words)
    //-----------------------------------------------------------------
    localparam int FD = 128;
    logic [31:0] rf [0:FD-1];            // card -> block2mem
    int          rf_wr, rf_rd, rf_cnt;
    logic [31:0] wf [0:15];              // mem2block -> card
    int          wf_wr, wf_rd, wf_cnt;

    //-----------------------------------------------------------------
    // card
    //-----------------------------------------------------------------
    typedef enum logic [2:0] {C_IDLE, C_CMD, C_RD, C_RD_GAP, C_WR, C_WR_BUSY} c_state_t;
    c_state_t    c_state;
    int          c_timer;
    bit          app_cmd;                // the last command was CMD55
    logic [5:0]  c_cmd;
    logic [1:0]  c_rsp_type, c_data_type;
    logic [31:0] c_arg;
    // the data of a read: from the image (ofs) or from small_buf
    bit          c_from_img;
    longint      c_ofs;                  // byte offset in the image / small_buf
    int          c_blk, c_byte;          // block number, byte in the block
    logic [7:0]  small_buf [0:63];

    localparam logic [15:0] RCA = 16'h13ab;
    localparam logic [31:0] ST_TRAN = 32'h0000_0900;   // tran, ready for data

    function automatic logic [127:0] cid();
        // MID 03, OID "SD", PNM "SE032", PRV 0x80, PSN, MDT
        return {8'h03, "SD", "SE032", 8'h80, 32'h1234_5678, 4'h0, 12'h1A9, 8'h01};
    endfunction
    function automatic logic [127:0] csd();
        // CSD 2.0 : TAAC 0E, NSAC 0, TRAN_SPEED 32 (25 MHz), CCC 5B5,
        // READ_BL_LEN 9, C_SIZE, WRITE_BL_LEN 9
        return {32'h400E_0032, 16'h5B59, 10'd0, c_size, 16'h7F80, 32'h0A40_0001};
    endfunction

    function automatic logic [127:0] short_rsp(input logic [5:0] idx, input logic [31:0] v);
        return {88'd0, 2'b00, idx, v};
    endfunction

    // what the card answers; returns 0 when it does not answer (timeout)
    function automatic bit answer(input logic [5:0] cmd, input logic [31:0] arg,
                                  input bit acmd, output logic [127:0] rsp);
        logic [31:0] st;
        st  = ST_TRAN | (acmd ? 32'h20 : 32'h0);
        rsp = '0;
        if (acmd) begin
            case (cmd)
                6'd6, 6'd13, 6'd51: begin rsp = short_rsp(cmd, st); return 1; end
                6'd41: begin rsp = short_rsp(6'h3F, 32'hC0FF_8000); return 1; end
                default: ;
            endcase
        end
        case (cmd)
            6'd0:  return 1;                                        // no response
            6'd2:  begin rsp = cid(); return 1; end
            6'd3:  begin rsp = short_rsp(cmd, {RCA, 16'h0500}); return 1; end
            6'd6, 6'd7, 6'd12, 6'd13, 6'd16, 6'd17, 6'd18, 6'd24, 6'd25:
                   begin rsp = short_rsp(cmd, st); return 1; end
            6'd8:  begin rsp = short_rsp(cmd, {20'd0, arg[11:0]}); return 1; end
            6'd9:  begin rsp = csd(); return 1; end
            6'd55: begin rsp = short_rsp(cmd, ST_TRAN | 32'h20); return 1; end
            default: return 0;
        endcase
    endfunction

    //-----------------------------------------------------------------
    // DMA master : one AXI4-Lite transfer at a time
    //-----------------------------------------------------------------
    typedef enum logic [2:0] {D_IDLE, D_W, D_B, D_AR, D_R} d_state_t;
    d_state_t    d_state;
    logic [31:0] d_addr;
    logic        aw_done, w_done;
    logic        d_stale;              // its engine was reset meanwhile

    assign m_awvalid = (d_state == D_W) & ~aw_done;
    assign m_wvalid  = (d_state == D_W) & ~w_done;
    assign m_bready  = (d_state == D_B);
    assign m_arvalid = (d_state == D_AR);
    assign m_rready  = (d_state == D_R);
    assign m_awaddr  = {d_addr[31:3], 3'b000};
    assign m_araddr  = {d_addr[31:3], 3'b000};

    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_argument <= '0; cmd_command <= '0; cmd_response <= '0;
            cmd_done <= 1'b1; cmd_timeout <= 1'b0; data_done <= 1'b1;
            block_length <= '0; block_count <= '0;
            b2m_base <= '0; b2m_length <= '0; b2m_offset <= '0; b2m_enable <= 1'b0;
            m2b_base <= '0; m2b_length <= '0; m2b_offset <= '0; m2b_enable <= 1'b0;
            ev_pending_p <= '0; ev_enable <= '0;
            c_state <= C_IDLE; c_timer <= 0; app_cmd <= 1'b0;
            rf_wr <= 0; rf_rd <= 0; rf_cnt <= 0;
            wf_wr <= 0; wf_rd <= 0; wf_cnt <= 0;
            d_state <= D_IDLE; aw_done <= 1'b0; w_done <= 1'b0; d_stale <= 1'b0;
            m_wdata <= '0; m_wstrb <= '0; d_addr <= '0;
        end else begin
            int rf_push, rf_pop, wf_push, wf_pop;
            bit b2m_reset, m2b_reset;
            rf_push = 0; rf_pop = 0; wf_push = 0; wf_pop = 0;
            b2m_reset = 0; m2b_reset = 0;

            //---------------------------------------------------------
            // register writes
            //---------------------------------------------------------
            for (int p = 0; p < 2; p++) begin
                logic        en;
                logic [5:0]  ix;
                logic [31:0] v;
                en = p ? wr1_en  : wr0_en;
                ix = p ? wr1_idx : wr0_idx;
                v  = p ? wr1_dat : wr0_dat;
                if (en) begin
                    case (ix)
                        6'd7:  cmd_argument <= v;
                        6'd8:  cmd_command  <= v;
                        6'd9:  if (c_state == C_IDLE) begin
                                   c_cmd       <= cmd_command[13:8];
                                   c_rsp_type  <= cmd_command[1:0];
                                   c_data_type <= cmd_command[6:5];
                                   c_arg       <= cmd_argument;
                                   cmd_done    <= 1'b0;
                                   cmd_timeout <= 1'b0;
                                   data_done   <= 1'b0;
                                   c_timer     <= CMD_CYCLES;
                                   c_state     <= C_CMD;
                               end
                        6'd16: block_length <= v[9:0];
                        6'd17: block_count  <= v;
                        6'd18: b2m_base[63:32] <= v;
                        6'd19: b2m_base[31:0]  <= v;
                        6'd20: b2m_length <= v;
                        6'd21: begin
                                   b2m_enable <= v[0];
                                   b2m_offset <= '0;
                                   b2m_reset  = 1;
                               end
                        6'd26: m2b_base[63:32] <= v;
                        6'd27: m2b_base[31:0]  <= v;
                        6'd28: m2b_length <= v;
                        6'd29: begin
                                   m2b_enable <= v[0];
                                   m2b_offset <= '0;
                                   m2b_reset  = 1;
                               end
                        6'd35: ev_pending_p <= ev_pending_p & ~v[4:0];
                        6'd36: ev_enable    <= v[4:0];
                        default: ;
                    endcase
                end
            end

            //---------------------------------------------------------
            // card
            //---------------------------------------------------------
            case (c_state)
                C_IDLE: ;
                C_CMD: begin
                    if (c_timer > 0) c_timer <= c_timer - 1;
                    else begin
                        logic [127:0] rsp;
                        bit           ok;
                        bit           acmd;
                        acmd = app_cmd;
                        ok   = present && answer(c_cmd, c_arg, acmd, rsp);
                        if (sdlog)
                            $display("[SD] %sCMD%0d arg=%08h rsp_type=%0d data=%0d -> %s",
                                     acmd ? "A" : "", c_cmd, c_arg, c_rsp_type, c_data_type,
                                     ok ? "ok" : "timeout");
                        app_cmd <= (c_cmd == 6'd55) && ok;
                        if (!ok) begin
                            cmd_timeout <= 1'b1;
                            cmd_done    <= 1'b1;
                            data_done   <= 1'b1;
                            c_state     <= C_IDLE;
                        end else begin
                            cmd_response <= rsp;
                            cmd_done     <= 1'b1;
                            c_blk  <= 0;
                            c_byte <= 0;
                            c_timer <= BLK_GAP;
                            if (c_data_type == 2'd1) begin
                                // read : from the image or a small buffer
                                c_from_img <= !acmd && ((c_cmd == 6'd17) || (c_cmd == 6'd18));
                                c_ofs      <= longint'(c_arg) * 512;
                                for (int i = 0; i < 64; i++) small_buf[i] = 8'h00;
                                if (acmd && (c_cmd == 6'd51)) begin
                                    small_buf[0] = 8'h02;          // SD 2.0
                                    small_buf[1] = 8'h35;          // security 3, 1/4 bit
                                    small_buf[2] = 8'h80;          // SD_SPEC3
                                end
                                if (!acmd && (c_cmd == 6'd6))
                                    small_buf[13] = 8'h01;         // group 1: default only
                                c_state <= C_RD_GAP;
                            end else if (c_data_type == 2'd2) begin
                                c_ofs   <= longint'(c_arg) * 512;
                                c_timer <= WORD_CYCLES;
                                c_state <= C_WR;
                            end else begin
                                data_done <= 1'b1;
                                c_state   <= C_IDLE;
                            end
                        end
                    end
                end
                C_RD_GAP: begin
                    if (c_timer > 0) c_timer <= c_timer - 1;
                    else begin
                        c_timer <= WORD_CYCLES;
                        c_state <= C_RD;
                    end
                end
                C_RD: begin
                    // one word every WORD_CYCLES, if block2mem has room
                    if (c_timer > 0) c_timer <= c_timer - 1;
                    else if (rf_cnt < FD) begin
                        logic [31:0] w;
                        for (int b = 0; b < 4; b++) begin
                            longint a;
                            a = c_ofs + c_byte + b;
                            if (c_from_img)
                                w[8*b +: 8] = (a < img_bytes) ? disk[a] : 8'h00;
                            else
                                w[8*b +: 8] = small_buf[(c_byte + b) % 64];
                        end
                        if (b2m_enable) begin
                            rf[rf_wr] <= w;
                            rf_wr     <= (rf_wr + 1) % FD;
                            rf_push   = 1;
                        end
                        c_timer <= WORD_CYCLES;
                        if (c_byte + 4 >= int'(block_length)) begin
                            c_byte <= 0;
                            c_ofs  <= c_ofs + longint'(block_length);
                            c_blk  <= c_blk + 1;
                            if (c_blk + 1 >= int'(block_count)) begin
                                data_done <= 1'b1;
                                c_state   <= C_IDLE;
                            end else begin
                                c_timer <= BLK_GAP;
                                c_state <= C_RD_GAP;
                            end
                        end else begin
                            c_byte <= c_byte + 4;
                        end
                    end
                end
                C_WR: begin
                    if (c_timer > 0) c_timer <= c_timer - 1;
                    else if (wf_cnt > 0) begin
                        logic [31:0] w;
                        w = wf[wf_rd];
                        for (int b = 0; b < 4; b++)
                            if (c_ofs + c_byte + b < img_bytes)
                                disk[c_ofs + c_byte + b] = w[8*b +: 8];
                        wf_rd   <= (wf_rd + 1) % 16;
                        wf_pop  = 1;
                        c_timer <= WORD_CYCLES;
                        if (c_byte + 4 >= int'(block_length)) begin
                            c_byte  <= 0;
                            c_ofs   <= c_ofs + longint'(block_length);
                            c_blk   <= c_blk + 1;
                            c_timer <= WR_BUSY;
                            c_state <= C_WR_BUSY;
                        end else begin
                            c_byte <= c_byte + 4;
                        end
                    end
                end
                C_WR_BUSY: begin
                    if (c_timer > 0) c_timer <= c_timer - 1;
                    else if (c_blk >= int'(block_count)) begin
                        data_done <= 1'b1;
                        c_state   <= C_IDLE;
                    end else begin
                        c_timer <= WORD_CYCLES;
                        c_state <= C_WR;
                    end
                end
                default: c_state <= C_IDLE;
            endcase

            //---------------------------------------------------------
            // DMA engines, one AXI4-Lite transfer at a time
            //---------------------------------------------------------
            case (d_state)
                D_IDLE: begin
                    if (b2m_enable && (rf_cnt > 0) && (b2m_offset < b2m_length)) begin
                        logic [31:0] a;
                        a = b2m_base[31:0] + b2m_offset;
                        d_addr  <= a;
                        m_wdata <= {rf[rf_rd], rf[rf_rd]};
                        m_wstrb <= a[2] ? 8'hF0 : 8'h0F;
                        aw_done <= 1'b0;
                        w_done  <= 1'b0;
                        d_state <= D_W;
                    end else if (m2b_enable && (m2b_offset < m2b_length) && (wf_cnt < 16)) begin
                        d_addr  <= m2b_base[31:0] + m2b_offset;
                        d_state <= D_AR;
                    end
                end
                D_W: begin
                    if (m_awvalid && m_awready) aw_done <= 1'b1;
                    if (m_wvalid  && m_wready)  w_done  <= 1'b1;
                    if ((aw_done || (m_awvalid && m_awready)) &&
                        (w_done  || (m_wvalid  && m_wready)))
                        d_state <= D_B;
                end
                D_B: if (m_bvalid) begin
                    if (m_bresp != 2'b00)
                        $display("SD_MODEL: DMA write error at %08h", d_addr);
                    if (!d_stale && !b2m_reset) begin
                        rf_rd  <= (rf_rd + 1) % FD;
                        rf_pop = 1;
                        b2m_offset <= b2m_offset + 4;
                        if (b2m_offset + 4 == b2m_length) ev_pending_p[1] <= 1'b1;
                    end
                    d_stale <= 1'b0;
                    d_state <= D_IDLE;
                end
                D_AR: if (m_arready) d_state <= D_R;
                D_R: if (m_rvalid) begin
                    if (m_rresp != 2'b00)
                        $display("SD_MODEL: DMA read error at %08h", d_addr);
                    // an enable written meanwhile has reset the engine
                    if (!d_stale && !m2b_reset) begin
                        wf[wf_wr] <= d_addr[2] ? m_rdata[63:32] : m_rdata[31:0];
                        wf_wr     <= (wf_wr + 1) % 16;
                        wf_push   = 1;
                        m2b_offset <= m2b_offset + 4;
                        if (m2b_offset + 4 == m2b_length) ev_pending_p[2] <= 1'b1;
                    end
                    d_stale <= 1'b0;
                    d_state <= D_IDLE;
                end
                default: d_state <= D_IDLE;
            endcase

            // a transfer in flight for an engine that is reset now is
            // finished on the bus but its data is dropped
            if ((b2m_reset && (d_state == D_W || d_state == D_B)) ||
                (m2b_reset && (d_state == D_AR || d_state == D_R)))
                d_stale <= 1'b1;
            if (b2m_reset) begin
                rf_wr <= 0; rf_rd <= 0; rf_cnt <= 0;
            end else begin
                rf_cnt <= rf_cnt + rf_push - rf_pop;
            end
            if (m2b_reset) begin
                wf_wr <= 0; wf_rd <= 0; wf_cnt <= 0;
            end else begin
                wf_cnt <= wf_cnt + wf_push - wf_pop;
            end
        end
    end

endmodule : SD_MODEL
