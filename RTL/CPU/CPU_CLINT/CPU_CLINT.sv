//---------------------------------------------------------------------------
// CPU_CLINT.sv
//
// Core local interruptor : the software interrupt and the timer of the harts
// (CPU_CORE_SPEC.md 8, CPU_CACHE_SPEC.md 6.4.8). The register map is the
// usual one of the SiFive CLINT, relative to the base address of the block:
//
//   0x0000 + 4 * hart   msip      32 bit, bit 0 is the software interrupt
//   0x4000 + 8 * hart   mtimecmp  64 bit, one per hart
//   0xBFF8              mtime     64 bit, shared by all harts
//
// The port is a plain synchronous slave (one access per cycle, the read
// answer is combinational) so that it can be put behind whatever bus the
// system uses; CPU_TOP puts it on the peripheral bus.
//
// mtime counts one step every TICK_DIV cycles of clk. A real system divides
// the core clock down to a fixed frequency (the timebase of the software);
// the simulation uses 1.
//
// NUM_HARTS is the one place that has to change to go from one hart to
// several: the map above is defined by the hart index, so software and the
// device tree see the layout they expect without any further change.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_CLINT
    #(
        parameter int NUM_HARTS = 1,
        parameter int TICK_DIV  = 1       // clk cycles per step of mtime
    )
    (
        input  logic                   clk,
        input  logic                   rst_n,

        // register port
        input  logic                   sel,       // an access takes place
        input  logic                   we,
        input  logic [15:0]            addr,      // byte address in the block
        input  logic [63:0]            wdata,
        input  logic [7:0]             wstrb,
        output logic [63:0]            rdata,

        // to the cores, one bit per hart
        output logic [NUM_HARTS-1:0]   irq_m_soft,
        output logic [NUM_HARTS-1:0]   irq_m_timer,
        output logic [63:0]            mtime
    );

    localparam logic [15:0] ADDR_MTIMECMP = 16'h4000;
    localparam logic [15:0] ADDR_MTIME    = 16'hBFF8;

    logic [NUM_HARTS-1:0] msip;
    logic [63:0]          mtimecmp [0:NUM_HARTS-1];
    logic [31:0]          tick;

    //-----------------------------------------------------------------
    // which register does the access refer to
    //-----------------------------------------------------------------
    logic in_msip, in_mtimecmp, hit_mtime;

    assign hit_mtime   = (addr[15:3] == ADDR_MTIME[15:3]);
    assign in_msip     = (addr < ADDR_MTIMECMP);
    assign in_mtimecmp = (addr >= ADDR_MTIMECMP) && (addr < ADDR_MTIME);

    // msip is 32 bit wide, so one 64 bit word holds the bits of two harts
    int msip_lo, msip_hi, cmp_idx;
    assign msip_lo = int'(addr[15:3]) * 2;
    assign msip_hi = msip_lo + 1;
    assign cmp_idx = (int'(addr) - int'(ADDR_MTIMECMP)) / 8;

    // an index that is always inside the array; whether it is the one that
    // was asked for is decided separately
    int cmp_safe;
    logic cmp_ok, msip_lo_ok, msip_hi_ok;
    assign cmp_ok     = in_mtimecmp && (cmp_idx >= 0) && (cmp_idx < NUM_HARTS);
    assign cmp_safe   = cmp_ok ? cmp_idx : 0;
    assign msip_lo_ok = in_msip && (msip_lo < NUM_HARTS);
    assign msip_hi_ok = in_msip && (msip_hi < NUM_HARTS);

    //-----------------------------------------------------------------
    // read
    //-----------------------------------------------------------------
    always @(*) begin
        rdata = 64'd0;
        if      (hit_mtime) rdata = mtime;
        else if (cmp_ok)    rdata = mtimecmp[cmp_safe];
        else begin
            if (msip_lo_ok) rdata[0]  = msip[msip_lo];
            if (msip_hi_ok) rdata[32] = msip[msip_hi];
        end
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

    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msip  <= '0;
            mtime <= 64'd0;
            tick  <= 32'd0;
            for (int h = 0; h < NUM_HARTS; h++)
                mtimecmp[h] <= 64'hFFFF_FFFF_FFFF_FFFF;
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
                if (hit_mtime)
                    mtime <= merge(mtime, wdata, wstrb);
                else if (cmp_ok)
                    mtimecmp[cmp_safe] <= merge(mtimecmp[cmp_safe], wdata, wstrb);
                else begin
                    if (msip_lo_ok && wstrb[0]) msip[msip_lo] <= wdata[0];
                    if (msip_hi_ok && wstrb[4]) msip[msip_hi] <= wdata[32];
                end
            end
        end
    end

    //-----------------------------------------------------------------
    assign irq_m_soft = msip;

    always @(*)
        for (int h = 0; h < NUM_HARTS; h++)
            irq_m_timer[h] = (mtime >= mtimecmp[h]);

endmodule : CPU_CLINT
