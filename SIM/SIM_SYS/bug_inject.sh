#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : the bugs that only the real caches can show
#
#   ./bug_inject.sh [id ...]
#
# SIM_CORE answers the cache ports from one flat memory: there is no
# instruction cache to invalidate and no dirty line to write back, so a core
# that forgets either still passes every test there. fence.i was broken from
# M1 to M6 for exactly that reason and nothing noticed until the core was put
# behind CPU_CACHE.
#
# This campaign is therefore small on purpose. It carries the mutations whose
# detection depends on the caches being real; everything else belongs to
# SIM_CORE, which is far quicker.
#
# The programs come from SIM_CORE, and one riscv-test is added because
# rv64ui-p-fence_i is the sharpest of the lot. bench/fploop (make -C bench)
# is run as well for its cycle bounds: it is the one place a loss of
# cycles that changes no answer shows (M19).
#
# Not listed, because they cannot change what any program sees:
#   - a fetch going out in the cycle another is cancelled (IFU). The cache
#     drops it with the cancelled one, but it is younger than a fetch that
#     either traps or is thrown away by a branch first, so nobody waits for
#     its answer.
#   - a DMA write made an ordinary store instead of a write through. The
#     line is then allocated and left dirty, which the CPU sees just as
#     well; memory gets the value when the line is written back. The write
#     through is there so that memory has it at once, not for coherence.
#   - the L2 (CPU_L2) taking a read while beats of the last one still wait
#     in its R FIFO, or answering with the wrong ID. BUS_ARB in CPU_CACHE
#     holds the read channel until the last R beat and routes by its grant,
#     not by ID, so the L2 never sees a second read early and nobody looks
#     at the ID. SIM_L2 checks both with two readers of its own.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RTL=../../RTL
WORK=bug_work
RVTESTS=${RVTESTS:-$HOME/RISCV/riscv-tests}
PREFIX=/opt/riscv/bin/riscv64-unknown-elf-

VFLAGS="--binary --timing -j 2 --top-module tb_SYS -Wno-fatal -Wno-INITIALDLY"

# the programs "make run-all" runs, read from the Makefile
RUN_LIST="$(make -s -p -n 2>/dev/null | awk -F' := ' '/^TESTS := /{print $2}' | tr ' ' '\n' | sed 's|^|tests/|') \
$(make -s -p -n 2>/dev/null | awk -F' := ' '/^PROGS := /{print $2}' | tr ' ' '\n' | sed 's|^|progs/|')"

# id # file # sed expression # description
MUTATIONS=(
"1#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign ex_mem        = ex_is_load | ex_is_store | ex_is_fencei;%assign ex_mem        = ex_is_load | ex_is_store;%#core: fence.i does not write the data cache back"
"2#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign i_flush_valid = fencei_busy;%assign i_flush_valid = 1'b0;%#core: fence.i does not invalidate the instruction cache"
"3#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign fencei_taken = ma_valid \& ma_is_fencei \& ~stall_ma \& ~trap_taken;%assign fencei_taken = ma_valid \& ma_is_fencei \& ~trap_taken;%#core: the instruction cache is invalidated before the write back is done"
"4#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%\.e_paddr      (mr_paddr),%.e_paddr      (mr_vaddr),%#LSU: the cache is given the virtual address as a tag"
"5#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%if (push_req \&\& !redirect_valid) i_req_paddr <= tr_paddr\[PADDR_WIDTH-1:0\];%if (push_req \&\& !redirect_valid) i_req_paddr <= i_req_addr;%#IFU: the cache is given the virtual address as a tag"
"6#CPU_CACHE/ICACHE/ICACHE.sv#s%if (s1_valid \&\& (i_kill || i_cancel)) begin%if (s1_valid \&\& i_kill) begin%#I\$: a fetch the PMP refused still goes to memory"
"8#CPU_DMA/DMA_CACHE.sv#s%w_got <= 1'b1; w_q <= s_wdata; left <= s_wstrb;%w_got <= 1'b1; w_q <= s_wdata; left <= 8'hFF;%#DMA: the write strobes are ignored"
"9#CPU_DMA/DMA_CACHE.sv#s%assign dc_req_wdata = w_q >> (8 \* int'(p_off));%assign dc_req_wdata = w_q;%#DMA: the data of a piece is not moved to the right"
"11#CPU_DMA/DMA_CACHE.sv#s%else                      dc_req_addr = {ar_q\[ADDR_WIDTH-1:3\], 3'b000};%else                      dc_req_addr = {aw_q[ADDR_WIDTH-1:3], 3'b000};%#DMA: a read goes to the address of the last write"
"12#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%assign i_req_valid = req_go \& ~redirect_valid;%assign i_req_valid = req_go;%#IFU: a fetch goes out in the cycle of a redirect"
"13#CPU_CACHE/CPU_CACHE/CPU_CACHE.sv#s%assign ev_dc_refill = dc_axi4_arvalid \& dc_axi4_arready;%assign ev_dc_refill = ic_axi4_arvalid \& ic_axi4_arready;%#PMU: the D$ miss event counts the fills of the I$ (d04)"
"14#CPU_CACHE/CPU_CACHE/CPU_CACHE.sv#s%assign ev_ic_refill = ic_axi4_arvalid \& ic_axi4_arready;%assign ev_ic_refill = 1'b0;%#PMU: no I$ miss events (d04)"
"15#CPU_MMU/CORE_MMU/CORE_MMU.sv#s%ptw_need \& ~kill \& ~d_need_walk;%ptw_need \& ~kill \&  d_need_walk;%#PMU: the ITLB miss event counts the walks of the data side (d04)"
"16#CPU_MMU/CORE_MMU/CORE_MMU.sv#s%assign ev_dtlb_miss = ~grant \& lsu_idle \& ptw_need \& ~kill \&  d_need_walk;%assign ev_dtlb_miss = ptw_need \&  d_need_walk;%#PMU: a DTLB miss counted every cycle it waits for the walker (d04)"
"19#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%~stall_ma \& ~lu_hazard \& ~fp_wait;%~stall_ma \& ~lu_hazard;%#core: an FSD waiting for the FPU asks the cache from EX, is taken back and goes from MA (fploop's cycle bound)"
"17#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[18\] = ev_l2_read;%assign hpm_ev[18] = 1'b0;%#PMU: no L2 read events (d04)"
"18#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[19\] = ev_l2_miss;%assign hpm_ev[19] = ev_l2_read;%#PMU: the L2 miss event counts every L2 read (d04)"
"20#CPU_CORE/CPU_CORE/CPU_CORE.sv#s%assign hpm_ev\[20\] = stall_ma \& (ma_cmd == 4'd1);%assign hpm_ev[20] = stall_ma;%#PMU (M0): the store wait event counts the waits of loads too (d04)"
"21#CPU_CACHE/DCACHE/DCACHE.sv#s%assign ev_miss  = ~ms_empty;%assign ev_miss  = 1'b0;%#PMU (M0): no wait on a miss is seen (d04)"
"22#CPU_CACHE/DCACHE/DCACHE.sv#s%assign ev_miss  = ~ms_empty;%assign ev_miss  = 1'b1;%#PMU (M0): every wait of MA counted as one on a miss (d04)"
"23#CPU_CACHE/CPU_CACHE/CPU_CACHE.sv#s%assign ic_outst   = {1'b0, ic_fills} + 3'(ic_axi4_arvalid);%assign ic_outst   = {1'b0, ic_fills};%#PMU (M0): an I$ fill waiting for the bus is not outstanding (d04)"
"24#CPU_CACHE/CPU_CACHE/CPU_CACHE.sv#s%assign ev_fills_2 = ({1'b0, dc_outst} + {1'b0, ic_outst}) >= 4'd2;%assign ev_fills_2 = (dc_outst >= 3'd2);%#PMU (M0): two fills outstanding only when both are the D$'s (d04)"
"25#CPU_CACHE/DCACHE/DCACHE.sv#s%assign ev_vic_copy   = (f_state == F_WB_READ) | (f_state == F_WB_WAIT) | (f_state == F_WB_PUSH);%assign ev_vic_copy   = 1'b0;%#PMU (M0): no wait for a dirty victim copied out (d04)"
)

SEL=("$@")
pass=0; miss=0; skip=0

for m in "${MUTATIONS[@]}"; do
    id=${m%%#*};   rest=${m#*#}
    file=${rest%%#*}; rest=${rest#*#}
    expr=${rest%%#*}; desc=${rest#*#}
    if [ ${#SEL[@]} -ne 0 ] && [[ " ${SEL[*]} " != *" $id "* ]]; then continue; fi

    rm -rf $WORK; mkdir -p $WORK
    cp -r $RTL/CPU $WORK/CPU
    cp -r $RTL/BUS $WORK/BUS
    sed -i "$expr" $WORK/CPU/$file
    if diff -q $RTL/CPU/$file $WORK/CPU/$file > /dev/null; then
        echo "M$id [NOT APPLIED] $desc"; skip=$((skip+1)); continue
    fi

    SRCS=$(grep -oE '\$\(RTL_DIR\)/[A-Za-z0-9_/]+\.sv' Makefile \
           | sed "s|\$(RTL_DIR)|$WORK|" | tr '\n' ' ')
    verilator $VFLAGS -Mdir $WORK/obj $SRCS AXI4_SLAVE_MEM.sv AXIL_PERIPH.sv tb_SYS.sv \
        > $WORK/build.log 2>&1
    if [ ! -x $WORK/obj/Vtb_SYS ]; then
        echo "M$id [BUILD FAILED] $desc"; miss=$((miss+1)); continue
    fi

    # Exactly the programs of "make run-all". The tests of SIM_CORE that
    # need its own bench (t06_irq, t15_plic) fail here whatever the RTL,
    # and running them made every mutation look detected.
    fails=0
    for t in $RUN_LIST; do
        [ -f $t.hex ] || continue
        timeout 300 ./$WORK/obj/Vtb_SYS +hex=$t.hex +name=$(basename $t) \
            > $WORK/$(basename $t).log 2>&1
        grep -q ": PASS" $WORK/$(basename $t).log || fails=$((fails+1))
    done
    if [ -f rvtests/rv64ui-p-fence_i.hex ]; then
        th=$(${PREFIX}nm rvtests/rv64ui-p-fence_i | awk '$3=="tohost"{print $1}')
        timeout 300 ./$WORK/obj/Vtb_SYS +hex=rvtests/rv64ui-p-fence_i.hex \
            +name=fence_i +tohost=$th +maxcycles=300000 > $WORK/fence.log 2>&1
        grep -q ": PASS" $WORK/fence.log || fails=$((fails+1))
    fi

    # the floating point kernels with their cycle bounds (bench/fploop.c):
    # a loss of cycles that changes no answer
    if [ -f bench/fploop.hex ]; then
        timeout 600 ./$WORK/obj/Vtb_SYS +hex=bench/fploop.hex +name=fploop \
            +tohost=$(cat bench/fploop.tohost) +maxcycles=5000000 > $WORK/fploop.log 2>&1
        grep -q ": PASS" $WORK/fploop.log || fails=$((fails+1))
    fi

    if [ $fails -gt 0 ]; then
        echo "M$id [DETECTED: $fails runs fail] $desc"; pass=$((pass+1))
    else
        echo "M$id [NOT DETECTED] $desc"; miss=$((miss+1))
    fi
done

rm -rf $WORK
echo ""
echo "SIM_SYS bug injection : $pass detected, $miss missed, $skip not applied"
[ $miss -eq 0 ] && [ $skip -eq 0 ]
