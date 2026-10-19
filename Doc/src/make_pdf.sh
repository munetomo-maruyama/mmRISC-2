#!/bin/sh
# make_pdf.sh : the white papers, A4 portrait
#   WhitePaper_mmRISC-2.html   -> ../20261020_WhitePaper_mmRISC-2.pdf    (English)
#   WhitePaper_mmRISC-2_J.html -> ../20261020_WhitePaper_mmRISC-2_J.pdf  (Japanese)
# Needs Google Chrome (headless) and the Noto Sans CJK JP font. The English
# figures (figs/*_en.svg) are made from the Japanese ones by figs_en.py.
cd "$(dirname "$0")"
python3 figs_en.py || exit 1
for v in "" _J; do
    google-chrome --headless=new --disable-gpu --no-sandbox --no-pdf-header-footer \
        --virtual-time-budget=10000 \
        --print-to-pdf=../20261020_WhitePaper_mmRISC-2$v.pdf "file://$PWD/WhitePaper_mmRISC-2$v.html"
done
