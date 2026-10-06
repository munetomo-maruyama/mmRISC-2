# ベンチマーク(実機、Linux 上)

CoreMark・Dhrystone・小さな測定(`micro`)を、静的リンクの Linux ユーザプログラムとして
作り、ボードには TFTP で渡す(SD カードは書き換えない)。同じバイナリを別の CPU
(Rocket 構成)でも動かせば、CPU だけが違う比較になる。結果と分析は
`../../docs/BENCH.md`。

| ファイル | 内容 |
|---|---|
| `Makefile` | `make` で `out/coremark`、`out/dhrystone`、`out/micro`、Zba / Zbb で作った `out/coremark_zb`、`out/dhrystone_zb`。`make tftp` で TFTP サーバへ(sudo) |
| `bench.sh` | ボードで実行。3 つを TFTP で `/tmp` に取ってきて順に走らせ、MHz あたりの値を出す。コアが Zba / Zbb を持ち(`/proc/cpuinfo`)、サーバに `*_zb` があればそれも走らせる |
| `micro.c` | 帯域(D$ に入る / 入らない)、依存ロードの遅延、不整列ロード、倍精度の積和 |
| `dhry_shim.c` | riscv-tests の Dhrystone が裸の環境に求めるもの(タイマ、表示)を Linux で |
| `workload.sh` | ボードで実行。CoreMark の外の負荷(gzip、sha256sum、find、tar、SD の読み出し、fork + exec、TFTP)を PMU で数え、1 行 1 負荷の表にする(下の「workload.sh」) |
| `perf.sh` | ボードで実行。`perf` と CoreMark を TFTP で取ってきて、性能カウンタ(`CPU_CORE_SPEC.md` 決定 69)で CoreMark のサイクルの行き先を数える(下の「perf」) |

コンパイラは `/opt/riscv/bin/riscv64-unknown-linux-gnu-gcc`(**GCC 13.2.0**、glibc 2.40)、
オプションは **`-march=rv64imafdc -mabi=lp64d -O2 -static`**(`*_zb` は `-march=rv64imafdc_zba_zbb`)。
`-mtune` はツールチェーンの既定(`rocket`)。比較の条件をそろえるため `-O3` などは使わない
(詳しくは `../../docs/BENCH.md` の「ビルドの条件」)。

ソースはこのリポジトリに含めず、手元のチェックアウトを読む(中身は変更しない):

| 変数 | 既定 | 内容 |
|---|---|---|
| `COREMARK` | `~/RISCV/Rocket/vivado-risc-v/bare-metal/coremark/coremark` | https://github.com/eembc/coremark |
| `RVTESTS` | `~/RISCV/riscv-tests` | https://github.com/riscv-software-src/riscv-tests |

Dhrystone は `out/dhry` に写して 3 か所だけ直す: タイマを `mcycle` から
`clock_gettime` に(ユーザモードはこのカーネルでは cycle を読めない)、空の
`debug_printf` を外して終わりの自己検査(「should be」)を表示、`HZ * Number_Of_Runs`
の int の桁あふれを long に。

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

CoreMark が 10 秒以上、Dhrystone が数秒、`micro` が約 1 分。最後に要約:

```
CoreMark       xxx.xx iterations/s   x.xxx CoreMark/MHz  (ok)
Dhrystone    xxxxxxx per second      x.xxx DMIPS/MHz
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

## workload.sh(CoreMark の外の負荷、2026-10-06)

CoreMark はキャッシュに収まるので(`../../docs/BENCH.md` 13 章)、Linux の普通の仕事を同じ
カウンタで数える(`ROADMAP.md` D1)。`perf` と、入力に使うカーネルの `Image` を TFTP で取ってきて
`/tmp`(RAM)に置き、次の 8 つをそれぞれ `perf stat` で 5 回走らせる。

| 負荷 | 中身 | 見たいもの |
|---|---|---|
| `gzip` / `gunzip` | 2 MB の圧縮と展開 | 整数の計算、数百 KB の表 |
| `sha256` | 4 MB の `sha256sum` | 流れる読み出し |
| `find` | `find / -xdev` と `ls -lR` | カーネル、VFS |
| `tar` | `/bin /sbin /usr /etc /lib` の tar(ページキャッシュを捨ててから) | ext4、SD カード |
| `sdread` | ルートパーティションを 16 MB `dd`(同上) | SD の DMA(D$ を通る) |
| `forkexec` | `busybox uname` を 100 回 fork + exec | プロセス生成、ページフォルト、TLB |
| `tftp` | `perf`(3 MB)の TFTP | Ethernet、IP スタック |

1〜4 回目でイベント 16 種を 4 つずつ、5 回目でサイクルと命令のユーザ / カーネルの内訳を数える
(各イベントは同じ回のサイクル・命令で割る)。約 10 分。ログは `/tmp/workload.log`、
生の数は `/tmp/wl/*.csv`。

```bash
make tftp
```

```sh
cd /tmp && tftp -g -r workload.sh 192.168.0.12 && sh workload.sh 192.168.0.12
```

最後の表の列: `Mcyc`(百万サイクル)、`CPI`、1000 命令あたりの I$ / D$ ミス(行の読み込み)・
ITLB / DTLB ミス(ページテーブルを引いた回数)・例外、サイクルに対する D$ 待ち / フロントエンドが
空 / バックエンドが詰まっている / ロードユースの割合、条件分岐の予測ミス率、カーネルの割合。
CoreMark の同じ数字を最後に並べる。

