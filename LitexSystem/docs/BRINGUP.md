# mmRISC-2 / LiteX 立ち上げ手順と確認状況

最終更新: 2026-09-24

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
| **LiteX BIOS そのもの(割り込み込み)** | **確認済**。`SIM/SIM_BIOS`(2026-09-24、実機で止まったのを受けて追加) |
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

## 実機で最初に止まったところ(2026-09-24)

最初のビットストリームでは、ターミナルに `        __`(バナーの最初の
16 文字)だけが出て止まった。**CPU は動いていた**: ROM から BIOS を取り、
C を実行し、UART に書いていた。止まったのは割り込みで、

- BIOS の UART は割り込み駆動。最初の 16 文字は UART の TX FIFO に直接入り、
  それ以降は割り込みハンドラが送り出すリングバッファに溜まる。
- 割り込みが一度も来なかった。PLIC のソース 1 の優先度が 0 のままだった。
- 原因は D$ の非キャッシュアクセスが **AXI-Lite のアドレスを 8 バイトに丸めて**
  いたこと。内蔵 PLIC は 32 bit レジスタのどちらの半分かをアドレスのビット 2 で
  決めるので、`0x0C00_0004` への書き込みは「下半分への、ストローブの立っていない
  書き込み」になって落ちた。読み出しも同様で、claim(+4)を読むつもりが
  threshold(+0)になる。

SIM_CORE のメモリモデルはバイト単位のアドレスを渡していたので見えず、
SIM_SYS / SIM_CPU は外部割り込みを 0 に固定していた。**実際の BIOS を割り込み
込みで走らせたことが一度も無かった**。`SIM/SIM_BIOS` は CPU_TOP に本物の
`bios.bin` を載せ、LiteX の UART(16 段 FIFO、レベルのイベント)をモデル化して
その穴を埋める。修正前の RTL で同じ 16 文字で止まることを確かめてから直した。

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
変更点は ISA 文字列、TLB 8 エントリ、PMP 8 領域、デバッグトリガの削除
(TLB と PMP は当初 16 だったが、FPGA に入れるために 8 にした。`docs/TIMING.md` 7 章)。

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
