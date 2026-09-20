//---------------------------------------------------------------------------
// CPU_CORE.sv
//
// mmRISC-2 CPU core (RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md).
//
//   IF1 / IF2 : CORE_IFU, instruction cache and fetch queue
//   ID        : CORE_DEC and the register file
//   EX        : CORE_EXU (ALU, branch, address), the data cache request
//   MA        : waits for the data cache answer
//   WB        : register write back, trace, halt
//
//   M1 : RV64I without CSR, traps or MMU. ECALL / EBREAK / an illegal
//   instruction stop the core and are reported on halt_cause, which is what
//   the test bench uses to end a program.
//---------------------------------------------------------------------------

`timescale 1ns/1ps

module CPU_CORE
    #(
        parameter int          PADDR_WIDTH  = 40,
        parameter logic [63:0] RESET_VECTOR = 64'h0000_0000_8000_0000,
        parameter int          FQ_DEPTH     = 4
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

        // retirement trace (verification)
        output logic                    trace_valid,
        output logic [63:0]             trace_pc,
        output logic [31:0]             trace_insn,
        output logic                    trace_rd_we,
        output logic [4:0]              trace_rd,
        output logic [63:0]             trace_rd_data,

        // the core stopped (M1 has no trap handler yet)
        output logic                    core_halted,
        output logic [2:0]              halt_cause    // 1:ECALL 2:EBREAK 3:illegal 4:bus error
    );

    localparam logic [2:0] HALT_NONE    = 3'd0;
    localparam logic [2:0] HALT_ECALL   = 3'd1;
    localparam logic [2:0] HALT_EBREAK  = 3'd2;
    localparam logic [2:0] HALT_ILLEGAL = 3'd3;
    localparam logic [2:0] HALT_BUSERR  = 3'd4;

    //=================================================================
    // ID : fetch queue, decoder, register file
    //=================================================================
    logic        fq_valid, fq_ready, fq_error;
    logic [63:0] fq_pc;
    logic [31:0] fq_insn;

    logic        redirect_valid;
    logic [63:0] redirect_pc;

    CORE_IFU
        #(.PADDR_WIDTH(PADDR_WIDTH), .RESET_VECTOR(RESET_VECTOR), .FQ_DEPTH(FQ_DEPTH))
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
            .fq_error       (fq_error)
        );

    assign i_flush_valid = 1'b0;        // fence.i comes with the trap logic

    // decoder
    logic [4:0]  dec_rs1, dec_rs2, dec_rd;
    logic        dec_use_rs1, dec_use_rs2, dec_we_rd;
    logic [63:0] dec_imm;
    logic [3:0]  dec_alu_op;
    logic [1:0]  dec_a_sel;
    logic        dec_b_sel, dec_word_op;
    logic        dec_is_branch, dec_is_jal, dec_is_jalr;
    logic [2:0]  dec_br_op;
    logic        dec_is_load, dec_is_store;
    logic [1:0]  dec_mem_size;
    logic        dec_mem_signed;
    logic        dec_is_fence, dec_is_fence_i, dec_is_ecall, dec_is_ebreak, dec_illegal;

    CORE_DEC u_dec
        (
            .insn       (fq_insn),
            .rs1        (dec_rs1),
            .rs2        (dec_rs2),
            .rd         (dec_rd),
            .use_rs1    (dec_use_rs1),
            .use_rs2    (dec_use_rs2),
            .we_rd      (dec_we_rd),
            .imm        (dec_imm),
            .alu_op     (dec_alu_op),
            .a_sel      (dec_a_sel),
            .b_sel      (dec_b_sel),
            .word_op    (dec_word_op),
            .is_branch  (dec_is_branch),
            .is_jal     (dec_is_jal),
            .is_jalr    (dec_is_jalr),
            .br_op      (dec_br_op),
            .is_load    (dec_is_load),
            .is_store   (dec_is_store),
            .mem_size   (dec_mem_size),
            .mem_signed (dec_mem_signed),
            .is_fence   (dec_is_fence),
            .is_fence_i (dec_is_fence_i),
            .is_ecall   (dec_is_ecall),
            .is_ebreak  (dec_is_ebreak),
            .illegal    (dec_illegal)
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
    logic        ex_is_branch, ex_is_jal, ex_is_jalr;
    logic        ex_is_load, ex_is_store;
    logic [1:0]  ex_mem_size;
    logic        ex_mem_signed;
    logic [2:0]  ex_halt;                  // ECALL / EBREAK / illegal / fetch error

    //=================================================================
    // MA stage registers
    //=================================================================
    logic        ma_valid, ma_we_rd, ma_mem, ma_is_load;
    logic [63:0] ma_pc, ma_result;
    logic [31:0] ma_insn;
    logic [4:0]  ma_rd;
    logic [2:0]  ma_halt;

    //=================================================================
    // WB stage registers
    //=================================================================
    logic [63:0] wb_pc;
    logic [31:0] wb_insn;
    logic [2:0]  wb_halt;

    //=================================================================
    // forwarding into EX
    //=================================================================
    logic [63:0] ex_a_fwd, ex_b_fwd, ma_fwd_data;

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
            .alu_result (alu_result),
            .link_pc    (link_pc),
            .target_pc  (target_pc),
            .take_branch(take_branch),
            .mem_addr   (mem_addr)
        );

    //=================================================================
    // load / store unit
    //=================================================================
    logic lsu_req_valid, lsu_accept, lsu_resp_valid, lsu_resp_error;
    logic [63:0] lsu_resp_data;

    CORE_LSU #(.PADDR_WIDTH(PADDR_WIDTH)) u_lsu
        (
            .clk          (clk),
            .rst_n        (rst_n),
            .req_valid    (lsu_req_valid),
            .req_is_store (ex_is_store),
            .req_addr     (mem_addr),
            .req_size     (ex_mem_size),
            .req_signed   (ex_mem_signed),
            .req_wdata    (ex_b_fwd),
            .req_accept   (lsu_accept),
            .resp_valid   (lsu_resp_valid),
            .resp_data    (lsu_resp_data),
            .resp_error   (lsu_resp_error),
            .kill         (1'b0),
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
    // pipeline control
    //=================================================================
    logic ex_is_mem, stall_ma, stall_ex, ex_advance, id_advance;

    assign ex_is_mem     = ex_valid & (ex_is_load | ex_is_store) & (ex_halt == HALT_NONE);
    assign lsu_req_valid = ex_is_mem & ~stall_ma;
    assign stall_ma      = ma_valid & ma_mem & ~lsu_resp_valid;
    assign stall_ex      = stall_ma | (ex_is_mem & ~lsu_accept);
    assign ex_advance    = ~stall_ex;
    assign id_advance    = ex_advance & ~core_halted;
    assign fq_ready      = id_advance;

    // a branch or jump in EX redirects the front end
    assign redirect_valid = ex_valid & take_branch & ex_advance & (ex_halt == HALT_NONE);
    assign redirect_pc    = target_pc;

    //=================================================================
    // pipeline registers
    //=================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid    <= 1'b0;
            ex_pc       <= 64'd0;
            ex_insn     <= 32'd0;
            ex_rs1_data <= 64'd0;
            ex_rs2_data <= 64'd0;
            ex_imm      <= 64'd0;
            ex_rs1      <= 5'd0;
            ex_rs2      <= 5'd0;
            ex_rd       <= 5'd0;
            ex_we_rd    <= 1'b0;
            ex_alu_op   <= 4'd0;
            ex_a_sel    <= 2'd0;
            ex_b_sel    <= 1'b0;
            ex_word_op  <= 1'b0;
            ex_br_op    <= 3'd0;
            ex_is_branch<= 1'b0;
            ex_is_jal   <= 1'b0;
            ex_is_jalr  <= 1'b0;
            ex_is_load  <= 1'b0;
            ex_is_store <= 1'b0;
            ex_mem_size <= 2'd0;
            ex_mem_signed <= 1'b0;
            ex_halt     <= HALT_NONE;

            ma_valid    <= 1'b0;
            ma_we_rd    <= 1'b0;
            ma_mem      <= 1'b0;
            ma_is_load  <= 1'b0;
            ma_pc       <= 64'd0;
            ma_insn     <= 32'd0;
            ma_result   <= 64'd0;
            ma_rd       <= 5'd0;
            ma_halt     <= HALT_NONE;

            wb_valid    <= 1'b0;
            wb_we_rd    <= 1'b0;
            wb_rd       <= 5'd0;
            wb_data     <= 64'd0;
            wb_pc       <= 64'd0;
            wb_insn     <= 32'd0;
            wb_halt     <= HALT_NONE;

            core_halted <= 1'b0;
            halt_cause  <= HALT_NONE;
        end else begin
            //---------------------------------------------------------
            // ID -> EX
            //---------------------------------------------------------
            if (id_advance) begin
                ex_valid      <= fq_valid & ~redirect_valid;
                ex_pc         <= fq_pc;
                ex_insn       <= fq_insn;
                ex_rs1_data   <= rf_rs1_data;
                ex_rs2_data   <= rf_rs2_data;
                ex_imm        <= dec_imm;
                ex_rs1        <= dec_use_rs1 ? dec_rs1 : 5'd0;
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
                ex_is_load    <= dec_is_load;
                ex_is_store   <= dec_is_store;
                ex_mem_size   <= dec_mem_size;
                ex_mem_signed <= dec_mem_signed;
                if      (!fq_valid)     ex_halt <= HALT_NONE;
                else if (fq_error)      ex_halt <= HALT_BUSERR;
                else if (dec_is_ecall)  ex_halt <= HALT_ECALL;
                else if (dec_is_ebreak) ex_halt <= HALT_EBREAK;
                else if (dec_illegal)   ex_halt <= HALT_ILLEGAL;
                else                    ex_halt <= HALT_NONE;
            end else begin
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
                ma_valid   <= ex_valid & ~core_halted;
                ma_pc      <= ex_pc;
                ma_insn    <= ex_insn;
                ma_rd      <= ex_rd;
                ma_we_rd   <= ex_we_rd & (ex_halt == HALT_NONE);
                ma_mem     <= ex_is_mem;
                ma_is_load <= ex_is_load;
                ma_halt    <= ex_halt;
                if (ex_is_jal || ex_is_jalr) ma_result <= link_pc;
                else                         ma_result <= alu_result;
            end else if (!stall_ma) begin
                // MA handed its instruction over but EX has nothing to give
                // (the cache did not take the next access yet) : bubble
                ma_valid   <= 1'b0;
                ma_we_rd   <= 1'b0;
                ma_mem     <= 1'b0;
                ma_is_load <= 1'b0;
                ma_halt    <= HALT_NONE;
            end

            //---------------------------------------------------------
            // MA -> WB
            //---------------------------------------------------------
            if (!stall_ma) begin
                wb_valid <= ma_valid;
                wb_pc    <= ma_pc;
                wb_insn  <= ma_insn;
                wb_rd    <= ma_rd;
                wb_we_rd <= ma_we_rd;
                wb_halt  <= ma_halt;
                if (ma_mem && ma_is_load) wb_data <= lsu_resp_data;
                else                      wb_data <= ma_result;
                if (ma_valid && ma_mem && lsu_resp_error) wb_halt <= HALT_BUSERR;
            end else begin
                wb_valid <= 1'b0;       // MA keeps its instruction : bubble
                wb_we_rd <= 1'b0;
                wb_halt  <= HALT_NONE;
            end

            //---------------------------------------------------------
            // halt
            //---------------------------------------------------------
            if (wb_valid && (wb_halt != HALT_NONE) && !core_halted) begin
                core_halted <= 1'b1;
                halt_cause  <= wb_halt;
            end
        end
    end

    always @(*) begin
        trace_valid   = wb_valid & (wb_halt == HALT_NONE) & ~core_halted;
        trace_pc      = wb_pc;
        trace_insn    = wb_insn;
        trace_rd_we   = wb_we_rd & (wb_rd != 5'd0);
        trace_rd      = wb_rd;
        trace_rd_data = wb_data;
    end

endmodule : CPU_CORE
