# LitexSystem — mmRISC-2 の LiteX / Linux システム

[English](README.md)

Digilent Arty A7-100T 上に、**CPU が mmRISC-2 の** LiteX SoC を組み、
Linux を起動するための一式。

隣の `LitexRocket/` は**参考用**で、同じボードに LiteX 標準の Rocket Chip を
載せて Linux 起動まで到達済みのもの(git 管理外。作り方は下の「準備」)。そこで確立した
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
出してある。OpenOCD と gdb でハードウェアブレークポイント・ウォッチポイントも使える
(動いている Linux カーネルで確認済み。`docs/JTAG.md`。ピン配置は `FPGA/ARTY_A7_100T` と同じ)。

## Rocket 構成との違い

始めは Rocket 構成とメモリマップがバイト単位で一致していたので、デバイスツリーは
CPU ノードだけ書き換えれば済んだ。その後、次の 3 点が変わっている。

- **LiteX の L2 なし**(`--l2-size 0`)。mmRISC-2 はメモリバスを直接 LiteDRAM につなぐ。
  代わりに CPU の中に L2 を持つ(2026-10-06、`RTL/CPU/CPU_L2`、256 KB)。
  `build_soc.sh --cpu-l2-size 0` で外せる(前後の比較用)。
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
│   ├── setup_litex.sh   決めたコミットで LiteX の作業場所を作る(litex_repos.py。「準備」)
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

## 準備

ここのスクリプトは**リポジトリに入っていないもの**を使う: `LitexSystem/` の隣の `LitexRocket/` にある
LiteX の作業場所と OpenSBI のソース、そして `~/mmlitex_build/` の BusyBox 一式。この章は、それらを新しい
マシンで作る手順。Rocket 構成でやったこと(2026-09-13)に沿い、いま使っている版にそろえてある。コマンドは
`cd` しない限りリポジトリの最上位(`mmRISC-2/`)で実行する。

### 何に何が要るか

| パス | 使うもの | 要否 |
|---|---|---|
| `LitexRocket/.venv/` | `scripts/build_soc.sh`(Python と LiteX) | 要る |
| `LitexRocket/litex_ws/` | `scripts/build_soc.sh`(LiteX、litex-boards、LiteDRAM、LiteEth、LiteSDCard など) | 要る |
| `LitexRocket/software/opensbi/` | `scripts/build_opensbi.sh`(`fw_jump.bin`) | 要る |
| `~/mmlitex_build/initramfs/` | `scripts/sd_rootfs.sh`(SD カードの第 2 パーティション)、`SIM/SIM_BIOS` | SD カードを作るなら要る |
| `~/mmlitex_build/initrd_bb` | `SIM/SIM_BIOS`(`make linux` とそれ以降) | Linux のシミュレーションだけ |
| `LitexRocket/software/linux/` | `scripts/build_perf.sh`、`Image` の作り直し | `perf` か新しいカーネルのときだけ(`Image` 自体は `software/boot/` にある) |
| `LitexRocket/litex_ws/build/`、`software/boot/`、`docs/` | Rocket 構成そのもの | 要らない(参考用) |

### 0. ホスト

- **Linux 側**: Ubuntu 24.04(ここでは Apple Silicon の Mac 上の Parallels Desktop の arm64。x86_64 でも
  同じ)。Vivado 以外はすべてここで動く。
- **Vivado 側**: Vivado 2025.1(ここでは Windows 11。Vivado は x86 専用)。Linux 側と共有したフォルダ越しに
  `build/gateware/` を読む。そのために `build_soc.sh` が tcl の中のパスを相対にしている。
- パッケージ(Ubuntu):
  ```bash
  sudo apt install git build-essential python3-venv device-tree-compiler \
       flex bison bc libssl-dev libncurses-dev cpio fakeroot curl
  ```

### 1. クロスコンパイラ(`/opt/riscv`)

スクリプトはどれも `/opt/riscv/bin` を `PATH` に入れる。使うコンパイラは 2 つ: `riscv64-unknown-elf-`
(LiteX BIOS、ベンチマーク、試験プログラム)と `riscv64-unknown-linux-gnu-`(OpenSBI、カーネル、
BusyBox、perf)。どちらも [riscv-gnu-toolchain](https://github.com/riscv-collab/riscv-gnu-toolchain) の
GCC 13.2.0 で、`--with-arch=rv64imafdc --with-abi=lp64d --enable-multilib` で構成したもの:

```bash
git clone https://github.com/riscv-collab/riscv-gnu-toolchain
cd riscv-gnu-toolchain
./configure --prefix=/opt/riscv --with-arch=rv64imafdc --with-abi=lp64d --enable-multilib
sudo make            # riscv64-unknown-elf-   (newlib)
sudo make linux      # riscv64-unknown-linux-gnu-   (glibc)
```

もっと新しい GCC でもよい。ベンチマークの Zba / Zbb 版には GCC 12 以降が要る。

### 2. LiteX の作業場所(`LitexRocket/.venv`、`LitexRocket/litex_ws`)

```bash
LitexSystem/scripts/setup_litex.sh
```

仮想環境 `LitexRocket/.venv` を作り、LiteX のリポジトリを **このプロジェクトが使っているコミットで**
`LitexRocket/litex_ws` に取ってきて(`scripts/litex_repos.py`、41 本、約 2.6 GB)、`litex_setup.py --install`
で venv に入れ、`meson` と `ninja`(LiteX BIOS 用)を足す。主なもの:

| リポジトリ | コミット(2026-09) |
|---|---|
| litex | `6d8a38cade2092cb1e7db3e5602e81093aead8f9` |
| litex-boards | `bca0201f1f22de6789a30ff809367cf16ab6a0bc` |
| migen | `4c2ae8dfeea37f235b52acb8166f12acaaae4f7c` |
| litedram | `ab27325fa488ada7a0e1cef271e5bd7d94c2bb7e` |
| liteeth | `8c9150ff121cb3148d8ea26ce3b1c5200479848d` |
| litesdcard | `227d61bc2b92ca56cac78a539b98e378468b1ba1` |

`scripts/litex_repos.py` は、実機に使った作業場所から `litex_setup.py --freeze` で書き出したもの。
LiteX 自体には手を入れていない: `--cpu-type mmrisc` は `LitexSystem/cpu` から来る(下の「LiteX 側に
手を入れていない」)。CSR の配置と割り込み番号は LiteX の版で変わるので、別のコミットに移すときは
`build/csr.json` を `software/mmrisc_arty.dts` と突き合わせること。

確認: `LitexSystem/scripts/build_soc.sh` が `build/gateware/digilent_arty.v` と
`build/software/bios/bios.bin` まで通ること。

### 3. OpenSBI(`LitexRocket/software/opensbi`)

```bash
mkdir -p LitexRocket/software
git clone https://github.com/riscv-software-src/opensbi LitexRocket/software/opensbi
git -C LitexRocket/software/opensbi checkout 3593a5facc4c6938b90429a6973ba9ee21fc5899
```

`build_opensbi.sh` はこの写しに `software/boot/opensbi_patches/` を当ててビルドするので、clone は
きれいなまま残る。確認: できた `fw_jump.bin` の md5 が `software/boot/README_J.md` の表と同じこと
(デバイスツリーを変えていなければ)。

### 4. BusyBox とルートファイルシステム(`~/mmlitex_build`)

[linux-on-litex-rocket](https://github.com/litex-hub/linux-on-litex-rocket) の `scripts/build_software.sh`
と同じ。共有フォルダではなくローカルディスクで作る(共有フォルダは遅く、Mac ではファイル名の
大文字・小文字を区別しない)。

```bash
mkdir -p ~/mmlitex_build && cd ~/mmlitex_build
export PATH=/opt/riscv/bin:$PATH
git clone https://github.com/litex-hub/linux-on-litex-rocket
curl https://busybox.net/downloads/busybox-1.36.1.tar.bz2 | tar xfj -
cd busybox-1.36.1
cp ../linux-on-litex-rocket/conf/busybox-1.36.1-rv64gc.config .config
make CROSS_COMPILE=riscv64-unknown-linux-gnu-
cd ..

mkdir initramfs && cd initramfs
mkdir -p bin sbin lib etc dev home proc sys tmp mnt nfs root usr/bin usr/sbin usr/lib
cp ../busybox-1.36.1/busybox bin/
ln -s bin/busybox ./init
cat > etc/inittab <<'EOT'
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t devtmpfs devtmpfs /dev
::sysinit:/bin/busybox mount -t tmpfs tmpfs /tmp
::sysinit:/bin/busybox mount -t sysfs sysfs /sys
::sysinit:/bin/busybox --install -s
/dev/console::sysinit:-/bin/ash
EOT
fakeroot sh -c 'find . | cpio -H newc -o' | gzip > ../initrd_bb
```

`initramfs/` が SD カードのルートの土台で、`sd_rootfs.sh` がその上にこのリポジトリの `software/rootfs/`
(独自の `inittab`、`sbin/init`、udhcpc のスクリプト、`stress.sh`)を重ねる。`initrd_bb` は同じ一式を
initramfs にしたもので、`SIM/SIM_BIOS` だけが使う。

### 5. Linux のソース(任意、`LitexRocket/software/linux`)

`software/boot/Image` はリポジトリに入っているので、カーネルのソースが要るのは `build_perf.sh` か
カーネルを変えるときだけ。大文字・小文字を区別するファイルシステムに clone し(そうしないと何が起きるかは
`software/boot/README_J.md`)、スクリプトが見る場所にリンクする(`build_perf.sh` は引数でもパスを
受け取る):

```bash
cd ~/mmlitex_build
git clone https://github.com/litex-hub/linux -b litex-rebase
git -C linux checkout 4929f78c004ecab9b68bb41018a3d11749dcea62
cd -
ln -s ~/mmlitex_build/linux LitexRocket/software/linux

# Image を作り直すなら:
cp LitexSystem/software/boot/linux.config ~/mmlitex_build/linux/.config
make -C ~/mmlitex_build/linux ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- Image
```

このコミットのソースそのものは、`linux.config` と一緒に GitHub の Release
[`linux-src-4929f78c004e`](https://github.com/munetomo-maruyama/mmRISC-2/releases/tag/linux-src-4929f78c004e)
にも置いてある。

### 6. 任意: Rocket 構成そのもの

同じボードに LiteX の Rocket Chip を載せた参照用の SoC を作るなら(mmRISC-2 には要らない):

```bash
cd LitexRocket/litex_ws
source ../.venv/bin/activate
export PATH=/opt/riscv/bin:$PATH
python3 litex-boards/litex_boards/targets/digilent_arty.py --build --variant a7-100 \
    --cpu-type rocket --cpu-variant linux --cpu-num-cores 1 --cpu-mem-width 1 \
    --sys-clk-freq 50e6 --with-sdcard
```

`pythondata-cpu-rocket` は `setup_litex.sh` が取ってくるリポジトリに入っている。Vivado は
`litex_ws/build/digilent_arty/gateware/` で、mmRISC-2 と同じように走らせる。

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
