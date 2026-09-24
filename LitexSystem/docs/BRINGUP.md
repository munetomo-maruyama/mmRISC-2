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

## 2 回目: `Booting from boot.json...` で止まった(2026-09-24)

BIOS は最後まで立ち上がった: SDRAM の較正(m0 / m1 とも b01)、memtest、
memspeed(書き 37.7 / 読み 41.6 MiB/s)、ブートメニュー。止まったのは
SD カードからの読み込みの途中。

### 1. SD カードの PMOD は **JD**

LiteX の Arty 用プラットフォームは SD カード PMOD を `pmodd`(**JD**、
`D4 D3 F4 F3 E2 D2 H2 G2`)に置く。このビルドの XDC も Rocket のビルドも同じ
ピン。**JA に挿すと SD コントローラには何もつながっていない**。

### 2. L2 キャッシュを外した(`--l2-size 0`)

mmRISC-2 は LiteDRAM への専用のメモリバスを持ち、DMA ポートは持たない。
この組み合わせだと LiteX は SoC バス(= SD カードの DMA)を **8 KiB の
ライトバック L2 経由**で LiteDRAM につなぐ(`soc.py` の
`connect_main_bus_to_dram`)。CPU はその L2 を通らないので:

- SD カードから DRAM に読み込んだデータ(OpenSBI、カーネル)の最後の数 KiB が
  L2 に残ったままになりうる
- BIOS の `flush_l2_cache()` は「CPU でメインメモリを読んで L2 を追い出す」
  実装なので、L2 を通らない mmRISC-2 では何も起きない

Rocket は一貫性のある DMA ポート(`dma_bus`)を持つのでこの問題が無い。
`scripts/build_soc.sh` に `--l2-size 0` を入れた。メモリマップは変わらない
(`csr.csv` の差は `config_l2_size` が消えただけ)。

## 3 回目: OpenSBI までは出て、カーネルが何も出さない(2026-09-24)

PMOD を JD に挿し直すと、`boot.json` から `Image`(15 MB)と `fw_jump.bin` を
読み込み、OpenSBI v1.9 が起動してプラットフォーム情報を全部出した。止まったのは
OpenSBI が S モードのカーネル(0x8020_0000)に飛んだ直後で、`earlycon` の
出力が一行も無かった。

原因: **S モードから satp を書いて MMU を入れる手順**。Linux の `head.S`
(`relocate_enable_mmu`)は、stvec に「satp を書いた次の命令」の**仮想**
アドレスを入れてから satp を書き、次の命令のフェッチがページフォールトになる
ことで仮想アドレスへ移る(実行中の物理アドレスは新しい表に無い)。mmRISC-2 の
CSR 書き込みは直列化されるが、**後ろの命令は書き込みの前に(変換なしで)
フェッチキューに入っていた**ので、フォールトせずに物理アドレスのまま走り、
あとで別のフェッチがフォールトしたときには stvec の先も写っておらず、黙って
回り続ける。

これまでの MMU の試験は、M モードで satp を書いて `mret` で S に入る形だった。
`mret` は取り直すので、この順序を一度も踏んでいなかった。

対策: **satp と PMP の CSR への書き込みは、コミット時に後ろを取り直す**
(fence.i / SFENCE.VMA と同じ道)。`t21_satp` がこの手順をそのまま試す
(最初に書いた版は、失敗の分岐自身がフォールトして stvec に戻り、偶然 PASS
していた。「そのラベルに何回来たか」を数えて直した)。

### この先で当たるはずの問題: Linux の SD ドライバと DMA の一貫性

BIOS は DMA のあとに `fence.i`(D$ の書き戻し + 無効化)を呼ぶので問題ない。
**Linux は呼ばない**。LiteX の `litex_mmc` ドライバは DMA の受け皿を
`dma_alloc_coherent` で取り、ハードウェアが一貫性を保つ前提で使う。mmRISC-2 の
D$ は DMA の書き込みを知らないので、ルートファイルシステムを SD から読むと
古いキャッシュ内容を読む可能性が高い。Rocket では `dma_bus` がこれを解決していた。
対策(D$ を通る DMA ポートを CPU_TOP に足す、など)は、カーネルが起動するのを
見てから決める。まずは initramfs で起動させるのが安全。

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
