# Eclipse によるベアメタルのプログラム開発(JTAG / cJTAG)

[English](ECLIPSE.md)

mmRISC-2 のボードは持っているが、PC にはまだ何も入れていない人が、ボードで動く C のプログラムを 1 行ずつ追える
ようになるまでの手順。ツールの用意、リポジトリの中の場所、ビルド、JTAG(または 2 線の cJTAG)でのロード、
Eclipse でのデバッグまで。Ubuntu(x86_64 / arm64)と Windows のどちらでも、同じプロジェクトのファイルで動く。

ここでのベアメタルのプログラムは、Linux なしで CPU の上にマシンモードで単独で走る C のプログラム。256 MB の
DRAM、UART(printf)、LED、タイマ、割り込みをすべて自分で使える。デバッガが DRAM に読み込むので、SD カードにも
FPGA のフラッシュにも何も書かない。

## 1. 必要なもの

**ハードウェア**

| | |
|---|---|
| ボード | mmRISC-2 のビットストリームを入れた Digilent Arty A7-100T(`LitexSystem/README_J.md`、`FPGA/ARTY_A7_100T/README.md`) |
| JTAG アダプタ | PMOD JA に配線した FT2232H のモジュール(チャネル A)(`FPGA/ARTY_A7_100T/README.md` 3 章、`JTAG_J.md` 1 章) |
| cJTAG を使う場合 | `JTAG_J.md` 1 章の 4 線 → 2 線のアダプタ |
| シリアル | ボード自身の USB ポート(LiteX の UART、115200 baud)と端末ソフト |

**ソフトウェア**(どれも無料。確かめた版)

| ツール | Ubuntu | Windows |
|---|---|---|
| Eclipse IDE for Embedded C/C++ Developers(Eclipse Embedded CDT) | 2023-06 以降、`linux-gtk-x86_64` か `-aarch64` | 2023-06 以降、`win32-x86_64` |
| xPack GNU RISC-V Embedded GCC(`riscv-none-elf-gcc`) | 15.2.0-1、`linux-x64` か `linux-arm64` | 15.2.0-1、`win32-x64` |
| OpenOCD、4 線 JTAG | ソースからビルドした riscv-openocd、または xPack OpenOCD 0.12.0-7 | xPack OpenOCD 0.12.0-7 |
| OpenOCD、2 線 cJTAG | ソースからビルドした **riscv-openocd**(`ftdi oscan1_mode` がある。xPack OpenOCD には無い) | MSYS2 でビルドした riscv-openocd |
| make、rm(Eclipse のマネージドビルド) | システムのもの | xPack Windows Build Tools |
| Python 3 | システムのもの | 新しいプロジェクトを作るときだけ(8 章) |

Eclipse は https://www.eclipse.org/downloads/packages/ (「Eclipse IDE for Embedded C/C++ Developers」)から、
xPack のツールは https://xpack-dev-tools.github.io/ から(それぞれ GitHub のリリースのページに、アーカイブと
`.sha` のチェックサムがある)。どれも管理者権限でのインストールは要らず、好きな場所に展開するだけ。

**このツールチェーンを使う理由**: DRAM は 0x8000_0000(2 GB)から始まり、そこにリンクするには C ライブラリが
`-mcmodel=medany` でビルドされている必要がある。xPack の newlib はそうなっている。riscv-gnu-toolchain を既定の
設定でビルドした newlib は `medlow` で、リンクで「relocation truncated to fit: R_RISCV_HI20」になる。

## 2. どこに何があるか

```
mmRISC-2/
├── LitexSystem/
│   ├── docs/ECLIPSE_J.md                  この文書
│   └── software/baremetal/
│       ├── common/                        すべてのプログラムで共通
│       │   ├── mmrisc.h                   SoC のアドレス(UART、LED、CLINT)、CSR の操作
│       │   ├── crt0.S                     起動: _start、トラップの入口
│       │   ├── syscalls.c                 newlib が必要とするもの(UART への printf、malloc、exit)
│       │   ├── link.ld                    すべて 0x8000_0000 からの DRAM に置く
│       │   ├── common.mk                  コマンドラインでのビルドの規則
│       │   └── load.gdb                   コマンドラインのデバッガの手順
│       ├── hello/                         最初のプログラム: printf、mcycle、LED
│       ├── timer_irq/                     割り込み(CLINT のタイマ)を C で受ける
│       │     それぞれに main.c、Makefile と Eclipse のファイル:
│       │     .project、.cproject、"<名前> Debug JTAG.launch"、"<名前> Debug cJTAG.launch"
│       └── eclipse_project.py             新しいプログラムの Eclipse のファイルを作る
└── FPGA/ARTY_A7_100T/openocd/
    ├── ft2232h_jtag.cfg                   OpenOCD、4 線 JTAG
    └── ft2232h_cjtag.cfg                  OpenOCD、2 線 cJTAG
```

リポジトリの構成はそのままにしておくこと: 起動構成は OpenOCD の設定を
`<プロジェクト>/../../../../FPGA/ARTY_A7_100T/openocd/` という道筋で探し、プロジェクトは `../common` を
リンクしている。プロジェクトはその場で使う(Eclipse のワークスペースにはコピーしない)。

## 3. ツールの用意

### Ubuntu

```bash
mkdir -p ~/tools && cd ~/tools
tar xzf xpack-riscv-none-elf-gcc-15.2.0-1-linux-x64.tar.gz       # または -linux-arm64
tar xzf eclipse-embedcpp-2023-06-R-linux-gtk-x86_64.tar.gz       # または -aarch64
```

OpenOCD: 4 線 JTAG だけなら xPack OpenOCD を同じように展開すれば足りる。cJTAG には riscv-openocd をビルドする
(https://github.com/riscv-collab/riscv-openocd : `./bootstrap && ./configure --enable-ftdi && make && sudo make
install` で `/usr/local/bin/openocd` に入る)。こちらは 4 線 JTAG もできる。

root なしでアダプタの USB を使うには、OpenOCD のソースの `contrib/60-openocd.rules`(xPack OpenOCD の `contrib/`
にもある)を `/etc/udev/rules.d/` に置いて `sudo udevadm control --reload` し、アダプタを挿し直す。仮想マシンでは
FT2232H(とシリアルコンソール用にボードの USB)を仮想マシンに渡しておく。

### Windows

1. `xpack-riscv-none-elf-gcc-15.2.0-1-win32-x64.zip`、`xpack-openocd-0.12.0-7-win32-x64.zip`、
   `xpack-windows-build-tools-<版>-win32-x64.zip` を、たとえば `C:\tools\` の下に展開する。
2. `eclipse-embedcpp-2023-06-R-win32-x86_64.zip` を展開して `eclipse.exe` を起動する。
3. OpenOCD が FT2232H のチャネル A を使うには WinUSB ドライバが要る: Zadig(https://zadig.akeo.ie/ )で
   Options > List All Devices、アダプタの **Interface 0**(チャネル A)を選んで WinUSB を入れる。ボード自身の
   USB シリアルは FTDI のドライバのまま(コンソールの COM ポート)。
4. ボードの COM ポート用の端末ソフト(Tera Term など)、115200 baud。

Windows で cJTAG を使うには riscv-openocd のビルドが要る(MSYS2 の mingw-w64 で、同じく `bootstrap` /
`configure` / `make`)。4 線 JTAG は xPack OpenOCD のままで動く。

## 4. ボードの準備

1. Linux のときと同じようにビットストリームを書き込む(Vivado の Hardware Manager か、フラッシュ)。
2. **SD カードを抜き、Ethernet も抜いて** RESET を押す。LiteX BIOS は起動するものを見つけられず、プロンプト
   `litex>` で止まる。その時点で DRAM の初期化は済んでいて、プログラムにはそれが要る。
3. ボードの USB ポートでシリアル端末を開く(115200 baud)。BIOS のプロンプトと、後でプログラムの出力がここに出る。
4. スイッチ: 4 線 JTAG なら **SW3 を下**(cJTAG なら上)、**SW2 を下**(認証なし。上にすると OpenOCD の設定が
   鍵を送る。`JTAG_J.md` 3 章)。
5. JTAG アダプタをつなぐ。

プログラムは CPU をリセットせずに読み込む: リセットすると BIOS が最初の命令からやり直し、DRAM がまだ使えない。
そのため起動構成と `load.gdb` は、BIOS のどこにいても CPU を止めるだけで、プログラムを読み込んで `_start` から
走らせる。

## 5. Eclipse の設定(最初に 1 回)

1. Eclipse を起動し、ワークスペースは **リポジトリの外** に作る(例 `~/mmRISC-2_ws`)。Eclipse 自身の設定を
   置くだけ。
2. Window > Preferences > MCU:
   - **Global RISC-V Toolchains Paths**: Default toolchain は `xPack GNU RISC-V Embedded GCC`、Toolchain folder は
     xPack GCC の `bin`(例 `/home/<あなた>/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin`、
     `C:\tools\xpack-riscv-none-elf-gcc-15.2.0-1\bin`)。
   - **Global OpenOCD Path**: Executable は `openocd`(Windows では `openocd.exe`)、Folder はそれがあるフォルダ
     (riscv-openocd なら `/usr/local/bin`、または xPack OpenOCD の `bin`)。
   - Windows だけ、**Global Build Tools Path**: xPack Windows Build Tools の `bin`。
3. File > Import > General > **Existing Projects into Workspace** > Next。Root directory は
   `<リポジトリ>/LitexSystem/software/baremetal`。`hello` と `timer_irq` にチェックを入れ、**「Copy projects into
   workspace」は外したまま** Finish。

プロジェクトは Eclipse Embedded CDT の「マネージドビルド」で、ツールチェーンは「RISC-V Cross GCC」: Eclipse が
`Debug/` か `Release/` に自分でメイクファイルを作る。設定(Project > Properties > C/C++ Build > Settings)は最初から
合わせてある: `rv64imafdc` + `_zicsr_zifencei_zba_zbb_zbs`、ABI `lp64d`、コードモデル `medany`、インクルードの道筋と
リンカスクリプト `../common/link.ld`、`-nostartfiles`、`libm`。Debug は `-O0`(1 行ずつ追うため)、Release は `-O2`。

## 6. ビルド

プロジェクトを選んで Project > Build Project(または金槌のボタン)。Console の最後は

```
Invoking: GNU RISC-V Cross Print Size
riscv-none-elf-size --format=berkeley "hello.elf"
   text	   data	    bss	    dec	    hex	filename
  35220	   2928	    712	  38860	   97cc	hello.elf
Finished building: hello.siz
```

デバッガが読み込むのは `Debug/hello.elf`。`hello.lst` はソース付きのリスティング。

## 7. デバッグ

1. Run > Debug Configurations… > **GDB OpenOCD Debugging** > `hello Debug JTAG`(SW3 を上にしたなら
   `hello Debug cJTAG`)> Debug。初回は Debug パースペクティブに切り替えるか聞かれるので、はい。
2. Eclipse が OpenOCD を起動し(Console に `Examined RISC-V core` と `Listening on port 3333`)、gdb を起動し、
   CPU を止め、プログラムを読み込み、pc を `_start` にして **`main` の最初の行** まで走らせて止まる。
3. そこから:

| 操作 | 結果 |
|---|---|
| F6(Step Over) | 1 行進む。シリアル端末に `Hello from mmRISC-2 ...` |
| `count_primes(...)` の行で F5(Step Into) | 関数の中に入る |
| 行の左端をダブルクリック、F8(Resume) | そのブレークポイントで止まる |
| Variables / Expressions ビュー | ローカル変数。Expressions に `led_count` を足すと LED と一緒に変わる |
| Registers ビュー、Memory ビュー(`0x80000000`)、Disassembly | レジスタ(CSR も)、メモリ、命令 |
| ブレークポイントなしで F8 | 最後まで走る。`exit` は `_exit` の中の `ebreak` で止まる |
| Ctrl+F2(Terminate) | 終える(OpenOCD と gdb も止まる) |

2 つのプログラムの出力(`hello` は Debug、`-O0` でビルドしたもの):

```
Hello from mmRISC-2 (bare metal, machine mode)
  misa    800000000014112d
  mhartid 0
  primes up to 20000: 2262
  11663566 cycles, 5197272 instructions, CPI 2.244, 233272 us
done
```

```
timer_irq: the CLINT every 100 ms
  5 interrupts
  10 interrupts
  15 interrupts
  20 interrupts
done
```

`hello` は LD4〜LD7 で 0 から 15 まで数え、`timer_irq` は 100 ms ごとに数える。`timer_irq` で `trap_handler()` に
ブレークポイントを置くと割り込みの中で止まり、`mcause` は `0x8000000000000007`(マシンタイマ割り込み)。

ブレークポイント: ソフトウェアのブレークポイント(いくつでも)は DRAM で使える。ハードウェアのトリガは 4 つで、
ハードウェアのブレークポイントとウォッチポイントで共有する。ウォッチポイントは変数の先頭アドレスへのアクセスで
だけ止まる(`JTAG_J.md` 3 章)。

もう一度走らせるには、Terminate して同じ構成をもう一度起動する(BIOS がプロンプトにいる必要はもうない: CPU は
どこにいても止められ、DRAM は RESET まで使える状態のまま)。

## 8. 自分のプログラムを作る

```bash
cd <リポジトリ>/LitexSystem/software/baremetal
mkdir myprog
cp hello/main.c hello/Makefile myprog/
sed -i 's/^TARGET := hello/TARGET := myprog/' myprog/Makefile
python3 eclipse_project.py myprog      # "myprog" 用の .project、.cproject、2 つの .launch
```

そのあと 5 章と同じく File > Import > Existing Projects into Workspace。プロジェクトのフォルダに置いた `.c` /
`.S` は、何もしなくても Eclipse がビルドする。コマンドラインでは Makefile の `SRCS` に足す。

`common/` がプログラムに与えるもの:

- UART への `printf` / `puts` / `getchar`(newlib、`long long` と浮動小数点も)、`malloc`(ヒープはプログラムの
  終わりから、スタックのある DRAM の最上位の 64 KB の手前まで)
- `mmrisc.h`: `LEDS_OUT`、UART のレジスタ、`CLINT_MTIME` / `CLINT_MTIMECMP`、`csr_read()` / `csr_write()` /
  `csr_set()` / `csr_clear()`、`mmrisc_cycle()`、`mmrisc_mtime()`(500 kHz)、`mmrisc_delay_us()`
- `trap_handler(mcause, mepc, mtval)`: すべてのトラップで呼ばれ、C の関数が使ってよい整数レジスタは退避済み。
  割り込みを受けるにはプログラムで定義する(`timer_irq` のように)。既定のものは例外を表示して止まる。戻る例外
  ハンドラは自分で `mepc` を進めること。
- FPU は有効(`mstatus.FS`)、割り込みはプログラムが有効にするまで無効、`.bss` はクリア済み。

## 9. Eclipse を使わない場合

同じプログラムをコマンドラインでビルドして走らせられる:

```bash
export PATH=<xpack-gcc>/bin:$PATH
cd <リポジトリ>/LitexSystem/software/baremetal/hello
make OPT=0                      # out/hello.elf(既定は OPT=2)
```

```bash
openocd -f <リポジトリ>/FPGA/ARTY_A7_100T/openocd/ft2232h_jtag.cfg        # 別のターミナルで
```

```bash
riscv-none-elf-gdb -x ../common/load.gdb out/hello.elf
```

`load.gdb` は OpenOCD につなぎ、CPU を止め、読み込み、pc を `_start` にして `main` まで走らせる。あとは gdb の
コマンド(`next`、`step`、`break`、`print`、`continue` ...)。`make hex` は `out/hello.hex` も作り、`SIM/SIM_BIOS` で
SoC 全体ごとシミュレーションできる: `./obj_dir/Vtb_BIOS +linux +fw=<.hex> +image=<任意の hex>`(ROM が 0x8000_0000 に
飛ぶ。UART の出力はシミュレータのログに出る)。

## 10. うまく動かないとき

| 症状 | 原因と対処 |
|---|---|
| リンクで `relocation truncated to fit: R_RISCV_HI20` | newlib が `medlow` のツールチェーン: xPack GCC を使う(1 章) |
| Eclipse:「Program riscv-none-elf-gcc not found in PATH」 | Global RISC-V Toolchains Paths(5 章)が未設定か、別のツールチェーン名に設定されている |
| OpenOCD: `unable to open ftdi device` | アダプタが見えていない: USB を VM に渡しているか、udev の規則(Ubuntu)、Interface 0 の WinUSB(Windows)。設定は説明文字列 `Dual RS232` と 0403:6010 を探すので、モジュールが違う名前なら `ftdi device_desc` を変える |
| OpenOCD: `invalid command name "ftdi oscan1_mode"` | cJTAG を、それの無い OpenOCD で: riscv-openocd を使う |
| OpenOCD: `dmstatus=0x3`、`examination failed` | SW2 が上で、鍵が通っていない(`JTAG_J.md` 3 章) |
| 読み込めたが何も出ない、すぐにトラップで止まる | DRAM が初期化されていない: BIOS を通っていない(4 章)、または起動構成を CPU をリセットするように変えた。RESET を押し、`litex>` を待って、もう一度デバッグする |
| `_exit` の中の `ebreak` で止まる | プログラムが終わった(`main` から `return`、または `exit()`) |
| ボードで Linux が動いていた | デバッガで止まり、メモリは上書きされる。終わったら RESET を押す(SD カードを挿せば Linux がまた起動する) |

## 11. しくみ

- プログラムは DRAM の先頭でマシンモードで走る: `link.ld` が `_start`(`.text.init`)を 0x8000_0000 に置き、
  その後にコードとデータ。スタックは 0x9000_0000 の手前の 64 KB。LiteX BIOS は ROM(0x1000_0000)で走り、データは
  SRAM(0x1100_0000)なので、DRAM は使わない。
- `crt0.S` は割り込みを止め、`mtvec` を自分のトラップの入口にし、`gp`、`sp`、FPU を設定し、`.bss` をクリアして
  `main()` を呼ぶ。`exit()` は `ebreak` で終わり、デバッガ(OpenOCD が `dcsr.ebreakm` を立てる)がそこで止める。
- デバッガはデバッグモジュールのシステムバスアクセスでプログラムを書き込み、それはデータキャッシュを通る。その
  ときコアが命令キャッシュを無効にするので、`fence.i` は要らない(`JTAG_J.md` 3 章)。
- 起動構成: リセットなし(`doFirstReset` / `doSecondReset` が off)、プロジェクトの `Debug/<名前>.elf` のイメージと
  シンボルを読み込み、`set $pc = _start`、`main` で止める。gdb は `${cross_prefix}gdb`(全体のツールチェーンの
  道筋)、OpenOCD は `${openocd_path}/${openocd_executable}`(全体の OpenOCD の道筋)に
  `-f "${project_loc}/../../../../FPGA/ARTY_A7_100T/openocd/ft2232h_[c]jtag.cfg"`。`eclipse_project.py` が、
  プログラムのフォルダにこれらとプロジェクトのファイルを書く。
