#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : check that tb_CACHE detects deliberately injected bugs
#
# Each mutation copies the RTL to a work directory, applies one sed edit and
# runs the selected test sections. The test bench is expected to FAIL (or to
# hang, which the watchdog turns into a failure).
#
#   ./bug_inject.sh            : all mutations (run in parallel)
#   ./bug_inject.sh <n> ...    : selected mutations
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=bug_work
mkdir -p $WORK

# -j 2 (not -j 0): four mutations are built in parallel, and letting each
# build use every core exhausts the machine and makes verilator abort
VFLAGS="--binary --timing -j 2 --top-module tb_CACHE -Wno-fatal"

# id # file # sed expression # +from # +to # description
MUTATIONS=(
"1#CACHE/ICACHE/ICACHE.sv#s/.inv_all(i_flush_valid)/.inv_all(1'b0)/#6#6#I\$: fence.i does not invalidate the array"
"2#CACHE/ICACHE/ICACHE.sv#s/!(s1_valid \&\& !hit \&\& !i_kill)/1'b1/#10#11#I\$: accepts a new request while the current one misses"
"3#CACHE/ICACHE/ICACHE.sv#s/!fill_flushed \&\& !i_flush_valid/1'b1/#6#6#I\$: fill validates a line invalidated by fence.i"
"4#CACHE/DCACHE/DCACHE.sv#s/tag_wr_dirty = 1'b1;\$/tag_wr_dirty = 1'b0;/#11#12#D\$: store hit does not set the dirty bit"
"5#CACHE/DCACHE/DCACHE.sv#s/ms_wb_needed\[ms_tail\]  <= victim_dirty;/ms_wb_needed[ms_tail]  <= 1'b0;/#3#3#D\$: dirty victim is not written back"
"6#CACHE/DCACHE/DCACHE.sv#s/s1_wr_strb   = size_strb(s1_addr\[2:0\], s1_size);/s1_wr_strb   = 8'hFF;/#2#2#D\$: store ignores the byte strobe"
"7#CACHE/DCACHE/DCACHE.sv#s/assign sc_ok         = res_valid \&\&/assign sc_ok         = 1'b1 \&\&/#5#5#D\$: SC succeeds without a valid reservation"
"8#CACHE/DCACHE/DCACHE.sv#s/assign ms_attach_ok = !((ms_match_id == ms_head)/assign ms_attach_ok = 1'b1 \&\& !((1'b0)/#9#11#D\$: joins a fill after its beat has passed"
"9#CACHE/DCACHE/DCACHE.sv#s/hit_word = merge_bytes(hit_word, fwd_data, fwd_strb);/hit_word = merge_bytes(hit_word, fwd_data, 8'h00);/#11#11#D\$: no forwarding of a write issued with the read"
"10#CACHE/DCACHE/DCACHE.sv#s/4'd9:    return (so < ss) ? o : s;/4'd9:    return (o < s) ? o : s;/#4#4#D\$: AMOMIN compares unsigned"
"11#CACHE/DCACHE/DCACHE.sv#s/4'd5:    return o + s;/4'd5:    return o - s;/#4#4#D\$: AMOADD subtracts"
"12#CACHE/DCACHE/DCACHE.sv#s/if (res_valid \&\& (res_line == addr_line(s1_addr))) res_valid <= 1'b0;/;/g#5#5#D\$: a store does not clear the reservation"
"13#CACHE/DCACHE/DCACHE.sv#s/s1_can_retire = !ms_locked\[ms_match_id\] \&\& ms_attach_ok;/s1_can_retire = ms_attach_ok;/#9#12#D\$: ignores the MSHR lock of a pending store"
"14#CACHE/DCACHE/DCACHE.sv#s/m_axil_wstrb   <= size_strb(s1_addr\[2:0\], s1_size);/m_axil_wstrb   <= 8'hFF;/#7#7#D\$: uncached store ignores the byte strobe"
"15#CACHE/DCACHE/DCACHE.sv#s/rob_err\[i\]  <= f_err | (m_axi4_rresp != 2'b00);/rob_err[i]  <= 1'b0;/#8#8#D\$: bus error of a store fill is not reported"
"16#CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv#s/mem\[wr_way\]\[wr_addr\]/mem[0][wr_addr]/#1#3#data array: writes always go to way 0"
"17#CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv#s/valid_bit\[int'(wr_index) \* WAYS + int'(wr_way)\] <= wr_valid;/valid_bit[int'(wr_index) * WAYS + int'(wr_way)] <= 1'b1;/#3#8#tag array: valid bit is never cleared"
"18#CACHE/DCACHE/DCACHE.sv#s/if (wb_empty \&\& (w_state == W_IDLE)) begin/if (1'b1) begin/#3#3#D\$: FLUSH answers before the writebacks finished"
)

run_one() {
    local line="$1"
    IFS='#' read -r id file expr from to desc <<< "$line"
    local d=$WORK/m$id
    rm -rf $d; mkdir -p $d
    cp -r ../../RTL $d/RTL
    sed -i "$expr" $d/RTL/$file
    if cmp -s ../../RTL/$file $d/RTL/$file; then
        echo "M$id [NOT APPLIED] $desc"; return
    fi
    local R=$d/RTL
    local SRCS="$R/CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv $R/CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
$R/CACHE/ICACHE/ICACHE.sv $R/CACHE/DCACHE/DCACHE.sv $R/CACHE/CPU_CACHE/CPU_CACHE.sv \
$R/BUS/BUS_ARB/BUS_ARB.sv $R/BUS/AXI4_ADDR_NARROW/AXI4_ADDR_NARROW.sv \
$R/BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv ../SIM_CPU/AXI4_SLAVE_MEM.sv \
../SIM_CPU/AXIL_SLAVE_MEM.sv tb_CACHE.sv"
    if ! verilator $VFLAGS -Mdir $d/obj $SRCS > $d/build.log 2>&1; then
        sleep 5                       # retry once (transient resource failure)
        if ! verilator $VFLAGS -Mdir $d/obj $SRCS > $d/build.log 2>&1; then
            echo "M$id [BUILD FAILED] $desc"; return
        fi
    fi
    timeout 900 ./$d/obj/Vtb_CACHE +from=$from +to=$to > $d/sim.log 2>&1
    if grep -q "RESULT : PASS" $d/sim.log; then
        echo "M$id [NOT DETECTED] $desc"
    elif grep -q "RESULT : FAIL" $d/sim.log; then
        echo "M$id [DETECTED: $(grep -c '\[FAIL\]' $d/sim.log) fails] $desc"
    else
        echo "M$id [DETECTED: hang/timeout] $desc"
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
