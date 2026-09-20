# SIM_FPU — FPU 単体の検証

`RTL/CPU/CPU_FPU` を **Berkeley SoftFloat**(RISC-V 特殊化)と突き合わせる。
仕様は [`../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md`](../../RTL/CPU/CPU_CORE/CPU_CORE_SPEC.md) 10 章。

浮動小数点で間違えるのは丸めと特殊値なので、参照モデルは自作せず、RISC-V 仕様
自身が指している SoftFloat をそのまま使う。RISCV 特殊化を選ぶと canonical NaN、
NaN の伝播規則、**tininess は丸めの後で判定**という RISC-V の約束がそのまま入る。

## 使い方

| コマンド | 内容 |
|---|---|
| `make` | 既定のベクタで全演算を比較 |
| `make long` | ランダムベクタを 40 倍にして流す |
| `make OPS=0,1,2 run` | 指定した演算だけ(番号は `CORE_FPU` の `FOP_*`) |
| `make lint` | Verilator lint |

プラスアーグ: `+ops=<list>` `+rand=<n>` `+seed=<n>` `+verbose`

## SoftFloat の用意

リポジトリには含めない。一度だけビルドしておく。

```
git clone https://github.com/ucb-bar/berkeley-softfloat-3 ~/RISCV/berkeley-softfloat-3
cd ~/RISCV/berkeley-softfloat-3/build
cp -r Linux-x86_64-GCC Linux-aarch64-RISCV-GCC          # 使う環境に合わせる
sed -i 's/^SPECIALIZE_TYPE ?= .*/SPECIALIZE_TYPE ?= RISCV/' Linux-aarch64-RISCV-GCC/Makefile
make -C Linux-aarch64-RISCV-GCC
```

場所を変えるときは `make SOFTFLOAT=... SF_BUILD=...`。

## 何を突き合わせているか

- 全演算(算術・FMA・除算・平方根・比較・変換・符号操作・分類・転送)
- 単精度と倍精度
- **丸め 5 モード全部**(RNE / RTZ / RDN / RUP / RMM)
- 結果のビットパターンと**例外フラグの 5 ビット全部**

オペランドのプールは、浮動小数点が壊れる場所を狙って並べてある。

| 種類 | 例 |
|---|---|
| ゼロ | ±0 |
| subnormal | 最小・最大・中間 |
| 正規数の境界 | 最小正規数、最大正規数、その ±1ulp |
| 丸め境界 | 1±1ulp、2^52、2^53、2^23、2^24 |
| 無限大 | ±inf |
| NaN | canonical、signalling(正負) |
| NaN-boxing されていない単精度 | 上位が 0 や任意の値 |

これらの総当たり(34×34)に、ランダムなビットパターンを重ねている。

`make` で 45 万チェック、`make long` で約 494 万チェック。
