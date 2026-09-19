#!/bin/bash
#---------------------------------------------------------------------------
# sweep.sh : run the cache test bench over a range of parameters
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
SRCS="$RTL/CPU/CPU_CACHE/CACHE_TAG_ARRAY/CACHE_TAG_ARRAY.sv $RTL/CPU/CPU_CACHE/CACHE_DATA_ARRAY/CACHE_DATA_ARRAY.sv \
$RTL/CPU/CPU_CACHE/ICACHE/ICACHE.sv $RTL/CPU/CPU_CACHE/DCACHE/DCACHE.sv $RTL/CPU/CPU_CACHE/CPU_CACHE/CPU_CACHE.sv \
$RTL/BUS/BUS_ARB/BUS_ARB.sv $RTL/BUS/AXI4_ADDR_NARROW/AXI4_ADDR_NARROW.sv \
$RTL/BUS/AXIL_ADDR_NARROW/AXIL_ADDR_NARROW.sv ../SIM_CPU/AXI4_SLAVE_MEM.sv \
../SIM_CPU/AXIL_SLAVE_MEM.sv tb_CACHE.sv"
VFLAGS="--binary --timing -j 0 --top-module tb_CACHE -Wno-fatal"

# id # description # parameter overrides
CONFIGS=(
"1#default (Rocket linux equivalent)#"
"2#D\$ direct mapped (1 way)#-GDC_WAYS=1"
"3#D\$ 2 ways#-GDC_WAYS=2"
"4#D\$ 8 ways#-GDC_WAYS=8 -GMEM_WORDS=32768"
"5#D\$ 16 sets#-GDC_SETS=16"
"6#D\$ 256 sets#-GDC_SETS=256 -GMEM_WORDS=65536"
"7#block 16B#-GDC_BLOCK=16 -GIC_BLOCK=16"
"8#block 32B#-GDC_BLOCK=32 -GIC_BLOCK=32"
"9#block 128B#-GDC_BLOCK=128 -GIC_BLOCK=128 -GMEM_WORDS=32768"
"10#MSHR 1#-GNUM_MSHR=1"
"11#MSHR 4#-GNUM_MSHR=4"
"12#MSHR 4, writeback 1#-GNUM_MSHR=4 -GNUM_WB=1"
"13#random replacement#-GREPLACE_RANDOM=1"
"14#I\$ direct mapped, 16 sets#-GIC_WAYS=1 -GIC_SETS=16"
"15#I\$ 8 ways#-GIC_WAYS=8"
"16#small D\$ (16 sets x 1 way x 16B)#-GDC_SETS=16 -GDC_WAYS=1 -GDC_BLOCK=16"
"17#large D\$ (256 sets x 8 ways x 128B)#-GDC_SETS=256 -GDC_WAYS=8 -GDC_BLOCK=128 -GMEM_WORDS=262144"
"18#asymmetric I\$ / D\$#-GIC_SETS=32 -GIC_WAYS=2 -GIC_BLOCK=32 -GDC_SETS=128 -GDC_BLOCK=32"
)

run_one() {
    local line="$1"
    IFS='#' read -r id desc params <<< "$line"
    local d=$WORK/c$id
    mkdir -p $d
    if ! verilator $VFLAGS -Mdir $d/obj $params $SRCS > $d/build.log 2>&1; then
        echo "C$id [BUILD FAILED] $desc"; return
    fi
    if timeout 3600 ./$d/obj/Vtb_CACHE > $d/sim.log 2>&1; then :; fi
    if grep -q "RESULT : PASS" $d/sim.log; then
        echo "C$id [PASS $(grep -o '([0-9]* checks' $d/sim.log | tr -d '(')] $desc"
    elif grep -q "RESULT : FAIL" $d/sim.log; then
        echo "C$id [FAIL $(grep -c '\[FAIL\]' $d/sim.log) errors] $desc"
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
