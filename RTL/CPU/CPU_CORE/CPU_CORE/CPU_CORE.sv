//---------------------------------------------------------------------------
// CPU_CORE.sv
//
// mmRISC-2 CPU core (RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md).
//
//   IF1 / IF2 : CORE_IFU, instruction cache and fetch queue
//   ID        : CORE_DEC and the register file
//   EX        : CORE_EXU (ALU, branch, address), the data cache request,
//               the CSR read
//   MA        : waits for the data cache answer. This is the commit point:
//               a trap, an MRET and a CSR write happen here
//   WB        : register write back and trace
//
//   M5 : RV64IMAFDC + Zicsr + machine, supervisor and user mode with
//   delegation. The privilege level lives in CORE_CSR; the pipeline reads it
//   to decide which instructions are legal and which ECALL cause to raise.
//
//   Why the commit point is MA and not WB: a store hands its data to the
//   cache in EX, so the trap of the instruction in front of it has to be
//   decided while the store is still in EX. With the trap taken in MA the
//   store is one stage behind the trapping instruction and is held back by
//   `trap_taken`.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_CORE
    #(
        parameter int          PADDR_WIDTH  = 40,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000,
        parameter logic [63:0] HART_ID      = 64'd0,
        parameter int          PQ_DEPTH     = 16,     // parcels in the fetch queue
        parameter int          PMP_ENTRIES  = 16      // 0 removes PMP
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
    logic        fq_valid, fq_ready, fq_error, fq_is_rvc;
    logic [63:0] fq_pc;
    logic [31:0] fq_insn;          // raw, 16 bit in the low half when compressed

    logic        redirect_valid;
    logic [63:0] redirect_pc;

    CORE_IFU
        #(.PADDR_WIDTH(PADDR_WIDTH), .RESET_VECTOR(RESET_VECTOR), .PQ_DEPTH(PQ_DEPTH))
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
            .fq_valid       (fq_valid),
            .fq_ready       (fq_ready),
            .fq_pc          (fq_pc),
            .fq_insn        (fq_insn),
            .fq_is_rvc      (fq_is_rvc),
            .fq_error       (fq_error)
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
    logic ex_is_mem, stall_ma, stall_ex, ex_advance;
    logic id_ready, id_advance, pipe_busy, serial_busy, wfi_wait, flush;
    logic ma_exc, trap_taken, mret_taken, sret_taken, fencei_taken, fencei_busy;
    logic sfence_taken, commit;

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
    logic        ex_exc_r;                 // exception seen in ID
    logic        ex_exc_int_r;
    logic [4:0]  ex_exc_cause_r;
    logic [63:0] ex_exc_tval_r;

    //=================================================================
    // MA stage registers
    //=================================================================
    logic        ma_valid, ma_we_rd, ma_mem, ma_is_load, ma_is_store;
    logic [63:0] ma_pc, ma_result;
    logic [31:0] ma_insn;
    logic [4:0]  ma_rd;
    logic        ma_is_mret, ma_is_sret, ma_is_sfence, ma_is_fencei;
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

    always @(*) begin
        ex_a_fwd = ex_rs1_data;
        if      (ma_valid && ma_we_rd && (ma_rd != 5'd0) && (ma_rd == ex_rs1)) ex_a_fwd = ma_fwd_data;
        else if (wb_valid && wb_we_rd && (wb_rd != 5'd0) && (wb_rd == ex_rs1)) ex_a_fwd = wb_data;

        ex_b_fwd = ex_rs2_data;
        if      (ma_valid && ma_we_rd && (ma_rd != 5'd0) && (ma_rd == ex_rs2)) ex_b_fwd = ma_fwd_data;
        else if (wb_valid && wb_we_rd && (wb_rd != 5'd0) && (wb_rd == ex_rs2)) ex_b_fwd = wb_data;
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

    always @(*) begin
        ex_fs1_fwd = ex_fs1_data;
        if      (ex_use_fs1 && ma_valid && ma_fp_we && (ma_fp_rd == ex_fs1)) ex_fs1_fwd = ma_fp_fwd_data;
        else if (ex_use_fs1 && wb_valid && wb_fp_we && (wb_fp_rd == ex_fs1)) ex_fs1_fwd = wb_fp_data;

        ex_fs2_fwd = ex_fs2_data;
        if      (ex_use_fs2 && ma_valid && ma_fp_we && (ma_fp_rd == ex_fs2)) ex_fs2_fwd = ma_fp_fwd_data;
        else if (ex_use_fs2 && wb_valid && wb_fp_we && (wb_fp_rd == ex_fs2)) ex_fs2_fwd = wb_fp_data;

        ex_fs3_fwd = ex_fs3_data;
        if      (ex_use_fs3 && ma_valid && ma_fp_we && (ma_fp_rd == ex_fs3)) ex_fs3_fwd = ma_fp_fwd_data;
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

    assign mdu_active = ex_valid & ex_is_mdu & ~ex_exc;
    // Not while MA is waiting for the cache: the operand of this instruction
    // may be the answer that has not arrived yet, and a unit that runs for
    // several cycles latches what it is given at the start.
    assign mdu_start  = mdu_active & ~mdu_busy & ~mdu_done & ~flush & ~stall_ma;
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

    assign fpu_active = ex_valid & ex_fp_arith & ~ex_exc;
    assign fpu_start  = fpu_active & ~fpu_busy & ~fpu_done & ~flush & ~stall_ma;
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
    logic       ex_exc, ex_exc_int;
    logic [4:0] ex_exc_cause;
    logic [63:0] ex_exc_tval;

    always @(*) begin
        case (ex_mem_size)
            2'd1:    misaligned = mem_addr[0];
            2'd2:    misaligned = |mem_addr[1:0];
            2'd3:    misaligned = |mem_addr[2:0];
            default: misaligned = 1'b0;
        endcase
    end

    always @(*) begin
        ex_exc       = ex_exc_r;
        ex_exc_int   = ex_exc_int_r;
        ex_exc_cause = ex_exc_cause_r;
        ex_exc_tval  = ex_exc_tval_r;
        if (!ex_exc_r) begin
            if (ex_is_csr && (!csr_exists || csr_denied ||
                              (ex_csr_wr && csr_readonly))) begin
                ex_exc       = 1'b1;
                ex_exc_cause = EXC_ILLEGAL;
                ex_exc_tval  = ex_is_rvc ? {48'd0, ex_insn[15:0]} : {32'd0, ex_insn};
            end else if (take_branch && target_pc[0]) begin
                ex_exc       = 1'b1;
                ex_exc_cause = EXC_IADDR;
                ex_exc_tval  = target_pc;
            end else if ((ex_is_load || ex_is_store) && misaligned) begin
                ex_exc       = 1'b1;
                ex_exc_cause = ex_is_store ? EXC_SADDR : EXC_LADDR;
                ex_exc_tval  = mem_addr;
            end
        end
    end

    //=================================================================
    // load / store unit
    //=================================================================
    logic lsu_req_valid, lsu_accept;

    CORE_LSU #(.PADDR_WIDTH(PADDR_WIDTH)) u_lsu
        (
            .clk          (clk),
            .rst_n        (rst_n),
            .req_valid    (lsu_req_valid),
            .req_cmd      (ex_mem_cmd),
            .req_addr     (mem_addr),
            .req_size     (ex_mem_size),
            .req_signed   (ex_mem_signed),
            .req_wdata    (ex_is_fp_store ? ex_fs2_fwd : ex_b_fwd),
            .req_accept   (lsu_accept),
            .resp_valid   (lsu_resp_valid),
            .resp_data    (lsu_resp_data),
            .resp_error   (lsu_resp_error),
            .kill         (1'b0),      // nothing is ever in flight at a trap:
                                       // a memory access moves to MA in the
                                       // cycle it is issued, and the younger
                                       // instructions are killed before EX
            .d_req_valid  (d_req_valid),
            .d_req_ready  (d_req_ready),
            .d_req_addr   (d_req_addr),
            .d_req_paddr  (d_req_paddr),
            .d_req_size   (d_req_size),
            .d_req_cmd    (d_req_cmd),
            .d_req_wdata  (d_req_wdata),
            .d_resp_valid (d_resp_valid),
            .d_resp_data  (d_resp_data),
            .d_resp_error (d_resp_error)
        );

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
    assign flush        = trap_taken | mret_taken | sret_taken |
                          fencei_taken | sfence_taken;
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
    assign ex_is_mem     = ex_valid & (ex_is_load | ex_is_store) & ~ex_exc;
    // a memory access must not be started when the instruction in front of it
    // traps, because the cache cannot take the write back
    assign lsu_req_valid = ex_is_mem & ~stall_ma & ~flush;
    assign stall_ma      = ma_valid & ma_mem & ~lsu_resp_valid;
    assign stall_ex      = stall_ma | (ex_is_mem & ~lsu_accept & ~flush)
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
    assign pipe_busy   = ex_valid | ma_valid | wb_valid;
    assign serial_busy = (ex_valid & ex_serial) | (ma_valid & ma_serial);
    assign wfi_wait    = fq_valid & dec_is_wfi & ~irq_any;
    assign id_ready    = ~(fq_valid & (dec_is_csr | dec_is_mret | dec_is_sret |
                                       dec_is_sfence | dec_is_fence |
                                       dec_is_fence_i) & pipe_busy)
                       & ~serial_busy & ~wfi_wait;
    assign id_advance  = ex_advance & id_ready;
    assign fq_ready    = id_advance;

    // a branch or jump in EX redirects the front end; a trap and an MRET come
    // from the commit point and win
    assign redirect_valid = flush |
                            (ex_valid & take_branch & ex_advance & ~ex_exc);
    always @(*) begin
        if      (trap_taken)   redirect_pc = trap_vector;
        else if (mret_taken)   redirect_pc = mret_target;
        else if (sret_taken)   redirect_pc = sret_target;
        else if (fencei_taken || sfence_taken)
                               redirect_pc = ma_pc + (ma_is_rvc ? 64'd2 : 64'd4);
        else                   redirect_pc = target_pc;
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
            end else if (fq_error) begin
                id_exc       = 1'b1;
                id_exc_cause = EXC_IFAULT;
                id_exc_tval  = fq_pc;
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
            ex_is_mret    <= 1'b0;
            ex_is_sret    <= 1'b0;
            ex_is_sfence  <= 1'b0;
            ex_is_fencei  <= 1'b0;
            ex_serial     <= 1'b0;
            ex_exc_r      <= 1'b0;
            ex_exc_int_r  <= 1'b0;
            ex_exc_cause_r<= 5'd0;
            ex_exc_tval_r <= 64'd0;

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
                // forwarding sources move on (MA hands its instruction over,
                // WB becomes a bubble) while the instruction stays here, so
                // the value has to be captured instead of being looked up
                // again every cycle.
                ex_rs1_data <= ex_a_fwd;
                ex_rs2_data <= ex_b_fwd;
            end

            //---------------------------------------------------------
            // EX -> MA
            //---------------------------------------------------------
            if (ex_advance) begin
                ma_valid      <= ex_valid;
                ma_pc         <= ex_pc;
                ma_insn       <= ex_insn;
                ma_rd         <= ex_rd;
                ma_we_rd      <= ex_we_rd & ~ex_exc;
                ma_mem        <= ex_is_mem;
                ma_is_load    <= ex_is_load;
                ma_is_store   <= ex_is_store;
                ma_is_mret    <= ex_is_mret;
                ma_is_sret    <= ex_is_sret;
                ma_is_sfence  <= ex_is_sfence;
                ma_is_fencei  <= ex_is_fencei;
                // SFENCE.VMA rs2, rs1 : rs1 selects the address and rs2 the
                // ASID, a zero register meaning "every one of them"
                ma_sfence_vaddr <= (ex_rs1 == 5'd0) ? 64'd0 : ex_a_fwd;
                ma_sfence_asid  <= (ex_rs2 == 5'd0) ? 64'd0 : ex_b_fwd;
                ma_serial     <= ex_serial;
                ma_is_rvc     <= ex_is_rvc;
                ma_is_fp      <= ex_is_fp;
                ma_fp_arith   <= ex_fp_arith & ~ex_exc;
                ma_fp_we      <= ex_fp_we_rd & ~ex_exc;
                ma_fp_rd      <= ex_rd;
                ma_fp_box     <= ex_fp_box;
                ma_fp_flags   <= fpu_flags;
                ma_csr_wr     <= ex_is_csr & ex_csr_wr & ~ex_exc;
                ma_csr_addr   <= ex_csr_addr;
                ma_csr_wdata  <= csr_wval;
                ma_exc_r      <= ex_exc;
                ma_exc_int_r  <= ex_exc_int;
                ma_exc_cause_r<= ex_exc_cause;
                ma_exc_tval_r <= ex_exc_tval;
                if      (ex_is_csr)                ma_result <= csr_rdata;
                else if (ex_fp_arith)              ma_result <= fpu_result;
                else if (ex_is_mdu)                ma_result <= mdu_result;
                else if (ex_is_jal || ex_is_jalr)  ma_result <= link_pc;
                else                               ma_result <= alu_result;
            end else if (!stall_ma) begin
                // MA handed its instruction over but EX has nothing to give
                // (the cache did not take the next access yet) : bubble
                ma_valid   <= 1'b0;
                ma_we_rd   <= 1'b0;
                ma_mem     <= 1'b0;
                ma_is_load <= 1'b0;
                ma_is_mret <= 1'b0;
                ma_is_sret <= 1'b0;
                ma_is_sfence <= 1'b0;
                ma_is_fencei <= 1'b0;
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
            // a trap or an MRET empties EX and MA
            //---------------------------------------------------------
            if (flush) begin
                ex_valid   <= 1'b0;
                ex_exc_r   <= 1'b0;
                ex_serial  <= 1'b0;
                ma_valid   <= 1'b0;
                ma_we_rd   <= 1'b0;
                ma_mem     <= 1'b0;
                ma_is_mret <= 1'b0;
                ma_is_sret <= 1'b0;
                ma_is_sfence <= 1'b0;
                ma_is_fencei <= 1'b0;
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
