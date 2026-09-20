# mmRISC-2

64bit RISC-V CPU(RV64GC、MMU、内蔵 CLINT/PLIC、JTAG/cJTAG オンチップデバッグ)を
SystemVerilog で自作し、Digilent Arty A7-100T 上で Linux を動かすプロジェクト。
周辺回路と Linux は LiteX から持ってくる。

## ディレクトリ構成

```
RTL/
├── TOP/            FPGA トップ(CPU_TOP + テスト用 RAM)
├── CPU/
│   ├── CPU_TOP/        CPU ブロックのトップ。デバッグ論理・キャッシュ・バス調停をまとめる
│   ├── CPU_CACHE/      L1 命令/データキャッシュ  → CPU_CACHE_SPEC.md
│   │   ├── CPU_CACHE/      I$ + D$ + BUS_ARB
│   │   ├── ICACHE/         命令キャッシュ
│   │   ├── DCACHE/         データキャッシュ(MSHR、書き戻し、AMO/LR-SC)
│   │   ├── CACHE_PORT_ARB/ D$ ポートの調停(CPU 優先、デバッガと共有)
│   │   ├── CACHE_TAG_ARRAY/    タグ + 有効 + ダーティ
│   │   └── CACHE_DATA_ARRAY/   データ配列
│   ├── CPU_CORE/       CPU コア  → CPU_CORE_SPEC.md
│   │   ├── CPU_CORE/       コアのトップ(IF1/IF2/ID/EX/MA/WB、フォワーディング)
│   │   ├── CORE_IFU/       命令フェッチ(PC、未処理要求 FIFO、フェッチキュー)
│   │   ├── CORE_DEC/       命令デコーダ
│   │   ├── CORE_DECOMP/    圧縮命令(C)を 32bit 命令に伸張
│   │   ├── CORE_CSR/       CSR ファイルとトラップ状態(M-mode)
│   │   ├── CORE_MDU/       乗除算器(M)
│   │   ├── CORE_FRF/       浮動小数点レジスタファイル(32×64、3R1W)
│   │   ├── CORE_RF/        整数レジスタファイル(32×64bit、2R1W)
│   │   ├── CORE_EXU/       ALU、分岐条件、アドレス生成
│   │   └── CORE_LSU/       ロード/ストアユニット(データキャッシュポート)
│   ├── CPU_FPU/        浮動小数点ユニット(F/D)
│   │   ├── CORE_FPU/       全演算(積和 1 本、反復除算/平方根)
│   │   └── FPU_ROUND/      正規化・丸め・詰め込み(丸めるものは全部ここ)
│   ├── CPU_CLINT/      CLINT(msip / mtime / mtimecmp)
│   ├── CPU_DBG/        デバッグ論理  → CPU_DBG_SPEC.md
│   │   ├── CPU_DBG/        デバッグ論理のトップ
│   │   ├── DBG_DTM/        JTAG DTM(Debug Spec 1.0)
│   │   ├── DBG_CJTAG/      cJTAG (OScan1) アダプタ
│   │   ├── DBG_CDC/        DTM ↔ DM のクロック載せ替え
│   │   ├── DBG_DM/         デバッグモジュール(abstract command、SBA、認証)
│   │   ├── DBG_BUSMST/     デバッグ用バスマスタ(周辺バス)
│   │   ├── DBG_CACHE/      デバッグアクセスをデータキャッシュへ
│   │   └── DBG_HART_STUB/  CPU コア実装までのハート代用
│   └── CPU_BFM/        CPU コア代用の BFM(シミュレーション用)
└── BUS/
    ├── BUS_ARB/            AXI4 マスタ調停
    ├── AXI4_ADDR_NARROW/   AXI4 アドレス幅変換
    ├── AXIL_ADDR_NARROW/   AXI4-Lite アドレス幅変換
    ├── AXI4_RAM/           シミュレーション/FPGA 用 RAM(メモリバス)
    └── AXIL_RAM/           シミュレーション/FPGA 用 RAM(周辺バス)

SIM/
├── SIM_CORE/       CPU コアの検証(アセンブラ試験、背圧注入、バグ注入)
├── SIM_FPU/        FPU の検証(Berkeley SoftFloat と突き合わせ)
├── SIM_CACHE/      L1 キャッシュの検証(参照モデル、パラメータ掃引、バグ注入)
├── SIM_DBG/        デバッグ論理の検証(JTAG / cJTAG)
├── SIM_CPU/        CPU_TOP のバス検証
└── SIM_OCD/        OpenOCD との協調シミュレーション(remote_bitbang)

FPGA/ARTY_A7_100T/  Vivado ビルドスクリプト、制約、OpenOCD 設定、レポート
Spec/               RISC-V 公式仕様書(PDF)
LitexRocket/        参考用(リポジトリには含めない)
```

仕様書は各ブロックのディレクトリ直下に置く。

| 仕様書 | 内容 |
|---|---|
| [`RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md`](RTL/CPU/CPU_CACHE/CPU_CACHE_SPEC.md) | L1 キャッシュ(パラメータ、インタフェース、動作、検証結果) |
| [`RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md`](RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md) | デバッグ論理(JTAG/cJTAG DTM、DM、認証、FPGA 確認結果) |
| [`RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md) | CPU コア(命令セット、パイプライン、MMU、CSR、実装順序) |

## シミュレーション

各ディレクトリで `make`(Verilator)。`make iverilog` で Icarus Verilog でも同じ試験を実行できる。

| コマンド | 内容 | 結果 |
|---|---|---|
| `cd SIM/SIM_CORE && make` | CPU コアの命令試験(RV64IMAFDC + Zicsr + トラップ + CLINT) | 全 PASS |
| `cd SIM/SIM_CORE && make stress` | 両キャッシュポートに背圧を入れて同じ試験 | 全 PASS |
| `cd SIM/SIM_CORE && make clint` | CLINT のマルチハート・レジスタマップ(4 ハート) | PASS 32 チェック |
| `cd SIM/SIM_CORE && make riscv-tests` | 公式 riscv-tests(rv64ui / um / ua / uc / uf / ud / mi) | 124 PASS、既知の不合格 6(未実装機能を要求する試験) |
| `cd SIM/SIM_FPU && make` | FPU を Berkeley SoftFloat と比較 | PASS 45 万チェック |
| `cd SIM/SIM_FPU && make long` | 同上、ランダムベクタを増やす | PASS 約 494 万チェック |
| `cd SIM/SIM_CORE && ./bug_inject.sh` | バグ注入 90 種 | 全て検出 |
| `cd SIM/SIM_CACHE && make` | L1 キャッシュ全試験 | PASS 8817 チェック |
| `cd SIM/SIM_CACHE && make perf` | ヒット連続 / ミス連続のスループット | ヒット 1.0、ミス 12〜13、追い出し 22 サイクル/アクセス |
| `cd SIM/SIM_CACHE && make wave-perf` | 同上の波形(VCD + GTKWave 用 .gtkw) | 4 パターン |
| `cd SIM/SIM_CACHE && ./sweep.sh` | パラメータ掃引 18 構成 | 全 PASS |
| `cd SIM/SIM_CACHE && ./bug_inject.sh` | バグ注入 20 種 | 全て検出 |
| `cd SIM/SIM_DBG && make` | デバッグ論理 | PASS 3010 チェック |
| `cd SIM/SIM_DBG && ./bug_inject.sh` | バグ注入 15 種 | 全て検出 |
| `cd SIM/SIM_CPU && make` | CPU_TOP のバスと L1 キャッシュ経路 | PASS |
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

## FPGA

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
| L1 命令/データキャッシュ | 完了(掃引・バグ注入まで) |
| CPU_TOP への組み込み | 完了(BFM がキャッシュを駆動、デバッガも D$ 経由)。FPGA 実機で OpenOCD から D$ 経由のアクセスを確認済み |
| CPU コア(パイプライン) | 仕様 Rev-1 策定済み、これから実装 |
| MMU (Sv39) | コアが M-mode で動いたあと(CPU_CORE_SPEC.md M5) |
| L2 キャッシュ | CPU ブロック完成後に検討 |
