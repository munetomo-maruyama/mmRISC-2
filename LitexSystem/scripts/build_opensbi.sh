#!/bin/bash
#---------------------------------------------------------------------------
# build_opensbi.sh : OpenSBI with the mmRISC-2 device tree built in
#
#   ./scripts/build_opensbi.sh [path to the opensbi source]
#
# OpenSBI is loaded at 0x8000_0000 and jumps to Linux at 0x8020_0000. The
# device tree is NOT a separate file on the SD card: it is embedded in
# fw_jump.bin here, which is why this has to be re-run every time the DTS
# changes.
#
# The source defaults to the one of the reference Rocket build, which is
# outside this repository. Point the argument somewhere else if you have
# your own checkout.
#---------------------------------------------------------------------------
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
LITEX_SYSTEM=$(dirname "$HERE")
REPO=$(dirname "$LITEX_SYSTEM")

OPENSBI=${1:-$REPO/LitexRocket/software/opensbi}
# DTS / DTB / OUT may be given from outside: SIM/SIM_BIOS builds a variant
# of the device tree with an initramfs for its Linux run
DTS=${DTS:-"$LITEX_SYSTEM/software/mmrisc_arty.dts"}
DTB=${DTB:-"$LITEX_SYSTEM/software/mmrisc_arty.dtb"}
OUT=${OUT:-"$LITEX_SYSTEM/software/boot"}

[ -d "$OPENSBI" ] || { echo "no OpenSBI source at $OPENSBI"; exit 1; }

export PATH=/opt/riscv/bin:$PATH
command -v riscv64-unknown-linux-gnu-gcc > /dev/null || {
    echo "riscv64-unknown-linux-gnu- toolchain not found"; exit 1; }

echo "== device tree =="
dtc -I dts -O dtb -o "$DTB" "$DTS"

# Build in a scratch copy: the source is shared with the reference build
# and must not collect our objects.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r "$OPENSBI" "$WORK/opensbi"

echo "== OpenSBI =="
make -C "$WORK/opensbi" -j"$(nproc)" \
    PLATFORM=generic \
    CROSS_COMPILE=riscv64-unknown-linux-gnu- \
    FW_FDT_PATH="$DTB" \
    FW_JUMP_FDT_ADDR=0x82400000 > "$WORK/build.log" 2>&1 || {
        tail -20 "$WORK/build.log"; exit 1; }

mkdir -p "$OUT"
cp "$WORK/opensbi/build/platform/generic/firmware/fw_jump.bin" "$OUT/"

# prove the right tree went in
if strings -a "$OUT/fw_jump.bin" | grep -q "mmrisc,mmrisc-2"; then
    echo "  embedded device tree: mmRISC-2"
else
    echo "  ERROR: the embedded device tree is not the mmRISC-2 one"; exit 1
fi

echo ""
echo "$OUT/fw_jump.bin is ready"
echo "  copy it to the FAT partition of the SD card, next to Image and boot.json"
