# ベンチマーク(実機、Linux 上)

CoreMark・Dhrystone・小さな測定(`micro`)を、静的リンクの Linux ユーザプログラムとして
作り、ボードには TFTP で渡す(SD カードは書き換えない)。同じバイナリを別の CPU
(Rocket 構成)でも動かせば、CPU だけが違う比較になる。結果と分析は
`../../docs/BENCH.md`。

| ファイル | 内容 |
|---|---|
| `Makefile` | `make` で `out/coremark`、`out/dhrystone`、`out/micro`。`make tftp` で TFTP サーバへ(sudo) |
| `bench.sh` | ボードで実行。3 つを TFTP で `/tmp` に取ってきて順に走らせ、MHz あたりの値を出す |
| `micro.c` | 帯域(D$ に入る / 入らない)、依存ロードの遅延、不整列ロード、倍精度の積和 |
| `dhry_shim.c` | riscv-tests の Dhrystone が裸の環境に求めるもの(タイマ、表示)を Linux で |

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
