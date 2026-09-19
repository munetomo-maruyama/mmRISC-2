//---------------------------------------------------------------------------
// DBG_HART_STUB.sv
//
// Pseudo hart for the provisional debug logic (removed when the CPU core is
// implemented). It only models the run control state machine and holds the
// register values accessed through the Access Register abstract command, so
// that a debugger sees an RV64GC hart.
//
// Run control
//   reset    : hart_rst=1 (synchronous). On release: halted with cause 5 if
//              resethaltreq=1, otherwise running.
//   running  : haltreq=1 -> halted, cause 3 (haltreq)
//   halted   : resumereq pulse -> running (resumed pulse). If dcsr.step=1 the
//              hart halts again on the next cycle with cause 4 (step) and
//              dpc += 4 (cause 3 if haltreq is also set).
//
// Register access (reg_req pulse -> reg_ack pulse on the next cycle)
//   All registers are handled as 64 bit. A 32-bit write (size64=0) updates
//   the low 32 bits only. reg_err=1 when the register does not exist or is
//   read-only on a write (DM reports cmderr=3).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module DBG_HART_STUB
    #(
        parameter logic [63:0] MISA         = 64'h8000_0000_0014_112d,
        parameter logic [31:0] MVENDORID    = 32'h0000_0000,
        parameter logic [63:0] MARCHID      = 64'h0000_0000_6d6d_3032,
        parameter logic [63:0] MIMPL        = 64'h0000_0000_0000_0001,
        parameter logic [63:0] MHARTID      = 64'h0,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000
    )
    (
        input  logic        clk,
        input  logic        hart_rst,      // synchronous, active high

        // run control
        input  logic        haltreq,
        input  logic        resumereq,     // pulse
        input  logic        resethaltreq,
        output logic        halted,
        output logic        running,
        output logic        resumed,       // pulse

        // register access
        input  logic        reg_req,       // pulse
        input  logic        reg_wr,
        input  logic [15:0] reg_regno,
        input  logic        reg_size64,
        input  logic [63:0] reg_wdata,
        output logic        reg_ack,       // pulse
        output logic [63:0] reg_rdata,
        output logic        reg_err
    );

    //-----------------------------------------------------------------
    // Register numbers
    //-----------------------------------------------------------------
    localparam logic [15:0] R_FFLAGS     = 16'h0001;
    localparam logic [15:0] R_FRM        = 16'h0002;
    localparam logic [15:0] R_FCSR       = 16'h0003;
    localparam logic [15:0] R_SSTATUS    = 16'h0100;
    localparam logic [15:0] R_STVEC      = 16'h0105;
    localparam logic [15:0] R_SSCRATCH   = 16'h0140;
    localparam logic [15:0] R_SEPC       = 16'h0141;
    localparam logic [15:0] R_SCAUSE     = 16'h0142;
    localparam logic [15:0] R_STVAL      = 16'h0143;
    localparam logic [15:0] R_SATP       = 16'h0180;
    localparam logic [15:0] R_MSTATUS    = 16'h0300;
    localparam logic [15:0] R_MISA       = 16'h0301;
    localparam logic [15:0] R_MEDELEG    = 16'h0302;
    localparam logic [15:0] R_MIDELEG    = 16'h0303;
    localparam logic [15:0] R_MIE        = 16'h0304;
    localparam logic [15:0] R_MTVEC      = 16'h0305;
    localparam logic [15:0] R_MCOUNTEREN = 16'h0306;
    localparam logic [15:0] R_MSCRATCH   = 16'h0340;
    localparam logic [15:0] R_MEPC       = 16'h0341;
    localparam logic [15:0] R_MCAUSE     = 16'h0342;
    localparam logic [15:0] R_MTVAL      = 16'h0343;
    localparam logic [15:0] R_MIP        = 16'h0344;
    localparam logic [15:0] R_DCSR       = 16'h07B0;
    localparam logic [15:0] R_DPC        = 16'h07B1;
    localparam logic [15:0] R_DSCRATCH0  = 16'h07B2;
    localparam logic [15:0] R_DSCRATCH1  = 16'h07B3;
    localparam logic [15:0] R_MVENDORID  = 16'h0F11;
    localparam logic [15:0] R_MARCHID    = 16'h0F12;
    localparam logic [15:0] R_MIMPL      = 16'h0F13;
    localparam logic [15:0] R_MHARTID    = 16'h0F14;
    localparam logic [15:0] R_MCONFIGPTR = 16'h0F15;

    // WARL masks
    localparam logic [63:0] MSTATUS_WMASK = 64'h0000_0000_007E_79AA; // SIE MIE SPIE MPIE SPP MPP FS MPRV SUM MXR TVM TW TSR
    localparam logic [63:0] MSTATUS_FIXED = 64'h0000_000A_0000_0000; // UXL=SXL=2
    localparam logic [63:0] SSTATUS_WMASK = 64'h0000_0000_000C_6122; // SIE SPIE SPP FS SUM MXR
    localparam logic [63:0] SSTATUS_RMASK = 64'h8000_0003_000D_E122; // + UXL XS SD
    localparam logic [63:0] MIP_WMASK     = 64'h0000_0000_0000_0222; // SSIP STIP SEIP
    localparam logic [63:0] MIE_WMASK     = 64'h0000_0000_0000_0AAA;
    localparam logic [63:0] MEDELEG_WMASK = 64'h0000_0000_0000_B3FF;
    localparam logic [63:0] MIDELEG_WMASK = 64'h0000_0000_0000_0222;
    localparam logic [31:0] DCSR_WMASK    = 32'h0000_BE17;           // ebreakm ebreaks ebreaku stepie stopcount stoptime mprven step prv

    //-----------------------------------------------------------------
    // Run control
    //-----------------------------------------------------------------
    typedef enum logic [1:0] {H_RESET, H_RUN, H_HALT, H_STEP} h_state_t;
    h_state_t h_state;

    assign halted  = (h_state == H_HALT);
    assign running = (h_state == H_RUN) | (h_state == H_STEP);

    //-----------------------------------------------------------------
    // Register storage
    //-----------------------------------------------------------------
    // GPR x0-x31 at index 0-31, FPR f0-f31 at index 32-63 (distributed RAM)
    logic [63:0] xf [0:63];
    initial for (int i = 0; i < 64; i++) xf[i] = 64'd0;

    logic [4:0]  fflags;
    logic [2:0]  frm;
    logic [63:0] mstatus;
    logic [63:0] medeleg, mideleg, mie, mip, mtvec;
    logic [31:0] mcounteren;
    logic [63:0] mscratch, mepc, mcause, mtval;
    logic [63:0] stvec, sscratch, sepc, scause, stval, satp;
    logic [31:0] dcsr;
    logic [63:0] dpc, dscratch0, dscratch1;

    logic [63:0] mstatus_rd;
    assign mstatus_rd = (mstatus & MSTATUS_WMASK) | MSTATUS_FIXED
                      | {(mstatus[14:13] == 2'b11), 63'd0};

    //-----------------------------------------------------------------
    // Register read decode
    //-----------------------------------------------------------------
    logic        rd_exist;
    logic        rd_only;
    logic [63:0] rd_val;

    always_comb begin
        rd_exist = 1'b1;
        rd_only  = 1'b0;
        rd_val   = 64'd0;
        if (reg_regno >= 16'h1000 && reg_regno <= 16'h103f) begin
            rd_val = (reg_regno == 16'h1000) ? 64'd0 : xf[reg_regno[5:0]];
        end else begin
            case (reg_regno)
                R_FFLAGS:     rd_val = {59'd0, fflags};
                R_FRM:        rd_val = {61'd0, frm};
                R_FCSR:       rd_val = {56'd0, frm, fflags};
                R_SSTATUS:    rd_val = mstatus_rd & SSTATUS_RMASK;
                R_STVEC:      rd_val = stvec;
                R_SSCRATCH:   rd_val = sscratch;
                R_SEPC:       rd_val = sepc;
                R_SCAUSE:     rd_val = scause;
                R_STVAL:      rd_val = stval;
                R_SATP:       rd_val = satp;
                R_MSTATUS:    rd_val = mstatus_rd;
                R_MISA:       rd_val = MISA;
                R_MEDELEG:    rd_val = medeleg;
                R_MIDELEG:    rd_val = mideleg;
                R_MIE:        rd_val = mie;
                R_MTVEC:      rd_val = mtvec;
                R_MCOUNTEREN: rd_val = {32'd0, mcounteren};
                R_MSCRATCH:   rd_val = mscratch;
                R_MEPC:       rd_val = mepc;
                R_MCAUSE:     rd_val = mcause;
                R_MTVAL:      rd_val = mtval;
                R_MIP:        rd_val = mip;
                R_DCSR:       rd_val = {32'd0, dcsr};
                R_DPC:        rd_val = dpc;
                R_DSCRATCH0:  rd_val = dscratch0;
                R_DSCRATCH1:  rd_val = dscratch1;
                R_MVENDORID:  begin rd_val = {32'd0, MVENDORID}; rd_only = 1'b1; end
                R_MARCHID:    begin rd_val = MARCHID;            rd_only = 1'b1; end
                R_MIMPL:      begin rd_val = MIMPL;              rd_only = 1'b1; end
                R_MHARTID:    begin rd_val = MHARTID;            rd_only = 1'b1; end
                R_MCONFIGPTR: begin rd_val = 64'd0;              rd_only = 1'b1; end
                default:      rd_exist = 1'b0;
            endcase
        end
    end

    // value to be written (32-bit writes keep the upper half)
    logic [63:0] wv;
    assign wv = reg_size64 ? reg_wdata : {rd_val[63:32], reg_wdata[31:0]};

    logic do_wr;
    assign do_wr = reg_req & reg_wr & rd_exist & ~rd_only;

    //-----------------------------------------------------------------
    // GPR/FPR write (no reset: distributed RAM)
    //-----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (do_wr && reg_regno >= 16'h1001 && reg_regno <= 16'h103f)
            xf[reg_regno[5:0]] <= wv;
    end

    //-----------------------------------------------------------------
    // Run control and CSRs
    //-----------------------------------------------------------------
    always_ff @(posedge clk) begin
        reg_ack   <= 1'b0;
        resumed   <= 1'b0;
        if (hart_rst) begin
            h_state   <= H_RESET;
            reg_rdata <= 64'd0;
            reg_err   <= 1'b0;
            fflags    <= 5'd0;
            frm       <= 3'd0;
            mstatus   <= 64'd0;
            medeleg   <= 64'd0;
            mideleg   <= 64'd0;
            mie       <= 64'd0;
            mip       <= 64'd0;
            mtvec     <= 64'd0;
            mcounteren<= 32'd0;
            mscratch  <= 64'd0;
            mepc      <= 64'd0;
            mcause    <= 64'd0;
            mtval     <= 64'd0;
            stvec     <= 64'd0;
            sscratch  <= 64'd0;
            sepc      <= 64'd0;
            scause    <= 64'd0;
            stval     <= 64'd0;
            satp      <= 64'd0;
            dcsr      <= {4'd4, 28'd3};          // debugver=4, prv=M
            dpc       <= RESET_VECTOR;
            dscratch0 <= 64'd0;
            dscratch1 <= 64'd0;
        end else begin
            //---------------------------------------------------------
            // run control
            //---------------------------------------------------------
            case (h_state)
                H_RESET: begin
                    if (resethaltreq) begin
                        h_state    <= H_HALT;
                        dcsr[8:6]  <= 3'd5;
                    end else begin
                        h_state    <= H_RUN;
                    end
                end
                H_RUN: begin
                    if (haltreq) begin
                        h_state    <= H_HALT;
                        dcsr[8:6]  <= 3'd3;
                    end
                end
                H_HALT: begin
                    if (resumereq) begin
                        resumed <= 1'b1;
                        h_state <= dcsr[2] ? H_STEP : H_RUN;
                    end
                end
                H_STEP: begin
                    h_state    <= H_HALT;
                    dcsr[8:6]  <= haltreq ? 3'd3 : 3'd4;
                    dpc        <= dpc + 64'd4;
                end
                default: h_state <= H_RESET;
            endcase

            //---------------------------------------------------------
            // register access
            //---------------------------------------------------------
            if (reg_req) begin
                reg_ack   <= 1'b1;
                reg_err   <= ~rd_exist | (reg_wr & rd_only);
                reg_rdata <= rd_val;
            end

            if (do_wr) begin
                case (reg_regno)
                    R_FFLAGS:     fflags     <= wv[4:0];
                    R_FRM:        frm        <= wv[2:0];
                    R_FCSR:       begin fflags <= wv[4:0]; frm <= wv[7:5]; end
                    R_SSTATUS:    mstatus    <= (mstatus & ~SSTATUS_WMASK) | (wv & SSTATUS_WMASK);
                    R_STVEC:      stvec      <= {wv[63:2], 1'b0, wv[0]};
                    R_SSCRATCH:   sscratch   <= wv;
                    R_SEPC:       sepc       <= {wv[63:1], 1'b0};
                    R_SCAUSE:     scause     <= wv;
                    R_STVAL:      stval      <= wv;
                    R_SATP:       if (wv[63:60] == 4'd0 || wv[63:60] == 4'd8)
                                      satp   <= {wv[63:60], 16'd0, wv[43:0]};
                    R_MSTATUS:    begin
                                      mstatus[63:0] <= (wv & MSTATUS_WMASK)
                                                     | (mstatus & ~MSTATUS_WMASK);
                                      if (wv[12:11] == 2'b10)          // MPP WARL
                                          mstatus[12:11] <= mstatus[12:11];
                                  end
                    R_MISA:       ;                                    // WARL: ignored
                    R_MEDELEG:    medeleg    <= wv & MEDELEG_WMASK;
                    R_MIDELEG:    mideleg    <= wv & MIDELEG_WMASK;
                    R_MIE:        mie        <= wv & MIE_WMASK;
                    R_MTVEC:      mtvec      <= {wv[63:2], 1'b0, wv[0]};
                    R_MCOUNTEREN: mcounteren <= wv[31:0];
                    R_MSCRATCH:   mscratch   <= wv;
                    R_MEPC:       mepc       <= {wv[63:1], 1'b0};
                    R_MCAUSE:     mcause     <= wv;
                    R_MTVAL:      mtval      <= wv;
                    R_MIP:        mip        <= wv & MIP_WMASK;
                    R_DCSR:       begin
                                      dcsr <= (dcsr & ~DCSR_WMASK) | (wv[31:0] & DCSR_WMASK);
                                      if (wv[1:0] == 2'b10)            // prv WARL
                                          dcsr[1:0] <= dcsr[1:0];
                                  end
                    R_DPC:        dpc        <= {wv[63:1], 1'b0};
                    R_DSCRATCH0:  dscratch0  <= wv;
                    R_DSCRATCH1:  dscratch1  <= wv;
                    default: ;
                endcase
            end
        end
    end

endmodule : DBG_HART_STUB
