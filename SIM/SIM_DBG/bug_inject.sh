#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : check that tb_DBG detects deliberately injected bugs
#
# Each mutation copies RTL to a work directory, applies one sed edit,
# runs the selected test sections with Icarus Verilog and expects FAIL.
#   ./bug_inject.sh            : all mutations (run in parallel)
#   ./bug_inject.sh <n> ...    : selected mutations
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=bug_work
mkdir -p $WORK

# id # file # sed expression # +from # +to # description
MUTATIONS=(
"1#CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv#s/if (~req \& ~ack_s)/if (~req)/;s/else if (pend \& ~req \& ~ack_s)/else if (pend \& ~req)/#4#6#CDC: raise req before the previous ack has fallen"
"2#CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv#s/assign t_busy  = pend | (req \& ~ack_s);/assign t_busy  = (req \& ~ack_s);/#4#6#CDC: pending request not reported busy"
"3#CPU/CPU_DBG/DBG_CDC/DBG_CDC.sv#s/assign t_rdata = t_complete ? s_rdata : r_rdata;/assign t_rdata = r_rdata;/#3#5#CDC: response taken one handshake late"
"4#CPU/CPU_DBG/DBG_DTM/DBG_DTM.sv#s/end else if (dmi_busy) begin/end else if (1'b0) begin/#4#5#DTM: Capture-DR ignores busy"
"5#CPU/CPU_DBG/DBG_DTM/DBG_DTM.sv#s/if (dr_sr\[17\] | dr_sr\[16\]) begin/if (dr_sr[17]) begin/#4#4#DTM: dmireset does not clear sticky op"
"6#CPU/CPU_DBG/DBG_DM/DBG_DM.sv#s/if (autoexec_r\[data_idx\] \&\& cmderr_r == CMDERR_NONE)/if (dmi_wr \&\& autoexec_r[data_idx] \&\& cmderr_r == CMDERR_NONE)/#8#8#DM: autoexec not triggered by data read"
"7#CPU/CPU_DBG/DBG_DM/DBG_DM.sv#s/assign authenticated   = ~auth_en | auth_ok;/assign authenticated   = 1'b1;/#13#13#DM: authentication bypassed"
"8#CPU/CPU_DBG/DBG_DM/DBG_DM.sv#s/sbaddress_r <= sbaddress_r + ADDR_WIDTH'(size_bytes(sbaccess_r));/sbaddress_r <= sbaddress_r + 40'd8;/#10#10#DM: sbautoincrement ignores size"
"9#CPU/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv#s/t_wstrb <= size_strb(bm_size) << bm_addr\[2:0\];/t_wstrb <= size_strb(bm_size);/#9#9#BUSMST: write strobe not shifted to the lane"
"10#CPU/CPU_DBG/DBG_BUSMST/DBG_BUSMST.sv#s/if (tmo_hit) begin/if (1'b0) begin/#11#11#BUSMST: no timeout"
"11#CPU/CPU_DBG/DBG_HART_STUB/DBG_HART_STUB.sv#s/dpc        <= dpc + 64'd4;/dpc        <= dpc;/#7#7#HART: step does not advance dpc"
"12#CPU/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv#s/assign tms_oe = oscan1 \& (phase == 2'd2) \& ~tck;/assign tms_oe = oscan1 \& (phase == 2'd2);/#14#14#cJTAG: TMSC driven while TCKC high"
"13#CPU/CPU_DBG/DBG_CJTAG/DBG_CJTAG.sv#s/assign esc_deselect = (esc_r == 2);/assign esc_deselect = 1'b0;/#14#14#cJTAG: deselection escape ignored"
"14#BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv#s/m_wvalid  = s_wvalid  \& s_awvalid \& ~aw_err;/m_wvalid  = 1'b0;/;s/s_wready  = m_wready  \& s_awvalid \& ~aw_err;/s_wready  = 1'b0;/#10#10#bridge: W held until AWREADY (old behaviour, deadlocks with AXIL_RAM)"
"15#BUS/BUS_ARB/BUS_ARB.sv#s/end else if (m_axi4_bvalid \& m_axi4_bready) begin/end else if (m_axi4_awvalid \& m_axi4_awready) begin/#12#12#BUS_ARB: write grant released too early"
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
    local srcs
    srcs=$(sed -n '/^RTL_SRCS/,/^$/p' Makefile | grep -o '\$(RTL_DIR)[^ ]*' | sed "s#\$(RTL_DIR)#$d/RTL#")
    iverilog -g2012 -Wno-timescale -s tb_DBG -o $d/sim.vvp $srcs tb_DBG.sv > $d/compile.log 2>&1
    timeout 600 vvp $d/sim.vvp +from=$from +to=$to > $d/sim.log 2>&1
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
        while [ $(jobs -r | wc -l) -ge 6 ]; do sleep 1; done
    fi
done
for p in "${pids[@]}"; do wait $p; done
