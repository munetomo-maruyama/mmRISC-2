//---------------------------------------------------------------------------
// CPU_CORE.sv
//
// mmRISC-2 CPU core (RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md).
//
//   IF1 / IF2 : CORE_IFU, instruction cache and fetch queue
//   ID        : CORE_DEC and the register file
//   EX        : CORE_EXU (ALU, branch, address), the DTLB, the CSR read,
//               the multi cycle units (MDU, FPU)
//   MR        : the PMP check and the data cache request
//   MA        : waits for the data cache answer. This is the commit point:
//               a trap, an MRET and a CSR write happen here
//   WB        : register write back and trace
//
//   M5 : RV64IMAFDC + Zicsr + machine, supervisor and user mode with
//   delegation. The privilege level lives in CORE_CSR; the pipeline reads it
//   to decide which instructions are legal and which ECALL cause to raise.
//
//   Why the commit point is MA and not WB: a store hands its data to the
//   cache in MR, so the trap of the instruction in front of it has to be
//   decided while the store is still in MR. With the trap taken in MA the
//   store is one stage behind the trapping instruction and is held back by
//   `trap_taken`.
//
//   Why MR is a stage of its own: deciding whether a memory access may go
//   to the cache needs the forwarded operand, the address, the DTLB, the
//   PMP and the exception that comes out of them, and at 50 MHz on an
//   Artix-7 that did not fit in one cycle (LitexSystem/docs/TIMING.md 15).
//   EX now ends with the translated address, MR checks it and issues it.
//   A load is one stage further from EX, so an instruction that uses its
//   result right behind it waits one cycle more (the load-use interlock
//   below).
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_CORE
    #(
        parameter int          PADDR_WIDTH  = 40,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000,
        parameter logic [63:0] HART_ID      = 64'd0,
        parameter int          PQ_DEPTH     = 16,     // parcels in the fetch queue
        parameter int          PMP_ENTRIES  = 8,     // 0 removes PMP
        parameter int          ITLB_ENTRIES = 8,
        parameter int          DTLB_ENTRIES = 8,
        parameter int          BTB_ENTRIES  = 64
    )
    (
        input  logic                    clk,
        input  logic                    rst_n,

        // instruction cache
        output logic                    i_req_valid,
        input  logic                    i_req_ready,
        output logic [PADDR_WIDTH-1:0]  i_req_addr,
        output logic [PADDR_WIDTH-1:0]  i_req_paddr,
        input  logic                    i_resp_valid,
        input  logic [63:0]             i_resp_data,
        input  logic                    i_resp_error,
        output logic                    i_flush_valid,
        input  logic                    i_flush_done,
        output logic                    i_kill,

        // data cache
        output logic                    d_req_valid,
        input  logic                    d_req_ready,
        output logic [PADDR_WIDTH-1:0]  d_req_addr,
        output logic [PADDR_WIDTH-1:0]  d_req_paddr,
        output logic [1:0]              d_req_size,
        output logic [3:0]              d_req_cmd,
        output logic [63:0]             d_req_wdata,
        input  logic                    d_resp_valid,
        input  logic [63:0]             d_resp_data,
        input  logic                    d_resp_error,

        // interrupts (CLINT, PLIC)
        input  logic                    irq_m_soft,
        input  logic                    irq_m_timer,
        input  logic                    irq_m_ext,
        input  logic                    irq_s_ext,
        input  logic [63:0]             mtime,

        // retirement trace (verification)
        output logic                    trace_valid,
        output logic [63:0]             trace_pc,
        output logic [31:0]             trace_insn,
        output logic                    trace_rd_we,
        output logic [4:0]              trace_rd,
        output logic [63:0]             trace_rd_data,
        output logic [1:0]              trace_priv,

        // trap trace (verification)
        output logic                    trap_valid,
        output logic                    trap_is_int,
        output logic [4:0]              trap_cause,
        output logic [63:0]             trap_epc,
        output logic [63:0]             trap_tval,
        output logic                    trap_to_s
    );

    //=================================================================
    // exception causes
    //=================================================================
    localparam logic [4:0] EXC_IADDR  = 5'd0;    // instruction address misaligned
    localparam logic [4:0] EXC_IFAULT = 5'd1;    // instruction access fault
    localparam logic [4:0] EXC_ILLEGAL= 5'd2;
    localparam logic [4:0] EXC_BREAK  = 5'd3;
    localparam logic [4:0] EXC_LADDR  = 5'd4;    // load address misaligned
    localparam logic [4:0] EXC_LFAULT = 5'd5;    // load access fault
    localparam logic [4:0] EXC_SADDR  = 5'd6;    // store address misaligned
    localparam logic [4:0] EXC_SFAULT = 5'd7;    // store access fault
    localparam logic [4:0] EXC_ECALL_U= 5'd8;    // 8 + priv : U 8, S 9, M 11
    localparam logic [4:0] EXC_IPAGE  = 5'd12;   // instruction page fault
    localparam logic [4:0] EXC_LPAGE  = 5'd13;
    localparam logic [4:0] EXC_SPAGE  = 5'd15;

    //=================================================================
    // privilege levels
    //=================================================================
    localparam logic [1:0] PRIV_U = 2'b00;
    localparam logic [1:0] PRIV_S = 2'b01;
    localparam logic [1:0] PRIV_M = 2'b11;

    //=================================================================
    // ID : fetch queue, decoder, register file
    //=================================================================
    logic        fq_valid, fq_ready, fq_is_rvc, fq_fault_hi;
    logic [1:0]  fq_fault;
    logic        fq_pred_taken, btb_upd_valid;
    logic [63:0] fq_pred_target;

    // What the execute stage tells the branch target buffer. Declared here,
    // above the instance that uses them, because everything they are driven
    // from lives further down: naming those directly would leave Icarus
    // Verilog with one bit wide implicit wires and silently truncated
    // addresses.
    logic [63:0] btb_upd_pc, btb_upd_target;
    logic        btb_upd_is32, btb_upd_taken, btb_flush;
    logic [63:0] fq_pc;

    // to and from the MMU
    logic        i_tr_req, i_tr_ready;
    logic [63:0] i_tr_vaddr, i_tr_paddr;
    logic [1:0]  i_tr_fault;
    logic        d_tr_req, d_tr_ready;
    logic [63:0] d_tr_paddr;
    logic [1:0]  d_tr_fault;

    // the data cache port, shared between the load store unit and the walker
    logic                   lsu_idle, ptw_active;
    logic                   lsu_d_req_valid, lsu_d_req_ready;
    logic [PADDR_WIDTH-1:0] lsu_d_req_addr, lsu_d_req_paddr;
    logic [1:0]             lsu_d_req_size;
    logic [3:0]             lsu_d_req_cmd;
    logic [63:0]            lsu_d_req_wdata;
    logic                   lsu_d_resp_valid;
    logic                   ptw_req_valid, ptw_req_ready, ptw_resp_valid;
    logic [63:0]            ptw_req_addr, ptw_req_paddr;
    logic [31:0] fq_insn;          // raw, 16 bit in the low half when compressed

    logic        redirect_valid;
    logic [63:0] redirect_pc;

    CORE_IFU
        #(.PADDR_WIDTH(PADDR_WIDTH), .RESET_VECTOR(RESET_VECTOR),
          .PQ_DEPTH(PQ_DEPTH), .BTB_ENTRIES(BTB_ENTRIES))
    u_ifu
        (
            .clk            (clk),
            .rst_n          (rst_n),
            .i_req_valid    (i_req_valid),
            .i_req_ready    (i_req_ready),
            .i_req_addr     (i_req_addr),
            .i_req_paddr    (i_req_paddr),
            .i_resp_valid   (i_resp_valid),
            .i_resp_data    (i_resp_data),
            .i_resp_error   (i_resp_error),
            .i_kill         (i_kill),
            .redirect_valid (redirect_valid),
            .redirect_pc    (redirect_pc),
            .tr_req         (i_tr_req),
            .tr_vaddr       (i_tr_vaddr),
            .tr_ready       (i_tr_ready),
            .tr_paddr       (i_tr_paddr),
            .tr_fault       (i_tr_fault),
            .fq_valid       (fq_valid),
            .fq_ready       (fq_ready),
            .fq_pc          (fq_pc),
            .fq_insn        (fq_insn),
            .fq_is_rvc      (fq_is_rvc),
            .fq_fault       (fq_fault),
            .fq_fault_hi    (fq_fault_hi),
            .fq_pred_taken  (fq_pred_taken),
            .fq_pred_target (fq_pred_target),
            .btb_upd_valid  (btb_upd_valid),
            .btb_upd_pc     (btb_upd_pc),
            .btb_upd_is32   (btb_upd_is32),
            .btb_upd_target (btb_upd_target),
            .btb_upd_taken  (btb_upd_taken),
            .btb_flush      (btb_flush)
        );


    // a compressed instruction is turned into the 32 bit one that means the
    // same, so that there is only one decoder
    logic [31:0] decomp_insn, id_insn;
    logic        decomp_illegal;

    CORE_DECOMP u_decomp
        (
            .insn_c  (fq_insn[15:0]),
            .insn    (decomp_insn),
            .illegal (decomp_illegal)
        );

    assign id_insn = fq_is_rvc ? decomp_insn : fq_insn;

    // decoder
    logic [4:0]  dec_rs1, dec_rs2, dec_rd;
    logic        dec_use_rs1, dec_use_rs2, dec_we_rd;
    logic [63:0] dec_imm;
    logic [3:0]  dec_alu_op;
    logic [1:0]  dec_a_sel;
    logic        dec_b_sel, dec_word_op;
    logic        dec_is_branch, dec_is_jal, dec_is_jalr;
    logic [2:0]  dec_br_op;
    logic        dec_is_mdu;
    logic [2:0]  dec_mdu_op;
    logic        dec_is_load, dec_is_store;
    logic [3:0]  dec_mem_cmd;
    logic [1:0]  dec_mem_size;
    logic        dec_mem_signed;
    logic        dec_is_fence, dec_is_fence_i, dec_is_ecall, dec_is_ebreak;
    logic        dec_is_mret, dec_is_sret, dec_is_sfence, dec_is_wfi, dec_illegal;
    logic        dec_is_fp, dec_fp_arith, dec_fp_fmt;
    logic [4:0]  dec_fp_op;
    logic [2:0]  dec_fp_rm;
    logic        dec_use_fs1, dec_use_fs2, dec_use_fs3, dec_fp_we_rd;
    logic        dec_fp_int_signed, dec_fp_int_w;
    logic        dec_is_fp_load, dec_is_fp_store;
    logic        dec_is_csr, dec_csr_imm_sel, dec_csr_wr, dec_csr_rd;
    logic [11:0] dec_csr_addr;
    logic [1:0]  dec_csr_op;

    CORE_DEC u_dec
        (
            .insn        (id_insn),
            .rs1         (dec_rs1),
            .rs2         (dec_rs2),
            .rd          (dec_rd),
            .use_rs1     (dec_use_rs1),
            .use_rs2     (dec_use_rs2),
            .we_rd       (dec_we_rd),
            .imm         (dec_imm),
            .alu_op      (dec_alu_op),
            .a_sel       (dec_a_sel),
            .b_sel       (dec_b_sel),
            .word_op     (dec_word_op),
            .is_branch   (dec_is_branch),
            .is_jal      (dec_is_jal),
            .is_jalr     (dec_is_jalr),
            .br_op       (dec_br_op),
            .is_mdu      (dec_is_mdu),
            .mdu_op      (dec_mdu_op),
            .is_load     (dec_is_load),
            .is_store    (dec_is_store),
            .mem_cmd     (dec_mem_cmd),
            .mem_size    (dec_mem_size),
            .mem_signed  (dec_mem_signed),
            .is_fence    (dec_is_fence),
            .is_fence_i  (dec_is_fence_i),
            .is_ecall    (dec_is_ecall),
            .is_ebreak   (dec_is_ebreak),
            .is_mret     (dec_is_mret),
            .is_sret     (dec_is_sret),
            .is_sfence   (dec_is_sfence),
            .is_wfi      (dec_is_wfi),
            .illegal     (dec_illegal),
            .is_fp         (dec_is_fp),
            .fp_arith      (dec_fp_arith),
            .fp_op         (dec_fp_op),
            .fp_fmt        (dec_fp_fmt),
            .fp_rm         (dec_fp_rm),
            .use_fs1       (dec_use_fs1),
            .use_fs2       (dec_use_fs2),
            .use_fs3       (dec_use_fs3),
            .fp_we_rd      (dec_fp_we_rd),
            .fp_int_signed (dec_fp_int_signed),
            .fp_int_w      (dec_fp_int_w),
            .is_fp_load    (dec_is_fp_load),
            .is_fp_store   (dec_is_fp_store),
            .is_csr      (dec_is_csr),
            .csr_addr    (dec_csr_addr),
            .csr_op      (dec_csr_op),
            .csr_imm_sel (dec_csr_imm_sel),
            .csr_wr      (dec_csr_wr),
            .csr_rd      (dec_csr_rd)
        );

    logic [63:0] rf_rs1_data, rf_rs2_data;
    logic        wb_valid, wb_we_rd;
    logic [4:0]  wb_rd;
    logic [63:0] wb_data;

    CORE_RF u_rf
        (
            .clk      (clk),
            .rst_n    (rst_n),
            .rs1      (dec_rs1),
            .rs1_data (rf_rs1_data),
            .rs2      (dec_rs2),
            .rs2_data (rf_rs2_data),
            .we       (wb_valid & wb_we_rd),
            .rd       (wb_rd),
            .rd_data  (wb_data)
        );

    //=================================================================
    // floating point register file
    //=================================================================
    logic [63:0] frf_fs1_data, frf_fs2_data, frf_fs3_data;
    logic        wb_fp_we;
    logic [63:0] wb_fp_data;
    logic [4:0]  wb_fp_rd;

    CORE_FRF u_frf
        (
            .clk      (clk),
            .rst_n    (rst_n),
            .rs1      (dec_rs1),
            .rs1_data (frf_fs1_data),
            .rs2      (dec_rs2),
            .rs2_data (frf_fs2_data),
            .rs3      (fq_insn[31:27]),
            .rs3_data (frf_fs3_data),
            .we       (wb_valid & wb_fp_we),
            .rd       (wb_fp_rd),
            .rd_data  (wb_fp_data)
        );

    //=================================================================
    // pipeline control
    //
    //   Declared here because the units below are held back by them: an
    //   iterative unit must not start while MA is still waiting for the
    //   cache, and it has to be killed when a trap empties the pipeline.
    //=================================================================
    logic ex_mem, stall_ma, stall_ex, ex_advance, ex_mmu_wait;
    logic mr_is_mem, stall_mr, mr_advance, lu_hazard;
    logic id_ready, id_advance, pipe_busy, serial_busy, wfi_wait, flush;
    logic ma_exc, trap_taken, mret_taken, sret_taken, fencei_taken, fencei_busy;
    logic refetch_taken;
    logic sfence_taken, commit, ex_mispredict;

    // the exception of the instruction in EX. `ex_exc_pre` is everything
    // that is known before the address is translated, `ex_exc` has the
    // fault of the translation on top of it. The PMP comes in MR.
    logic        ex_exc_pre, ex_exc, ex_exc_int;
    logic [4:0]  ex_exc_cause_pre, ex_exc_cause;
    logic [63:0] ex_exc_tval_pre, ex_exc_tval;

    //=================================================================
    // EX stage registers
    //=================================================================
    logic        ex_valid;
    logic [63:0] ex_pc, ex_rs1_data, ex_rs2_data, ex_imm;
    logic [31:0] ex_insn;
    logic [4:0]  ex_rs1, ex_rs2, ex_rd;
    logic        ex_we_rd, ex_b_sel, ex_word_op;
    logic [3:0]  ex_alu_op;
    logic [1:0]  ex_a_sel;
    logic [2:0]  ex_br_op;
    logic        ex_is_branch, ex_is_jal, ex_is_jalr, ex_is_rvc;
    logic        ex_is_mdu;
    logic [2:0]  ex_mdu_op;
    logic        ex_is_load, ex_is_store;
    logic [3:0]  ex_mem_cmd;
    logic [1:0]  ex_mem_size;
    logic        ex_mem_signed;
    logic        ex_is_fp, ex_fp_arith, ex_fp_fmt, ex_fp_we_rd;
    logic [4:0]  ex_fp_op;
    logic [2:0]  ex_fp_rm;
    logic        ex_use_fs1, ex_use_fs2, ex_use_fs3;
    logic        ex_fp_int_signed, ex_fp_int_w;
    logic        ex_is_fp_store, ex_fp_box;
    logic [4:0]  ex_fs1, ex_fs2, ex_fs3;
    logic [63:0] ex_fs1_data, ex_fs2_data, ex_fs3_data;
    logic        ex_is_csr, ex_csr_imm_sel, ex_csr_wr;
    logic [4:0]  ex_csr_uimm;
    logic [11:0] ex_csr_addr;
    logic [1:0]  ex_csr_op;
    logic        ex_is_mret, ex_is_sret, ex_is_sfence, ex_is_fencei, ex_serial;
    logic        ex_pred_taken;
    logic [63:0] ex_pred_target;
    logic        ex_exc_r;                 // exception seen in ID
    logic        ex_exc_int_r;
    logic [4:0]  ex_exc_cause_r;
    logic [63:0] ex_exc_tval_r;

    //=================================================================
    // MR stage registers
    //
    //   What MA used to be given by EX, and the access itself: the
    //   translated address, the command and the data of a store.
    //=================================================================
    logic        mr_valid, mr_we_rd, mr_mem, mr_is_load, mr_is_store;
    logic [63:0] mr_pc, mr_result;
    logic [31:0] mr_insn;
    logic [4:0]  mr_rd;
    logic        mr_is_mret, mr_is_sret, mr_is_sfence, mr_is_fencei;
    logic        mr_refetch;
    logic        mr_is_rvc, mr_serial;
    logic [63:0] mr_sfence_vaddr, mr_sfence_asid;
    logic        mr_is_fp, mr_fp_arith, mr_fp_we, mr_fp_box;
    logic [4:0]  mr_fp_flags;
    logic        mr_csr_wr;
    logic [11:0] mr_csr_addr;
    logic [63:0] mr_csr_wdata;
    logic        mr_exc_r, mr_exc_int_r;
    logic [4:0]  mr_exc_cause_r;
    logic [63:0] mr_exc_tval_r;
    logic [3:0]  mr_cmd;
    logic [63:0] mr_vaddr, mr_paddr, mr_wdata;
    logic [1:0]  mr_size;
    logic        mr_signed;
    logic        mr_pmp_fail;     // from the PMP of the data side, for MR

    //=================================================================
    // MA stage registers
    //=================================================================
    logic        ma_valid, ma_we_rd, ma_mem, ma_is_load, ma_is_store;
    logic [63:0] ma_pc, ma_result;
    logic [31:0] ma_insn;
    logic [4:0]  ma_rd;
    logic        ma_is_mret, ma_is_sret, ma_is_sfence, ma_is_fencei;
    logic        ma_refetch;     // predicted taken but not a control transfer
    logic        ma_is_rvc, ma_serial;
    logic [63:0] ma_sfence_vaddr, ma_sfence_asid;
    logic        ma_is_fp, ma_fp_arith, ma_fp_we, ma_fp_box;
    logic [4:0]  ma_fp_rd;
    logic [4:0]  ma_fp_flags;
    logic        ma_csr_wr;
    logic [11:0] ma_csr_addr;
    logic [63:0] ma_csr_wdata;
    logic        ma_exc_r, ma_exc_int_r;
    logic [4:0]  ma_exc_cause_r;
    logic [63:0] ma_exc_tval_r;

    //=================================================================
    // WB stage registers
    //=================================================================
    logic [63:0] wb_pc;
    logic [31:0] wb_insn;

    //=================================================================
    // forwarding into EX
    //=================================================================
    logic [63:0] ex_a_fwd, ex_b_fwd, ma_fwd_data;
    logic        lsu_resp_valid, lsu_resp_error;
    logic [63:0] lsu_resp_data;

    // EX only moves on while MA is not stalled, so when a load sits in MA its
    // answer is on the cache port in exactly that cycle; ma_result holds the
    // address of the access and must not be forwarded
    assign ma_fwd_data = (ma_mem & ma_is_load) ? lsu_resp_data : ma_result;

    // Three sources, the youngest first: MR, MA, WB. MR only forwards what
    // EX computed; the answer of a load in MR is not there yet, and an
    // instruction that needs it waits (lu_hazard) until the load is in MA.

    // Where each operand comes from is decided one cycle early, into a flip
    // flop per source (see "forwarding selects" next to the pipeline
    // registers): this multiplexer heads the longest path of the design,
    // the address of a load or store on its way through the DTLB and the
    // PMP, and a comparison of register numbers in front of it would put
    // its depth and the routing of ma_rd and wb_rd on that path as well.
    logic fwd_a_mr, fwd_a_ma, fwd_a_wb, fwd_b_mr, fwd_b_ma, fwd_b_wb;

    always @(*) begin
        ex_a_fwd = ex_rs1_data;
        if      (fwd_a_mr) ex_a_fwd = mr_result;
        else if (fwd_a_ma) ex_a_fwd = ma_fwd_data;
        else if (fwd_a_wb) ex_a_fwd = wb_data;

        ex_b_fwd = ex_rs2_data;
        if      (fwd_b_mr) ex_b_fwd = mr_result;
        else if (fwd_b_ma) ex_b_fwd = ma_fwd_data;
        else if (fwd_b_wb) ex_b_fwd = wb_data;
    end

    //=================================================================
    // forwarding of the floating point sources
    //
    //   f0 is an ordinary register, so "this instruction does not use the
    //   source" is a flag of its own and not the register number zero.
    //=================================================================
    logic [63:0] ex_fs1_fwd, ex_fs2_fwd, ex_fs3_fwd, ma_fp_fwd_data;
    logic [63:0] ma_load_data;

    assign ma_load_data  = ma_fp_box ? {32'hFFFF_FFFF, lsu_resp_data[31:0]}
                                     : lsu_resp_data;
    assign ma_fp_fwd_data = (ma_mem & ma_is_load) ? ma_load_data : ma_result;

    // what MR can forward : a floating point result EX computed (not a load)
    logic mr_fp_fwd;
    assign mr_fp_fwd = mr_valid & mr_fp_we & ~mr_mem;

    always @(*) begin
        ex_fs1_fwd = ex_fs1_data;
        if      (ex_use_fs1 && mr_fp_fwd && (mr_rd == ex_fs1))                ex_fs1_fwd = mr_result;
        else if (ex_use_fs1 && ma_valid && ma_fp_we && (ma_fp_rd == ex_fs1)) ex_fs1_fwd = ma_fp_fwd_data;
        else if (ex_use_fs1 && wb_valid && wb_fp_we && (wb_fp_rd == ex_fs1)) ex_fs1_fwd = wb_fp_data;

        ex_fs2_fwd = ex_fs2_data;
        if      (ex_use_fs2 && mr_fp_fwd && (mr_rd == ex_fs2))                ex_fs2_fwd = mr_result;
        else if (ex_use_fs2 && ma_valid && ma_fp_we && (ma_fp_rd == ex_fs2)) ex_fs2_fwd = ma_fp_fwd_data;
        else if (ex_use_fs2 && wb_valid && wb_fp_we && (wb_fp_rd == ex_fs2)) ex_fs2_fwd = wb_fp_data;

        ex_fs3_fwd = ex_fs3_data;
        if      (ex_use_fs3 && mr_fp_fwd && (mr_rd == ex_fs3))                ex_fs3_fwd = mr_result;
        else if (ex_use_fs3 && ma_valid && ma_fp_we && (ma_fp_rd == ex_fs3)) ex_fs3_fwd = ma_fp_fwd_data;
        else if (ex_use_fs3 && wb_valid && wb_fp_we && (wb_fp_rd == ex_fs3)) ex_fs3_fwd = wb_fp_data;
    end

    //=================================================================
    // EX : ALU, branch, address
    //=================================================================
    logic [63:0] alu_result, link_pc, target_pc, mem_addr;
    logic        take_branch;

    CORE_EXU u_exu
        (
            .rs1_data   (ex_a_fwd),
            .rs2_data   (ex_b_fwd),
            .pc         (ex_pc),
            .imm        (ex_imm),
            .alu_op     (ex_alu_op),
            .a_sel      (ex_a_sel),
            .b_sel      (ex_b_sel),
            .word_op    (ex_word_op),
            .br_op      (ex_br_op),
            .is_branch  (ex_is_branch),
            .is_jal     (ex_is_jal),
            .is_jalr    (ex_is_jalr),
            .is_rvc     (ex_is_rvc),
            .alu_result (alu_result),
            .link_pc    (link_pc),
            .target_pc  (target_pc),
            .take_branch(take_branch),
            .mem_addr   (mem_addr)
        );

    //=================================================================
    // multiply and divide (M)
    //=================================================================
    logic        mdu_active, mdu_start, mdu_busy, mdu_done, mdu_ack;
    logic [63:0] mdu_result;

    CORE_MDU u_mdu
        (
            .clk      (clk),
            .rst_n    (rst_n),
            .start    (mdu_start),
            .kill     (flush),
            .op       (ex_mdu_op),
            .word_op  (ex_word_op),
            .rs1_data (ex_a_fwd),
            .rs2_data (ex_b_fwd),
            .busy     (mdu_busy),
            .done     (mdu_done),
            .ack      (mdu_ack),
            .result   (mdu_result)
        );

    // ex_exc_pre is all an MDU instruction can raise (the translation never
    // sees it), and it keeps the DTLB off the stall of EX
    assign mdu_active = ex_valid & ex_is_mdu & ~ex_exc_pre;
    // Not while MA is waiting for the cache, nor while a load an operand
    // comes from is still in MR: the operand is not there yet, and a unit
    // that runs for several cycles latches what it is given at the start.
    assign mdu_start  = mdu_active & ~mdu_busy & ~mdu_done & ~flush & ~stall_ma &
                        ~lu_hazard;
    assign mdu_ack    = mdu_active & mdu_done & ex_advance;

    //=================================================================
    // floating point unit
    //=================================================================
    logic        fpu_active, fpu_start, fpu_busy, fpu_done, fpu_ack;
    logic [63:0] fpu_result;
    logic        fpu_res_is_int;
    logic [4:0]  fpu_flags;
    logic [63:0] fpu_a;
    logic [2:0]  frm_csr;
    logic [1:0]  fs_csr;
    logic [2:0]  ex_rm_eff;

    assign fpu_a = ex_use_fs1 ? ex_fs1_fwd : ex_a_fwd;

    CORE_FPU u_fpu
        (
            .clk           (clk),
            .rst_n         (rst_n),
            .start         (fpu_start),
            .kill          (flush),
            .op            (ex_fp_op),
            .fmt           (ex_fp_fmt),
            .rm            (ex_rm_eff),
            .int_signed    (ex_fp_int_signed),
            .int_w         (ex_fp_int_w),
            .a             (fpu_a),
            .b             (ex_fs2_fwd),
            .c             (ex_fs3_fwd),
            .busy          (fpu_busy),
            .done          (fpu_done),
            .ack           (fpu_ack),
            .result        (fpu_result),
            .result_is_int (fpu_res_is_int),
            .flags         (fpu_flags)
        );

    assign fpu_active = ex_valid & ex_fp_arith & ~ex_exc_pre;
    assign fpu_start  = fpu_active & ~fpu_busy & ~fpu_done & ~flush & ~stall_ma &
                        ~lu_hazard;
    assign fpu_ack    = fpu_active & fpu_done & ex_advance;

    //=================================================================
    // CSR file
    //=================================================================
    logic [63:0] csr_rdata;
    logic        csr_exists, csr_readonly, csr_denied;
    logic        csr_wr_en;
    logic        trap_en, trap_int_c;
    logic [4:0]  trap_cause_c;
    logic [63:0] trap_epc_c, trap_tval_c, trap_vector;
    logic        mret_en, sret_en;
    logic [63:0] mret_target, sret_target;
    logic        irq_req, irq_any;
    logic [4:0]  irq_cause;

    // privilege and translation state, read by the pipeline and the MMU
    logic [1:0]  priv;
    logic [63:0] satp;
    logic        st_sum, st_mxr, st_mprv, st_tvm, st_tw, st_tsr;
    logic [1:0]  st_mpp;
    logic [8*PMP_ENTRIES-1:0]  pmpcfg;
    logic [64*PMP_ENTRIES-1:0] pmpaddr;

    // misa : bit 0 is 'A' ... bit 8 is 'I' ... bit 12 is 'M'
    // bit 0 'A', 2 'C', 3 'D', 5 'F', 8 'I', 12 'M', 18 'S', 20 'U'
    localparam logic [63:0] MISA_VAL = (64'd2 << 62) | (64'd1 << 0) | (64'd1 << 2) |
                                       (64'd1 << 3) | (64'd1 << 5) |
                                       (64'd1 << 8) | (64'd1 << 12) |
                                       (64'd1 << 18) | (64'd1 << 20);

    CORE_CSR #(.HART_ID(HART_ID), .MISA(MISA_VAL), .PMP_ENTRIES(PMP_ENTRIES)) u_csr
        (
            .clk         (clk),
            .rst_n       (rst_n),
            .rd_addr     (ex_csr_addr),
            .rd_data     (csr_rdata),
            .rd_exists   (csr_exists),
            .rd_readonly (csr_readonly),
            .rd_denied   (csr_denied),
            .wr_en       (csr_wr_en),
            .wr_addr     (ma_csr_addr),
            .wr_data     (ma_csr_wdata),
            .trap_en     (trap_en),
            .trap_int    (trap_int_c),
            .trap_cause  (trap_cause_c),
            .trap_epc    (trap_epc_c),
            .trap_tval   (trap_tval_c),
            .trap_vector (trap_vector),
            .trap_to_s   (trap_to_s),
            .mret_en     (mret_en),
            .sret_en     (sret_en),
            .mret_target (mret_target),
            .sret_target (sret_target),
            .irq_m_soft  (irq_m_soft),
            .irq_m_timer (irq_m_timer),
            .irq_m_ext   (irq_m_ext),
            .irq_s_ext   (irq_s_ext),
            .mtime       (mtime),
            .irq_req     (irq_req),
            .irq_cause   (irq_cause),
            .irq_any     (irq_any),
            .priv        (priv),
            .satp_out    (satp),
            .mstatus_sum_out  (st_sum),
            .mstatus_mxr_out  (st_mxr),
            .mstatus_mprv_out (st_mprv),
            .mstatus_mpp_out  (st_mpp),
            .mstatus_tvm_out  (st_tvm),
            .mstatus_tw_out   (st_tw),
            .mstatus_tsr_out  (st_tsr),
            .pmpcfg_out  (pmpcfg),
            .pmpaddr_out (pmpaddr),
            .instret_inc (commit),
            .fflags_we   (commit & ma_fp_arith),
            .fflags_set  (ma_fp_flags),
            .fs_dirty    (commit & ma_is_fp),
            .frm_out     (frm_csr),
            .fs_out      (fs_csr)
        );

    // the new value of the CSR
    logic [63:0] csr_src, csr_wval;
    assign csr_src = ex_csr_imm_sel ? {59'd0, ex_csr_uimm} : ex_a_fwd;

    always @(*) begin
        case (ex_csr_op)
            2'd2:    csr_wval = csr_rdata |  csr_src;     // set
            2'd3:    csr_wval = csr_rdata & ~csr_src;     // clear
            default: csr_wval = csr_src;                  // write
        endcase
    end

    //=================================================================
    // the rounding mode of the instruction
    //
    //   rm = 111 means "take it from frm". A reserved value, in the
    //   instruction or in frm, makes the instruction illegal.
    //=================================================================
    logic dec_rm_bad;

    always @(*) begin
        ex_rm_eff = (ex_fp_rm == 3'b111) ? frm_csr : ex_fp_rm;
    end

    assign dec_rm_bad = dec_fp_arith &
                        ((dec_fp_rm == 3'b101) || (dec_fp_rm == 3'b110) ||
                         ((dec_fp_rm == 3'b111) &&
                          ((frm_csr == 3'b101) || (frm_csr == 3'b110) ||
                           (frm_csr == 3'b111))));

    // with mstatus.FS off the whole extension is not there
    logic fp_off, csr_is_fp;
    assign fp_off    = (fs_csr == 2'b00);
    assign csr_is_fp = (dec_csr_addr == 12'h001) || (dec_csr_addr == 12'h002) ||
                       (dec_csr_addr == 12'h003);

    //=================================================================
    // exceptions found in EX
    //=================================================================
    logic       misaligned;

    always @(*) begin
        case (ex_mem_size)
            2'd1:    misaligned = mem_addr[0];
            2'd2:    misaligned = |mem_addr[1:0];
            2'd3:    misaligned = |mem_addr[2:0];
            default: misaligned = 1'b0;
        endcase
    end

    always @(*) begin
        ex_exc_pre       = ex_exc_r;
        ex_exc_cause_pre = ex_exc_cause_r;
        ex_exc_tval_pre  = ex_exc_tval_r;
        if (!ex_exc_r) begin
            if (ex_is_csr && (!csr_exists || csr_denied ||
                              (ex_csr_wr && csr_readonly))) begin
                ex_exc_pre       = 1'b1;
                ex_exc_cause_pre = EXC_ILLEGAL;
                ex_exc_tval_pre  = ex_is_rvc ? {48'd0, ex_insn[15:0]}
                                             : {32'd0, ex_insn};
            end else if (take_branch && target_pc[0]) begin
                ex_exc_pre       = 1'b1;
                ex_exc_cause_pre = EXC_IADDR;
                ex_exc_tval_pre  = target_pc;
            end else if ((ex_is_load || ex_is_store) && misaligned) begin
                ex_exc_pre       = 1'b1;
                ex_exc_cause_pre = ex_is_store ? EXC_SADDR : EXC_LADDR;
                ex_exc_tval_pre  = mem_addr;
            end
        end
    end

    // The address is only handed to the MMU when the instruction is going to
    // use it. A misaligned access is reported as misaligned and never
    // translated, which is the order the specification asks for.
    assign d_tr_req = ex_valid & (ex_is_load | ex_is_store) & ~ex_exc_pre;

    always @(*) begin
        ex_exc       = ex_exc_pre;
        ex_exc_int   = ex_exc_int_r;
        ex_exc_cause = ex_exc_cause_pre;
        ex_exc_tval  = ex_exc_tval_pre;
        if (d_tr_req && (d_tr_fault != 2'd0)) begin
            ex_exc       = 1'b1;
            ex_exc_cause = (d_tr_fault == 2'd2)
                         ? (ex_is_store ? EXC_SPAGE  : EXC_LPAGE)
                         : (ex_is_store ? EXC_SFAULT : EXC_LFAULT);
            ex_exc_tval  = mem_addr;
        end
    end

    //=================================================================
    // the MMU
    //=================================================================
    CORE_MMU #(.PMP_ENTRIES  (PMP_ENTRIES),
               .ITLB_ENTRIES (ITLB_ENTRIES),
               .DTLB_ENTRIES (DTLB_ENTRIES)) u_mmu
        (
            .clk          (clk),
            .rst_n        (rst_n),
            .priv         (priv),
            .satp         (satp),
            .mstatus_sum  (st_sum),
            .mstatus_mxr  (st_mxr),
            .mstatus_mprv (st_mprv),
            .mstatus_mpp  (st_mpp),
            .pmpcfg       (pmpcfg),
            .pmpaddr      (pmpaddr),
            .i_req        (i_tr_req),
            .i_vaddr      (i_tr_vaddr),
            .i_ready      (i_tr_ready),
            .i_paddr      (i_tr_paddr),
            .i_fault      (i_tr_fault),
            .d_req        (d_tr_req),
            .d_vaddr      (mem_addr),
            .d_size       (ex_mem_size),
            .d_is_load    (ex_is_load),
            .d_is_store   (ex_is_store),
            .d_ready      (d_tr_ready),
            .d_paddr      (d_tr_paddr),
            .d_fault      (d_tr_fault),
            .p_paddr      (mr_paddr),
            .p_size       (mr_size),
            .p_is_load    (mr_is_load),
            .p_is_store   (mr_is_store),
            .p_fail       (mr_pmp_fail),
            .sfence_valid (sfence_taken),
            .sfence_vaddr (ma_sfence_vaddr),
            .sfence_asid  (ma_sfence_asid),
            .kill         (flush),
            .lsu_idle     (lsu_idle & ~(mr_valid & mr_mem)),
            .ptw_active   (ptw_active),
            .m_req_valid  (ptw_req_valid),
            .m_req_ready  (ptw_req_ready),
            .m_req_addr   (ptw_req_addr),
            .m_req_paddr  (ptw_req_paddr),
            .m_resp_valid (ptw_resp_valid),
            .m_resp_data  (d_resp_data),
            .m_resp_error (d_resp_error)
        );

    //=================================================================
    // the data cache port : the pipeline or the page table walker
    //
    //   The walker is only granted the port while the load store unit has
    //   nothing in flight, and it keeps it until its read has come back, so
    //   there is never one access of each in the cache at the same time.
    //=================================================================
    assign d_req_valid  = ptw_active ? ptw_req_valid : lsu_d_req_valid;
    assign d_req_addr   = ptw_active ? ptw_req_addr[PADDR_WIDTH-1:0]  : lsu_d_req_addr;
    assign d_req_paddr  = ptw_active ? ptw_req_paddr[PADDR_WIDTH-1:0] : lsu_d_req_paddr;
    assign d_req_size   = ptw_active ? 2'd3  : lsu_d_req_size;   // eight bytes
    assign d_req_cmd    = ptw_active ? 4'd0  : lsu_d_req_cmd;    // a plain load
    assign d_req_wdata  = ptw_active ? 64'd0 : lsu_d_req_wdata;

    assign ptw_req_ready   = ptw_active & d_req_ready;
    assign ptw_resp_valid  = ptw_active & d_resp_valid;
    assign lsu_d_req_ready = ~ptw_active & d_req_ready;
    assign lsu_d_resp_valid= ~ptw_active & d_resp_valid;

    //=================================================================
    // load / store unit
    //=================================================================
    logic lsu_req_valid, lsu_accept;

    CORE_LSU #(.PADDR_WIDTH(PADDR_WIDTH)) u_lsu
        (
            .clk          (clk),
            .rst_n        (rst_n),
            .req_valid    (lsu_req_valid),
            .req_cmd      (mr_cmd),
            .req_addr     (mr_vaddr),
            .req_size     (mr_size),
            .req_signed   (mr_signed),
            .req_paddr    (mr_paddr),
            .req_wdata    (mr_wdata),
            .req_accept   (lsu_accept),
            .resp_valid   (lsu_resp_valid),
            .resp_data    (lsu_resp_data),
            .resp_error   (lsu_resp_error),
            .kill         (1'b0),      // nothing is ever in flight at a trap:
                                       // a memory access moves to MA in the
                                       // cycle it is issued, and the younger
                                       // instructions are killed before EX
            .idle         (lsu_idle),
            .d_req_valid  (lsu_d_req_valid),
            .d_req_ready  (lsu_d_req_ready),
            .d_req_addr   (lsu_d_req_addr),
            .d_req_paddr  (lsu_d_req_paddr),
            .d_req_size   (lsu_d_req_size),
            .d_req_cmd    (lsu_d_req_cmd),
            .d_req_wdata  (lsu_d_req_wdata),
            .d_resp_valid (lsu_d_resp_valid),
            .d_resp_data  (d_resp_data),
            .d_resp_error (d_resp_error)
        );

    //=================================================================
    // MR : the protection check, and the access goes to the cache
    //
    //   The PMP looks at the address the DTLB gave in EX, which MR holds.
    //   It only decides when nothing before it has: a misaligned address
    //   and a fault of the translation were already found in EX.
    //=================================================================
    logic        mr_exc;
    logic [4:0]  mr_exc_cause;
    logic [63:0] mr_exc_tval;

    always @(*) begin
        mr_exc       = mr_exc_r;
        mr_exc_cause = mr_exc_cause_r;
        mr_exc_tval  = mr_exc_tval_r;
        if (!mr_exc_r && (mr_is_load || mr_is_store) && mr_pmp_fail) begin
            mr_exc       = 1'b1;
            mr_exc_cause = mr_is_store ? EXC_SFAULT : EXC_LFAULT;
            mr_exc_tval  = mr_vaddr;
        end
    end

    //=================================================================
    // the commit point (MA) : trap, MRET, CSR write
    //=================================================================
    logic [4:0]  ma_exc_cause;
    logic [63:0] ma_exc_tval;

    // an access fault is reported with the answer of the cache
    always @(*) begin
        ma_exc       = ma_exc_r;
        ma_exc_cause = ma_exc_cause_r;
        ma_exc_tval  = ma_exc_tval_r;
        if (!ma_exc_r && ma_mem && lsu_resp_valid && lsu_resp_error) begin
            ma_exc       = 1'b1;
            ma_exc_cause = ma_is_store ? EXC_SFAULT : EXC_LFAULT;
            ma_exc_tval  = ma_result;         // the address of the access
        end
    end

    assign trap_taken   = ma_valid & ma_exc     & ~stall_ma;
    assign mret_taken   = ma_valid & ma_is_mret & ~stall_ma & ~trap_taken;
    assign sret_taken   = ma_valid & ma_is_sret & ~stall_ma & ~trap_taken;
    // SFENCE.VMA changes the translation the front end has already used, so
    // like fence.i it refetches from the instruction behind it
    assign sfence_taken = ma_valid & ma_is_sfence & ~stall_ma & ~trap_taken;
    // fence.i invalidates the instruction cache and refetches from the next
    // instruction; the cache does not take a request while the invalidate is
    // running, so nothing of the old content can be fetched in between
    assign fencei_taken = ma_valid & ma_is_fencei & ~stall_ma & ~trap_taken;
    // an instruction that the front end took for a taken branch although it
    // is none (see "the front end guessed, EX knows") refetches from the
    // instruction behind it, the way the fences do
    assign refetch_taken = ma_valid & ma_refetch & ~stall_ma & ~trap_taken;
    assign flush        = trap_taken | mret_taken | sret_taken |
                          fencei_taken | sfence_taken | refetch_taken;
    assign commit     = ma_valid & ~stall_ma & ~trap_taken;

    assign trap_en      = trap_taken;
    assign trap_int_c   = ma_exc_int_r;
    assign trap_cause_c = ma_exc_cause;
    assign trap_epc_c   = ma_pc;
    assign trap_tval_c  = ma_exc_tval;
    assign mret_en      = mret_taken;
    assign sret_en      = sret_taken;
    assign csr_wr_en    = ma_valid & ma_csr_wr & ~stall_ma & ~trap_taken;

    //=================================================================
    // pipeline control
    //=================================================================
    // fence.i goes out on the data port as well: it is the flush of the
    // data cache, and MA waits for its answer before the instruction cache
    // is invalidated
    assign ex_mem        = ex_is_load | ex_is_store | ex_is_fencei;
    assign mr_is_mem     = mr_valid & mr_mem & ~mr_exc;
    // a memory access must not be started when the instruction in front of it
    // traps, because the cache cannot take the write back
    assign lsu_req_valid = mr_is_mem & ~stall_ma & ~flush;
    assign stall_ma      = ma_valid & ma_mem & ~lsu_resp_valid;
    assign stall_mr      = stall_ma | (mr_is_mem & ~lsu_accept & ~flush);
    assign mr_advance    = ~stall_mr;
    // the page table is being walked : the address is not there yet
    assign ex_mmu_wait   = d_tr_req & ~d_tr_ready & ~flush;

    // Load-use: an instruction in EX reads a register that a load in MR is
    // about to bring. It waits one cycle, after which the load is in MA and
    // its answer is forwarded the cycle it arrives. Compared on the
    // registers of both stages, so it is short. A load, LR, SC and an AMO
    // all write their register from the cache; a store and fence.i write
    // none.
    logic lu_int, lu_fp;
    assign lu_int = mr_valid & mr_mem & mr_we_rd & (mr_rd != 5'd0) &
                    ((mr_rd == ex_rs1) | (mr_rd == ex_rs2));
    assign lu_fp  = mr_valid & mr_mem & mr_fp_we &
                    ((ex_use_fs1 & (mr_rd == ex_fs1)) |
                     (ex_use_fs2 & (mr_rd == ex_fs2)) |
                     (ex_use_fs3 & (mr_rd == ex_fs3)));
    assign lu_hazard = ex_valid & (lu_int | lu_fp) & ~flush;

    assign stall_ex      = stall_mr | ex_mmu_wait | lu_hazard
                                    | (mdu_active & ~mdu_done & ~flush)
                                    | (fpu_active & ~fpu_done & ~flush);
    assign ex_advance    = ~stall_ex;

    // A CSR access, an MRET and the fences are serialising in both
    // directions: they are only issued into an empty pipeline, and nothing
    // follows them until they have committed.
    //
    //   The first half makes the counters exact. The second half is needed
    //   because the decoder itself reads CSR state: mstatus.FS says whether
    //   the floating point extension is there at all, and frm supplies the
    //   rounding mode of an instruction that asks for the dynamic one. An
    //   instruction decoded one cycle too early would see the old value of
    //   either and be turned into an illegal instruction.
    assign pipe_busy   = ex_valid | mr_valid | ma_valid | wb_valid;
    assign serial_busy = (ex_valid & ex_serial) | (mr_valid & mr_serial) |
                         (ma_valid & ma_serial);
    assign wfi_wait    = fq_valid & dec_is_wfi & ~irq_any;
    assign id_ready    = ~(fq_valid & (dec_is_csr | dec_is_mret | dec_is_sret |
                                       dec_is_sfence | dec_is_fence |
                                       dec_is_fence_i) & pipe_busy)
                       & ~serial_busy & ~wfi_wait;
    assign id_advance  = ex_advance & id_ready;
    assign fq_ready    = id_advance;

    //=================================================================
    // the front end guessed, EX knows
    //
    //   A redirect is only needed when the two disagree, which is the whole
    //   point of the predictor.
    //
    //   A control transfer never goes to the MMU or to a unit that takes
    //   more than one cycle, and its exception is already complete in
    //   ex_exc_pre. What it has to wait for is only that its operands are
    //   there: MA is not waiting for a load, and no load it reads is in MR.
    //   It does not wait for EX to move on, which also depends on whether
    //   the cache takes the access in MR, and that keeps the PMP and the
    //   cache handshake off the path that ends in the whole front end
    //   (LitexSystem/docs/TIMING.md 13 and 15). If EX does stay where it
    //   is, the redirect and the update of the buffer have happened already
    //   and must not happen again: ex_ctrl_done remembers that.
    //
    //   An instruction that is not a control transfer but was predicted
    //   taken is the other kind of disagreement. The buffer is tagged with
    //   the virtual address alone, so it happens when the address space
    //   changes under the same addresses without a fence: a switch of ASID
    //   in satp. That one can be a load waiting for its translation, so it
    //   is not put right from EX: it is marked, and when it commits it
    //   refetches from the instruction behind it the way the fences do.
    //   It costs a cycle more than a redirect from EX, and only in this
    //   case.
    //=================================================================
    logic [63:0] ex_seq_pc;
    logic        ex_is_ctrl;
    assign ex_seq_pc  = ex_pc + (ex_is_rvc ? 64'd2 : 64'd4);
    assign ex_is_ctrl = ex_is_branch | ex_is_jal | ex_is_jalr;

    assign ex_mispredict = ex_valid & ex_is_ctrl & ~ex_exc_pre &
                           ((take_branch != ex_pred_taken) |
                            (take_branch & (target_pc != ex_pred_target)));

    logic ex_ctrl_go, ex_ctrl_done;
    assign ex_ctrl_go = ex_valid & ex_is_ctrl & ~stall_ma & ~lu_hazard &
                        ~ex_ctrl_done & ~flush;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     ex_ctrl_done <= 1'b0;
        else if (flush || ex_advance)   ex_ctrl_done <= 1'b0;
        else if (ex_ctrl_go)            ex_ctrl_done <= 1'b1;
    end

    // the buffer learns from every control transfer that gets through
    assign btb_upd_valid  = ex_ctrl_go & ~ex_exc_pre;
    assign btb_upd_pc     = ex_pc;
    assign btb_upd_is32   = ~ex_is_rvc;
    assign btb_upd_target = target_pc;
    assign btb_upd_taken  = take_branch;
    assign btb_flush      = fencei_taken | sfence_taken;

    // a trap and an MRET come from the commit point and win
    assign redirect_valid = flush | (ex_mispredict & ex_ctrl_go);
    always @(*) begin
        if      (trap_taken)   redirect_pc = trap_vector;
        else if (mret_taken)   redirect_pc = mret_target;
        else if (sret_taken)   redirect_pc = sret_target;
        else if (fencei_taken || sfence_taken || refetch_taken)
                               redirect_pc = ma_pc + (ma_is_rvc ? 64'd2 : 64'd4);
        else                   redirect_pc = take_branch ? target_pc : ex_seq_pc;
    end

    assign i_flush_valid = fencei_busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)              fencei_busy <= 1'b0;
        else if (fencei_taken)   fencei_busy <= 1'b1;
        else if (i_flush_done)   fencei_busy <= 1'b0;
    end

    //=================================================================
    // instructions that the current privilege level may not execute
    //
    //   TSR / TVM / TW let a hypervisor (or M mode) catch the supervisor
    //   doing these; without them the rule is simply the level of the
    //   instruction.
    //=================================================================
    logic priv_bad;

    assign priv_bad =
          (dec_is_mret   & (priv != PRIV_M))
        | (dec_is_sret   & ((priv == PRIV_U) | ((priv == PRIV_S) & st_tsr)))
        | (dec_is_sfence & ((priv == PRIV_U) | ((priv == PRIV_S) & st_tvm)))
        | (dec_is_wfi    & (priv != PRIV_M) & st_tw);

    //=================================================================
    // exceptions found in ID
    //=================================================================
    logic        id_exc, id_exc_int;
    logic [4:0]  id_exc_cause;
    logic [63:0] id_exc_tval;

    always @(*) begin
        id_exc       = 1'b0;
        id_exc_int   = 1'b0;
        id_exc_cause = 5'd0;
        id_exc_tval  = 64'd0;
        if (fq_valid) begin
            // an interrupt is taken instead of the instruction, so it comes
            // before every exception the instruction itself would raise.
            // WFI is the exception: it completes and the interrupt is taken
            // on the instruction behind it, so that mepc points there.
            if (irq_req && !dec_is_wfi) begin
                id_exc       = 1'b1;
                id_exc_int   = 1'b1;
                id_exc_cause = irq_cause;
            end else if (fq_fault != 2'd0) begin
                id_exc       = 1'b1;
                id_exc_cause = (fq_fault == 2'd2) ? EXC_IPAGE : EXC_IFAULT;
                // mepc is the instruction, but mtval is the address that
                // could not be fetched, which is the second half when the
                // instruction lies across a page boundary
                id_exc_tval  = fq_pc + (fq_fault_hi ? 64'd2 : 64'd0);
            end else if (dec_illegal || (fq_is_rvc && decomp_illegal) ||
                         (dec_is_fp & fp_off) ||
                         (dec_is_csr & csr_is_fp & fp_off) ||
                         dec_rm_bad || priv_bad) begin
                id_exc       = 1'b1;
                id_exc_cause = EXC_ILLEGAL;
                id_exc_tval  = fq_is_rvc ? {48'd0, fq_insn[15:0]} : {32'd0, fq_insn};
            end else if (dec_is_ecall) begin
                id_exc       = 1'b1;
                id_exc_cause = EXC_ECALL_U + {3'd0, priv};
            end else if (dec_is_ebreak) begin
                id_exc       = 1'b1;
                id_exc_cause = EXC_BREAK;
                id_exc_tval  = fq_pc;
            end
        end
    end

    //=================================================================
    // forwarding selects
    //
    //   Which instruction EX, MR, MA and WB will hold in the next cycle is
    //   decided by the same signals that load the pipeline registers
    //   below, so the comparisons of register numbers can be made now on
    //   what they are about to hold, and only their answers stored. The
    //   rules here are those of the registers below, case for case; a
    //   change to either has to be made to both.
    //
    //   MR : a trap or an xRET empties it, an advancing EX fills it, and
    //        otherwise it either keeps what it has (stalled) or becomes a
    //        bubble. Its write is cancelled by an exception in EX. It only
    //        forwards what EX computed, never the answer of a load.
    //   MA : the same with MR in front of it; its write is cancelled by an
    //        exception in MR (the PMP).
    //   WB : gets what MA has unless MA is stalled; a trap in MA stops it.
    //   EX : the source registers of the instruction ID hands over, or of
    //        the one EX keeps. A kept instruction has already taken the
    //        forwarded value into ex_rs1_data, and the source that gave it
    //        either stays where it is or moves one stage on, where it has
    //        the same value; so looking it up again gives the same answer.
    //        The one exception is the load in MR that EX waits for: it is
    //        not forwarded from MR, and one cycle later it is in MA.
    //=================================================================
    logic [4:0] nx_rs1, nx_rs2, nx_mr_rd, nx_ma_rd;
    logic       nx_mr_wr, nx_ma_wr, nx_wb_wr;

    assign nx_rs1   = ex_advance ? (dec_use_rs1 ? dec_rs1 : 5'd0) : ex_rs1;
    assign nx_rs2   = ex_advance ? (dec_use_rs2 ? dec_rs2 : 5'd0) : ex_rs2;
    assign nx_mr_rd = ex_advance ? ex_rd : mr_rd;
    assign nx_ma_rd = mr_advance ? mr_rd : ma_rd;

    always @(*) begin
        if      (flush)      nx_mr_wr = 1'b0;
        else if (ex_advance) nx_mr_wr = ex_valid & ex_we_rd & ~ex_exc & ~ex_mem;
        else if (mr_advance) nx_mr_wr = 1'b0;
        else                 nx_mr_wr = mr_valid & mr_we_rd & ~mr_mem;
        nx_mr_wr = nx_mr_wr & (nx_mr_rd != 5'd0);

        if      (flush)      nx_ma_wr = 1'b0;
        else if (mr_advance) nx_ma_wr = mr_valid & mr_we_rd & ~mr_exc;
        else if (!stall_ma)  nx_ma_wr = 1'b0;
        else                 nx_ma_wr = ma_valid & ma_we_rd;
        nx_ma_wr = nx_ma_wr & (nx_ma_rd != 5'd0);
    end

    assign nx_wb_wr = ~stall_ma & ma_valid & ~trap_taken & ma_we_rd &
                      (ma_rd != 5'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fwd_a_mr <= 1'b0;
            fwd_a_ma <= 1'b0;
            fwd_a_wb <= 1'b0;
            fwd_b_mr <= 1'b0;
            fwd_b_ma <= 1'b0;
            fwd_b_wb <= 1'b0;
        end else begin
            fwd_a_mr <= nx_mr_wr & (nx_mr_rd == nx_rs1);
            fwd_a_ma <= nx_ma_wr & (nx_ma_rd == nx_rs1);
            fwd_a_wb <= nx_wb_wr & (ma_rd    == nx_rs1);
            fwd_b_mr <= nx_mr_wr & (nx_mr_rd == nx_rs2);
            fwd_b_ma <= nx_ma_wr & (nx_ma_rd == nx_rs2);
            fwd_b_wb <= nx_wb_wr & (ma_rd    == nx_rs2);
        end
    end

    //=================================================================
    // pipeline registers
    //=================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid      <= 1'b0;
            ex_pc         <= 64'd0;
            ex_insn       <= 32'd0;
            ex_rs1_data   <= 64'd0;
            ex_rs2_data   <= 64'd0;
            ex_imm        <= 64'd0;
            ex_rs1        <= 5'd0;
            ex_rs2        <= 5'd0;
            ex_rd         <= 5'd0;
            ex_we_rd      <= 1'b0;
            ex_alu_op     <= 4'd0;
            ex_a_sel      <= 2'd0;
            ex_b_sel      <= 1'b0;
            ex_word_op    <= 1'b0;
            ex_br_op      <= 3'd0;
            ex_is_branch  <= 1'b0;
            ex_is_jal     <= 1'b0;
            ex_is_jalr    <= 1'b0;
            ex_is_rvc     <= 1'b0;
            ex_is_mdu     <= 1'b0;
            ex_mdu_op     <= 3'd0;
            ex_is_load    <= 1'b0;
            ex_is_store   <= 1'b0;
            ex_mem_cmd    <= 4'd0;
            ex_mem_size   <= 2'd0;
            ex_mem_signed <= 1'b0;
            ex_is_fp        <= 1'b0;
            ex_fp_arith     <= 1'b0;
            ex_fp_op        <= 5'd0;
            ex_fp_fmt       <= 1'b0;
            ex_fp_rm        <= 3'd0;
            ex_use_fs1      <= 1'b0;
            ex_use_fs2      <= 1'b0;
            ex_use_fs3      <= 1'b0;
            ex_fp_we_rd     <= 1'b0;
            ex_fp_int_signed<= 1'b0;
            ex_fp_int_w     <= 1'b0;
            ex_is_fp_store  <= 1'b0;
            ex_fp_box       <= 1'b0;
            ex_fs1 <= 5'd0; ex_fs2 <= 5'd0; ex_fs3 <= 5'd0;
            ex_fs1_data <= 64'd0; ex_fs2_data <= 64'd0; ex_fs3_data <= 64'd0;
            ex_is_csr     <= 1'b0;
            ex_csr_addr   <= 12'd0;
            ex_csr_op     <= 2'd0;
            ex_csr_imm_sel<= 1'b0;
            ex_csr_uimm   <= 5'd0;
            ex_csr_wr     <= 1'b0;
            ex_pred_taken <= 1'b0;
            ex_pred_target<= 64'd0;
            ex_is_mret    <= 1'b0;
            ex_is_sret    <= 1'b0;
            ex_is_sfence  <= 1'b0;
            ex_is_fencei  <= 1'b0;
            ex_serial     <= 1'b0;
            ex_exc_r      <= 1'b0;
            ex_exc_int_r  <= 1'b0;
            ex_exc_cause_r<= 5'd0;
            ex_exc_tval_r <= 64'd0;

            mr_valid      <= 1'b0;
            mr_we_rd      <= 1'b0;
            mr_mem        <= 1'b0;
            mr_is_load    <= 1'b0;
            mr_is_store   <= 1'b0;
            mr_pc         <= 64'd0;
            mr_insn       <= 32'd0;
            mr_result     <= 64'd0;
            mr_rd         <= 5'd0;
            mr_is_mret    <= 1'b0;
            mr_is_sret    <= 1'b0;
            mr_is_sfence  <= 1'b0;
            mr_is_fencei  <= 1'b0;
            mr_refetch    <= 1'b0;
            mr_sfence_vaddr <= 64'd0;
            mr_sfence_asid  <= 64'd0;
            mr_serial     <= 1'b0;
            mr_is_rvc     <= 1'b0;
            mr_csr_wr     <= 1'b0;
            mr_csr_addr   <= 12'd0;
            mr_csr_wdata  <= 64'd0;
            mr_is_fp      <= 1'b0;
            mr_fp_arith   <= 1'b0;
            mr_fp_we      <= 1'b0;
            mr_fp_box     <= 1'b0;
            mr_fp_flags   <= 5'd0;
            mr_exc_r      <= 1'b0;
            mr_exc_int_r  <= 1'b0;
            mr_exc_cause_r<= 5'd0;
            mr_exc_tval_r <= 64'd0;
            mr_cmd        <= 4'd0;
            mr_vaddr      <= 64'd0;
            mr_paddr      <= 64'd0;
            mr_wdata      <= 64'd0;
            mr_size       <= 2'd0;
            mr_signed     <= 1'b0;

            ma_valid      <= 1'b0;
            ma_we_rd      <= 1'b0;
            ma_mem        <= 1'b0;
            ma_is_load    <= 1'b0;
            ma_is_store   <= 1'b0;
            ma_pc         <= 64'd0;
            ma_insn       <= 32'd0;
            ma_result     <= 64'd0;
            ma_rd         <= 5'd0;
            ma_is_mret    <= 1'b0;
            ma_is_sret    <= 1'b0;
            ma_is_sfence  <= 1'b0;
            ma_is_fencei  <= 1'b0;
            ma_refetch    <= 1'b0;
            ma_sfence_vaddr <= 64'd0;
            ma_sfence_asid  <= 64'd0;
            ma_serial     <= 1'b0;
            ma_is_rvc     <= 1'b0;
            ma_csr_wr     <= 1'b0;
            ma_csr_addr   <= 12'd0;
            ma_csr_wdata  <= 64'd0;
            ma_is_fp      <= 1'b0;
            ma_fp_arith   <= 1'b0;
            ma_fp_we      <= 1'b0;
            ma_fp_box     <= 1'b0;
            ma_fp_rd      <= 5'd0;
            ma_fp_flags   <= 5'd0;
            ma_exc_r      <= 1'b0;
            ma_exc_int_r  <= 1'b0;
            ma_exc_cause_r<= 5'd0;
            ma_exc_tval_r <= 64'd0;

            wb_valid      <= 1'b0;
            wb_we_rd      <= 1'b0;
            wb_rd         <= 5'd0;
            wb_data       <= 64'd0;
            wb_pc         <= 64'd0;
            wb_insn       <= 32'd0;
            wb_fp_we      <= 1'b0;
            wb_fp_rd      <= 5'd0;
            wb_fp_data    <= 64'd0;
        end else begin
            //---------------------------------------------------------
            // ID -> EX
            //---------------------------------------------------------
            if (ex_advance) begin
                ex_valid      <= id_advance & fq_valid & ~redirect_valid;
                ex_pc         <= fq_pc;
                ex_insn       <= fq_insn;
                ex_rs1_data   <= rf_rs1_data;
                ex_rs2_data   <= rf_rs2_data;
                ex_imm        <= dec_imm;
                ex_rs1        <= dec_use_rs1 ? dec_rs1 : 5'd0;
                ex_csr_uimm   <= dec_rs1;
                ex_rs2        <= dec_use_rs2 ? dec_rs2 : 5'd0;
                ex_rd         <= dec_rd;
                ex_we_rd      <= dec_we_rd;
                ex_alu_op     <= dec_alu_op;
                ex_a_sel      <= dec_a_sel;
                ex_b_sel      <= dec_b_sel;
                ex_word_op    <= dec_word_op;
                ex_br_op      <= dec_br_op;
                ex_is_branch  <= dec_is_branch;
                ex_is_jal     <= dec_is_jal;
                ex_is_jalr    <= dec_is_jalr;
                ex_is_rvc     <= fq_is_rvc;
                ex_is_mdu     <= dec_is_mdu;
                ex_mdu_op     <= dec_mdu_op;
                ex_is_load    <= dec_is_load;
                ex_is_store   <= dec_is_store;
                ex_mem_cmd    <= dec_mem_cmd;
                ex_mem_size   <= dec_mem_size;
                ex_mem_signed <= dec_mem_signed;
                ex_is_fp        <= dec_is_fp;
                ex_fp_arith     <= dec_fp_arith;
                ex_fp_op        <= dec_fp_op;
                ex_fp_fmt       <= dec_fp_fmt;
                ex_fp_rm        <= dec_fp_rm;
                ex_use_fs1      <= dec_use_fs1;
                ex_use_fs2      <= dec_use_fs2;
                ex_use_fs3      <= dec_use_fs3;
                ex_fp_we_rd     <= dec_fp_we_rd;
                ex_fp_int_signed<= dec_fp_int_signed;
                ex_fp_int_w     <= dec_fp_int_w;
                ex_is_fp_store  <= dec_is_fp_store;
                ex_fp_box       <= dec_is_fp_load & ~dec_fp_fmt;
                ex_fs1          <= dec_use_fs1 ? dec_rs1 : 5'd0;
                ex_fs2          <= dec_use_fs2 ? dec_rs2 : 5'd0;
                ex_fs3          <= dec_use_fs3 ? fq_insn[31:27] : 5'd0;
                ex_fs1_data     <= frf_fs1_data;
                ex_fs2_data     <= frf_fs2_data;
                ex_fs3_data     <= frf_fs3_data;
                ex_is_csr     <= dec_is_csr;
                ex_csr_addr   <= dec_csr_addr;
                ex_csr_op     <= dec_csr_op;
                ex_csr_imm_sel<= dec_csr_imm_sel;
                ex_csr_wr     <= dec_csr_wr;
                ex_pred_taken <= fq_pred_taken;
                ex_pred_target<= fq_pred_target;
                ex_is_mret    <= dec_is_mret;
                ex_is_sret    <= dec_is_sret;
                ex_is_sfence  <= dec_is_sfence;
                ex_is_fencei  <= dec_is_fence_i;
                ex_serial     <= dec_is_csr | dec_is_mret | dec_is_sret |
                                 dec_is_sfence;
                ex_exc_r      <= id_exc;
                ex_exc_int_r  <= id_exc_int;
                ex_exc_cause_r<= id_exc_cause;
                ex_exc_tval_r <= id_exc_tval;
            end else begin
                ex_fs1_data <= ex_fs1_fwd;
                ex_fs2_data <= ex_fs2_fwd;
                ex_fs3_data <= ex_fs3_fwd;
                // EX is stalled : keep the operands it has been given. The
                // forwarding sources move on (MR and MA hand their
                // instructions over, WB becomes a bubble) while the
                // instruction stays here, so the value has to be captured
                // instead of being looked up again every cycle.
                ex_rs1_data <= ex_a_fwd;
                ex_rs2_data <= ex_b_fwd;
            end

            //---------------------------------------------------------
            // EX -> MR
            //---------------------------------------------------------
            if (ex_advance) begin
                mr_valid      <= ex_valid;
                mr_pc         <= ex_pc;
                mr_insn       <= ex_insn;
                mr_rd         <= ex_rd;
                mr_we_rd      <= ex_we_rd & ~ex_exc;
                mr_mem        <= ex_mem;
                mr_is_load    <= ex_is_load;
                mr_is_store   <= ex_is_store;
                mr_is_mret    <= ex_is_mret;
                mr_is_sret    <= ex_is_sret;
                mr_is_sfence  <= ex_is_sfence;
                mr_is_fencei  <= ex_is_fencei;
                mr_refetch    <= ex_pred_taken & ~ex_is_ctrl;
                // SFENCE.VMA rs2, rs1 : rs1 selects the address and rs2 the
                // ASID, a zero register meaning "every one of them"
                mr_sfence_vaddr <= (ex_rs1 == 5'd0) ? 64'd0 : ex_a_fwd;
                mr_sfence_asid  <= (ex_rs2 == 5'd0) ? 64'd0 : ex_b_fwd;
                mr_serial     <= ex_serial;
                mr_is_rvc     <= ex_is_rvc;
                mr_is_fp      <= ex_is_fp;
                mr_fp_arith   <= ex_fp_arith & ~ex_exc;
                mr_fp_we      <= ex_fp_we_rd & ~ex_exc;
                mr_fp_box     <= ex_fp_box;
                mr_fp_flags   <= fpu_flags;
                mr_csr_wr     <= ex_is_csr & ex_csr_wr & ~ex_exc;
                mr_csr_addr   <= ex_csr_addr;
                mr_csr_wdata  <= csr_wval;
                mr_exc_r      <= ex_exc;
                mr_exc_int_r  <= ex_exc_int;
                mr_exc_cause_r<= ex_exc_cause;
                mr_exc_tval_r <= ex_exc_tval;
                // the access
                mr_cmd        <= ex_mem_cmd;
                mr_vaddr      <= mem_addr;
                mr_paddr      <= d_tr_paddr;
                mr_size       <= ex_mem_size;
                mr_signed     <= ex_mem_signed;
                mr_wdata      <= ex_is_fp_store ? ex_fs2_fwd : ex_b_fwd;
                if      (ex_is_csr)                mr_result <= csr_rdata;
                else if (ex_fp_arith)              mr_result <= fpu_result;
                else if (ex_is_mdu)                mr_result <= mdu_result;
                else if (ex_is_jal || ex_is_jalr)  mr_result <= link_pc;
                else                               mr_result <= alu_result;
            end else if (mr_advance) begin
                // MR handed its instruction over but EX has nothing to give
                // (a unit is still working, or EX waits for a load) : bubble
                mr_valid   <= 1'b0;
                mr_we_rd   <= 1'b0;
                mr_mem     <= 1'b0;
                mr_is_load <= 1'b0;
                mr_is_store<= 1'b0;
                mr_is_mret <= 1'b0;
                mr_is_sret <= 1'b0;
                mr_is_sfence <= 1'b0;
                mr_is_fencei <= 1'b0;
                mr_refetch   <= 1'b0;
                mr_serial  <= 1'b0;
                mr_csr_wr  <= 1'b0;
                mr_exc_r   <= 1'b0;
                mr_is_fp   <= 1'b0;
                mr_fp_arith<= 1'b0;
                mr_fp_we   <= 1'b0;
            end

            //---------------------------------------------------------
            // MR -> MA
            //---------------------------------------------------------
            if (mr_advance) begin
                ma_valid      <= mr_valid;
                ma_pc         <= mr_pc;
                ma_insn       <= mr_insn;
                ma_rd         <= mr_rd;
                ma_we_rd      <= mr_we_rd & ~mr_exc;
                ma_mem        <= mr_is_mem;
                ma_is_load    <= mr_is_load;
                ma_is_store   <= mr_is_store;
                ma_is_mret    <= mr_is_mret;
                ma_is_sret    <= mr_is_sret;
                ma_is_sfence  <= mr_is_sfence;
                ma_is_fencei  <= mr_is_fencei;
                ma_refetch    <= mr_refetch;
                ma_sfence_vaddr <= mr_sfence_vaddr;
                ma_sfence_asid  <= mr_sfence_asid;
                ma_serial     <= mr_serial;
                ma_is_rvc     <= mr_is_rvc;
                ma_is_fp      <= mr_is_fp;
                ma_fp_arith   <= mr_fp_arith & ~mr_exc;
                ma_fp_we      <= mr_fp_we & ~mr_exc;
                ma_fp_rd      <= mr_rd;
                ma_fp_box     <= mr_fp_box;
                ma_fp_flags   <= mr_fp_flags;
                ma_csr_wr     <= mr_csr_wr & ~mr_exc;
                ma_csr_addr   <= mr_csr_addr;
                ma_csr_wdata  <= mr_csr_wdata;
                ma_exc_r      <= mr_exc;
                ma_exc_int_r  <= mr_exc_int_r;
                ma_exc_cause_r<= mr_exc_cause;
                ma_exc_tval_r <= mr_exc_tval;
                ma_result     <= mr_result;
            end else if (!stall_ma) begin
                // MA handed its instruction over but MR has nothing to give
                // (the cache did not take the next access yet) : bubble
                ma_valid   <= 1'b0;
                ma_we_rd   <= 1'b0;
                ma_mem     <= 1'b0;
                ma_is_load <= 1'b0;
                ma_is_mret <= 1'b0;
                ma_is_sret <= 1'b0;
                ma_is_sfence <= 1'b0;
                ma_is_fencei <= 1'b0;
                ma_refetch   <= 1'b0;
                ma_serial  <= 1'b0;
                ma_csr_wr  <= 1'b0;
                ma_exc_r   <= 1'b0;
                ma_is_fp   <= 1'b0;
                ma_fp_arith<= 1'b0;
                ma_fp_we   <= 1'b0;
            end

            //---------------------------------------------------------
            // MA -> WB
            //---------------------------------------------------------
            if (!stall_ma) begin
                wb_valid <= ma_valid & ~trap_taken;
                wb_pc    <= ma_pc;
                wb_insn  <= ma_insn;
                wb_rd    <= ma_rd;
                wb_we_rd <= ma_we_rd;
                wb_fp_we <= ma_fp_we & ~trap_taken;
                wb_fp_rd <= ma_fp_rd;
                if (ma_mem && ma_is_load) begin
                    wb_data    <= ma_load_data;
                    wb_fp_data <= ma_load_data;
                end else begin
                    wb_data    <= ma_result;
                    wb_fp_data <= ma_result;
                end
            end else begin
                wb_valid <= 1'b0;       // MA keeps its instruction : bubble
                wb_we_rd <= 1'b0;
                wb_fp_we <= 1'b0;
            end

            //---------------------------------------------------------
            // a trap or an MRET empties EX, MR and MA
            //---------------------------------------------------------
            if (flush) begin
                ex_valid   <= 1'b0;
                ex_exc_r   <= 1'b0;
                ex_serial  <= 1'b0;
                ex_pred_taken <= 1'b0;
                mr_valid   <= 1'b0;
                mr_we_rd   <= 1'b0;
                mr_mem     <= 1'b0;
                mr_is_mret <= 1'b0;
                mr_is_sret <= 1'b0;
                mr_is_sfence <= 1'b0;
                mr_is_fencei <= 1'b0;
                mr_refetch   <= 1'b0;
                mr_serial  <= 1'b0;
                mr_csr_wr  <= 1'b0;
                mr_exc_r   <= 1'b0;
                mr_is_fp   <= 1'b0;
                mr_fp_arith<= 1'b0;
                mr_fp_we   <= 1'b0;
                ma_valid   <= 1'b0;
                ma_we_rd   <= 1'b0;
                ma_mem     <= 1'b0;
                ma_is_mret <= 1'b0;
                ma_is_sret <= 1'b0;
                ma_is_sfence <= 1'b0;
                ma_is_fencei <= 1'b0;
                ma_refetch   <= 1'b0;
                ma_serial  <= 1'b0;
                ma_csr_wr  <= 1'b0;
                ma_exc_r   <= 1'b0;
                ma_is_fp   <= 1'b0;
                ma_fp_arith<= 1'b0;
                ma_fp_we   <= 1'b0;
            end
        end
    end

    //=================================================================
    // trace
    //=================================================================
    always @(*) begin
        trace_valid   = wb_valid;
        trace_pc      = wb_pc;
        trace_insn    = wb_insn;
        trace_rd_we   = wb_we_rd & (wb_rd != 5'd0);
        trace_rd      = wb_rd;
        trace_rd_data = wb_data;
        trace_priv    = priv;

        trap_valid    = trap_taken;
        trap_is_int   = ma_exc_int_r;
        trap_cause    = ma_exc_cause;
        trap_epc      = ma_pc;
        trap_tval     = ma_exc_tval;
    end

endmodule : CPU_CORE
