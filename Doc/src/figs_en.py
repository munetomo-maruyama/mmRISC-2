#!/usr/bin/env python3
# figs_en.py : English versions of the figures of the white paper
#
#   python3 figs_en.py        # figs/<name>.svg -> figs/<name>_en.svg
#
# Each Japanese text of a figure is replaced by its English, and its font is
# scaled when the English needs less room (a value (text, scale)). A text that
# has no entry here stops the script, so that nothing Japanese is left.

import os, re, html, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIGS = os.path.join(HERE, 'figs')
NAMES = ['fig_summary', 'fig_env_wp', 'fig_cycle', 'fig_core', 'fig_soc', 'fig_first', 'fig_timeline_wp',
         'fig_perf', 'fig_workload', 'fig_wns', 'fig_prefetch', 'fig_verif']

EN = {
    # summary
    '12 日': '12 days', '着手から自作 CPU で Linux 起動': ('Start to Linux on the home-made CPU', 0.9),
    '30 日': '30 days', 'Rev.01 まで(189 コミット)': 'To Rev.01 (189 commits)',
    '22,084 行': ('22,084 lines', 0.85), 'RTL(SystemVerilog 46 ファイル)': ('RTL (SystemVerilog, 46 files)', 0.95),
    '仕様・検証・文書も Claude Code': ('Spec, verification, docs: Claude Code too', 0.85),
    'SD カードの ext4 から BusyBox まで': ('From the SD card\'s ext4 to BusyBox', 0.9),
    'Ethernet、perf も動作': 'Ethernet and perf work too',
    'CoreMark(最大最適化、Zba/Zbb)': ('CoreMark (fastest options, Zba/Zbb)', 0.9),
    '-O2: 2.785、DMIPS 1.542': '-O2: 2.785, DMIPS 1.542',
    '550 種': '550', 'バグ注入をすべて検出': 'Bug injections, all detected',
    'テストが壊れた RTL を見つけるか': ('Do the tests find broken RTL?', 0.95),
    # environment
    '● Claude Code(CLI / デスクトップ)': '● Claude Code (CLI / desktop)',
    '● RISC-V GCC 13.2(elf / linux-gnu)': '● RISC-V GCC 13.2 (elf / linux-gnu)',
    '● LiteX(SoC 生成)、OpenSBI、Linux、': '● LiteX (SoC generator), OpenSBI,',
    '   BusyBox、perf のビルド': '   Linux, BusyBox and perf builds',
    '● OpenOCD / gdb(JTAG・cJTAG)': '● OpenOCD / gdb (JTAG, cJTAG)',
    '● TFTP サーバ(ボードへ転送)': '● TFTP server (to the board)',
    '   合成・配置配線': '   synthesis, place & route', '   ビットストリーム': '   bitstream',
    '   書き込み(USB)': '   programming (USB)',
    '共有フォルダ(リポジトリ、build/gateware のレポート)': 'Shared folder (the repository, the reports in build/gateware)',
    'Vivado は x86 専用だが': 'Vivado is x86 only, but it',
    'Windows 11 arm で動いた': 'ran on Windows 11 for Arm',
    'XC7A100T、DDR3 256 MB': 'XC7A100T, DDR3 256 MB', 'Ethernet 10/100、USB-UART': 'Ethernet 10/100, USB-UART',
    'USB(書き込み・UART)、Ethernet、JTAG': 'USB (programming, UART), Ethernet, JTAG',
    '● mmRISC-2(公開、Apache-2.0)': '● mmRISC-2 (public, Apache-2.0)',
    '   Claude Code が自分で': '   Claude Code commits', '   コミットと push': '   and pushes by itself',
    '● Rev.01 のタグは main、': '● Tag Rev.01 on main,', '   開発は dev ブランチ': '   development on dev',
    '● Release にカーネルのソース': '● Kernel source in a release',
    'モデル': 'Model', 'Sonnet 5 09-13〜14': 'Sonnet 5 09-13 to 14', 'Opus 5  09-15〜22': 'Opus 5  09-15 to 22',
    'Opus 5.5  09-23〜': 'Opus 5.5  from 09-23',
    # cycle
    '① 仕様を書く': '① Write the spec', '.md の仕様書と': 'Specs in .md and', '設計判断(決定 78 件)': '78 design decisions',
    '② RTL を書く': '② Write the RTL', '(パラメータ化)': '(parameterized)',
    '③ 自作テスト + 参照モデル': ('③ Own tests + reference models', 0.9),
    'ランダム、背圧、掃引': 'random, back pressure, sweeps', 'riscv-tests、Linux 起動': 'riscv-tests, Linux boot',
    '④ バグ注入': '④ Bug injection', 'RTL をわざと壊し': 'break the RTL on purpose', 'テストが気づくか': 'do the tests notice?',
    '⑤ 実機で確かめる': '⑤ Check on the board', 'Vivado 合成・書き込み': 'Vivado synthesis, programming',
    'WNS、ベンチ、PMU': 'WNS, benchmarks, PMU',
    '⑥ 記録し、次を決める': ('⑥ Record, decide the next', 0.95), 'コミット、push': 'commit, push',
    'テーマ': 'Each', 'ごとに回す': 'theme',
    '私': 'The author', '両者': 'Both',
    '回すたびに残るもの': 'What each round leaves', '・仕様書の決定事項': '・decisions in the spec',
    '・試験と変異の数': '・tests and mutations', '・実機の数字': '・numbers from the board', '  (WNS、CPI)': '  (WNS, CPI)',
    '・教訓のメモ': '・notes of lessons',
    '私が決めること': 'The author decides', '・次のテーマ': '・the next theme',
    '・提案のどれを採るか': '・which proposal to take', '・実機の結果を渡す': '・and hands over results',
    # core
    'CPU_CORE:8 段 in-order、1 命令ずつ発行': 'CPU_CORE: 8-stage in-order, single issue',
    '命令フェッチ': 'Instruction fetch', 'BTB 256、gshare 8K': 'BTB 256, gshare 8K', 'RAS、RVC 展開': 'RAS, RVC expansion',
    'デコード': ('Decode', 0.95), '分岐': 'branch', 'アドレス': 'address', '判定': 'check',
    'ロード・ストア': 'Load / store', 'D$ へ EX から': 'issued from EX', '早出し、2 サイクル': 'to the D$, 2 cycles',
    '乗算 1〜2 cyc': 'mul 1 to 2 cyc', '除算 早期終了': 'div early exit',
    'F / D、9 段': 'F / D, 9 stages', 'FMA 毎サイクル': 'FMA every cycle', '除算・√ は反復': 'div, sqrt iterate',
    'M / S / U、Sstc': 'M / S / U, Sstc', 'PMU 26 イベント': 'PMU 26 events', 'Sdtrig 4 本': 'Sdtrig 4 triggers',
    'Sv39、TLB 8+8': 'Sv39, TLB 8+8', 'ページウォーカ': 'page table walker',
    'I$ 16 KB  4 ウェイ、64 B ライン': 'I$ 16 KB  4 ways, 64 B lines',
    'ノンブロッキング(MSHR 2)、ライトバック': 'non-blocking (MSHR 2), write-back',
    'AMO・LR/SC、cbo.zero': 'AMO, LR/SC, cbo.zero', '読み出しを調停(FAST_READ)': 'arbitrates reads (FAST_READ)',
    '256 KB、4 ウェイ': '256 KB, 4 ways', 'ライトバック': 'write-back',
    'JTAG / cJTAG DTM、DM、認証': 'JTAG / cJTAG DTM, DM, auth.',
    'SoC の DMA を': 'the SoC\'s DMA', 'D$ 経由で(一貫性)': 'via the D$ (coherent)',
    'DMA 入力': 'DMA in', 'AXI-Lite(周辺)': 'AXI-Lite (periph.)', 'LiteX の CSR へ': 'to LiteX CSRs',
    'AXI4(メモリ)': 'AXI4 (memory)', 'LiteDRAM へ': 'to LiteDRAM', 'キャッシュ': 'un-', '無し': 'cached',
    # soc
    'L1 16+16 KB、L2 256 KB': 'L1 16+16 KB, L2 256 KB', 'CLINT / PLIC / デバッグ': 'CLINT / PLIC / debug',
    'DDR3 コントローラ': 'DDR3 controller', 'CSR バス': 'CSR bus', '(AXI-Lite から)': '(from AXI-Lite)',
    'SD・Ethernet の DMA は CPU の D$ を通る(ハードで一貫性)': 'DMA of SD and Ethernet goes through the CPU\'s D$ (coherent in HW)',
    'LiteX の L2 は外し、CPU 内の L2 を使う': 'LiteX\'s L2 removed; the CPU has its own L2',
    'JTAG / cJTAG(PMOD JA)→ OpenOCD / gdb': 'JTAG / cJTAG (PMOD JA) → OpenOCD / gdb',
    'ソフトウェア(既存のものを使う)': 'Software (used as it is)', 'BusyBox 1.36(シェル)': 'BusyBox 1.36 (shell)',
    'SD カードの ext4': 'on the SD card\'s ext4', 'perf、PMU、Zbb / Zbc / Zicboz を使う': 'uses perf, PMU, Zbb / Zbc / Zicboz',
    'デバイスツリーを内蔵、パッチ 1 本': 'device tree built in, one patch',
    'SD の boot.json → Image、fw_jump.bin': 'boot.json on SD → Image, fw_jump.bin',
    '自作したのは CPU_TOP の RTL だけ': 'Only the RTL of CPU_TOP is home-made',
    '(周辺は LiteX、ソフトは既存のまま)': '(peripherals from LiteX, software as it is)',
    '開発用: TFTP(ネットブート)、': 'For development: TFTP (netboot),',
    'stress.sh(120 分)、workload.sh': 'stress.sh (120 min), workload.sh',
    # first steps
    '(a) 09-15〜16 シミュレーション(SIM_CPU)': '(a) 09-15 to 16: simulation (SIM_CPU)',
    'CPU の代役': 'stands in for the CPU', 'AXI4 メモリ': 'AXI4 memory', 'AXI-Lite メモリ': 'AXI-Lite memory',
    '● 長いバースト、8 / 16 / 32 / 64 ビットの全レーン': '● Long bursts, every lane of 8 / 16 / 32 / 64 bits',
    '● アドレスは 40 ビット(LiteX では上位を 0 判定)': '● 40-bit addresses (LiteX checks the top bits are 0)',
    '● 波形は GTKWave の .gtkw まで Claude Code が用意': '● Claude Code also made the GTKWave .gtkw files',
    '(b) 09-16〜17 デバッガを FPGA で(09-20 に D$ 経由も)': ('(b) 09-16 to 17: the debugger on the FPGA (via the D$ on 09-20)', 0.9),
    'アダプタ': 'adapter', 'DTM → DM': 'DTM → DM',
    '● CPU 本体より先に作った': '● Built before the CPU itself',
    '● OpenOCD から mdw / mww で': '● OpenOCD read and wrote memory',
    '   メモリが読み書きできた': '   with mdw / mww',
    '● cJTAG の再接続も確認': '● cJTAG reconnection checked too',
    # timeline
    'LiteX + Rocket で Linux': 'Linux on LiteX + Rocket', 'バス・BFM の検証': 'Bus and BFM checks',
    'JTAG / cJTAG デバッガ': 'JTAG / cJTAG debugger', 'L1 キャッシュ': 'L1 caches', 'CPU コア M1〜M7': 'CPU core M1 to M7',
    '50 MHz のタイミング': 'Timing at 50 MHz', '実機: BIOS → Linux': 'Board: BIOS → Linux',
    'Ethernet、負荷試験、SD': 'Ethernet, stress test, SD',
    '性能: D$、分岐、乗除算、ISA': 'Speed: D$, branches, mul/div, ISA',
    'Linux 負荷の計測、L2': 'Linux loads measured, L2',
    'FPU パイプライン、文書を日英に': 'FPU pipeline, docs in EN / JA',
    'メモリ待ち、タイミング、Zicboz / Zbc': ('Memory waits, timing, Zicboz / Zbc', 0.95),
    'Rocket で Linux': 'Linux on Rocket', '50 MHz MET・BIOS': '50 MHz met, BIOS',
    '自作 CPU で Linux': 'Linux on own CPU',
    # perf
    '初版': 'first', '分岐予測': 'br. pred.', 'EX 早出し': 'EX issue', '乗算 1cyc': 'mul 1cyc',
    '除算早期': 'div exit', 'late 分岐': 'late br.', '最大最適化': 'fastest opt.',
    '実機(Linux 上、50 MHz)。最大最適化以外は -O2。BENCH.md 8・17 章':
        'On the board (under Linux, 50 MHz). -O2 except "fastest opt.". BENCH.md 8 and 17',
    # workload
    'CPI(小さいほど速い)': 'CPI (lower is faster)', 'ユーザモード': 'user mode',
    'カーネルが主(ファイル、SD、fork、ネットワーク)': 'kernel heavy (files, SD, fork, network)',
    'L2 なし(10-06)': 'no L2 (10-06)',
    '×: L2 なし → Rev.01 の速さ。ls -lR は Zbc で命令数も減った。BENCH.md 14・15・25 章':
        '×: speed, no L2 → Rev.01. ls -lR also runs fewer instructions with Zbc. BENCH.md 14, 15, 25',
    # wns
    '50 MHz を満たすまで(09-22〜24)': 'Closing 50 MHz (09-22 to 24)',
    '初回': 'first', '段階1': 'step 1', '段階2': 'step 2', 'やり直し': 'redo', '案1': 'option 1',
    'MR 段': 'MR stage', '隠れ経路': 'hidden path',
    'ステージ MR を足して(7→8 段)解決': 'Solved by adding stage MR (7 → 8 stages)',
    '機能・性能を足しながら(09-25〜10-12)': 'While adding features (09-25 to 10-12)',
    'JTAG を足して −0.034': 'JTAG added: −0.034', 'PMP の経路': 'PMP path',
    '0 を割るたびに経路を読んで直す(T1〜T7)': 'Each time it fell to 0, the path was read and fixed (T1 to T7)',
    'post-route WNS、50 MHz(20 ns)、TIMING.md 1〜44 章': 'post-route WNS, 50 MHz (20 ns), TIMING.md 1 to 44',
    # prefetch
    'I$ プリフェッチを入れたときの CPI の変化': 'CPI change with the I$ prefetch',
    'シミュレーション': 'Simulation', '(メモリが即答)': '(memory answers at once)',
    '実機 tftp': 'Board tftp', '実機 sdread': 'Board sdread', '実機 forkexec': 'Board forkexec',
    '(遅れのモデル)': '(latency model)', '← 速くなる   遅くなる →': '← faster   slower →',
    # verification
    'BFM + AXI メモリ': 'BFM + AXI memory', '波形で確かめる': 'checked in waveforms',
    '参照モデル + ランダム': ('Reference model + random', 0.85), 'キャッシュ、19 構成の掃引': 'caches, sweep of 19 configs',
    'バグ注入': 'Bug injection', 'テストの検出力を測る': 'how much the tests catch',
    '自作テスト + riscv-tests': 'Own tests + riscv-tests', 'コア、背圧をかけて': 'core, with back pressure',
    '本物の BIOS・Linux を': ('The real BIOS and Linux', 0.9), 'シミュレーションで(SIM_BIOS)': 'in simulation (SIM_BIOS)',
    'CPU と DMA を同時に': 'CPU and DMA together', 'ランダム(実機の WARNING から)': 'random (from a board WARNING)',
    'PMU と perf で実機を測る': ('Board measured by PMU, perf', 0.82), 'workload.sh、関数ごと': 'workload.sh, by function',
    'メモリの遅れのモデル': ('Memory latency model', 0.9), 'シミュが実機と同じ判定に': 'sim agrees with the board',
    '黄色: 実機で問題が出てから足した方法 ─ 実機が検証の穴を教える':
        'Yellow: added after a problem on the board. The board shows the holes in verification',
}

def text_sub(m):
    attrs, body = m.group(1), html.unescape(m.group(2))
    if not re.search(r'[\u3000-\u30ff\u4e00-\u9fff\uff00-\uffef〜]', body):
        return m.group(0)
    if body not in EN:
        sys.exit(f'no English for {body!r}')
    v = EN[body]
    t, k = (v, 1.0) if isinstance(v, str) else v
    if k != 1.0:
        attrs = re.sub(r'font-size="([\d.]+)"', lambda a: f'font-size="{float(a.group(1)) * k:.1f}"', attrs)
    return f'<text{attrs}>{html.escape(t)}</text>'

for n in NAMES:
    s = open(os.path.join(FIGS, n + '.svg')).read()
    s = re.sub(r'<text([^>]*)>([^<]*)</text>', text_sub, s)
    open(os.path.join(FIGS, n + '_en.svg'), 'w').write(s)
print('English figures ->', FIGS)
