# mmRISC-2 の LiteX システムのメモリマップ

[English](MEMMAP.md)

Arty A7-100T で Linux を起動するシステム(`LitexSystem/`)のアドレスマップと、各領域をどこが実装しているか
(このリポジトリの RTL か、LiteX が生成するものか)、起動の途中で何がどこで動くかをまとめる。アドレスは物理アドレス。

## 1. リセット後の最初の命令

リセットされると、CPU は **0x1000_0000 の LiteX のブート ROM、つまり LiteX BIOS** から命令を取り出す。
この ROM は `RTL/` のモジュールではない。LiteX が SoC の中にブロック RAM として生成し、BIOS をビットストリームに
焼き込む。最初の命令フェッチの経路:

| 段 | 内容 | 場所 |
|---|---|---|
| 1 | リセット後のフェッチ先は `CPU_TOP` のパラメータ `RESET_VECTOR`。既定値は 0x8000_0000 で、LiteX が自分の ROM のアドレス 0x1000_0000 に設定する(`set_reset_address`) | `RTL/CPU/CPU_CORE/CORE_IFU/CORE_IFU.sv`(`fetch_pc <= RESET_VECTOR`)、`LitexSystem/cpu/mmrisc/core.py` |
| 2 | アドレスが `MEM_BASE`(0x8000_0000)より下なので、命令キャッシュはキャッシュしない。64 ビットの単発の読み出しが AXI4-Lite の周辺バスに出る | `RTL/CPU/CPU_CACHE/ICACHE/ICACHE.sv`(`s1_cacheable`)、`CPU_CACHE` |
| 3 | バスの調停(デバッガの System Bus Access はここで合流)、次に `CPU_MMIO`: CLINT でも PLIC でもないので `CPU_TOP` の `m_axil_*` から外へ出る | `RTL/BUS/BUS_ARB/BUS_ARB.sv`、`RTL/CPU/CPU_MMIO/CPU_MMIO.sv`、`RTL/CPU/CPU_TOP/CPU_TOP.sv` |
| 4 | AXI4-Lite から Wishbone へ。LiteX の SoC バス(32 ビットの Wishbone)とそのアドレスデコーダ | `core.py`(`AXILite2Wishbone`)、生成される `build/gateware/digilent_arty.v` |
| 5 | LiteX の `rom`: `Memory rom: 12141-words x 32-bit`。`digilent_arty_rom.init` で初期化される読み出し専用のブロック RAM で、中身は BIOS(`build/software/bios/bios.bin`、48,564 バイト) | `build/gateware/digilent_arty.v`、`digilent_arty_rom.init` |

つまり BIOS は、DRAM 上の OpenSBI に引き渡すまで(6 章)、ROM からキャッシュなしで動く。ROM は生成物なので、
BIOS を作り直す(`scripts/build_soc.sh`)たびに変わり、ビットストリームも作り直しになる。

## 2. CPU の決まりは 1 つ: `MEM_BASE`

`CPU_TOP` はアドレス空間を `MEM_BASE` = 0x8000_0000 の 1 か所だけで分ける:

| アドレス | 経路 | キャッシュ |
|---|---|---|
| ≥ 0x8000_0000 | L1 キャッシュ → L2(`CPU_L2`、256 KB)→ AXI4 のメモリバス(`m_axi4_*`)→ LiteDRAM | する(I$、D$、L2) |
| < 0x8000_0000 | AXI4-Lite の周辺バス → `CPU_MMIO` → CPU 内の CLINT / PLIC、それ以外は `m_axil_*` から SoC バスへ | しない |

`CPU_TOP` の中のアドレスは 40 ビット。LiteX は 32 ビットで扱うので、`core.py` が上位 8 ビットを落とす(この SoC の
アドレスはすべて 4 GB 未満)。LiteX が ROM と SRAM を「cached」と宣言しているのは、ROM を IO 領域に置くことを
LiteX が許さないからで、ハードウェアはキャッシュしない(`core.py` の `io_regions`)。

## 3. 物理マップ

| アドレス | 大きさ | 領域 | 実装 | バス、キャッシュ |
|---|---|---|---|---|
| 0x0200_0000 – 0x0200_FFFF | 64 KB | **CLINT**(ソフトウェア割り込み、タイマ) | `CPU_TOP` 内の `RTL/CPU/CPU_CLINT` | 周辺、しない |
| 0x0C00_0000 – 0x0C3F_FFFF | 4 MB | **PLIC**(デバイスツリーは 64 MB、0x0C00_0000 – 0x0FFF_FFFF と宣言) | `CPU_TOP` 内の `RTL/CPU/CPU_PLIC` | 周辺、しない |
| 0x1000_0000 – 0x1001_FFFF | 128 KB | **ROM**: LiteX BIOS(使用 48,564 バイト)。リセットベクタ | LiteX の `rom`(ブロック RAM) | 周辺、しない |
| 0x1100_0000 – 0x1100_1FFF | 8 KB | **SRAM**: DRAM が使えるまでの BIOS のデータとスタック | LiteX の `sram`(ブロック RAM) | 周辺、しない |
| 0x1200_0000 – 0x1200_FFFF | 64 KB | 周辺の **CSR**(4 章) | LiteX | 周辺、しない |
| 0x3000_0000 – 0x3000_1FFF | 8 KB | **Ethernet のパケットバッファ**: 受信 2 スロットが 0x3000_0000、送信 2 スロットが 0x3000_1000、各 2 KB | LiteX の `ethmac` | 周辺、しない |
| 0x8000_0000 – 0x8FFF_FFFF | 256 MB | **DRAM**(DDR3、MT41K128M16 × 2) | LiteDRAM。`CPU_L2` 経由 | メモリ、する |

ほかのアドレスには何も応答しない。そこへのアクセスは、バスに応じて SoC バスのバスエラー(タイムアウト後)か
アクセス例外で終わる。JTAG のデバッグモジュールはこのマップの上にアドレスを持たない: デバッガは JTAG で
つながり、その System Bus Access が外から上のマップを読み書きする(`RTL/CPU/CPU_DBG/CPU_DBG_SPEC.md`)。

CLINT の中(0x0200_0000 から): `msip` +0x0000、`mtimecmp` +0x4000、`mtime` +0xBFF8。`mtime` は 500 kHz で数える
(50 MHz / `CLINT_TICK_DIV` = 100。デバイスツリーの `timebase-frequency`)。PLIC の中(0x0C00_0000 から):
優先度 +0x00_0000、ペンディング +0x00_1000、許可 +0x00_2000 + 0x80 × コンテキスト、しきい値とクレーム
+0x20_0000 + 0x1000 × コンテキスト。コンテキスト 0 がマシンモード、1 がスーパーバイザモード。

## 4. 周辺の CSR(0x1200_0000)

`build/csr.csv`(`scripts/build_soc.sh` が生成)から。各 2 KB:

| アドレス | ブロック | Linux(デバイスツリー) |
|---|---|---|
| 0x1200_0000 | `ctrl`(リセット、スクラッチ、バスエラー) | `litex,soc-controller` |
| 0x1200_0800 | `ddrphy` | (BIOS だけが使う) |
| 0x1200_1000 | `ethmac` | `litex,liteeth`(0x3000_0000 と組) |
| 0x1200_1800 | `ethphy`(MDIO) | `litex,liteeth` |
| 0x1200_2000 | `identifier_mem`(SoC の名前の文字列) | — |
| 0x1200_2800 | `leds` | —(ベアメタルのサンプルが使う) |
| 0x1200_3000 | `sdcard` | `litex,mmc` |
| 0x1200_3800 | `sdram`(LiteDRAM のコントローラ) | (BIOS だけが使う) |
| 0x1200_4000 | `timer0` | `litex,timer` |
| 0x1200_4800 | `uart` | `litex,liteuart`(`console=liteuart0`) |

## 5. 割り込み

| 発生元 | LiteX の IRQ | PLIC のソース |
|---|---|---|
| UART | 0 | 1 |
| timer0 | 1 | 2 |
| Ethernet | 2 | 3 |
| SD カード | 3 | 4 |

PLIC のソース 0 は存在しないので、`core.py` が LiteX の線を 1 つずらしてつなぐ。CLINT はハートにソフトウェア割り込みと
タイマ割り込みを、PLIC はマシン(11)とスーパーバイザ(9)の外部割り込みを与える。Linux のタイマは Sstc の
S モードタイマ(`stimecmp`)で、同じ `mtime` を数える。

## 6. 起動の途中で何がどこで動くか

| 段 | コード | 動く場所 | モード |
|---|---|---|---|
| 1 | LiteX BIOS: DDR3 を初期化し(`sdram`、`ddrphy`)、検査し、SD カードの `boot.json` を読んで 2 つのファイルを DRAM に読み込む | ROM 0x1000_0000、データは SRAM 0x1100_0000 | M |
| 2 | OpenSBI(`fw_jump.bin`、デバイスツリーを内蔵): **0x8000_0000** に読み込まれる。2 MB を確保し(LiteX の領域 `opensbi`)、デバイスツリーを **0x8240_0000** に置く(`scripts/build_opensbi.sh` の `FW_JUMP_FDT_ADDR`) | DRAM | M |
| 3 | Linux(`Image`): **0x8020_0000** に読み込まれ(`boot.json`)、OpenSBI がデバイスツリーのアドレスを渡して S モードで起動する | DRAM | S |
| 4 | SD カードの第 2 パーティションの BusyBox か Debian(`root=/dev/mmcblk0p2`) | DRAM(仮想記憶、Sv39) | U |

`software/boot/boot.json`:

```json
{
    "Image":       "0x80200000",
    "fw_jump.bin": "0x80000000"
}
```

`software/baremetal/` のベアメタルのプログラム(`docs/ECLIPSE.md`)は、2〜4 段の代わりになる: 0x8000_0000 に
リンクし、BIOS が DRAM を整えた後に JTAG で読み込む。

## 7. 数値を決めている場所

| 何 | ファイル |
|---|---|
| 各領域のベースアドレス(CLINT、PLIC、ROM、SRAM、CSR、Ethernet バッファ、DRAM)、`MEM_BASE`、リセットベクタ | `LitexSystem/cpu/mmrisc/core.py`(`mem_map`、`set_reset_address`) |
| LiteX が割り当てた CSR のアドレスと IRQ の番号 | `LitexSystem/build/csr.csv`、`csr.json`(生成物) |
| Linux に伝える内容 | `LitexSystem/software/mmrisc_arty.dts`(`fw_jump.bin` に内蔵) |
| BIOS が OpenSBI と Linux を読み込む場所 | `LitexSystem/software/boot/boot.json` |
| OpenSBI がデバイスツリーを置く場所 | `LitexSystem/scripts/build_opensbi.sh`(`FW_JUMP_FDT_ADDR`) |
| RTL の既定値(`RESET_VECTOR`、`MEM_BASE`、`CLINT_BASE`、`PLIC_BASE`) | `RTL/CPU/CPU_TOP/CPU_TOP.sv` |

このマップは LiteX の Rocket 構成のものと 1 バイト単位で同じで、そのおかげで最初の Linux の起動はその
デバイスツリーを使い回せた(`docs/BRINGUP.md`)。どれかを変えるときは、デバイスツリーも一緒に変える。

## 8. ほかの構成

| 構成 | マップ |
|---|---|
| デバッグ立ち上げ用の設計 `FPGA/ARTY_A7_100T`(`RTL/TOP/TOP.sv`) | メモリバスの 0x8000_0000 に 64 KB の RAM、周辺バスの 0x1200_0000 に 4 KB の RAM。リセットベクタは 0x8000_0000 |
| シミュレーション `SIM/SIM_SYS`、`SIM_CORE` | 0x8000_0000 にメモリ、リセットベクタ 0x8000_0000(`SIM_SYS` の `make romboot` は、キャッシュなしのフェッチを確かめるために `MEM_BASE` より下から始める) |
| `SIM/SIM_BIOS` | 実機と同じマップに、本物の BIOS と UART・SD カードのモデル |
