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
# rv64ui-p-fence_i is the sharpest of the lot.
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
"4#CPU_CORE/CORE_LSU/CORE_LSU.sv#s%d_req_paddr <= req_paddr\[PADDR_WIDTH-1:0\];%d_req_paddr <= req_addr[PADDR_WIDTH-1:0];%#LSU: the cache is given the virtual address as a tag"
"5#CPU_CORE/CORE_IFU/CORE_IFU.sv#s%if (push_req) i_req_paddr <= tr_paddr\[PADDR_WIDTH-1:0\];%if (push_req) i_req_paddr <= i_req_addr;%#IFU: the cache is given the virtual address as a tag"
"6#CPU_CACHE/ICACHE/ICACHE.sv#s%if (s1_valid \&\& (i_kill || i_cancel)) begin%if (s1_valid \&\& i_kill) begin%#I\$: a fetch the PMP refused still goes to memory"
"8#CPU_DMA/DMA_CACHE.sv#s%w_got <= 1'b1; w_q <= s_wdata; left <= s_wstrb;%w_got <= 1'b1; w_q <= s_wdata; left <= 8'hFF;%#DMA: the write strobes are ignored"
"9#CPU_DMA/DMA_CACHE.sv#s%assign dc_req_wdata = w_q >> (8 \* int'(p_off));%assign dc_req_wdata = w_q;%#DMA: the data of a piece is not moved to the right"
"11#CPU_DMA/DMA_CACHE.sv#s%else                      dc_req_addr = {ar_q\[ADDR_WIDTH-1:3\], 3'b000};%else                      dc_req_addr = {aw_q[ADDR_WIDTH-1:3], 3'b000};%#DMA: a read goes to the address of the last write"
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
