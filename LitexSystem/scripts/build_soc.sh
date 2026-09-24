#!/bin/bash
#---------------------------------------------------------------------------
# build_soc.sh : generate the LiteX SoC around mmRISC-2 for the Arty A7-100T
#
#   ./scripts/build_soc.sh [extra litex arguments]
#
# What comes out, in LitexSystem/build/ :
#   gateware/digilent_arty.v     the SoC, with CPU_TOP instantiated
#   gateware/digilent_arty.tcl   the Vivado script (run it on the Windows VM)
#   software/bios/bios.bin       the LiteX BIOS
#   csr.json / soc.h             the map the device tree has to agree with
#
# The Vivado run itself is not done here: Vivado is x86 only and lives on
# the Windows VM. This script stops after the RTL and the BIOS, and rewrites
# the paths in the tcl so that the Windows side can run it from the gateware
# directory whatever drive the share is mounted on.
#---------------------------------------------------------------------------
set -e

# --l2-size 0 : no L2 cache between the SoC bus and LiteDRAM. mmRISC-2 has
# a memory bus of its own straight to LiteDRAM and no DMA port, so LiteX
# hangs the SoC bus -- and with it the DMA of the SD card -- on LiteDRAM
# through that L2, which the CPU never sees. Data the SD card loads (the
# kernel, OpenSBI) could stay in it, and the BIOS's flush_l2_cache() cannot
# get it out: it reads main memory through the CPU, which bypasses the L2.
# See docs/BRINGUP.md.

HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")
LITEX_WS="$REPO/LitexRocket/litex_ws"
VENV="$REPO/LitexRocket/.venv"
BUILD="$LITEX_SYSTEM/build"

[ -d "$VENV" ]     || { echo "no venv at $VENV"; exit 1; }
[ -d "$LITEX_WS" ] || { echo "no LiteX workspace at $LITEX_WS"; exit 1; }

source "$VENV/bin/activate"
export PATH=/opt/riscv/bin:$PATH

# LiteX collects a CPU from every directory holding a core.py, in its own
# tree and in the working directory. Running from here is what makes
# --cpu-type mmrisc work without touching the LiteX checkout.
cd "$LITEX_SYSTEM/cpu"

python3 "$LITEX_WS/litex-boards/litex_boards/targets/digilent_arty.py" \
    --build --no-compile-gateware \
    --variant a7-100 \
    --cpu-type mmrisc \
    --sys-clk-freq 50e6 \
    --with-sdcard \
    --l2-size 0 \
    --output-dir "$BUILD" \
    "$@"

# Vivado runs on the other VM, where the share is mounted somewhere else.
# Make every path to this repository relative to the gateware directory.
TCL="$BUILD/gateware/digilent_arty.tcl"
if [ -f "$TCL" ]; then
    python3 - "$TCL" "$REPO" <<'PY'
import sys, os
tcl, repo = sys.argv[1], os.path.realpath(sys.argv[2])
gateware  = os.path.dirname(os.path.realpath(tcl))
rel       = os.path.relpath(repo, gateware)
text      = open(tcl).read()
n         = text.count(repo)
open(tcl, "w").write(text.replace(repo, rel))
print(f"  {n} absolute paths in the tcl made relative ({rel})")
PY
fi

# the Windows side runs this from the gateware directory
cp "$HERE/build_digilent_arty.bat" "$BUILD/gateware/" 2>/dev/null || true

echo ""
echo "SoC built in $BUILD"
echo "  next: run gateware/digilent_arty.tcl under Vivado on the Windows VM"
