# mmRISC-2

64bit RISC-V CPU(RV64GC、MMU、内蔵 CLINT/PLIC、JTAG/cJTAG オンチップデバッグ)を
SystemVerilog で自作し、Digilent Arty A7-100T 上で Linux を動かすプロジェクト。
周辺回路と Linux は LiteX から持ってくる。

**現状(2026-09)**: Arty A7-100T の実機(50 MHz)で、LiteX BIOS → OpenSBI → Linux が
SD カードの ext4 から BusyBox のシェルまで起動し、Ethernet(DHCP、ping、BIOS の TFTP
ネットブート)も動く。30 分の負荷試験(ネットワーク・SD カード・メモリの同時照合)は
PASS。立ち上げの経緯は [`LitexSystem/docs/BRINGUP.md`](LitexSystem/docs/BRINGUP.md)。

## ディレクトリ構成

```
RTL/
├── TOP/            FPGA 単体のトップ(CPU_TOP + テスト用 RAM。デバッグ論理の実機確認用)
├── CPU/
│   ├── CPU_TOP/        CPU ブロックのトップ。コア・キャッシュ・MMIO・デバッグ・DMA ポートをまとめる
│   ├── CPU_CORE/       CPU コア  → CPU_CORE_SPEC.md
│   │   ├── CPU_CORE/       コアのトップ(IF1/IF2/FQ/ID/EX/MR/MA/WB の 8 段、フォワーディング、トラップ)
│   │   ├── CORE_IFU/       命令フェッチ(PC、未処理要求 FIFO、フェッチキュー)
│   │   ├── CORE_BTB/       分岐予測(BTB)
│   │   ├── CORE_DEC/       命令デコーダ
│   │   ├── CORE_DECOMP/    圧縮命令(C)を 32bit 命令に伸張
│   │   ├── CORE_CSR/       CSR ファイルとトラップ状態(M / S / U)
│   │   ├── CORE_MDU/       乗除算器(M)
│   │   ├── CORE_FRF/       浮動小数点レジスタファイル(32×64、3R1W)
│   │   ├── CORE_RF/        整数レジスタファイル(32×64bit、2R1W)
│   │   ├── CORE_EXU/       ALU、分岐条件、アドレス生成
│   │   └── CORE_LSU/       ロード/ストアユニット(データキャッシュポート)
│   ├── CPU_MMU/        Sv39 MMU と PMP
│   │   ├── CORE_MMU/       ITLB / DTLB / ウォーカ / PMP のまとめ
│   │   ├── MMU_TLB/        TLB
│   │   ├── MMU_PTW/        ページテーブルウォーカ
│   │   └── MMU_PMP/        PMP(8 エントリ)
│   ├── CPU_FPU/        浮動小数点ユニット(F/D)
│   │   ├── CORE_FPU/       全演算(積和 1 本、反復除算/平方根)
│   │   └── FPU_ROUND/      正規化・丸め・詰め込み(2 サイクル)
│   ├── CPU_CACHE/      L1 命令/データキャッシュ  → CPU_CACHE_SPEC.md
│   │   ├── CPU_CACHE/      I$ + D$ + BUS_ARB
│   │   ├── ICACHE/         命令キャッシュ
│   │   ├── DCACHE/         データキャッシュ(MSHR、書き戻し、AMO/LR-SC、ライトスルー)
│   │   ├── CACHE_PORT_ARB/ D$ ポートの調停(CPU と第 2 ポート)
│   │   ├── CACHE_TAG_ARRAY/    タグ + 有効 + ダーティ
│   │   └── CACHE_DATA_ARRAY/   データ配列
│   ├── CPU_DMA/        DMA ポート(SoC の DMA をデータキャッシュ経由でメモリへ。一貫性をハードで保つ)
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
│   │   └── DBG_HART_STUB/  ハートの代用(コアとはまだつないでいない。halt / resume は未対応)
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
├── SIM_CPU/        CPU_TOP のバス検証
├── SIM_SYS/        コア + 本物のキャッシュ + AXI + DMA ポート(バグ注入)
├── SIM_BIOS/       LiteX BIOS と Linux(OpenSBI → Linux → BusyBox、SD カードのモデル)
├── SIM_DBG/        デバッグ論理(JTAG / cJTAG)
└── SIM_OCD/        OpenOCD との協調シミュレーション(remote_bitbang)

LitexSystem/        LiteX の SoC に mmRISC-2 を載せ、Arty で Linux を動かす一式  → LitexSystem/README.md
FPGA/ARTY_A7_100T/  LiteX なしの単体ビルド(デバッグ論理の確認用)、制約、OpenOCD 設定
Spec/               RISC-V 公式仕様書(PDF)
LitexRocket/        Rocket 構成の LiteX 一式(ワークスペース、カーネル、BusyBox。リポジトリには含めない)
```

仕様書は各ブロックのディレクトリ直下に置く。

| 仕様書 | 内容 |
|---|---|
| [`RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md`](RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md) | L1 キャッシュ(パラメータ、インタフェース、動作、検証結果) |
| [`RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md`](RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md) | デバッグ論理(JTAG/cJTAG DTM、DM、認証、FPGA 確認結果) |
| [`RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md) | CPU コア(命令セット、パイプライン、MMU、CSR、実装順序) |
| [`LitexSystem/docs/BRINGUP.md`](LitexSystem/docs/BRINGUP.md) | 実機の立ち上げ記録(止まった場所、原因、修正)と手順 |
| [`LitexSystem/docs/TIMING.md`](LitexSystem/docs/TIMING.md) | 50 MHz のタイミング収束の記録 |
| [`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md) | SD カードの作り方、Ethernet、TFTP ネットブート、負荷試験 |

## シミュレーション

各ディレクトリで `make`(Verilator)。`make iverilog` で Icarus Verilog でも同じ試験を実行できる。

| コマンド | 内容 | 結果 |
|---|---|---|
| `cd SIM/SIM_CORE && make` | CPU コアの命令試験(RV64IMAFDC + Zicsr + トラップ + CLINT) | 全 PASS |
| `cd SIM/SIM_CORE && make stress` | 両キャッシュポートに背圧を入れて同じ試験 | 全 PASS |
| `cd SIM/SIM_CORE && make clint` | CLINT のマルチハート・レジスタマップ(4 ハート) | PASS 32 チェック |
| `cd SIM/SIM_CORE && make riscv-tests` | 公式 riscv-tests(rv64ui / um / ua / uc / uf / ud / mi) | 132 PASS、既知の不合格 5(未実装機能を要求する試験) |
| `cd SIM/SIM_FPU && make` | FPU を Berkeley SoftFloat と比較 | PASS 45 万チェック |
| `cd SIM/SIM_FPU && make long` | 同上、ランダムベクタを増やす | PASS 約 494 万チェック |
| `cd SIM/SIM_CORE && ./bug_inject.sh` | バグ注入 171 種 | 170 検出。M175 は BTB の性能だけに効く変異で、機能試験では見えない(理由はスクリプト冒頭) |
| `cd SIM/SIM_CACHE && make` | L1 キャッシュ全試験(18 セクション。17 は CPU と DMA ポートを同じラインで同時にランダムに) | PASS 60263 チェック |
| `cd SIM/SIM_CACHE && make perf` | ヒット連続 / ミス連続のスループット | ヒット 1.0、ミス 12〜13、追い出し 22 サイクル/アクセス |
| `cd SIM/SIM_CACHE && make wave-perf` | 同上の波形(VCD + GTKWave 用 .gtkw) | 4 パターン |
| `cd SIM/SIM_CACHE && ./sweep.sh` | パラメータ掃引 18 構成 | 全 PASS |
| `cd SIM/SIM_CACHE && ./bug_inject.sh` | バグ注入 28 種 | 全て検出 |
| `cd SIM/SIM_DBG && make` | デバッグ論理 | PASS 3010 チェック |
| `cd SIM/SIM_DBG && ./bug_inject.sh` | バグ注入 15 種 | 全て検出 |
| `cd SIM/SIM_CPU && make` | CPU_TOP のバスと L1 キャッシュ経路 | PASS |
| `cd SIM/SIM_SYS && make` | コア + 本物のキャッシュ + AXI + DMA ポート(自作試験と riscv-tests) | 全 PASS |
| `cd SIM/SIM_SYS && ./bug_inject.sh` | バグ注入 9 種 | 全て検出 |
| `cd SIM/SIM_MMU && ./bug_inject.sh` | PMP のバグ注入 21 種 | 全て検出 |
| `cd SIM/SIM_FPU && ./bug_inject.sh` | FPU のバグ注入 25 種 | 全て検出 |
| `cd SIM/SIM_BIOS && make check` | LiteX BIOS をそのまま実行(割り込み込み) | PASS |
| `cd SIM/SIM_BIOS && make linux-sd` | SD カードのモデルから Linux を起動(実機と同じ fw_jump.bin) | BusyBox のプロンプトまで |
| `cd SIM/SIM_OCD && make` | OpenOCD 協調シミュレーション | PASS |

必要なツール: Verilator 5.x、Icarus Verilog 12、GTKWave、riscv-openocd、
riscv64-unknown-elf ツールチェイン(`/opt/riscv`)、Berkeley SoftFloat(SIM_FPU)。

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
LitexSystem/scripts/build_opensbi.sh    # デバイスツリー入りの fw_jump.bin
sudo LitexSystem/scripts/sd_rootfs.sh /media/<user>/rootfs   # SD カードのルート
```

詳細は [`LitexSystem/README.md`](LitexSystem/README.md) と
[`LitexSystem/software/boot/README.md`](LitexSystem/software/boot/README.md)。

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
| JTAG / cJTAG デバッグ論理 | 完了(シミュレーション、FPGA 実機とも確認済み) |
| L1 命令/データキャッシュ | 完了(掃引・バグ注入、CPU と DMA の同時ランダム試験まで)。DMA ポート付き |
| CPU コア | RV64GC、M / S / U、8 段パイプライン。riscv-tests 132 本 PASS |
| MMU (Sv39) と PMP | 完了 |
| LiteX SoC 上の Linux | 実機(Arty A7-100T、50 MHz)で SD カードの ext4 から BusyBox まで。Ethernet(DHCP、TFTP ネットブート)。負荷試験 30 分 PASS |
| JTAG でコアをデバッグ | 未(Arty の USB からの JTAG 配線、デバッグモジュールとコアの接続) |
| L2 キャッシュ | 未(今の構成は L2 なし) |
