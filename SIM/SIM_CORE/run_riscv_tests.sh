#!/bin/bash
#---------------------------------------------------------------------------
# run_riscv_tests.sh : build and run the official riscv-tests on the core
#
#   ./run_riscv_tests.sh [set ...]     default: rv64ui rv64mi
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
SETS=${@:-"rv64ui rv64um rv64ua rv64uc rv64uf rv64ud rv64mi"}
OUT=rvtests
PREFIX=/opt/riscv/bin/riscv64-unknown-elf-
SIM=./obj_dir/Vtb_CORE

if [ ! -d "$RVTESTS/isa" ]; then
    echo "riscv-tests not found in $RVTESTS"
    echo "  git clone --recursive https://github.com/riscv-software-src/riscv-tests $RVTESTS"
    exit 1
fi
if [ ! -x $SIM ]; then echo "build the simulator first (make)"; exit 1; fi

# Tests that ask for something this core does not implement. They are run all
# the same and are reported, but they do not turn the campaign into a failure.
#   ma_data    : wants misaligned accesses to be carried out in hardware; this
#                core traps on them, which the specification allows
#                (rv64mi-p-ma_addr checks the trapping side and passes)
#   breakpoint : wants the debug triggers (tselect / tdata*)
#   pmpaddr    : wants PMP, which comes with the supervisor mode (M5)
#   amocas_*   : the compare and swap of Zacas, which is not part of A
EXPECTED_FAIL="rv64ui-p-ma_data rv64mi-p-breakpoint rv64mi-p-pmpaddr \
rv64ua-p-amocas_w rv64ua-p-amocas_d rv64ua-p-amocas_q"

mkdir -p $OUT
pass=0; fail=0; xfail=0; failed=""

for set in $SETS; do
    for src in $RVTESTS/isa/$set/*.S; do
        name=$(basename $src .S)
        [ "$name" = "Makefrag" ] && continue
        elf=$OUT/$set-p-$name
        if ! ${PREFIX}gcc -march=rv64imafdc_zicsr_zifencei -mabi=lp64 -static \
                -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
                -Wl,--no-warn-rwx-segments \
                -I$RVTESTS/isa/macros/scalar -I$RVTESTS/env/p -I$RVTESTS/env \
                -T$RVTESTS/env/p/link.ld $src -o $elf 2> $elf.buildlog; then
            echo "$set-p-$name : BUILD FAILED"
            fail=$((fail+1)); failed="$failed $set-p-$name"
            continue
        fi
        ${PREFIX}objcopy -O binary $elf $elf.bin
        python3 tools/bin2hex.py $elf.bin $elf.hex
        ${PREFIX}objdump -d $elf > $elf.dis
        tohost=$(${PREFIX}nm $elf | awk '$3=="tohost"{print $1}')
        if [ -z "$tohost" ]; then echo "$set-p-$name : no tohost symbol"; continue; fi
        line=$($SIM +hex=$elf.hex +name=$set-p-$name +tohost=$tohost \
                    +maxcycles=${MAXCYCLES:-100000} $EXTRA 2>&1 | grep -E ": (PASS|FAIL)")
        echo "$line"
        if echo "$line" | grep -q PASS; then pass=$((pass+1));
        elif [[ " $EXPECTED_FAIL " == *" $set-p-$name "* ]]; then xfail=$((xfail+1));
        else fail=$((fail+1)); failed="$failed $set-p-$name"; fi
    done
done

echo ""
echo "riscv-tests : $pass passed, $xfail known failures, $fail unexpected failures"
[ $xfail -ne 0 ] && echo "known:$EXPECTED_FAIL"
[ $fail -ne 0 ] && echo "failed:$failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
