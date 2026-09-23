#!/bin/bash
#---------------------------------------------------------------------------
# bug_inject.sh : check that tb_FPU detects deliberately injected bugs
#
#   Each mutation copies the RTL to a work directory, applies one sed edit
#   and runs the comparison against SoftFloat. The run is expected to FAIL.
#
#     ./bug_inject.sh          : every mutation
#     ./bug_inject.sh <text>   : only the ones whose name contains <text>
#
# The mutations aim at the places where the unit was cut into cycles, which
# is where a register that is written in one state and read in another can
# be wired to the wrong thing without any of it showing up in a lint.
#
#---------------------------------------------------------------------------
set -u

RTL=../../RTL/CPU/CPU_FPU
WORK=bug_work
N=${N:-400}

SOFTFLOAT=${SOFTFLOAT:-$HOME/RISCV/berkeley-softfloat-3}
SF_BUILD=${SF_BUILD:-$SOFTFLOAT/build/Linux-aarch64-RISCV-GCC}
VERILATOR_FLAGS="--binary --timing -j 0 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-DECLFILENAME -Wno-BLKSEQ \
  -CFLAGS -I$SOFTFLOAT/source/include -CFLAGS -I$SF_BUILD \
  -LDFLAGS $SF_BUILD/softfloat.a"

MUTATIONS=(
# the operand copy
"operands are never copied|CORE_FPU/CORE_FPU.sv|s|end else if (start) begin|end else if (1'b0) begin|"
"the control is copied from the wrong place|CORE_FPU/CORE_FPU.sv|s|u_op <= op; u_fmt <= fmt; u_rm <= rm;|u_op <= op; u_fmt <= ~fmt; u_rm <= rm;|"

# holding the unpacked value (S_UNP) and the partial products (S_PP)
"the held significand is the wrong operand|CORE_FPU/CORE_FPU.sv|s|a_exp <= w_a_exp;  a_sig <= w_a_sig;|a_exp <= w_a_exp;  a_sig <= w_b_sig;|"
"the held exponent is the one before normalising|CORE_FPU/CORE_FPU.sv|s|b_exp <= w_b_exp;  b_sig <= w_b_sig;|b_exp <= 0;        b_sig <= w_b_sig;|"
"a partial product takes the wrong half|CORE_FPU/CORE_FPU.sv|s%pp_hl <= {32'd0, x_sig\[63:32\]} \* {32'd0, y_sig\[31:0\]};%pp_hl <= {32'd0, x_sig[31:0]} * {32'd0, y_sig[31:0]};%"

# the alignment cycle (S_M2)
"the alignment sticky is thrown away|CORE_FPU/CORE_FPU.sv|s|al_st     <= sh\[128\];|al_st     <= 1'b0;|g"
"the alignment always says add|CORE_FPU/CORE_FPU.sv|s|al_add <= (prod_sign == zz_sign);|al_add <= 1'b1;|"
"the common exponent of a shifted product is wrong|CORE_FPU/CORE_FPU.sv|s|            com_exp   <= zz_exp;|            com_exp   <= pexp_v;|"
"the addend keeps the sign of the product|CORE_FPU/CORE_FPU.sv|s|al_sgn_ls <= zz_sign;|al_sgn_ls <= prod_sign;|"

# the addition cycle (S_M3)
"the sticky is not taken off the difference|CORE_FPU/CORE_FPU.sv|s|sum_sub = al_gt - al_ls - (al_st ? 129'd1 : 129'd0);|sum_sub = al_gt - al_ls;|"
"the difference is taken the wrong way round|CORE_FPU/CORE_FPU.sv|s|end else if (al_gt >= al_ls) begin|end else if (al_gt < al_ls) begin|"
"a cancelling sum keeps the sign of the larger side|CORE_FPU/CORE_FPU.sv|s|                        sum_sign <= al_sgn_ls;|                        sum_sign <= al_sgn_gt;|"
"the alignment sticky does not reach the rounder|CORE_FPU/CORE_FPU.sv|s|stick_sum <= al_st;|stick_sum <= 1'b0;|"

# the select and round cycles (S_SEL / S_RND)
"the rounder is given a stale sticky|CORE_FPU/CORE_FPU.sv|s|q_rnd_sticky <= rnd_sticky;|q_rnd_sticky <= 1'b0;|"
"the rounder is given the wrong format|CORE_FPU/CORE_FPU.sv|s|q_rnd_fmt    <= rnd_fmt;|q_rnd_fmt    <= 1'b1;|"
"the rounded answer is used even when nothing was rounded|CORE_FPU/CORE_FPU.sv|s|result        <= q_use_rnd ? rnd_result : q_sp_res;|result        <= rnd_result;|"
"the flags of the rounder are dropped|CORE_FPU/CORE_FPU.sv|s%q_use_rnd ? (q_sp_flags | rnd_flags)%q_use_rnd ? (q_sp_flags)%"
"an answer that is an integer is not said to be one|CORE_FPU/CORE_FPU.sv|s|q_sp_is_int  <= sp_is_int;|q_sp_is_int  <= 1'b0;|"

# the rounder itself
"underflow is never reported|FPU_ROUND/FPU_ROUND.sv|s|flags\[1\] = tiny \& inexact \& ~overflow;|flags[1] = 1'b0;|"
"round to nearest never breaks a tie to even|FPU_ROUND/FPU_ROUND.sv|s|RM_RNE:  inc = guard \& (rest \| lsb);|RM_RNE:  inc = guard;|"
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

    verilator $VERILATOR_FLAGS --top-module tb_FPU -Mdir $WORK/obj \
        $WORK/FPU_ROUND/FPU_ROUND.sv $WORK/CORE_FPU/CORE_FPU.sv \
        $PWD/tb_FPU.sv $PWD/sf_dpi.c > $WORK/build.log 2>&1
    if [ ! -x $WORK/obj/Vtb_FPU ]; then
        echo "  $name : BUILD FAILED"
        miss=$((miss+1)); continue
    fi
    out=$(./$WORK/obj/Vtb_FPU +rand=$N 2>&1 | grep "FPU RESULT")
    if echo "$out" | grep -q FAIL; then
        echo "  $name : detected"
        pass=$((pass+1))
    else
        echo "  $name : NOT DETECTED   <-- $out"
        miss=$((miss+1))
    fi
done
rm -rf $WORK
echo
echo "FPU bug injection : $pass detected, $miss missed, $skip not applied"
[ $miss -eq 0 ] && [ $skip -eq 0 ]
