#!/bin/bash
#---------------------------------------------------------------------------
# sweep.sh : run the L2 test bench over a range of parameters
#
#   ./sweep.sh            : every configuration (built and run in parallel)
#   ./sweep.sh <n> ...    : only the listed configuration numbers
#
# Each configuration gets its own Verilator model directory under sweep_work.
#---------------------------------------------------------------------------
cd "$(dirname "$0")"
WORK=sweep_work
mkdir -p $WORK

RTL=../../RTL
SRCS="$RTL/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv $RTL/CPU/CPU_L2/L2_TAG_ARRAY.sv \
$RTL/CPU/CPU_L2/CPU_L2.sv ../SIM_CPU/AXI4_SLAVE_MEM.sv tb_L2.sv"
VFLAGS="--binary --timing -j 2 --top-module tb_L2 -Wno-fatal"

# id # description # parameter overrides # plusargs
CONFIGS=(
"1#256 KB, 4 ways (the design)##"
"2#256 KB, 4 ways, random replacement#-GL2_RANDOM=1#"
"3#128 KB, 8 ways#-GL2_SIZE=131072 -GL2_WAYS=8#"
"4#512 KB, 4 ways (memory 2 x the L2)#-GL2_SIZE=524288 -GRANGE_X=2#"
"5#8 KB, 4 ways (many evictions)#-GL2_SIZE=8192#+ops=20000"
"6#8 KB, 4 ways, random replacement#-GL2_SIZE=8192 -GL2_RANDOM=1#+ops=20000"
"7#4 KB, direct mapped#-GL2_SIZE=4096 -GL2_WAYS=1#+ops=20000"
"8#4 KB, 2 ways#-GL2_SIZE=4096 -GL2_WAYS=2#+ops=20000"
"9#16 KB, 8 ways, memory 16 x the L2#-GL2_SIZE=16384 -GL2_WAYS=8 -GRANGE_X=16#+ops=20000"
"10#8 KB, 4 ways, other seed#-GL2_SIZE=8192#+ops=20000 +seed=7"
"11#8 KB, 4 ways, other seed#-GL2_SIZE=8192#+ops=20000 +seed=12345"
)

run_one() {
    local line="$1"
    IFS='#' read -r id desc params plus <<< "$line"
    local d=$WORK/c$id
    rm -rf $d; mkdir -p $d
    if ! verilator $VFLAGS -Mdir $d/obj $params $SRCS > $d/build.log 2>&1; then
        echo "C$id [BUILD FAILED] $desc"; return
    fi
    timeout 3600 ./$d/obj/Vtb_L2 $plus > $d/sim.log 2>&1
    if grep -q "RESULT : PASS" $d/sim.log; then
        echo "C$id [PASS $(grep -o '([0-9]* checks' $d/sim.log | tr -d '(')] $desc"
    elif grep -q "RESULT : FAIL" $d/sim.log; then
        echo "C$id [FAIL $(grep -o '[0-9]* errors' $d/sim.log | tail -1)] $desc"
    else
        echo "C$id [TIMEOUT/HANG] $desc"
    fi
}

sel=("$@")
pids=()
for line in "${CONFIGS[@]}"; do
    id=${line%%#*}
    if [ ${#sel[@]} -eq 0 ] || [[ " ${sel[*]} " == *" $id "* ]]; then
        run_one "$line" &
        pids+=($!)
        while [ $(jobs -r | wc -l) -ge 4 ]; do sleep 2; done
    fi
done
for p in "${pids[@]}"; do wait $p; done
