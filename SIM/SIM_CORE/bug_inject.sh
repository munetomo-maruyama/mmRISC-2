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
#     by t24_predict (since branches across a fetch word are predicted
#     through a tail entry, 2026-10) and by the virtual memory test below.
#     What covers
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
#   - "the access behind a trapping instruction is still issued" (41 until
#     the accesses went from EX, 2026-10): what decides it now is lsu_e_go,
#     which 240 - 250 take apart piece by piece
#   - the precedence of MA's request over EX's in CORE_LSU (~m_valid in
#     e_accept): MA only has a request when it holds an access that has not
#     gone, and then stall_ma is set, which keeps EX from issuing anyway; the
#     two never ask in the same cycle
#   - the gate that keeps a debug entry from taking a trap (trap_en in
#     CPU_CORE): CORE_CSR gives dbg_enter priority over trap_en as well, so
#     either one alone keeps mepc and mcause as they were
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
"11#CPU_CORE/CORE_RF/CORE_RF.sv#s/else if (wr_a \&\& (rs1 == rd))       rs1_data = rd_data;/else if (1'b0)                      rs1_data = rd_data;/#RF: no write first bypass on the first read port"
"12#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/                        imm      = imm_s;/                        imm      = imm_i;/#decoder: a store uses the I type immediate"
"13#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/2'd1:    ext = r_signed ? {{48{d_resp_data\[15\]}}, d_resp_data\[15:0\]}/2'd1:    ext = r_signed ? {{48{d_resp_data[7]}}, d_resp_data[15:0]}/#LSU: LH sign extends from the wrong bit"
"14#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign d_req_cmd   = m_valid ? m_cmd   : e_cmd;/assign d_req_cmd   = 4'd0;/#LSU: a store is issued as a load"
"15#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign e_accept = e_valid \& ~m_valid \& d_req_ready;/assign e_accept = e_valid \& ~m_valid;/#LSU: an access from EX counts as issued although the cache did not take it"
"16#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign i_kill      = redirect_valid . self_redirect;%assign i_kill      = 1'b0;%#IFU: the cache is not told about a redirect"
"17#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p1, p0};/assign fq_insn   = fq_is_rvc ? {16'd0, p0} : {p0, p1};/#IFU: the two parcels of a 32 bit instruction are swapped"
"18#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (fwd_a_ma) ex_a_fwd = ma_fwd_data;/else if (1'b0) ex_a_fwd = ma_fwd_data;/#core: no forwarding from MA into the first operand"
"19#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (fwd_b_wb) ex_b_fwd = wb_data;/else if (1'b0) ex_b_fwd = wb_data;/#core: no forwarding from WB into the second operand"
"20#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_fwd_data = (ma_mem \& ma_is_load) ? lsu_resp_data : ma_result;/assign ma_fwd_data = ma_result;/#core: a load in MA forwards its address"
"21#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs1_data <= ex_a_fwd;/                ex_rs1_data <= ex_rs1_data;/#core: a stalled EX does not keep the forwarded operand"
"22#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs2_data <= ex_b_fwd;/                ex_rs2_data <= ex_rs2_data;/#core: a stalled EX does not keep the forwarded store data"
"23#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign stall_mr      = stall_ma;/assign stall_mr      = 1'b0;/#core: MR moves on while MA waits for the cache"
"24#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ma_valid   <= 1'b0;/                ma_valid   <= ma_valid;/#core: MA is not emptied by a flush (what MR held retires as a no-op; t07 counts minstret)"
"25#CPU_CORE/CPU_CORE/CPU_CORE.sv#s@                wb_valid <= 1'b0;       // MA keeps its instruction : bubble@                wb_valid <= wb_valid;@#core: WB keeps its instruction while MA waits and retires it again"
"26#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_valid      <= id_advance \& fq_valid \& ~redirect_valid;/                ex_valid      <= id_advance \& fq_valid;/#core: the instruction behind a taken branch is not killed"
"27#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|id_exc_cause = EXC_ECALL_U + {3'd0, priv};|id_exc_cause = EXC_BREAK;|#core: ECALL is reported as a breakpoint"
"28#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign pop_q     = fq_valid \& fq_ready;/assign pop_q     = fq_valid;/#IFU: the fetch queue drops an instruction that ID could not take"
"77#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                       \& ~serial_busy \& ~wfi_wait \& ~dbg_halted \& ~id_gpr_wait;/                       \& ~wfi_wait \& ~dbg_halted \& ~id_gpr_wait;/#core: the instruction behind a CSR write is decoded with the old mstatus.FS"
"78#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign fpu_in_valid = fpu_active \& ex_advance \& ~kill_ex \& ~flush;/assign fpu_in_valid = fpu_active \& ex_advance \& ~flush;/#core: an FP operation is handed to the FPU in the cycle a late branch throws it away (t33)"
"79#CPU_CORE/CPU_CORE/CPU_CORE.sv#/assign mdu_start/s/ \& ~stall_ma \&/ \&/#core: the multiplier starts before the load in front of it has answered"
"80#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                         (dec_is_fp \& fp_off) ||/                         (1'b0) ||/#core: an FP instruction is allowed although mstatus.FS is off"
"81#CPU_FPU/FPU_ROUND/FPU_ROUND.sv#s/        flags\[1\] = tiny \& inexact \& ~overflow;              \/\/ UF/        flags[1] = 1'b0;/#FPU: underflow is never reported"
"82#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_load_data  = ma_fp_box ? {32'hFFFF_FFFF, lsu_resp_data\[31:0\]}/assign ma_load_data  = 1'b0 ? {32'hFFFF_FFFF, lsu_resp_data[31:0]}/#core: FLW does not NaN box what it loaded"
"83#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/mr_wdata      <= ex_is_fp_store ? ex_fs2_fwd : ex_b_fwd;/mr_wdata      <= ex_b_fwd;/#core: the store data of FSD comes from the integer file"
"84#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/            if (fflags_we) fflags <= fflags | fflags_set;/;/#CSR: fflags does not accumulate"
"85#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|        mstatus_val\[14:13\] = mstatus_fs;|        mstatus_val[14:13] = 2'b11;|#CSR: mstatus.FS always reads as dirty"
"86#CPU_FPU/FPU_ROUND/FPU_ROUND.sv#s/            RM_RNE:  inc = guard \& (rest | lsb);/            RM_RNE:  inc = guard;/#FPU: round to nearest never breaks a tie to even"
"87#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/        ex_rm_eff = (ex_fp_rm == 3'b111) ? frm_csr : ex_fp_rm;/        ex_rm_eff = ex_fp_rm;/#core: the dynamic rounding mode ignores frm"
"88#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                                    | fp_wait;/                                    | 1'b0;/#core: EX does not wait for the FPU (t33)"
"89#CPU_CORE/CORE_FRF/CORE_FRF.sv#s/if (we   \&\& (r == rd))    return rd_data;/;/#FRF: no write first bypass for the writes of the pipeline (FLD)"
"90#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/        else if (ex_use_fs1 \&\& ma_valid \&\& ma_fp_we \&\& (ma_fp_rd == ex_fs1)) ex_fs1_fwd = ma_fp_fwd_data;/        else if (1'b0) ex_fs1_fwd = ma_fp_fwd_data;/#core: no forwarding of a floating point result from MA"
"29#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|mstatus_val\[12:11\] = mstatus_mpp;|mstatus_val[12:11] = 2'b11;|#CSR: mstatus.MPP always reads as machine mode"
"30#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_mpie <= mstatus_mie;/mstatus_mpie <= 1'b0;/#CSR: a trap does not save the interrupt enable in MPIE"
"31#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_mie  <= mstatus_mpie;/mstatus_mie  <= 1'b0;/#CSR: MRET does not put the interrupt enable back"
"32#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/CSR_MEPC      : mepc       <= {wr_data\[63:1\], 1'b0};/CSR_MEPC      : mepc       <= wr_data;/#CSR: mepc keeps the low bits of the written value"
"33#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign trap_vector = (tvec_sel\[1:0\] == 2'b01) \&\& trap_int|assign trap_vector = 1'b0 \&\& trap_int|#CSR: the vectored mode of mtvec is ignored"
"34#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|if      (irq_deliver\[IRQ_M_EXT\])   irq_cause = 5'(IRQ_M_EXT);|if      (irq_deliver[IRQ_M_TIMER]) irq_cause = 5'(IRQ_M_TIMER);|#CSR: the timer interrupt is reported before the external one"
"35#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/assign ex_readonly = (ex_addr\[11:10\] == 2'b11);/assign ex_readonly = 1'b0;/#CSR: writing a read only CSR is allowed"
"36#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|                ex = ((a\[4:0\] >= 5'd3) \&\&|                ex = 1'b1 \|\| ((a[4:0] >= 5'd3) \&\&|#CSR: a CSR that does not exist answers instead of trapping"
"37#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (instret_inc \&\& !inhibit_ir \&\& !ir_filt) minstret <= minstret + 64'd1;%%#CSR: minstret does not count"
"38#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|assign m_enabled   = (priv_r != PRIV_M) . mstatus_mie;|assign m_enabled   = 1'b1;|#CSR: an interrupt is taken although mstatus.MIE is clear"
"39#CPU_CLINT/CPU_CLINT.sv#s/mtimecmp\[cmp_safe\] <= merge(mtimecmp\[cmp_safe\], wdata, wstrb);/;/#CLINT: mtimecmp cannot be written"
"40#CPU_CLINT/CPU_CLINT.sv#s/assign irq_m_soft = msip;/assign irq_m_soft = '0;/#CLINT: the software interrupt never reaches the core"
"42#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/end else if (irq_req \&\& !dec_is_wfi \&\& !step_active) begin/end else if (irq_req \&\& !step_active) begin/#core: the interrupt is taken on the WFI itself, so mepc points at it"
"43#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                                       dec_is_fence_i) \& pipe_busy)/                                       dec_is_fence_i) \& 1'b0)/#core: a CSR access is issued into a pipeline that is not empty"
"44#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/    assign wfi_wait    = fq_valid \& dec_is_wfi \& ~irq_any \& ~step_active \& ~dbg_haltreq;/    assign wfi_wait    = 1'b0;/#core: WFI does not wait"
"45#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            2'd3:    misaligned = |mem_addr\[2:0\];/            2'd3:    misaligned = 1'b0;/#core: a misaligned double word is not detected"
"46#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign mr_is_mem     = mr_valid \& mr_mem \& ~mr_exc;%assign mr_is_mem     = mr_valid \& mr_mem;%#core: an instruction that trapped still touches memory"
"146#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign ex_mmu_wait   = d_tr_req \& ~d_tr_ready \& ~flush;%assign ex_mmu_wait   = 1'b0;%#core: an access leaves EX before its address is translated"
"47#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign trap_epc_c   = ma_pc;/assign trap_epc_c   = ma_pc + 64'd4;/#core: mepc points behind the instruction that trapped"
"48#CPU_CORE/CPU_CORE/CPU_CORE.sv#s|                                             : {32'd0, ex_insn};|                                             : 64'd0;|#core: mtval of an illegal CSR access is empty"
"49#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/csr_wr = (funct3\[1:0\] == 2'b01) || (rs1 != 5'd0);/csr_wr = 1'b1;/#decoder: CSRRS with x0 writes the CSR"
"50#CPU_CORE/CORE_DEC/CORE_DEC.sv#s|12'h302: begin is_mret   = 1'b1; sys_noarg = 1'b1; end|12'h302: illegal = 1'b1;|#decoder: MRET is not known"
"51#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/OP_MULH:            begin a_signed = 1'b1; b_signed = 1'b1; end/OP_MULH:            begin a_signed = 1'b0; b_signed = 1'b0; end/#MDU: MULH multiplies unsigned"
"52#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/corr  <= ((a_signed \& a_prep\[63\]) ? b_prep : 64'd0) +/corr  <= ((1'b0) ? b_prep : 64'd0) +/#MDU: the sign of the first operand is not corrected"
"53#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/                            quo_r <= {64{1'b1}};/                            quo_r <= 64'd0;/#MDU: a division by zero answers zero"
"54#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/                            quo_r <= a_prep;                 \/\/ overflow/                            quo_r <= 64'd0;/#MDU: the one overflow of a division is not special"
"55#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/quo_neg <= a_signed \& (a_prep\[63\] ^ b_prep\[63\]);/quo_neg <= 1'b0;/#MDU: the quotient keeps no sign"
"56#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/rem_neg <= a_signed \& a_prep\[63\];/rem_neg <= a_signed \& b_prep[63];/#MDU: the remainder takes the sign of the divisor"
"57#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/assign width    = word_r ? 7'd32 : 7'd64;/assign width    = 7'd64;/#MDU: the 32 bit forms divide over 64 steps"
"58#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/{64'd0, a_mag\[31:0\], 32'd0}/{64'd0, a_mag}/#MDU: the dividend of a 32 bit form is not moved up"
"258#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/assign mid_lo = pp_hl\[31:0\] + pp_lh\[31:0\];/assign mid_lo = pp_hl[31:0];/#MDU: the low half of MUL leaves out one middle product"
"259#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/if (op_r == OP_MUL) mul_result = word_r ? {{32{mul_lo\[31\]}}, mul_lo\[31:0\]} : mul_lo;/if (op_r == OP_MUL) mul_result = word_r ? {32'd0, mul_lo[31:0]} : mul_lo;/#MDU: MULW does not extend the sign"
"260#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/assign done   = ((state == S_MUL) \&\& (op_r == OP_MUL)) || (state == S_MULH) ||/assign done   = (state == S_MUL) || (state == S_MULH) ||/#MDU: MULH is answered before its high half is summed"
"261#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/                    if (op_r == OP_MUL) begin/                    if (1'b0) begin/#MDU: MUL takes the long way (one cycle slower, same result)"
"262#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/assign skip     = (skip_raw > width - 7'd1) ? width - 7'd1 : skip_raw;/assign skip     = 7'd0;/#MDU: a divide skips nothing (right, but slow)"
"263#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/assign skip_raw = dvd_lz + (7'd63 - dvs_lz);/assign skip_raw = dvd_lz + (7'd64 - dvs_lz);/#MDU: a divide skips one step too many"
"264#CPU_CORE/CORE_MDU/CORE_MDU.sv#s/assign skip     = (skip_raw > width - 7'd1) ? width - 7'd1 : skip_raw;/assign skip     = (skip_raw > width) ? width : skip_raw;/#MDU: a divide may skip every step"
"265#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            if (kill_ex) begin/            if (1'b0) begin/#core: a late branch that guessed wrong leaves EX and MR as they are"
"266#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign late_a   = mr_late_a ? ma_fwd_data : mr_br_a;/assign late_a   = mr_br_a;/#core: a late branch compares rs1 as EX had it, not the load"
"267#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign late_b   = mr_late_b ? ma_fwd_data : mr_wdata;/assign late_b   = mr_wdata;/#core: a late branch compares rs2 as EX had it, not the load"
"268#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign kill_ex      = mr_late_go \& mr_late_miss;/assign kill_ex      = 1'b0;/#core: a late branch never redirects"
"269#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/mr_late_a     <= ex_late \& (mr_rd == ex_rs1);/mr_late_a     <= ex_late \& (mr_rd == ex_rs2);/#core: a late branch takes the load for the wrong operand"
"270#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            .kill     (flush | kill_ex),/            .kill     (flush),/#core: a divide behind a late branch that guessed wrong goes on"
"271#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/~ex_ctrl_done \& ~flush \& ~ex_late \& ~mr_late_pend;/~ex_ctrl_done \& ~flush \& ~ex_late;/; s/assign ctrl_behind_late = ex_valid \& ex_is_ctrl \& ~ex_ctrl_done \& mr_late_pend;/assign ctrl_behind_late = 1'b0;/#core: a branch in EX does not wait for a late branch in MR"
"272#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                                       dec_is_sfence | dec_is_fence |/                                       dec_is_sfence |/#core: a FENCE does not wait for the accesses in front of it"
"273#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%a_zx  = a_uw ? {32'd0, op_a\[31:0\]} : op_a;%a_zx  = op_a;%#EXU: the .uw forms of Zba use all of rs1"
"274#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%a_add = a_zx << a_shift;%a_add = a_zx;%#EXU: sh1add .. sh3add do not shift"
"275#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_ANDN: res = op_a \& ~op_b;%ALU_ANDN: res = op_a \& op_b;%#EXU: ANDN does not invert rs2"
"276#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_XNOR: res = ~(op_a ^ op_b);%ALU_XNOR: res = op_a ^ op_b;%#EXU: XNOR is XOR"
"277#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_MIN:  res = (\$signed(op_a) < \$signed(op_b)) ? op_a : op_b;%ALU_MIN:  res = (op_a < op_b) ? op_a : op_b;%#EXU: MIN compares unsigned"
"278#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_MAXU: res = (op_a < op_b) ? op_b : op_a;%ALU_MAXU: res = (\$signed(op_a) < \$signed(op_b)) ? op_b : op_a;%#EXU: MAXU compares signed"
"279#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%rot_r = {32'd0, (a32 >> shamt\[4:0\]) | (a32 << (6'd32 - {1'b0, shamt\[4:0\]}))};%rot_r = {32'd0, (a32 >> shamt[4:0])};%#EXU: RORW / RORIW do not wrap around"
"280#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%a_cnt = word_op ? {a32, 32'hFFFF_FFFF} : op_a;%a_cnt = op_a;%#EXU: CLZW counts in the whole register"
"281#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%n_ctz = word_op ? count_tz({32'hFFFF_FFFF, a32}) : count_tz(op_a);%n_ctz = count_tz(op_a);%#EXU: CTZW counts past bit 31"
"282#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%n_pop = word_op ? count_ones({32'd0, a32}) : count_ones(op_a);%n_pop = count_ones(op_a);%#EXU: CPOPW counts the upper half too"
"283#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%{8{|op_a\[8\*i +: 8\]}}%{8{\&op_a[8*i +: 8]}}%#EXU: ORC.B fills a byte only when all its bits are set"
"284#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%op_a\[8\*(7-i) +: 8\]%op_a[8*i +: 8]%#EXU: REV8 does not reverse"
"285#CPU_CORE/CORE_DEC/CORE_DEC.sv#s%if (rs2 != 5'd0) illegal = 1'b1;            // PACKW (Zbkb)%%#decoder: PACKW (Zbkb) is taken for ZEXT.H"
"286#CPU_CORE/CORE_DEC/CORE_DEC.sv#s%word_op = 1'b0;                         // a 64 bit result%word_op = 1'b1;%#decoder: SLLI.UW gives a 32 bit result"
"287#CPU_CORE/CORE_DEC/CORE_DEC.sv#s%^                        a_uw = 1'b1; word_op = 1'b0;$%                        a_uw = 1'b1;%#decoder: ADD.UW gives a 32 bit result"
"288#CPU_CORE/CORE_DEC/CORE_DEC.sv#s%12'h605: alu_op = ALU_SEXTH;%12'h605: alu_op = ALU_SEXTB;%#decoder: SEXT.H is decoded as SEXT.B"
"289#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%mip_val\[IRQ_S_TIMER\]  = menvcfg_stce ? stip_cmp : mip_stip;%mip_val[IRQ_S_TIMER]  = mip_stip;%#CSR: with STCE the supervisor timer is still the bit M writes"
"290#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%stip_cmp <= (mtime >= stimecmp);%stip_cmp <= (mtime < stimecmp);%#CSR: the stimecmp comparison the wrong way round"
"291#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%dn = (lvl != PRIV_M) \& (~stce | ~mcen\[1\]);%dn = (lvl != PRIV_M) \& ~mcen[1];%#CSR: S mode reaches stimecmp without STCE"
"292#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%dn = (lvl != PRIV_M) \& (~stce | ~mcen\[1\]);%dn = (lvl != PRIV_M) \& ~stce;%#CSR: S mode reaches stimecmp without mcounteren.TM"
"293#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (!menvcfg_stce) mip_stip <= wr_data\[IRQ_S_TIMER\];%mip_stip <= wr_data[IRQ_S_TIMER];%#CSR: M writes the STIP bit while STCE owns it"
"294#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (!inhibit_cy \&\& !cy_filt)                mcycle   <= mcycle + 64'd1;%if (!cy_filt) mcycle   <= mcycle + 64'd1;%#CSR: mcountinhibit.CY does not stop mcycle"
"295#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (instret_inc \&\& !inhibit_ir \&\& !ir_filt) minstret <= minstret + 64'd1;%if (instret_inc \&\& !ir_filt) minstret <= minstret + 64'd1;%#CSR: mcountinhibit.IR does not stop minstret"
"296#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%CSR_MCOUNTINHIBIT: rd_data = {32'd0, hpm_inh\[31:3\], inhibit_ir, 1'b0, inhibit_cy};%CSR_MCOUNTINHIBIT: rd_data = {32'd0, hpm_inh[31:3], inhibit_ir, inhibit_cy, inhibit_cy};%#CSR: mcountinhibit shows a TM bit (it has none)"
"297#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%            CSR_MENVCFG   : rd_data = {menvcfg_stce, 63'd0};%%#CSR: no menvcfg (OpenSBI would see version 1.11 and no Sstc)"
"298#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(trig_cfg\[8\*i+6\] | (priv != 2'b11) | tcontrol_mte)%1'b1%#trig: a breakpoint fires in M mode with tcontrol.MTE clear (t30)"
"299#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(priv == 2'b01) ? trig_cfg\[8\*i+4\] : trig_cfg\[8\*i+3\]%(priv == 2'b01) ? trig_cfg[8*i+3] : trig_cfg[8*i+4]%#trig: the s and u bits swapped (t30)"
"300#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(~mr_exc_r | mr_exc_mem) \&%~mr_exc_r \&%#trig: a misaligned access is reported before its breakpoint (t30)"
"301#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%((trig_cfg\[8\*i+0\] \& mr_is_load) | (trig_cfg\[8\*i+1\] \& mr_is_store))%((trig_cfg[8*i+1] \& mr_is_load) | (trig_cfg[8*i+0] \& mr_is_store))%#trig: load and store triggers swapped (t30)"
"302#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%id_exc_int   = |(id_thit \& trig_dbg);%id_exc_int   = 1'b0;%#trig: an execute trigger of the debugger raises a breakpoint instead of halting (t23)"
"303#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%mr_exc_int   = |(mr_dthit \& trig_dbg);%mr_exc_int   = 1'b0;%#trig: a load trigger of the debugger raises a breakpoint instead of halting (t23)"
"304#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign trig_fired   = trap_taken ? ma_trig : '0;%assign trig_fired   = mr_trig;%#trig: hit set by a match on a path that is thrown away (t30)"
"305#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign trig_fired   = trap_taken ? ma_trig : '0;%assign trig_fired   = '0;%#trig: hit never set (t23, t30)"
"306#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%ma_trig       <= mr_trig;%ma_trig       <= mr_trig_r;%#trig: hit of a load or store trigger lost (t23, t30)"
"307#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%id_exc_cause = id_exc_int ? {2'b10, 3'd2} : EXC_BREAK;%id_exc_cause = id_exc_int ? {2'b10, 3'd1} : EXC_BREAK;%#trig: an execute trigger halts with dcsr.cause ebreak (t23)"
"308#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%                          (fq_pc == trig_addr\[64\*i +: 64\]);%                          (fq_pc[63:2] == trig_addr[64*i+2 +: 62]);%#trig: an execute trigger matches a whole word, not the address (t30)"
"309#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%                    tc_mte       <= 1'b0;%                    tc_mte       <= tc_mte;%#trig: a trap leaves tcontrol.MTE set, a trigger fires in its own handler (t30)"
"310#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%                tc_mte       <= tc_mpte;%                tc_mte       <= tc_mte;%#trig: MRET does not put tcontrol.MTE back (t30)"
"311#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%t_dmode \[tselect\] <= dbg_access \& wr_data\[59\];%t_dmode [tselect] <= wr_data[59];%#trig: the program sets dmode (t30)"
"312#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%assign t_writable = ~t_dmode\[tselect\] | dbg_access;%assign t_writable = 1'b1;%#trig: the program changes a trigger of the debugger (t23)"
"313#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (wr_data < 64'(TRIGGERS))%if (1'b1)%#trig: tselect takes a trigger that does not exist (t30)"
"314#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%t_hit    <= t_hit | trig_fired;%t_hit    <= t_hit;%#trig: hit never set in the CSR (t23, t30)"
"315#CPU_CORE/CORE_DEC/CORE_DEC.sv#s%{7'b0000111, 3'b101}: alu_op = ALU_CZEQZ;%{7'b0000111, 3'b101}: alu_op = ALU_CZNEZ;%#Zicond: czero.eqz decoded as czero.nez (t31)"
"316#CPU_CORE/CORE_DEC/CORE_DEC.sv#s%{7'b0000111, 3'b111}: alu_op = ALU_CZNEZ;%{7'b0000111, 3'b111}: illegal = 1'b1;%#Zicond: czero.nez illegal (t31)"
"317#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_CZEQZ:res = (op_b == 64'd0) ? 64'd0 : op_a;%ALU_CZEQZ:res = (op_b[31:0] == 32'd0) ? 64'd0 : op_a;%#Zicond: czero.eqz looks at the low half of rs2 only (t31)"
"318#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_CZNEZ:res = (op_b != 64'd0) ? 64'd0 : op_a;%ALU_CZNEZ:res = (op_b != 64'd0) ? 64'd0 : op_b;%#Zicond: czero.nez gives rs2 instead of rs1 (t31)"
"319#CPU_CORE/CORE_EXU/CORE_EXU.sv#s%ALU_CZNEZ:res = (op_b != 64'd0) ? 64'd0 : op_a;%ALU_CZNEZ:res = (op_b[0]) ? 64'd0 : op_a;%#Zicond: czero.nez tests bit 0 of rs2 only (t31)"
"320#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (hpm_ev_q\[hpm_sel\[i\]\] \&\& !inhibit_hpm\[i\] \&\&%if (hpm_ev_q[hpm_sel[i]] \&\&%#PMU: mcountinhibit does not stop the event counters (t32)"
"321#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%!((hpm_priv_q == PRIV_M) ? hpm_minh\[i\] :%!((hpm_priv_q == PRIV_M) ? 1'b0 :%#PMU: MINH ignored (t32)"
"322#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%(hpm_priv_q == PRIV_S) ? hpm_sinh\[i\] : hpm_uinh\[i\])) begin%(hpm_priv_q == PRIV_S) ? hpm_sinh[i] : 1'b0)) begin%#PMU: UINH ignored (t32)"
"323#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (!hpm_of\[i\]) mip_lcofip <= 1'b1;%if (1'b0) mip_lcofip <= 1'b1;%#PMU: an overflow raises no interrupt (t32)"
"324#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (!hpm_of\[i\]) mip_lcofip <= 1'b1;%if (1'b1) mip_lcofip <= 1'b1;%#PMU: a wrap with OF already set raises the interrupt again (t32)"
"325#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%MIDELEG_MASK = 64'h0000_0000_0000_2222;%MIDELEG_MASK = 64'h0000_0000_0000_0222;%#PMU: the overflow interrupt cannot be delegated (t12, t32)"
"326#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%((priv_r == PRIV_M) ? 32'hFFFF_FFFF : mcounteren)%32'hFFFF_FFFF%#PMU: scountovf not masked by mcounteren below M (t32)"
"327#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (a\[11:5\] == 7'h60) dn = ctr_dn;%%#PMU: hpmcounterN readable below M whatever counteren says (t32)"
"328#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%hpm_sel\[i\]  <= (wr_data\[55:0\] < 56'(HPM_EVENTS))%hpm_sel[i]  <= 1'b1%#PMU: an event number that does not exist is kept (t32)"
"329#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%else                               irq_cause = 5'(IRQ_LCOF);%else                               irq_cause = 5'(IRQ_S_TIMER);%#PMU: the overflow interrupt reported as a timer interrupt (t32)"
"330#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (mideleg\[IRQ_LCOF\])   mip_lcofip <= wr_data\[IRQ_LCOF\];%%#PMU: S mode cannot clear LCOFIP through sip (t32)"
"331#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (mideleg\[IRQ_LCOF\])    mie_lcofie <= wr_data\[IRQ_LCOF\];%%#PMU: S mode cannot enable LCOF through sie (t32)"
"332#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%hpm_priv_q <= priv_r;%hpm_priv_q <= PRIV_M;%#PMU: every event taken for one of M mode (t32)"
"333#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[3\]  = commit \& ma_is_load; %assign hpm_ev[3]  = commit \& (ma_is_load | ma_is_store); %#PMU: stores counted as loads (t32)"
"334#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[5\]  = (ex_ctrl_go \& ex_is_branch) | mr_late_go;%assign hpm_ev[5]  = (ex_ctrl_go \& ex_is_branch);%#PMU: branches resolved in MR not counted (t32)"
"335#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[6\]  = (ex_ctrl_go \& ex_mispredict) | kill_ex;%assign hpm_ev[6]  = kill_ex;%#PMU: wrong guesses found in EX not counted (t32)"
"336#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[15\] = trap_en \& ~trap_int_c;%assign hpm_ev[15] = trap_en;%#PMU: interrupts counted as exceptions (t32)"
"337#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[16\] = trap_en \&  trap_int_c;%assign hpm_ev[16] = trap_en;%#PMU: exceptions counted as interrupts (t32)"
"341#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if      (ex_use_fs1 \&\& fpo_fp \&\& (fpu_out_rd == ex_fs1))/if      (1'b0)/#FPU: the answer is not forwarded to the first source the cycle it comes out (t33)"
"342#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/return use_fs \& fp_pend\[r\] \& ~(fpo_fp \& (fpu_out_rd == r));/return 1'b0;/#FPU: a source the FPU still owes is not waited for (t33)"
"343#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/fp_waw = ex_fp_we_rd \& fp_pend\[ex_rd\];/fp_waw = 1'b0;/#FPU: FLD writes a register the FPU still owes (t33)"
"344#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/(gpr_pend\[r\] | (ex_valid \& ex_fp_arith \& ex_we_rd \& (ex_rd == r)))/gpr_pend[r]/#FPU: ID does not see the integer register the operation in EX is about to owe (t33)"
"345#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/(dec_we_rd   \& gpr_owed(dec_rd)));/1'b0);/#FPU: an integer write overtakes the FPU's answer to the same register (t33)"
"346#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/.kill0         (flush),/.kill0         (1'b0),/#FPU: an operation in P0 behind FENCE.I is not taken back (t33)"
"347#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if (flush \&\& mr_valid \&\& mr_fpu) begin/if (1'b0) begin/#FPU: a register stays owed after its operation was taken back (t33)"
"348#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/| wb_valid | fpu_busy;/| wb_valid;/#FPU: a CSR instruction does not wait for the FPU to be empty (t33)"
"349#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/.fflags_set  (fpu_out_flags),/.fflags_set  (5'd0),/#FPU: the flags of the answers are lost (t11, t33)"
"350#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/.hold0         (stall_ma),/.hold0         (1'b0),/#FPU: P0 does not stop with MR (t33)"
"351#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/.we_b     (fpo_int),/.we_b     (1'b0),/#FPU: an integer answer is not written (t33)"
"352#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/.we_b     (fpo_fp),/.we_b     (1'b0),/#FPU: a floating point answer is not written"
"353#CPU_CORE/CORE_FRF/CORE_FRF.sv#s/return lvt\[r\] ? bank_b\[r\] : bank_a\[r\];/return bank_a[r];/#FRF: the live value table is not read"
"354#CPU_CORE/CORE_RF/CORE_RF.sv#s/rs1_data = lvt\[rs1\] ? bank_b\[rs1\] : bank_a\[rs1\];/rs1_data = bank_a[rs1];/#RF: the live value table is not read for rs1 (t33)"
"355#CPU_CORE/CORE_FRF/CORE_FRF.sv#s/if (we_b \&\& (r == rd_b))  return rd_data_b;/;/#FRF: a read in the cycle the FPU writes gets the old value (t33)"
"356#CPU_CORE/CORE_FRF/CORE_FRF.sv#s/if (we_b) lvt\[rd_b\] <= 1'b1;/;/#FRF: the live value table does not follow a write of the FPU"
"357#CPU_CORE/CORE_RF/CORE_RF.sv#s/else if (wr_b \&\& (rs1 == rd_b))     rs1_data = rd_data_b;/else if (1'b0)                      rs1_data = rd_data_b;/#RF: a read of rs1 in the cycle the FPU writes gets the old value (t33)"
"358#CPU_CORE/CORE_RF/CORE_RF.sv#s/rs2_data = lvt\[rs2\] ? bank_b\[rs2\] : bank_a\[rs2\];/rs2_data = bank_a[rs2];/#RF: the live value table is not read for rs2 (t33)"
"359#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/csr_check(ex_addr, 1'b0,/csr_check(ex_addr, 1'b1,/#CSR: a program reaches dcsr / dpc / dscratch (t05)"
"360#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/csr_check(rd_addr, dbg_access,/csr_check(rd_addr, 1'b0,/#debug: the debugger cannot reach dcsr / dpc / dscratch (t23)"
"338#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[2\]  = commit;%assign hpm_ev[2]  = commit | trap_en;%#PMU: a trap counted as a retired instruction (t32)"
"339#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (!inhibit_cy \&\& !cy_filt) %if (!inhibit_cy) %#Smcntrpmf: mcyclecfg does not stop mcycle (t32)"
"340#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%assign ir_filt = (priv_r == PRIV_M) ? ir_minh : (priv_r == PRIV_S) ? ir_sinh : ir_uinh;%assign ir_filt = (priv_r == PRIV_M) ? ir_minh : (priv_r == PRIV_S) ? ir_sinh : 1'b0;%#Smcntrpmf: UINH of minstretcfg ignored (t32)"
"253#CPU_CORE/CORE_BTB/CORE_BTB.sv#s/assign hit_taken  = look_d\[F_COND\] ? pht_look : look_d\[F_CNT + 1\];/assign hit_taken  = look_d[F_CNT + 1];/#BTB: no gshare, the counter of the entry decides"
"254#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/hist_s <= {hist_s\[HIST_BITS-2:0\], btb_taken};/hist_s <= hist_s;/#IFU: the fetch side keeps no history"
"255#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/(btb_upd_valid \&\& btb_upd_cond \&\& btb_known)/(btb_upd_valid \&\& btb_upd_cond)/#IFU: the execute side also counts branches without an entry"
"256#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/                hist_s   <= hist_a_next;//#IFU: a redirect does not put the history right"
"257#CPU_CORE/CORE_BTB/CORE_BTB.sv#s/assign pht_upd_idx  = pht_index(upd_word, upd_hist);/assign pht_upd_idx  = pht_index(upd_word, look_hist);/#BTB: the update takes the fetch side's history"
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
"100#CPU_CORE/CORE_CSR/CORE_CSR.sv#s|if (a\[9:8\] > lvl) dn = 1'b1;|if (1'b0) dn = 1'b1;|#CSR: the privilege of a CSR address is not checked"
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
"174#CPU_CORE/CORE_BTB/CORE_BTB.sv#s%assign spans    = upd_is32 \&\& (upd_off == 2'b11);%assign spans    = 1'b0;%#BTB: a 32 bit branch across two words is allocated on its own word, not as a tail"
"175#CPU_CORE/CORE_BTB/CORE_BTB.sv#s%                              upd_cond, upd_target, new_cnt }%                              upd_cond, upd_d[F_TARGET +: 64], new_cnt }%#BTB: the target of an entry that is hit again is not kept up to date"
"177#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%: (btb_off >= next_start));%: 1'b1);%#IFU: a prediction is used even when the branch is before the address jumped to"
"178#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign straddle      = fq_have \& ~fq_is_rvc \& d0;%assign straddle      = 1'b0;%#IFU: the misfetch of a trim inside an instruction is not caught"
"179#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign fq_pred_taken  = fq_is_rvc ? d0 : d1;%assign fq_pred_taken  = d0;%#IFU: the prediction of a 32 bit instruction is read from its first parcel"
"180#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%2'd0 : (btb_off + {1'b0, btb_is32});%2'd0 : (btb_off);%#IFU: the trim keeps only the first half of a 32 bit branch"
"181#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%head_pc <= fq_pred_target;%head_pc <= head_pc + 64'd4;%#IFU: the head does not follow a prediction to its target"
"182#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%push_pc <= pred_resp ? pr_target\[pr_head\]%push_pc <= pred_resp ? 64'd0%#IFU: the push address after a prediction is wrong"
"183#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(take_branch \& (target_pc != ex_pred_target))%1'b0%#core: a prediction to the wrong target is not put right"
"184#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%((take_branch != ex_pred_taken) .%(1'b0 |%#core: a branch that was predicted wrongly is not put right"
"185#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%redirect_pc = take_branch ? target_pc : ex_seq_pc;%redirect_pc = target_pc;%#core: a wrong taken prediction does not go back to the next instruction"
"187#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign btb_upd_is32   = mr_late_pend ? ~mr_is_rvc    : ~ex_is_rvc;%assign btb_upd_is32   = 1'b0;%#core: the buffer is told every branch is compressed"
"188#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign nx_rs1   = ex_advance ? (dec_use_rs1 ? dec_rs1 : 5'd0) : ex_rs1;%assign nx_rs1   = dec_use_rs1 ? dec_rs1 : 5'd0;%#core: the forwarding select of a stalled EX looks at the operands of the next instruction"
"189#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else                 nx_ma_wr = ma_valid \& ma_we_rd;%else                 nx_ma_wr = 1'b0;%#core: the forwarding select forgets a load that waits in MA"
"190#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%nx_ma_wr = nx_ma_wr \& (nx_ma_rd != 5'd0);%nx_ma_wr = nx_ma_wr;%#core: a result written to x0 is forwarded from MA"
"192#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else if (ex_advance) nx_mr_wr = ex_valid \& ex_we_rd \& ~ex_exc \& ~ex_mem \& ~ex_fp_arith;%else if (ex_advance) nx_mr_wr = ex_we_rd \& ~ex_exc \& ~ex_mem \& ~ex_fp_arith;%#core: the forwarding select from MR does not check that the instruction is there"
"193#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%                mr_refetch    <= (ex_pred_taken \& ~ex_is_ctrl) | ex_csr_fetch;%                mr_refetch    <= ex_csr_fetch;%#core: a non branch predicted taken is not refetched"
"194#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else if (fencei_taken || sfence_taken || refetch_taken)%else if (fencei_taken || sfence_taken)%#core: the refetch goes to where EX says, not behind the instruction"
"195#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign refetch_taken = ma_valid \& ma_refetch \& ~stall_ma \& ~trap_taken;%assign refetch_taken = ma_valid \& ma_refetch \& ~trap_taken;%#core: the refetch does not wait for the load it belongs to"
"196#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign lu_hazard = ex_valid \& (lu_int | lu_fp) \& ~flush \& ~ex_late;%assign lu_hazard = ex_valid \& lu_fp \& ~flush \& ~ex_late;%#core: no load-use interlock on an integer register"
"197#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign lu_hazard = ex_valid \& (lu_int | lu_fp) \& ~flush \& ~ex_late;%assign lu_hazard = ex_valid \& lu_int \& ~flush \& ~ex_late;%#core: no load-use interlock on a floating point register"
"198#CPU_CORE/CPU_CORE/CPU_CORE.sv#/assign mdu_start/{n;s/~lu_hazard;/1'b1;/}#core: the multiplier starts while its operand is a load in MR"
"199#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%mr_exc_cause = mr_is_store ? EXC_SFAULT : EXC_LFAULT;%mr_exc_cause = EXC_LFAULT;%#core: a store refused by the PMP is reported as a load"
"202#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign ex_ctrl_go = ex_valid \& ex_is_ctrl \& ~stall_ma \& ~lu_hazard \&%assign ex_ctrl_go = ex_valid \& ex_is_ctrl \& ~stall_ma \&%#core: a branch is decided before the load it reads has answered"
"203#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+assign ptw_pmp_fail = grant \& w_pmp_fail;+assign ptw_pmp_fail = 1'b0;+#MMU: the walker reads a page table the protection refuses"
"204#CPU_MMU/CORE_MMU/CORE_MMU.sv#s+            .priv     (ptw_priv),+            .priv     (2'b11),+#MMU: the walker's reads are checked as machine mode"
"205#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign cancel_q    = chk_valid \& pmp_fail \& ~self_redirect;%assign cancel_q    = 1'b0;%#IFU: a fetch the PMP refuses is not cancelled"
"206#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%((i_resp_error | resp_cancel) ? 2'd1 : 2'd0)%(i_resp_error ? 2'd1 : 2'd0)%#IFU: a cancelled fetch is answered without a fault"
"207#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%if (cancel_q) pr_cancel\[pr_tail - OS_BITS'(1)\] <= 1'b1;%%#IFU: a cancelled fetch is never answered"
"208#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign cancel_q    = chk_valid \& pmp_fail%assign cancel_q    = pmp_fail%#IFU: the PMP answer is taken when no request is being checked"
"209#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%mr_refetch    <= (ex_pred_taken \& ~ex_is_ctrl) | ex_csr_fetch;%mr_refetch    <= (ex_pred_taken \& ~ex_is_ctrl);%#core: a write of satp does not refetch what behind it was fetched untranslated"
"210#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%if (rd_addr == CSR_MIP) rmw_data\[IRQ_S_EXT\] = mip_seip;%;%#CSR: csrrs / csrrc of mip copy the PLIC line into the software SEIP bit"
"211#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%end else if (irq_req \&\& !dec_is_wfi \&\& !step_active) begin%end else if (irq_req \&\& !dec_is_wfi) begin%#debug: a single step takes a pending interrupt"
"212#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%\& ~step_active \& ~dbg_haltreq;%\& ~step_active;%#debug: a halt request does not end the wait of WFI"
"213#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%if (dbg_take \&\& !(dec_is_wfi \&\& dbg_take_cause == 3'd3)) begin%if (dbg_take) begin%#debug: a halt request halts in front of WFI, not behind it"
"214#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%end else if (dec_is_ebreak \&\& ebreak_dbg) begin%end else if (1'b0) begin%#debug: EBREAK ignores dcsr.ebreakm"
"216#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%if      (dbg_resume_now) redirect_pc = dpc;%if (dbg_resume_now) redirect_pc = dpc + 64'd4;%#debug: resume does not go to dpc"
"217#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%step_issued <= 1'b1;%step_issued <= 1'b0;%#debug: dcsr.step does not halt again"
"218#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%: {dra_old\[63:32\], dra_wdata\[31:0\]};%: {32'd0, dra_wdata[31:0]};%#debug: a 32 bit register write clears the upper half"
"219#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%if (halted_r) dra_state <= 2'd1;%if (1'b1) dra_state <= 2'd1;%#debug: registers are accessed while the hart runs"
"220#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%if (!dra_exists || (dra_wr \&\& dra_ro)) begin%if (!dra_exists) begin%#debug: a write to a read only CSR is not an error"
"221#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(dra_csr \& dbg_csr_exists)%dra_csr%#debug: every CSR number exists"
"222#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%dcsr_cause <= dbg_cause;%dcsr_cause <= 3'd3;%#debug: dcsr.cause is always haltreq"
"223#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%dpc        <= {dbg_pc\[63:1\], 1'b0};%dpc        <= dbg_pc + 64'd4;%#debug: dpc is the instruction behind the one halted on"
"224#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%if (boot_r) reset_halt_pend <= dbg_resethaltreq;%if (1'b0) reset_halt_pend <= dbg_resethaltreq;%#debug: resethaltreq is ignored"
"225#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%priv_r <= dcsr_prv;%priv_r <= priv_r;%#debug: resume ignores dcsr.prv"
"226#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%.fs_dirty    ((commit \& ma_is_fp) | dbg_frf_we)%.fs_dirty    (commit \& ma_is_fp)%#debug: a debugger write of an FPR leaves mstatus.FS clean"
"227#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign rf_ra1      = (dra_state != 2'd0) ? dbg_regno_q\[4:0\] : dec_rs1;%assign rf_ra1      = dec_rs1;%#debug: a GPR read takes the register of the instruction in ID"
"228#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%\& ~serial_busy \& ~wfi_wait \& ~dbg_halted \& ~id_gpr_wait;%\& ~serial_busy \& ~wfi_wait \& ~id_gpr_wait;%#debug: instructions issue while halted"
"229#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%.rd_addr     (dbg_csr_sel ? dbg_regno_q\[11:0\] : ex_csr_addr)%.rd_addr     (ex_csr_addr)%#debug: a CSR read takes the CSR of the instruction in EX"
"230#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%(reset_halt_pend | dbg_haltreq | step_issued)%(reset_halt_pend | step_issued)%#debug: haltreq is ignored"
"231#CPU_CORE/CORE_CSR/CORE_CSR.sv#s%CSR_DCSR      : if (dbg_access) begin%CSR_DCSR      : if (1'b0) begin%#debug: dcsr cannot be written"
"232#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%            ex_exc_tval = mem_addr;%            ex_exc_tval = ex_exc_tval_pre;%#core: a page fault of a load or a store reports no address in tval"
"233#CPU_CORE/CORE_BTB/CORE_BTB.sv#s%    assign allow   = upd_valid;%    assign allow   = upd_valid \&\& !spans;%#BTB: a branch across a fetch word gets no tail entry (t24)"
"234#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%(btb_tail ? (seq_fetch \& (next_start == 2'd0))%(btb_tail ? ((next_start == 2'd0))%#IFU: a tail entry is used in a word that was jumped into (t24)"
"235#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign pred_target = btb_ret ? ras_s\[sp_s - RAS_BITS'(1)\] : btb_target;%assign pred_target = btb_target;%#IFU: returns go where the buffer last saw them go, not to the stack (t24)"
"236#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%                sp_s     <= sp_a_next;%                sp_s     <= sp_s;%#IFU: a redirect leaves the fetch side's stack pointer where the wrong path left it"
"237#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%{61'd0, pred_last, 1'b0} + 64'd2;%{61'd0, pred_last, 1'b0};%#IFU: a predicted call pushes its own address instead of the one behind it"
"238#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign a_pop     = btb_upd_valid \& btb_upd_ret;%assign a_pop     = 1'b0;%#IFU: the stack of the execute stage never pops"
"239#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign btb_upd_ret  = ~mr_late_pend \& ex_is_jalr \& (ex_rd == 5'd0) \& ex_rs1_link;%assign btb_upd_ret  = 1'b0;%#core: no jalr is taken for a return"
"240#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign lsu_e_go    = mr_e_acc \& mr_valid \& ~mr_exc \& ~flush \&%assign lsu_e_go    = mr_e_acc \& mr_valid \& ~flush \&%#LSU: an access that MR refuses (PMP, fault, misaligned) goes all the same"
"241#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign lsu_e_go    = mr_e_acc \& mr_valid \& ~mr_exc \& ~flush \&%assign lsu_e_go    = mr_e_acc \& mr_valid \& ~mr_exc \&%#LSU: an access goes in the cycle MA flushes the pipeline"
"242#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%                         ~(ma_valid \& ma_mem \& ~ma_issued) \&%                         %#LSU: an access goes before an older one that was taken back (t03, t25)"
"243#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign mr_spec_ok  = (mr_cmd == 4'd0) \& (mr_paddr >= MEM_BASE);%assign mr_spec_ok  = (mr_paddr >= MEM_BASE);%#LSU: a store goes while the instruction in front can still trap (t25)"
"244#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign mr_spec_ok  = (mr_cmd == 4'd0) \& (mr_paddr >= MEM_BASE);%assign mr_spec_ok  = (mr_cmd == 4'd0);%#LSU: an uncached load goes while the instruction in front can still trap (t25)"
"245#CPU_CORE/CORE_LSU/CORE_LSU.sv#s%if (flush)                            drop <= os_next;%if (1'b0)                             drop <= os_next;%#LSU: an answer still in flight at a trap is handed to the next access (t25)"
"246#CPU_CORE/CORE_LSU/CORE_LSU.sv#s%assign d_req_paddr  = e_acc_q ? e_paddr\[PADDR_WIDTH-1:0\] : m_paddr_q;%assign d_req_paddr  = m_paddr_q;%#LSU: a request from EX gets the physical address of the last one from MA"
"247#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%else if (lsu_e_accept)    ex_e_blocked <= 1'b1;%else if (lsu_e_accept)    ex_e_blocked <= 1'b0;%#LSU: EX keeps issuing while it waits for the walker (which then never gets the port)"
"248#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%                ma_issued <= mr_issued;%                ma_issued <= 1'b0;%#LSU: an access that went from EX goes again from MA"
"250#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign older_done  = ~ma_valid | commit;%assign older_done  = 1'b1;%#LSU: a store goes while the instruction in front waits and may still trap (t25)"
"251#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign m_accept = m_valid \& d_req_ready;/assign m_accept = m_valid;/#LSU: an access from MA counts as issued although the cache did not take it"
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
$d/CPU/CPU_FPU/FPU_PIPE/FPU_PIPE.sv \
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

    # the multiply / divide unit also on its own bench (tb_MDU): operands
    # and cycle counts the programs do not reach
    if [[ $file == */CORE_MDU.sv ]]; then
        if verilator --binary --timing -j 2 -Wno-fatal --top-module tb_MDU -Mdir $d/obj_mdu \
               $R/CORE_MDU/CORE_MDU.sv tb_MDU.sv > $d/build_mdu.log 2>&1 &&
           timeout 300 ./$d/obj_mdu/Vtb_MDU +n=20000 2>&1 | grep -q "RESULT : PASS"; then
            passes=$((passes+1))
        else
            fails=$((fails+1))
        fi
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
