#!/bin/sh
# make_pdf.sh : WhitePaper_mmRISC-2.html -> ../20261015_WhitePaper_mmRISC-2.pdf (A4 portrait)
# Needs Google Chrome (headless) and the Noto Sans CJK JP font.
cd "$(dirname "$0")"
google-chrome --headless=new --disable-gpu --no-sandbox --no-pdf-header-footer \
    --virtual-time-budget=10000 \
    --print-to-pdf=../20261015_WhitePaper_mmRISC-2.pdf "file://$PWD/WhitePaper_mmRISC-2.html"
