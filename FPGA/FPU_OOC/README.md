# FPU 単体の論理合成(out of context)

`RTL/CPU/CPU_FPU` の FPU を 1 つだけ Vivado で合成・配置配線し、資源とタイミングを見る。
パイプライン版 `FPU_PIPE`(ROADMAP C2、`CPU_CORE_SPEC.md` 10.11)と、いまコアが使っている
`CORE_FPU` を同じ条件で比べ、パイプライン化の値段を知るため。

## 実行(Windows、Vivado 2025.1)

```
synth_fpu.bat                 FPU_PIPE、50 MHz、配置配線まで
synth_fpu.bat CORE_FPU        比べるために今の FPU
synth_fpu.bat FPU_PIPE 15     66 MHz で(余裕を見る)
```

引数は順に トップ(`FPU_PIPE` / `CORE_FPU`)・クロック周期(ns)・配置配線(1 / 0)。結果は
`output/<トップ>/summary.txt`(LUT、FF、DSP、LUT RAM、WNS、レジスタ間の WNS、WHS、スライス)。

ポートの両側に周期の 30 % を入出力遅延として与える(`FPGA/L2_OOC` と同じ考え方)。コアでは
オペランドが EX の転送の多重化器を通って来るので、入力側が厳しい。どちらの FPU も最初のサイクルで
オペランドを写し取るので、レジスタ間の WNS(`timing_reg2reg.rpt`)が FPU そのものの余裕。

## 見たいこと

- **LUT・FF の増え方**: 段ごとに制御と待つ答え(束)を持たせた分。FF は増えるが LUT は大きくは
  増えない見込み(各段の論理は `CORE_FPU` の状態と同じ)。全体はいまスライス 91.4 %(`TIMING.md`
  32 章)なので、ここで増える分が組み込みの予算になる
- **DSP**: 変わらないはず(部分積は `CORE_FPU` でも 1 サイクルで全部出していた)
- **レジスタ間の WNS**: `CORE_FPU` と同じくらいのはず(段の切れ目が状態の切れ目と同じ)
