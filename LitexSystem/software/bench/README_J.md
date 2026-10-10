# ベンチマーク(実機、Linux 上)

[English](README.md)

CoreMark・Dhrystone・小さな測定(`micro`)を、静的リンクの Linux ユーザプログラムとして
作り、ボードには TFTP で渡す(SD カードは書き換えない)。同じバイナリを別の CPU
(Rocket 構成)でも動かせば、CPU だけが違う比較になる。結果と分析は
`../../docs/BENCH.md`。

| ファイル | 内容 |
|---|---|
| `Makefile` | `make` で `out/coremark`、`out/dhrystone`、`out/micro`、Zba / Zbb で作った `out/coremark_zb`、`out/dhrystone_zb`、最大の最適化で作った `out/coremark_max`、`out/dhrystone_max`、`out/coremark_zb_max`、`out/dhrystone_zb_max`、`out/dhrystone_lto`、`out/dhrystone_zb_lto`(下の「最大の最適化」)。`make tftp` で TFTP サーバへ(sudo) |
| `bench.sh` | ボードで実行。3 つを TFTP で `/tmp` に取ってきて順に走らせ、MHz あたりの値を出す。サーバに `*_zb`(コアが Zba / Zbb を持つとき、`/proc/cpuinfo`)、`*_max`、`*_zb_max`、`dhrystone_*lto` があればそれも走らせる |
| `micro.c` | 帯域(D$ に入る / 入らない)、依存ロードの遅延、不整列ロード、倍精度の積和(C と、`fpkern.S` のアセンブラ)。`micro 50 fp` で浮動小数点だけ |
| `fpkern.S` / `fpkern.c` / `fpkern.h` | パイプライン化した FPU(`CPU_CORE_SPEC.md` 10.11)向けのアセンブラの核: 行列積(4×4 のブロック、そのままと D$ に合わせて切ったもの(`fpkern.c`、`../../docs/BENCH.md` 16 章))、FIR 8 タップ、内積。`fpkern.h` に同じ計算の C 版(答えの照合用)。シミュレーションでは `SIM/SIM_SYS/bench/fploop.c` が同じ核を走らせる |
| `dhry_shim.c` | riscv-tests の Dhrystone が裸の環境に求めるもの(タイマ、表示)を Linux で |
| `workload.sh` | ボードで実行。CoreMark の外の負荷(gunzip、md5sum、awk、ls、ext4 と SD の読み出し、fork + exec、TFTP)を PMU で数え、1 行 1 負荷の表にする(下の「workload.sh」) |
| `perf.sh` | ボードで実行。`perf` と CoreMark を TFTP で取ってきて、性能カウンタ(`CPU_CORE_SPEC.md` 決定 69)で CoreMark のサイクルの行き先を数える(下の「perf」) |

コンパイラは `/opt/riscv/bin/riscv64-unknown-linux-gnu-gcc`(**GCC 13.2.0**、glibc 2.40)、
オプションは **`-march=rv64imafdc -mabi=lp64d -O2 -static`**(`*_zb` は `-march=rv64imafdc_zba_zbb`)。
`-mtune` はツールチェーンの既定(`rocket`)。比較の条件をそろえるため、基本の値は `-O3` などを使わずに測る
(詳しくは `../../docs/BENCH.md` の「ビルドの条件」)。それとは別に、このコアで一番速くなる
オプションで作ったものも並べて測る(次の節)。

### 最大の最適化(`*_max`、`dhrystone_lto`)

CoreMark と Dhrystone を、速さだけを狙ったオプションでも作る。どのオプションが速いかは
ベンチマークごとに違ったので、別々に決めた(`SIM/SIM_SYS/bench/optsweep.sh` でシミュレーションの
サイクルを比べた。`../../docs/BENCH.md` 17 章):

| | オプション(`Makefile` の変数) |
|---|---|
| CoreMark(`OPT_MAX_CM`) | `-O3 -funroll-all-loops -finline-functions --param max-inline-insns-auto=20 -falign-functions=4 -falign-jumps=4 -falign-loops=4` |
| Dhrystone(`OPT_MAX_DHRY`) | 上と同じ + `-mtune=sifive-7-series` |
| Dhrystone、規則の外(`OPT_LTO_DHRY`) | `-O2 -flto` |

- CoreMark のオプションは結果に表示される(`Compiler flags`)。CoreMark の規則はオプションを
  報告すれば何を使ってもよい。
- Dhrystone の規則(`dhrystone.h` の冒頭: 分割コンパイル、手続きを併合しない、それ以外の最適化は
  明記すれば可)に従うので、`dhrystone_max` は `-flto` を使わない。`-flto` は 2 つのファイルを
  またいで手続きを展開し、シミュレーションではいちばん速かった(+17 %)ので、
  `dhrystone_lto` / `dhrystone_zb_lto` として別に作り、要約に「off-rule」と付けて出す。

## 手順

```bash
cd LitexSystem/software/bench
make
make tftp              # /srv/tftp へ(sudo)
```

ボード(シェル、ネットワークが上がっていること):

```sh
cd /tmp && tftp -g -r bench.sh 192.168.0.12 && sh bench.sh 192.168.0.12
```

CoreMark が 10 秒以上、Dhrystone が数秒、`micro` が約 1 分で、4 つの作り方を全部で約 3 分。
最後に要約:

```
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok, Zba/Zbb)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (Zba/Zbb)
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok, max opt)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (max opt)
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok, Zba/Zbb, max opt)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (Zba/Zbb, max opt)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (LTO, off-rule)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz  (Zba/Zbb, LTO, off-rule)
```

ログは `/tmp/bench.log`。他の仕事(`stress.sh` など)が動いていない状態で測ること。
時間は `clock_gettime`(mtime、500 kHz)で測り、サイクルは 50 MHz として換算する。

## perf(性能カウンタ)

コアの性能カウンタ(`hpmcounter3`〜`6`、イベント 17 種、`CPU_CORE_SPEC.md` 決定 69)を
Linux の `perf` で読む。要るもの:

- PMU 入りのビットストリームと、`pmu` ノード入りのデバイスツリーで作った `fw_jump.bin`
- `CONFIG_PERF_EVENTS` / `CONFIG_RISCV_PMU_SBI` 入りのカーネル(`../boot/Image`、
  設定は `../boot/linux.config`)
- `perf` 本体: `../../scripts/build_perf.sh` がカーネルのソースの `tools/perf` から
  静的リンクで作り、`out/perf` に置く(`make tftp` がそれも TFTP サーバへ送る)

```bash
../../scripts/build_perf.sh
make tftp
```

ボード:

```sh
cd /tmp && tftp -g -r perf.sh 192.168.0.12 && sh perf.sh 192.168.0.12
```

CoreMark を `perf stat` で 4 回(カウンタが 4 本なので 1 回に 4 イベント)、`perf record`
で 1 回走らせる(1 回 10 秒以上)。最後に 1000 命令あたりの回数とサイクルに占める割合の
要約を出す。ログは `/tmp/perf.log`。

`perf` から見えるイベント:

| 指定 | 数えるもの |
|---|---|
| `cycles` / `instructions` | 固定のカウンタ(`cycle` / `instret`) |
| `branches` / `branch-misses` | 条件分岐 / 予測が外れた分岐・ジャンプ |
| `cache-misses`、`L1-dcache-load-misses` | D$ のミス(ラインの読み込み。ストアのミスも入る) |
| `L1-dcache-loads` / `L1-dcache-stores` | リタイアしたロード / ストア |
| `L1-icache-load-misses` | I$ のミス |
| `dTLB-load-misses` / `iTLB-load-misses` | ページテーブルを引いた回数 |
| `stalled-cycles-frontend` / `stalled-cycles-backend` | 発行できなかったサイクル(フロントエンドが空 / EX 以降が詰まっている) |
| `r1`〜`r11` | コアのイベント番号そのもの(16 進)。`r1` サイクル、`r2` 命令、`r3` ロード、`r4` ストア、`r5` 条件分岐、`r6` 予測ミス、`r7` I$ ミス、`r8` D$ ミス、`r9` ITLB ミス、`ra` DTLB ミス、`rb` D$ 待ち、`rc` フロントエンドが空、`rd` ロードユース、`re` MDU / FPU 待ち、`rf` 例外、`r10` 割り込み、`r11` バックエンドが詰まっている |

`perf record` は Sscofpmf のあふれ割り込みで標本を取る。固定のサイクルカウンタはあふれ
割り込みを出せないので、`-e r1`(`hpmcounter` で数えるサイクル)を使う。この `perf` は
libelf なしで作ってあるので、関数名は出ない(`--sort dso` でどのバイナリかは分かる)。

## workload.sh(CoreMark の外の負荷、2026-10-06。メモリの待ちは 2026-10-10)

CoreMark はキャッシュに収まるので(`../../docs/BENCH.md` 13 章)、Linux の普通の仕事を同じ
カウンタで数える(`ROADMAP.md` D1)。`perf`、入力に使うカーネルの `Image` と、その先頭 2 MB を
ホストで gzip したもの(`out/image2m.gz`。SD カードの BusyBox には gzip・sha256sum・find が
無い)を TFTP で取ってきて `/tmp`(RAM)に置き、次の 8 つをそれぞれ `perf stat` で 5 回走らせる。
それぞれ先に 1 回走らせて成功を確かめ、失敗したものは表に FAILED と出す。

| 負荷 | 中身 | 見たいもの |
|---|---|---|
| `gunzip` | 2 MB の展開 | 流れる処理、ユーザモード |
| `md5sum` | 4 MB の `md5sum` | 流れる読み出しとハッシュ |
| `awk` | 5000 項目の表を回す awk のループ | インタプリタ(コードが大きい、ハッシュ表) |
| `ls` | ルートの `ls -lR` | カーネル、VFS、lstat |
| `ext4read` | SD カードに書いた 8 MB のファイルを `cat`(ページキャッシュを捨ててから) | ext4、SD カード |
| `sdread` | ルートパーティションを 16 MB `dd`(同上) | SD の DMA(D$ を通る) |
| `forkexec` | `busybox uname` を 100 回 fork + exec | プロセス生成、ページフォルト、TLB |
| `tftp` | `perf`(3 MB)の TFTP | Ethernet、IP スタック |

1〜4 回目でイベント 16 種を 4 つずつ、5 回目で L2 の読み出しとミス(`r12` / `r13`、2026-10-06 に
追加。L2 の無いビットストリームでは 0)、6・7 回目で M0 のメモリの待ち(`r14`〜`r18`、2026-10-10 に追加、
`../../docs/BENCH_J.md` 18 章。2 つ目の表: MA の待ちの全部、ストアの分、ミスの分、ダーティな追い出し行の写しの分、
ライン読み込みが 1 本以上 / 2 本以上未完了)、0 回目でサイクルと命令のユーザ / カーネルの内訳を数える
(各イベントは同じ回のサイクル・命令で割る)。約 14 分。ログは `/tmp/workload.log`、
生の数は `/tmp/wl/*.csv`。イベント 20〜24 は 2026-10-10 以降のビットストリームが要る(古いものでは 0)。

```bash
make tftp
```

```sh
cd /tmp && tftp -g -r workload.sh 192.168.0.12 && sh workload.sh 192.168.0.12
```

最後の表の列: `Mcyc`(百万サイクル)、`CPI`、1000 命令あたりの I$ / D$ ミス(行の読み込み)・
ITLB / DTLB ミス(ページテーブルを引いた回数)・例外、サイクルに対する D$ 待ち / フロントエンドが
空 / バックエンドが詰まっている / ロードユースの割合、条件分岐の予測ミス率、カーネルの割合、
`L2`(1000 命令あたりの L2 の読み出し = L1 の fill)、`L2m%`(L2 のミス率)。L2 の前後の比較は
`../../docs/BENCH.md` 15 章。
CoreMark の同じ数字を最後に並べる。

