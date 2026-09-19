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
│   │   ├── CACHE_TAG_ARRAY/    タグ + 有効 + ダーティ
│   │   └── CACHE_DATA_ARRAY/   データ配列
│   ├── CPU_DBG/        デバッグ論理  → CPU_DBG_SPEC.md
│   │   ├── CPU_DBG/        デバッグ論理のトップ
│   │   ├── DBG_DTM/        JTAG DTM(Debug Spec 1.0)
│   │   ├── DBG_CJTAG/      cJTAG (OScan1) アダプタ
│   │   ├── DBG_CDC/        DTM ↔ DM のクロック載せ替え
│   │   ├── DBG_DM/         デバッグモジュール(abstract command、SBA、認証)
│   │   ├── DBG_BUSMST/     デバッグ用バスマスタ
│   │   └── DBG_HART_STUB/  CPU コア実装までのハート代用
│   └── CPU_BFM/        CPU コア代用の BFM(シミュレーション用)
└── BUS/
    ├── BUS_ARB/            AXI4 マスタ調停
    ├── AXI4_ADDR_NARROW/   AXI4 アドレス幅変換
    ├── AXIL_ADDR_NARROW/   AXI4-Lite アドレス幅変換
    ├── AXI4_RAM/           シミュレーション/FPGA 用 RAM(メモリバス)
    └── AXIL_RAM/           シミュレーション/FPGA 用 RAM(周辺バス)

SIM/
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

## シミュレーション

各ディレクトリで `make`(Verilator)。`make iverilog` で Icarus Verilog でも同じ試験を実行できる。

| コマンド | 内容 | 結果 |
|---|---|---|
| `cd SIM/SIM_CACHE && make` | L1 キャッシュ全試験 | PASS 8817 チェック |
| `cd SIM/SIM_CACHE && ./sweep.sh` | パラメータ掃引 18 構成 | 全 PASS |
| `cd SIM/SIM_CACHE && ./bug_inject.sh` | バグ注入 18 種 | 全て検出 |
| `cd SIM/SIM_DBG && make` | デバッグ論理 | PASS 3010 チェック |
| `cd SIM/SIM_DBG && ./bug_inject.sh` | バグ注入 15 種 | 全て検出 |
| `cd SIM/SIM_CPU && make` | CPU_TOP のバス | PASS 47351 チェック |
| `cd SIM/SIM_OCD && make` | OpenOCD 協調シミュレーション | PASS |

必要なツール: Verilator 5.x、Icarus Verilog 12、GTKWave、riscv-openocd。

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
| CPU_TOP への組み込み | これから |
| CPU コア(パイプライン)と MMU | これから |
| L2 キャッシュ | CPU ブロック完成後に検討 |
