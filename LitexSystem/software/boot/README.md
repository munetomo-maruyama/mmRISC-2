# SD カードに置くもの

FAT16 の第 1 パーティションのルートに 3 つ。

| ファイル | 出どころ | ロード先 |
|---|---|---|
| `fw_jump.bin` | `scripts/build_opensbi.sh` が**ここに**作る | 0x8000_0000 |
| `Image` | Linux カーネル。Rocket 構成のものをそのまま使う | 0x8020_0000 |
| `boot.json` | 同上 | ― |

`Image` と `boot.json` は CPU に依存しないので、Rocket 構成で作ったもの
(`LitexRocket/software/boot/`)をそのままコピーすればよい。

ルートファイルシステムは第 2 パーティション(ext4、ラベル `rootfs`)。
これも作り直す必要は無い。

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
(`software/rootfs/usr/share/udhcpc/default.script`)を SD カードの第 2
パーティションに一度だけ入れる(PC 側で):

```bash
sudo mkdir -p /media/taka/rootfs/usr/share/udhcpc
sudo cp software/rootfs/usr/share/udhcpc/default.script /media/taka/rootfs/usr/share/udhcpc/
sudo chmod +x /media/taka/rootfs/usr/share/udhcpc/default.script
sync
```

ボードで:

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

```bash
sudo apt install tftpd-hpa          # 公開ディレクトリは /srv/tftp
sudo cp <Image> /srv/tftp/Image
sudo cp LitexSystem/software/boot/fw_jump.bin /srv/tftp/fw_jump.bin
sudo cp <boot.json> /srv/tftp/boot.json   # SD カードの第 1 パーティションと同じもの
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
