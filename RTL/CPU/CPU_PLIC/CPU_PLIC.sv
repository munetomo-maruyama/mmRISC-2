//---------------------------------------------------------------------------
// CPU_PLIC.sv
//
// Platform level interrupt controller (CPU_CORE_SPEC.md 8).
//
// The register map is the one of the RISC-V PLIC specification, relative to
// the base address of the block:
//
//   0x000000 + 4*s          priority of source s        (s = 1 .. SOURCES)
//   0x001000 + 4*w          pending, read only, 32 sources per word
//   0x002000 + 0x80*c + 4*w enable for context c
//   0x200000 + 0x1000*c + 0 priority threshold of context c
//   0x200000 + 0x1000*c + 4 claim on read, complete on write
//
// A context is a hart and a privilege level: with one hart, context 0 is its
// machine mode and context 1 its supervisor mode. That is the layout the
// device tree of Linux describes, and it is why the block is built around
// contexts from the start rather than around harts (CPU_CACHE_SPEC.md 6.4).
// Going to several harts is then only a question of the parameter.
//
// Source 0 does not exist: reading the claim register gives 0 when there is
// nothing to claim, so that number cannot belong to a source.
//
// The gateway of each source is the level triggered one: the line sets the
// pending bit, claiming clears it, and no further request is made until the
// context has written the completion back. A line that is still asserted
// then makes the source pending again.
//
// The port is a plain synchronous slave with a 64 bit data path, like
// CPU_CLINT. Every register is 32 bit and is answered in the half of the
// word its address falls in, so a 32 bit access of software lands on it.
// The claim only happens when the address is exactly that of the claim
// register, so a wider read that happens to cover it does not claim.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_PLIC
    #(
        parameter int SOURCES   = 31,     // 1 .. SOURCES
        parameter int CONTEXTS  = 2,      // one hart : machine, supervisor
        parameter int PRIO_BITS = 3       // priorities 0 .. 2**PRIO_BITS-1
    )
    (
        input  logic                   clk,
        input  logic                   rst_n,

        // register port
        input  logic                   sel,       // an access takes place
        input  logic                   we,
        input  logic [21:0]            addr,      // byte address in the block
        input  logic [63:0]            wdata,
        input  logic [7:0]             wstrb,
        output logic [63:0]            rdata,

        // interrupt lines, source s is bit s; bit 0 is not used
        input  logic [SOURCES:0]       src,

        // one line per context
        output logic [CONTEXTS-1:0]    irq
    );

    localparam int WORDS   = (SOURCES + 32) / 32;    // words of the bit arrays
    localparam int ID_BITS = (SOURCES > 1) ? $clog2(SOURCES + 1) : 1;

    //-----------------------------------------------------------------
    // state
    //-----------------------------------------------------------------
    logic [PRIO_BITS-1:0] prio      [0:SOURCES];
    logic                 pending   [0:SOURCES];
    logic                 gw_ready  [0:SOURCES];     // the gateway may forward
    logic                 enable    [0:CONTEXTS-1][0:SOURCES];
    logic [PRIO_BITS-1:0] threshold [0:CONTEXTS-1];

    //-----------------------------------------------------------------
    // what a context would be given if it claimed now
    //
    //   The highest priority among the sources that are pending, enabled
    //   for it and above its threshold. Equal priorities are settled by the
    //   lowest number, which is why the loop counts down.
    //
    //   Priority zero means the source never interrupts, and it needs no
    //   test of its own: the threshold cannot go below zero, so "greater
    //   than the threshold" already excludes it.
    //-----------------------------------------------------------------
    logic [ID_BITS-1:0]   best_id   [0:CONTEXTS-1];
    logic [PRIO_BITS-1:0] best_prio [0:CONTEXTS-1];

    always @(*) begin
        for (int c = 0; c < CONTEXTS; c++) begin
            best_id[c]   = '0;
            best_prio[c] = '0;
            for (int s = SOURCES; s >= 1; s--) begin
                if (pending[s] && enable[c][s] &&
                    (prio[s] > threshold[c]) && (prio[s] >= best_prio[c])) begin
                    best_id[c]   = ID_BITS'(s);
                    best_prio[c] = prio[s];
                end
            end
        end
    end

    always @(*) begin
        for (int c = 0; c < CONTEXTS; c++)
            irq[c] = (best_id[c] != '0);
    end

    //-----------------------------------------------------------------
    // address decode
    //
    //   `word` is the index into a bit array, `half` says which half of the
    //   64 bit data path the register lives in.
    //-----------------------------------------------------------------
    logic in_prio, in_pending, in_enable, in_context;
    int   prio_idx, bit_word, ctx_en, ctx_ctl;
    logic half;
    logic is_claim, is_threshold;

    assign half         = addr[2];
    assign in_prio      = sel && (addr < 22'h001000);
    assign in_pending   = sel && (addr >= 22'h001000) && (addr < 22'h002000);
    assign in_enable    = sel && (addr >= 22'h002000) && (addr < 22'h200000);
    assign in_context   = sel && (addr >= 22'h200000);

    assign prio_idx     = int'(addr[21:2]);                       // 4 bytes each
    assign bit_word     = in_enable ? (int'(addr[6:2]))           // inside a context
                                    : (int'(addr[11:2]));         // pending array
    assign ctx_en       = (int'(addr) - 32'h00_2000) / 32'h80;
    assign ctx_ctl      = (int'(addr) - 32'h20_0000) / 32'h1000;
    assign is_threshold = in_context && ((int'(addr) % 32'h1000) == 0);
    assign is_claim     = in_context && ((int'(addr) % 32'h1000) == 4);

    // the range checks; an access outside them reads zero and writes nothing
    logic ok_prio, ok_pending, ok_enable, ok_ctx;
    assign ok_prio    = in_prio    && (prio_idx >= 1) && (prio_idx <= SOURCES);
    assign ok_pending = in_pending && (bit_word < WORDS);
    assign ok_enable  = in_enable  && (ctx_en < CONTEXTS) && (bit_word < WORDS);
    assign ok_ctx     = in_context && (ctx_ctl < CONTEXTS);

    //-----------------------------------------------------------------
    // read
    //-----------------------------------------------------------------
    logic [31:0] rd32;

    always @(*) begin
        rd32 = 32'd0;
        if (ok_prio) begin
            rd32[PRIO_BITS-1:0] = prio[prio_idx];
        end else if (ok_pending) begin
            for (int b = 0; b < 32; b++)
                if ((bit_word * 32 + b) <= SOURCES)
                    rd32[b] = pending[bit_word * 32 + b];
        end else if (ok_enable) begin
            for (int b = 0; b < 32; b++)
                if ((bit_word * 32 + b) <= SOURCES)
                    rd32[b] = enable[ctx_en][bit_word * 32 + b];
        end else if (ok_ctx && is_threshold) begin
            rd32[PRIO_BITS-1:0] = threshold[ctx_ctl];
        end else if (ok_ctx && is_claim) begin
            rd32 = {{(32-ID_BITS){1'b0}}, best_id[ctx_ctl]};
        end
        // the register sits in the half of the word its address falls in
        rdata = half ? {rd32, 32'd0} : {32'd0, rd32};
    end

    //-----------------------------------------------------------------
    // write
    //-----------------------------------------------------------------
    logic [31:0] wr32;
    logic        wr_en;
    logic [ID_BITS-1:0] done_id;

    assign wr32    = half ? wdata[63:32] : wdata[31:0];
    assign wr_en   = sel && we && (half ? wstrb[4] : wstrb[0]);
    assign done_id = wr32[ID_BITS-1:0];

    // a read of the claim register takes the source away from the pending set
    logic claim_now;
    assign claim_now = sel && !we && ok_ctx && is_claim && (best_id[ctx_ctl] != '0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s <= SOURCES; s++) begin
                prio[s]     <= '0;
                pending[s]  <= 1'b0;
                gw_ready[s] <= 1'b1;
            end
            for (int c = 0; c < CONTEXTS; c++) begin
                threshold[c] <= '0;
                for (int s = 0; s <= SOURCES; s++) enable[c][s] <= 1'b0;
            end
        end else begin
            //---------------------------------------------------------
            // the gateways
            //---------------------------------------------------------
            for (int s = 1; s <= SOURCES; s++)
                if (src[s] && gw_ready[s]) begin
                    pending[s]  <= 1'b1;
                    gw_ready[s] <= 1'b0;
                end

            //---------------------------------------------------------
            // claim and complete
            //---------------------------------------------------------
            if (claim_now)
                pending[best_id[ctx_ctl]] <= 1'b0;

            if (wr_en && ok_ctx && is_claim) begin
                // a completion of a source this context may not use is
                // ignored, as the specification asks
                if ((done_id != '0) && (int'(done_id) <= SOURCES) &&
                    enable[ctx_ctl][done_id])
                    gw_ready[done_id] <= 1'b1;
            end

            //---------------------------------------------------------
            // the configuration registers
            //---------------------------------------------------------
            if (wr_en) begin
                if (ok_prio)
                    prio[prio_idx] <= wr32[PRIO_BITS-1:0];
                else if (ok_enable) begin
                    for (int b = 0; b < 32; b++)
                        if (((bit_word * 32 + b) <= SOURCES) &&
                            ((bit_word * 32 + b) != 0))
                            enable[ctx_en][bit_word * 32 + b] <= wr32[b];
                end else if (ok_ctx && is_threshold)
                    threshold[ctx_ctl] <= wr32[PRIO_BITS-1:0];
                // the pending array is read only
            end
        end
    end

endmodule : CPU_PLIC
