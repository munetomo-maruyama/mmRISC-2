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
//
//   Sstc (2026-10, CPU_CORE_SPEC.md decision 66): stimecmp, and with
//   menvcfg.STCE set the supervisor timer interrupt (mip.STIP) is
//   time >= stimecmp instead of a bit M mode writes. menvcfg, senvcfg and
//   mcountinhibit came with it: they make the hart one of version 1.12 of
//   the privileged specification, which is when OpenSBI looks for Sstc.
//
//   Sdtrig (2026-10, CPU_CORE_SPEC.md decision 67): TRIGGERS triggers of
//   type 2 (mcontrol) behind tselect / tdata1 / tdata2, and tcontrol. Each
//   matches the address of an instruction (execute) or of a load or store
//   exactly, in the levels its m / s / u bits name, and raises a breakpoint
//   exception (action 0) or enters debug mode (action 1, only for a trigger
//   that belongs to the debugger, dmode). The core does the matching
//   (trig_* below); this keeps the registers and sets hit when a trigger
//   really fired.
//
//   PMU (2026-10, CPU_CORE_SPEC.md decision 69): HPM_COUNTERS counters from
//   mhpmcounter3 on, each with its mhpmevent (an event number below
//   HPM_EVENTS, and the Sscofpmf bits OF / MINH / SINH / UINH), and their
//   bits in mcountinhibit, mcounteren and scounteren. The core says which
//   events happened in a cycle (hpm_ev); they are counted one cycle later.
//   A counter that wraps sets its OF, and OF going from 0 to 1 raises the
//   local counter overflow interrupt (LCOFI, 13), which can be delegated.
//   The counters above the implemented ones read 0 and ignore writes.
//   Smcntrpmf gives mcycle and minstret the same MINH / SINH / UINH, in
//   mcyclecfg and minstretcfg: without it OpenSBI does not let Linux use
//   them once Sscofpmf is there (they could not leave a level out).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CORE_CSR
    #(
        parameter logic [63:0] HART_ID   = 64'd0,
        // misa : MXL = 2 (64 bit) and one bit per implemented letter,
        // bit 0 is 'A' ... bit 8 is 'I' ... bit 18 is 'S', bit 20 is 'U'
        parameter logic [63:0] MISA      = (64'd2 << 62) | (64'd1 << 8),
        // number of implemented PMP entries (0, 16 or 64; 0 removes PMP)
        parameter int          PMP_ENTRIES = 8,
        // The privileged specification lets an implementation provide zero,
        // sixteen or sixty four PMP entries, and the CSRs of the entries it
        // does not provide still have to read as zero rather than raise an
        // illegal instruction. PMP_ENTRIES is how many actually check an
        // address; this is how many the software can see.
        parameter int          PMP_CSRS    = 16,
        // Sdtrig: number of triggers (type 2, mcontrol)
        parameter int          TRIGGERS    = 4,
        // PMU: counters mhpmcounter3 .. mhpmcounter(3+HPM_COUNTERS-1), and
        // the number of event inputs (event 0 is "nothing")
        parameter int          HPM_COUNTERS = 4,
        parameter int          HPM_EVENTS   = 20
    )
    (
        input  logic        clk,
        input  logic        rst_n,

        // read port (EX, or the debugger while the hart is halted)
        input  logic [11:0] rd_addr,
        output logic [63:0] rd_data,
        output logic [63:0] rmw_data,      // what csrrs / csrrc start from
        output logic        rd_exists,     // the CSR is implemented (for dbg_access)
        output logic        rd_readonly,   // writing it is an error

        // the checks of the CSR instruction in EX. They look at its own
        // address, not at rd_addr, so that the debugger's register number
        // (rd_addr while halted) is not on the path to the exception.
        input  logic [11:0] ex_addr,
        output logic        ex_exists,     // the CSR is implemented
        output logic        ex_readonly,   // writing it is an illegal instruction
        output logic        ex_denied,     // not allowed at the current level

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
        input  logic [HPM_EVENTS-1:0] hpm_ev,   // the events of this cycle

        // floating point state
        input  logic        fflags_we,     // accumulate the flags of one op
        input  logic [4:0]  fflags_set,
        input  logic        fs_dirty,      // an FP register or fcsr was written
        output logic [2:0]  frm_out,       // the dynamic rounding mode
        output logic [1:0]  fs_out,        // mstatus.FS

        // debug (RISC-V Debug Spec 1.0, 4.9). dcsr, dpc and dscratch0/1
        // exist only for accesses of the debugger (dbg_access), which the
        // core makes while the hart is halted; an instruction sees them as
        // not implemented.
        input  logic        dbg_access,    // rd / wr come from the debugger
        input  logic        dbg_enter,     // the hart enters debug mode
        input  logic [2:0]  dbg_cause,     //   why (dcsr.cause)
        input  logic [63:0] dbg_pc,        //   the instruction not executed
        input  logic        dbg_resume,    // it leaves debug mode
        output logic        dcsr_step,
        output logic        dcsr_ebreakm,
        output logic        dcsr_ebreaks,
        output logic        dcsr_ebreaku,
        output logic [63:0] dpc_out,

        // Sdtrig: what each trigger matches, for the core
        //   trig_cfg[8i +: 8] = {dmode, action, m, s, u, execute, store, load}
        output logic [8*TRIGGERS-1:0]  trig_cfg,
        output logic [64*TRIGGERS-1:0] trig_addr,  // tdata2
        output logic        tcontrol_mte,          // M mode triggers of action 0 on
        input  logic [TRIGGERS-1:0]    trig_fired  // set hit (with the trap / halt)
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
    localparam logic [11:0] CSR_SENVCFG   = 12'h10A;
    localparam logic [11:0] CSR_STIMECMP  = 12'h14D;
    localparam logic [11:0] CSR_MENVCFG   = 12'h30A;
    localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
    localparam logic [11:0] CSR_SCOUNTOVF = 12'hDA0;
    localparam logic [11:0] CSR_MCYCLECFG   = 12'h321;
    localparam logic [11:0] CSR_MINSTRETCFG = 12'h322;
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
    // debug mode only
    localparam logic [11:0] CSR_TSELECT   = 12'h7A0;
    localparam logic [11:0] CSR_TDATA1    = 12'h7A1;
    localparam logic [11:0] CSR_TDATA2    = 12'h7A2;
    localparam logic [11:0] CSR_TDATA3    = 12'h7A3;
    localparam logic [11:0] CSR_TINFO     = 12'h7A4;
    localparam logic [11:0] CSR_TCONTROL  = 12'h7A5;
    localparam logic [11:0] CSR_DCSR      = 12'h7B0;
    localparam logic [11:0] CSR_DPC       = 12'h7B1;
    localparam logic [11:0] CSR_DSCRATCH0 = 12'h7B2;
    localparam logic [11:0] CSR_DSCRATCH1 = 12'h7B3;

    // interrupt numbers
    localparam int IRQ_S_SOFT  = 1;
    localparam int IRQ_M_SOFT  = 3;
    localparam int IRQ_S_TIMER = 5;
    localparam int IRQ_M_TIMER = 7;
    localparam int IRQ_S_EXT   = 9;
    localparam int IRQ_M_EXT   = 11;
    localparam int IRQ_LCOF    = 13;     // Sscofpmf: a counter overflowed

    // delegation masks. Exception 11 (ECALL from M) can never be delegated,
    // 10 and 14 are reserved; only the three supervisor interrupts and the
    // counter overflow can.
    localparam logic [63:0] MEDELEG_MASK = 64'h0000_0000_0000_B3FF;
    localparam logic [63:0] MIDELEG_MASK = 64'h0000_0000_0000_2222;

    //-----------------------------------------------------------------
    // state
    //-----------------------------------------------------------------
    logic [1:0]  priv_r;
    // dcsr : ebreakm/s/u, step, prv and cause are kept; stepie, stopcount
    // and stoptime are 0 (interrupts are off while stepping, the counters
    // and mtime run on in debug mode), xdebugver is 4
    logic        dcsr_ebreakm_r, dcsr_ebreaks_r, dcsr_ebreaku_r, dcsr_step_r;
    logic [1:0]  dcsr_prv;
    logic [2:0]  dcsr_cause;
    logic [63:0] dpc, dscratch0, dscratch1;
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
    // Sstc and its company: menvcfg is STCE alone (every other field belongs
    // to an extension this core does not have and reads 0), senvcfg is all
    // read only 0, mcountinhibit has CY and IR (no hpmcounters)
    logic        menvcfg_stce;
    logic        inhibit_cy, inhibit_ir;
    logic [63:0] stimecmp;
    logic        stip_cmp;       // time >= stimecmp, one cycle late

    // PMU. Counter i is mhpmcounter(3+i).
    localparam int HPM_N = (HPM_COUNTERS > 0) ? HPM_COUNTERS : 1;
    logic [63:0] hpm_cnt   [0:HPM_N-1];
    logic [4:0]  hpm_sel   [0:HPM_N-1];   // the event
    logic [HPM_N-1:0] hpm_of, hpm_minh, hpm_sinh, hpm_uinh;
    logic [HPM_N-1:0] inhibit_hpm;
    logic        mip_lcofip, mie_lcofie;
    logic [HPM_EVENTS-1:0] hpm_ev_q;      // the events of the last cycle
    logic [1:0]  hpm_priv_q;              //   and the level they happened at
    logic [31:0] hpm_ovf;                 // OF of each counter, at its number
    logic [31:3] hpm_inh;                 // mcountinhibit of the counters
    // Smcntrpmf: the levels mcycle and minstret do not count at
    logic        cy_minh, cy_sinh, cy_uinh, ir_minh, ir_sinh, ir_uinh;
    logic        cy_filt, ir_filt;

    // Sdtrig. A trigger has the fields of mcontrol that are not hard wired
    // here: match is always 0 (equal; maskmax 0, no NAPOT), select / timing
    // / size / chain are 0 (the address, before the access, any size, not
    // chained), action is 0 or 1.
    localparam int TSEL_BITS = (TRIGGERS > 1) ? $clog2(TRIGGERS) : 1;
    logic [TSEL_BITS-1:0] tselect;
    logic [TRIGGERS-1:0]  t_dmode, t_action, t_hit;
    logic [TRIGGERS-1:0]  t_m, t_s, t_u, t_exec, t_store, t_load;
    logic [63:0]          t_data2 [0:TRIGGERS-1];
    logic                 tc_mte, tc_mpte;
    logic [63:0]          tdata1_val;
    logic                 t_writable;    // the selected trigger may be written
    logic [4:0]  fflags;
    logic [2:0]  frm;

    assign frm_out = frm;
    assign fs_out  = mstatus_fs;
    assign priv    = priv_r;
    assign dcsr_step    = dcsr_step_r;
    assign dcsr_ebreakm = dcsr_ebreakm_r;
    assign dcsr_ebreaks = dcsr_ebreaks_r;
    assign dcsr_ebreaku = dcsr_ebreaku_r;
    assign dpc_out      = dpc;
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
        mie_val[IRQ_LCOF]     = mie_lcofie;

        // the machine pending bits are driven by the CLINT and the PLIC and
        // are read only; the supervisor ones are written by software (this is
        // how M mode delivers a timer or a software interrupt to S mode) and
        // the external one is also raised by the PLIC
        mip_val               = 64'd0;
        mip_val[IRQ_S_SOFT]   = mip_ssip;
        mip_val[IRQ_M_SOFT]   = irq_m_soft;
        mip_val[IRQ_S_TIMER]  = menvcfg_stce ? stip_cmp : mip_stip;
        mip_val[IRQ_M_TIMER]  = irq_m_timer;
        mip_val[IRQ_S_EXT]    = mip_seip | irq_s_ext;
        mip_val[IRQ_M_EXT]    = irq_m_ext;
        mip_val[IRQ_LCOF]     = mip_lcofip;
    end

    // Smcntrpmf: mcycle and minstret leave the current level out
    assign cy_filt = (priv_r == PRIV_M) ? cy_minh : (priv_r == PRIV_S) ? cy_sinh : cy_uinh;
    assign ir_filt = (priv_r == PRIV_M) ? ir_minh : (priv_r == PRIV_S) ? ir_sinh : ir_uinh;

    // the counters' bits of scountovf and mcountinhibit
    always @(*) begin
        hpm_ovf = 32'd0;
        hpm_inh = '0;
        for (int i = 0; i < HPM_COUNTERS; i++) begin
            hpm_ovf[3+i] = hpm_of[i];
            hpm_inh[3+i] = inhibit_hpm[i];
        end
    end

    assign sie_val    = mie_val & mideleg;
    assign sip_val    = mip_val & mideleg;

    // A csrrs / csrrc of mip modifies the bits software can write, and for
    // SEIP that is the software bit alone, not its OR with the PLIC line
    // that a read returns (privileged spec, mip). Taking the read value
    // copied a pending supervisor interrupt of the PLIC into the software
    // bit, which then held SEIP up for good: OpenSBI clears STIP with csrc
    // on every machine timer interrupt, and Linux on the Arty ended in an
    // endless supervisor external interrupt with nothing to claim.
    always @(*) begin
        rmw_data = rd_data;
        if (rd_addr == CSR_MIP) rmw_data[IRQ_S_EXT] = mip_seip;
    end
    assign mcause_val = {mcause_int, 58'd0, mcause_code};
    assign scause_val = {scause_int, 58'd0, scause_code};

    //-----------------------------------------------------------------
    // Sdtrig: tdata1 of the selected trigger (mcontrol, RV64)
    //   63:60 type = 2   59 dmode   58:53 maskmax = 0   20 hit
    //   15:12 action     6 m   4 s   3 u   2 execute   1 store   0 load
    //-----------------------------------------------------------------
    assign tdata1_val = {4'd2, t_dmode[tselect], 6'd0, 30'd0, 2'd0, t_hit[tselect],
                         1'b0, 1'b0, 2'd0, {3'd0, t_action[tselect]}, 1'b0, 4'd0,
                         t_m[tselect], 1'b0, t_s[tselect], t_u[tselect],
                         t_exec[tselect], t_store[tselect], t_load[tselect]};
    // a trigger of the debugger is written by the debugger alone
    assign t_writable = ~t_dmode[tselect] | dbg_access;
    assign tcontrol_mte = tc_mte;
    always @(*) begin
        for (int i = 0; i < TRIGGERS; i++) begin
            trig_cfg[8*i +: 8]   = {t_dmode[i], t_action[i], t_m[i], t_s[i], t_u[i],
                                    t_exec[i], t_store[i], t_load[i]};
            trig_addr[64*i +: 64] = t_data2[i];
        end
    end

    //-----------------------------------------------------------------
    // read
    //
    //   `csr_check` says whether an address is implemented and whether the
    //   current level may touch it (both end up as an illegal instruction;
    //   they are separate only to keep the reasons readable). It is used
    //   twice: on the address of the instruction in EX, and on rd_addr for
    //   the debugger. rd_data itself does not need to know either.
    //-----------------------------------------------------------------
    function automatic logic [1:0] csr_check     // {exists, denied}
        (
            input logic [11:0] a,
            input logic        dbg,              // the debugger asks
            input logic [1:0]  lvl,              // the current level
            input logic [31:0] mcen,             // mcounteren
            input logic [31:0] scen,             // scounteren
            input logic        stce,             // menvcfg.STCE
            input logic        tvm               // mstatus.TVM
        );
        logic ex, dn, ctr_dn;
        int   cs, ai;
        // cycle / time / instret / hpmcounterN are readable below M only
        // when the level above says so in its counteren
        ctr_dn = (lvl != PRIV_M) &
                 (~mcen[a[4:0]] | ((lvl == PRIV_U) & ~scen[a[4:0]]));
        ex = 1'b1;
        dn = 1'b0;
        case (a)
            CSR_FFLAGS, CSR_FRM, CSR_FCSR,
            CSR_SSTATUS, CSR_SIE, CSR_STVEC, CSR_SCOUNTEREN, CSR_SSCRATCH,
            CSR_SEPC, CSR_SCAUSE, CSR_STVAL, CSR_SIP, CSR_SENVCFG,
            CSR_MENVCFG, CSR_MCOUNTINHIBIT, CSR_MCYCLECFG, CSR_MINSTRETCFG,
            CSR_SCOUNTOVF,
            CSR_MSTATUS, CSR_MISA, CSR_MEDELEG, CSR_MIDELEG, CSR_MIE,
            CSR_MTVEC, CSR_MCOUNTEREN, CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE,
            CSR_MTVAL, CSR_MIP, CSR_MCYCLE, CSR_MINSTRET,
            CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID,
            CSR_TSELECT, CSR_TDATA1, CSR_TDATA2, CSR_TDATA3, CSR_TINFO,
            CSR_TCONTROL  : ;
            // below M only with STCE and with the time counter allowed
            CSR_STIMECMP  : dn = (lvl != PRIV_M) & (~stce | ~mcen[1]);
            // TVM traps the supervisor reading or writing satp
            CSR_SATP      : dn = (lvl == PRIV_S) & tvm;
            CSR_CYCLE, CSR_TIME, CSR_INSTRET : dn = ctr_dn;
            CSR_DCSR, CSR_DPC, CSR_DSCRATCH0, CSR_DSCRATCH1 : ex = dbg;
            default       : begin
                // mhpmcounter3-31 (0xB03-), hpmcounter3-31 (0xC03-),
                // mhpmevent3-31 (0x323-), and the PMP registers
                cs = int'(a) - int'(CSR_PMPCFG0);
                ai = int'(a) - int'(CSR_PMPADDR0);
                ex = ((a[4:0] >= 5'd3) &&
                      ((a[11:5] == 7'h58) || (a[11:5] == 7'h60) || (a[11:5] == 7'h19))) ||
                     ((PMP_CSRS > 0) && (cs >= 0) && (cs < 16) && (cs % 2 == 0) &&
                      ((cs / 2) * 8 < PMP_CSRS)) ||
                     ((PMP_CSRS > 0) && (ai >= 0) && (ai < PMP_CSRS));
                // hpmcounterN like cycle / instret
                if (a[11:5] == 7'h60) dn = ctr_dn;
            end
        endcase
        // bits 9:8 of the address are the lowest level that may use it
        if (a[9:8] > lvl) dn = 1'b1;
        return {ex, dn};
    endfunction

    // the debugger is not subject to the level
    /* verilator lint_off UNUSEDSIGNAL */
    logic        rd_denied_unused;
    /* verilator lint_on UNUSEDSIGNAL */
    assign {ex_exists, ex_denied} = csr_check(ex_addr, 1'b0, priv_r, mcounteren,
                                              scounteren, menvcfg_stce, mstatus_tvm);
    assign {rd_exists, rd_denied_unused} = csr_check(rd_addr, dbg_access, priv_r,
                                              mcounteren, scounteren, menvcfg_stce,
                                              mstatus_tvm);

    // the two top bits of the address say whether the CSR can be written
    assign ex_readonly = (ex_addr[11:10] == 2'b11);
    assign rd_readonly = (rd_addr[11:10] == 2'b11);

    logic        hpm_rd_hit;
    logic [63:0] hpm_rdata;
    int          rd_hpm_idx;

    // mhpmcounter3-31 (0xB03-), hpmcounter3-31 (0xC03-), mhpmevent3-31
    // (0x323-): all of them exist, those past the implemented ones read 0
    assign rd_hpm_idx = int'(rd_addr[4:0]) - 3;
    always @(*) begin
        hpm_rd_hit = 1'b0;
        hpm_rdata  = 64'd0;
        if (rd_addr[4:0] >= 5'd3) begin
            if ((rd_addr[11:5] == 7'h58) || (rd_addr[11:5] == 7'h60)) begin
                hpm_rd_hit = 1'b1;
                for (int i = 0; i < HPM_COUNTERS; i++)
                    if (rd_hpm_idx == i) hpm_rdata = hpm_cnt[i];
            end else if (rd_addr[11:5] == 7'h19) begin
                hpm_rd_hit = 1'b1;
                for (int i = 0; i < HPM_COUNTERS; i++)
                    if (rd_hpm_idx == i)
                        hpm_rdata = {hpm_of[i], hpm_minh[i], hpm_sinh[i], hpm_uinh[i],
                                     2'b00, 53'd0, hpm_sel[i]};
            end
        end
    end
    logic [63:0] pmp_rdata;

    // pmpcfg0 / pmpcfg2 / ... : even numbered only on RV64, eight entries each
    // pmpaddr0 ... pmpaddr(N-1)
    //   pmpcfg0 .. pmpcfg14 : eight entries each, only the even numbered
    //   ones exist on RV64.  pmpaddr0 .. pmpaddr63 : one entry each.
    int rd_cfg_sel, rd_cfg_base, rd_addr_idx;

    always @(*) begin
        pmp_rdata   = 64'd0;
        rd_cfg_sel  = int'(rd_addr) - int'(CSR_PMPCFG0);
        rd_cfg_base = (rd_cfg_sel / 2) * 8;
        rd_addr_idx = int'(rd_addr) - int'(CSR_PMPADDR0);
        if (PMP_CSRS > 0) begin
            if ((rd_cfg_sel >= 0) && (rd_cfg_sel < 16) && (rd_cfg_sel % 2 == 0) &&
                (rd_cfg_base < PMP_CSRS)) begin
                for (int i = 0; i < 8; i++)
                    if (rd_cfg_base + i < PMP_ENTRIES)
                        pmp_rdata[8*i +: 8] = pmpcfg[rd_cfg_base + i];
            end else if ((rd_addr_idx >= 0) && (rd_addr_idx < PMP_CSRS)) begin
                if (rd_addr_idx < PMP_ENTRIES)
                    pmp_rdata = {10'd0, pmpaddr[rd_addr_idx]};
            end
        end
    end

    always @(*) begin
        rd_data   = 64'd0;
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
            CSR_SENVCFG   : rd_data = 64'd0;
            CSR_STIMECMP  : rd_data = stimecmp;
            CSR_MENVCFG   : rd_data = {menvcfg_stce, 63'd0};
            CSR_MCOUNTINHIBIT: rd_data = {32'd0, hpm_inh[31:3], inhibit_ir, 1'b0, inhibit_cy};
            CSR_MCYCLECFG : rd_data = {1'b0, cy_minh, cy_sinh, cy_uinh, 60'd0};
            CSR_MINSTRETCFG:rd_data = {1'b0, ir_minh, ir_sinh, ir_uinh, 60'd0};
            // the supervisor sees the overflow of a counter only if M lets
            // it read that counter
            CSR_SCOUNTOVF : rd_data = {32'd0, hpm_ovf &
                                       ((priv_r == PRIV_M) ? 32'hFFFF_FFFF : mcounteren)};
            CSR_SATP      : rd_data = satp;
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
            CSR_CYCLE     : rd_data = mcycle;
            CSR_TIME      : rd_data = mtime;
            CSR_INSTRET   : rd_data = minstret;
            CSR_MVENDORID : rd_data = 64'd0;
            CSR_MARCHID   : rd_data = 64'd0;
            CSR_MIMPID    : rd_data = 64'd0;
            CSR_MHARTID   : rd_data = HART_ID;
            CSR_DCSR      : rd_data = {32'd0, 4'd4, 12'd0, dcsr_ebreakm_r, 1'b0,
                                       dcsr_ebreaks_r, dcsr_ebreaku_r, 3'b000, dcsr_cause,
                                       3'b000, dcsr_step_r, dcsr_prv};
            CSR_TSELECT   : rd_data = 64'(tselect);
            CSR_TDATA1    : rd_data = tdata1_val;
            CSR_TDATA2    : rd_data = t_data2[tselect];
            CSR_TDATA3    : rd_data = 64'd0;     // no textra
            CSR_TINFO     : rd_data = 64'd4;     // type 2 only
            CSR_TCONTROL  : rd_data = {56'd0, tc_mpte, 3'd0, tc_mte, 3'd0};
            CSR_DPC       : rd_data = dpc;
            CSR_DSCRATCH0 : rd_data = dscratch0;
            CSR_DSCRATCH1 : rd_data = dscratch1;
            default       : rd_data = hpm_rd_hit ? hpm_rdata : pmp_rdata;
        endcase
    end

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
    // supervisor, and external before software before timer; the counter
    // overflow after all of them
    always @(*) begin
        if      (irq_deliver[IRQ_M_EXT])   irq_cause = 5'(IRQ_M_EXT);
        else if (irq_deliver[IRQ_M_SOFT])  irq_cause = 5'(IRQ_M_SOFT);
        else if (irq_deliver[IRQ_M_TIMER]) irq_cause = 5'(IRQ_M_TIMER);
        else if (irq_deliver[IRQ_S_EXT])   irq_cause = 5'(IRQ_S_EXT);
        else if (irq_deliver[IRQ_S_SOFT])  irq_cause = 5'(IRQ_S_SOFT);
        else if (irq_deliver[IRQ_S_TIMER]) irq_cause = 5'(IRQ_S_TIMER);
        else                               irq_cause = 5'(IRQ_LCOF);
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
            dcsr_ebreakm_r <= 1'b0;
            dcsr_ebreaks_r <= 1'b0;
            dcsr_ebreaku_r <= 1'b0;
            dcsr_step_r    <= 1'b0;
            dcsr_prv       <= PRIV_M;
            dcsr_cause     <= 3'd0;
            dpc            <= 64'd0;
            dscratch0      <= 64'd0;
            dscratch1      <= 64'd0;
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
            menvcfg_stce <= 1'b0;
            tselect      <= '0;
            t_dmode      <= '0;
            t_action     <= '0;
            t_hit        <= '0;
            t_m          <= '0;
            t_s          <= '0;
            t_u          <= '0;
            t_exec       <= '0;
            t_store      <= '0;
            t_load       <= '0;
            for (int i = 0; i < TRIGGERS; i++) t_data2[i] <= 64'd0;
            tc_mte       <= 1'b0;
            tc_mpte      <= 1'b0;
            inhibit_cy   <= 1'b0;
            inhibit_ir   <= 1'b0;
            for (int i = 0; i < HPM_N; i++) begin
                hpm_cnt[i] <= 64'd0;
                hpm_sel[i] <= 5'd0;
            end
            hpm_of       <= '0;
            hpm_minh     <= '0;
            hpm_sinh     <= '0;
            hpm_uinh     <= '0;
            inhibit_hpm  <= '0;
            mip_lcofip   <= 1'b0;
            mie_lcofie   <= 1'b0;
            hpm_ev_q     <= '0;
            hpm_priv_q   <= PRIV_M;
            {cy_minh, cy_sinh, cy_uinh} <= 3'b000;
            {ir_minh, ir_sinh, ir_uinh} <= 3'b000;
            stimecmp     <= {64{1'b1}};      // never, until written
            stip_cmp     <= 1'b0;
            fflags       <= 5'd0;
            frm          <= 3'd0;
            for (int i = 0; i < PMP_ENTRIES; i++) begin
                pmpcfg[i]  <= 8'd0;
                pmpaddr[i] <= 54'd0;
            end
        end else begin
            if (!inhibit_cy && !cy_filt)                mcycle   <= mcycle + 64'd1;
            if (instret_inc && !inhibit_ir && !ir_filt) minstret <= minstret + 64'd1;
            // the counters of events: what happened last cycle, at the
            // level it happened at, unless the counter is inhibited or its
            // mhpmevent leaves that level out. Wrapping sets OF; OF going
            // from 0 to 1 raises the overflow interrupt.
            hpm_ev_q   <= hpm_ev;
            hpm_priv_q <= priv_r;
            for (int i = 0; i < HPM_COUNTERS; i++) begin
                if (hpm_ev_q[hpm_sel[i]] && !inhibit_hpm[i] &&
                    !((hpm_priv_q == PRIV_M) ? hpm_minh[i] :
                      (hpm_priv_q == PRIV_S) ? hpm_sinh[i] : hpm_uinh[i])) begin
                    hpm_cnt[i] <= hpm_cnt[i] + 64'd1;
                    if (&hpm_cnt[i]) begin
                        hpm_of[i] <= 1'b1;
                        if (!hpm_of[i]) mip_lcofip <= 1'b1;
                    end
                end
            end
            stip_cmp <= (mtime >= stimecmp);
            // a trigger fired: the trap or the halt it caused happens now
            t_hit    <= t_hit | trig_fired;

            // the flags of the operations pile up; a write of the CSR below
            // takes precedence over the accumulation of the same cycle
            if (fflags_we) fflags <= fflags | fflags_set;
            if (fs_dirty)  mstatus_fs <= 2'b11;

            if (dbg_enter) begin
                // nothing else changes: debug mode runs at M privilege, but
                // no instruction runs in it here (no program buffer)
                dpc        <= {dbg_pc[63:1], 1'b0};
                dcsr_cause <= dbg_cause;
                dcsr_prv   <= priv_r;
            end else if (dbg_resume) begin
                // dret: back to the level in dcsr.prv; below M that clears
                // MPRV, as an MRET to that level does
                priv_r <= dcsr_prv;
                if (dcsr_prv != PRIV_M) mstatus_mprv <= 1'b0;
            end else if (trap_en) begin
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
                    // no M mode breakpoint in the handler until MRET
                    tc_mpte      <= tc_mte;
                    tc_mte       <= 1'b0;
                end
            end else if (mret_en) begin
                tc_mte       <= tc_mpte;
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
                        mie_lcofie <= wr_data[IRQ_LCOF];
                    end
                    CSR_SIE: begin
                        // only the delegated bits are visible through sie
                        if (mideleg[IRQ_S_SOFT])  mie_ssie <= wr_data[IRQ_S_SOFT];
                        if (mideleg[IRQ_S_TIMER]) mie_stie <= wr_data[IRQ_S_TIMER];
                        if (mideleg[IRQ_S_EXT])   mie_seie <= wr_data[IRQ_S_EXT];
                        if (mideleg[IRQ_LCOF])    mie_lcofie <= wr_data[IRQ_LCOF];
                    end
                    CSR_MIP: begin
                        mip_ssip <= wr_data[IRQ_S_SOFT];
                        // with STCE the bit is the comparison, read only
                        if (!menvcfg_stce) mip_stip <= wr_data[IRQ_S_TIMER];
                        mip_seip <= wr_data[IRQ_S_EXT];
                        mip_lcofip <= wr_data[IRQ_LCOF];
                    end
                    CSR_MENVCFG      : menvcfg_stce <= wr_data[63];
                    CSR_MCOUNTINHIBIT: begin
                        inhibit_cy <= wr_data[0];
                        inhibit_ir <= wr_data[2];
                        for (int i = 0; i < HPM_COUNTERS; i++)
                            inhibit_hpm[i] <= wr_data[3+i];
                    end
                    CSR_STIMECMP     : stimecmp <= wr_data;
                    CSR_MCYCLECFG    : {cy_minh, cy_sinh, cy_uinh} <= wr_data[62:60];
                    CSR_MINSTRETCFG  : {ir_minh, ir_sinh, ir_uinh} <= wr_data[62:60];
                    // a value past the last trigger is not taken (that is
                    // how a debugger counts them)
                    CSR_TSELECT      : if (wr_data < 64'(TRIGGERS))
                                           tselect <= wr_data[TSEL_BITS-1:0];
                    CSR_TDATA1       : if (t_writable) begin
                        if (wr_data[63:60] == 4'd2) begin
                            // dmode only from the debugger; action 1 (enter
                            // debug mode) only for a trigger of the debugger
                            t_dmode [tselect] <= dbg_access & wr_data[59];
                            t_action[tselect] <= dbg_access & wr_data[59] &
                                                 (wr_data[15:12] == 4'd1);
                            t_hit   [tselect] <= wr_data[20];
                            t_m     [tselect] <= wr_data[6];
                            t_s     [tselect] <= wr_data[4];
                            t_u     [tselect] <= wr_data[3];
                            t_exec  [tselect] <= wr_data[2];
                            t_store [tselect] <= wr_data[1];
                            t_load  [tselect] <= wr_data[0];
                        end else begin
                            // another type (0 is "disabled"): nothing matches
                            t_dmode [tselect] <= 1'b0;
                            t_action[tselect] <= 1'b0;
                            t_hit   [tselect] <= 1'b0;
                            t_m     [tselect] <= 1'b0;
                            t_s     [tselect] <= 1'b0;
                            t_u     [tselect] <= 1'b0;
                            t_exec  [tselect] <= 1'b0;
                            t_store [tselect] <= 1'b0;
                            t_load  [tselect] <= 1'b0;
                        end
                    end
                    CSR_TDATA2       : if (t_writable) t_data2[tselect] <= wr_data;
                    CSR_TCONTROL     : begin
                        tc_mte  <= wr_data[3];
                        tc_mpte <= wr_data[7];
                    end
                    CSR_SIP: begin
                        // the supervisor may only clear its own software
                        // interrupt; the timer and external ones belong to M
                        if (mideleg[IRQ_S_SOFT]) mip_ssip <= wr_data[IRQ_S_SOFT];
                        // and the overflow, which is its business when
                        // delegated (Sscofpmf)
                        if (mideleg[IRQ_LCOF])   mip_lcofip <= wr_data[IRQ_LCOF];
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
                    CSR_DCSR      : if (dbg_access) begin
                        dcsr_ebreakm_r <= wr_data[15];
                        dcsr_ebreaks_r <= wr_data[13];
                        dcsr_ebreaku_r <= wr_data[12];
                        dcsr_step_r    <= wr_data[2];
                        // prv is WARL: 2 (hypervisor) does not exist
                        if (wr_data[1:0] != 2'b10) dcsr_prv <= wr_data[1:0];
                    end
                    CSR_DPC       : if (dbg_access) dpc       <= {wr_data[63:1], 1'b0};
                    CSR_DSCRATCH0 : if (dbg_access) dscratch0 <= wr_data;
                    CSR_DSCRATCH1 : if (dbg_access) dscratch1 <= wr_data;
                    CSR_MCYCLE    : mcycle     <= wr_data;
                    CSR_MINSTRET  : minstret   <= wr_data;
                    default       : begin
                        // mhpmcounterN / mhpmeventN; an event number that
                        // does not exist is taken as 0 (nothing). misa and
                        // the read only ones end here too.
                        for (int i = 0; i < HPM_COUNTERS; i++) begin
                            if (wr_addr == 12'hB03 + 12'(i))
                                hpm_cnt[i] <= wr_data;
                            if (wr_addr == 12'h323 + 12'(i)) begin
                                hpm_of[i]   <= wr_data[63];
                                hpm_minh[i] <= wr_data[62];
                                hpm_sinh[i] <= wr_data[61];
                                hpm_uinh[i] <= wr_data[60];
                                hpm_sel[i]  <= (wr_data[55:0] < 56'(HPM_EVENTS))
                                             ? wr_data[4:0] : 5'd0;
                            end
                        end
                    end
                endcase
                end
            end
        end
    end

endmodule : CORE_CSR
