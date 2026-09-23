#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : put one bug at a time into the MMU and check that the
#                 benches notice
#
#   ./bug_inject.sh [pattern]     only the mutations whose name matches
#
# The copy of the RTL is built in bug_work with its own object directory.
# The project lives on a shared folder whose timestamps have a resolution of
# a second, so make cannot be trusted to notice a file that was just written:
# every mutation is built from scratch.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RTL=../../RTL/CPU/CPU_MMU
WORK=bug_work
FILTER=${1:-}
N=${N:-20000}

VERILATOR_FLAGS="--binary --timing -j 0 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-BLKSEQ"

# name | file | sed expression
MUTATIONS=(
"pmp napot mask off by one|MMU_PMP/MMU_PMP.sv|s|napot_mask = this_a ^ (this_a + 54'd1);|napot_mask = this_a ^ (this_a + 54'd2);|"
"pmp napot mask not inverted|MMU_PMP/MMU_PMP.sv|s|((a_up \& ~napot_mask\[53:1\]) == (this_a\[53:1\] \& ~napot_mask\[53:1\]))|((a_up \& napot_mask\[53:1\]) == (this_a\[53:1\] \& napot_mask\[53:1\]))|"
"pmp TOR top inclusive|MMU_PMP/MMU_PMP.sv|s#below = up_lt | (up_eq \& ~x0 \& t0);#below = up_lt | (up_eq \& (~x0 | t0));#"
"pmp TOR bottom exclusive|MMU_PMP/MMU_PMP.sv|s#ge_lo = (i == 0) ? 1'b1 : ~lt_lo\[(i+N-1)%N\];#ge_lo = (i == 0) ? 1'b1 : ~lt_lo[(i+N-1)%N] \& ~eq_lo[(i+N-1)%N];#; s#ge_hi = (i == 0) ? 1'b1 : ~lt_hi\[(i+N-1)%N\];#ge_hi = (i == 0) ? 1'b1 : ~lt_hi[(i+N-1)%N] \& ~eq_hi[(i+N-1)%N];#"
"pmp TOR base is not the entry before|MMU_PMP/MMU_PMP.sv|s|A_TOR   : begin m_lo\[i\] = ge_lo \& lt_lo\[i\]; m_hi\[i\] = ge_hi \& lt_hi\[i\];|A_TOR   : begin m_lo[i] = lt_lo[i]; m_hi[i] = lt_hi[i];|"
"pmp NA4 compares too few bits|MMU_PMP/MMU_PMP.sv|s|eq_lo\[i\] = up_eq\[i\] \& (lo0 == this_a\[0\]);|eq_lo[i] = up_eq[i];|; s|eq_hi\[i\] = up_eq\[i\] \& (hi0 == this_a\[0\]);|eq_hi[i] = up_eq[i];|"
"pmp NA4 behaves like NAPOT|MMU_PMP/MMU_PMP.sv|s|A_NA4   : begin m_lo\[i\] = eq_lo\[i\];         m_hi\[i\] = eq_hi\[i\];|A_NA4   : begin m_lo[i] = napot[i]; m_hi[i] = napot[i];|"
"pmp OFF still matches|MMU_PMP/MMU_PMP.sv|s|default : begin m_lo\[i\] = 1'b0;             m_hi\[i\] = 1'b0;|default : begin m_lo[i] = 1'b1; m_hi[i] = 1'b1;|"
"pmp highest match wins|MMU_PMP/MMU_PMP.sv|s%assign sel_lo = m_lo \& (~m_lo + N'(1));%always @(*) begin sel_lo = '0; for (int i = 0; i < ENTRIES; i++) if (m_lo[i]) sel_lo = N'(1) << i; end%; s%assign sel_hi = m_hi \& (~m_hi + N'(1));%always @(*) begin sel_hi = '0; for (int i = 0; i < ENTRIES; i++) if (m_hi[i]) sel_hi = N'(1) << i; end%"
"pmp machine mode ignores the lock|MMU_PMP/MMU_PMP.sv|s|((priv == PRIV_M) \&\& !win_cfg\[7\])|(priv == PRIV_M)|"
"pmp lock bit read from the wrong place|MMU_PMP/MMU_PMP.sv|s|!win_cfg\[7\])|!win_cfg\[6\])|"
"pmp nothing matches : open to all|MMU_PMP/MMU_PMP.sv|s|fail = (priv != PRIV_M);|fail = 1'b0;|"
"pmp nothing matches : closed to all|MMU_PMP/MMU_PMP.sv|s|fail = (priv != PRIV_M);|fail = 1'b1;|"
"pmp access across two entries allowed|MMU_PMP/MMU_PMP.sv|s|else if (sel_lo != sel_hi)         fail = 1'b1;   // not one region|else if (1'b0)                     fail = 1'b1;|"
"pmp access half outside allowed|MMU_PMP/MMU_PMP.sv|s|else if (!hit_lo \&\& !hit_hi)       fail = (priv != PRIV_M);|else if (!hit_lo \|\| !hit_hi)       fail = (priv != PRIV_M);|"
"pmp execute checked against R|MMU_PMP/MMU_PMP.sv|s|!(is_exec  \&\& !win_cfg\[2\])|!(is_exec  \&\& !win_cfg\[0\])|"
"pmp write checked against R|MMU_PMP/MMU_PMP.sv|s|!(is_write \&\& !win_cfg\[1\])|!(is_write \&\& !win_cfg\[0\])|"
"pmp size ignored : only the first byte|MMU_PMP/MMU_PMP.sv|s#assign hi0  = paddr\[2\] | (size == 2'd3);#assign hi0  = paddr[2];#"
"pmp address not shifted|MMU_PMP/MMU_PMP.sv|s|assign a_up = paddr\[55:3\];|assign a_up = paddr[53:1];|"
"pmp upper bits compared too short|MMU_PMP/MMU_PMP.sv|s|up_lt\[i\] = (a_up < this_a\[53:1\]);|up_lt[i] = (a_up[51:0] < this_a[52:1]);|"
"pmp misaligned block start not cleared|MMU_PMP/MMU_PMP.sv|s|assign lo0  = paddr\[2\] \& (size != 2'd3);|assign lo0  = paddr[2];|"
)

pass=0; miss=0; skip=0
for m in "${MUTATIONS[@]}"; do
    name=${m%%|*};  rest=${m#*|}
    file=${rest%%|*}; expr=${rest#*|}
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && continue

    rm -rf $WORK
    mkdir -p $WORK
    cp -r $RTL/* $WORK/
    sed -i "$expr" $WORK/$file
    if diff -q $RTL/$file $WORK/$file > /dev/null; then
        echo "  $name : NOT APPLIED"
        skip=$((skip+1)); continue
    fi

    case $file in
        MMU_PMP/*) top=tb_PMP; src="$WORK/MMU_PMP/MMU_PMP.sv tb_PMP.sv" ;;
        MMU_TLB/*) top=tb_TLB; src="$WORK/MMU_TLB/MMU_TLB.sv tb_TLB.sv" ;;
        *) echo "  $name : no bench"; skip=$((skip+1)); continue ;;
    esac

    verilator $VERILATOR_FLAGS --top-module $top -Mdir $WORK/obj $src > $WORK/build.log 2>&1
    if [ ! -x $WORK/obj/V$top ]; then
        echo "  $name : BUILD FAILED"
        miss=$((miss+1)); continue
    fi
    out=$(./$WORK/obj/V$top +n=$N 2>&1 | grep "TEST RESULT")
    if echo "$out" | grep -q FAIL; then
        echo "  $name : detected"
        pass=$((pass+1))
    else
        echo "  $name : NOT DETECTED   <-- $out"
        miss=$((miss+1))
    fi
done

rm -rf $WORK
echo ""
echo "MMU bug injection : $pass detected, $miss missed, $skip not applied"
[ $miss -eq 0 ] && [ $skip -eq 0 ]
