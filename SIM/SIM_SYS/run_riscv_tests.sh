#!/bin/bash
#---------------------------------------------------------------------------
# run_riscv_tests.sh : the official riscv-tests, through the real caches
#
#   ./run_riscv_tests.sh [-v] [set ...]
#
#     -v : build the tests for the virtual memory environment instead of the
#          physical one. That environment boots into supervisor mode with
#          Sv39 on, runs the test in user mode and hands out its pages on
#          demand, so every instruction of the test is translated and the
#          page table is walked thousands of times.
#
# The repository is expected in $RVTESTS (default ~/RISCV/riscv-tests); it is
# not part of this project:
#   git clone --recursive https://github.com/riscv-software-src/riscv-tests
#
# Every test is linked at 0x80000000 like our own ones. The address of the
# tohost word is taken out of the ELF file and handed to the test bench.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
RVTESTS=${RVTESTS:-$HOME/RISCV/riscv-tests}
ENVN=p
if [ "$1" = "-v" ]; then ENVN=v; shift; fi
if [ "$ENVN" = "v" ]; then
    SETS=${@:-"rv64ui rv64um rv64ua rv64uc rv64uf rv64ud"}
else
    SETS=${@:-"rv64ui rv64um rv64ua rv64uc rv64uf rv64ud rv64mi rv64si"}
fi
OUT=rvtests
PREFIX=/opt/riscv/bin/riscv64-unknown-elf-
SIM=./obj_dir/Vtb_SYS

if [ ! -d "$RVTESTS/isa" ]; then
    echo "riscv-tests not found in $RVTESTS"
    echo "  git clone --recursive https://github.com/riscv-software-src/riscv-tests $RVTESTS"
    exit 1
fi
# build the simulator if the RTL has moved since the last one
if ! make -s obj_dir/Vtb_SYS > /dev/null; then
    echo "the simulator did not build"; exit 1
fi

# Tests that ask for something this core does not implement. They are run all
# the same and are reported, but they do not turn the campaign into a failure.
#   ma_data    : wants misaligned accesses to be carried out in hardware; this
#                core traps on them, which the specification allows
#                (rv64mi-p-ma_addr checks the trapping side and passes)
#   breakpoint : wants the debug triggers (tselect / tdata*)
#   amocas_*   : the compare and swap of Zacas, which is not part of A
EXPECTED_FAIL="rv64ui-p-ma_data rv64mi-p-breakpoint \
rv64ua-p-amocas_w rv64ua-p-amocas_d rv64ua-p-amocas_q \
rv64ui-v-ma_data rv64ua-v-amocas_w rv64ua-v-amocas_d rv64ua-v-amocas_q"

mkdir -p $OUT
pass=0; fail=0; xfail=0; failed=""

for set in $SETS; do
    for src in $RVTESTS/isa/$set/*.S; do
        name=$(basename $src .S)
        [ "$name" = "Makefrag" ] && continue
        elf=$OUT/$set-$ENVN-$name
        if [ "$ENVN" = "v" ]; then
            entropy=0x$(echo $set-v-$name | md5sum | cut -c 1-7)
            BUILD="-DENTROPY=$entropy -std=gnu99 -O2 \
                   -I$RVTESTS/env/v -I$RVTESTS/isa/macros/scalar -I$RVTESTS/env \
                   -T$RVTESTS/env/v/link.ld $RVTESTS/env/v/entry.S \
                   $RVTESTS/env/v/vm.c $RVTESTS/env/v/string.c"
        else
            BUILD="-I$RVTESTS/isa/macros/scalar -I$RVTESTS/env/p -I$RVTESTS/env \
                   -T$RVTESTS/env/p/link.ld"
        fi
        if ! ${PREFIX}gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64 -static \
                -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
                -Wl,--no-warn-rwx-segments \
                $BUILD $src -o $elf 2> $elf.buildlog; then
            echo "$set-$ENVN-$name : BUILD FAILED"
            fail=$((fail+1)); failed="$failed $set-$ENVN-$name"
            continue
        fi
        ${PREFIX}objcopy -O binary $elf $elf.bin
        python3 ../SIM_CORE/tools/bin2hex.py $elf.bin $elf.hex
        ${PREFIX}objdump -d $elf > $elf.dis
        tohost=$(${PREFIX}nm $elf | awk '$3=="tohost"{print $1}')
        if [ -z "$tohost" ]; then echo "$set-$ENVN-$name : no tohost symbol"; continue; fi
        [ "$ENVN" = "v" ] && MAXDEF=20000000 || MAXDEF=300000
        line=$($SIM +hex=$elf.hex +name=$set-$ENVN-$name +tohost=$tohost \
                    +maxcycles=${MAXCYCLES:-$MAXDEF} $EXTRA 2>&1 | grep -E ": (PASS|FAIL)")
        echo "$line"
        if echo "$line" | grep -q PASS; then pass=$((pass+1));
        elif [[ " $EXPECTED_FAIL " == *" $set-$ENVN-$name "* ]]; then xfail=$((xfail+1));
        else fail=$((fail+1)); failed="$failed $set-$ENVN-$name"; fi
    done
done

echo ""
echo "riscv-tests : $pass passed, $xfail known failures, $fail unexpected failures"
[ $xfail -ne 0 ] && echo "known:$EXPECTED_FAIL"
[ $fail -ne 0 ] && echo "failed:$failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
