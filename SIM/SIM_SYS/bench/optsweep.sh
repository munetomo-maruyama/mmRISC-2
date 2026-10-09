#!/bin/bash
#---------------------------------------------------------------------------
# optsweep.sh : CoreMark and Dhrystone of this directory built with other
# compiler flags, run in SIM_SYS, cycles compared
#
#   ./optsweep.sh [name ...]          (in SIM/SIM_SYS/bench, after make)
#
# How OPT_MAX_CM and OPT_MAX_DHRY of LitexSystem/software/bench/Makefile
# (the coremark_max / dhrystone_max builds on the board) were chosen:
# LitexSystem/docs/BENCH.md 17. Each flag set below is built for rv64gc and
# for Zba / Zbb, the runs go 8 at a time (about 10 minutes for all), and the
# table gives CoreMark/MHz (10 iterations) and DMIPS/MHz (500 runs) from
# the cycles of the timed parts. CoreMark complains that it ran for less
# than 10 seconds ("Errors detected"); what matters is that crcfinal is the
# same for every build (0xfcaf at 10 iterations).
#
# The bare machine has its own small string functions (minilib.c) where the
# board has glibc's, so Dhrystone gives less here than on the board; the
# order of the flag sets is what this is for.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
W=optsweep
CM=${COREMARK:-$HOME/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark}
P=/opt/riscv/bin/riscv64-unknown-elf-
SF="-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4"

declare -A F
F[o2]="-O2"
F[o3]="-O3"
F[o3u]="-O3 -funroll-loops"
F[sf]="$SF"
F[sfpta]="$SF -fipa-pta"
F[sfal8]="${SF//=4/=8}"
F[sfs7]="$SF -mtune=sifive-7-series"
F[o2lto]="-O2 -flto"
F[o3lto]="-O3 -flto"
F[sflto]="$SF -flto"
NAMES=${*:-o2 o3 o3u sf sfpta sfal8 sfs7 o2lto o3lto sflto}

[ -f ee/ee_printf.c ] && [ -f dhry/dhrystone.h ] || { echo "run make first"; exit 1; }
[ -x ../obj_dir/Vtb_SYS ] || { echo "build SIM_SYS first (make in SIM/SIM_SYS)"; exit 1; }
rm -rf $W; mkdir -p $W

for isa in gc zb; do
    A="-march=rv64imafdc_zicsr_zifencei -mabi=lp64d"
    [ $isa = zb ] && A="-march=rv64imafdc_zicsr_zifencei_zba_zbb -mabi=lp64d"
    for v in $NAMES; do
        O="${F[$v]}"
        [ -n "$O" ] || { echo "no flag set $v"; exit 1; }
        C="$A $O -mcmodel=medany -nostdlib -T link.ld -fno-tree-loop-distribute-patterns -Wl,--no-warn-rwx-segments"
        ${P}gcc $C -I. -I$CM -DFLAGS_STR="\"$A $O\"" -DITERATIONS=10 -DPERFORMANCE_RUN=1 \
            crt.S minilib.c ee/ee_printf.c core_portme.c $CM/core_list_join.c $CM/core_main.c \
            $CM/core_matrix.c $CM/core_state.c $CM/core_util.c -lgcc -o $W/cm_${isa}_$v.elf || exit 1
        ${P}gcc $C -std=gnu89 -fno-common -fno-builtin-printf -Dprintf=ee_printf -w -Idhry -I. -I$CM \
            crt.S minilib.c ee/ee_printf.c dhry_shim.c dhry/dhrystone.c dhry/dhrystone_main.c \
            -lgcc -o $W/dh_${isa}_$v.elf || exit 1
    done
done
for e in $W/*.elf; do
    b=${e%.elf}
    ${P}objcopy -O binary $e $b.bin
    python3 ../../SIM_CORE/tools/bin2hex.py $b.bin $b.hex
    ${P}nm $e | awk '$3=="tohost"{print $1}' > $b.tohost
done

ls $W/*.hex | xargs -P 8 -I{} sh -c \
    'b=${1%.hex}; ../obj_dir/Vtb_SYS +hex=$1 +name=$(basename $b) +tohost=$(cat $b.tohost) +maxcycles=50000000 > $b.log 2>&1' _ {}

printf "%-8s %-8s %-8s %-8s %-10s %-10s  %s\n" "flags" "CM/MHz" "+Zb" "crc" "DMIPS/MHz" "+Zb" "flags"
for v in $NAMES; do
    cm() { grep "CoreMark/MHz" $W/cm_$1_$v.log | awk '{ print $3 }'; }
    dm() { grep "timed part" $W/dh_$1_$v.log | sed 's/.*: \([0-9]*\) cycles.*/\1/' |
           awk '{ printf "%.3f", 500e6 / ($1 * 1757) }'; }
    crc=$(grep -h crcfinal $W/cm_*_$v.log | awk '{ print $3 }' | sort -u | tr '\n' ' ')
    printf "%-8s %-8s %-8s %-8s %-10s %-10s  %s\n" $v "$(cm gc)" "$(cm zb)" "$crc" "$(dm gc)" "$(dm zb)" "${F[$v]}"
done
