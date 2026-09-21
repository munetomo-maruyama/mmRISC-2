#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : check that the core tests detect deliberately injected bugs
#
# Each mutation copies the RTL to a work directory, applies one sed edit and
# runs every test program. At least one test is expected to FAIL (or to hang,
# which the watchdog of the test bench turns into a failure).
#
#   ./bug_inject.sh            : all mutations (run in parallel)
#   ./bug_inject.sh <n> ...    : selected mutations
#
# Not listed, because they cannot change the behaviour of this bench:
#   - the guards against x0 in CORE_RF (the read side and the write side each
#     make the other one invisible)
#   - the write back path of the data cache, which this bench has no model of
#     (it is exercised in SIM_CACHE)
#   - the inside of MMU_PMP, which has its own bench and its own campaign in
#     SIM_MMU; what is listed here is the way the core uses it
#   - a redirect issued while EX is stalled: the front end is redirected to
#     the same address again when EX finally moves on
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=bug_work
mkdir -p $WORK

# built by run_riscv_tests.sh -v; without it the campaign still runs, but the
# mutations that only the virtual memory environment can see are not covered
VTEST=rvtests/rv64ui-v-add
VTOHOST=$(/opt/riscv/bin/riscv64-unknown-elf-nm $VTEST 2>/dev/null | awk '$3=="tohost"{print $1}')
if [ ! -f $VTEST.hex ]; then
    echo "note: $VTEST.hex is missing; run ./run_riscv_tests.sh -v rv64ui first"
fi

# -j 2 (not -j 0): four mutations are built in parallel
VFLAGS="--binary --timing -j 2 --top-module tb_CORE -Wno-fatal"

# id # file # sed expression # description
MUTATIONS=(
"1#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/alu_op = insn\[30\] ? ALU_SRA : ALU_SRL;/alu_op = ALU_SRL;/g#decoder: SRAI / SRAIW become logical shifts"
"2#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/mem_signed = ~funct3\[2\];/mem_signed = 1'b1;/#decoder: LBU, LHU and LWU sign extend"
"3#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/mem_size   = funct3\[1:0\];/mem_size   = 2'd3;/#decoder: every access is a double word"
"4#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/ALU_SLT:  res = {63'd0, (\$signed(op_a) < \$signed(op_b))};/ALU_SLT:  res = {63'd0, (op_a < op_b)};/#EXU: SLT compares unsigned"
"5#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/3'b101:  take_branch = is_branch \& ~lt;/3'b101:  take_branch = is_branch \& lt;/#EXU: BGE takes the branch like BLT"
"6#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/assign link_pc  = pc + (is_rvc ? 64'd2 : 64'd4);/assign link_pc  = pc;/#EXU: the link address of JAL and JALR is the PC itself"
"7#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/alu_result = word_op ? {{32{res\[31\]}}, res\[31:0\]} : res;/alu_result = res;/#EXU: the 32 bit result is not sign extended"
"8#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/shamt = word_op ? {1'b0, op_b\[4:0\]} : op_b\[5:0\];/shamt = op_b[5:0];/#EXU: a 32 bit shift uses six bits of shift amount"
"9#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/else                        sh_src = {32'd0, op_a\[31:0\]};/else                        sh_src = op_a;/#EXU: SRLW shifts the whole 64 bit register"
"10#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/if (is_jalr) target_pc = (rs1_data + imm) \& ~64'd1;/if (is_jalr) target_pc = pc + imm;/#EXU: JALR jumps relative to the PC"
"11#CPU_CORE/CORE_RF/CORE_RF.sv#s/else if (wr_en \&\& (rs1 == rd))    rs1_data = rd_data;/else if (1'b0)                    rs1_data = rd_data;/#RF: no write first bypass on the first read port"
"12#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/                        imm      = imm_s;/                        imm      = imm_i;/#decoder: a store uses the I type immediate"
"13#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/2'd1:    ext = signed_r ? {{48{d_resp_data\[15\]}}, d_resp_data\[15:0\]}/2'd1:    ext = signed_r ? {{48{d_resp_data[7]}}, d_resp_data[15:0]}/#LSU: LH sign extends from the wrong bit"
"14#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign d_req_cmd   = req_cmd;/assign d_req_cmd   = 4'd0;/#LSU: a store is issued as a load"
"15#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign req_accept  = d_req_valid \& d_req_ready;/assign req_accept  = d_req_valid;/#LSU: the access counts as issued although the cache did not take it"
"16#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign i_kill      = redirect_valid;/assign i_kill      = 1'b0;/#IFU: the cache is not told about a redirect"
"17#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p1, p0};/assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p0, p1};/#IFU: the two parcels of a 32 bit instruction are swapped"
"18#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if      (ma_valid \&\& ma_we_rd \&\& (ma_rd != 5'd0) \&\& (ma_rd == ex_rs1)) ex_a_fwd = ma_fwd_data;/if      (1'b0) ex_a_fwd = ma_fwd_data;/#core: no forwarding from MA into the first operand"
"19#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (wb_valid \&\& wb_we_rd \&\& (wb_rd != 5'd0) \&\& (wb_rd == ex_rs2)) ex_b_fwd = wb_data;/else if (1'b0) ex_b_fwd = wb_data;/#core: no forwarding from WB into the second operand"
"20#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_fwd_data = (ma_mem \& ma_is_load) ? lsu_resp_data : ma_result;/assign ma_fwd_data = ma_result;/#core: a load in MA forwards its address"
"21#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs1_data <= ex_a_fwd;/                ex_rs1_data <= ex_rs1_data;/#core: a stalled EX does not keep the forwarded operand"
"22#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs2_data <= ex_b_fwd;/                ex_rs2_data <= ex_rs2_data;/#core: a stalled EX does not keep the forwarded store data"
"23#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/(ex_is_mem \& ~lsu_accept \& ~flush)/(1'b0)/#core: EX moves on although the cache did not take the access"
"24#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ma_valid   <= 1'b0;/                ma_valid   <= ma_valid;/#core: MA is not emptied when EX has nothing to hand over"
"25#CPU_CORE/CPU_CORE/CPU_CORE.sv#s@                wb_valid <= 1'b0;       // MA keeps its instruction : bubble@                wb_valid <= wb_valid;@#core: WB keeps its instruction while MA waits and retires it again"
"26#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_valid      <= id_advance \& fq_valid \& ~redirect_valid;/                ex_valid      <= id_advance \& fq_valid;/#core: the instruction behind a taken branch is not killed"
"27#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|id_exc_cause = EXC_ECALL_U + {3'd0, priv};|id_exc_cause = EXC_BREAK;|#core: ECALL is reported as a breakpoint"
"28#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign pop_q     = fq_valid \& fq_ready;/assign pop_q     = fq_valid;/#IFU: the fetch queue drops an instruction that ID could not take"
"77#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                       \& ~serial_busy \& ~wfi_wait;/                       \& ~wfi_wait;/#core: the instruction behind a CSR write is decoded with the old mstatus.FS"
"78#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign fpu_start  = fpu_active \& ~fpu_busy \& ~fpu_done \& ~flush \& ~stall_ma;/assign fpu_start  = fpu_active \& ~fpu_busy \& ~fpu_done \& ~flush;/#core: the FPU starts before the load in front of it has answered"
"79#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign mdu_start  = mdu_active \& ~mdu_busy \& ~mdu_done \& ~flush \& ~stall_ma;/assign mdu_start  = mdu_active \& ~mdu_busy \& ~mdu_done \& ~flush;/#core: the multiplier starts before the load in front of it has answered"
"80#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                         (dec_is_fp \& fp_off) ||/                         (1'b0) ||/#core: an FP instruction is allowed although mstatus.FS is off"
"81#CPU_FPU/FPU_ROUND/FPU_ROUND.sv#s/        flags\[1\] = tiny \& inexact \& ~overflow;              \/\/ UF/        flags[1] = 1'b0;/#FPU: underflow is never reported"
"82#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_load_data  = ma_fp_box ? {32'hFFFF_FFFF, lsu_resp_data\[31:0\]}/assign ma_load_data  = 1'b0 ? {32'hFFFF_FFFF, lsu_resp_data[31:0]}/#core: FLW does not NaN box what it loaded"
"83#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            .req_wdata    (ex_is_fp_store ? ex_fs2_fwd : ex_b_fwd),/            .req_wdata    (ex_b_fwd),/#core: the store data of FSD comes from the integer file"
"84#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/            if (fflags_we) fflags <= fflags | fflags_set;/;/#CSR: fflags does not accumulate"
"85#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|        mstatus_val\[14:13\] = mstatus_fs;|        mstatus_val[14:13] = 2'b11;|#CSR: mstatus.FS always reads as dirty"
"86#CPU_FPU/FPU_ROUND/FPU_ROUND.sv#s/            RM_RNE:  inc = guard \& (rest | lsb);/            RM_RNE:  inc = guard;/#FPU: round to nearest never breaks a tie to even"
"87#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/        ex_rm_eff = (ex_fp_rm == 3'b111) ? frm_csr : ex_fp_rm;/        ex_rm_eff = ex_fp_rm;/#core: the dynamic rounding mode ignores frm"
"88#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/| (fpu_active \& ~fpu_done \& ~flush);/| (1'b0);/#core: EX does not wait for the FPU"
"89#CPU_CORE/CORE_FRF/CORE_FRF.sv#s/        rs3_data = (we \&\& (rs3 == rd)) ? rd_data : regs\[rs3\];/        rs3_data = regs[rs3];/#FRF: the third read port has no write first bypass"
"90#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/        if      (ex_use_fs1 \&\& ma_valid \&\& ma_fp_we \&\& (ma_fp_rd == ex_fs1)) ex_fs1_fwd = ma_fp_fwd_data;/        if      (1'b0) ex_fs1_fwd = ma_fp_fwd_data;/#core: no forwarding of a floating point result from MA"
"29#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|mstatus_val\[12:11\] = mstatus_mpp;|mstatus_val[12:11] = 2'b11;|#CSR: mstatus.MPP always reads as machine mode"
"30#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_mpie <= mstatus_mie;/mstatus_mpie <= 1'b0;/#CSR: a trap does not save the interrupt enable in MPIE"
"31#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_mie  <= mstatus_mpie;/mstatus_mie  <= 1'b0;/#CSR: MRET does not put the interrupt enable back"
"32#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/CSR_MEPC      : mepc       <= {wr_data\[63:1\], 1'b0};/CSR_MEPC      : mepc       <= wr_data;/#CSR: mepc keeps the low bits of the written value"
"33#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign trap_vector = (tvec_sel\[1:0\] == 2'b01) \&\& trap_int|assign trap_vector = 1'b0 \&\& trap_int|#CSR: the vectored mode of mtvec is ignored"
"34#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|if      (irq_deliver\[IRQ_M_EXT\])   irq_cause = 5'(IRQ_M_EXT);|if      (irq_deliver[IRQ_M_TIMER]) irq_cause = 5'(IRQ_M_TIMER);|#CSR: the timer interrupt is reported before the external one"
"35#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/assign rd_readonly = (rd_addr\[11:10\] == 2'b11);/assign rd_readonly = 1'b0;/#CSR: writing a read only CSR is allowed"
"36#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|rd_exists = pmp_hit;|rd_exists = 1'b1;|#CSR: a CSR that does not exist answers instead of trapping"
"37#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/if (instret_inc) minstret <= minstret + 64'd1;/;/#CSR: minstret does not count"
"38#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign m_enabled   = (priv_r != PRIV_M) . mstatus_mie;|assign m_enabled   = 1'b1;|#CSR: an interrupt is taken although mstatus.MIE is clear"
"39#CPU_CLINT/CPU_CLINT.sv#s/mtimecmp\[cmp_safe\] <= merge(mtimecmp\[cmp_safe\], wdata, wstrb);/;/#CLINT: mtimecmp cannot be written"
"40#CPU_CLINT/CPU_CLINT.sv#s/assign irq_m_soft = msip;/assign irq_m_soft = '0;/#CLINT: the software interrupt never reaches the core"
"41#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign lsu_req_valid = ex_is_mem \& ~stall_ma \& ~flush;/assign lsu_req_valid = ex_is_mem \& ~stall_ma;/#core: the access behind a trapping instruction is still issued"
"42#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if (irq_req \&\& !dec_is_wfi) begin/if (irq_req) begin/#core: the interrupt is taken on the WFI itself, so mepc points at it"
"43#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                                       dec_is_fence_i) \& pipe_busy)/                                       dec_is_fence_i) \& 1'b0)/#core: a CSR access is issued into a pipeline that is not empty"
"44#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/    assign wfi_wait    = fq_valid \& dec_is_wfi \& ~irq_any;/    assign wfi_wait    = 1'b0;/#core: WFI does not wait"
"45#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            2'd3:    misaligned = |mem_addr\[2:0\];/            2'd3:    misaligned = 1'b0;/#core: a misaligned double word is not detected"
"46#CPU_CORE/CPU_CORE/CPU_CORE.sv#s+assign ex_is_mem     = ex_valid \& (ex_is_load . ex_is_store) \& ~ex_exc+assign ex_is_mem     = ex_valid \& (ex_is_load | ex_is_store)+#core: an instruction that trapped still touches memory"
"146#CPU_CORE/CPU_CORE/CPU_CORE.sv#s+                                    \& d_tr_ready;+                                    ;+#core: an access is issued before its address is translated"
"47#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign trap_epc_c   = ma_pc;/assign trap_epc_c   = ma_pc + 64'd4;/#core: mepc points behind the instruction that trapped"
"48#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|                                             : {32'd0, ex_insn};|                                             : 64'd0;|#core: mtval of an illegal CSR access is empty"
"49#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/csr_wr = (funct3\[1:0\] == 2'b01) || (rs1 != 5'd0);/csr_wr = 1'b1;/#decoder: CSRRS with x0 writes the CSR"
"50#CPU_CORE/CORE_DEC/CORE_DEC.sv#s|12'h302: begin is_mret   = 1'b1; sys_noarg = 1'b1; end|12'h302: illegal = 1'b1;|#decoder: MRET is not known"
"51#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/OP_MULH:            begin a_signed = 1'b1; b_signed = 1'b1; end/OP_MULH:            begin a_signed = 1'b0; b_signed = 1'b0; end/#MDU: MULH multiplies unsigned"
"52#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/prod\[127:64\] <= prod\[127:64\] - (a_neg ? b_r : 64'd0)/prod[127:64] <= prod[127:64] - (1'b0 ? b_r : 64'd0)/#MDU: the sign of the first operand is not corrected"
"53#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/                            quo_r <= {64{1'b1}};/                            quo_r <= 64'd0;/#MDU: a division by zero answers zero"
"54#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/                            quo_r <= a_prep;                 \/\/ overflow/                            quo_r <= 64'd0;/#MDU: the one overflow of a division is not special"
"55#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/quo_neg <= a_signed \& (a_prep\[63\] ^ b_prep\[63\]);/quo_neg <= 1'b0;/#MDU: the quotient keeps no sign"
"56#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/rem_neg <= a_signed \& a_prep\[63\];/rem_neg <= a_signed \& b_prep[63];/#MDU: the remainder takes the sign of the divisor"
"57#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/count   <= word_op ? 7'd32 : 7'd64;/count   <= 7'd64;/#MDU: the 32 bit forms divide over 64 steps"
"58#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/{64'd0, a_mag\[31:0\], 32'd0}/{64'd0, a_mag}/#MDU: the dividend of a 32 bit form is not moved up"
"59#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (ex_is_mdu)                ma_result <= mdu_result;/else if (1'b0)                     ma_result <= mdu_result;/#core: the result of the multiplier is thrown away"
"60#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/| (mdu_active \& ~mdu_done \& ~flush)/| (1'b0)/#core: EX does not wait for the multiplier"
"61#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/5'b00000: mem_cmd = 4'd5;           \/\/ AMOADD/5'b00000: mem_cmd = 4'd4;/#decoder: AMOADD is issued as AMOSWAP"
"62#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/5'b00011: mem_cmd = CMD_SC;/5'b00011: mem_cmd = CMD_LR;/#decoder: SC is issued as LR"
"63#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/                    is_load = 1'b1;              \/\/ rs2 is the source of the/                    is_load = 1'b0;/#decoder: an atomic operation does not write its register"
"64#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/                            is_store = 1'b0;/                            is_store = 1'b1;/#decoder: LR counts as a store, so a misaligned LR reports the wrong cause"
"65#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/insn = i_type(imm_addi4spn, 5'd2, 3'b000, rdp, OP_IMM);/insn = i_type(imm_lw, 5'd2, 3'b000, rdp, OP_IMM);/#decompressor: C.ADDI4SPN takes the wrong immediate"
"66#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/3'b010: insn = i_type(imm_lw, rs1p, 3'b010, rdp, OP_LOAD);   \/\/ C.LW/3'b010: insn = i_type(imm_ld, rs1p, 3'b010, rdp, OP_LOAD);/#decompressor: C.LW takes the immediate of C.LD"
"67#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/2'b01: insn = i_type({6'b010000, shamt}, rs1p, 3'b101, rs1p, OP_IMM);/2'b01: insn = i_type({6'b000000, shamt}, rs1p, 3'b101, rs1p, OP_IMM);/#decompressor: C.SRAI becomes a logical shift"
"68#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/insn_c\[6\], insn_c\[7\], insn_c\[2\]/insn_c[7], insn_c[6], insn_c[2]/#decompressor: two bits of the jump target of C.J are swapped"
"69#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/insn = i_type(12'd0, rs1, 3'b000, 5'd1, OP_JALR);/insn = i_type(12'd0, rs1, 3'b000, 5'd0, OP_JALR);/#decompressor: C.JALR does not write the link register"
"70#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/insn = i_type(imm_ci, rd, 3'b000, rd, OP_IMM32);/insn = i_type(imm_ci, rd, 3'b000, rd, OP_IMM);/#decompressor: C.ADDIW becomes a 64 bit ADDI"
"71#CPU_CORE/CORE_DECOMP/CORE_DECOMP.sv#s/if (insn_c\[12:5\] == 8'd0) illegal = 1'b1;   \/\/ also the all zero word/;/#decompressor: the reserved encoding of C.ADDI4SPN is accepted"
"72#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/pq_head <= pq_head + (fq_is_rvc ? PQ_BITS'(1) : PQ_BITS'(2));/pq_head <= pq_head + PQ_BITS'(1);/#IFU: a 32 bit instruction takes one parcel out of the queue"
"73#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign push_n    = 3'd4 - {1'b0, push_pc\[2:1\]};/assign push_n    = 3'd4;/#IFU: a redirect into the middle of a word keeps the parcels in front of it"
"74#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign fq_is_rvc = (p0\[1:0\] != 2'b11);/assign fq_is_rvc = 1'b0;/#IFU: every instruction is taken to be 32 bit wide"
"75#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/assign link_pc  = pc + (is_rvc ? 64'd2 : 64'd4);/assign link_pc  = pc + 64'd4;/#EXU: the link address of a compressed jump is four bytes on"
"76#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/                mepc         <= {trap_epc\[63:1\], 1'b0};/                mepc         <= {trap_epc[63:2], 2'b00};/#CSR: mepc drops bit 1, which is wrong with the C extension"
"91#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+end else if (d_pmp_fail) begin+end else if (1'b0) begin+#MMU: a load or store is never refused by the protection"
"92#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+end else if (i_pmp_fail) begin+end else if (1'b0) begin+#MMU: a fetch is never refused by the protection"
"93#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+if (lsu_idle \&\& ptw_need \&\& !kill) begin+if (ptw_need \&\& !kill) begin+#MMU: the walker takes the cache port while the pipeline is using it"
"94#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|.is_exec  (1'b1),|.is_exec  (1'b0),|#MMU: a fetch is checked against no permission at all"
"95#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|id_exc_cause = EXC_ECALL_U + {3'd0, priv};|id_exc_cause = 5'd11;|#core: ECALL always reports machine mode"
"96#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign trap_to_s = deleg \& (priv_r != PRIV_M);|assign trap_to_s = 1'b0;|#CSR: nothing is ever delegated"
"97#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign trap_to_s = deleg \& (priv_r != PRIV_M);|assign trap_to_s = deleg;|#CSR: a trap from machine mode is delegated too"
"98#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign sret_target = sepc;|assign sret_target = mepc;|#CSR: SRET returns to mepc"
"99#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|priv_r       <= mstatus_mpp;|priv_r       <= PRIV_M;|#CSR: MRET stays in machine mode"
"100#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|if (rd_addr\[9:8\] > priv_r) rd_denied = 1'b1;|if (1'b0) rd_denied = 1'b1;|#CSR: the privilege of a CSR address is not checked"
"101#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|mstatus_mpp  <= priv_r;|mstatus_mpp  <= PRIV_M;|#CSR: a trap records machine mode as the level it came from"
"102#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|(dec_is_sfence \& ((priv == PRIV_U) . ((priv == PRIV_S) \& st_tvm)))|1'b0|#core: TVM does not catch SFENCE.VMA"
"103#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign s_enabled   = (priv_r == PRIV_U) . ((priv_r == PRIV_S) \& mstatus_sie);|assign s_enabled   = mstatus_sie;|#CSR: a supervisor interrupt in user mode needs SIE"

"110#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign d_u_ok    = (d_priv == PRIV_U) ? d_tperm\[4\]|assign d_u_ok    = (d_priv == PRIV_U) ? 1'b1|#MMU: user mode may use a supervisor page"
"111#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|: (~d_tperm\[4\] . mstatus_sum);|: 1'b1;|#MMU: the supervisor may use a user page without SUM"
"112#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign d_perm_ok = d_u_ok \& d_tperm\[6\]|assign d_perm_ok = d_u_ok \& 1'b1|#MMU: the accessed bit is not checked"
"113#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|(d_is_store ? (d_tperm\[2\] \& d_tperm\[7\]) : 1'b1)|(d_is_store ? d_tperm[7] : 1'b1)|#MMU: a store does not need write permission"
"114#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|(d_is_store ? (d_tperm\[2\] \& d_tperm\[7\]) : 1'b1)|(d_is_store ? d_tperm[2] : 1'b1)|#MMU: a store does not need the dirty bit"
"115#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign d_rd_ok   = d_tperm\[1\] . (mstatus_mxr \& d_tperm\[3\]);|assign d_rd_ok   = d_tperm[1] \| d_tperm[3];|#MMU: an execute only page is readable without MXR"
"116#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign i_perm_ok = i_tperm\[3\] \& i_tperm\[6\]|assign i_perm_ok = i_tperm[6]|#MMU: a page without execute permission may be executed"
"117#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|2'd1:    merge_pa = {8'd0, ppn_in\[43:9\],  va\[20:0\]};   // 2M|2'd1:    merge_pa = {8'd0, ppn_in, va[11:0]};|#MMU: a two megabyte page is put together like a small one"
"118#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|2'd2:    merge_pa = {8'd0, ppn_in\[43:18\], va\[29:0\]};   // 1G|2'd2:    merge_pa = {8'd0, ppn_in, va[11:0]};|#MMU: a gigabyte page is put together like a small one"
"119#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign d_va_ok = (d_vaddr\[63:39\] == {25{d_vaddr\[38\]}});|assign d_va_ok = 1'b1;|#MMU: a virtual address that is not sign extended is accepted"
"120#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign i_trans = sv39 \& (priv   != PRIV_M);|assign i_trans = sv39;|#MMU: machine mode fetches are translated too"
"121#CPU_MMU/CORE_MMU/CORE_MMU.sv#s|assign d_priv  = mstatus_mprv ? mstatus_mpp : priv;|assign d_priv  = priv;|#MMU: MPRV is ignored"
"122#CPU_MMU/MMU_TLB/MMU_TLB.sv#s|default: vpn_match = (a == b);                 // 4K|default: vpn_match = (a[26:9] == b[26:9]);|#TLB: a four kilobyte entry compares too few bits and aliases"
"123#CPU_MMU/MMU_TLB/MMU_TLB.sv#s|inv_hit\[i\] = (inv_all_addr ..|inv_hit[i] = (1'b0 \&\&|#TLB: SFENCE.VMA with an address invalidates nothing"
"124#CPU_MMU/MMU_TLB/MMU_TLB.sv#s|if (inv_hit\[i\]) e_valid\[i\] <= 1'b0;|if (1'b0) e_valid[i] <= 1'b0;|#TLB: SFENCE.VMA invalidates nothing at all"
"125#CPU_MMU/MMU_PTW/MMU_PTW.sv#s|assign pte_bad  = ~pte_v .|assign pte_bad  = 1'b0 \&|#PTW: an entry that is not valid is walked anyway"
"126#CPU_MMU/MMU_PTW/MMU_PTW.sv#s|2'd1:    vpn_sel = vpn_r\[17:9\];|2'd1:    vpn_sel = vpn_r[8:0];|#PTW: the index of the middle level is taken from the wrong bits"
"127#CPU_MMU/MMU_PTW/MMU_PTW.sv#s+2'd2:    misaligned = .pte_ppn\[17:0\];+2'd2:    misaligned = 1'b0;+#PTW: a gigabyte page need not be aligned"
"128#CPU_MMU/MMU_PTW/MMU_PTW.sv#s+2'd1:    misaligned = .pte_ppn\[8:0\];+2'd1:    misaligned = 1'b0;+#PTW: a two megabyte page need not be aligned"
"129#CPU_MMU/MMU_PTW/MMU_PTW.sv#s|assign pte_leaf = pte_r . pte_x;|assign pte_leaf = pte_r;|#PTW: a page that may only be executed is not a leaf"
"130#CPU_MMU/MMU_PTW/MMU_PTW.sv#s|assign m_req_addr  = {8'd0, table_ppn, 12'd0} . {52'd0, vpn_sel, 3'd0};|assign m_req_addr  = {8'd0, table_ppn, 12'd0};|#PTW: every entry of a table is read as the first one"
"150#CPU_PLIC/CPU_PLIC.sv#s%for (int s = SOURCES; s >= 1; s--) begin%for (int s = 1; s <= SOURCES; s++) begin%#PLIC: a tie of equal priorities is broken by the highest number"
"151#CPU_PLIC/CPU_PLIC.sv#s+(prio\[s\] > threshold\[c\])+(prio[s] >= threshold[c])+#PLIC: the threshold lets its own priority through"
"152#CPU_PLIC/CPU_PLIC.sv#s+(prio\[s\] >= best_prio\[c\])+(prio[s] <= best_prio[c])+#PLIC: the lowest priority is served first"
"153#CPU_PLIC/CPU_PLIC.sv#s+pending\[best_id\[ctx_ctl\]\] <= 1'b0;+;+#PLIC: a claim does not take the source out of the pending set"
"154#CPU_PLIC/CPU_PLIC.sv#s+if (src\[s\] \&\& gw_ready\[s\]) begin+if (src[s]) begin+#PLIC: the gateway forwards again before the completion"
"155#CPU_PLIC/CPU_PLIC.sv#s+gw_ready\[done_id\] <= 1'b1;+;+#PLIC: a completion does not reopen the gateway"
"156#CPU_PLIC/CPU_PLIC.sv#s+enable\[ctx_ctl\]\[done_id\])+1'b1)+#PLIC: a context may complete a source it has not enabled"
"157#CPU_PLIC/CPU_PLIC.sv#s%enable\[ctx_en\]\[bit_word . 32 . b\] <= wr32\[b\];%enable[0][bit_word * 32 + b] <= wr32[b];%#PLIC: an enable written for one context lands in all of them"
"158#CPU_PLIC/CPU_PLIC.sv#s+irq\[c\] = (best_id\[c\] != '0);+irq[c] = 1'b0;+#PLIC: no interrupt line is ever raised"
"159#CPU_PLIC/CPU_PLIC.sv#s+rd32 = {{(32-ID_BITS){1'b0}}, best_id\[ctx_ctl\]};+rd32 = 32'd0;+#PLIC: a claim always reads zero"
"160#CPU_PLIC/CPU_PLIC.sv#s+assign claim_now = sel \&\& !we \&\& ok_ctx \&\& is_claim+assign claim_now = sel \&\& !we \&\& ok_ctx+#PLIC: reading the threshold claims as well"
"161#CPU_PLIC/CPU_PLIC.sv#s+assign is_claim     = in_context \&\& ((int'(addr) % 32'h1000) == 4);+assign is_claim     = in_context \&\& ((int'(addr) % 32'h1000) == 0);+#PLIC: the claim register is at the wrong offset"
"162#CPU_PLIC/CPU_PLIC.sv#s+assign ctx_ctl      = (int'(addr) - 32'h20_0000) / 32'h1000;+assign ctx_ctl      = 0;+#PLIC: every context uses the claim register of context zero"
"163#CPU_PLIC/CPU_PLIC.sv#s+assign ctx_en       = (int'(addr) - 32'h00_2000) / 32'h80;+assign ctx_en       = 0;+#PLIC: every enable word belongs to context zero"
)

# every mutation is run without and with back pressure on both cache ports
STALL_MODES=("" "+istall=40 +dstall=40")

run_one() {
    local line="$1"
    IFS='#' read -r id file expr desc <<< "$line"
    local d=$WORK/m$id
    rm -rf $d; mkdir -p $d
    cp -r ../../RTL/CPU $d/CPU
    sed -i "$expr" $d/CPU/$file
    if cmp -s ../../RTL/CPU/$file $d/CPU/$file; then
        echo "M$id [NOT APPLIED] $desc"; return
    fi
    local R=$d/CPU/CPU_CORE
    local SRCS="$d/CPU/CPU_MMU/MMU_PMP/MMU_PMP.sv \
$d/CPU/CPU_MMU/MMU_TLB/MMU_TLB.sv $d/CPU/CPU_MMU/MMU_PTW/MMU_PTW.sv \
$d/CPU/CPU_MMU/CORE_MMU/CORE_MMU.sv \
$R/CORE_DEC/CORE_DEC.sv $R/CORE_DECOMP/CORE_DECOMP.sv $R/CORE_CSR/CORE_CSR.sv \
$R/CORE_RF/CORE_RF.sv \
$R/CORE_IFU/CORE_IFU.sv $R/CORE_EXU/CORE_EXU.sv $R/CORE_LSU/CORE_LSU.sv \
$R/CORE_MDU/CORE_MDU.sv \
$R/CORE_FRF/CORE_FRF.sv $d/CPU/CPU_FPU/FPU_ROUND/FPU_ROUND.sv \
$d/CPU/CPU_FPU/CORE_FPU/CORE_FPU.sv \
$R/CPU_CORE/CPU_CORE.sv $d/CPU/CPU_CLINT/CPU_CLINT.sv \
$d/CPU/CPU_PLIC/CPU_PLIC.sv \
CORE_MEM_MODEL.sv tb_CORE.sv"
    if ! verilator $VFLAGS -Mdir $d/obj $SRCS > $d/build.log 2>&1; then
        sleep 5                       # retry once (transient resource failure)
        if ! verilator $VFLAGS -Mdir $d/obj $SRCS > $d/build.log 2>&1; then
            echo "M$id [BUILD FAILED] $desc"; return
        fi
    fi
    local fails=0 passes=0 m=0
    for mode in "${STALL_MODES[@]}"; do
        m=$((m+1))
        for t in $(ls tests/t*.S | xargs -n1 basename | sed 's/\.S$//'); do
            timeout 300 ./$d/obj/Vtb_CORE +hex=tests/$t.hex +name=$t $mode > $d/$t.$m.log 2>&1
            if grep -q ": PASS" $d/$t.$m.log; then passes=$((passes+1)); else fails=$((fails+1)); fi
        done
        # One test out of the virtual memory environment. The tests above all
        # run out of a single gigabyte page, so their instruction TLB never
        # misses while a load is in the cache; this one is mapped four
        # kilobytes at a time and does that all the time, which is the only
        # way the arbitration of the cache port between the pipeline and the
        # page table walker is exercised.
        if [ -f $VTEST.hex ]; then
            timeout 300 ./$d/obj/Vtb_CORE +hex=$VTEST.hex +name=vtest \
                +tohost=$VTOHOST +maxcycles=3000000 $mode > $d/vtest.$m.log 2>&1
            if grep -q ": PASS" $d/vtest.$m.log; then passes=$((passes+1)); else fails=$((fails+1)); fi
        fi
    done
    if [ $fails -eq 0 ]; then
        echo "M$id [NOT DETECTED] $desc"
    else
        echo "M$id [DETECTED: $fails/$((fails+passes)) runs fail] $desc"
    fi
}

sel=("$@")
pids=()
for line in "${MUTATIONS[@]}"; do
    id=${line%%#*}
    if [ ${#sel[@]} -eq 0 ] || [[ " ${sel[*]} " == *" $id "* ]]; then
        run_one "$line" &
        pids+=($!)
        while [ $(jobs -r | wc -l) -ge 4 ]; do sleep 2; done
    fi
done
for p in "${pids[@]}"; do wait $p; done
