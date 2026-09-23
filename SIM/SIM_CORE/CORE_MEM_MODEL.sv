//---------------------------------------------------------------------------
// CORE_MEM_MODEL.sv
//
// Memory model with the cache port protocol (CPU_CACHE_SPEC.md 5), used to
// test the core on its own: one request per cycle, answers in order after a
// fixed number of cycles. The real caches are exercised in SIM_CPU.
//
//   - LOAD  : the answer is right aligned and zero extended, like the cache
//   - STORE : byte strobes from the size and the offset
//   - LR / SC and the atomic operations of the A extension, with the
//     reservation kept per cache line, exactly as DCACHE does it
//   - FENCE / FLUSH : answered immediately
//   - addresses outside a known region return an error (access fault)
//
//   Besides the memory the data port reaches three more regions, which is
//   what the system looks like: the CLINT of the core, the PLIC, and two
//   registers of the test bench. The first of those raises the external
//   interrupt lines by hand (for the tests that want no controller in the
//   way), the second is the source vector that goes into the PLIC.
//
//   The port presents the virtual address with the request and the physical
//   one in the cycle after the request was taken (CPU_CACHE_SPEC.md 5.6).
//   This model does what the cache does with that: it takes the request into
//   a register and resolves it from the physical address one cycle later.
//   Without it a test that turns the MMU on would look for its data at the
//   virtual address.
//
//   +istall=<n> / +dstall=<n> hold the ready line of the port low in about
//   n percent of the cycles, which exercises the back pressure paths of the
//   core. The data port also checks the rule of M1 that the core keeps at
//   most one access in flight.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_MEM_MODEL
    #(
        parameter int          PADDR_WIDTH = 40,
        parameter logic [63:0] BASE_ADDR   = 64'h0000_0000_8000_0000,
        parameter int          WORDS       = 8192,      // 64 KiB
        parameter logic [63:0] CLINT_BASE  = 64'h0000_0000_0200_0000,
        parameter logic [63:0] TBREG_BASE  = 64'h0000_0000_0300_0000,
        parameter logic [63:0] PLIC_BASE   = 64'h0000_0000_0C00_0000,
        parameter int          LINE_BYTES  = 64,         // like the data cache
        parameter int          I_LATENCY   = 2,
        parameter int          D_LATENCY   = 3
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // instruction port
        input  logic                    i_req_valid,
        output logic                    i_req_ready,
        input  logic [PADDR_WIDTH-1:0]  i_req_addr,
        input  logic [PADDR_WIDTH-1:0]  i_req_paddr,
        // like the instruction cache: a kill drops every answer that is in
        // flight, nothing is returned for those requests
        input  logic                    i_kill,
        // like the instruction cache: the request whose physical address is
        // presented in this cycle is dropped, the ones before it are not
        input  logic                    i_cancel,
        output logic                    i_resp_valid,
        output logic [63:0]             i_resp_data,
        output logic                    i_resp_error,

        // data port
        input  logic                    d_req_valid,
        output logic                    d_req_ready,
        input  logic [PADDR_WIDTH-1:0]  d_req_addr,
        input  logic [PADDR_WIDTH-1:0]  d_req_paddr,
        input  logic [1:0]              d_req_size,
        input  logic [3:0]              d_req_cmd,
        input  logic [63:0]             d_req_wdata,
        output logic                    d_resp_valid,
        output logic [63:0]             d_resp_data,
        output logic                    d_resp_error,

        // CLINT (the model routes the accesses of its region to it)
        output logic                    clint_sel,
        output logic                    clint_we,
        output logic [15:0]             clint_addr,
        output logic [63:0]             clint_wdata,
        output logic [7:0]              clint_wstrb,
        input  logic [63:0]             clint_rdata,

        // PLIC, the same kind of port
        output logic                    plic_sel,
        output logic                    plic_we,
        output logic [21:0]             plic_addr,
        output logic [63:0]             plic_wdata,
        output logic [7:0]              plic_wstrb,
        input  logic [63:0]             plic_rdata,

        // the interrupt lines the bench raises by hand: bit 0 and 1 go
        // straight to the core, the second word is the source vector of the
        // PLIC
        output logic [31:0]             plic_src,

        // register of the test bench: bit 0 is the external interrupt
        output logic                    irq_ext,      // bit 0 : machine
        output logic                    irq_s_ext,    // bit 1 : supervisor

        // sticky : the core broke the rules of the port
        output logic                    prot_error
    );

    localparam logic [3:0] CMD_LOAD   = 4'd0;
    localparam logic [3:0] CMD_STORE  = 4'd1;
    localparam logic [3:0] CMD_LR     = 4'd2;
    localparam logic [3:0] CMD_SC     = 4'd3;
    localparam logic [3:0] CMD_AMO_LO = 4'd4;
    localparam logic [3:0] CMD_AMO_HI = 4'd12;
    localparam logic [3:0] CMD_FENCE  = 4'd13;
    localparam logic [3:0] CMD_FLUSH  = 4'd14;

    // the memory is cleared and loaded by the test bench (one initial block,
    // so that the order is defined)
    logic [63:0] mem [0:WORDS-1];

    function automatic int widx(input logic [PADDR_WIDTH-1:0] a);
        return int'((a - BASE_ADDR[PADDR_WIDTH-1:0]) >> 3);
    endfunction
    function automatic bit in_range(input logic [PADDR_WIDTH-1:0] a);
        return (a >= BASE_ADDR[PADDR_WIDTH-1:0]) &&
               (a <  BASE_ADDR[PADDR_WIDTH-1:0] + PADDR_WIDTH'(8 * WORDS));
    endfunction
    function automatic bit in_clint(input logic [PADDR_WIDTH-1:0] a);
        return (a >= CLINT_BASE[PADDR_WIDTH-1:0]) &&
               (a <  CLINT_BASE[PADDR_WIDTH-1:0] + PADDR_WIDTH'(65536));
    endfunction
    function automatic bit in_plic(input logic [PADDR_WIDTH-1:0] a);
        return (a >= PLIC_BASE[PADDR_WIDTH-1:0]) &&
               (a <  PLIC_BASE[PADDR_WIDTH-1:0] + PADDR_WIDTH'(4*1024*1024));
    endfunction

    function automatic bit in_tbreg(input logic [PADDR_WIDTH-1:0] a);
        return (a[PADDR_WIDTH-1:4] == TBREG_BASE[PADDR_WIDTH-1:4]);
    endfunction
    function automatic bit mapped(input logic [PADDR_WIDTH-1:0] a);
        return in_range(a) || in_clint(a) || in_tbreg(a) || in_plic(a);
    endfunction

    // right align and zero extend, as the cache does
    function automatic logic [63:0] extract(input logic [63:0] word,
                                            input logic [2:0]  lsb,
                                            input logic [1:0]  size);
        logic [63:0] v;
        v = word >> (8 * int'(lsb));
        case (size)
            2'd0:    return {56'd0, v[7:0]};
            2'd1:    return {48'd0, v[15:0]};
            2'd2:    return {32'd0, v[31:0]};
            default: return v;
        endcase
    endfunction

    function automatic logic [7:0] strb(input logic [2:0] lsb, input logic [1:0] size);
        case (size)
            2'd0:    return 8'h01 << lsb;
            2'd1:    return 8'h03 << lsb;
            2'd2:    return 8'h0F << lsb;
            default: return 8'hFF;
        endcase
    endfunction

    // DCACHE.sv amo_calc
    function automatic logic [63:0] amo_calc(input logic [3:0]  cmd,
                                             input logic [1:0]  size,
                                             input logic [63:0] old_v,
                                             input logic [63:0] src);
        logic signed [63:0] so, ss;
        logic [63:0] o, s;
        if (size == 2'd2) begin
            o  = {32'd0, old_v[31:0]};
            s  = {32'd0, src[31:0]};
            so = {{32{old_v[31]}}, old_v[31:0]};
            ss = {{32{src[31]}},   src[31:0]};
        end else begin
            o  = old_v;  s  = src;
            so = old_v;  ss = src;
        end
        case (cmd)
            4'd4:    return s;
            4'd5:    return o + s;
            4'd6:    return o ^ s;
            4'd7:    return o & s;
            4'd8:    return o | s;
            4'd9:    return (so < ss) ? o : s;
            4'd10:   return (so < ss) ? s : o;
            4'd11:   return (o  < s)  ? o : s;
            default: return (o  < s)  ? s : o;
        endcase
    endfunction

    // the core hands the data of a store over right aligned; the cache moves
    // it into its lane (DCACHE.sv align_wdata)
    function automatic logic [63:0] align_wdata(input logic [2:0] lsb, input logic [63:0] d);
        return d << (8 * lsb);
    endfunction

    //-----------------------------------------------------------------
    // back pressure : ready is held low in about <n> percent of the cycles
    //-----------------------------------------------------------------
    int          i_stall_pct, d_stall_pct;
    logic [31:0] i_lfsr, d_lfsr;
    logic        i_stall, d_stall;

    initial begin
        if (!$value$plusargs("istall=%d", i_stall_pct)) i_stall_pct = 0;
        if (!$value$plusargs("dstall=%d", d_stall_pct)) d_stall_pct = 0;
    end

    assign i_stall = (int'(i_lfsr[6:0]) % 100) < i_stall_pct;
    assign d_stall = (int'(d_lfsr[6:0]) % 100) < d_stall_pct;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_lfsr <= 32'h1234_5678;
            d_lfsr <= 32'h8765_4321;
        end else begin
            i_lfsr <= {i_lfsr[30:0], i_lfsr[31] ^ i_lfsr[21] ^ i_lfsr[1] ^ i_lfsr[0]};
            d_lfsr <= {d_lfsr[30:0], d_lfsr[31] ^ d_lfsr[21] ^ d_lfsr[1] ^ d_lfsr[0]};
        end
    end

    //-----------------------------------------------------------------
    // instruction port : a shift register of I_LATENCY stages
    //-----------------------------------------------------------------
    logic [I_LATENCY:0]        ip_valid;
    logic [63:0]               ip_data  [0:I_LATENCY];
    logic [I_LATENCY:0]        ip_error;

    assign i_req_ready  = ~i_stall;
    assign i_resp_valid = ip_valid[0];
    assign i_resp_data  = ip_data[0];
    assign i_resp_error = ip_error[0];

    //-----------------------------------------------------------------
    // data port
    //-----------------------------------------------------------------
    logic [D_LATENCY:0]        dp_valid;
    logic [63:0]               dp_data  [0:D_LATENCY];
    logic [D_LATENCY:0]        dp_error;

    assign d_req_ready  = ~d_stall;
    assign d_resp_valid = dp_valid[0];
    assign d_resp_data  = dp_data[0];
    assign d_resp_error = dp_error[0];

    // M1 keeps one data access in flight; more than one would mean the
    // busy interlock of CORE_LSU is broken
    int outstanding;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            outstanding <= 0;
            prot_error  <= 1'b0;
        end else begin
            if (d_req_valid && d_req_ready && !d_resp_valid) begin
                if (outstanding >= 1) begin
                    prot_error <= 1'b1;
                    $display("[%0t] CORE_MEM_MODEL: a second data access was issued while one was outstanding", $time);
                end
                outstanding <= outstanding + 1;
            end else if (d_resp_valid && !(d_req_valid && d_req_ready)) begin
                outstanding <= outstanding - 1;
            end
        end
    end

    //-----------------------------------------------------------------
    // stage 1 : the request, and the address the cache would use
    //
    //   Only the page offset is taken from the virtual address, the rest
    //   from the physical one, which is what DCACHE builds s1_paddr from.
    //-----------------------------------------------------------------
    logic                   s1i_valid;
    logic [PADDR_WIDTH-1:0] s1i_vaddr, s1i_addr;
    logic                   s1d_valid;
    logic [PADDR_WIDTH-1:0] s1d_vaddr, s1d_addr;
    logic [1:0]             s1d_size;
    logic [3:0]             s1d_cmd;
    logic [63:0]            s1d_wdata;

    assign s1i_addr = {i_req_paddr[PADDR_WIDTH-1:12], s1i_vaddr[11:0]};
    assign s1d_addr = {d_req_paddr[PADDR_WIDTH-1:12], s1d_vaddr[11:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1i_valid <= 1'b0;
            s1d_valid <= 1'b0;
            s1i_vaddr <= '0;
            s1d_vaddr <= '0;
            s1d_size  <= 2'd0;
            s1d_cmd   <= 4'd0;
            s1d_wdata <= 64'd0;
        end else begin
            s1i_valid <= i_req_valid & i_req_ready & ~i_kill;
            if (i_req_valid & i_req_ready) s1i_vaddr <= i_req_addr;
            s1d_valid <= d_req_valid & d_req_ready;
            if (d_req_valid & d_req_ready) begin
                s1d_vaddr <= d_req_addr;
                s1d_size  <= d_req_size;
                s1d_cmd   <= d_req_cmd;
                s1d_wdata <= d_req_wdata;
            end
        end
    end

    logic [63:0] rd_word, wr_word;
    logic [63:0] wr_data;
    logic        sc_hit;

    // the reservation of LR / SC, per cache line as in DCACHE
    logic                    res_valid;
    logic [PADDR_WIDTH-1:0]  res_line;
    function automatic logic [PADDR_WIDTH-1:0] lidx(input logic [PADDR_WIDTH-1:0] a);
        return a / PADDR_WIDTH'(LINE_BYTES);
    endfunction

    // an access takes place this cycle
    logic       d_acc, d_is_amo, d_is_lr, d_is_sc, d_writes, d_reads;
    logic [7:0] wr_strb;
    assign d_is_amo = (s1d_cmd >= CMD_AMO_LO) && (s1d_cmd <= CMD_AMO_HI);
    assign d_is_lr  = (s1d_cmd == CMD_LR);
    assign d_is_sc  = (s1d_cmd == CMD_SC);
    assign d_acc    = s1d_valid &
                      ((s1d_cmd == CMD_LOAD) || (s1d_cmd == CMD_STORE) ||
                       d_is_lr || d_is_sc || d_is_amo);
    assign d_reads  = (s1d_cmd == CMD_LOAD) || d_is_lr || d_is_amo;
    assign d_writes = (s1d_cmd == CMD_STORE) || d_is_amo;
    assign wr_strb = strb(s1d_addr[2:0], s1d_size);

    assign plic_sel    = d_acc & in_plic(s1d_addr);
    assign plic_we     = (s1d_cmd == CMD_STORE);
    assign plic_addr   = s1d_addr[21:0];
    assign plic_wdata  = align_wdata(s1d_addr[2:0], s1d_wdata);
    assign plic_wstrb  = wr_strb;

    assign clint_sel   = d_acc & in_clint(s1d_addr);
    assign clint_we    = (s1d_cmd == CMD_STORE);
    assign clint_addr  = s1d_addr[15:0];
    assign clint_wdata = align_wdata(s1d_addr[2:0], s1d_wdata);
    assign clint_wstrb = wr_strb;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ip_valid <= '0;
            ip_error <= '0;
            dp_valid <= '0;
            dp_error <= '0;
            for (int i = 0; i <= I_LATENCY; i++) ip_data[i] <= 64'd0;
            for (int i = 0; i <= D_LATENCY; i++) dp_data[i] <= 64'd0;
            irq_ext   <= 1'b0;
            irq_s_ext <= 1'b0;
            plic_src  <= 32'd0;
            res_valid <= 1'b0;
            res_line  <= '0;
        end else begin
            //---------------------------------------------------------
            // instruction port
            //---------------------------------------------------------
            for (int i = 0; i < I_LATENCY; i++) begin
                ip_valid[i] <= ip_valid[i+1] & ~i_kill;
                ip_data[i]  <= ip_data[i+1];
                ip_error[i] <= ip_error[i+1];
            end
            ip_valid[I_LATENCY] <= s1i_valid & ~i_kill & ~i_cancel;
            ip_error[I_LATENCY] <= s1i_valid & ~in_range(s1i_addr);
            ip_data[I_LATENCY]  <= (s1i_valid & in_range(s1i_addr))
                                   ? mem[widx(s1i_addr)] : 64'd0;

            //---------------------------------------------------------
            // data port
            //---------------------------------------------------------
            for (int i = 0; i < D_LATENCY; i++) begin
                dp_valid[i] <= dp_valid[i+1];
                dp_data[i]  <= dp_data[i+1];
                dp_error[i] <= dp_error[i+1];
            end
            dp_valid[D_LATENCY] <= s1d_valid;
            dp_error[D_LATENCY] <= d_acc & ~mapped(s1d_addr);
            dp_data[D_LATENCY]  <= 64'd0;

            if (d_acc && in_range(s1d_addr)) begin
                rd_word  = mem[widx(s1d_addr)];
                sc_hit   = res_valid && (res_line == lidx(s1d_addr));
                wr_word  = rd_word;
                if (d_reads)
                    dp_data[D_LATENCY] <= extract(rd_word, s1d_addr[2:0], s1d_size);
                if (d_is_sc)
                    dp_data[D_LATENCY] <= sc_hit ? 64'd0 : 64'd1;

                if (d_writes || (d_is_sc && sc_hit)) begin
                    if (d_is_amo)
                        wr_data = align_wdata(s1d_addr[2:0],
                                     amo_calc(s1d_cmd, s1d_size,
                                              extract(rd_word, s1d_addr[2:0], s1d_size),
                                              s1d_wdata));
                    else
                        wr_data = align_wdata(s1d_addr[2:0], s1d_wdata);
                    for (int b = 0; b < 8; b++)
                        if (wr_strb[b]) wr_word[8*b +: 8] = wr_data[8*b +: 8];
                    mem[widx(s1d_addr)] <= wr_word;
                end

                // the reservation, kept per line like the cache
                if (d_is_lr) begin
                    res_valid <= 1'b1;
                    res_line  <= lidx(s1d_addr);
                end else if (d_is_sc) begin
                    res_valid <= 1'b0;
                end else if (d_writes && res_valid &&
                             (res_line == lidx(s1d_addr))) begin
                    res_valid <= 1'b0;
                end
            end else if (d_acc && in_clint(s1d_addr) && (s1d_cmd == CMD_LOAD)) begin
                dp_data[D_LATENCY] <= extract(clint_rdata, s1d_addr[2:0], s1d_size);
            end else if (d_acc && in_plic(s1d_addr) && (s1d_cmd == CMD_LOAD)) begin
                dp_data[D_LATENCY] <= extract(plic_rdata, s1d_addr[2:0], s1d_size);
            end else if (d_acc && in_tbreg(s1d_addr)) begin
                // the first word drives the two lines directly, the second
                // the source vector of the PLIC
                if (s1d_cmd == CMD_LOAD)
                    dp_data[D_LATENCY] <= s1d_addr[3]
                        ? extract({32'd0, plic_src}, s1d_addr[2:0], s1d_size)
                        : extract({62'd0, irq_s_ext, irq_ext},
                                  s1d_addr[2:0], s1d_size);
                else if ((s1d_cmd == CMD_STORE) && wr_strb[0]) begin
                    if (s1d_addr[3]) plic_src <= clint_wdata[31:0];
                    else begin
                        irq_ext   <= clint_wdata[0];
                        irq_s_ext <= clint_wdata[1];
                    end
                end
            end
        end
    end

endmodule : CORE_MEM_MODEL
