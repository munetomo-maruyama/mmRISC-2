# LitexSystem — mmRISC-2 の LiteX / Linux システム

Digilent Arty A7-100T 上に、**CPU が mmRISC-2 の** LiteX SoC を組み、
Linux を起動するための一式。

隣の `LitexRocket/` は**参考用**で、同じボードに LiteX 標準の Rocket Chip を
載せて Linux 起動まで到達済みのもの(git 管理外)。そこで確立した
ソフトウェア一式と SD カードの作り方をそのまま使い、**CPU だけ差し替える**のが
ここの仕事。

## 現状(2026-09)

実機(50 MHz)で LiteX BIOS → OpenSBI → Linux が SD カードの ext4 から BusyBox の
シェルまで起動し、Ethernet(DHCP、ping、BIOS の TFTP ネットブート)も動く。
途中で見つかった問題と修正は `docs/BRINGUP.md`、タイミングは `docs/TIMING.md`。
JTAG / cJTAG のデバッグポートを PMOD JA に出してある(`docs/JTAG.md`。ピン配置は
`FPGA/ARTY_A7_100T` と同じ)。

## Rocket 構成との違い

始めは Rocket 構成とメモリマップがバイト単位で一致していたので、デバイスツリーは
CPU ノードだけ書き換えれば済んだ。その後、次の 3 点が変わっている。

- **L2 なし**(`--l2-size 0`)。mmRISC-2 はメモリバスを直接 LiteDRAM につなぐ。
- **DMA ポート**。SD カードや Ethernet の DMA を CPU のデータキャッシュ経由で
  メモリへ通す(`dma_bus`)。Linux が前提にする DMA の一貫性をハードウェアで保つ。
- **Ethernet**(`--with-ethernet --eth-dhcp`)。ethmac / ethphy が CSR の先頭に
  入ったので、SD カード・timer0・UART の CSR が 0x1000 ずつ後ろへずれ、割り込みは
  uart 0、timer0 1、ethmac 2、sdcard 3(PLIC では +1)になった。

OpenSBI(デバイスツリーは `fw_jump.bin` に埋め込み)とルートファイルシステムは
このディレクトリで作る。Linux の `Image` と `boot.json` は Rocket 構成のものを
そのまま使う。**ビットストリームと `fw_jump.bin` は組で使う**(配置が違うと UART の
場所がずれ、何も表示されない)。

## 構成

```
LitexSystem/
├── cpu/mmrisc/          LiteX の CPU ラッパ(Python)と C ランタイム
│   ├── core.py          バス・メモリマップ・パラメータ・RTL ファイル一覧
│   ├── system.h         キャッシュ操作(fence.i)
│   ├── irq.h            PLIC
│   ├── crt0.S           起動とトラップ入口(シングルコア版)
│   └── boot-helper.S
├── scripts/
│   ├── build_soc.sh     SoC 生成(Linux 側。Vivado は走らせない)
│   ├── build_digilent_arty.bat   Vivado 実行(Windows 側)
│   ├── build_opensbi.sh デバイスツリー入りの fw_jump.bin
│   ├── sd_rootfs.sh     SD カードのルートファイルシステムを書く
│   └── jtag_check.tcl   実機の JTAG 確認(OpenOCD)
├── software/
│   ├── mmrisc_arty.dts  デバイスツリー
│   ├── boot/            SD カードの第 1 パーティションに置くもの(fw_jump.bin)と手順
│   └── rootfs/          ルートファイルシステムに足すもの(inittab、udhcpc のスクリプト、
│                        負荷試験 stress.sh)
├── docs/
│   ├── BRINGUP.md       立ち上げ記録と手順
│   ├── TIMING.md        タイミング収束の記録
│   ├── JTAG.md          JTAG / cJTAG デバッグ(ピン、スイッチ、OpenOCD)
│   └── TFTP_SERVER.md   Parallels 上の Ubuntu を TFTP サーバにする手順
└── build/               生成物(git 管理外)
```

## 手順

```bash
# 1. SoC を生成(Linux VM)
./scripts/build_soc.sh

# 2. ビットストリーム(Windows VM の Vivado)
#    build/gateware/ で build_digilent_arty.bat を実行

# 3. OpenSBI をデバイスツリー込みで作り、SD カードの第 1 パーティションへ
./scripts/build_opensbi.sh          # -> software/boot/fw_jump.bin

# 4. SD カードの第 2 パーティション(ext4)
sudo ./scripts/sd_rootfs.sh /media/<user>/rootfs
```

SD カードの作り方、Ethernet、TFTP ネットブート、負荷試験は
`software/boot/README.md`。

## LiteX 側に手を入れていない

LiteX は `core.py` を持つディレクトリを、自分のツリーと**カレントディレクトリ**の
両方から拾う(`litex/soc/cores/cpu/__init__.py` の `collect_cpus`)。
`build_soc.sh` が `LitexSystem/cpu` から起動するので、`--cpu-type mmrisc` が
そのまま通る。LiteX のチェックアウトは一切変更していない。
