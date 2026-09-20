//---------------------------------------------------------------------------
// CORE_CSR.sv
//
// CSR file and trap state of the machine mode (CPU_CORE_SPEC.md 7, 8).
//
//   - the read port is combinational and is used in EX
//   - the write port is a single cycle pulse from the commit point (MA)
//   - a trap or an MRET arrives from the same commit point and has priority
//     over the write of the instruction (a trapping instruction writes nothing)
//
//   IALIGN is 16 because the C extension is implemented, so only bit 0 of
//   mepc is dropped.
//
//   M2 implements machine mode only. `mstatus.MPP` is therefore WARL with the
//   single legal value 3, and there is no delegation, no `satp` and no PMP:
//   those addresses do not exist and are answered with an illegal instruction
//   exception, which is what the riscv-tests environment expects.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_CSR
    #(
        parameter logic [63:0] HART_ID   = 64'd0,
        // misa : MXL = 2 (64 bit) and one bit per implemented letter,
        // bit 0 is 'A' ... bit 8 is 'I'. M2 implements I only.
        parameter logic [63:0] MISA      = (64'd2 << 62) | (64'd1 << 8)
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // read port (EX)
        input  logic [11:0] rd_addr,
        output logic [63:0] rd_data,
        output logic        rd_exists,     // the CSR is implemented
        output logic        rd_readonly,   // writing it is an illegal instruction

        // write port (commit, one cycle)
        input  logic        wr_en,
        input  logic [11:0] wr_addr,
        input  logic [63:0] wr_data,

        // trap entry (commit, one cycle, has priority over wr_en)
        input  logic        trap_en,
        input  logic        trap_int,      // interrupt, not exception
        input  logic [4:0]  trap_cause,
        input  logic [63:0] trap_epc,
        input  logic [63:0] trap_tval,
        output logic [63:0] trap_vector,   // where the trap handler starts

        // MRET (commit, one cycle)
        input  logic        mret_en,
        output logic [63:0] mret_target,

        // interrupt inputs (CLINT, PLIC)
        input  logic        irq_m_soft,
        input  logic        irq_m_timer,
        input  logic        irq_m_ext,
        input  logic [63:0] mtime,         // for the `time` counter

        // to the pipeline
        output logic        irq_req,       // an enabled interrupt is pending and mstatus.MIE
        output logic [4:0]  irq_cause,
        output logic        irq_any,       // enabled and pending, whatever mstatus.MIE says (WFI)

        // counters
        input  logic        instret_inc
    );

    //-----------------------------------------------------------------
    // addresses
    //-----------------------------------------------------------------
    localparam logic [11:0] CSR_MSTATUS   = 12'h300;
    localparam logic [11:0] CSR_MISA      = 12'h301;
    localparam logic [11:0] CSR_MIE       = 12'h304;
    localparam logic [11:0] CSR_MTVEC     = 12'h305;
    localparam logic [11:0] CSR_MCOUNTEREN= 12'h306;
    localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
    localparam logic [11:0] CSR_MEPC      = 12'h341;
    localparam logic [11:0] CSR_MCAUSE    = 12'h342;
    localparam logic [11:0] CSR_MTVAL     = 12'h343;
    localparam logic [11:0] CSR_MIP       = 12'h344;
    localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
    localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
    localparam logic [11:0] CSR_CYCLE     = 12'hC00;
    localparam logic [11:0] CSR_TIME      = 12'hC01;
    localparam logic [11:0] CSR_INSTRET   = 12'hC02;
    localparam logic [11:0] CSR_MVENDORID = 12'hF11;
    localparam logic [11:0] CSR_MARCHID   = 12'hF12;
    localparam logic [11:0] CSR_MIMPID    = 12'hF13;
    localparam logic [11:0] CSR_MHARTID   = 12'hF14;

    // interrupt numbers
    localparam int IRQ_M_SOFT  = 3;
    localparam int IRQ_M_TIMER = 7;
    localparam int IRQ_M_EXT   = 11;

    //-----------------------------------------------------------------
    // state
    //-----------------------------------------------------------------
    logic        mstatus_mie, mstatus_mpie;
    logic [63:0] mtvec, mscratch, mepc, mtval;
    logic        mcause_int;
    logic [4:0]  mcause_code;
    logic        mie_msie, mie_mtie, mie_meie;
    logic [31:0] mcounteren;
    logic [63:0] mcycle, minstret;

    //-----------------------------------------------------------------
    // composed values
    //-----------------------------------------------------------------
    logic [63:0] mstatus_val, mie_val, mip_val, mcause_val;

    // MPP is WARL and machine mode is the only legal value
    always @(*) begin
        mstatus_val        = 64'd0;
        mstatus_val[3]     = mstatus_mie;     // MIE
        mstatus_val[7]     = mstatus_mpie;    // MPIE
        mstatus_val[12:11] = 2'b11;           // MPP
    end

    always @(*) begin
        mie_val               = 64'd0;
        mie_val[IRQ_M_SOFT]   = mie_msie;
        mie_val[IRQ_M_TIMER]  = mie_mtie;
        mie_val[IRQ_M_EXT]    = mie_meie;

        // the pending bits of machine mode are driven by the CLINT and the
        // PLIC, so they are read only here
        mip_val               = 64'd0;
        mip_val[IRQ_M_SOFT]   = irq_m_soft;
        mip_val[IRQ_M_TIMER]  = irq_m_timer;
        mip_val[IRQ_M_EXT]    = irq_m_ext;
    end

    assign mcause_val = {mcause_int, 58'd0, mcause_code};

    //-----------------------------------------------------------------
    // read
    //-----------------------------------------------------------------
    always @(*) begin
        rd_data   = 64'd0;
        rd_exists = 1'b1;
        case (rd_addr)
            CSR_MSTATUS   : rd_data = mstatus_val;
            CSR_MISA      : rd_data = MISA;
            CSR_MIE       : rd_data = mie_val;
            CSR_MTVEC     : rd_data = mtvec;
            CSR_MCOUNTEREN: rd_data = {32'd0, mcounteren};
            CSR_MSCRATCH  : rd_data = mscratch;
            CSR_MEPC      : rd_data = mepc;
            CSR_MCAUSE    : rd_data = mcause_val;
            CSR_MTVAL     : rd_data = mtval;
            CSR_MIP       : rd_data = mip_val;
            CSR_MCYCLE    : rd_data = mcycle;
            CSR_MINSTRET  : rd_data = minstret;
            CSR_CYCLE     : rd_data = mcycle;
            CSR_TIME      : rd_data = mtime;
            CSR_INSTRET   : rd_data = minstret;
            CSR_MVENDORID : rd_data = 64'd0;
            CSR_MARCHID   : rd_data = 64'd0;
            CSR_MIMPID    : rd_data = 64'd0;
            CSR_MHARTID   : rd_data = HART_ID;
            default       : rd_exists = 1'b0;
        endcase
    end

    // the two top bits of the address say whether the CSR can be written
    assign rd_readonly = (rd_addr[11:10] == 2'b11);

    //-----------------------------------------------------------------
    // interrupts
    //-----------------------------------------------------------------
    logic [63:0] irq_active;
    assign irq_active = mip_val & mie_val;
    assign irq_any    = |irq_active;
    assign irq_req    = irq_any & mstatus_mie;

    // the priority of the privileged specification: external, software, timer
    always @(*) begin
        if      (irq_active[IRQ_M_EXT])   irq_cause = 5'(IRQ_M_EXT);
        else if (irq_active[IRQ_M_SOFT])  irq_cause = 5'(IRQ_M_SOFT);
        else                              irq_cause = 5'(IRQ_M_TIMER);
    end

    //-----------------------------------------------------------------
    // trap vector and MRET target
    //-----------------------------------------------------------------
    // mtvec mode 1 sends interrupts to base + 4 * cause
    assign trap_vector = (mtvec[1:0] == 2'b01) && trap_int
                       ? {mtvec[63:2], 2'b00} + {57'd0, trap_cause, 2'b00}
                       : {mtvec[63:2], 2'b00};
    assign mret_target = mepc;

    //-----------------------------------------------------------------
    // write, trap, counters
    //-----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mtvec        <= 64'd0;
            mscratch     <= 64'd0;
            mepc         <= 64'd0;
            mtval        <= 64'd0;
            mcause_int   <= 1'b0;
            mcause_code  <= 5'd0;
            mie_msie     <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mcounteren   <= 32'd0;
            mcycle       <= 64'd0;
            minstret     <= 64'd0;
        end else begin
            mcycle <= mcycle + 64'd1;
            if (instret_inc) minstret <= minstret + 64'd1;

            if (trap_en) begin
                mepc         <= {trap_epc[63:1], 1'b0};
                mcause_int   <= trap_int;
                mcause_code  <= trap_cause;
                mtval        <= trap_tval;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (mret_en) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (wr_en) begin
                case (wr_addr)
                    CSR_MSTATUS: begin
                        mstatus_mie  <= wr_data[3];
                        mstatus_mpie <= wr_data[7];
                    end
                    CSR_MIE: begin
                        mie_msie <= wr_data[IRQ_M_SOFT];
                        mie_mtie <= wr_data[IRQ_M_TIMER];
                        mie_meie <= wr_data[IRQ_M_EXT];
                    end
                    // the two low bits are the mode: 0 direct, 1 vectored,
                    // everything else is reserved and is not taken over
                    CSR_MTVEC     : mtvec      <= (wr_data[1:0] < 2'd2)
                                                ? wr_data : {wr_data[63:2], 2'b00};
                    CSR_MCOUNTEREN: mcounteren <= wr_data[31:0];
                    CSR_MSCRATCH  : mscratch   <= wr_data;
                    CSR_MEPC      : mepc       <= {wr_data[63:1], 1'b0};
                    CSR_MCAUSE    : begin
                        mcause_int  <= wr_data[63];
                        mcause_code <= wr_data[4:0];
                    end
                    CSR_MTVAL     : mtval      <= wr_data;
                    CSR_MCYCLE    : mcycle     <= wr_data;
                    CSR_MINSTRET  : minstret   <= wr_data;
                    default       : ;            // misa, mip and the read only ones
                endcase
            end
        end
    end

endmodule : CORE_CSR
