# LitexSystem — mmRISC-2 の LiteX / Linux システム

Digilent Arty A7-100T 上に、**CPU が mmRISC-2 の** LiteX SoC を組み、
Linux を起動するための一式。

隣の `LitexRocket/` は**参考用**で、同じボードに LiteX 標準の Rocket Chip を
載せて Linux 起動まで到達済みのもの(git 管理外)。そこで確立した
ソフトウェア一式と SD カードの作り方をそのまま使い、**CPU だけ差し替える**のが
ここの仕事。

## 現状(2026-10-05)

実機(50 MHz)で LiteX BIOS → OpenSBI → Linux 7.2 が SD カードの ext4 から BusyBox の
シェルまで起動し、Ethernet(DHCP、ping、BIOS の TFTP ネットブート)も動く。120 分の
負荷試験(メモリ・Ethernet・SD カードの同時照合)は PASS。

| | |
|---|---|
| 性能 | **2.747 CoreMark/MHz**(Zba/Zbb で作ったもの。rv64gc なら 2.462)、**1.482 DMIPS/MHz** |
| ISA(Linux から見える) | `rv64imafdc_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zba_zbb_smcntrpmf_sscofpmf_sstc`、デバッグのトリガ 4 本(Sdtrig) |
| 性能カウンタ | `hpmcounter3`〜`6`、イベント 17 種。Linux の `perf stat` / `perf record` で使える(`software/bench/perf.sh`) |
| タイミング | 50 MHz で WNS +0.452 ns(MET) |
| 資源 | LUT 45,598 / 63,400(71.9 %)、ブロック RAM 40.5 / 135 タイル |

途中で見つかった問題と修正は `docs/BRINGUP.md`、タイミングは `docs/TIMING.md`、性能は
`docs/BENCH.md`、次のテーマは `docs/ROADMAP.md`。JTAG / cJTAG のデバッグポートを PMOD JA に
出してある。OpenOCD でハードウェアブレークポイント・ウォッチポイントも使える(gdb の
`hbreak` / `watch` も同じ仕組み。実機の gdb ではまだ試していない)(`docs/JTAG.md`。ピン配置は
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

OpenSBI(デバイスツリーは `fw_jump.bin` に埋め込み。パッチ 1 本を写しに当てる)と
ルートファイルシステムはこのディレクトリで作る。Linux の `Image` は Rocket 構成と同じ
ソース・設定に、性能カウンタのための `CONFIG_PERF_EVENTS` / `CONFIG_RISCV_PMU_SBI` を
足して作り直したもの(`software/boot/README.md`)。**ビットストリームと `fw_jump.bin` は
組で使う**(配置が違うと UART の場所がずれ、何も表示されない。デバイスツリーが CPU の
拡張を宣言しているので、拡張の無い古いビットストリームとも組めない)。

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
│   ├── build_opensbi.sh デバイスツリー入りの fw_jump.bin(opensbi_patches を当てる)
│   ├── build_perf.sh    perf(静的リンク)を作り、bench/out に置く
│   ├── sd_rootfs.sh     SD カードのルートファイルシステムを書く
│   ├── timing_paths.tcl / .bat   最悪 300 本の経路のレポート(Windows 側)
│   └── jtag_check.tcl   実機の JTAG 確認(OpenOCD)
├── software/
│   ├── mmrisc_arty.dts  デバイスツリー
│   ├── boot/            SD カードの第 1 パーティションに置くもの(Image、fw_jump.bin、
│   │                    boot.json)、カーネルの設定、OpenSBI のパッチと手順
│   ├── rootfs/          ルートファイルシステムに足すもの(inittab、udhcpc のスクリプト、
│                        負荷試験 stress.sh)
│   └── bench/           ベンチマーク(CoreMark、Dhrystone、micro)と perf.sh。TFTP でボードへ
├── docs/
│   ├── BRINGUP.md       立ち上げ記録と手順
│   ├── TIMING.md        タイミング収束の記録
│   ├── JTAG.md          JTAG / cJTAG デバッグ(ピン、スイッチ、OpenOCD)
│   ├── BENCH.md         性能測定(シミュレーションと実機、どこでサイクルを失うか)
│   ├── ROADMAP.md       次の設計テーマ
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
#    (Image、fw_jump.bin、boot.json。Mac から書く: software/boot/README.md)
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
