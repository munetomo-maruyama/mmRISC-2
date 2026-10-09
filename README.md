# mmRISC-2

64bit RISC-V CPU を SystemVerilog で自作し、Digilent Arty A7-100T 上で Linux を動かすプロジェクト。周辺回路は LiteX から持ってくる。CPU が持つもの:

- RV64GC(IMAFDC)+ Zba / Zbb / Zicond
- M / S / U モード、PMP
- Sv39 MMU(ITLB / DTLB、ハードウェアのページテーブルウォーカ)
- 8 段のインオーダ・パイプライン
- 分岐予測(BTB 256 エントリ、gshare、戻りアドレススタック)
- FPU(単精度・倍精度)
- L1 キャッシュ(I$ / D$ 各 16 KB、D$ はノンブロッキング・書き戻し)
- **L2 キャッシュ(256 KB)**
- SoC の DMA も D$ を通し、キャッシュの一貫性をハードウェアで保つ
- 内蔵の CLINT / PLIC、Sstc(S モードのタイマ)
- JTAG / cJTAG のオンチップデバッグ(Debug Spec 1.0、ハードウェアトリガ 4 本)
- 性能カウンタ(Zihpm、Sscofpmf。Linux の `perf` で使える)

## 現状(2026-10-09)

Arty A7-100T の実機(50 MHz)で、LiteX BIOS → OpenSBI → **Linux 7.2** が SD カードの ext4
から BusyBox のシェルまで起動し、Ethernet(DHCP、TFTP)も動く。120 分の負荷試験(メモリ・
Ethernet・SD カードの同時照合)は、L2 キャッシュを入れた版でも PASS(2026-10-09)。

| | |
|---|---|
| 性能(実機、Linux 上) | **2.786 CoreMark/MHz**(Zba/Zbb で作ったもの。rv64gc なら 2.498)、**1.496 DMIPS/MHz**。自作の始めの 1.584 / 0.823 から +76 % / +82 %。L2 キャッシュでカーネルが主の負荷(TFTP、SD の読み出し、`ls -lR`)が 1.5〜1.7 倍 |
| ISA | RV64IMAFDC、Zicsr、Zifencei、Zicntr、Zihpm、**Zba、Zbb、Zicond**、Zihintpause、Zihintntl、M / S / U、Sv39、PMP 8 エントリ |
| 特権の拡張 | **Sstc**(S モードのタイマ)、**Sscofpmf**(性能カウンタのあふれ割り込み)、**Smcntrpmf**、**Sdtrig**(デバッグのトリガ 4 本)、特権仕様 1.12 |
| 性能カウンタ | `hpmcounter3`〜`6`、イベント 19 種(キャッシュ・L2・TLB のミス、分岐予測ミス、停止の理由)。Linux の `perf stat` / `perf record` で使える |
| デバッグ | JTAG / cJTAG(Debug Spec 1.0)。OpenOCD / gdb で halt / step / レジスタ / メモリ、ソフトウェアとハードウェアのブレークポイント、ウォッチポイント(動いている Linux カーネルにも置ける) |
| FPGA | 50 MHz で WNS +0.159 ns、LUT 46,957 / 63,400(74.1 %)、スライス 91.4 %、ブロック RAM 108.5 / 135 タイル(L2 を含む) |

**コアの構成**

- 8 段のパイプライン(IF1 / IF2 / FQ / ID / EX / MR / MA / WB)、1 命令ずつ順に発行
- 転送(フォワーディング)は EX・MR・MA から
- 分岐予測: BTB 256 エントリ、gshare(PHT 8192)、戻りアドレススタック
- ロードの値で決まる分岐は MR で確定する
- ロード・ストアは EX から D$ に出し、ヒットの答えは 2 サイクル後(命令が MA に着いたサイクル)に見える
- そのため MA は待たず、ヒットするロード・ストアは**毎サイクル 1 本ずつ**(スループット 1)進む
- 待つのは、ロードの結果を直後の命令が使うとき(ロードユース)だけ。依存するロードの連鎖で 1 回 約 3 サイクル
- 乗算 1〜2 サイクル、除算は早期終了つき
- L1 キャッシュ: I$ / D$ 各 16 KiB(4 ウェイ、64 B 行)、D$ はノンブロッキング・ライトバック
- SoC の DMA も D$ を通るので、一貫性はハードウェアで保つ
- FPU(F / D): 積和 1 本、除算・平方根は反復
- L2 キャッシュ: 256 KB(4 ウェイ、64 B 行、書き戻し)を L1 と LiteDRAM の間に置く
- L2 のヒットで L1 のミス 1 回が 31 → 14 サイクルになり、カーネルの負荷で 85〜95 % 当たる([`BENCH.md`](LitexSystem/docs/BENCH.md) 15 章)

立ち上げの経緯は [`LitexSystem/docs/BRINGUP.md`](LitexSystem/docs/BRINGUP.md)、性能の作業と
実機の内訳は [`LitexSystem/docs/BENCH.md`](LitexSystem/docs/BENCH.md)、次のテーマは
[`LitexSystem/docs/ROADMAP.md`](LitexSystem/docs/ROADMAP.md)。

## 文書

| 文書 | 内容 |
|---|---|
| [`RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md) | CPU コア(命令セット、パイプライン、MMU、CSR、デバッグ、決定事項 1〜69) |
| [`RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md`](RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md) | L1 キャッシュ(パラメータ、インタフェース、動作、検証結果) |
| [`RTL/CPU/CPU_L2/CPU_L2_SPEC.md`](RTL/CPU/CPU_L2/CPU_L2_SPEC.md) | L2 キャッシュ(方式、動作、資源、検証、実機の効果) |
| [`RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md`](RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md) | デバッグ論理(JTAG/cJTAG DTM、DM、認証) |
| [`LitexSystem/README.md`](LitexSystem/README.md) | LiteX の SoC に載せて Linux を動かす一式 |
| [`LitexSystem/docs/BRINGUP.md`](LitexSystem/docs/BRINGUP.md) | 実機の立ち上げ記録(止まった場所、原因、修正)と手順 |
| [`LitexSystem/docs/BENCH.md`](LitexSystem/docs/BENCH.md) | 性能測定(シミュレーションと実機、PMU で見たサイクルの行き先、版ごとの推移) |
| [`LitexSystem/docs/TIMING.md`](LitexSystem/docs/TIMING.md) | 50 MHz のタイミング収束の記録 |
| [`LitexSystem/docs/JTAG.md`](LitexSystem/docs/JTAG.md) | JTAG / cJTAG デバッグ(ピン、スイッチ、OpenOCD) |
| [`LitexSystem/docs/ROADMAP.md`](LitexSystem/docs/ROADMAP.md) | 次の設計テーマ |
| [`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md) | SD カードの作り方、Ethernet、TFTP ネットブート、負荷試験、配布しているバイナリ |
| [`LitexSystem/software/bench/README.md`](LitexSystem/software/bench/README.md) | 実機のベンチマークと `perf` |
| [`SIM/SIM_CORE/README.md`](SIM/SIM_CORE/README.md) | コアの検証環境(自作試験 32 本、riscv-tests、バグ注入) |

## ディレクトリ構成

```
RTL/
├── TOP/            FPGA 単体のトップ(CPU_TOP + テスト用 RAM。デバッグ論理の実機確認用)
├── CPU/
│   ├── CPU_TOP/        CPU ブロックのトップ。コア・キャッシュ・MMIO・デバッグ・DMA ポートをまとめる
│   ├── CPU_CORE/       CPU コア  → CPU_CORE_SPEC.md
│   │   ├── CPU_CORE/       コアのトップ(8 段、フォワーディング、トラップ、トリガの照合、性能イベント)
│   │   ├── CORE_IFU/       命令フェッチ(PC、未処理要求 FIFO、フェッチキュー、分岐履歴)
│   │   ├── CORE_BTB/       分岐予測(BTB、gshare、戻りアドレススタック)
│   │   ├── CORE_DEC/       命令デコーダ
│   │   ├── CORE_DECOMP/    圧縮命令(C)を 32bit 命令に伸張
│   │   ├── CORE_CSR/       CSR とトラップ状態(M / S / U、デバッグ、トリガ、性能カウンタ)
│   │   ├── CORE_MDU/       乗除算器(M)
│   │   ├── CORE_FRF/       浮動小数点レジスタファイル(32×64、3R1W)
│   │   ├── CORE_RF/        整数レジスタファイル(32×64bit、2R1W)
│   │   ├── CORE_EXU/       ALU(Zba / Zbb / Zicond を含む)、分岐条件、アドレス生成
│   │   └── CORE_LSU/       ロード/ストアユニット(EX からの早出し、データキャッシュポート)
│   ├── CPU_MMU/        Sv39 MMU と PMP
│   │   ├── CORE_MMU/       ITLB / DTLB / ウォーカ / PMP のまとめ
│   │   ├── MMU_TLB/        TLB
│   │   ├── MMU_PTW/        ページテーブルウォーカ
│   │   └── MMU_PMP/        PMP(8 エントリ)
│   ├── CPU_FPU/        浮動小数点ユニット(F/D)
│   │   ├── CORE_FPU/       全演算(積和 1 本、反復除算/平方根)
│   │   └── FPU_ROUND/      正規化・丸め・詰め込み
│   ├── CPU_CACHE/      L1 命令/データキャッシュ  → CPU_CACHE_SPEC.md
│   │   ├── CPU_CACHE/      I$ + D$ + BUS_ARB
│   │   ├── ICACHE/         命令キャッシュ
│   │   ├── DCACHE/         データキャッシュ(MSHR、書き戻し、AMO/LR-SC、取り消し)
│   │   ├── CACHE_PORT_ARB/ D$ ポートの調停(CPU と第 2 ポート)
│   │   ├── CACHE_TAG_ARRAY/    タグ + 有効 + ダーティ
│   │   └── CACHE_DATA_ARRAY/   データ配列
│   ├── CPU_L2/         L2 キャッシュ(256 KB、L1 の後ろ)  → CPU_L2_SPEC.md
│   ├── CPU_DMA/        DMA ポート(SoC の DMA をデータキャッシュ経由でメモリへ)
│   ├── CPU_MMIO/       内蔵の CLINT / PLIC への振り分け
│   ├── CPU_CLINT/      CLINT(msip / mtime / mtimecmp)
│   ├── CPU_PLIC/       PLIC(M / S の 2 コンテキスト)
│   ├── CPU_DBG/        デバッグ論理  → CPU_DBG_SPEC.md
│   │   ├── CPU_DBG/        デバッグ論理のトップ
│   │   ├── DBG_DTM/        JTAG DTM(Debug Spec 1.0)
│   │   ├── DBG_CJTAG/      cJTAG (OScan1) アダプタ
│   │   ├── DBG_CDC/        DTM ↔ DM のクロック載せ替え
│   │   ├── DBG_DM/         デバッグモジュール(abstract command、SBA、認証)
│   │   ├── DBG_BUSMST/     デバッグ用バスマスタ(周辺バス)
│   │   ├── DBG_CACHE/      デバッグアクセスをデータキャッシュへ
│   │   └── DBG_HART_STUB/  ハートの代用(BFM の構成でだけ使う。普段はコアがハート)
│   └── CPU_BFM/        CPU コア代用の BFM(シミュレーション用)
└── BUS/
    ├── BUS_ARB/            AXI4 マスタ調停
    ├── AXI4_ADDR_NARROW/   AXI4 アドレス幅変換
    ├── AXIL_ADDR_NARROW/   AXI4-Lite アドレス幅変換
    ├── AXI4_RAM/           シミュレーション/FPGA 用 RAM(メモリバス)
    └── AXIL_RAM/           シミュレーション/FPGA 用 RAM(周辺バス)

SIM/
├── SIM_CORE/       CPU コア(自作試験、riscv-tests、背圧注入、バグ注入)
├── SIM_MMU/        PMP の単体検証(参照モデル、バグ注入)
├── SIM_FPU/        FPU(Berkeley SoftFloat と突き合わせ)
├── SIM_CACHE/      L1 キャッシュ(参照モデル、CPU と DMA の同時ランダム、パラメータ掃引、バグ注入)
├── SIM_L2/         L2 キャッシュ(参照モデル、同時ランダム、書き出しの停止、パラメータ掃引、バグ注入)
├── SIM_CPU/        CPU_TOP のバス検証
├── SIM_SYS/        コア + 本物のキャッシュ + AXI + DMA ポート(バグ注入、性能の内訳)
├── SIM_BIOS/       LiteX BIOS と Linux(OpenSBI → Linux → BusyBox、SD カードのモデル、perf)
├── SIM_DBG/        デバッグ論理(JTAG / cJTAG)
└── SIM_OCD/        OpenOCD との協調シミュレーション(remote_bitbang)

LitexSystem/        LiteX の SoC に mmRISC-2 を載せ、Arty で Linux を動かす一式  → LitexSystem/README.md
FPGA/ARTY_A7_100T/  LiteX なしの単体ビルド(デバッグ論理の確認用)、制約、OpenOCD 設定
LitexRocket/        Rocket 構成の LiteX 一式(ワークスペース、カーネルのソース、BusyBox。リポジトリには含めない)
```

## シミュレーション

各ディレクトリで `make`(Verilator)。自分で書いた参照モデルや公式の試験と突き合わせ、
わざと壊した RTL(バグ注入)を試験が見つけることまで確かめる。

| コマンド | 内容 | 結果 |
|---|---|---|
| `cd SIM/SIM_CORE && make` | CPU コアの自作試験 32 本(命令、トラップ、MMU、PMP、デバッグ、分岐予測、トリガ、性能カウンタ ほか) | 全 PASS |
| `cd SIM/SIM_CORE && make stress` | 両キャッシュポートに背圧を入れて同じ試験 | 全 PASS |
| `cd SIM/SIM_CORE && make riscv-tests` | 公式 riscv-tests(rv64ui / um / ua / uc / uf / ud / uzba / uzbb / uzicond / mi / si) | 167 PASS、既知の不合格 4(未実装機能を要求する試験) |
| `cd SIM/SIM_CORE && make riscv-tests-v` | 同じ試験を仮想記憶(Sv39)の環境で | 143 PASS、既知の不合格 4 |
| `cd SIM/SIM_CORE && make mdu / clint / plic` | 乗除算器(参照モデル 20 万演算)、CLINT(4 ハート)、PLIC | PASS |
| `cd SIM/SIM_CORE && ./bug_inject.sh` | バグ注入 297 種(背圧あり/なしの両方) | 全て検出 |
| `cd SIM/SIM_SYS && make` | コア + 本物の L1 / L2 キャッシュ + AXI + DMA ポート(自作試験 25 本、DMA・PMU などのプログラム 4 本)。`PARAMS=-GL2_SIZE=0` で L2 なし | 全 PASS(L2 あり / なし) |
| `cd SIM/SIM_SYS && make riscv-tests` | riscv-tests を本物のキャッシュ越しに | 133 PASS、既知の不合格 4 |
| `cd SIM/SIM_SYS && ./bug_inject.sh` | バグ注入 16 種 | 全て検出 |
| `cd SIM/SIM_CACHE && make` | L1 キャッシュ全試験(CPU と DMA ポートを同じラインで同時にランダムに、取り消しを含む) | PASS 64,943 チェック |
| `cd SIM/SIM_CACHE && ./bug_inject.sh` | バグ注入 40 種 | 全て検出 |
| `cd SIM/SIM_L2 && make` / `./sweep.sh` / `./bug_inject.sh` | L2 キャッシュ(256 KB・4 ウェイ)/ 容量・ウェイ・置き換えの 11 構成 / バグ注入 31 種 | PASS 約 150 万チェック / 全 PASS / 全て検出 |
| `cd SIM/SIM_MMU && make` / `./bug_inject.sh` | PMP を参照モデルと比較 / バグ注入 21 種 | PASS 20 万チェック / 全て検出 |
| `cd SIM/SIM_FPU && make` / `./bug_inject.sh` | FPU を Berkeley SoftFloat と比較 / バグ注入 33 種 | PASS 約 58 万チェック / 全て検出 |
| `cd SIM/SIM_DBG && make` / `./bug_inject.sh` | デバッグ論理 / バグ注入 15 種 | PASS 3,026 チェック / 全て検出 |
| `cd SIM/SIM_CPU && make` | CPU_TOP のバスと L1 キャッシュ経路 | PASS 46,718 チェック |
| `cd SIM/SIM_BIOS && make check` | LiteX BIOS をそのまま実行(割り込み込み) | PASS |
| `cd SIM/SIM_BIOS && make linux-sd` | SD カードのモデルから Linux を起動(実機と同じ fw_jump.bin と Image) | BusyBox のプロンプトまで |
| `cd SIM/SIM_BIOS && make linux-perf` / `make pmu-sbi` | Linux 上の `perf` / OpenSBI の PMU の呼び出しを Linux と同じ手順で | 6 カウンタ同時、あふれ割り込みで標本 / PASS |
| `cd SIM/SIM_OCD && make` | OpenOCD 協調シミュレーション(ブレークポイント、ウォッチポイント、L2 ありでの `reset halt` を含む) | PASS |

必要なツール: Verilator 5.x、Icarus Verilog 12、GTKWave、riscv-openocd、
riscv64-unknown-elf / riscv64-unknown-linux-gnu ツールチェイン(`/opt/riscv`、GCC 13.2)、
Berkeley SoftFloat(SIM_FPU)。

`make riscv-tests` は公式の riscv-tests を使う。リポジトリには含めないので、
別途取得しておく(既定の場所は `~/RISCV/riscv-tests`、`RVTESTS` で変更可)。

```
git clone --recursive https://github.com/riscv-software-src/riscv-tests ~/RISCV/riscv-tests
```

`SIM/SIM_FPU` は Berkeley SoftFloat を参照モデルにする。用意の仕方は
[`SIM/SIM_FPU/README.md`](SIM/SIM_FPU/README.md)。

## Arty で Linux を動かす(LiteX)

```
LitexSystem/scripts/build_soc.sh        # SoC と BIOS を生成(Linux 側)
# Vivado(Windows 側)で LitexSystem/build/gateware のビットストリームを作る
LitexSystem/scripts/build_opensbi.sh    # デバイスツリー入りの fw_jump.bin(パッチを当てる)
sudo LitexSystem/scripts/sd_rootfs.sh /media/<user>/rootfs   # SD カードのルート
```

SD カードの第 1 パーティション(FAT16)には `LitexSystem/software/boot/` の `Image`、
`fw_jump.bin`、`boot.json` を置く(リポジトリに入っている。ビットストリームと
`fw_jump.bin` は組で使う)。詳細は [`LitexSystem/README.md`](LitexSystem/README.md) と
[`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md)。
実機のベンチマークと `perf` は
[`LitexSystem/software/bench/README.md`](LitexSystem/software/bench/README.md)。

## FPGA(LiteX なし、デバッグ論理の確認用)

```
cd FPGA/ARTY_A7_100T
vivado -mode batch -source build.tcl
```

ビットストリームとレポートは `output/` に出る。OpenOCD の設定は `openocd/` にある。
詳細は [`FPGA/ARTY_A7_100T/README.md`](FPGA/ARTY_A7_100T/README.md)。

## 進捗

| フェーズ | 状態 |
|---|---|
| JTAG / cJTAG デバッグ論理 | 完了。コアにつないで実機で halt / step / レジスタ / メモリ / ブレークポイント |
| L1 命令/データキャッシュ | 完了(掃引・バグ注入、CPU と DMA の同時ランダム試験まで)。DMA ポート付き |
| CPU コア | RV64GC + Zba / Zbb / Zicond、M / S / U、8 段パイプライン、分岐予測(gshare) |
| MMU (Sv39) と PMP | 完了 |
| LiteX SoC 上の Linux | 実機で SD カードの ext4 から BusyBox まで。Ethernet、TFTP ネットブート。負荷試験 120 分 PASS |
| 性能 | 2.786 CoreMark/MHz、1.496 DMIPS/MHz(実機、Linux 上)。性能カウンタと `perf` で実機の内訳を測れる |
| L2 キャッシュ | 完了(256 KB、[`CPU_L2_SPEC.md`](RTL/CPU/CPU_L2/CPU_L2_SPEC.md))。実機でカーネルの負荷が 1.2〜1.7 倍 |
| 次のテーマ | 2 段目の TLB(ユーザモードの負荷)、FPU のパイプライン化の前のタイミングの手当て([`ROADMAP.md`](LitexSystem/docs/ROADMAP.md)) |

## ライセンス

このリポジトリの自作のファイル(RTL、テストベンチ、スクリプト、文書)は
[Apache License 2.0](LICENSE) で配布する。ソースを公開せずに使うこと、改変、再頒布、製品への
組み込みは自由で、条件は LICENSE と [NOTICE](NOTICE) の写しを添えることと、改変したファイルに
その旨を書くこと。

次の他者のファイルはそれぞれのライセンスに従う(詳しくは [NOTICE](NOTICE)、
[`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md)):

| ファイル | 中身 | ライセンス |
|---|---|---|
| `LitexSystem/software/boot/Image`、`linux.config` | Linux カーネル(litex-hub/linux、変更なし)とその設定 | GPL-2.0 |
| `LitexSystem/software/boot/fw_jump.bin`、`opensbi_patches/` | OpenSBI とそのパッチ | BSD-2-Clause |
| `LitexSystem/software/rootfs/usr/share/udhcpc/default.script` | BusyBox の例のスクリプト(変更なし) | GPL-2.0 |

LiteX、OpenSBI、Linux のソースそのものはリポジトリに含めず、ビルドのときに外から持ってくる。

## 参考文献

設計の拠り所にした仕様書と資料。版は参照したもの(各文書の最新版は配布元を参照)。

| 文書 | 版 | 配布元 |
|---|---|---|
| The RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture | 20260120 | [riscv/riscv-isa-manual](https://github.com/riscv/riscv-isa-manual/releases) |
| The RISC-V Instruction Set Manual, Volume II: Privileged Architecture | 20260120 | [riscv/riscv-isa-manual](https://github.com/riscv/riscv-isa-manual/releases) |
| The RISC-V Debug Specification | 1.0(2025-02-21 改訂、Ratified) | [riscv/riscv-debug-spec](https://github.com/riscv/riscv-debug-spec) |
| RISC-V Platform-Level Interrupt Controller Specification | 1.0.0(2023-03) | [riscv/riscv-plic-spec](https://github.com/riscv/riscv-plic-spec) |
| The RISC-V Advanced Interrupt Architecture | 1.0(20250312 改訂) | [riscv/riscv-aia](https://github.com/riscv/riscv-aia) |
| RISC-V IOMMU Architecture Specification | 1.0.1(2026-02-22) | [riscv-non-isa/riscv-iommu](https://github.com/riscv-non-isa/riscv-iommu) |
| RISC-V Profiles | 1.0(2023-04-02) | [riscv/riscv-profiles](https://github.com/riscv/riscv-profiles) |
| RVA23 Profiles / RVB23 Profiles | 1.0(2024-10-17) | [riscv/riscv-profiles](https://github.com/riscv/riscv-profiles) |
| Arty A7 Reference Manual、Arty A7 回路図 | | [Digilent Reference](https://digilent.com/reference/programmable-logic/arty-a7/start) |

