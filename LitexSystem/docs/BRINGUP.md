# mmRISC-2 / LiteX 立ち上げ手順と確認状況

最終更新: 2026-09-25

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
| ビットストリーム | **通る**。50MHz でタイミング収束(`TIMING.md`) |
| 実機で BIOS が出るか | **確認済**(2026-09-24) |
| 実機で Linux が起動するか | **確認済**(2026-09-25、WNS 0.013ns)。SD カードの ext4 から BusyBox のプロンプトまで。`cat /proc/cpuinfo`、`uname -a` が動く。未解決: 起動中に 1 度 `kernel/bpf/memalloc.c:186` の WARNING(下記) |

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

### Linux の起動をシミュレーションで確かめた(`SIM/SIM_BIOS`、`make linux`)

`+linux` では BIOS を走らせず、ROM の小さなスタブから OpenSBI に飛ぶ。
主記憶(256 MiB、Linux は上から取るので全部要る)には `fw_jump.bin` を
0x8000_0000 に、Rocket 構成の `Image`(同じカーネル)を 0x8020_0000 に置く。
`+pcmon=<n>` で n サイクルごとに PC を出し、`System.map` で関数名に直せる。
CLINT の分周は実機と同じ 100(これを 1 のままにすると時刻が 100 倍速く進み、
タイマ割り込みが 100 倍来る)。

satp の修正を入れた RTL で:

```
OpenSBI v1.9 ... → Linux version 7.2.0-rc2 ... → earlycon
riscv-plic: interrupt-controller@c000000: mapped 4 interrupts
LiteX SoC Controller driver initialized
12003800.serial: ttyLXU0 ... is a liteuart
litex-mmc 12002000.mmc: LiteX MMC controller initialized.
cpu0: scalar unaligned word access speed is 0.01x byte access speed (slow)
Waiting for root device /dev/mmcblk0p2...
```

2 億 3300 万サイクル(50 MHz で約 4.7 秒)。**カーネルは SD カードを要る
ところまで全部通る**。SD のコマンドがタイムアウトするのはベンチに SD カードの
モデルが無いから。不整列アクセスは OpenSBI がエミュレートしている(遅いのは想定どおり)。

### DMA ポートを付けた(2026-09-24、案 A)

CPU_TOP に DMA ポート(AXI4-Lite スレーブ)を足し、SD カードの DMA が
データキャッシュを通るようにした(`CPU_CACHE_SPEC.md` 4.8)。`core.py` で
`dma_bus` として宣言したので、LiteX は SD カードの `block2mem` / `mem2block` を
そちらにつなぎ、`CONFIG_CPU_HAS_DMA_BUS` を定義する。メモリマップは変わらない。
Linux 側もデバイスツリーも変更不要(DMA は一貫している、が既定)。

検証の途中で、SIM_SYS のバグ注入キャンペーンが**壊れていた**ことがわかった。
SIM_CORE の試験を全部走らせていて、そのうち `t06_irq` と `t15_plic` はこの
ベンチでは RTL に関係なく落ちるので、**どの変異も「検出」と数えられていた**。
`make run-all` と同じ試験だけを走らせるように直すと 4 本が本当は未検出で:

- I$ が `i_cancel` を無視する(拒否したフェッチがバスに出る): 結果は変わらない
  ので、ベンチが周辺バスの読み出しを数え、`progs/d02_pmp_fetch` で 0 回を確かめる
- fence.i が書き戻しの終わる前に I$ を無効化する: `progs/d03_fencei`(書き戻しが
  最後に届くセット 63 のコードを書き換え、キャッシュ全体を dirty にしてから fence.i)
- 残り 2 本は結果にも安全にも影響しない(理由をヘッダに書いて外した)

`t13_pmp` にも、I$ に無いラインへの拒否フェッチを足した。

### この先で当たるはずの問題: Linux の SD ドライバと DMA の一貫性(解決済み、上)

BIOS は DMA のあとに `fence.i`(D$ の書き戻し + 無効化)を呼ぶので問題ない。
**Linux は呼ばない**。LiteX の `litex_mmc` ドライバは DMA の受け皿を
`dma_alloc_coherent` で取り、ハードウェアが一貫性を保つ前提で使う。mmRISC-2 の
D$ は DMA の書き込みを知らないので、ルートファイルシステムを SD から読むと
古いキャッシュ内容を読む可能性が高い。Rocket では `dma_bus` がこれを解決していた。
対策(D$ を通る DMA ポートを CPU_TOP に足す、など)は、カーネルが起動するのを
見てから決める。まずは initramfs で起動させるのが安全。

## 4 回目: SD カードの ext4 を載せ、`Run /sbin/init` で止まった(2026-09-24)

DMA ポートを入れたビットストリーム(WNS 0.008ns)で、カーネルは SD カードを
認識し、ext4 をマウントして `Run /sbin/init` まで進んだ。ただし

- `clk: Disabling unused clocks` の後(ext4 のマウントとジャーナルの回復中)で
  **止まることがある**
- `Run /sbin/init ... TERM=linux` の後で**必ず止まる**

### ユーザー空間そのものはシミュレーションで動く

`SIM/SIM_BIOS` の `make linux-initrd` で、SD カードの第 2 パーティションと同じ
BusyBox 一式(`~/mmlitex_build/initrd_bb`)を initramfs として渡し、`/init`
(= busybox)を起動させた。inittab の sysinit(proc / devtmpfs / tmpfs / sysfs の
マウント、`busybox --install -s`)が走り、ash のプロンプト `# ` まで出て、
あとは `arch_cpu_idle` で入力を待つ。UART を実機の速さ(`+uart_cycles=4340`、
FIFO が埋まり TX 割り込みで送る)にしても同じ。`+utrace=<n>` で、ユーザー
モードに入ってからのトラップ(ページフォールト、ecall、タイマ)を全部見られる。

つまり U モード、システムコール、ページフォールト、tty の割り込み送信は動いて
いる。実機との違いは、実行ファイルのページが **SD カードから DMA で**来ること。

### 原因: D$ の書き戻しキューと、同じラインの fill / 単発書き込みの順序

D$ は追い出した dirty ラインを書き戻しキューに積み、書き込みエンジンが順に
AXI4 へ出す。キューにある間、メモリはまだ古い。そこに

1. **同じラインの fill** が来ると、AR をすぐ出して古いラインを読んでいた
   (CPU が追い出した直後のラインを読み直す、DMA の読み出しが同じラインに来る)。
2. **DMA の書き込み(`STWTHR`)** が来ると、書き込みエンジンはキューより
   単発書き込みを優先していたので、DMA のデータが先にメモリへ行き、そのあとで
   キューの古いラインがそれを上書きしていた。
3. `STWTHR` がバスに出ている間の同じラインの fill も、それを追い越せた。

Linux の `litex_mmc` はページキャッシュのページに直接 DMA する。そのページは
直前まで別の用途に使われていて、CPU の D$ に dirty ラインが残っていることが多い。
追い出しと DMA が重なると、ページの一部が古い内容のまま残る。busybox のコードが
化ければユーザー空間は進まないし、ジャーナル回復中の書き込み(`mem2block` は
D$ から読む)が化ければ ext4 が止まる。

修正: fill は同じラインの書き戻しと単発書き込みが B 応答を受けるまで AR を出さず
(`f_ar_block`、状態 `F_ARW`)、単発書き込みは同じラインがキューにある間は出さない
(`sw_wait_wb`)。`CPU_CACHE_SPEC.md` 4.3。

`SIM/SIM_CACHE` のセクション 16 が、メモリモデルの AWREADY を止めて(`aw_hold`)
書き戻しを実際に待たせ、4 通りとも再現する(修正前は全部失敗)。バグ注入
M23〜M25 も全て検出。既存のシミュレーションで見つからなかったのは、メモリモデルが
書き込みをすぐ受け取るので、キューに滞留しなかったから。実機では LiteDRAM と
DRAM のリフレッシュで書き込みが待たされ、AXI4 は読みが書きを追い越すことを
禁じていない。

### SD カードの中身は疑ってかかる

修正前の構成では、ジャーナルの回復で古いデータが SD カードに書かれた
可能性がある。次に試す前に PC で

```bash
sudo e2fsck -f /dev/sdX2
cmp /media/<user>/rootfs/bin/busybox ~/mmlitex_build/initramfs/bin/busybox
```

を確かめ、壊れていたら第 2 パーティションの中身を入れ直す。

## 5 回目: D$ の順序を直しても同じ 2 か所で止まった(2026-09-25)

WNS 0.103ns のビットストリームでも症状は同じだった。止まっている間にキーを
打ってもエコーが返らず、数分待っても RCU の停止検出も出ない。CPU が止まって
いるか、割り込みが永久に入らないかのどちらかで、ハードウェア側の問題。

### SD カードのモデルを作った(`SIM/SIM_BIOS/SD_MODEL.sv`、`make linux-sd`)

LiteSDCard をレジスタの水準で真似たもの(core / phy、block2mem / mem2block の DMA、
イベントと割り込み)に、ディスクイメージを持つ SDHC カードをつないだ。DMA は
LiteX の Wishbone2AXILite と同じ形(32 bit を 1 回ずつ、ダブルワードのアドレスに
ストローブ 0x0F / 0xF0)で CPU の DMA ポートに入る。`sdcard.img` は実機の
カードと同じ構成(MBR、ext4 の第 2 パーティションに BusyBox 一式と `sbin/init`)で、
実機と同じ `fw_jump.bin`(`root=/dev/mmcblk0p2`)で起動する。`+sdlog` で SD の
コマンド、`+dmalog` で DMA ポートの要求、`+pcmon` で割り込み線・PLIC の claim 数・
SD の状態が見える。

これで実機の 2 つの停止が**両方ともシミュレーションで再現**し、原因が 2 つあった。

### 原因 1: D$ の fill が DMA の書き込みに答えていた(`clk: Disabling unused clocks` の後で固まる)

`STWTHR`(DMA の書き込み)は ROB の `rob_wait` を立てていたが、`rob_mshr` は
その ROB の枠の前の持ち主の値のままだった。fill は「`rob_wait` が立っていて
`rob_mshr` が自分」の要求に答えるので、CPU の fill が DMA の書き込みに、まだ
メモリに書く前に答えてしまう。本物の応答が後から来ると、その枠をもう使って
いる別の要求を「完了」にする。シミュレーションでは D$ が DMA に二度と答えなく
なり、CPU もキャッシュ要求を出さなくなった。実機の「エコーも返らない」と同じ。

`STWTHR` は書き込みエンジンだけが答えるようにした(`rob_wait` は fill を待つ
要求専用)。SIM_CACHE 16(e) と変異 M26。

### 原因 2: `mip.SEIP` が立ちっぱなしになる(`Run /sbin/init` の後で止まる)

1 を直すと ext4 のマウントまで進み、今度は割り込みの嵐になった。PLIC は何も
出していないのに `mip.SEIP` が 1 のままで、カーネルは S の外部割り込みを受けては
claim が 0 で戻る、を繰り返していた。

`mip.SEIP` の読み出し値は「ソフトウェアが書けるビット OR PLIC の S 線」だが、
`csrrs` / `csrrc` がその読み出し値を元に書いていたので、PLIC が S に割り込みを
出している最中の読み書きで、線の値がソフトウェアのビットに写っていた。OpenSBI は
M のタイマ割り込みのたびに `csrc mip, STIP` を実行するので、SD カードの割り込みと
タイマが重なった瞬間に SEIP が固定される。特権仕様は「読み書きに使うのは
ソフトウェアのビットだけ」と定めている。`CORE_CSR` の `rmw_data` で直した
(`CPU_CORE_SPEC.md` 決定 51、`t22_mip_seip`、変異 M210)。

SD カードの割り込みが頻繁になるユーザー空間の起動で「必ず」、マウント中は
「ときどき」止まったのは、タイマと SD の割り込みが重なる回数の差で説明できる。

### 結果

`make linux-sd` で、SD カードから ext4 をマウントし、`/sbin/init` → BusyBox の
`# ` プロンプトまで進む。回帰(SIM_CORE、SIM_SYS、SIM_CPU、riscv-tests 132 本、
SIM_CACHE と掃引 18 構成)はすべて PASS。

## 6 回目: 実機で Linux のプロンプトが出た(2026-09-25)

5 回目の 2 つの修正を入れたビットストリーム(WNS 0.013ns)で、実機が SD カードの
ext4 から `/sbin/init` → BusyBox の `# ` まで進み、`cat /proc/cpuinfo`
(`rv64imafdc_...`、`mmu: sv39`)と `uname -a` が動いた。

- `mount: mounting devtmpfs on /dev failed: Device or resource busy` は無害。
  カーネルが `/dev` を既にマウントしていて、inittab がもう一度マウントしようと
  しているだけ。
- **未解決**: パーティション表を読んだ直後に 1 度、`kernel/bpf/memalloc.c:186`
  (`WARN_ON_ONCE(local_inc_return(&c->active) != 1)`)が出た。0 のはずの per-CPU
  カウンタを原子的に 1 足した結果が 1 でなかった、ということで、AMO かメモリの
  一貫性を疑う。シミュレーションでは一度も出ていない。頻度を実機で確かめつつ、
  DMA ポートと CPU の AMO・ミスを混ぜたランダム試験を SIM_CACHE に足して探す。

## 7 回目: DMA と CPU を混ぜたランダム試験で、さらに 2 つ(2026-09-26)

6 回目の WARNING(`kernel/bpf/memalloc.c:186`)は起動し直すと出なくなった。まれな
タイミングでしか起きない不具合は実機では追えないので、SIM_CACHE に CPU と DMA
(第 2 ポート)を同じラインで同時にランダムに動かす試験(セクション 17)を足した。

DMA が無くても出る D$ のバグが 2 つ見つかった(`CPU_CACHE_SPEC.md` 4.3 の 5):

- **`fence.i` の直後のアクセスが別のラインのデータを返す**。フラッシュのウォークが
  タグを読んでいる間、ステージ 1 で待つ要求が他のセットのタグと比べていた。
  Linux は実行ページを写像するたびに `fence.i` を出す。
- **ストアが消える**。ストアのヒットでラインが dirty になったサイクルに、同じセットの
  ミスがタグを読んで MSHR 待ちになると、1 サイクル後にはフォワーディングが切れて
  clean に見え、そのラインを書き戻さずに追い出していた。

どちらも「0 のはずのカウンタが 0 でない」「値が古い」といった形で出るので、6 回目の
WARNING の説明として十分あり得る。直したビットストリームで確かめる。

テストベンチ側にも不具合があった(期待値のキューが満杯でも書いていた)。直して
から、セクション 17 を 24 シード × 50000 操作で PASS。

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
