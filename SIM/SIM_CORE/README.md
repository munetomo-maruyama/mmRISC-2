# SIM_CORE — CPU コア単体の検証

`RTL/CPU/CPU_CORE` を単体で動かす環境。実キャッシュの代わりに
`CORE_MEM_MODEL.sv`(キャッシュポートのプロトコルを持つメモリモデル)を
つなぎ、アセンブラ試験と公式 riscv-tests を走らせる。CLINT
(`RTL/CPU/CPU_CLINT`)はモデルの隣に置き、本来のアドレスに見える。

アドレス:

| 範囲 | 内容 |
|---|---|
| 0x8000_0000 + 64KiB | メモリ(プログラムとデータ) |
| 0x0200_0000 + 64KiB | CLINT |
| 0x0300_0000 | テストベンチのレジスタ。bit0 が外部割り込み線 |
| それ以外 | 応答なし = アクセスフォールト |

仕様は [`../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md) 12.3 と 12.4。

## 使い方

| コマンド | 内容 |
|---|---|
| `make` | 試験プログラムを作って全部走らせる(Verilator) |
| `make TEST=t03_ldst run` | 1 本だけ走らせる |
| `make stress` | 両キャッシュポートに背圧(ready を 40% のサイクルで落とす)を入れて全部走らせる |
| `make trace` | リタイアトレース付きで 1 本走らせる |
| `make wave` | VCD を出す |
| `make iverilog` | Icarus Verilog で同じ試験 |
| `make riscv-tests` | 公式 riscv-tests(rv64ui / rv64mi)。`RVTESTS` でリポジトリの場所を指定 |
| `make bugs` / `./bug_inject.sh` | バグ注入 50 種(背圧あり/なしの両方で判定) |
| `make lint` | Verilator lint |

プラスアーグ:

| 引数 | 内容 |
|---|---|
| `+hex=<file>` `+name=<name>` | プログラムイメージと試験名 |
| `+tohost=<addr>` | tohost の番地(既定 0x8000_2000。riscv-tests では ELF から取る) |
| `+trace` | リタイアした命令(PC、命令語、書き込みレジスタ)とトラップを出す |
| `+dtrace` | データポートの要求/応答を出す |
| `+istall=<n>` `+dstall=<n>` | 命令/データポートの `ready` を約 n% のサイクルで落とす |
| `+maxcycles=<n>` | ウォッチドッグ(既定 200000) |

## 試験プログラム

`tests/*.S` を `/opt/riscv/bin/riscv64-unknown-elf-gcc` で `-march=rv64i` として
組み立てる。`tests/link.ld` は `.text` を 0x8000_0000、`.data` を 0x8000_1000、
`.tohost` を 0x8000_2000 に置く。

riscv-tests と同じ約束で、`tohost` に 1 を書けば合格、`(チェック番号 << 1) | 1`
を書けば不合格。テストベンチはストアチャネルを見て `tohost` を拾い、0 以外が
書かれた時点で試験を終える(プログラムはそのあと無限ループでよい)。
フレーム(`tests/test.h`)は gp(x3)、t0(x5)、t6(x31)を使うので、試験本体は
x10〜x30 だけを使うこと。`TEST_INIT` が既定のトラップハンドラを入れる。
予期しないトラップは `64 + cause` として報告され、テストベンチが原因・`mepc`・
`mtval` を続けて表示する。

| 試験 | 内容 |
|---|---|
| `t01_alu` | 即値・レジスタ演算、シフト、LUI/AUIPC、32bit 形式、符号付き/符号なし比較 |
| `t02_branch` | 6 種の分岐、JAL/JALR、ループ、前後方向ジャンプ |
| `t03_ldst` | 全サイズのロード/ストア、符号/ゼロ拡張、バイトレーン、負オフセット |
| `t04_hazard` | フォワーディング、load-use、ストアデータ、ストール中のオペランド保持 |
| `t05_csr` | CSR 命令、WARL フィールド、カウンタの正確さ、不正な CSR アクセス |
| `t06_irq` | CLINT(タイマ/ソフトウェア/外部)、マスク、WFI、ベクタ方式の mtvec |
| `t07_trap` | バスのアクセスフォールト、不整列、`mtval`/`mepc`、トラップ後方の命令の抑止 |

## テストベンチが自動で見ているもの

- 停止要因(ECALL 以外で止まったら不合格)
- キャッシュポートの規則違反(M1 は同時に 1 アクセスのみ)
- 同じ PC が 2 サイクル連続でリタイアしていないこと(二重リタイア)
- ウォッチドッグ(ハングを不合格にする)
