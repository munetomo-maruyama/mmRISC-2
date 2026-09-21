//---------------------------------------------------------------------------
// CORE_CSR.sv
//
// CSR file, privilege level and trap state (CPU_CORE_SPEC.md 7, 8, 14).
//
//   - the read port is combinational and is used in EX
//   - the write port is a single cycle pulse from the commit point (MA)
//   - a trap, an MRET and an SRET arrive from the same commit point and have
//     priority over the write of the instruction (a trapping instruction
//     writes nothing)
//
//   IALIGN is 16 because the C extension is implemented, so only bit 0 of
//   mepc and sepc is dropped.
//
//   M5 adds supervisor and user mode. The privilege level lives here because
//   everything that changes it (a trap, MRET, SRET) is decided here; the
//   pipeline only reads it.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_CSR
    #(
        parameter logic [63:0] HART_ID   = 64'd0,
        // misa : MXL = 2 (64 bit) and one bit per implemented letter,
        // bit 0 is 'A' ... bit 8 is 'I' ... bit 18 is 'S', bit 20 is 'U'
        parameter logic [63:0] MISA      = (64'd2 << 62) | (64'd1 << 8),
        // number of implemented PMP entries (0, 16 or 64; 0 removes PMP)
        parameter int          PMP_ENTRIES = 16
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // read port (EX)
        input  logic [11:0] rd_addr,
        output logic [63:0] rd_data,
        output logic        rd_exists,     // the CSR is implemented
        output logic        rd_readonly,   // writing it is an illegal instruction
        output logic        rd_denied,     // not allowed at the current level

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
        output logic        trap_to_s,     // the trap is delegated to S mode

        // MRET / SRET (commit, one cycle)
        input  logic        mret_en,
        input  logic        sret_en,
        output logic [63:0] mret_target,
        output logic [63:0] sret_target,

        // interrupt inputs (CLINT, PLIC)
        input  logic        irq_m_soft,
        input  logic        irq_m_timer,
        input  logic        irq_m_ext,
        input  logic        irq_s_ext,     // PLIC, supervisor context
        input  logic [63:0] mtime,         // for the `time` counter

        // to the pipeline
        output logic        irq_req,       // an interrupt can be taken now
        output logic [4:0]  irq_cause,
        output logic        irq_any,       // enabled and pending (WFI wake up)

        // privilege and translation state
        output logic [1:0]  priv,          // current privilege level
        output logic [63:0] satp_out,
        output logic        mstatus_sum_out,
        output logic        mstatus_mxr_out,
        output logic        mstatus_mprv_out,
        output logic [1:0]  mstatus_mpp_out,
        output logic        mstatus_tvm_out,
        output logic        mstatus_tw_out,
        output logic        mstatus_tsr_out,

        // PMP configuration, flattened for the checker
        output logic [8*PMP_ENTRIES-1:0]  pmpcfg_out,
        output logic [64*PMP_ENTRIES-1:0] pmpaddr_out,

        // counters
        input  logic        instret_inc,

        // floating point state
        input  logic        fflags_we,     // accumulate the flags of one op
        input  logic [4:0]  fflags_set,
        input  logic        fs_dirty,      // an FP register or fcsr was written
        output logic [2:0]  frm_out,       // the dynamic rounding mode
        output logic [1:0]  fs_out         // mstatus.FS
    );

    //-----------------------------------------------------------------
    // privilege levels
    //-----------------------------------------------------------------
    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;

    //-----------------------------------------------------------------
    // addresses
    //-----------------------------------------------------------------
    localparam logic [11:0] CSR_FFLAGS    = 12'h001;
    localparam logic [11:0] CSR_FRM       = 12'h002;
    localparam logic [11:0] CSR_FCSR      = 12'h003;
    // supervisor
    localparam logic [11:0] CSR_SSTATUS   = 12'h100;
    localparam logic [11:0] CSR_SIE       = 12'h104;
    localparam logic [11:0] CSR_STVEC     = 12'h105;
    localparam logic [11:0] CSR_SCOUNTEREN= 12'h106;
    localparam logic [11:0] CSR_SSCRATCH  = 12'h140;
    localparam logic [11:0] CSR_SEPC      = 12'h141;
    localparam logic [11:0] CSR_SCAUSE    = 12'h142;
    localparam logic [11:0] CSR_STVAL     = 12'h143;
    localparam logic [11:0] CSR_SIP       = 12'h144;
    localparam logic [11:0] CSR_SATP      = 12'h180;
    // machine
    localparam logic [11:0] CSR_MSTATUS   = 12'h300;
    localparam logic [11:0] CSR_MISA      = 12'h301;
    localparam logic [11:0] CSR_MEDELEG   = 12'h302;
    localparam logic [11:0] CSR_MIDELEG   = 12'h303;
    localparam logic [11:0] CSR_MIE       = 12'h304;
    localparam logic [11:0] CSR_MTVEC     = 12'h305;
    localparam logic [11:0] CSR_MCOUNTEREN= 12'h306;
    localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
    localparam logic [11:0] CSR_MEPC      = 12'h341;
    localparam logic [11:0] CSR_MCAUSE    = 12'h342;
    localparam logic [11:0] CSR_MTVAL     = 12'h343;
    localparam logic [11:0] CSR_MIP       = 12'h344;
    localparam logic [11:0] CSR_PMPCFG0   = 12'h3A0;
    localparam logic [11:0] CSR_PMPADDR0  = 12'h3B0;
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
    localparam int IRQ_S_SOFT  = 1;
    localparam int IRQ_M_SOFT  = 3;
    localparam int IRQ_S_TIMER = 5;
    localparam int IRQ_M_TIMER = 7;
    localparam int IRQ_S_EXT   = 9;
    localparam int IRQ_M_EXT   = 11;

    // delegation masks. Exception 11 (ECALL from M) can never be delegated,
    // 10 and 14 are reserved; only the three supervisor interrupts can.
    localparam logic [63:0] MEDELEG_MASK = 64'h0000_0000_0000_B3FF;
    localparam logic [63:0] MIDELEG_MASK = 64'h0000_0000_0000_0222;

    //-----------------------------------------------------------------
    // state
    //-----------------------------------------------------------------
    logic [1:0]  priv_r;
    logic        mstatus_mie, mstatus_mpie, mstatus_sie, mstatus_spie;
    logic [1:0]  mstatus_mpp;
    logic        mstatus_spp;
    logic        mstatus_mprv, mstatus_sum, mstatus_mxr;
    logic        mstatus_tvm, mstatus_tw, mstatus_tsr;
    logic [1:0]  mstatus_fs;
    logic [63:0] mtvec, mscratch, mepc, mtval;
    logic [63:0] stvec, sscratch, sepc, stval;
    logic        mcause_int, scause_int;
    logic [4:0]  mcause_code, scause_code;
    logic        mie_msie, mie_mtie, mie_meie;
    logic        mie_ssie, mie_stie, mie_seie;
    logic        mip_ssip, mip_stip, mip_seip;   // software written bits
    logic [63:0] medeleg, mideleg;
    logic [63:0] satp;
    logic [31:0] mcounteren, scounteren;
    logic [63:0] mcycle, minstret;
    logic [4:0]  fflags;
    logic [2:0]  frm;

    assign frm_out = frm;
    assign fs_out  = mstatus_fs;
    assign priv    = priv_r;
    assign satp_out = satp;
    assign mstatus_sum_out  = mstatus_sum;
    assign mstatus_mxr_out  = mstatus_mxr;
    assign mstatus_mprv_out = mstatus_mprv;
    assign mstatus_mpp_out  = mstatus_mpp;
    assign mstatus_tvm_out  = mstatus_tvm;
    assign mstatus_tw_out   = mstatus_tw;
    assign mstatus_tsr_out  = mstatus_tsr;

    //-----------------------------------------------------------------
    // PMP registers
    //
    //   pmpcfg is addressed in groups of eight bytes (only the even numbered
    //   CSRs exist on RV64), pmpaddr one entry at a time.
    //-----------------------------------------------------------------
    logic [7:0]  pmpcfg  [0:(PMP_ENTRIES > 0 ? PMP_ENTRIES-1 : 0)];
    logic [53:0] pmpaddr [0:(PMP_ENTRIES > 0 ? PMP_ENTRIES-1 : 0)];

    // a locked entry cannot be written any more until the hart is reset
    function automatic logic pmp_locked(input int i);
        pmp_locked = (PMP_ENTRIES > 0) && pmpcfg[i][7];
    endfunction

    always @(*) begin
        pmpcfg_out  = '0;
        pmpaddr_out = '0;
        for (int i = 0; i < PMP_ENTRIES; i++) begin
            pmpcfg_out [8*i  +: 8 ] = pmpcfg[i];
            pmpaddr_out[64*i +: 64] = {10'd0, pmpaddr[i]};
        end
    end

    //-----------------------------------------------------------------
    // composed values
    //-----------------------------------------------------------------
    logic [63:0] mstatus_val, sstatus_val, mie_val, mip_val;
    logic [63:0] mcause_val, scause_val, sie_val, sip_val;
    logic        sd_bit;

    assign sd_bit = (mstatus_fs == 2'b11);

    always @(*) begin
        mstatus_val        = 64'd0;
        mstatus_val[1]     = mstatus_sie;
        mstatus_val[3]     = mstatus_mie;
        mstatus_val[5]     = mstatus_spie;
        mstatus_val[7]     = mstatus_mpie;
        mstatus_val[8]     = mstatus_spp;
        mstatus_val[12:11] = mstatus_mpp;
        mstatus_val[14:13] = mstatus_fs;
        mstatus_val[17]    = mstatus_mprv;
        mstatus_val[18]    = mstatus_sum;
        mstatus_val[19]    = mstatus_mxr;
        mstatus_val[20]    = mstatus_tvm;
        mstatus_val[21]    = mstatus_tw;
        mstatus_val[22]    = mstatus_tsr;
        mstatus_val[33:32] = 2'b10;          // UXL : 64 bit
        mstatus_val[35:34] = 2'b10;          // SXL : 64 bit
        mstatus_val[63]    = sd_bit;

        // sstatus is the same register seen through a mask
        sstatus_val        = 64'd0;
        sstatus_val[1]     = mstatus_sie;
        sstatus_val[5]     = mstatus_spie;
        sstatus_val[8]     = mstatus_spp;
        sstatus_val[14:13] = mstatus_fs;
        sstatus_val[18]    = mstatus_sum;
        sstatus_val[19]    = mstatus_mxr;
        sstatus_val[33:32] = 2'b10;          // UXL
        sstatus_val[63]    = sd_bit;
    end

    always @(*) begin
        mie_val               = 64'd0;
        mie_val[IRQ_S_SOFT]   = mie_ssie;
        mie_val[IRQ_M_SOFT]   = mie_msie;
        mie_val[IRQ_S_TIMER]  = mie_stie;
        mie_val[IRQ_M_TIMER]  = mie_mtie;
        mie_val[IRQ_S_EXT]    = mie_seie;
        mie_val[IRQ_M_EXT]    = mie_meie;

        // the machine pending bits are driven by the CLINT and the PLIC and
        // are read only; the supervisor ones are written by software (this is
        // how M mode delivers a timer or a software interrupt to S mode) and
        // the external one is also raised by the PLIC
        mip_val               = 64'd0;
        mip_val[IRQ_S_SOFT]   = mip_ssip;
        mip_val[IRQ_M_SOFT]   = irq_m_soft;
        mip_val[IRQ_S_TIMER]  = mip_stip;
        mip_val[IRQ_M_TIMER]  = irq_m_timer;
        mip_val[IRQ_S_EXT]    = mip_seip | irq_s_ext;
        mip_val[IRQ_M_EXT]    = irq_m_ext;
    end

    assign sie_val    = mie_val & mideleg;
    assign sip_val    = mip_val & mideleg;
    assign mcause_val = {mcause_int, 58'd0, mcause_code};
    assign scause_val = {scause_int, 58'd0, scause_code};

    //-----------------------------------------------------------------
    // read
    //
    //   `rd_exists` says the address is implemented, `rd_denied` that the
    //   current level may not touch it. Both end up as an illegal
    //   instruction; they are separate only to keep the reasons readable.
    //-----------------------------------------------------------------
    logic        ctr_denied;
    logic [4:0]  ctr_bit;
    logic        pmp_hit;
    logic [63:0] pmp_rdata;

    // pmpcfg0 / pmpcfg2 / ... : even numbered only on RV64, eight entries each
    // pmpaddr0 ... pmpaddr(N-1)
    //   pmpcfg0 .. pmpcfg14 : eight entries each, only the even numbered
    //   ones exist on RV64.  pmpaddr0 .. pmpaddr63 : one entry each.
    int rd_cfg_sel, rd_cfg_base, rd_addr_idx;

    always @(*) begin
        pmp_hit     = 1'b0;
        pmp_rdata   = 64'd0;
        rd_cfg_sel  = int'(rd_addr) - int'(CSR_PMPCFG0);
        rd_cfg_base = (rd_cfg_sel / 2) * 8;
        rd_addr_idx = int'(rd_addr) - int'(CSR_PMPADDR0);
        if (PMP_ENTRIES > 0) begin
            if ((rd_cfg_sel >= 0) && (rd_cfg_sel < 16) && (rd_cfg_sel % 2 == 0) &&
                (rd_cfg_base < PMP_ENTRIES)) begin
                pmp_hit = 1'b1;
                for (int i = 0; i < 8; i++)
                    pmp_rdata[8*i +: 8] = pmpcfg[rd_cfg_base + i];
            end else if ((rd_addr_idx >= 0) && (rd_addr_idx < PMP_ENTRIES)) begin
                pmp_hit   = 1'b1;
                pmp_rdata = {10'd0, pmpaddr[rd_addr_idx]};
            end
        end
    end

    // cycle / time / instret are readable below M only when the level above
    // says so in its counteren
    assign ctr_bit    = rd_addr[4:0];
    always @(*) begin
        ctr_denied = 1'b0;
        if (priv_r != PRIV_M) begin
            if (!mcounteren[ctr_bit]) ctr_denied = 1'b1;
            else if ((priv_r == PRIV_U) && !scounteren[ctr_bit]) ctr_denied = 1'b1;
        end
    end

    always @(*) begin
        rd_data   = 64'd0;
        rd_exists = 1'b1;
        rd_denied = 1'b0;
        case (rd_addr)
            CSR_FFLAGS    : rd_data = {59'd0, fflags};
            CSR_FRM       : rd_data = {61'd0, frm};
            CSR_FCSR      : rd_data = {56'd0, frm, fflags};
            CSR_SSTATUS   : rd_data = sstatus_val;
            CSR_SIE       : rd_data = sie_val;
            CSR_STVEC     : rd_data = stvec;
            CSR_SCOUNTEREN: rd_data = {32'd0, scounteren};
            CSR_SSCRATCH  : rd_data = sscratch;
            CSR_SEPC      : rd_data = sepc;
            CSR_SCAUSE    : rd_data = scause_val;
            CSR_STVAL     : rd_data = stval;
            CSR_SIP       : rd_data = sip_val;
            CSR_SATP      : begin
                rd_data   = satp;
                // TVM traps the supervisor reading or writing satp
                rd_denied = (priv_r == PRIV_S) & mstatus_tvm;
            end
            CSR_MSTATUS   : rd_data = mstatus_val;
            CSR_MISA      : rd_data = MISA;
            CSR_MEDELEG   : rd_data = medeleg;
            CSR_MIDELEG   : rd_data = mideleg;
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
            CSR_CYCLE     : begin rd_data = mcycle;   rd_denied = ctr_denied; end
            CSR_TIME      : begin rd_data = mtime;    rd_denied = ctr_denied; end
            CSR_INSTRET   : begin rd_data = minstret; rd_denied = ctr_denied; end
            CSR_MVENDORID : rd_data = 64'd0;
            CSR_MARCHID   : rd_data = 64'd0;
            CSR_MIMPID    : rd_data = 64'd0;
            CSR_MHARTID   : rd_data = HART_ID;
            default       : begin
                rd_data   = pmp_rdata;
                rd_exists = pmp_hit;
            end
        endcase

        // bits 9:8 of the address are the lowest level that may use it
        if (rd_addr[9:8] > priv_r) rd_denied = 1'b1;
    end

    // the two top bits of the address say whether the CSR can be written
    assign rd_readonly = (rd_addr[11:10] == 2'b11);

    //-----------------------------------------------------------------
    // interrupts
    //
    //   An interrupt is taken when it is pending and enabled and the level it
    //   belongs to is not below the current one; at its own level the global
    //   enable of that level decides. Delegated interrupts belong to S.
    //-----------------------------------------------------------------
    logic [63:0] irq_pending, irq_deliver;
    logic        m_enabled, s_enabled;

    assign irq_pending = mip_val & mie_val;
    assign m_enabled   = (priv_r != PRIV_M) | mstatus_mie;
    assign s_enabled   = (priv_r == PRIV_U) | ((priv_r == PRIV_S) & mstatus_sie);

    always @(*) begin
        for (int i = 0; i < 64; i++)
            irq_deliver[i] = irq_pending[i] & (mideleg[i] ? s_enabled : m_enabled);
    end

    assign irq_any = |irq_pending;
    assign irq_req = |irq_deliver;

    // the priority of the privileged specification: machine before
    // supervisor, and external before software before timer
    always @(*) begin
        if      (irq_deliver[IRQ_M_EXT])   irq_cause = 5'(IRQ_M_EXT);
        else if (irq_deliver[IRQ_M_SOFT])  irq_cause = 5'(IRQ_M_SOFT);
        else if (irq_deliver[IRQ_M_TIMER]) irq_cause = 5'(IRQ_M_TIMER);
        else if (irq_deliver[IRQ_S_EXT])   irq_cause = 5'(IRQ_S_EXT);
        else if (irq_deliver[IRQ_S_SOFT])  irq_cause = 5'(IRQ_S_SOFT);
        else                               irq_cause = 5'(IRQ_S_TIMER);
    end

    //-----------------------------------------------------------------
    // delegation, trap vector, return targets
    //-----------------------------------------------------------------
    logic deleg;

    assign deleg     = trap_int ? mideleg[{1'b0, trap_cause}]
                                : medeleg[{1'b0, trap_cause}];
    // a trap is never delegated to a level above the one it came from
    assign trap_to_s = deleg & (priv_r != PRIV_M);

    // mode 1 (vectored) sends interrupts to base + 4 * cause
    logic [63:0] tvec_sel;
    assign tvec_sel    = trap_to_s ? stvec : mtvec;
    assign trap_vector = (tvec_sel[1:0] == 2'b01) && trap_int
                       ? {tvec_sel[63:2], 2'b00} + {57'd0, trap_cause, 2'b00}
                       : {tvec_sel[63:2], 2'b00};
    assign mret_target = mepc;
    assign sret_target = sepc;

    //-----------------------------------------------------------------
    // write, trap, counters
    //-----------------------------------------------------------------
    int wr_cfg_sel, wr_cfg_base, wr_addr_idx;
    assign wr_cfg_sel  = int'(wr_addr) - int'(CSR_PMPCFG0);
    assign wr_cfg_base = (wr_cfg_sel / 2) * 8;
    assign wr_addr_idx = int'(wr_addr) - int'(CSR_PMPADDR0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            priv_r       <= PRIV_M;
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mstatus_sie  <= 1'b0;
            mstatus_spie <= 1'b0;
            mstatus_mpp  <= PRIV_U;
            mstatus_spp  <= 1'b0;
            mstatus_mprv <= 1'b0;
            mstatus_sum  <= 1'b0;
            mstatus_mxr  <= 1'b0;
            mstatus_tvm  <= 1'b0;
            mstatus_tw   <= 1'b0;
            mstatus_tsr  <= 1'b0;
            mstatus_fs   <= 2'b00;
            mtvec        <= 64'd0;
            mscratch     <= 64'd0;
            mepc         <= 64'd0;
            mtval        <= 64'd0;
            mcause_int   <= 1'b0;
            mcause_code  <= 5'd0;
            stvec        <= 64'd0;
            sscratch     <= 64'd0;
            sepc         <= 64'd0;
            stval        <= 64'd0;
            scause_int   <= 1'b0;
            scause_code  <= 5'd0;
            mie_msie     <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mie_ssie     <= 1'b0;
            mie_stie     <= 1'b0;
            mie_seie     <= 1'b0;
            mip_ssip     <= 1'b0;
            mip_stip     <= 1'b0;
            mip_seip     <= 1'b0;
            medeleg      <= 64'd0;
            mideleg      <= 64'd0;
            satp         <= 64'd0;
            mcounteren   <= 32'd0;
            scounteren   <= 32'd0;
            mcycle       <= 64'd0;
            minstret     <= 64'd0;
            fflags       <= 5'd0;
            frm          <= 3'd0;
            for (int i = 0; i < PMP_ENTRIES; i++) begin
                pmpcfg[i]  <= 8'd0;
                pmpaddr[i] <= 54'd0;
            end
        end else begin
            mcycle <= mcycle + 64'd1;
            if (instret_inc) minstret <= minstret + 64'd1;

            // the flags of the operations pile up; a write of the CSR below
            // takes precedence over the accumulation of the same cycle
            if (fflags_we) fflags <= fflags | fflags_set;
            if (fs_dirty)  mstatus_fs <= 2'b11;

            if (trap_en) begin
                if (trap_to_s) begin
                    sepc         <= {trap_epc[63:1], 1'b0};
                    scause_int   <= trap_int;
                    scause_code  <= trap_cause;
                    stval        <= trap_tval;
                    mstatus_spie <= mstatus_sie;
                    mstatus_sie  <= 1'b0;
                    mstatus_spp  <= (priv_r == PRIV_S);
                    priv_r       <= PRIV_S;
                end else begin
                    mepc         <= {trap_epc[63:1], 1'b0};
                    mcause_int   <= trap_int;
                    mcause_code  <= trap_cause;
                    mtval        <= trap_tval;
                    mstatus_mpie <= mstatus_mie;
                    mstatus_mie  <= 1'b0;
                    mstatus_mpp  <= priv_r;
                    priv_r       <= PRIV_M;
                end
            end else if (mret_en) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
                mstatus_mpp  <= PRIV_U;
                priv_r       <= mstatus_mpp;
                // returning to anything below M clears MPRV, so a handler
                // cannot leave the data side translating as another level
                if (mstatus_mpp != PRIV_M) mstatus_mprv <= 1'b0;
            end else if (sret_en) begin
                mstatus_sie  <= mstatus_spie;
                mstatus_spie <= 1'b1;
                mstatus_spp  <= 1'b0;
                priv_r       <= {1'b0, mstatus_spp};
                mstatus_mprv <= 1'b0;        // SPP is never M
            end else if (wr_en) begin
                if ((PMP_ENTRIES > 0) &&
                    (wr_cfg_sel >= 0) && (wr_cfg_sel < 16) &&
                    (wr_cfg_sel % 2 == 0) && (wr_cfg_base < PMP_ENTRIES)) begin
                    for (int i = 0; i < 8; i++) begin
                        if (!pmp_locked(wr_cfg_base + i)) begin
                            // bit 5 and 6 are reserved and read as zero, and
                            // W without R is a reserved encoding
                            pmpcfg[wr_cfg_base + i] <=
                                {wr_data[8*i+7], 2'b00, wr_data[8*i+4 -: 2],
                                 (wr_data[8*i+1] & ~wr_data[8*i]) ? 3'b000
                                                                 : wr_data[8*i +: 3]};
                        end
                    end
                end else if ((PMP_ENTRIES > 0) &&
                             (wr_addr_idx >= 0) && (wr_addr_idx < PMP_ENTRIES)) begin
                    // an entry is also frozen when the next one is locked and
                    // is in TOR mode, because that one uses this address
                    if (!pmp_locked(wr_addr_idx) &&
                        !((wr_addr_idx < PMP_ENTRIES-1) &&
                          pmp_locked(wr_addr_idx + 1) &&
                          (pmpcfg[wr_addr_idx + 1][4:3] == 2'b01)))
                        pmpaddr[wr_addr_idx] <= wr_data[53:0];
                end else begin
                case (wr_addr)
                    CSR_FFLAGS: begin
                        fflags     <= wr_data[4:0];
                        mstatus_fs <= 2'b11;
                    end
                    CSR_FRM: begin
                        frm        <= wr_data[2:0];
                        mstatus_fs <= 2'b11;
                    end
                    CSR_FCSR: begin
                        fflags     <= wr_data[4:0];
                        frm        <= wr_data[7:5];
                        mstatus_fs <= 2'b11;
                    end
                    CSR_MSTATUS: begin
                        mstatus_sie  <= wr_data[1];
                        mstatus_mie  <= wr_data[3];
                        mstatus_spie <= wr_data[5];
                        mstatus_mpie <= wr_data[7];
                        mstatus_spp  <= wr_data[8];
                        // MPP is WARL; there is no reserved level 2
                        mstatus_mpp  <= (wr_data[12:11] == 2'b10) ? PRIV_U
                                                                  : wr_data[12:11];
                        mstatus_fs   <= wr_data[14:13];
                        mstatus_mprv <= wr_data[17];
                        mstatus_sum  <= wr_data[18];
                        mstatus_mxr  <= wr_data[19];
                        mstatus_tvm  <= wr_data[20];
                        mstatus_tw   <= wr_data[21];
                        mstatus_tsr  <= wr_data[22];
                    end
                    CSR_SSTATUS: begin
                        mstatus_sie  <= wr_data[1];
                        mstatus_spie <= wr_data[5];
                        mstatus_spp  <= wr_data[8];
                        mstatus_fs   <= wr_data[14:13];
                        mstatus_sum  <= wr_data[18];
                        mstatus_mxr  <= wr_data[19];
                    end
                    CSR_MEDELEG: medeleg <= wr_data & MEDELEG_MASK;
                    CSR_MIDELEG: mideleg <= wr_data & MIDELEG_MASK;
                    CSR_MIE: begin
                        mie_ssie <= wr_data[IRQ_S_SOFT];
                        mie_msie <= wr_data[IRQ_M_SOFT];
                        mie_stie <= wr_data[IRQ_S_TIMER];
                        mie_mtie <= wr_data[IRQ_M_TIMER];
                        mie_seie <= wr_data[IRQ_S_EXT];
                        mie_meie <= wr_data[IRQ_M_EXT];
                    end
                    CSR_SIE: begin
                        // only the delegated bits are visible through sie
                        if (mideleg[IRQ_S_SOFT])  mie_ssie <= wr_data[IRQ_S_SOFT];
                        if (mideleg[IRQ_S_TIMER]) mie_stie <= wr_data[IRQ_S_TIMER];
                        if (mideleg[IRQ_S_EXT])   mie_seie <= wr_data[IRQ_S_EXT];
                    end
                    CSR_MIP: begin
                        mip_ssip <= wr_data[IRQ_S_SOFT];
                        mip_stip <= wr_data[IRQ_S_TIMER];
                        mip_seip <= wr_data[IRQ_S_EXT];
                    end
                    CSR_SIP: begin
                        // the supervisor may only clear its own software
                        // interrupt; the timer and external ones belong to M
                        if (mideleg[IRQ_S_SOFT]) mip_ssip <= wr_data[IRQ_S_SOFT];
                    end
                    // the two low bits are the mode: 0 direct, 1 vectored,
                    // everything else is reserved and is not taken over
                    CSR_MTVEC     : mtvec      <= (wr_data[1:0] < 2'd2)
                                                ? wr_data : {wr_data[63:2], 2'b00};
                    CSR_STVEC     : stvec      <= (wr_data[1:0] < 2'd2)
                                                ? wr_data : {wr_data[63:2], 2'b00};
                    CSR_MCOUNTEREN: mcounteren <= wr_data[31:0];
                    CSR_SCOUNTEREN: scounteren <= wr_data[31:0];
                    CSR_MSCRATCH  : mscratch   <= wr_data;
                    CSR_SSCRATCH  : sscratch   <= wr_data;
                    CSR_MEPC      : mepc       <= {wr_data[63:1], 1'b0};
                    CSR_SEPC      : sepc       <= {wr_data[63:1], 1'b0};
                    CSR_MCAUSE    : begin
                        mcause_int  <= wr_data[63];
                        mcause_code <= wr_data[4:0];
                    end
                    CSR_SCAUSE    : begin
                        scause_int  <= wr_data[63];
                        scause_code <= wr_data[4:0];
                    end
                    CSR_MTVAL     : mtval      <= wr_data;
                    CSR_STVAL     : stval      <= wr_data;
                    // MODE is WARL: only bare (0) and Sv39 (8) exist here, so
                    // anything else leaves satp alone
                    CSR_SATP      : if ((wr_data[63:60] == 4'd0) ||
                                        (wr_data[63:60] == 4'd8))
                                        satp <= {wr_data[63:60], wr_data[59:44],
                                                 wr_data[43:0]};
                    CSR_MCYCLE    : mcycle     <= wr_data;
                    CSR_MINSTRET  : minstret   <= wr_data;
                    default       : ;            // misa and the read only ones
                endcase
                end
            end
        end
    end

endmodule : CORE_CSR
