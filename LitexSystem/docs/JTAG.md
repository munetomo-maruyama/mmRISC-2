# JTAG / cJTAG デバッグ(LiteX SoC)

mmRISC-2 のデバッグモジュール(`RTL/CPU/CPU_DBG`、RISC-V Debug Spec 1.0)を
Arty の PMOD JA に出し、OpenOCD から halt / step / レジスタ / メモリを扱う。
ピン配置・スイッチ・OpenOCD の設定は、デバッグ論理の立ち上げに使った
`FPGA/ARTY_A7_100T`(`RTL/TOP/TOP.sv`、`TOP.xdc`)と**同じ**にしてあるので、
同じケーブルと同じ `.cfg` がそのまま使える。

## 1. ピンとスイッチ

| PMOD JA | FPGA ピン | 信号 | FPGA 側 |
|---|---|---|---|
| JA1 | G13 | TCK / TCKC | プルアップ。汎用ピン上のクロック |
| JA2 | B11 | TDI | プルアップ |
| JA3 | A11 | TDO | プルアップ。シフト中だけ駆動 |
| JA4 | D12 | TMS / TMSC | キーパ(cJTAG ではホストとターゲットが交互に駆動する) |
| JA7 | D13 | nTRST | プルアップ。TAP のリセット |
| JA8 | B18 | nSRST | プルアップ。**CPU** のリセット(下記) |
| JA5 / JA11 | — | GND | |

| スイッチ | 下 | 上 |
|---|---|---|
| SW3(A10) | 4 線 JTAG | 2 線 cJTAG(OScan1) |
| SW2(C10) | 認証なし | 認証あり(鍵 `0xbeefcafe`) |

状態表示は RGB LED(LiteX の LED チェイサが LD4〜LD7 を使っていて、その CSR の
位置はデバイスツリーと `fw_jump.bin` が前提にしているので動かさない)。明るすぎるので
1/16 のデューティで点ける。

| LED | 色 | 意味 |
|---|---|---|
| LD0 | 赤 / 緑 | ハート停止中 / 実行中 |
| LD1 | 青 | dmactive(デバッガが DM を有効にしている) |
| LD2 | 緑 | cJTAG オンライン(SW3 上のとき) |

実装は `cpu/mmrisc/core.py` の `add_jtag`。`--cpu-jtag none` を `build_soc.sh` に
渡すとタイオフに戻る。制約(`build/gateware/digilent_arty.xdc` と `.tcl`)は
`TOP.xdc` / `TOP_impl.xdc` と同じ内容:

- TCK と TMSC に 100 ns の `create_clock`、sys と互いに非同期(`set_clock_groups`)
- 両方ともクロック専用ピンではないので `CLOCK_DEDICATED_ROUTE FALSE`(合成後に
  バッファの出力ネットへ。`pre_placement_commands`)
- nTRST / nSRST / SW2 / SW3 / TDI / TMS / TDO は false path

## 2. リセット

| 何が | 何をリセットするか |
|---|---|
| ボードの RESET ボタン、LiteX のシステムリセット | SoC 全体(デバッグモジュールも) |
| nSRST(JA8)、`ndmreset`、`hartreset` | **CPU だけ**(コア・キャッシュ・CPU 内のバス)。デバッグモジュールと LiteX の周辺は動いたまま |

OpenOCD の `reset` は nSRST を使う(`reset_config trst_and_srst`)。CPU は ROM の
先頭から BIOS をやり直す。`reset halt` なら BIOS の最初の命令の手前で止まる。

## 3. OpenOCD

配線は `FPGA/ARTY_A7_100T/README.md` 3 章(FT2232H のチャネル A)。Ubuntu VM で
FT2232H を USB パススルーして使う。

```bash
cd LitexSystem
# 4 線 JTAG(SW3 下)
openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg  -f scripts/jtag_check.tcl
# 2 線 cJTAG(SW3 上、外付けの 4 線→2 線アダプタ経由)
openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_cjtag.cfg -f scripts/jtag_check.tcl
```

`scripts/jtag_check.tcl` は、CPU が何をしていても(BIOS のプロンプトでも Linux の
シェルでも)実行できる確認手順。halt して pc・dcsr・mstatus・satp を表示し、
misa と dcsr.xdebugver を確かめ、SoC の識別文字列(CSR 空間 0x1200_2000)をシステム
バス経由で読み、a0 を書いて戻し、3 命令ステップして resume する。メモリには書かない。
最後に `JTAG CHECK RESULT : PASS` が出る。OpenOCD はそのまま残るので、
`telnet localhost 4444` で続けて操作できる。

```
halt
reg                                   ; 全レジスタ
reg pc
mdw 0x12002000 8                      ; 識別文字列(1 文字 32bit)
mdd 0x80000000 4                      ; メモリ(D$ 経由で読むので CPU と同じ値が見える)
step
resume
reset halt                            ; CPU だけリセットして BIOS の手前で止める
resume
```

### 知っておくこと

- **メモリは物理アドレス**。設定ファイルは `riscv set_enable_virt2phys off` なので、
  Linux のカーネル仮想アドレスをそのまま `mdw` しても読めない。物理アドレス
  (メモリは 0x8000_0000 から)で読むか、halt 中に `riscv set_enable_virt2phys on`
  にする(ページテーブルを OpenOCD が引く)。
- **ソフトウェアブレークポイントのみ**。トリガ(Sdtrig)は無いので `bp <addr> 4` は
  EBREAK の書き込みになる(`hw` 指定は不可)。書き込みは D$ に入り、`CPU_TOP` が I$ を
  無効化するので、そのまま効く。
- **Program Buffer は無い**(`progbufsize=0`)。接続時と最初の step の前に
  `Unable to insert program into progbuf` が 3 行出る。OpenOCD が、このコアに無い
  CSR(vlenb、mtopi、tselect)を探して Program Buffer を試した跡で、害はない。
- step 中は割り込みを取らない(`dcsr.stepie=0`)。Linux のアイドル(WFI)で halt
  すると、WFI を終えた次の命令で止まる。止めている間も `mtime` は進むので、
  resume 直後にタイマ割り込みがまとめて来る。
- 認証あり(SW2 上)のときは、設定ファイルが `init` のあとで
  `riscv authdata_write 0xbeefcafe` を実行する(次節)。

### 認証の確認

SW2 は OpenOCD を起動する**前に**上げておく(OpenOCD は接続時に DM をリセットし、
そこで認証が解ける)。鍵は環境変数 `AUTH_KEY` で差し替えられる。

| 手順 | 期待する結果 |
|---|---|
| 1. SW2 上、`AUTH_KEY=0x12345678 openocd -f ../FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg`(誤った鍵) | `Debugger is not authenticated to target Debug Module. (dmstatus=0x3)`、`examination failed`。telnet で `halt` しても `Target not examined yet` で何も起きず、LD0 は緑(実行中)のまま |
| 2. 続けて telnet で `riscv authdata_write 0xbeefcafe` | `authdata_write resulted in successful authentication`、`Examined RISC-V core`。以後 `halt` / `reg` / `mdw` が使える |
| 3. SW2 上、`AUTH_KEY` なしで `openocd ... -f scripts/jtag_check.tcl` | 設定ファイルが正しい鍵を書き、`JTAG CHECK RESULT : PASS` |
| 4. SW2 下、`AUTH_KEY=none`(鍵を書かない) | 認証不要なので、そのまま `examine` が通る |

未認証の間、DM は `dmstatus` の authenticated / version と `authdata` 以外をすべて 0 と
読ませ、halt 要求・ndmreset・システムバスアクセスを一切行わない(`CPU_DBG_SPEC.md` 4.7)。
dmstatus=0x3 は version=3(Debug Spec 1.0)で authenticated=0 の値。

## 4. 検証

| 環境 | 内容 |
|---|---|
| `SIM/SIM_CORE` `t23_debug` | コア単体。テストベンチのデバッガがコアの `dbg_*` を直接動かす。変異 M211–M231 |
| `SIM/SIM_OCD` | `RTL/TOP/TOP.sv`(本物のコアがハート)と OpenOCD の協調シミュレーション。halt、GPR/FPR/CSR、メモリ(メモリバス・周辺バス)、load_image、step、ソフトウェアブレークポイント、reset halt。認証ありでも同じ |
| `SIM/SIM_DBG` | デバッグ論理そのもの(TAP、DTM、DM、cJTAG、SBA)、3026 項目 |
| 実機 | `scripts/jtag_check.tcl`(上記) |
