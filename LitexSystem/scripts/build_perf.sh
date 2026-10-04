#!/bin/bash
#---------------------------------------------------------------------------
# build_perf.sh : perf (tools/perf of the kernel) for mmRISC-2, static
#
#   ./scripts/build_perf.sh [path to the kernel source]
#
# One static binary that runs on the BusyBox root of the SD card: copy it
# to the board (make -C software/bench tftp puts it on the TFTP server
# with the benchmarks, perf.sh fetches it). It needs the kernel with
# CONFIG_PERF_EVENTS / CONFIG_RISCV_PMU_SBI (software/boot/linux.config)
# and the pmu node of the device tree (CPU_CORE_SPEC.md decision 69).
#
# Built without the optional libraries (no libelf, libtraceevent, python,
# ...): perf stat and perf record / report work; symbols of a program are
# not resolved (perf report --sort dso still says which binary), and the
# tracepoint events are not there.
#---------------------------------------------------------------------------
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")

LINUX=${1:-$REPO/LitexRocket/software/linux}
OUT=${OUT:-$HOME/mmlitex_build/perf_build}

[ -d "$LINUX/tools/perf" ] || { echo "no kernel source at $LINUX"; exit 1; }
export PATH=/opt/riscv/bin:$PATH
mkdir -p "$OUT"

make -C "$LINUX/tools/perf" O="$OUT" ARCH=riscv \
    CROSS_COMPILE=riscv64-unknown-linux-gnu- LDFLAGS=-static \
    NO_LIBELF=1 NO_LIBTRACEEVENT=1 NO_JEVENTS=1 NO_LIBPYTHON=1 NO_LIBPERL=1 \
    NO_SLANG=1 NO_GTK2=1 NO_LIBUNWIND=1 NO_LIBDW=1 NO_LIBBPF=1 NO_BPF_SKEL=1 \
    NO_LIBCAP=1 NO_LIBNUMA=1 NO_LIBZSTD=1 NO_LZMA=1 NO_LIBCRYPTO=1 \
    NO_LIBBABELTRACE=1 NO_LIBDEBUGINFOD=1 NO_CAPSTONE=1 NO_LIBLLVM=1 \
    NO_DEMANGLE=1 NO_SHELLCHECK=1 -j"$(nproc)"

riscv64-unknown-linux-gnu-strip -o "$OUT/perf.stripped" "$OUT/perf"
mkdir -p "$LITEX_SYSTEM/software/bench/out"
cp "$OUT/perf.stripped" "$LITEX_SYSTEM/software/bench/out/perf"
ls -l "$LITEX_SYSTEM/software/bench/out/perf"
