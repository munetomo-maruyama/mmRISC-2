<!--
  mmRISC-2 の LiteX BIOS の TFTP ネットブート(LitexSystem/software/boot/README.md
  の「LiteX BIOS の TFTP ネットブート」)で、TFTP サーバを Mac の Parallels Desktop 上の
  Ubuntu に立てたときのノウハウ。別の Claude のチャット「Parallels Desktop の Ubuntu への
  TFTP アクセス」でまとめたもの(2026-09-26)を、そのまま記録する。

  このボードでの補足:
  - クライアントは Arty の LiteX BIOS(`netboot`)。BIOS は `blksize 1024` を要求する
    (下の tcpdump の例と同じ)。置くファイルは Image、fw_jump.bin、boot.json。
  - 実機で最初に netboot が失敗したのは、下の 3 章の ufw で UDP 69 が閉じていたため。
  - ボード側の Linux にも BusyBox の tftp クライアントがあり、外部機器からの確認に使える:
    `tftp -g -b 1024 -r <FILE> <SERVER_IP>`
-->

# Mac (Parallels Desktop) 上の Ubuntu で TFTP サーバを外部公開する手順

Mac 上の Parallels Desktop で動く Ubuntu に TFTP サーバを立て、同一 LAN 上の外部機器（評価ボードなど）からアクセスできるようにするための手順と、つまずきやすいポイントをまとめたものです。

## 表記

本文中のプレースホルダは環境に合わせて読み替えてください。

| 表記 | 意味 | 例 |
|---|---|---|
| `<SERVER_IP>` | Ubuntu（TFTP サーバ）の IP アドレス | 192.168.x.y |
| `<CLIENT_IP>` | 外部機器（TFTP クライアント）の IP アドレス | 192.168.x.z |
| `<LAN_SUBNET>` | LAN のサブネット | 192.168.x.0/24 |
| `<IFACE>` | Ubuntu のネットワークインターフェース名 | enp0s5 など |
| `<FILE>` | 取得するファイル名 | boot.bin など |

## 1. Parallels：ブリッジネットワークにする

VM の「構成」→「ハードウェア」→「ネットワーク」で、ソースを「ブリッジネットワーク」にし、外部機器がつながっている Mac のインターフェース（Wi-Fi / Ethernet / USB-Ethernet）を明示的に選びます。

共有ネットワーク（NAT）でもポート転送は設定できますが、TFTP は最初の要求だけ UDP 69 を使い、データ転送はサーバ側がエフェメラルポートから応答するため、NAT 越しでは不安定になりやすいです。ブリッジのほうが確実です。

設定後、Ubuntu が LAN のアドレスを持っていることを確認します。

```bash
ip -4 addr
```

## 2. Ubuntu：tftpd-hpa をインストール・設定

```bash
sudo apt install tftpd-hpa tftp-hpa
```

`/etc/default/tftpd-hpa`：

```
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure"
```

クライアントからのアップロード（put）で新規ファイル作成を許可する場合は `--create` を、ログを詳しく見たい場合は `-v -v` を `TFTP_OPTIONS` に追加します。

```bash
sudo mkdir -p /srv/tftp
sudo chown tftp:tftp /srv/tftp
sudo chmod 775 /srv/tftp
sudo systemctl restart tftpd-hpa
```

待ち受けを確認します。`0.0.0.0:69`（または `*:69`）なら OK です。`127.0.0.1:69` だと外部から届きません。

```bash
sudo ss -ulnp | grep ':69'
```

## 3. Ubuntu：ufw で UDP 69 を許可する

ufw が有効で既定が `deny (incoming)` の場合、UDP 69 への要求は応答なしで黙って破棄されます。Ubuntu のインストール直後や SSH だけ許可した状態ではこうなっていることが多いので、LAN からの TFTP を許可します。

```bash
sudo ufw allow from <LAN_SUBNET> to any port 69 proto udp comment 'TFTP'
sudo ufw status verbose
```

期待される表示：

```
69/udp                     ALLOW IN    <LAN_SUBNET>               # TFTP
```

許可が必要なのは 69/udp だけです。データ転送はサーバ側から先にエフェメラルポートで送信する流れなので、クライアントからの ACK は conntrack により ESTABLISHED として通過します。

## 4. 動作確認

Ubuntu 側でパケットを監視しながら、外部機器から get します。

```bash
sudo tcpdump -ni any host <CLIENT_IP>
```

外部機器側：

```bash
tftp <SERVER_IP> -c get <FILE>
```

成功時は、RRQ に対して Ubuntu から OACK / DATA が `Out` で出ていきます（ポート番号は環境により異なります）。

```
In  IP <CLIENT_IP>.<cport> > <SERVER_IP>.69: TFTP, RRQ "<FILE>" octet blksize 1024
Out IP <SERVER_IP>.<sport> > <CLIENT_IP>.<cport>: TFTP, OACK ...
In  IP <CLIENT_IP>.<cport> > <SERVER_IP>.<sport>: TFTP, ACK ...
Out IP <SERVER_IP>.<sport> > <CLIENT_IP>.<cport>: TFTP, DATA ...
```

## 注意点

**Ubuntu 自身からのテストでは外部経路を確認できない。** Ubuntu 上で自分の IP 宛てに tftp を実行しても通信は loopback 経由で処理されるため、ufw が外向けインターフェース側で落としていても成功してしまいます。必ず外部機器（少なくとも Mac）から試してください。

**ping が通っても TFTP が通るとは限らない。** ping（ICMP）と TFTP（UDP 69）はファイアウォールの扱いが別です。また、ping に応答しているのが本当に Ubuntu かどうかは、クライアント側の `arp -a` の MAC アドレスと Ubuntu の `ip link` の MAC アドレスを突き合わせて確認できます。

**tcpdump の「In」はファイアウォール通過を意味しない。** tcpdump は netfilter より手前でパケットを捕まえるため、表示されていても ufw で破棄されている場合があります。

**`udp` だけでフィルタすると ICMP を見落とす。** tftpd が待ち受けていない場合はカーネルが ICMP port unreachable を返しますが、`tcpdump ... udp` では表示されません。切り分け時は `host` だけで絞ってください。

## tcpdump の結果による切り分け

| tcpdump の様子 | 原因の候補 |
|---|---|
| RRQ すら見えない | Mac（pf、セキュリティソフト）、Parallels のネットワーク設定、IP の重複 |
| RRQ は見えるが応答がまったく出ない | Ubuntu のファイアウォール（ufw / iptables / nftables）で破棄 |
| RRQ に対して ICMP port unreachable が返る | tftpd が待ち受けていない（`TFTP_ADDRESS` の設定など） |
| DATA は出ているがクライアントが失敗 | クライアント側のファイアウォール（Windows など）や途中の機器 |

### 確認用コマンド

Ubuntu：

```bash
sudo ufw status verbose
sudo journalctl -k | grep 'UFW BLOCK' | grep 'DPT=69'
sudo nft list ruleset
sudo journalctl -u tftpd-hpa -f
```

Mac：

```bash
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
sudo pfctl -s info
sudo pfctl -s rules
```

外部から UDP 69 の見え方を確認（nmap がある場合）：

```bash
sudo nmap -sU -p 69 <SERVER_IP>
```

## 補足

NFS や DHCP など別のサービスを Ubuntu 上で外部公開する場合も、同様に `sudo ufw allow` で個別にポートを開ける必要があります。
