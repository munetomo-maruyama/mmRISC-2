#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : check that tb_L2 detects deliberately injected bugs
#
# Each mutation copies the RTL to a work directory, applies one sed edit and
# runs the bench (8 KB L2, 4 ways: many evictions). The bench is expected to
# FAIL (or to hang, which the watchdog turns into a failure).
#
#   ./bug_inject.sh            : all mutations (run in parallel)
#   ./bug_inject.sh <n> ...    : selected mutations
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=bug_work
mkdir -p $WORK

VFLAGS="--binary --timing -j 2 --top-module tb_L2 -Wno-fatal -GL2_SIZE=8192"
PLUS="+ops=3000 +maxcycles=2000000"
L2=CPU/CPU_L2/CPU_L2.sv

# id # file # sed expression # description
MUTATIONS=(
"1#$L2#s/assign cmp_vdirty = t_rd_valid\[vic_way\] \&\& t_rd_dirty\[vic_way\];/assign cmp_vdirty = 1'b0;/#a dirty victim is dropped, not written out"
"2#$L2#s/t_wr_way_en\[hit_way\] = 1'b1;/;/#a line write that hits does not make the line dirty"
"3#$L2#s|t_wr_way_en\[way\] = 1'b1;             // the new line, dirty|begin t_wr_way_en[way] = 1'b1; t_wr_dirty = 1'b0; end|#a line write that misses allocates a clean line"
"4#$L2#s/t_wr_dirty       = 1'b0;/t_wr_dirty       = 1'b1;/#a fill makes the line dirty (clean victims are written out)"
"5#$L2#s/assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;/assign cmp_need   = (cur_write \&\& !cur_line) || cmp_vdirty;/#a read miss does not wait for the write out in the evict buffer"
"6#$L2#s/assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;/assign cmp_need   = !cur_write || cmp_vdirty;/#a part write does not wait for the write out in the evict buffer"
"7#$L2#s/assign cmp_need   = !cur_write || !cur_line || cmp_vdirty;/assign cmp_need   = !cur_write || !cur_line;/#a line write with a dirty victim overwrites a full evict buffer"
"8#$L2#s/m_axi4_wdata   = eb_data\[dcnt\];/m_axi4_wdata   = eb_data[0];/#the write out sends word 0 eight times"
"9#$L2#s/eb_addr  <= {vic_tag, cur_idx/eb_addr  <= {cur_tag, cur_idx/#the write out goes to the address of the new line"
"10#$L2#s/t_wr_way_en = '1;/t_wr_way_en = '0;/#the walk after reset does not clear the tags"
"11#$L2#s/st        <= M_INIT;/st        <= M_IDLE;/#no walk after reset"
"12#$L2#s/r\[node\] = ~dir;/r[node] = dir;/#pseudo LRU points at the way just used"
"13#$L2#s/iss_now = ((f_cnt + 3'(rd_pend)) < 3'(FIFO_D));/iss_now = 1'b1;/#a read hit streams into a full R FIFO"
"14#$L2#s/(st == M_FILL) \&\& (f_cnt < 3'(FIFO_D));/(st == M_FILL);/#a fill takes beats into a full R FIFO"
"15#$L2#s/(f_cnt == 3'd0) \&\& //#a read is taken while beats of the last one wait"
"16#$L2#s/d_wr_en   = s_axi4_wvalid \& m_axi4_wready \& cur_hit;/d_wr_en   = 1'b0;/#a part write that hits leaves the line stale"
"17#$L2#s/d_wr_en   = s_axi4_wvalid \& m_axi4_wready \& cur_hit;/d_wr_en   = s_axi4_wvalid \& m_axi4_wready;/#a part write that misses writes into the victim"
"18#$L2#s/d_wr_addr = {cur_idx, cur_word + wcnt};/d_wr_addr = {cur_idx, cur_word + wcnt}; d_wr_strb = 8'hff;/#a part write that hits writes every byte of the word"
"19#$L2#s/(wcnt >= cur_word) \&\& //#a fill passes on the beats before the one asked for"
"20#$L2#s/f_in_last = (4'(pend_word) == last_beat);/f_in_last = 1'b0;/#a read hit has no RLAST"
"21#$L2#s/f_in_data = d_rd_data\[hit_way\*64 +: 64\];/f_in_data = d_rd_data[0 +: 64];/#the first beat of a hit comes from way 0"
"22#$L2#s/if ((dst == D_B) \&\& m_axi4_bvalid) eb_valid <= 1'b0;/if ((dst == D_AW) \&\& m_axi4_awready) eb_valid <= 1'b0;/#the evict buffer is free before its write out is done"
"23#$L2#s/t_rd_index  = acc_ar ? s_axi4_araddr\[OFF_BITS +: IDX_BITS\]/t_rd_index  = acc_ar ? s_axi4_awaddr[OFF_BITS +: IDX_BITS]/#a read looks up the set of the write address"
"24#$L2#s/cur_line  <= acc_aw \&\& (s_axi4_awlen == 8'd7) \&\&/cur_line  <= acc_aw \&\& (s_axi4_awlen != 8'd9) \&\&/#a part write is taken as a line write"
"25#$L2#s/f_id\[f_wp\]   <= cur_id;/f_id[f_wp]   <= '0;/#R carries ID 0"
"26#$L2#s/assign ev_miss = (st == M_CMP) \&\& !cur_write \&\& !hit_any;/assign ev_miss = (st == M_CMP) \&\& !cur_write;/#the PMU counts every read as a miss"
"27#$L2#s/pend_word <= cmp_iss ? cur_word + 3'd1 : iss_word;/pend_word <= iss_word;/#a hit's second beat is taken for another word"
"28#$L2#s/t_wr_valid       = !(fill_err || (m_axi4_rresp != 2'b00));/t_wr_valid       = 1'b0;/#a fill leaves the line invalid"
"29#$L2#s/if (dcnt == 3'd7) dst <= D_B;/if (dcnt == 3'd6) dst <= D_B;/#the write out stops after 7 beats"
"30#$L2#s/hit_vec\[w\] = t_rd_valid\[w\] \&\& (t_rd_tag\[w\*TAG_BITS +: TAG_BITS\] == cur_tag);/hit_vec[w] = t_rd_valid[w] \&\& (t_rd_tag[w*TAG_BITS+1 +: TAG_BITS-1] == cur_tag[TAG_BITS-1:1]);/#the tag compare drops the lowest tag bit"
"31#$L2#s/if (!need_buf || !eb_valid) begin/if (1'b1) begin/#M_WAIT does not wait for the evict buffer"
)

run_one() {
    local line="$1"
    IFS='#' read -r id file expr desc <<< "$line"
    local d=$WORK/m$id
    rm -rf $d; mkdir -p $d
    mkdir -p $d/RTL/CPU/CPU_CACHE/CACHE_DATA_ARRAY $d/RTL/CPU/CPU_L2
    cp ../../RTL/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $d/RTL/CPU/CPU_CACHE/CACHE_DATA_ARRAY/
    cp ../../RTL/CPU/CPU_L2/*.sv $d/RTL/CPU/CPU_L2/
    sed -i "$expr" $d/RTL/$file
    if cmp -s ../../RTL/$file $d/RTL/$file; then
        echo "M$id [NOT APPLIED] $desc"; return
    fi
    local R=$d/RTL
    local SRCS="$R/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $R/CPU/CPU_L2/L2_TAG_ARRAY.sv \
$R/CPU/CPU_L2/CPU_L2.sv ../SIM_CPU/AXI4_SLAVE_MEM.sv tb_L2.sv"
    if ! verilator $VFLAGS -Mdir $d/obj $SRCS > $d/build.log 2>&1; then
        sleep 5                       # retry once (transient resource failure)
        if ! verilator $VFLAGS -Mdir $d/obj $SRCS > $d/build.log 2>&1; then
            echo "M$id [BUILD FAILED] $desc"; return
        fi
    fi
    timeout 900 ./$d/obj/Vtb_L2 $PLUS > $d/sim.log 2>&1
    if grep -q "RESULT : PASS" $d/sim.log; then
        echo "M$id [NOT DETECTED] $desc"
    elif grep -q "RESULT : FAIL   (watchdog" $d/sim.log; then
        echo "M$id [DETECTED: hang, watchdog] $desc"
    elif grep -q "RESULT : FAIL" $d/sim.log; then
        echo "M$id [DETECTED: $(grep -o '[0-9]* errors' $d/sim.log | tail -1)] $desc"
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
