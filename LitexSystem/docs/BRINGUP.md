# mmRISC-2 / LiteX 立ち上げ手順と確認状況

最終更新: 2026-09-21

## 今どこまで確認できているか

境界をはっきりさせておく。**シミュレーションで確かめたこと**と、
**まだ実機で確かめていないこと**は別物。

| | 状態 |
|---|---|
| SoC の生成(RTL + BIOS) | **通る**。`scripts/build_soc.sh` |
| メモリマップが Rocket 構成と一致 | **確認済**(csr.json を突き合わせ) |
| 割り込み番号が Rocket 構成と一致 | **確認済**(soc.h の `*_interrupt_read`) |
| コア + 本物のキャッシュ + AXI | **確認済**。`SIM/SIM_SYS`、自作 15 本 + riscv-tests 132 本 |
| **キャッシュ外からの命令フェッチ** | **確認済**。`make romboot`(下記) |
| ビットストリーム | **未**。Windows VM の Vivado 待ち |
| 実機で BIOS が出るか | **未** |
| 実機で Linux が起動するか | **未** |

## キャッシュ外フェッチを先に潰した理由

LiteX の BIOS は **ROM 0x1000_0000 から走る**。mmRISC-2 のキャッシュは
`MEM_BASE`(= 0x8000_0000)を境に、**それ未満は AXI4-Lite の非キャッシュ**
アクセスになる。つまり BIOS の命令フェッチは丸ごと非キャッシュ経路を通る。

この経路は `SIM_CACHE` がキャッシュ単体では見ているが、**コアから通した
ことが一度も無かった**。ビットストリームを焼いてから「BIOS のバナーすら
出ない」を JTAG 無しで追うのは辛いので、先にシミュレーションで踏んだ。

`SIM/SIM_SYS` の `make romboot` は、リセットベクタを非キャッシュ窓に置き、
そこに置いた小さなスタブ(`li t0,0x80000000; jr t0`、うち 2 つは圧縮命令)
から本体へ飛ぶ。15 本すべて通る。

## 手順

### 1. SoC を生成(Linux VM)

```bash
cd LitexSystem
./scripts/build_soc.sh
```

`build/gateware/` に Verilog・XDC・tcl、`build/software/bios/` に BIOS。
tcl 内の本リポジトリへのパスは **gateware ディレクトリからの相対**に
書き換えてある(共有フォルダのドライブ文字が Windows 側で変わるため)。

### 2. ビットストリーム(Windows VM)

`build/gateware/` を開き `build_digilent_arty.bat` を実行。
Vivado 2025.1 で確認済みの手順(Rocket 構成での実績)。

**見るべき点**: LUT 使用率とタイミング。Rocket 構成は LUT 56%、
WNS +0.409ns @50MHz だった。mmRISC-2 は FPU と MMU を持つので、
ここは実際に出るまで分からない。

### 3. デバイスツリーと OpenSBI

`software/mmrisc_arty.dts` は Rocket 用から CPU ノードだけ変えたもの。
変更点は ISA 文字列、TLB 16 エントリ、PMP 16 領域、デバッグトリガの削除。

`timebase-frequency = <500000>` は **ハードウェアの `CLINT_TICK_DIV`= 100 と
対でなければならない**(50MHz / 100 = 500kHz)。片方だけ変えると Linux の
時間が狂う。

OpenSBI は DTB を `fw_jump.bin` に**埋め込む**方式なので、DTS を変えたら
必ず再ビルドする:

```bash
cd <opensbi>
make PLATFORM=generic CROSS_COMPILE=riscv64-unknown-linux-gnu- \
     FW_FDT_PATH=<...>/mmrisc_arty.dtb FW_JUMP_FDT_ADDR=0x82400000
```

### 4. SD カード

Rocket 構成のものがそのまま使える。第 1 パーティション(FAT16)に
`Image` / `fw_jump.bin` / `boot.json`、第 2 パーティション(ext4)に
ルートファイルシステム。`fw_jump.bin` だけ差し替える。

## 実機で詰まったときの見どころ

順に疑う。

1. **BIOS のバナーが出ない** — 非キャッシュフェッチかリセットベクタ。
   `romboot` が通っているので RTL 側の可能性は下がっているが、
   XDC やクロックの問題は別。
2. **BIOS は出るが `sdcardboot` が失敗** — Rocket 構成で踏んだ罠がそのまま
   当てはまる。`LitexRocket/docs/BUILD_STATUS.md` の
   「SD カードブートのトラブルシューティング記録」を先に読むこと。
   `sdcard_read <block>` で生セクタを読んで PC 側の `dd` と突き合わせる。
3. **OpenSBI は出るが Linux が進まない** — デバイスツリーと実際の
   ハードウェアの食い違いを疑う。特に `timebase-frequency` と PLIC の
   `riscv,ndev`、割り込み番号。
4. **ユーザ空間に落ちない** — MMU。`SIM_CORE` の riscv-tests 仮想記憶環境
   (109 本)が通っているので Sv39 自体は動くが、実機のメモリ量や
   キャッシュとの組み合わせは別。

## まだ繋いでいないもの

- **JTAG**。デバッグモジュールは RTL に入っているが、Arty のオンボード
  FTDI から `BSCANE2` 経由で引き出す配線を XDC に足していない。
  今はタイオフしてある(`core.py` の JTAG の項)。
- **デバッグモジュールとコアの接続**。`DBG_HART_STUB` のままで、
  halt / resume / ステップは効かない(`CPU_CORE_SPEC.md` 11 章)。
