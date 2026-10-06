# L2 キャッシュ単体の論理合成(out of context)

`RTL/CPU/CPU_L2` だけを Vivado で合成・配置配線し、資源とタイミングを見る。`CPU_TOP` に組み込む
(`CPU_L2_SPEC.md` 10 章の段階 3)前に、設計案 5 章の見積もりを確かめるため。

## 1. 実行(Windows、Vivado 2025.1)

このディレクトリで(共有フォルダ越しに):

```
synth_l2.bat                     256 KB・4 ウェイ・疑似 LRU、50 MHz、配置配線まで
synth_l2.bat 131072              128 KB
synth_l2.bat 262144 4 1          乱数置き換え
synth_l2.bat 262144 4 0 12.5     80 MHz で(余裕を見る)
synth_l2.bat 262144 4 0 20 0     合成だけ
```

引数は順に 容量(バイト)・ウェイ数・置き換え(1 = 乱数)・クロック周期(ns)・配置配線(1 / 0)。
結果は `output/L2_<KB>K_<ウェイ>w[_rnd]/` に出る。

| ファイル | 中身 |
|---|---|
| `summary.txt` | 数字のまとめ(LUT、FF、ブロック RAM、LUT RAM、WNS、レジスタ間の WNS、WHS、スライス) |
| `utilization_synth.rpt` / `utilization.rpt` | モジュールごとの資源(合成後 / 配線後) |
| `ram_utilization.rpt` | 配列がブロック RAM・LUT RAM のどちらになったか |
| `timing_summary.rpt`、`timing_paths.rpt`、`timing_reg2reg.rpt` | 配線後のタイミング(最後のものはレジスタからレジスタだけ) |

## 2. 制約の考え方

単体なので AXI のポートにはピンが無い。ポートの両側に周期の 30 % ずつを入力・出力遅延として
与える(`CPU_CACHE` と LiteX の側の論理の分の大まかな見積もり)。入力から出力へ素通しの経路
(AXI の READY / VALID、一部の書き込みの W)には周期の 40 % が残る。**組み込んだ後の本当の値は
段階 3 の全体の合成で決まる**ので、ここではレジスタ間の WNS(`timing_reg2reg.rpt`)を主に見る。

## 3. 見込み(`CPU_L2_SPEC.md` 5 章)と確かめること

| 項目 | 見込み(256 KB・4 ウェイ) | 確かめること |
|---|---|---|
| データ配列 | RAMB36 64 個(1 ウェイ 8,192 語 × 64 ビット = 16 個) | `ram_utilization.rpt` でブロック RAM になっていること。FF が 2 万を超えたらスクリプトが止める(配列が FF になった) |
| タグ配列 | RAMB36 4 個(1 ウェイ 1,024 × 26 ビット)。設計案の「2 タイル」より多い | 同上 |
| 疑似 LRU | LUT RAM(1,024 × 3 ビット) | `summary.txt` の LUT RAM の数が 0 でないこと(0 なら FF になっている) |
| LUT | 2,500〜4,000 | |
| FF | 1,500〜2,500(追い出しバッファ 512、R の FIFO 約 280 を含む) | |
| WNS(50 MHz) | 正 | 遅い経路があれば、どこか(`timing_reg2reg.rpt`)。候補はブロック RAM の出力 → タグ比較 → ウェイ選択 → R の FIFO(`M_CMP`) |

全体(`BENCH.md` 13 章の版)ではブロック RAM 40.5 / 135、LUT 45,598(71.9 %)、スライス 88.6 %。
L2 を足して 約 109 / 135 タイルになる見込み。スライスは単体の数がそのまま足されるわけでは
ない(全体では周りの論理とスライスを分け合う)ので、目安として見る。

## 4. 結果(2026-10-06、Vivado 2025.1、256 KB・4 ウェイ・疑似 LRU、50 MHz)

```
L2_256K_4w  (period 20.0 ns, I/O delay 6.0 ns each side)
after synthesis: 1078 LUT, 991 FF, RAMB36 68, RAMB18 0 (tag 4, data 64 primitives), LUT RAM cells 12
after routing: WNS 3.953 ns (register to register 5.977 ns), WHS 0.161 ns, 659 slices
```

配列はすべてブロック RAM(データ 64、タグ 4)、疑似 LRU は LUT RAM になった。LUT・FF は
見込みの半分以下。最悪のレジスタ間の経路は、タグの読み出し → タグ比較 → ヒット → データ配列
64 個の読み出し許可(13.5 ns、うち配線 9.1 ns)。読み方は `CPU_L2_SPEC.md` 5 章。

