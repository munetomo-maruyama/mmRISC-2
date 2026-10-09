#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject_pipe.sh : check that tb_FPU_PIPE detects deliberately injected
#                      bugs in FPU_PIPE (the pipelined FPU)
#
#     ./bug_inject_pipe.sh          : every mutation
#     ./bug_inject_pipe.sh <text>   : only the ones whose name contains <text>
#
# The arithmetic is the one of CORE_FPU (bug_inject.sh aims at it). These
# aim at what the pipeline adds: holding and taking back the first two
# stages, the divide / square root engine beside the pipeline, and the
# control that every stage hands to the next.
#---------------------------------------------------------------------------
set -u

RTL=../../RTL/CPU/CPU_FPU
WORK=bug_work_pipe
F=FPU_PIPE/FPU_PIPE.sv
ARGS=${ARGS:-+rand=40 +ops2=60000}

SOFTFLOAT=${SOFTFLOAT:-$HOME/RISCV/berkeley-softfloat-3}
SF_BUILD=${SF_BUILD:-$SOFTFLOAT/build/Linux-aarch64-RISCV-GCC}
VERILATOR_FLAGS="--binary --timing -j 0 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-DECLFILENAME -Wno-BLKSEQ \
  -CFLAGS -I$SOFTFLOAT/source/include -CFLAGS -I$SF_BUILD \
  -LDFLAGS $SF_BUILD/softfloat.a"

MUTATIONS=(
# holding and taking back the first two stages
"P0 is not taken back|$F|s|else if (kill0)            p0_v <= 1'b0;|else if (1'b0)             p0_v <= 1'b0;|"
"P1 is not taken back|$F|s|else if (kill1)         p1_v <= 1'b0;|else if (1'b0)          p1_v <= 1'b0;|"
"the operands of P0 change while it is held|$F|s|        if (!hold0) begin|        if (1'b1) begin|"
"the operands of P1 change while it is held|$F|s|        if (!hold1) begin|        if (1'b1) begin|"
"an operation leaves P1 while it is held|$F|s|assign p1_go = p1_v \& ~kill1 \& ~hold1;|assign p1_go = p1_v \& ~kill1;|"
"an operation taken back in P1 still moves on|$F|s|assign p1_go = p1_v \& ~kill1 \& ~hold1;|assign p1_go = p1_v \& ~hold1;|"
"an operation is taken while P0 is being taken back|$F|s|assign accept   = in_valid \& in_ready \& ~hold0 \& ~kill0;|assign accept   = in_valid \& in_ready \& ~hold0;|"

# the divide / square root engine. Not listed, equivalent to the design:
#   - the engine started while its operation is still held in P0, and
#   - the engine left running when its operation is taken back in P1:
#   its answer can only go in once the operation is past P1 (ds_cmt), so an
#   engine started early starts again when the operation moves, and one
#   whose operation was taken back never answers. The stop on taking back
#   (ds_kill) is kept so that the engine does not run on for nothing.
"the engine's operation also goes down the pipeline|$F|s|else        p2_v <= p1_go \& ~p1_ds_eng;|else        p2_v <= p1_go;|"
"a divide of special values goes to the engine|$F|s|p1_ds_eng <= is_ds(p0_op) \& ~p0_ds_special;|p1_ds_eng <= is_ds(p0_op);|"
"the root of a negative number goes to the engine|$F|s|p0_ds_special = w_a_nan \| w_a_zero \| w_a_sign \| w_a_inf;|p0_ds_special = w_a_nan \| w_a_zero \| w_a_inf;|"
"the engine's answer goes in before its operation is past P1|$F|s|assign ds_inject = ds_run \& ds_cmt \& |assign ds_inject = ds_run \& |"
"operations are taken while the engine runs|$F|s|assign in_ready = ~ds_busy;|assign in_ready = 1'b1;|"
"a divide taken back in P0 keeps the unit busy|$F|s/(kill0 \&\& p0_v \&\& is_ds(p0_op)) ||/1'b0 ||/"
"a single precision divide runs as long as a double|$F|s|(p0_fmt ? 8'd128 : 8'd64)|8'd128|"
"the engine's answer loses its sticky bit|$F|s|q_rsticky <= ds_sticky;|q_rsticky <= 1'b0;|"
"the engine keeps the tag of the next offer|$F|s|ds_tag    <= p0_tag;|ds_tag    <= in_tag;|"

# what every stage hands to the next
"P3 keeps its control|$F|s|        p3_c <= p2_c;|        p3_c <= p3_c;|"
"P5 takes the control of P3|$F|s|        p5_c <= p4_c;|        p5_c <= p3_c;|"
"the product's exponent and addend stay in P3|$F|s|        p3_f <= p2_f;|        p3_f <= p3_f;|"
"the alignment takes the addend's exponent for the product's|$F|s|pexp_v = prod\[127\] ? (int'(p3_f.sexp) + 1) : int'(p3_f.sexp);|pexp_v = prod[127] ? (int'(p3_f.sexp) + 1) : int'(p3_f.zexp);|"
"FCVT.S.D is rounded as a double|$F|s|p2_c.rfmt     <= (p1_op == FOP_CVT_S_D) ? 1'b0 :|p2_c.rfmt     <= (p1_op == FOP_CVT_S_D) ? 1'b1 :|"
"the rounder takes its inputs one stage late|$F|s|.load      (q_v),|.load      (r_v),|"
"the answer has the tag of the stage before|$F|s|out_tag    <= r_tag;|out_tag    <= q_tag;|"
"a conversion to an integer reads the wrong half|$F|s|v = q_rsig\[127:64\];|v = q_rsig[63:0];|"
"a conversion to an integer loses its flags|$F|s|r_flags   <= q_f2i ? f2i_flags : q_flags;|r_flags   <= q_flags;|"
"a sum that cancels out is always +0|$F|s|zero_sign  = (p5_c.rm == RM_RDN_L);|zero_sign  = 1'b0;|"
"0 + 0 of opposite signs ignores the rounding mode|$F|s|((p1_rm == RM_RDN_L) ? 1'b1 : 1'b0)|1'b0|"
"a conversion to an integer rounds with the mode of another|$F|s|        q_rm      <= p5_c.rm;|        q_rm      <= p4_c.rm;|"
)

FILTER=${1:-}
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

    verilator $VERILATOR_FLAGS --top-module tb_FPU_PIPE -Mdir $WORK/obj \
        $WORK/FPU_ROUND/FPU_ROUND.sv $WORK/FPU_PIPE/FPU_PIPE.sv \
        $PWD/tb_FPU_PIPE.sv $PWD/sf_dpi.c > $WORK/build.log 2>&1
    if [ ! -x $WORK/obj/Vtb_FPU_PIPE ]; then
        echo "  $name : BUILD FAILED"
        miss=$((miss+1)); continue
    fi
    out=$(timeout 600 ./$WORK/obj/Vtb_FPU_PIPE $ARGS 2>&1 | grep "FPU PIPE RESULT")
    if echo "$out" | grep -q FAIL; then
        echo "  $name : detected"
        pass=$((pass+1))
    elif [ -z "$out" ]; then
        echo "  $name : detected (no result, timeout)"
        pass=$((pass+1))
    else
        echo "  $name : NOT DETECTED   <-- $out"
        miss=$((miss+1))
    fi
done
rm -rf $WORK
echo
echo "FPU_PIPE bug injection : $pass detected, $miss missed, $skip not applied"
[ $miss -eq 0 ] && [ $skip -eq 0 ]
