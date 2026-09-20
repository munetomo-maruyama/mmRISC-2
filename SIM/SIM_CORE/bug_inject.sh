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
#   - i_req_paddr / d_req_paddr, which the memory model ignores (there is no
#     MMU yet; the two address ports are exercised in SIM_CACHE section 15)
#   - a redirect issued while EX is stalled: the front end is redirected to
#     the same address again when EX finally moves on
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=bug_work
mkdir -p $WORK

# -j 2 (not -j 0): four mutations are built in parallel
VFLAGS="--binary --timing -j 2 --top-module tb_CORE -Wno-fatal"

# id # file # sed expression # description
MUTATIONS=(
"1#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/alu_op = insn\[30\] ? ALU_SRA : ALU_SRL;/alu_op = ALU_SRL;/g#decoder: SRAI / SRAIW become logical shifts"
"2#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/mem_signed = ~funct3\[2\];/mem_signed = 1'b1;/#decoder: LBU, LHU and LWU sign extend"
"3#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/mem_size   = funct3\[1:0\];/mem_size   = 2'd3;/#decoder: every access is a double word"
"4#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/ALU_SLT:  res = {63'd0, (\$signed(op_a) < \$signed(op_b))};/ALU_SLT:  res = {63'd0, (op_a < op_b)};/#EXU: SLT compares unsigned"
"5#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/3'b101:  take_branch = is_branch \& ~lt;/3'b101:  take_branch = is_branch \& lt;/#EXU: BGE takes the branch like BLT"
"6#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/assign link_pc  = pc + 64'd4;/assign link_pc  = pc;/#EXU: the link address of JAL and JALR is the PC itself"
"7#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/alu_result = word_op ? {{32{res\[31\]}}, res\[31:0\]} : res;/alu_result = res;/#EXU: the 32 bit result is not sign extended"
"8#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/shamt = word_op ? {1'b0, op_b\[4:0\]} : op_b\[5:0\];/shamt = op_b[5:0];/#EXU: a 32 bit shift uses six bits of shift amount"
"9#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/else                        sh_src = {32'd0, op_a\[31:0\]};/else                        sh_src = op_a;/#EXU: SRLW shifts the whole 64 bit register"
"10#CPU_CORE/CORE_EXU/CORE_EXU.sv#s/if (is_jalr) target_pc = (rs1_data + imm) \& ~64'd1;/if (is_jalr) target_pc = pc + imm;/#EXU: JALR jumps relative to the PC"
"11#CPU_CORE/CORE_RF/CORE_RF.sv#s/else if (wr_en \&\& (rs1 == rd))    rs1_data = rd_data;/else if (1'b0)                    rs1_data = rd_data;/#RF: no write first bypass on the first read port"
"12#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/                        imm      = imm_s;/                        imm      = imm_i;/#decoder: a store uses the I type immediate"
"13#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/2'd1:    ext = signed_r ? {{48{d_resp_data\[15\]}}, d_resp_data\[15:0\]}/2'd1:    ext = signed_r ? {{48{d_resp_data[7]}}, d_resp_data[15:0]}/#LSU: LH sign extends from the wrong bit"
"14#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign d_req_cmd   = req_is_store ? CMD_STORE : CMD_LOAD;/assign d_req_cmd   = CMD_LOAD;/#LSU: a store is issued as a load"
"15#CPU_CORE/CORE_LSU/CORE_LSU.sv#s/assign req_accept  = d_req_valid \& d_req_ready;/assign req_accept  = d_req_valid;/#LSU: the access counts as issued although the cache did not take it"
"16#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign i_kill      = redirect_valid;/assign i_kill      = 1'b0;/#IFU: the cache is not told about a redirect"
"17#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign resp_insn = resp_pc\[2\] ? i_resp_data\[63:32\] : i_resp_data\[31:0\];/assign resp_insn = i_resp_data[31:0];/#IFU: always takes the low half of the cache word"
"18#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if      (ma_valid \&\& ma_we_rd \&\& (ma_rd != 5'd0) \&\& (ma_rd == ex_rs1)) ex_a_fwd = ma_fwd_data;/if      (1'b0) ex_a_fwd = ma_fwd_data;/#core: no forwarding from MA into the first operand"
"19#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/else if (wb_valid \&\& wb_we_rd \&\& (wb_rd != 5'd0) \&\& (wb_rd == ex_rs2)) ex_b_fwd = wb_data;/else if (1'b0) ex_b_fwd = wb_data;/#core: no forwarding from WB into the second operand"
"20#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ma_fwd_data = (ma_mem \& ma_is_load) ? lsu_resp_data : ma_result;/assign ma_fwd_data = ma_result;/#core: a load in MA forwards its address"
"21#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs1_data <= ex_a_fwd;/                ex_rs1_data <= ex_rs1_data;/#core: a stalled EX does not keep the forwarded operand"
"22#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_rs2_data <= ex_b_fwd;/                ex_rs2_data <= ex_rs2_data;/#core: a stalled EX does not keep the forwarded store data"
"23#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign stall_ex      = stall_ma | (ex_is_mem \& ~lsu_accept \& ~flush);/assign stall_ex      = stall_ma;/#core: EX moves on although the cache did not take the access"
"24#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ma_valid   <= 1'b0;/                ma_valid   <= ma_valid;/#core: MA is not emptied when EX has nothing to hand over"
"25#CPU_CORE/CPU_CORE/CPU_CORE.sv#s@                wb_valid <= 1'b0;       // MA keeps its instruction : bubble@                wb_valid <= wb_valid;@#core: WB keeps its instruction while MA waits and retires it again"
"26#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_valid      <= id_advance \& fq_valid \& ~redirect_valid;/                ex_valid      <= id_advance \& fq_valid;/#core: the instruction behind a taken branch is not killed"
"27#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                id_exc_cause = EXC_ECALL_M;/                id_exc_cause = EXC_BREAK;/#core: ECALL is reported as a breakpoint"
"28#CPU_CORE/CORE_IFU/CORE_IFU.sv#s/assign pop_q    = fq_valid \& fq_ready;/assign pop_q    = fq_valid;/#IFU: the fetch queue drops an instruction that ID could not take"
"29#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_val\[12:11\] = 2'b11;/mstatus_val[12:11] = 2'b00;/#CSR: mstatus.MPP is not the only legal value"
"30#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_mpie <= mstatus_mie;/mstatus_mpie <= 1'b0;/#CSR: a trap does not save the interrupt enable in MPIE"
"31#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/mstatus_mie  <= mstatus_mpie;/mstatus_mie  <= 1'b0;/#CSR: MRET does not put the interrupt enable back"
"32#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/CSR_MEPC      : mepc       <= {wr_data\[63:2\], 2'b00};/CSR_MEPC      : mepc       <= wr_data;/#CSR: mepc keeps the low bits of the written value"
"33#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/assign trap_vector = (mtvec\[1:0\] == 2'b01) \&\& trap_int/assign trap_vector = 1'b0 \&\& trap_int/#CSR: the vectored mode of mtvec is ignored"
"34#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/if      (irq_active\[IRQ_M_EXT\])   irq_cause = 5'(IRQ_M_EXT);/if      (irq_active[IRQ_M_TIMER]) irq_cause = 5'(IRQ_M_TIMER);/#CSR: the timer interrupt is reported before the external one"
"35#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/assign rd_readonly = (rd_addr\[11:10\] == 2'b11);/assign rd_readonly = 1'b0;/#CSR: writing a read only CSR is allowed"
"36#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/default       : rd_exists = 1'b0;/default       : rd_exists = 1'b1;/#CSR: a CSR that does not exist answers instead of trapping"
"37#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/if (instret_inc) minstret <= minstret + 64'd1;/;/#CSR: minstret does not count"
"38#CPU_CORE/CORE_CSR/CORE_CSR.sv#s/assign irq_req    = irq_any \& mstatus_mie;/assign irq_req    = irq_any;/#CSR: an interrupt is taken although mstatus.MIE is clear"
"39#CPU_CLINT/CPU_CLINT.sv#s/mtimecmp <= merge(mtimecmp, wdata, wstrb);/;/#CLINT: mtimecmp cannot be written"
"40#CPU_CLINT/CPU_CLINT.sv#s/assign irq_m_soft  = msip;/assign irq_m_soft  = 1'b0;/#CLINT: the software interrupt never reaches the core"
"41#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign lsu_req_valid = ex_is_mem \& ~stall_ma \& ~flush;/assign lsu_req_valid = ex_is_mem \& ~stall_ma;/#core: the access behind a trapping instruction is still issued"
"42#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/if (irq_req \&\& !dec_is_wfi) begin/if (irq_req) begin/#core: the interrupt is taken on the WFI itself, so mepc points at it"
"43#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                                       dec_is_fence_i) \& pipe_busy)/                                       dec_is_fence_i) \& 1'b0)/#core: a CSR access is issued into a pipeline that is not empty"
"44#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/    assign wfi_wait    = fq_valid \& dec_is_wfi \& ~irq_any;/    assign wfi_wait    = 1'b0;/#core: WFI does not wait"
"45#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/            2'd3:    misaligned = |mem_addr\[2:0\];/            2'd3:    misaligned = 1'b0;/#core: a misaligned double word is not detected"
"46#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign ex_is_mem     = ex_valid \& (ex_is_load | ex_is_store) \& ~ex_exc;/assign ex_is_mem     = ex_valid \& (ex_is_load | ex_is_store);/#core: an instruction that trapped still touches memory"
"47#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/assign trap_epc_c   = ma_pc;/assign trap_epc_c   = ma_pc + 64'd4;/#core: mepc points behind the instruction that trapped"
"48#CPU_CORE/CPU_CORE/CPU_CORE.sv#s/                ex_exc_tval  = {32'd0, ex_insn};/                ex_exc_tval  = 64'd0;/#core: mtval of an illegal CSR access is empty"
"49#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/csr_wr = (funct3\[1:0\] == 2'b01) || (rs1 != 5'd0);/csr_wr = 1'b1;/#decoder: CSRRS with x0 writes the CSR"
"50#CPU_CORE/CORE_DEC/CORE_DEC.sv#s/12'h302: is_mret   = 1'b1;/12'h302: illegal   = 1'b1;/#decoder: MRET is not known"
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
    local SRCS="$R/CORE_DEC/CORE_DEC.sv $R/CORE_CSR/CORE_CSR.sv $R/CORE_RF/CORE_RF.sv \
$R/CORE_IFU/CORE_IFU.sv $R/CORE_EXU/CORE_EXU.sv $R/CORE_LSU/CORE_LSU.sv \
$R/CPU_CORE/CPU_CORE.sv $d/CPU/CPU_CLINT/CPU_CLINT.sv \
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
