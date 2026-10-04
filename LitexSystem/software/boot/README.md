# SD カード

## 置くもの

カードは 2 つのパーティションに分ける。

| パーティション | 形式 | ラベル | 中身 |
|---|---|---|---|
| 1 | FAT16、512 MB | `LITEXBOOT` | 下の 3 つのファイル(ルートに置く) |
| 2 | ext4、残り全部 | `rootfs` | ルートファイルシステム |

第 1 パーティションに置く 3 つは、すべてこのディレクトリ(`software/boot/`)にある。

| ファイル | 出どころ | ロード先 | md5(2026-10-04) |
|---|---|---|---|
| `fw_jump.bin` | `scripts/build_opensbi.sh` がここに作る(デバイスツリー入り) | 0x8000_0000 | `28461f3da61988ac2ee6e61d7ddf1570` |
| `Image` | Linux カーネル。Rocket 構成で作ったものと同じ設定に、性能カウンタ(`perf`)のための `CONFIG_PERF_EVENTS` / `CONFIG_RISCV_PMU_SBI` を足して作り直したもの(2026-10、`CPU_CORE_SPEC.md` 決定 69) | 0x8020_0000 | `1d886448db1ae0b8e1629cfeba6b605b` |
| `boot.json` | BIOS が読む配置表。Rocket 構成と同じ | ― | `a1c356008baa859fa615b879d0fa18f3` |

3 つとも git で管理しているので、リポジトリを取ってくればそのままカードを作れる
(出どころとライセンスは下の「配布しているバイナリ」)。デバイスツリーを変えて
`scripts/build_opensbi.sh` を実行し直したら、新しい `fw_jump.bin` もコミットする
(ビットストリームと組で使うものなので、ずれると何も表示されない)。

第 2 パーティションは Rocket 構成の BusyBox 一式(`~/mmlitex_build/initramfs`)に、
このリポジトリの `software/rootfs/`(inittab、`sbin/init`、udhcpc のスクリプト、
負荷試験 `stress.sh`)を重ねたもの。`scripts/sd_rootfs.sh` が書く。

## 配布しているバイナリ

| ファイル | ソース | 作り方 | ライセンス |
|---|---|---|---|
| `Image` | Linux、[litex-hub/linux](https://github.com/litex-hub/linux) の commit `4929f78c004ecab9b68bb41018a3d11749dcea62`(7.2.0-rc2 ベース)。手は入れていない | この `Image` を作ったときの `.config` が同じディレクトリの `linux.config`(Rocket 構成の設定に `CONFIG_PERF_EVENTS`、`CONFIG_RISCV_PMU`、`CONFIG_RISCV_PMU_SBI` を足しただけ)。それを `.config` に置いて `make ARCH=riscv CROSS_COMPILE=riscv64-unknown-linux-gnu- Image`。コンパイラは riscv64-unknown-linux-gnu-gcc 13.2.0 | GPL-2.0(ソースは上の URL と commit から入手できる) |
| `fw_jump.bin` | OpenSBI、[riscv-software-src/opensbi](https://github.com/riscv-software-src/opensbi) の commit `3593a5facc4c6938b90429a6973ba9ee21fc5899`(v1.9 系)。ソースには手を入れず、`opensbi_patches/` のパッチ(2026-10: `0001` 止まっているカウンタも RESET 付きの停止で解放する。これが無いと Linux の `perf` がカウンタを使い切る)をビルド用の写しに当てる | `scripts/build_opensbi.sh`(パッチを当て、`PLATFORM=generic`、デバイスツリー `../mmrisc_arty.dts` を `FW_FDT_PATH` で埋め込む) | BSD-2-Clause(`COPYING.OpenSBI.BSD`) |
| `boot.json` | このリポジトリ | ― | このリポジトリと同じ |

カーネルのバージョン文字列に付いている `-dirty` は、作業ツリーに大文字小文字だけが違う
名前のファイル(netfilter の `xt_*.h` など 13 個)が無いためで、コードの変更ではない
(大文字小文字を区別しない場所を経由してコピーしたときに起きる)。

## 書き込み手順(Parallels Desktop 上の Ubuntu)

Parallels Desktop 上の Ubuntu では、カードを挿したときに自動でマウントされることも
されないこともある。また USB のカードリーダが途中で切れて付き直すことがあり、書き込み中に
切れるとファイルシステムが壊れる(`docs/BRINGUP.md` の 10 回目)。そこで、毎回
**全部アンマウント → マウント → 書き込み → sync → アンマウント → 切り離し**
の順で、すべて `udisksctl` で行う。`udisksctl` はデスクトップの自動マウントと同じ仕組みで、
マウント先のディレクトリ(`/media/<user>/<ラベル>`)も作り、消してくれる。

以下、リポジトリの一番上で実行する。

**0. カードのデバイス名を確かめる。** カードリーダが VM につながっていなければ、
Parallels のメニュー(デバイス → USB)で Ubuntu に接続する。

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
```

28.8G などカードの大きさで、`LITEXBOOT` と `rootfs` のパーティションを持つものが
カード。以下は `/dev/sdb` として書く(**違っていたら読み替える**。付き直すと名前が
変わることがある)。

**1. 全部アンマウントする。** マウントされていなければ `is not mounted` と出るだけで
害は無い。`lsblk` の `MOUNTPOINT` が空になったのを確かめる。

```bash
udisksctl unmount -b /dev/sdb1
udisksctl unmount -b /dev/sdb2
lsblk -o NAME,MOUNTPOINT /dev/sdb
```

**2. マウントする。** `Mounted /dev/sdb1 at /media/<user>/LITEXBOOT` のように、
マウント先が表示される。

```bash
udisksctl mount -b /dev/sdb1
udisksctl mount -b /dev/sdb2
```

**3. 書く。** 第 1 パーティションは自分の持ち物としてマウントされるので `sudo` は
要らない。第 2 パーティションは root の持ち物にするため `sudo` で書く。

```bash
cp LitexSystem/software/boot/fw_jump.bin LitexSystem/software/boot/Image \
   LitexSystem/software/boot/boot.json /media/$USER/LITEXBOOT/
sudo LitexSystem/scripts/sd_rootfs.sh /media/$USER/rootfs
```

`sd_rootfs.sh` は、カードに BusyBox がまだ無ければ一式を、あれば差分だけを書く
(カードの上で作ったファイルは残る)。一式を書き直すなら `--full` を付ける。

**4. 書き出す。**

```bash
sync
```

**5. アンマウントして切り離す。** `power-off` は書き込みをすべて確定させてから
カードを切り離す。これが終わってからカードを抜く(または Parallels で USB を外す)。

```bash
udisksctl unmount -b /dev/sdb1
udisksctl unmount -b /dev/sdb2
udisksctl power-off -b /dev/sdb
```

## 新しいカードを作る

**カードの中身はすべて消える。** デバイス名(ここでは `/dev/sdb`)を `lsblk` で
必ず確かめ、PC のディスク(`sda`)を指定しないこと。

手順 0 と 1(全部アンマウント)のあとで:

```bash
printf 'label: dos\nstart=2048, size=512MiB, type=6\ntype=83\n' | sudo sfdisk /dev/sdb
lsblk -o NAME,SIZE /dev/sdb                  # sdb1 が 512M、sdb2 が残り
udisksctl unmount -b /dev/sdb1               # 作り直した直後に自動でマウントされていたら外す
udisksctl unmount -b /dev/sdb2
sudo mkfs.vfat -F 16 -n LITEXBOOT /dev/sdb1
sudo mkfs.ext4 -L rootfs /dev/sdb2
```

あとは上の手順 2〜5 と同じ(`sd_rootfs.sh` は空のパーティションに一式を書く)。

## うまくいかないとき

- `mount point does not exist`: `sudo mount` を使ったとき、マウント先のディレクトリが
  無い(アンマウントで消えている)。`udisksctl mount` を使う。
- `Input/output error`、またはカーネルのログ(`sudo dmesg | tail -30`)に
  `Synchronize Cache(10) failed` や `I/O error`: カードリーダが切れた。つなぎ直して
  手順 0 からやり直し、書く前にファイルシステムを検査する(手順 1 でアンマウントした
  状態で):
  ```bash
  sudo fsck.vfat -a /dev/sdb1
  sudo e2fsck -f /dev/sdb2
  ```
- カードに本当に書けたか確かめる(PC のキャッシュを通さず、カードから読む):
  ```bash
  dd if=/media/$USER/LITEXBOOT/fw_jump.bin iflag=direct bs=4096 status=none | md5sum
  ```
- ボード側で `Liftoff!` の後に何も出ない: 第 1 パーティションのファイルが壊れているか
  古い。`fw_jump.bin` はどの版も 279048 バイトで大きさでは区別できないので、md5 を
  上の表と比べる。

## 電源を切る前に

いきなり電源を切ると、次の起動で ext4 がジャーナルを再生する
(`EXT4-fs (mmcblk0p2): recovery complete`)。壊れはしないが、書いた直後のデータは
失われうる。切る前にボードで

```sh
poweroff
```

を実行し、`reboot: Power down` が出てから電源を切る(`reboot` なら LiteX のリセットで
再起動する)。inittab の `::shutdown:` の行が、書き出しと読み出し専用への再マウントを
行うので、次の起動で `recovery complete` は出ない(2026-09-29 に実機で確認)。

`poweroff` の最後の `sbi_srst_reset: type=0x0 reason=0x0 failed` は、このボードに電源を
切る仕組みが無い(OpenSBI の `Platform Shutdown Device: ---`)ため。書き出しは済んで
いるので、そのまま電源を切るか RESET を押してよい。`umount: devtmpfs busy -
remounted read-only` も無害(`/dev` はメモリ上のもので、使用中なので外せないだけ)。

## デバイスツリーは別ファイルではない

`fw_jump.bin` に**埋め込んである**(`FW_FDT_PATH`)。だから
`software/mmrisc_arty.dts` を触ったら、SD カードに DTB を置くのではなく
`scripts/build_opensbi.sh` を実行し直して `fw_jump.bin` を差し替える。

## 起動

シリアル 115200bps。`litex>` プロンプトで:

```
sdcardboot
```

LiteX BIOS → OpenSBI → Linux → BusyBox と進めば成功。
詰まったときの見どころは `docs/BRINGUP.md`。

## Ethernet(2026-09-26 から)

SoC は `--with-ethernet --eth-dhcp` で作っている(`scripts/build_soc.sh`)。
Ethernet を入れると CSR の配置と割り込み番号が変わるので、**ビットストリームと
`fw_jump.bin` は必ず組で使う**。Ethernet 入りのビットストリームに古い
`fw_jump.bin` を組み合わせると(逆も)、UART の場所が違うので何も表示されない。
Ethernet 無しの最後のビットストリームは `build/known_good_noeth/` に取ってある。

| | Ethernet 無し | Ethernet 入り |
|---|---|---|
| ethmac / ethphy の CSR | ― | 0x1200_1000 / 0x1200_1800 |
| SD カード | 0x1200_2000、PLIC 3 | 0x1200_3000、PLIC 4 |
| timer0 | 0x1200_3000 | 0x1200_4000 |
| UART | 0x1200_3800 | 0x1200_4800 |
| パケットバッファ | ― | 0x3000_0000(8 KiB、キャッシュしない) |
| Ethernet の割り込み | ― | PLIC 3 |

### Linux で IP をもらう

BusyBox の `udhcpc` は、インタフェースを起こすこともアドレスを設定することも自分では
せず、スクリプトに任せる。しかもこの BusyBox は既定のスクリプトの場所が空
(`CONFIG_UDHCPC_DEFAULT_SCRIPT=""`)なので、**`-s` でスクリプトを指定しないと何も
実行されない**(インタフェースは DOWN のままで `Network is down` になる)。そのスクリプト
(`software/rootfs/usr/share/udhcpc/default.script`)は、上の書き込み手順の
`sd_rootfs.sh` がカードに入れる。inittab も起動時に `udhcpc` を実行するので、普段は
何もしなくてよい。手で取り直すなら、ボードで:

```sh
udhcpc -i eth0 -s /usr/share/udhcpc/default.script
                        # "Setting IP address ..." と "Adding router ..." が出れば設定済み
ifconfig eth0
ping <ルータの IP>      # "... is alive!" (この BusyBox の ping は簡易版で -c などは無い)
```

起動時に自動で取るなら `/etc/inittab` の `--install -s` の行より後に次を足す
(`-b`: 取れなければ裏で待ち続ける):

```
::sysinit:/bin/busybox udhcpc -i eth0 -b -s /usr/share/udhcpc/default.script
```

2026-09-26 に実機で確認: `udhcpc` で 192.168.0.11 を取得し、ルータと LAN 上の PC に
`ping` が通った。

MAC アドレスは BIOS と同じ `10:e2:d5:00:00:00`(デバイスツリーの
`local-mac-address`)なので、BIOS と Linux は DHCP で同じ IP をもらう。

### LiteX BIOS の TFTP ネットブート

カーネルと OpenSBI を SD カードではなく PC の TFTP サーバから読み込む。SD カードの
入れ替え無しでカーネルや `fw_jump.bin` を試せる。ルートファイルシステムは今まで
どおり SD カード(`root=/dev/mmcblk0p2`)。自動の起動順は シリアル → SD カード →
ネットワーク なので、ネットブートは `litex>` プロンプトから手で行う。

**1. TFTP サーバ(PC 側、一度だけ)**。ボードと同じネットワークにいること。VM で
立てるなら、VM のネットワークはブリッジ接続にする(NAT だとボードから届かない)。
Mac の Parallels Desktop 上の Ubuntu に立てる場合の詳しい手順(ブリッジ設定、
`tftpd-hpa` の設定、ufw で UDP 69 を開ける、tcpdump での切り分け)は
`docs/TFTP_SERVER.md`。

```bash
sudo apt install tftpd-hpa          # 公開ディレクトリは /srv/tftp
sudo cp LitexSystem/software/boot/Image LitexSystem/software/boot/fw_jump.bin \
        LitexSystem/software/boot/boot.json /srv/tftp/   # SD カードの第 1 パーティションと同じもの
ip -4 addr                                # サーバの IP を控える
```

**2. ボード**。電源を入れて `Press Q or ESC to abort boot completely.` の間に
`Q` を押すと `litex>` になる。

```
litex> eth_dhcp                       <- "Local IP: 192.168.x.y" が出れば DHCP 成功
litex> ping <サーバの IP>              <- 応答が返れば経路は通っている
litex> eth_remote_ip <サーバの IP>     <- TFTP サーバ(既定は 192.168.1.100)
litex> netboot                        <- boot.json を読み、Image と fw_jump.bin を取って起動
```

`Copying Image to 0x80200000 ...` の後、SD カードからの起動と同じように OpenSBI と
Linux が出れば成功(2026-09-26 に実機で確認)。

`Booting from boot.json...` の直後に `Booting from boot.bin...` へ進んで
`Network boot failed.` になるのは、`boot.json` すら取れていないとき。TFTP サーバが
動いているか、ファイルが `TFTP_DIRECTORY` にあるか、**サーバ側のファイアウォールが
UDP 69 番を通しているか**(実機ではこれだった)を確かめる。

ダウンロードは終わるのに `Liftoff!` の後に何も出ないときは、読み込んだ中身を確かめる。
`fw_jump.bin` はどの版も 279048 バイトで大きさでは区別できないので、まずサーバで
`strings fw_jump.bin | grep serial@` が `serial@12004800` を示すか見る。それでも出ない
なら、BIOS が再起動しても壊さない番地へ読み込んで BIOS に戻る JSON をサーバに置き、

```json
{
    "fw_jump.bin": "0x81000000",
    "Image":       "0x81200000",
    "bootargs":    {"addr": "0x10000000"}
}
```

`netboot check.json` → `Q` → `crc 0x81000000 <大きさ>` と `crc 0x81200000 <大きさ>` を、
PC で計算した CRC32(`python3 -c "import zlib,sys;print(hex(zlib.crc32(open(sys.argv[1],'rb').read())))" fw_jump.bin`)
と比べる。

TFTP サーバの既定値を変えてビットストリームごと作り直すなら
`REMOTE_IP=192.168.x.y ./scripts/build_soc.sh`。

## 長時間の負荷試験(`software/rootfs/root/stress.sh`)

Linux 上で 3 つの作業を同時に何時間も回し、どれも自分のデータを md5 で照合する。

| 作業 | 内容 | 主に試すもの |
|---|---|---|
| net | TFTP サーバから `Image`(15 MB)を 1024 バイトのブロックで取得 | Ethernet の大きなフレームの受信、割り込み |
| sd | 2 MB の乱数を SD カードの ext4 に書き、ページキャッシュを捨てて読み戻す | SD カードの DMA(読み書き両方) |
| mem | 64 MB の 0 を `/tmp`(RAM)に書く | データキャッシュと DRAM |

**準備**。TFTP サーバの公開ディレクトリに `stress.sh` を置き(`Image` はネットブート用に
置いたものをそのまま使う)、ボードで取ってくる:

```sh
udhcpc -i eth0 -s /usr/share/udhcpc/default.script     # 起動時に取っていれば不要
tftp -g -r stress.sh -l /root/stress.sh <サーバの IP>
chmod +x /root/stress.sh
```

**実行**(分を省くと 120 分):

```sh
/root/stress.sh <サーバの IP> 240
```

10 分ごとに `stress: 時刻 n OK, m NG, uptime ...` が 1 行出る。これが止まったら、その
時点でボードが止まっている。途中経過は別の端末が無いので、止めずに見るなら
`/root/stress.log` を後で見る(1 回ごとに 1 行)。終わると作業ごとの回数と、実行中に
増えたカーネルの警告(`warning` / `oops` / `error` など)を出し、最後に `=== PASS ===`
か `=== FAILED ===` を出す。照合に失敗したファイルは `/tmp/stress.d/net.bad`、
`/root/stress.d/sd.bad.<n>`、`/tmp/stress.d/mem.bad` に残る。

ネットワークを外して試すなら、サーバの代わりに `-` を渡す(`/root/stress.sh - 240`)。
