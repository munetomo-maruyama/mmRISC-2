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
"pmp napot mask not inverted|MMU_PMP/MMU_PMP.sv|s|((a \& ~napot_mask) == (this_a \& ~napot_mask))|((a \& napot_mask) == (this_a \& napot_mask))|"
"pmp TOR top inclusive|MMU_PMP/MMU_PMP.sv|s|(a >= prev_a) \&\& (a < this_a)|(a >= prev_a) \&\& (a <= this_a)|"
"pmp TOR bottom exclusive|MMU_PMP/MMU_PMP.sv|s|(a >= prev_a) \&\& (a < this_a)|(a > prev_a) \&\& (a < this_a)|"
"pmp TOR base is not the entry before|MMU_PMP/MMU_PMP.sv|s|prev_a = (i == 0) ? 54'd0 : addr\[64\*(i-1) +: 54\];|prev_a = 54'd0;|"
"pmp NA4 compares too few bits|MMU_PMP/MMU_PMP.sv|s|A_NA4   : match_one = (a == this_a);|A_NA4   : match_one = (a\[52:0\] == this_a\[52:0\]);|"
"pmp NA4 behaves like NAPOT|MMU_PMP/MMU_PMP.sv|s|A_NA4   : match_one = (a == this_a);|A_NA4   : match_one = ((a \& ~napot_mask) == (this_a \& ~napot_mask));|"
"pmp OFF still matches|MMU_PMP/MMU_PMP.sv|s|default : match_one = 1'b0;      // A = 0 : OFF|default : match_one = 1'b1;|"
"pmp highest match wins|MMU_PMP/MMU_PMP.sv|s|for (int i = ENTRIES-1; i >= 0; i--) begin|for (int i = 0; i < ENTRIES; i++) begin|"
"pmp machine mode ignores the lock|MMU_PMP/MMU_PMP.sv|s|((priv == PRIV_M) \&\& !win_cfg\[7\])|(priv == PRIV_M)|"
"pmp lock bit read from the wrong place|MMU_PMP/MMU_PMP.sv|s|!win_cfg\[7\])|!win_cfg\[6\])|"
"pmp nothing matches : open to all|MMU_PMP/MMU_PMP.sv|s|fail = (priv != PRIV_M);|fail = 1'b0;|"
"pmp nothing matches : closed to all|MMU_PMP/MMU_PMP.sv|s|fail = (priv != PRIV_M);|fail = 1'b1;|"
"pmp access across two entries allowed|MMU_PMP/MMU_PMP.sv|s|else if (idx_lo != idx_hi)         fail = 1'b1;   // across two regions|else if (1'b0)                     fail = 1'b1;|"
"pmp access half outside allowed|MMU_PMP/MMU_PMP.sv|s|else if (hit_lo != hit_hi)         fail = 1'b1;   // half in, half out|else if (1'b0)                     fail = 1'b1;|"
"pmp execute checked against R|MMU_PMP/MMU_PMP.sv|s|!(is_exec  \&\& !win_cfg\[2\])|!(is_exec  \&\& !win_cfg\[0\])|"
"pmp write checked against R|MMU_PMP/MMU_PMP.sv|s|!(is_write \&\& !win_cfg\[1\])|!(is_write \&\& !win_cfg\[0\])|"
"pmp size ignored : only the first byte|MMU_PMP/MMU_PMP.sv|s|default: last_byte = paddr + 64'd7;|default: last_byte = paddr;|"
"pmp address not shifted|MMU_PMP/MMU_PMP.sv|s|assign a_lo = paddr\[55:2\];|assign a_lo = paddr\[53:0\];|"
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
