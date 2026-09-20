//---------------------------------------------------------------------------
// CORE_MEM_MODEL.sv
//
// Memory model with the cache port protocol (CPU_CACHE_SPEC.md 5), used to
// test the core on its own: one request per cycle, answers in order after a
// fixed number of cycles. The real caches are exercised in SIM_CPU.
//
//   - LOAD  : the answer is right aligned and zero extended, like the cache
//   - STORE : byte strobes from the size and the offset
//   - FENCE / FLUSH : answered immediately
//   - addresses outside the memory return an error
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
        // like the instruction cache: a kill drops every answer that is in
        // flight, nothing is returned for those requests
        input  logic                    i_kill,
        output logic                    i_resp_valid,
        output logic [63:0]             i_resp_data,
        output logic                    i_resp_error,

        // data port
        input  logic                    d_req_valid,
        output logic                    d_req_ready,
        input  logic [PADDR_WIDTH-1:0]  d_req_addr,
        input  logic [1:0]              d_req_size,
        input  logic [3:0]              d_req_cmd,
        input  logic [63:0]             d_req_wdata,
        output logic                    d_resp_valid,
        output logic [63:0]             d_resp_data,
        output logic                    d_resp_error,

        // sticky : the core broke the rules of the port
        output logic                    prot_error
    );

    localparam logic [3:0] CMD_LOAD  = 4'd0;
    localparam logic [3:0] CMD_STORE = 4'd1;
    localparam logic [3:0] CMD_FENCE = 4'd13;
    localparam logic [3:0] CMD_FLUSH = 4'd14;

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

    logic [63:0] rd_word, wr_word;
    logic [7:0]  wr_strb;
    logic [63:0] wr_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ip_valid <= '0;
            ip_error <= '0;
            dp_valid <= '0;
            dp_error <= '0;
            for (int i = 0; i <= I_LATENCY; i++) ip_data[i] <= 64'd0;
            for (int i = 0; i <= D_LATENCY; i++) dp_data[i] <= 64'd0;
        end else begin
            //---------------------------------------------------------
            // instruction port
            //---------------------------------------------------------
            for (int i = 0; i < I_LATENCY; i++) begin
                ip_valid[i] <= ip_valid[i+1] & ~i_kill;
                ip_data[i]  <= ip_data[i+1];
                ip_error[i] <= ip_error[i+1];
            end
            ip_valid[I_LATENCY] <= i_req_valid & i_req_ready & ~i_kill;
            ip_error[I_LATENCY] <= i_req_valid & i_req_ready & ~in_range(i_req_addr);
            ip_data[I_LATENCY]  <= (i_req_valid & i_req_ready & in_range(i_req_addr))
                                   ? mem[widx(i_req_addr)] : 64'd0;

            //---------------------------------------------------------
            // data port
            //---------------------------------------------------------
            for (int i = 0; i < D_LATENCY; i++) begin
                dp_valid[i] <= dp_valid[i+1];
                dp_data[i]  <= dp_data[i+1];
                dp_error[i] <= dp_error[i+1];
            end
            dp_valid[D_LATENCY] <= d_req_valid & d_req_ready;
            dp_error[D_LATENCY] <= d_req_valid & d_req_ready & ~in_range(d_req_addr) &
                                   ((d_req_cmd == CMD_LOAD) || (d_req_cmd == CMD_STORE));
            dp_data[D_LATENCY]  <= 64'd0;

            if (d_req_valid && d_req_ready && in_range(d_req_addr)) begin
                rd_word = mem[widx(d_req_addr)];
                if (d_req_cmd == CMD_LOAD) begin
                    dp_data[D_LATENCY] <= extract(rd_word, d_req_addr[2:0], d_req_size);
                end else if (d_req_cmd == CMD_STORE) begin
                    wr_strb = strb(d_req_addr[2:0], d_req_size);
                    wr_word = rd_word;
                    wr_data = align_wdata(d_req_addr[2:0], d_req_wdata);
                    for (int b = 0; b < 8; b++)
                        if (wr_strb[b]) wr_word[8*b +: 8] = wr_data[8*b +: 8];
                    mem[widx(d_req_addr)] <= wr_word;
                end
            end
        end
    end

endmodule : CORE_MEM_MODEL
