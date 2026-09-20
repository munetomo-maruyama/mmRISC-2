//---------------------------------------------------------------------------
// CPU_CLINT.sv
//
// Core local interruptor : the software interrupt and the timer of one hart
// (CPU_CORE_SPEC.md 8). The register map is the usual one of the SiFive CLINT,
// relative to the base address of the block:
//
//   0x0000  msip      32 bit, bit 0 is the software interrupt
//   0x4000  mtimecmp  64 bit
//   0xBFF8  mtime     64 bit
//
// The port is a plain synchronous slave (one access per cycle, the read
// answer is combinational) so that it can be put behind whatever bus the
// system uses; CPU_TOP puts it on the peripheral bus.
//
// mtime counts one step every TICK_DIV cycles of clk. A real system divides
// the core clock down to a fixed frequency (the timebase of the software);
// the simulation uses 1.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_CLINT
    #(
        parameter int TICK_DIV = 1        // clk cycles per step of mtime
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // register port
        input  logic        sel,          // an access takes place this cycle
        input  logic        we,
        input  logic [15:0] addr,         // byte address inside the block
        input  logic [63:0] wdata,
        input  logic [7:0]  wstrb,
        output logic [63:0] rdata,

        // to the core
        output logic        irq_m_soft,
        output logic        irq_m_timer,
        output logic [63:0] mtime
    );

    localparam logic [15:0] ADDR_MSIP     = 16'h0000;
    localparam logic [15:0] ADDR_MTIMECMP = 16'h4000;
    localparam logic [15:0] ADDR_MTIME    = 16'hBFF8;

    logic        msip;
    logic [63:0] mtimecmp;
    logic [31:0] tick;

    // the 64 bit registers answer a word access as well, so the address is
    // compared without its low three bits
    logic hit_msip, hit_mtimecmp, hit_mtime;
    assign hit_msip     = (addr[15:3] == ADDR_MSIP[15:3]);
    assign hit_mtimecmp = (addr[15:3] == ADDR_MTIMECMP[15:3]);
    assign hit_mtime    = (addr[15:3] == ADDR_MTIME[15:3]);

    always @(*) begin
        if      (hit_msip)     rdata = {63'd0, msip};
        else if (hit_mtimecmp) rdata = mtimecmp;
        else if (hit_mtime)    rdata = mtime;
        else                   rdata = 64'd0;
    end

    // byte enables of a write
    function automatic logic [63:0] merge(input logic [63:0] old,
                                          input logic [63:0] nw,
                                          input logic [7:0]  strb);
        logic [63:0] r;
        r = old;
        for (int b = 0; b < 8; b++)
            if (strb[b]) r[8*b +: 8] = nw[8*b +: 8];
        return r;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msip     <= 1'b0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
            mtime    <= 64'd0;
            tick     <= 32'd0;
        end else begin
            if (TICK_DIV <= 1) begin
                mtime <= mtime + 64'd1;
            end else if (tick == 32'(TICK_DIV - 1)) begin
                tick  <= 32'd0;
                mtime <= mtime + 64'd1;
            end else begin
                tick  <= tick + 32'd1;
            end

            if (sel && we) begin
                if (hit_msip && wstrb[0])
                    msip <= wdata[0];
                else if (hit_mtimecmp)
                    mtimecmp <= merge(mtimecmp, wdata, wstrb);
                else if (hit_mtime)
                    mtime <= merge(mtime, wdata, wstrb);
            end
        end
    end

    assign irq_m_soft  = msip;
    assign irq_m_timer = (mtime >= mtimecmp);

endmodule : CPU_CLINT
