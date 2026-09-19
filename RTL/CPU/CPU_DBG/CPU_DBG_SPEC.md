# mmRISC-2 暫定デバッグ論理 仕様書

- 版: Rev-2 (2026-09-17) 実装・検証結果を反映(10章)
  - 2026-09-19: `RTL/CPU_DBG/` を `RTL/CPU/CPU_DBG/` へ移動(CPU_TOP 配下にインスタンス化されるため)
  - 2026-09-19: メモリバスのデバッグアクセスを L1 データキャッシュ経由にした
    (`DBG_CACHE`、`CPU_CACHE_SPEC.md` 4.7)。周辺バスは従来どおり `DBG_BUSMST` 直結
- 準拠仕様: **The RISC-V Debug Specification Version 1.0, Revised 2025-02-21: Ratified**
  (`Spec/riscv-debug-specification.pdf`)。以下、節番号はこの仕様書のもの。
- 対象: `RTL/CPU/CPU_DBG/`(デバッグ論理)、`RTL/CPU/CPU_TOP/`(組み込み)、`RTL/TOP/`(FPGAトップ)
- 決定事項は 9章にまとめた。

---

## 1. 目的と範囲

CPU本体(パイプライン、MMU、キャッシュ、CLINT/PLIC)は未実装である。本フェーズでは、
**JTAGから見るとRV64GCのハートと関連資源が存在するかのように振る舞うデバッグ論理**を作り、
OpenOCDからJTAG経由でアクセスできることをシミュレーションとFPGA(Arty A7-100T)で確認する。

| 項目 | 本フェーズ |
|---|---|
| JTAG DTM (6.1) | **本実装**(CDC含む、CPU本体実装後もそのまま使う) |
| Debug Module レジスタ (3.14) | **本実装** |
| System Bus Access (3.10) | **本実装**(実際のメモリバス/周辺バスへアクセス) |
| Abstract Command: Access Register (3.7.1.1) | **暫定**: 疑似ハート内のレジスタ記憶域に対して実行 |
| Abstract Command: Access Memory (3.7.1.3) | **本実装**(SBAと同じバスマスタを使用) |
| ハートの halt / resume / step / reset | **暫定**: 疑似ハート(状態機械のみ)で模擬 |
| コアデバッグCSR (dcsr/dpc/dscratch, 4.9) | **暫定**: 疑似ハートのレジスタ |
| Program Buffer (3.8) | 実装しない(progbufsize=0) |
| Trigger Module / Sdtrig (5章) | 実装しない(CPU本体実装後に検討) |
| Quick Access (3.7.1.2) | 実装しない(cmderr=2) |
| cJTAG (IEEE 1149.7 OScan1) | **本実装**(JTAGと切り替え、7章・3.6) |
| 認証 (authdata, 3.12) | **本実装**(有効/無効と鍵をCPU_TOP外部から入力、4.7) |

「暫定」部分は、CPU本体実装時に疑似ハートを本物のハートへのインタフェースに置き換える。
DTM・DMレジスタ・SBA・Access Memoryは置き換えずに使い続ける前提で作る。

---

## 2. ブロック構成

```
                       CPU_TOP
  ┌──────────────────────────────────────────────────────────────────────┐
  │  CPU_DBG                                                             │
  │  ┌──────────────┐ DMI req/resp  ┌─────────────────────────────────┐ │
  │  │ DBG_DTM      │  (CDC:       │ DBG_DM                          │ │
  │  │  JTAG TAP    │  4-phase     │  DMレジスタ / Abstract Command  │ │
  │  │  IR/DR       │  handshake)  │  SBA制御 / 疑似ハート接続       │ │
  │  │ [TCK domain] │◀────────────▶│ [system clock domain]           │ │
  │  └──────────────┘              └──────┬───────────────┬──────────┘ │
  │                                        │ halt/resume   │ bus req    │
  │                                ┌───────▼───────┐ ┌─────▼────────┐  │
  │                                │ DBG_HART_STUB │ │ DBG_BUSMST   │  │
  │                                │ 疑似ハート    │ │ SBA/AccessMem│  │
  │                                │ GPR/FPR/CSR   │ │ バスマスタ   │  │
  │                                └───────────────┘ └─────┬────────┘  │
  │                                                         │           │
  │  CPU_BFM (シミュレーション用、既存) ──┐                 │           │
  │                                        ▼                 ▼           │
  │                                   ┌──────────────────────────┐      │
  │                                   │ BUS_ARB (2マスタ→各バス) │      │
  │                                   │ + アドレスデコード       │      │
  │                                   └───────┬──────────┬───────┘      │
  └───────────────────────────────────────────┼──────────┼──────────────┘
                                   メモリバス AXI4   周辺バス AXI4-Lite
```

| モジュール | 置き場所 | 内容 |
|---|---|---|
| `CPU_DBG` | `RTL/CPU/CPU_DBG/CPU_DBG/` | 下記のラッパ |
| `DBG_CJTAG` | `RTL/CPU/CPU_DBG/DBG_CJTAG/` | cJTAG(OScan1)受信部。JTAGモードでは素通し |
| `DBG_DTM` | `RTL/CPU/CPU_DBG/DBG_DTM/` | JTAG TAP、IDCODE/dtmcs/dmi/BYPASS、CDC送信側 |
| `DBG_CDC` | `RTL/CPU/CPU_DBG/DBG_CDC/` | 同期化器、4相ハンドシェイク、リセット同期化器 |
| `DBG_DM` | `RTL/CPU/CPU_DBG/DBG_DM/` | DMレジスタ、Abstract Command、SBA制御 |
| `DBG_BUSMST` | `RTL/CPU/CPU_DBG/DBG_BUSMST/` | SBA/Access Memory用バスマスタ(AXI4/AXI4-Lite) |
| `DBG_HART_STUB` | `RTL/CPU/CPU_DBG/DBG_HART_STUB/` | 疑似ハート(暫定、CPU本体実装時に削除) |
| `DBG_CACHE` | `RTL/CPU/CPU_DBG/DBG_CACHE/` | メモリバスアクセスをデータキャッシュ経由にする(`DBG_VIA_CACHE=1`、既定) |
| `BUS_ARB` | `RTL/BUS/BUS_ARB/` | BFMとデバッグバスマスタの調停、メモリバス/周辺バスの振り分け |


---

## 3. JTAG DTM (6.1)

### 3.1 TAP

- IEEE 1149.1 の16状態TAPコントローラ。TRST(非同期、Low有効)とTest-Logic-Reset(TMS=1×5)の両方でリセット。
- **IR長 5bit**、TAPリセット時 IR = `0x01`(IDCODE)。Capture-IR で `0b00001` をロード。
- TDO は TCK 立ち下がりで更新。Shift-IR/Shift-DR 以外では `jtag_tdo_en=0`(FPGAではピンをHi-Z)。

| IR | レジスタ | 長さ | 内容 |
|---|---|---|---|
| `0x00` | BYPASS | 1 | |
| `0x01` | IDCODE | 32 | `0x26d6d001`(3.2) |
| `0x10` | dtmcs | 32 | 3.3 |
| `0x11` | dmi | 41 (abits=7) | 3.4 |
| その他 | BYPASS | 1 | 未実装命令はBYPASS(6.1.2) |

### 3.2 IDCODE(決定)

| フィールド | 提案値 | 備考 |
|---|---|---|
| Version [31:28] | `0x2` | mmRISC-2 |
| PartNumber [27:12] | `0x6d6d` ("mm") | mmRISC-1と同じ |
| ManufId [11:1] | `0x000` | JEDEC IDなし(非商用)。mmRISC-1と同じ |
| [0] | `1` | |
| **IDCODE** | **`0x26d6d001`** | mmRISC-1 は `0x16d6d001` |

### 3.3 dtmcs

| フィールド | 値 |
|---|---|
| version | 1 (0.13/1.0) |
| abits | 7 |
| idle | `1`(3.5参照) |
| dmistat | op のエイリアス |
| dmireset (W1) | op の sticky エラー(2/3)と errinfo をクリア。実行中のDMIトランザクションには影響しない |
| dtmhardreset (W1) | sticky op / errinfo を初期化し、まだDM側へ出していない要求を取り消す。既にDM側へ出た要求は完了まで busy を返す(3.5) |
| errinfo | 実装する。reset=4(unknown)。busy はエラーではないので 4 のまま。DMからのエラー(op=2)時 3 |

### 3.4 dmi

- `{address[6:0], data[31:0], op[1:0]}`
- Update-DR: op=1(read)/2(write) で、sticky エラーが無く、かつ前のトランザクションが完了していればDMIリクエストを開始。
  前のトランザクションが未完了なら op を **3(busy, sticky)** にし、要求は捨てる。
- Capture-DR: 完了していれば結果を data に取り込み、op=0(success)。未完了なら op=3(busy, sticky)。
- op=0(nop)は何もしない。op=3(reserved)は nop 扱い。

### 3.5 CDC(TCK ⇔ システムクロック)【重要要件】

**TCK とシステムクロックの周波数・位相関係は任意**(TCKが速くても遅くても、停止していても)とする。

方式: **Bundled data + 4相ハンドシェイク(req/ack)**

```
 TCK domain (DTM)                          system clock domain (DM)
 ─────────────────                         ────────────────────────
 req_data  (addr, wdata, op) ──── 保持 ───▶ (同期化しない: req中は不変)
 req  ──▶ [2FF sync] ──▶ req_s             req_s 立ち上がりで1回だけ実行
 ack_s ◀── [2FF sync] ◀── ack              実行完了で resp_data 確定 → ack=1
 resp_data (rdata, err) ◀── 保持 ───        (ack中は不変)
 req=0 (ack_s=1 を見てから)                 req_s=0 を見て ack=0
 次の req は ack_s=0 を確認してから
```

- データ(アドレス・書き込みデータ・読み出しデータ)は**同期化せず**、ハンドシェイク信号で安定期間を保証する(bundled data)。
  req/ack の1bit制御線だけを2段FFで同期化する。多ビット値を直接同期化しないので、ビット間スキューによる化けが原理的に起きない。
- 各ドメインは**自クロックのエッジだけで進む**。TCKが停止していてもDM側は処理を完了して ack を保持し、TCK再開時に完了を検出する。
  逆にシステムクロックが遅い場合は DTM が op=busy を返し、デバッガが Run-Test/Idle を追加して再試行する(6.1.5 の規定どおり)。
- **dtmhardreset / TRST / Test-Logic-Reset による中断**: DTM側は req を落とし、以後 **ack_s=0 を観測するまで新しい req を出さない**。
  DM側は実行中の操作を最後まで完了してから ack を落とす(バストランザクションを途中で壊さない)。
- **リセットの非同期性**: TCKドメインのリセットは「非同期アサート・TCK同期デアサート」、DMドメインは「非同期アサート・システムクロック同期デアサート」。
  片方のドメインだけがリセットされても、上記ハンドシェイク規則により相手側がハングしない。
- 同期化FFには `(* ASYNC_REG = "TRUE" *)` を付け、Vivado 制約で TCK とシステムクロックを `set_clock_groups -asynchronous` とする。
- `idle` ヒント: システムクロックが十分速い場合、Update-DR から Capture-DR までに Run-Test/Idle が
  1サイクルあれば ack が TCK 側に届くので `1` とする。これはヒントにすぎず、正しさは busy 応答と
  デバッガの再試行で保証する(OpenOCD は busy を受けると idle を自動的に増やす)。

### 3.6 cJTAG (IEEE 1149.7 OScan1)

**方針**: TCK をゲートで作らない。TAP は物理ピン TCKC で直接クロックし、クロックイネーブルで OScan1 の3相のうち1相だけ動かす。
システムクロックは一切使わない(任意のクロック比の要件を満たすため)。

| 項目 | 仕様 |
|---|---|
| モード選択 | `cjtag_en` 入力(0: JTAG、1: cJTAG)。TCKC ドメインへ2段同期、変化時は cJTAG 状態と TAP をリセット |
| 兼用ピン | TCK ⇔ TCKC、TMS ⇔ TMSC(双方向)。cJTAG時は TDI 不使用、TDO はHi-Z |
| エスケープ検出 | TCKC=High の間の TMSC 立ち上がり回数 r で判定: r≥4 リセット(オフライン+TAPリセット)、r=3 選択(活性化待ち)、r=2 選択解除(オフライン)、r≤1 無視 |
| エスケープ計数の実装 | TMSC 立ち上がりでクロックされる **グレイコード計数器**(TCKC=High のときのみ+1)。TCKC 立ち上がり/立ち下がりでスナップショットを取り、次の TCKC 立ち上がりで差分を評価。値が1bitずつしか変わらないので、通常動作で TMSC と TCKC のエッジが重なりメタステーブルになっても誤差は±1に収まり、エスケープ(r≥2)と誤判定しない |
| 活性化 | 選択エスケープ直後の TCKC 立ち上がり12回で OAC,EC,CP を LSB 先頭で受信。`0x08C`(OAC=1100, EC=1000, CP=0000)で OScan1 動作、不一致ならオフライン |
| OScan1 | 3相/TAPサイクル: 相0 TMSC=nTDI、相1 TMSC=TMS(いずれも TCKC 立ち上がりで取り込み)、相2 でターゲットが TDO を出力し、その TCKC 立ち上がりで TAP を1ステップ進める |
| TMSC 出力 | 相2の TCKC=Low の期間のみ駆動し、TCKC 立ち上がりで開放(開放後の値はピンのキーパが保持) |
| オフライン時 | TAP を Test-Logic-Reset に保持 |
| OpenOCD | `ftdi oscan1_mode on`(riscv-openocd 928f2b374 の `cjtag_reset_online_activate` シーケンス: リセットエスケープ8エッジ → 3パルス → 選択エスケープ6エッジ → OAC/EC/CP)と互換 |

---

## 4. Debug Module (3章、3.14)

### 4.1 基本パラメータ

| 項目 | 値 | 根拠 |
|---|---|---|
| dmstatus.version | 3 (1.0) | |
| ハート数 | **1**(hartsel=0 のみ存在) | 【提案】 |
| HARTSELLEN | 1bit 実装(hartsel=1 は nonexistent) | OpenOCDのハート数検出用 |
| hasel / hart array mask | 未実装(hasel=0固定) | |
| datacount | **4** | RV64 の Access Memory に arg0(64bit)+arg1(64bit) = data0..3 が必要(表2) |
| progbufsize / impebreak | 0 / 0 | Program Buffer 無し |
| abstractauto | 実装(autoexecdata[3:0]) | OpenOCDの連続メモリアクセス高速化 |
| confstrptr | 未実装(confstrptrvalid=0、0読み出し) | |
| nextdm | 0 | |
| hartinfo | 0(未実装) | Program Buffer 無しのため不要 |
| haltsum0 | 実装 | |
| authdata / authenticated | 実装(4.7) | |
| hasresethaltreq | 1(setresethaltreq/clrresethaltreq実装) | OpenOCD の `reset halt` 用 |
| hartreset | 実装(疑似ハートのみリセット) | |
| ndmreset | 実装(出力ポートとしてシステムへ出す、6.2) | |
| keepalive / ackunavail / stickyunavail | 未実装(0) | |
| relaxedpriv | 0 固定 | |

### 4.2 リセットの考え方(3.2, 3.14.2)

- **DM のリセットは電源投入リセットと dmactive のみ**。システムリセット(ndmreset や外部リセットボタン)では DM をリセットしない(仕様「dmactive以外にDMをリセットする機構を持つべきでない」)。
  このため CPU_TOP に**デバッグ論理専用の電源投入リセット入力**を追加する(6.2)。
- ndmreset=1 の間、CPU_TOP は `ndmreset` 出力を立て、FPGAトップは周辺・メモリ・CPU本体(将来)をリセットする。
  `dmstatus.ndmresetpending` を実装する。
- 疑似ハートは、ndmreset・hartreset・システムリセットでリセットされ、havereset がセットされる(ackhavereset でクリア)。
  resethaltreq が立っていれば、リセット解除後に halted(cause=5)へ遷移する。

### 4.3 Abstract Command

| cmdtype | 対応 |
|---|---|
| 0 Access Register | 対応(4.4) |
| 1 Quick Access | cmderr=2 |
| 2 Access Memory | 対応(4.5) |
| その他 | cmderr=2 |

共通規則: busy中の command/abstractcs/abstractauto/data書き込み → cmderr=1(cmderr=0 のときのみ)。cmderr≠0 の間は新しいコマンドを開始しない。

### 4.4 Access Register(暫定)

| 条件 | 結果 |
|---|---|
| ハートが running | cmderr=4 (halt/resume) |
| postexec=1 | cmderr=2 |
| aarsize が 2(32bit) / 3(64bit) 以外 | cmderr=2 |
| aarsize がレジスタ幅を超える(32bit CSR に 64bit 等) | **エラーにしない**(上位は0読み出し)。OpenOCD は examine 時にレジスタ幅不明のまま XLEN 幅で dcsr 等を読み、cmderr=2 を受けると CSR の abstract アクセス全体を無効化するため |
| 存在しない regno | **cmderr=3 (exception)**(3.7.1.1 の必須規定) |
| transfer=0 | 何もしない(postincrement のみ反映) |
| aarpostincrement | 対応 |

疑似ハートのレジスタ(読み書き可、値を保持するだけ):

| 番号 | レジスタ | 備考 |
|---|---|---|
| `0x1000` | x0 | 読み出し0、書き込み無視 |
| `0x1001`–`0x101f` | x1–x31 | 64bit |
| `0x1020`–`0x103f` | f0–f31 | 64bit(misa に F/D を立てるため) |
| `0x0001`–`0x0003` | fflags / frm / fcsr | fcsr の別名関係を実装 |
| `0x0300` | mstatus | WARL: SD/FS/MPP 等の書き込み可能ビットのみ保持 |
| `0x0301` | misa | `0x800000000014112d` (RV64 IMAFDCSU) |
| `0x0302`,`0x0303` | medeleg / mideleg | |
| `0x0304`,`0x0344` | mie / mip | |
| `0x0305` | mtvec | |
| `0x0306` | mcounteren | |
| `0x0340`–`0x0343` | mscratch / mepc / mcause / mtval | |
| `0x0100`,`0x0105`,`0x0140`–`0x0143`,`0x0180` | sstatus(mstatusの別名) / stvec / sscratch / sepc / scause / stval / satp | |
| `0x0F11`–`0x0F15` | mvendorid / marchid / mimpl / mhartid / mconfigptr | 読み出し専用。0 / 0x6d6d3032 / 0x00000001 / 0 / 0 |
| `0x07B0` | dcsr | debugver=4、prv(WARL: 0/1/3)、step、ebreakm/s/u、cause(RO) |
| `0x07B1` | dpc | |
| `0x07B2`,`0x07B3` | dscratch0 / dscratch1 | |
| `0x07A0`–`0x07A5` | tselect 等 | **未実装: cmderr=3**(OpenOCDはトリガ0個と判断する) |
| 上記以外 | | cmderr=3 |

### 4.5 Access Memory

- aamvirtual=0 のみ(1 は cmderr=2)。aamsize 0–3(8/16/32/64bit)、4 は cmderr=2。aampostincrement 対応。
- **ハートが running でも実行可能**(本物のCPUでも同じバス経路を使う想定)。
- バスエラー(SLVERR/DECERR)・タイムアウト・アドレス非整列・40bitを超えるアドレス → cmderr=5 (bus)。

### 4.6 System Bus Access (3.10, 3.14.22–30)

| 項目 | 値 |
|---|---|
| sbversion | 1 |
| sbasize | **40**(CPUの物理アドレス幅) → sbaddress0/1 を実装 |
| sbaccess8/16/32/64 | 1 / 1 / 1 / 1(128 は 0) |
| sbdata0/1 | 実装(64bitアクセス用) |
| sbreadonaddr / sbreadondata / sbautoincrement | 実装 |
| sbbusyerror / sbbusy | 実装 |
| sberror | 1: タイムアウト/バスリセット、2: DECERR、7: SLVERR、4: 未対応サイズ、3: アドレスがアクセスサイズに整列していない |
| タイムアウト | パラメータ(既定 システムクロック 2^20 サイクル) |

### 4.7 認証 (3.12)

| 入力 | 内容 |
|---|---|
| `dbg_auth_en` | 1: 認証必要、0: 認証不要(authenticated=1)。システムクロックへ2段同期 |
| `dbg_auth_key[31:0]` | 鍵。authdata への書き込み値が一致すれば authenticated=1 |

- 未認証の間: DMレジスタはすべて0読み出し・書き込み無視。例外は dmstatus の authenticated/authbusy/version、dmcontrol.dmactive、authdata(3.12の必須例外)。
  halt要求・ndmreset・SBA 等、DM外部への作用は一切行わない。
- dmactive=0 で authenticated は0に戻る(再認証が必要)。authbusy は常に0。
- authdata の読み出しは 0。
- OpenOCD からは `riscv authdata_write 0xbeefcafe`(mmRISC-1 と同じ)で認証する。

---

## 5. SBA/Access Memory のバスマスタと振り分け

### 5.1 アドレスによるバス選択【提案】

CPU本体でも同じ規則を使う前提で、CPU_TOP のパラメータとする。

| アドレス(40bit) | 行き先 |
|---|---|
| `0x00_8000_0000` 以上 | メモリバス(AXI4) |
| `0x00_0000_0000` – `0x00_7FFF_FFFF` | 周辺バス(AXI4-Lite) |

LiteX の配置(main_ram=`0x8000_0000`、ROM/SRAM/CSR=`0x1000_0000`〜`0x1200_0000`)と一致する。
CLINT(`0x0200_0000`)/PLIC(`0x0C00_0000`)はCPU内蔵予定だが、本フェーズでは未実装のため周辺バスへ出る。

### 5.2 AXI上の表現(これまでに検証した経路をそのまま使う)

| バス | 8/16/32bit アクセス | 64bit アクセス |
|---|---|---|
| メモリバス AXI4 | **AxSIZE=0/1/2 の狭幅単発転送**(WSTRB はアドレスから生成) | AxSIZE=3 |
| 周辺バス AXI4-Lite | WSTRB でレーン指定、読み出しは該当レーンを切り出し | WSTRB=0xFF |

- AXI ID は BFM(ID=0)と区別するため **ID=1** を使う。
- 64bit データ上のレーン位置はアドレス下位3bitで決まる(リトルエンディアン)。

### 5.3 BUS_ARB

- マスタ: CPU_BFM(シミュレーション用)、DBG_BUSMST。将来は CPU本体が加わる。
- **トランザクション単位のロック**(AW/AR を受理してから B/最終R 完了まで切り替えない)付き固定優先度(デバッグ優先)。
  メモリバス・周辺バスそれぞれ、読み出し系と書き込み系で独立に調停。

---

## 6. CPU_TOP への組み込み

### 6.1 インスタンス

`CPU_TOP` 内に `CPU_DBG`、`BUS_ARB` を追加。既存の `CPU_BFM` は BUS_ARB の片側マスタとして残す(FPGAでは何もしない)。

### 6.2 追加ポート【提案】

| ポート | 方向 | 内容 |
|---|---|---|
| `rst_dbg_n` | in | **デバッグ論理用の電源投入リセット**(4.2)。システムリセット `rst_n` とは別 |
| `ndmreset` | out | DM からのシステムリセット要求。FPGAトップで周辺・メモリのリセットに使う |
| `jtag_tck` | in | TCK(JTAG) / TCKC(cJTAG) |
| `jtag_tms_i` | in | TMS(JTAG) / TMSC 入力(cJTAG)。既存 `jtag_tms` を改名 |
| `jtag_tms_o` / `jtag_tms_oe` | out | TMSC 出力とイネーブル(cJTAG) |
| `jtag_tdi` | in | TDI |
| `jtag_tdo` / `jtag_tdo_oe` | out | TDO とイネーブル |
| `jtag_trst_n` | in | TRST |
| `cjtag_en` | in | 0: JTAG、1: cJTAG |
| `cjtag_online` | out | cJTAG が OScan1 動作中(LED表示用) |
| `dbg_auth_en` | in | 認証の有効/無効(4.7) |
| `dbg_auth_key[31:0]` | in | 認証の鍵(4.7) |
| `dbg_halted` / `dbg_running` / `dbg_dmactive` | out | 状態表示用(LED、暫定) |

CPU の識別値(IDCODE、mvendorid、marchid、mimpl、misa、mhartid)は CPU_TOP のパラメータとし、既定値は本仕様の決定値とする。

---

## 7. FPGAトップ (`RTL/TOP/TOP.sv`、Arty A7-100T)

### 7.1 構成

```
 clk100 (E3) ─▶ MMCM ─▶ sys_clk (既定50MHz, パラメータ)
 cpu_reset_n (C2) ─┐
 MMCM locked ──────┼─▶ POR生成 ─▶ rst_dbg_n (DM用: POR のみ)
 ndmreset ─────────┘            └─▶ rst_n    (システム: POR | ボタン | ndmreset)

 CPU_TOP ─ AXI4 ─▶ AXI4_ADDR_NARROW ─▶ AXI4_RAM   64KiB  @ 0x8000_0000 (BRAM)
         ─ AXI-L ▶ AXIL_ADDR_NARROW ─▶ AXIL_RAM    4KiB  @ 0x1200_0000 (BRAM/分散RAM)
 JTAG pins (PMOD) ─▶ CPU_TOP
 LED ◀─ dbg_halted / dbg_running / dmactive / ハートビート
```

- 上位ビット `[39:32]≠0` は既存の ADDR_NARROW で DECERR(OpenOCD から sberror=2 を確認できる)。
- RAM 範囲外(32bitアドレス内)も DECERR を返す(未使用領域アクセスの確認用)。
- メモリは合成可能な新規モジュール `RTL/BUS/AXI4_RAM`、`RTL/BUS/AXIL_RAM` とする(シミュレーション用モデルは合成不可のため)。

### 7.2 ピン割当(決定)

FT2232H(Dual RS232)を PMOD JA に直接接続(JTAG)、または外部の cJTAG 変換アダプタを PMOD JA に接続(cJTAG)。

| 信号 (JTAG / cJTAG) | PMOD JA | FPGAピン | 備考 |
|---|---|---|---|
| TCK / TCKC | JA1 | G13 | クロック入力、プルアップ |
| TDI / – | JA2 | B11 | プルアップ |
| TDO / – | JA3 | A11 | トライステート出力、プルアップ |
| TMS / TMSC | JA4 | D12 | 双方向、**プルアップなし**(KEEPER) |
| GND | JA5 | – | |
| VCC 3.3V | JA6 | – | |
| nTRST | JA7 | D13 | プルアップ |
| nSRST | JA8 | B18 | プルアップ、システムリセット入力 |

| ボード部品 | 用途 |
|---|---|
| SW3 (A10) | 下: JTAG、上: cJTAG |
| SW2 (C10) | 下: 認証無効、上: 認証有効(鍵 `0xbeefcafe`) |
| RESET ボタン (C2) | システムリセット(DM はリセットしない) |
| LD4 (H5) | ハート halted |
| LD5 (J5) | ハート running |
| LD6 (T9) | dmactive |
| LD7 (T10) | cJTAG オンライン(JTAGモード時は sys_clk ハートビート) |

- TCK/TCKC と TMSC は汎用I/Oピンからクロックとして使うため `CLOCK_DEDICATED_ROUTE FALSE` を付け、`create_clock` で定義し、
  システムクロックと互いに `set_clock_groups -asynchronous` とする。
- ビルド用ファイル(XDC、Vivado TCL、Windows用バッチ)は `FPGA/ARTY_A7_100T/` に置く。

### 7.3 ビルド

LitexRocket と同様に、Linux側で Vivado 用 TCL・XDC を生成し、Windows側 Vivado 2025.1 で合成する。

---

## 8. 検証計画

| ディレクトリ | 内容 |
|---|---|
| `SIM/SIM_CPU` | 既存テスト(BUS_ARB 追加後の回帰) |
| `SIM/SIM_DBG` | デバッグ論理の機能検証(新設) |

`SIM/SIM_DBG` の検証項目:

1. **JTAG BFM による TAP/IR/DR** : IDCODE、BYPASS、未実装IR、TLR/TRST
2. **dtmcs / dmi** : op の成功/busy/sticky、dmireset、dtmhardreset、errinfo
3. **CDC 耐性**: TCK周期とシステムクロック周期の比を広く振る(例: TCK/sys = 1/50 〜 50)、
   位相をランダム化、TCKを長時間停止、ジッタ付きTCK。すべてで DMI 読み書き結果が正しいこと、busy が正しく返り再試行で成功すること
4. **中断耐性**: DMI実行中の dtmhardreset / TRST / TLR、実行中の dmactive=0、片側ドメインのみのリセット
5. **DMレジスタ**: dmactive、dmstatus各ビット、hartsel存在判定、haltreq/resumereq/step/hartreset/ndmreset/resethaltreq/ackhavereset
6. **Abstract Command**: Access Register(全GPR/FPR/CSR、存在しない番号で cmderr=3、running で cmderr=4、aarsize不正で cmderr=2)、
   postincrement、abstractauto、busy中書き込みで cmderr=1
7. **SBA / Access Memory**: 8/16/32/64bit × メモリバス/周辺バス、autoincrement、readonaddr/readondata、
   DECERR/タイムアウト、sbbusyerror、BFM との同時アクセス(BUS_ARB)
8. **認証**: 未認証時のレジスタ読み出し0・書き込み無視・例外レジスタ、誤った鍵、正しい鍵、dmactive=0 による再ロック
9. **cJTAG**: OpenOCD と同じ活性化シーケンス、OScan1 での上記 1〜7 の主要項目、動作中のエスケープ(リセット/選択解除)と再活性化、
   TMSC の変化を TCKC 立ち下がりと同時刻にした最悪タイミング、JTAG⇔cJTAG のモード切り替え
10. **OpenOCD 実機連携シミュレーション**: Verilator + OpenOCD `remote_bitbang` ドライバで、
   **実物の OpenOCD をRTLシミュレーションに接続**し、`init`→`halt`→`reg`→`mdw/mww`→`resume`→`reset halt` を実行
   (FPGAに載せる前に OpenOCD との相性を確認する)
11. **意図的バグ注入**による検証の有効性確認(これまでと同様)

FPGA確認(Arty A7-100T): OpenOCD から上記8と同じ操作、および `load_image`/`verify_image` によるメモリ書き込み・照合。

---

## 9. 決定事項

| # | 項目 | 決定 |
|---|---|---|
| 1 | IDCODE / mvendorid / marchid / mimpl / mhartid | `0x26d6d001` / 0 / `0x6d6d3032`("mm02") / `0x00000001` / 0 |
| 2 | JTAG アダプタ | FT2232H(Dual RS232)を PMOD JA に接続 |
| 3 | cJTAG | JTAGと同時に実装、SW3 で切替、PMOD JA の TCK/TMS を TCKC/TMSC に兼用、変換は外部アダプタ |
| 4 | 認証 | 実装。有効/無効と鍵は CPU_TOP 外部入力。FPGA では SW2 で切替、鍵 `0xbeefcafe` |
| 5 | misa | `0x800000000014112d`(RV64 IMAFDC + S/U) |
| 6 | バス選択規則 | `0x8000_0000` 以上をメモリバス |
| 7 | FPGA のシステムクロック | MMCMで 50MHz(パラメータで変更可) |
| 8 | ディレクトリ | `RTL/CPU/CPU_DBG`、FPGAビルド用は `FPGA/ARTY_A7_100T` |

---

## 10. 実装結果(Rev-2 追記)

### 10.1 ファイル

| 種別 | ファイル |
|---|---|
| デバッグ論理 | `RTL/CPU/CPU_DBG/{DBG_CDC,DBG_CJTAG,DBG_DTM,DBG_DM,DBG_HART_STUB,DBG_BUSMST,CPU_DBG}/*.sv` |
| バス | `RTL/BUS/BUS_ARB/BUS_ARB.sv`、`RTL/BUS/AXI4_RAM/AXI4_RAM.sv`、`RTL/BUS/AXIL_RAM/AXIL_RAM.sv` |
| CPU | `RTL/CPU/CPU_TOP/CPU_TOP.sv`(ポート追加、パラメータ `USE_BFM`) |
| FPGAトップ | `RTL/TOP/TOP.sv`(`SIM=1` で MMCM をバイパス) |
| FPGAビルド | `FPGA/ARTY_A7_100T/{TOP.xdc,build.tcl,build.bat,README.md,openocd/*.cfg}` |
| 検証 | `SIM/SIM_DBG`(機能検証)、`SIM/SIM_OCD`(OpenOCD 連携)、`SIM/SIM_CPU`(回帰) |

### 10.2 実装上の決定・変更点

- **CDC(DBG_CDC)**:
  - ハンドシェイク状態はデバッグPORでのみリセットする。TRST/TLR/dtmhardreset は未送出の要求だけを取り消し、送出済みの要求は完了させる。これにより、中断後に古い応答を新しい要求の応答と取り違えることが原理的に起きない。
  - Capture-DR は、その TCK エッジで完了した応答を直接取り込む。これで idle=1 を満たす。
- **TCK ドメインのリセット**: TCK は電源投入時に動いていないため、リセット同期化器の FF に初期値 0(FPGA の INIT)を与え、リセットエッジなしでもリセット状態から始まるようにした。cJTAG エスケープ計数器も同様に初期値を与えた(計数の差分しか使わないので値そのものは任意)。
- **DM の in-flight 管理**: ハートのレジスタアクセスとバスマスタへの要求は、dmactive=0 でも消えない in-flight フラグで追跡する。ハートやバスがリセットされたら、その要求はエラーで完了させる(cmderr=4/5、sberror=1)。
- **DBG_BUSMST のタイムアウト**: タイムアウト時点で sberror=1(cmderr=5)を返す。AXI トランザクション自体は裏で完了を待ち(drain)、その間に来た新しい要求は即座にエラーを返す。
- **ハート stub のリセット**: `rst_n | ndmreset | hartreset` を 2FF で同期化した同期リセットとし、DM からの状態観測を同一クロックで行う。
- **ADDR_NARROW ブリッジの修正**:
  - 旧実装は W を AW ハンドシェイク完了まで保持していたため、AW と W の両方を待つスレーブ(新規 AXIL_RAM)とデッドロックした。これは AXI の規則「マスタは READY を待って VALID を出してはならない」に反する。
  - 修正後は、アドレスがデコード済み(範囲内)の AWVALID が出ている間に W も転送する。W が先に完了する場合に備え、状態 W_PASS_AW を追加した。
  - DECERR 時に W がスレーブへ漏れない性質は維持している。SIM_CPU の回帰は PASS。
- **モジュール名 TOP**: Verilator は内部のルートスコープ名に `TOP` を使うため、`TOP` をトップモジュールとして直接 lint/シミュレーションできない。テストベンチの下にインスタンス化すれば問題ない。
- **Verilator 5.020 / Icarus 12 の制約への対処**:
  - ループを含む関数のインライン展開で内部エラーが出るため、グレイコード変換をマクロにした。
  - Icarus は enum の三項演算に cast を要求するため、TAP 状態は localparam にした。
  - テストベンチでは break と配列リテラルを使わない。

### 10.3 検証結果

| 検証 | 結果 |
|---|---|
| `SIM/SIM_DBG` Verilator (`make`) | PASS 3010 checks(約40秒) |
| `SIM/SIM_DBG` Icarus (`make iverilog`) | PASS 3030 checks(約1分) |
| `SIM/SIM_DBG` バグ注入 (`make bug`) | 15 種すべて検出 |
| `SIM/SIM_OCD` OpenOCD 連携 (`make`、`make auth`) | PASS / PASS |
| `SIM/SIM_CPU` 回帰(ブリッジ修正後) | Verilator PASS 47351 / Icarus PASS 45815 |

**SIM_DBG** の 14 項目:
1. TAP / IR / IDCODE / BYPASS / TRST
2. dtmcs
3. DM レジスタ
4. DMI busy / sticky / dmireset
5. CDC スイープ:
   - TCK周期/システムクロック周期 = 0.02, 0.05, 0.13, 0.333, 0.5, 0.97, 1.0, 1.03, 2.9, 7.3, 20, 50。一部はジッタ ±40%。
   - 1/400 と 1000。
   - ランダム位相、TCK 停止。
6. dtmhardreset / TRST / TLR による要求中断、システムリセットで DM が保持されること
7. ラン制御: halt / resume / step / ndmreset / resethaltreq / hartreset
8. Access Register: GPR/FPR/CSR、WARL、cmderr 2/3/4、postincrement、autoexec
9. Access Memory: 両バス × 8/16/32/64bit、ブロック書き込み、各種エラー
10. SBA: 両バス × 8/16/32/64bit、autoincrement、readonaddr/readondata
11. バスエラー:
    - DECERR。上位アドレスへの書き込みが RAM に化けないこと。
    - 非整列アドレス、sbaccess、sbbusyerror、busy 中の cmderr=1。
    - タイムアウトとその後の復帰、ndmreset による中断。
12. CPU_BFM とデバッグバスマスタの同時アクセス
13. 認証
14. cJTAG:
    - 活性化、OScan1 アクセス、比スイープ、TMSC 最悪エッジ。
    - 選択解除 / リセットエスケープ、誤った活性化コード、JTAG への復帰、TMSC 競合なし。

**バグ注入**で検出を確認した不具合:
- CDC:
  - ack の立ち下がりを待たずに req を上げる
  - 保留中の要求を busy と報告しない
  - 応答を1ハンドシェイク遅れて取り込む
- DTM:
  - Capture-DR で busy を無視する
  - dmireset が sticky op を消さない
- DM:
  - data 読み出しで autoexec しない
  - 認証をバイパスする
  - sbautoincrement のサイズを誤る
- BUSMST:
  - WSTRB をレーンへシフトしない
  - タイムアウトしない
- HART: step で dpc が進まない
- cJTAG:
  - TCKC=High 中に TMSC を駆動する
  - 選択解除エスケープを無視する
- ブリッジ: 旧実装の W 保持(AXIL_RAM とのデッドロック)
- BUS_ARB: 書き込みグラントを早く解放する

注: ブリッジの「DECERR 書き込みの W が RAM に漏れる」不具合は、この系では観測できない。本系の RAM は、対応する AW を受け付けない限り W を受け付けないため。

**OpenOCD 連携** (riscv-openocd 0.12.0+dev-03026-g928f2b374、remote_bitbang):
- examine で XLEN=64、misa=0x800000000014112d を認識した。
- 以下がすべて期待どおりに動作した:
  - halt、reg(a0, s11, ft0, misa, marchid, pc)
  - mww/mwd/mwh/mwb と read_memory(両バス)、256 ワードのブロック転送、load_image / verify_image 4KiB
  - step(pc+4)、resume、reset halt(pc=0x80000000、RAM 保持)
- 認証ありでは、未認証エラーの後に `riscv authdata_write 0xbeefcafe` で再 examine に成功した。
- OpenOCD は progbufsize=0 のため「Unable to insert program into progbuf」を数回ログに出すが、Abstract Command / SBA へフォールバックして動作する。

### 10.4 シミュレーション専用の仕組み

- `AXI4_RAM` / `AXIL_RAM` の `sim_stall`(`ifndef SYNTHESIS`): テストベンチから AWREADY/ARREADY を止め、busy やタイムアウトを作る。
  - Verilator では force/release した net に release 後も値が残る場合があるため、force を使わずこの方式にした。
- `CPU_TOP` の `USE_BFM`: シミュレーションでは 1(CPU_BFM を同時アクセス試験に使う)。FPGA では 0。

### 10.5 FPGA 確認結果(Arty A7-100T、2026-09-17)

**Vivado 2025.1**
- タイミング: WNS +8.382ns、WHS +0.038ns、全制約を満たす。
- CRITICAL WARNING: 0。
- 残る警告は想定内のもののみ(`FPGA/ARTY_A7_100T/README.md`)。

**OpenOCD の設定**
- riscv-openocd 0.12.0+dev-03026-g928f2b374、FT2232H を使用。
- `riscv set_enable_virt2phys off`(MMU 実装まで)。

| 項目 | JTAG | cJTAG |
|---|---|---|
| IDCODE 検出、examine(XLEN=64、misa) | OK | OK |
| 周辺バス / メモリバスの読み書き(mww/mwd/mdw/mdd) | OK | OK |
| halt / resume / step(pc+4) | OK | OK |
| reg 読み書き(a0、misa、pc) | OK | OK |
| reset halt(pc=0x80000000、RAM 内容保持) | OK | OK |
| OpenOCD 再起動時の再オンライン化・アクティベート化 | − | OK |
| 認証(SW2 上) | OK | OK |

認証の詳細:
- 起動時は未認証(dmstatus=0x3)。
- cfg の `authdata_write 0xbeefcafe` で認証され、再 examine に成功する。
- 誤った鍵を書くと未認証に戻り、正しい鍵を書き直すと再認証されてアクセスが戻る。
- cfg で鍵を書かずに起動した場合、`mdd` は "Target not examined yet" で拒否される。正しい鍵を書くとアクセスできる。

OpenOCD が出す `Unable to insert program into progbuf` は無害(progbufsize=0 のため)。
- examine 時の2回。
- 最初の resume / step のトリガ列挙時(tselect が cmderr=3)。

### 10.6 FPGA 確認手順

`FPGA/ARTY_A7_100T/README.md` を参照(Windows 側 `build.bat` → Hardware Manager → OpenOCD)。
