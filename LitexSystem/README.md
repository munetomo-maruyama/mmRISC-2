# LitexSystem — mmRISC-2 の LiteX / Linux システム

Digilent Arty A7-100T 上に、**CPU が mmRISC-2 の** LiteX SoC を組み、
Linux を起動するための一式。

隣の `LitexRocket/` は**参考用**で、同じボードに LiteX 標準の Rocket Chip を
載せて Linux 起動まで到達済みのもの(git 管理外)。そこで確立した
ソフトウェア一式と SD カードの作り方をそのまま使い、**CPU だけ差し替える**のが
ここの仕事。

## なぜ差し替えだけで済むか

LiteX が吐いたメモリマップが Rocket 構成と**バイト単位で一致**した。

| | mmRISC-2 | Rocket |
|---|---|---|
| rom / sram / csr | 0x1000_0000 / 0x1100_0000 / 0x1200_0000 | 同じ |
| main_ram | 0x8000_0000 | 同じ |
| clint / plic | 0x0200_0000 / 0x0C00_0000 | 同じ |
| uart / timer0 / sdcard 割り込み | 0 / 1 / 2 (PLIC では +1) | 同じ |

したがってデバイスツリーは Rocket のものから **CPU ノードだけ**を書き換えれば
よい(`software/mmrisc_arty.dts`)。OpenSBI・Linux・ルートファイルシステムは
そのまま使える。

## 構成

```
LitexSystem/
├── cpu/mmrisc/          LiteX の CPU ラッパ(Python)と C ランタイム
│   ├── core.py          バス・メモリマップ・パラメータ・RTL ファイル一覧
│   ├── system.h         キャッシュ操作(fence.i)
│   ├── irq.h            PLIC。Rocket と同一配置なのでほぼそのまま
│   ├── crt0.S           起動とトラップ入口(シングルコア版)
│   └── boot-helper.S
├── scripts/
│   ├── build_soc.sh     SoC 生成(Linux 側。Vivado は走らせない)
│   └── build_digilent_arty.bat   Vivado 実行(Windows 側)
├── software/
│   ├── mmrisc_arty.dts  デバイスツリー
│   └── mmrisc_arty.dtb
├── docs/BRINGUP.md      手順と、確認済み・未確認の切り分け
└── build/               生成物(git 管理外)
```

## 手順

```bash
# 1. SoC を生成(Linux VM)
./scripts/build_soc.sh

# 2. ビットストリーム(Windows VM の Vivado 2025.1)
#    build/gateware/ で build_digilent_arty.bat を実行

# 3. OpenSBI を新しい DTB で再ビルド、SD カードへ
#    docs/BRINGUP.md を参照
```

## LiteX 側に手を入れていない

LiteX は `core.py` を持つディレクトリを、自分のツリーと**カレントディレクトリ**の
両方から拾う(`litex/soc/cores/cpu/__init__.py` の `collect_cpus`)。
`build_soc.sh` が `LitexSystem/cpu` から起動するので、`--cpu-type mmrisc` が
そのまま通る。LiteX のチェックアウトは一切変更していない。
