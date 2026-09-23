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
#   - anything whose detection needs the caches to be real. The memory model
#     here answers both ports from one flat array: there is no instruction
#     cache to invalidate and no dirty line to write back, so a core that
#     forgets either still passes everything below. fence.i was broken from
#     M1 to M6 for exactly that reason and nothing here noticed. Those
#     mutations live in SIM_SYS/bug_inject.sh, which runs the core behind
#     CPU_CACHE.
#   - the quality of the branch predictor beyond "it works at all". The
#     predictor is transparent: the execute stage puts every wrong guess
#     right, so nothing it gets wrong can change the result, only the clock.
#     What is checked here is that t16_bench still runs in BENCH_LIMIT
#     cycles, which catches a buffer that has stopped predicting. The finer
#     points -- comparing the tag, which branch of a word an update belongs
#     to, the hysteresis of the counter -- cost a few percent on a workload
#     this size, under the noise of the limit. Seeing those would need a
#     benchmark with a code footprint larger than the buffer, which is worth
#     building when the predictor is tuned rather than now. 174 and 175 are
#     listed but are in that category: they are left in for the day such a
#     benchmark exists. 175 reports NOT DETECTED until then; 174 is caught
#     by the virtual memory test below (a real wrong answer, check 20 of
#     rv64ui-v-add), which only runs when its hex exists, that is after
#     "make riscv-tests-v" has been run once. What covers
#     the buffer instead is that a change to it which alters no prediction
#     leaves every cycle count in the suite exactly where it was.
#   - the inside of MMU_PMP, which has its own bench and its own campaign in
#     SIM_MMU; what is listed here is the way the core uses it
#   - a redirect issued while EX is stalled: the front end is redirected to
#     the same address again when EX finally moves on
#   - the stall of MA in the forwarding select from WB: a stalled MA keeps
#     its instruction, so the select from MA is set whenever the one from
#     WB would be, and MA comes first
#   - a redirect of a control transfer repeated while EX waits for MR: it
#     goes to the same place again and the counter of the buffer saturates;
#     only the clock can tell (ex_ctrl_done)
#   - the walker waiting for an access in MR before it takes the port: the
#     access waits for the walk instead (the port is the walker's), and the
#     PMP answer to MR is held back while the walker owns the checker
#   - the select from MR forwarding the address of a load: EX waits for
#     that load (lu_hazard) and takes nothing from MR in the meantime that
#     it keeps
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=bug_work
mkdir -p $WORK

# built by run_riscv_tests.sh -v; without it the campaign still runs, but the
# mutations that only the virtual memory environment can see are not covered
# t16_bench takes 33556 cycles as the design stands and 64087 with no
# predictor at all; the limit sits between the two
BENCH_LIMIT=${BENCH_LIMIT:-45000}

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
"16#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign i_kill      = redirect_valid . self_redirect;%assign i_kill      = 1'b0;%#IFU: the cache is not told about a redirect"
"17#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p1, p0};/assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p0, p1};/#IFU: the two parcels of a 32 bit instruction are swapped"
"18#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (fwd_a_ma) ex_a_fwd = ma_fwd_data;/else if (1'b0) ex_a_fwd = ma_fwd_data;/#core: no forwarding from MA into the first operand"
"19#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (fwd_b_wb) ex_b_fwd = wb_data;/else if (1'b0) ex_b_fwd = wb_data;/#core: no forwarding from WB into the second operand"
"20#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_fwd_data = (ma_mem \& ma_is_load) ? lsu_resp_data : ma_result;/assign ma_fwd_data = ma_result;/#core: a load in MA forwards its address"
"21#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs1_data <= ex_a_fwd;/                ex_rs1_data <= ex_rs1_data;/#core: a stalled EX does not keep the forwarded operand"
"22#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs2_data <= ex_b_fwd;/                ex_rs2_data <= ex_rs2_data;/#core: a stalled EX does not keep the forwarded store data"
"23#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/(mr_is_mem \& ~lsu_accept \& ~flush)/(1'b0)/#core: MR moves on although the cache did not take the access"
"24#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ma_valid   <= 1'b0;/                ma_valid   <= ma_valid;/#core: MA is not emptied when EX has nothing to hand over"
"25#CPU_CORE/CPU_CORE/CPU_CORE.sv#s@                wb_valid <= 1'b0;       // MA keeps its instruction : bubble@                wb_valid <= wb_valid;@#core: WB keeps its instruction while MA waits and retires it again"
"26#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_valid      <= id_advance \& fq_valid \& ~redirect_valid;/                ex_valid      <= id_advance \& fq_valid;/#core: the instruction behind a taken branch is not killed"
"27#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|id_exc_cause = EXC_ECALL_U + {3'd0, priv};|id_exc_cause = EXC_BREAK;|#core: ECALL is reported as a breakpoint"
"28#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign pop_q     = fq_valid \& fq_ready;/assign pop_q     = fq_valid;/#IFU: the fetch queue drops an instruction that ID could not take"
"77#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                       \& ~serial_busy \& ~wfi_wait;/                       \& ~wfi_wait;/#core: the instruction behind a CSR write is decoded with the old mstatus.FS"
"78#CPU_CORE/CPU_CORE/CPU_CORE.sv#/assign fpu_start/s/ \& ~stall_ma \&/ \&/#core: the FPU starts before the load in front of it has answered"
"79#CPU_CORE/CPU_CORE/CPU_CORE.sv#/assign mdu_start/s/ \& ~stall_ma \&/ \&/#core: the multiplier starts before the load in front of it has answered"
"80#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                         (dec_is_fp \& fp_off) ||/                         (1'b0) ||/#core: an FP instruction is allowed although mstatus.FS is off"
"81#CPU_FPU/FPU_ROUND/FPU_ROUND.sv#s/        flags\[1\] = tiny \& inexact \& ~overflow;              \/\/ UF/        flags[1] = 1'b0;/#FPU: underflow is never reported"
"82#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_load_data  = ma_fp_box ? {32'hFFFF_FFFF, lsu_resp_data\[31:0\]}/assign ma_load_data  = 1'b0 ? {32'hFFFF_FFFF, lsu_resp_data[31:0]}/#core: FLW does not NaN box what it loaded"
"83#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/mr_wdata      <= ex_is_fp_store ? ex_fs2_fwd : ex_b_fwd;/mr_wdata      <= ex_b_fwd;/#core: the store data of FSD comes from the integer file"
"84#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/            if (fflags_we) fflags <= fflags | fflags_set;/;/#CSR: fflags does not accumulate"
"85#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|        mstatus_val\[14:13\] = mstatus_fs;|        mstatus_val[14:13] = 2'b11;|#CSR: mstatus.FS always reads as dirty"
"86#CPU_FPU/FPU_ROUND/FPU_ROUND.sv#s/            RM_RNE:  inc = guard \& (rest | lsb);/            RM_RNE:  inc = guard;/#FPU: round to nearest never breaks a tie to even"
"87#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/        ex_rm_eff = (ex_fp_rm == 3'b111) ? frm_csr : ex_fp_rm;/        ex_rm_eff = ex_fp_rm;/#core: the dynamic rounding mode ignores frm"
"88#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/| (fpu_active \& ~fpu_done \& ~flush);/| (1'b0);/#core: EX does not wait for the FPU"
"89#CPU_CORE/CORE_FRF/CORE_FRF.sv#s/        rs3_data = (we \&\& (rs3 == rd)) ? rd_data : regs\[rs3\];/        rs3_data = regs[rs3];/#FRF: the third read port has no write first bypass"
"90#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/        else if (ex_use_fs1 \&\& ma_valid \&\& ma_fp_we \&\& (ma_fp_rd == ex_fs1)) ex_fs1_fwd = ma_fp_fwd_data;/        else if (1'b0) ex_fs1_fwd = ma_fp_fwd_data;/#core: no forwarding of a floating point result from MA"
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
"41#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign lsu_req_valid = mr_is_mem \& ~stall_ma \& ~flush;/assign lsu_req_valid = mr_is_mem \& ~stall_ma;/#core: the access behind a trapping instruction is still issued"
"42#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if (irq_req \&\& !dec_is_wfi) begin/if (irq_req) begin/#core: the interrupt is taken on the WFI itself, so mepc points at it"
"43#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                                       dec_is_fence_i) \& pipe_busy)/                                       dec_is_fence_i) \& 1'b0)/#core: a CSR access is issued into a pipeline that is not empty"
"44#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/    assign wfi_wait    = fq_valid \& dec_is_wfi \& ~irq_any;/    assign wfi_wait    = 1'b0;/#core: WFI does not wait"
"45#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            2'd3:    misaligned = |mem_addr\[2:0\];/            2'd3:    misaligned = 1'b0;/#core: a misaligned double word is not detected"
"46#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign mr_is_mem     = mr_valid \& mr_mem \& ~mr_exc;%assign mr_is_mem     = mr_valid \& mr_mem;%#core: an instruction that trapped still touches memory"
"146#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign ex_mmu_wait   = d_tr_req \& ~d_tr_ready \& ~flush;%assign ex_mmu_wait   = 1'b0;%#core: an access leaves EX before its address is translated"
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
"59#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (ex_is_mdu)                mr_result <= mdu_result;/else if (1'b0)                     mr_result <= mdu_result;/#core: the result of the multiplier is thrown away"
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
"73#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign keep_lo   = push_pc\[2:1\];%assign keep_lo   = 2'd0;%#IFU: a redirect into the middle of a word keeps the parcels in front of it"
"74#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign fq_is_rvc = (p0\[1:0\] != 2'b11);/assign fq_is_rvc = 1'b0;/#IFU: every instruction is taken to be 32 bit wide"
"75#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/assign link_pc  = pc + (is_rvc ? 64'd2 : 64'd4);/assign link_pc  = pc + 64'd4;/#EXU: the link address of a compressed jump is four bytes on"
"76#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/                mepc         <= {trap_epc\[63:1\], 1'b0};/                mepc         <= {trap_epc[63:2], 2'b00};/#CSR: mepc drops bit 1, which is wrong with the C extension"
"91#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+assign p_fail       = d_pmp_fail;+assign p_fail       = 1'b0;+#MMU: a load or store is never refused by the protection"
"92#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+assign i_chk_fail = i_pmp_fail;+assign i_chk_fail = 1'b0;+#MMU: a fetch is never refused by the protection"
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
"174#CPU_CORE/CORE_BTB/CORE_BTB.sv#s%assign spans   = upd_is32 \&\& (upd_off == 2'b11);%assign spans   = 1'b0;%#BTB: a 32 bit branch across two words is allocated"
"175#CPU_CORE/CORE_BTB/CORE_BTB.sv#s%upd_d\[F_IS32\], upd_target, new_cnt %upd_d[F_IS32], upd_d[F_TARGET +: 64], new_cnt %#BTB: the target of an entry that is hit again is not kept up to date"
"177#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%(btb_off >= next_start);%1'b1;%#IFU: a prediction is used even when the branch is before the address jumped to"
"178#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign straddle      = fq_have \& ~fq_is_rvc \& d0;%assign straddle      = 1'b0;%#IFU: the misfetch of a trim inside an instruction is not caught"
"179#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign fq_pred_taken  = fq_is_rvc ? d0 : d1;%assign fq_pred_taken  = d0;%#IFU: the prediction of a 32 bit instruction is read from its first parcel"
"180#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%pr_last  \[pr_tail\] <= btb_off + {1'b0, btb_is32};%pr_last  [pr_tail] <= btb_off;%#IFU: the trim keeps only the first half of a 32 bit branch"
"181#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%head_pc <= fq_pred_target;%head_pc <= head_pc + 64'd4;%#IFU: the head does not follow a prediction to its target"
"182#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%push_pc <= pred_resp ? pr_target\[pr_head\]%push_pc <= pred_resp ? 64'd0%#IFU: the push address after a prediction is wrong"
"183#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(take_branch \& (target_pc != ex_pred_target))%1'b0%#core: a prediction to the wrong target is not put right"
"184#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%((take_branch != ex_pred_taken) .%(1'b0 |%#core: a branch that was predicted wrongly is not put right"
"185#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%redirect_pc = take_branch ? target_pc : ex_seq_pc;%redirect_pc = target_pc;%#core: a wrong taken prediction does not go back to the next instruction"
"187#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign btb_upd_is32   = ~ex_is_rvc;%assign btb_upd_is32   = 1'b0;%#core: the buffer is told every branch is compressed"
"188#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign nx_rs1   = ex_advance ? (dec_use_rs1 ? dec_rs1 : 5'd0) : ex_rs1;%assign nx_rs1   = dec_use_rs1 ? dec_rs1 : 5'd0;%#core: the forwarding select of a stalled EX looks at the operands of the next instruction"
"189#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else                 nx_ma_wr = ma_valid \& ma_we_rd;%else                 nx_ma_wr = 1'b0;%#core: the forwarding select forgets a load that waits in MA"
"190#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%nx_ma_wr = nx_ma_wr \& (nx_ma_rd != 5'd0);%nx_ma_wr = nx_ma_wr;%#core: a result written to x0 is forwarded from MA"
"192#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else if (ex_advance) nx_mr_wr = ex_valid \& ex_we_rd \& ~ex_exc \& ~ex_mem;%else if (ex_advance) nx_mr_wr = ex_we_rd \& ~ex_exc \& ~ex_mem;%#core: the forwarding select from MR does not check that the instruction is there"
"193#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%                mr_refetch    <= ex_pred_taken \& ~ex_is_ctrl;%                mr_refetch    <= 1'b0;%#core: a non branch predicted taken is not refetched"
"194#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else if (fencei_taken || sfence_taken || refetch_taken)%else if (fencei_taken || sfence_taken)%#core: the refetch goes to where EX says, not behind the instruction"
"195#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign refetch_taken = ma_valid \& ma_refetch \& ~stall_ma \& ~trap_taken;%assign refetch_taken = ma_valid \& ma_refetch \& ~trap_taken;%#core: the refetch does not wait for the load it belongs to"
"196#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign lu_hazard = ex_valid \& (lu_int | lu_fp) \& ~flush;%assign lu_hazard = ex_valid \& lu_fp \& ~flush;%#core: no load-use interlock on an integer register"
"197#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign lu_hazard = ex_valid \& (lu_int | lu_fp) \& ~flush;%assign lu_hazard = ex_valid \& lu_int \& ~flush;%#core: no load-use interlock on a floating point register"
"198#CPU_CORE/CPU_CORE/CPU_CORE.sv#/assign mdu_start/{n;s/~lu_hazard;/1'b1;/}#core: the multiplier starts while its operand is a load in MR"
"199#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%mr_exc_cause = mr_is_store ? EXC_SFAULT : EXC_LFAULT;%mr_exc_cause = EXC_LFAULT;%#core: a store refused by the PMP is reported as a load"
"202#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign ex_ctrl_go = ex_valid \& ex_is_ctrl \& ~stall_ma \& ~lu_hazard \&%assign ex_ctrl_go = ex_valid \& ex_is_ctrl \& ~stall_ma \&%#core: a branch is decided before the load it reads has answered"
"203#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+assign ptw_pmp_fail = grant \& w_pmp_fail;+assign ptw_pmp_fail = 1'b0;+#MMU: the walker reads a page table the protection refuses"
"204#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+            .priv     (ptw_priv),+            .priv     (2'b11),+#MMU: the walker's reads are checked as machine mode"
"205#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign i_cancel    = chk_valid \& pmp_fail \& ~redirect_valid \& ~self_redirect;%assign i_cancel    = 1'b0;%#IFU: a fetch the PMP refuses is not cancelled"
"206#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%((i_resp_error | resp_cancel) ? 2'd1 : 2'd0)%(i_resp_error ? 2'd1 : 2'd0)%#IFU: a cancelled fetch is answered without a fault"
"207#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%if (i_cancel) pr_cancel\[pr_tail - OS_BITS'(1)\] <= 1'b1;%%#IFU: a cancelled fetch is never answered"
"208#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign i_cancel    = chk_valid \& pmp_fail%assign i_cancel    = pmp_fail%#IFU: the PMP answer is taken when no request is being checked"
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
$R/CORE_BTB/CORE_BTB.sv $R/CORE_IFU/CORE_IFU.sv $R/CORE_EXU/CORE_EXU.sv $R/CORE_LSU/CORE_LSU.sv \
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
    # the clock, not the answer: a predictor that has stopped predicting
    # still gets everything right, only slowly
    local cyc
    cyc=$(timeout 300 ./$d/obj/Vtb_CORE +hex=tests/t16_bench.hex +name=bench 2>&1 \
          | grep -oE '[0-9]+ cycles' | grep -oE '[0-9]+')
    if [ -n "$cyc" ] && [ "$cyc" -gt "$BENCH_LIMIT" ]; then
        fails=$((fails+1))
    else
        passes=$((passes+1))
    fi

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
